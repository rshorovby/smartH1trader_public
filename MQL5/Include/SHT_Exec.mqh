#ifndef SHT_EXEC_MQH
#define SHT_EXEC_MQH

#include <Trade/Trade.mqh>
#include "SHT_Config.mqh"
#include "SHT_Log.mqh"
#include "SHT_Risk.mqh"

bool     g_live      = false;
long     g_magic     = 26081301;
int      g_deviation = 50;
CTrade   g_sht_trade;
double   g_open_lots = 0.0;

ENUM_ORDER_TYPE_FILLING SHT_Filling()
{
   const long mode = SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((mode & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC)
      return ORDER_FILLING_IOC;
   if((mode & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK)
      return ORDER_FILLING_FOK;
   return ORDER_FILLING_RETURN;
}

double SHT_NormPx(const double px)
{
   return NormalizeDouble(px, _Digits);
}

bool SHT_StopDistanceOk(const int side, const double entry, const double sl)
{
   const int    level = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   const double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   const double need  = (double)level * point;
   if(need <= 0.0)
      return true;
   if(side > 0)
      return ((entry - sl) >= need);
   return ((sl - entry) >= need);
}

void SHT_ExecInit(const long magic, const int deviation, const bool live)
{
   g_magic     = magic;
   g_deviation = deviation;
   g_live      = live;
   g_sht_trade.SetExpertMagicNumber(magic);
   g_sht_trade.SetDeviationInPoints(deviation);
   g_sht_trade.SetTypeFilling(SHT_Filling());
   g_sht_trade.SetAsyncMode(false);
}

bool SHT_ExecAllowed()
{
   if(!g_live)
      return false;
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
   {
      g_risk_why = "AutoTrading button is off";
      return false;
   }
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
   {
      g_risk_why = "EA trading disabled in properties";
      return false;
   }
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED) || !AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
   {
      g_risk_why = "account forbids expert trading";
      return false;
   }
   return true;
}

bool SHT_ExecSelect()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != g_magic)
         continue;
      return true;
   }
   return false;
}

bool SHT_ExecHasPos()
{
   return SHT_ExecSelect();
}

double SHT_ExecVolume()
{
   if(!SHT_ExecSelect())
      return 0.0;
   return PositionGetDouble(POSITION_VOLUME);
}

double SHT_ExecPrice()
{
   if(!SHT_ExecSelect())
      return 0.0;
   return PositionGetDouble(POSITION_PRICE_OPEN);
}

ulong SHT_ExecTicket()
{
   if(!SHT_ExecSelect())
      return 0;
   return (ulong)PositionGetInteger(POSITION_TICKET);
}

bool SHT_ExecOpen(const int side, const double lots, const double sl, const double tp)
{
   if(!SHT_ExecAllowed())
      return false;
   if(SHT_ExecHasPos())
   {
      g_risk_why = "already in a position";
      return false;
   }

   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const double px  = (side > 0 ? ask : bid);
   const double sln = SHT_NormPx(sl);
   const double tpn = (tp > 0.0 ? SHT_NormPx(tp) : 0.0);
   if(!SHT_StopDistanceOk(side, px, sln))
   {
      g_risk_why = "SL inside stop level";
      return false;
   }

   const string note = "SHT";
   bool ok = false;
   if(side > 0)
      ok = g_sht_trade.Buy(lots, _Symbol, 0.0, sln, tpn, note);
   else
      ok = g_sht_trade.Sell(lots, _Symbol, 0.0, sln, tpn, note);

   if(!ok)
   {
      g_risk_why = "OrderSend failed retcode=" + IntegerToString(g_sht_trade.ResultRetcode())
                   + " " + g_sht_trade.ResultComment();
      SHT_Error(g_risk_why);
      return false;
   }
   g_open_lots = lots;
   SHT_Info("LIVE open " + (side > 0 ? "buy" : "sell")
            + " lots=" + DoubleToString(lots, 2)
            + " sl=" + DoubleToString(sln, _Digits)
            + (tpn > 0.0 ? (" tp=" + DoubleToString(tpn, _Digits)) : " tp=none")
            + " deal=" + IntegerToString(g_sht_trade.ResultDeal()));
   return true;
}

bool SHT_ExecClose()
{
   if(!SHT_ExecHasPos())
      return true;
   const ulong ticket = SHT_ExecTicket();
   if(!g_sht_trade.PositionClose(ticket))
   {
      SHT_Error("LIVE close failed retcode=" + IntegerToString(g_sht_trade.ResultRetcode())
                + " " + g_sht_trade.ResultComment());
      return false;
   }
   SHT_Info("LIVE close ticket=" + IntegerToString((long)ticket));
   return true;
}

bool SHT_ExecCloseFrac(const double frac)
{
   if(!SHT_ExecSelect() || frac <= 0.0)
      return false;
   const double vol  = PositionGetDouble(POSITION_VOLUME);
   const double take = SHT_NormalizeLots(vol * frac);
   if(take <= 0.0 || take >= vol - 1e-12)
      return false;
   const ulong ticket = (ulong)PositionGetInteger(POSITION_TICKET);
   if(!g_sht_trade.PositionClosePartial(ticket, take))
   {
      SHT_Error("LIVE partial failed retcode=" + IntegerToString(g_sht_trade.ResultRetcode()));
      return false;
   }
   SHT_Info("LIVE partial " + DoubleToString(take, 2) + " of " + DoubleToString(vol, 2));
   return true;
}

bool SHT_ExecModify(const double sl, const double tp)
{
   if(!SHT_ExecSelect())
      return false;
   const ulong  ticket = (ulong)PositionGetInteger(POSITION_TICKET);
   const double cur_sl = PositionGetDouble(POSITION_SL);
   const double cur_tp = PositionGetDouble(POSITION_TP);
   const double sln    = SHT_NormPx(sl);
   const double tpn    = (tp > 0.0 ? SHT_NormPx(tp) : 0.0);
   if(MathAbs(cur_sl - sln) < SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 0.5
      && MathAbs(cur_tp - tpn) < SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 0.5)
      return true;
   if(!g_sht_trade.PositionModify(ticket, sln, tpn))
   {
      SHT_Error("LIVE modify failed retcode=" + IntegerToString(g_sht_trade.ResultRetcode()));
      return false;
   }
   return true;
}

#endif
