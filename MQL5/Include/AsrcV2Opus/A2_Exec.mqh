#ifndef A2_EXEC_MQH
#define A2_EXEC_MQH

#include <Trade/Trade.mqh>
#include "A2_Config.mqh"
#include "A2_Log.mqh"
#include "A2_Risk.mqh"

// Broker interface.
//
// Three changes from the v1 shared layer, all of them about not lying to the
// engine about what the broker did:
//
//   * a rejected send is retried on the transient retcodes with a refreshed
//     price instead of being dropped after one attempt;
//   * the position ticket is resolved from the deal's position id, and when that
//     fails the fallback only accepts a position the engine is not already
//     tracking. v1 fell back to "the newest ticket with our magic", which on a
//     two-leg strategy can bind both legs to the same ticket;
//   * a fill is verified before it is accepted. If the stop did not land on the
//     position, or the fill slipped further than allowed, the position is closed
//     immediately rather than left running unprotected or on wrong risk.

bool   g_a2_live      = false;
long   g_a2_magic     = 26081310;
int    g_a2_deviation = 500;
int    g_a2_max_tries = 3;
CTrade g_a2_trade;

ENUM_ORDER_TYPE_FILLING A2_Filling()
{
   const long mode = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((mode & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC)
      return ORDER_FILLING_IOC;
   if((mode & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK)
      return ORDER_FILLING_FOK;
   return ORDER_FILLING_RETURN;
}

void A2_ExecInit(const long magic, const int deviation, const bool live)
{
   g_a2_magic     = magic;
   g_a2_deviation = deviation;
   g_a2_live      = live;
   g_a2_trade.SetExpertMagicNumber(magic);
   g_a2_trade.SetDeviationInPoints(deviation);
   g_a2_trade.SetTypeFilling(A2_Filling());
   g_a2_trade.SetAsyncMode(false);
}

double A2_NormPx(const double px)
{
   return NormalizeDouble(px, _Digits);
}

bool A2_ExecAllowed()
{
   if(!g_a2_live)
      return false;
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
   {
      g_a2_why = "AutoTrading button is off";
      return false;
   }
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
   {
      g_a2_why = "EA trading disabled in properties";
      return false;
   }
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) || !AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
   {
      g_a2_why = "account forbids expert trading";
      return false;
   }
   return true;
}

bool A2_ExecIsHedge()
{
   return (AccountInfoInteger(ACCOUNT_MARGIN_MODE) == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING);
}

bool A2_ExecSelectTicket(const ulong ticket)
{
   if(ticket == 0)
      return false;
   if(!PositionSelectByTicket(ticket))
      return false;
   if(PositionGetString(POSITION_SYMBOL) != _Symbol)
      return false;
   if(PositionGetInteger(POSITION_MAGIC) != g_a2_magic)
      return false;
   return true;
}

int A2_ExecCount()
{
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetTicket(i) == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != g_a2_magic)
         continue;
      n++;
   }
   return n;
}

bool A2_StopDistanceOk(const int side, const double px, const double sl)
{
   const int    level = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   const double need  = (double)level * SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(need <= 0.0)
      return true;
   return (side > 0) ? ((px - sl) >= need) : ((sl - px) >= need);
}

ulong A2_ExecPositionFromDeal()
{
   const ulong deal = g_a2_trade.ResultDeal();
   if(deal == 0)
      return 0;
   if(!HistorySelect(TimeCurrent() - 300, TimeCurrent() + 5))
      return 0;
   if(!HistoryDealSelect(deal))
      return 0;
   long pos_id = 0;
   if(!HistoryDealGetInteger(deal, DEAL_POSITION_ID, pos_id) || pos_id <= 0)
      return 0;
   return (ulong)pos_id;
}

bool A2_IsKnown(const ulong ticket, const ulong &known[], const int known_n)
{
   for(int i = 0; i < known_n; i++)
      if(known[i] == ticket)
         return true;
   return false;
}

// Only usable when exactly one of our positions is untracked; two candidates mean
// we cannot tell them apart, and guessing is what produced the v1 defect.
ulong A2_ExecResolveUntracked(const ulong &known[], const int known_n)
{
   ulong found = 0;
   int   n     = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != g_a2_magic)
         continue;
      if(A2_IsKnown(ticket, known, known_n))
         continue;
      found = ticket;
      n++;
   }
   if(n != 1)
   {
      if(n > 1)
         A2_Error("cannot resolve the new ticket: " + IntegerToString(n)
                  + " untracked positions carry our magic");
      return 0;
   }
   return found;
}

bool A2_RetryableRetcode(const uint code)
{
   return (code == TRADE_RETCODE_REQUOTE
           || code == TRADE_RETCODE_PRICE_CHANGED
           || code == TRADE_RETCODE_PRICE_OFF
           || code == TRADE_RETCODE_TIMEOUT
           || code == TRADE_RETCODE_CONNECTION
           || code == TRADE_RETCODE_INVALID_PRICE);
}

bool A2_ExecCloseTicket(const ulong ticket)
{
   if(ticket == 0)
      return true;
   if(!A2_ExecSelectTicket(ticket))
      return true;   // already gone
   for(int attempt = 1; attempt <= g_a2_max_tries; attempt++)
   {
      if(g_a2_trade.PositionClose(ticket))
      {
         A2_Info("LIVE close ticket=" + IntegerToString((long)ticket));
         return true;
      }
      const uint code = g_a2_trade.ResultRetcode();
      A2_Warn("close attempt " + IntegerToString(attempt) + " failed ticket="
              + IntegerToString((long)ticket) + " retcode=" + IntegerToString((int)code)
              + " " + g_a2_trade.ResultComment());
      if(!A2_RetryableRetcode(code))
         break;
      Sleep(300);
      if(!A2_ExecSelectTicket(ticket))
         return true;
   }
   A2_Error("LIVE close FAILED ticket=" + IntegerToString((long)ticket)
            + " — position may still be open, check the terminal");
   return false;
}

bool A2_ExecEnsureStop(const ulong ticket, const double sl, const double tp)
{
   if(!A2_ExecSelectTicket(ticket))
      return false;
   const double cur_sl = PositionGetDouble(POSITION_SL);
   const double tol    = SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10.0;
   if(cur_sl > 0.0 && MathAbs(cur_sl - sl) <= tol)
      return true;
   for(int attempt = 1; attempt <= g_a2_max_tries; attempt++)
   {
      if(g_a2_trade.PositionModify(ticket, A2_NormPx(sl), A2_NormPx(tp)))
         return true;
      A2_Warn("stop modify attempt " + IntegerToString(attempt) + " failed retcode="
              + IntegerToString((int)g_a2_trade.ResultRetcode()));
      Sleep(300);
   }
   return false;
}

// Sends, resolves, verifies. Returns 0 unless the position exists with the stop
// attached and the fill inside the allowed slippage.
ulong A2_ExecSend(const int side, const double lots, const double sl, const double tp,
                  const string note, const double expect_px, const double max_slip_px,
                  const ulong &known[], const int known_n, double &fill_px)
{
   fill_px = 0.0;
   if(!A2_ExecAllowed())
      return 0;

   const double sln = A2_NormPx(sl);
   const double tpn = (tp > 0.0 ? A2_NormPx(tp) : 0.0);

   bool sent = false;
   for(int attempt = 1; attempt <= g_a2_max_tries && !sent; attempt++)
   {
      if(!SymbolInfoDouble(_Symbol, SYMBOL_ASK) || !SymbolInfoDouble(_Symbol, SYMBOL_BID))
      {
         g_a2_why = "no quote";
         return 0;
      }
      const double px = (side > 0 ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                  : SymbolInfoDouble(_Symbol, SYMBOL_BID));
      if(!A2_StopDistanceOk(side, px, sln))
      {
         g_a2_why = "SL inside the broker stop level";
         return 0;
      }
      if(max_slip_px > 0.0 && MathAbs(px - expect_px) > max_slip_px)
      {
         g_a2_why = "price moved " + DoubleToString(MathAbs(px - expect_px), _Digits)
                    + " from the signal before we could send";
         return 0;
      }

      sent = (side > 0) ? g_a2_trade.Buy(lots, _Symbol, 0.0, sln, tpn, note)
                        : g_a2_trade.Sell(lots, _Symbol, 0.0, sln, tpn, note);
      if(sent)
         break;

      const uint code = g_a2_trade.ResultRetcode();
      g_a2_why = "OrderSend retcode=" + IntegerToString((int)code) + " "
                 + g_a2_trade.ResultComment();
      A2_Warn("send attempt " + IntegerToString(attempt) + ": " + g_a2_why);
      if(!A2_RetryableRetcode(code))
         return 0;
      Sleep(250);
   }
   if(!sent)
   {
      A2_Error("LIVE open failed after " + IntegerToString(g_a2_max_tries)
               + " attempts: " + g_a2_why);
      return 0;
   }

   ulong ticket = A2_ExecPositionFromDeal();
   for(int w = 0; w < 20 && ticket == 0; w++)
   {
      Sleep(50);
      ticket = A2_ExecPositionFromDeal();
   }
   if(ticket == 0)
      ticket = A2_ExecResolveUntracked(known, known_n);
   if(ticket == 0 || !A2_ExecSelectTicket(ticket))
   {
      g_a2_why = "order filled but the position could not be identified";
      A2_Error("LIVE open sent and NOT tracked — " + g_a2_why + ", flatten by hand");
      return 0;
   }

   fill_px = PositionGetDouble(POSITION_PRICE_OPEN);

   if(!A2_ExecEnsureStop(ticket, sln, tpn))
   {
      A2_Error("stop did not attach to ticket " + IntegerToString((long)ticket)
               + " — closing the position rather than running it naked");
      A2_ExecCloseTicket(ticket);
      g_a2_why = "no stop on the fill";
      return 0;
   }

   if(max_slip_px > 0.0 && MathAbs(fill_px - expect_px) > max_slip_px)
   {
      A2_Error("fill slipped " + DoubleToString(MathAbs(fill_px - expect_px), _Digits)
               + " beyond the " + DoubleToString(max_slip_px, _Digits)
               + " allowance — closing");
      A2_ExecCloseTicket(ticket);
      g_a2_why = "fill outside the slippage allowance";
      return 0;
   }

   A2_Info("LIVE open " + (side > 0 ? "buy" : "sell")
           + " lots=" + DoubleToString(lots, 2)
           + " fill=" + DoubleToString(fill_px, _Digits)
           + " sl=" + DoubleToString(sln, _Digits)
           + (tpn > 0.0 ? (" tp=" + DoubleToString(tpn, _Digits)) : " tp=none")
           + " ticket=" + IntegerToString((long)ticket) + " " + note);
   return ticket;
}

#endif
