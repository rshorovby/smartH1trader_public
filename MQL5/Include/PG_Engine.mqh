#ifndef PG_ENGINE_MQH
#define PG_ENGINE_MQH

#include "PG_Config.mqh"
#include "SHT_Log.mqh"
#include "SHT_Risk.mqh"
#include "SHT_News.mqh"
#include "SHT_Exec.mqh"

bool     g_pg_replay      = false;
bool     g_pg_pos         = false;
datetime g_pg_entry_t     = 0;
double   g_pg_entry       = 0.0;
double   g_pg_sl          = 0.0;
double   g_pg_highest     = 0.0;
bool     g_pg_trail_on    = false;
double   g_pg_lots        = 0.0;
double   g_pg_risk_money  = 0.0;
ulong    g_pg_ticket      = 0;
int      g_pg_trade_id    = 0;
int      g_pg_consec_loss = 0;
datetime g_pg_cd_until    = 0;
string   g_pg_last_why    = "";
bool     g_pg_last_sig    = false;

double PG_LossMoneyForLots(const int side, const double lots, const double entry, const double sl)
{
   if(lots <= 0.0 || entry <= 0.0 || sl <= 0.0)
      return 0.0;
   double profit = 0.0;
   const ENUM_ORDER_TYPE typ = (side > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   if(!OrderCalcProfit(typ, _Symbol, lots, entry, sl, profit))
      return 0.0;
   return MathMax(0.0, -profit);
}

double PG_LotsForStopLive(const int side, const double entry, const double sl)
{
   const double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   const double risk_money = equity * g_risk_pct;
   const double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   const double vmax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   const double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(equity <= 0.0 || risk_money <= 0.0 || vmin <= 0.0 || step <= 0.0)
   {
      g_risk_why = "no equity / volume step";
      return 0.0;
   }

   double lo = vmin;
   double hi = vmax;
   double best = 0.0;
   for(int i = 0; i < 32; i++)
   {
      const double mid = SHT_NormalizeLots((lo + hi) * 0.5);
      if(mid <= 0.0)
         break;
      const double loss = PG_LossMoneyForLots(side, mid, entry, sl);
      if(loss <= risk_money + 1e-6)
      {
         best = mid;
         lo = mid + step;
      }
      else
         hi = mid - step;
   }

   if(best <= 0.0)
   {
      const double min_loss = PG_LossMoneyForLots(side, vmin, entry, sl);
      g_risk_why = "min lot risks " + DoubleToString(min_loss, 2)
                   + " > target " + DoubleToString(risk_money, 2);
      return 0.0;
   }
   return best;
}

bool PG_RiskCanEnterLive(const datetime t, const bool replay, const int side,
                         const double entry, const double sl, const double floating,
                         double &lots)
{
   lots = 0.0;
   if(replay)
      return SHT_RiskCanEnter(t, replay, MathAbs(entry - sl), floating, lots);

   SHT_RiskOnBar(t);
   if(SHT_RiskHalted(floating))
   {
      g_day_skips++;
      return false;
   }

   lots = PG_LotsForStopLive(side, entry, sl);
   if(lots <= 0.0)
      return false;

   const double loss = PG_LossMoneyForLots(side, lots, entry, sl);
   const double risk_money = AccountInfoDouble(ACCOUNT_EQUITY) * g_risk_pct;
   if(loss > risk_money + 0.01)
   {
      g_risk_why = "calc risk " + DoubleToString(loss, 2)
                   + " > target " + DoubleToString(risk_money, 2);
      return false;
   }

   g_risk_why = "";
   return true;
}

double PG_Stdev(const double &a[], const int shift, const int n)
{
   if(n < 2)
      return 0.0;
   double sum = 0.0;
   for(int i = 0; i < n; i++)
      sum += a[shift + i];
   const double mean = sum / n;
   double acc = 0.0;
   for(int i = 0; i < n; i++)
   {
      const double d = a[shift + i] - mean;
      acc += d * d;
   }
   return MathSqrt(acc / (n - 1));
}

bool PG_M30Signal(const datetime h1_open, bool &on)
{
   on = false;
   if(h1_open <= 0)
      return false;

   int sh = iBarShift(_Symbol, PG_SIGNAL_TF, h1_open, true);
   if(sh < 0)
   {
      sh = iBarShift(_Symbol, PG_SIGNAL_TF, h1_open, false);
      if(sh < 0)
         return false;
      const datetime mt = iTime(_Symbol, PG_SIGNAL_TF, sh);
      if(mt > h1_open)
         sh++;
   }
   if(sh < 0 || sh + PG_WARMUP >= Bars(_Symbol, PG_SIGNAL_TF))
      return false;

   const int need = sh + PG_VWMA_LEN + PG_ROC_LEN + 2;
   double cl[];
   long   vol[];
   ArraySetAsSeries(cl, true);
   ArraySetAsSeries(vol, true);
   if(CopyClose(_Symbol, PG_SIGNAL_TF, 0, need, cl) < need)
      return false;
   if(CopyTickVolume(_Symbol, PG_SIGNAL_TF, 0, need, vol) < need)
      return false;

   double num = 0.0;
   double den = 0.0;
   for(int i = 0; i < PG_VWMA_LEN; i++)
   {
      const double v = (vol[sh + i] > 0 ? (double)vol[sh + i] : 1.0);
      num += cl[sh + i] * v;
      den += v;
   }
   if(den <= 0.0 || cl[sh + PG_ROC_LEN] <= 0.0)
      return false;

   const double vw  = num / den;
   const double sd  = PG_Stdev(cl, sh, PG_SD_LEN);
   const double sd1 = vw - sd;
   const double roc = (cl[sh] / cl[sh + PG_ROC_LEN] - 1.0) * 100.0;
   on = (cl[sh] > sd1 && roc > 0.0);
   return true;
}

bool PG_Weekend(const datetime t)
{
   MqlDateTime dt;
   TimeToStruct(t, dt);
   return (dt.day_of_week == 0 || dt.day_of_week == 6);
}

bool PG_InCooldown(const datetime t)
{
   return (g_pg_cd_until > 0 && t < g_pg_cd_until);
}

void PG_ClearCd(const datetime t)
{
   if(g_pg_cd_until > 0 && t >= g_pg_cd_until)
   {
      g_pg_cd_until    = 0;
      g_pg_consec_loss = 0;
   }
}

void PG_Mark(const string tag, const datetime t, const double px,
             const int arrow, const color clr)
{
   const string n = PG_MRK + tag + IntegerToString(g_pg_trade_id);
   if(ObjectFind(0, n) >= 0)
      ObjectDelete(0, n);
   ObjectCreate(0, n, OBJ_ARROW, 0, t, px);
   ObjectSetInteger(0, n, OBJPROP_ARROWCODE, arrow);
   ObjectSetInteger(0, n, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, n, OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
}

void PG_LevelsDraw()
{
   const string n_e = PG_MRK + "entry";
   const string n_s = PG_MRK + "sl";
   if(!g_pg_pos)
   {
      if(ObjectFind(0, n_e) >= 0)
         ObjectDelete(0, n_e);
      if(ObjectFind(0, n_s) >= 0)
         ObjectDelete(0, n_s);
      return;
   }
   if(ObjectFind(0, n_e) < 0)
      ObjectCreate(0, n_e, OBJ_HLINE, 0, 0, g_pg_entry);
   ObjectSetDouble(0, n_e, OBJPROP_PRICE, g_pg_entry);
   ObjectSetInteger(0, n_e, OBJPROP_COLOR, clrDodgerBlue);
   ObjectSetInteger(0, n_e, OBJPROP_STYLE, STYLE_SOLID);
   ObjectSetInteger(0, n_e, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, n_e, OBJPROP_SELECTABLE, false);

   if(ObjectFind(0, n_s) < 0)
      ObjectCreate(0, n_s, OBJ_HLINE, 0, 0, g_pg_sl);
   ObjectSetDouble(0, n_s, OBJPROP_PRICE, g_pg_sl);
   ObjectSetInteger(0, n_s, OBJPROP_COLOR, clrTomato);
   ObjectSetInteger(0, n_s, OBJPROP_STYLE, STYLE_DASH);
   ObjectSetInteger(0, n_s, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, n_s, OBJPROP_SELECTABLE, false);
}

double PG_NowFloating()
{
   if(!g_pg_pos || g_pg_entry <= 0.0)
      return 0.0;
   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const double rdist = g_pg_entry * PG_EMERG_SL;
   if(rdist <= 0.0)
      return 0.0;
   return ((bid - g_pg_entry) / rdist) * g_pg_risk_money;
}

void PG_OnClosed(const datetime t, const double px, const string reason)
{
   const double rdist = g_pg_entry * PG_EMERG_SL;
   const double r = (rdist > 0.0 ? (px - g_pg_entry) / rdist : 0.0);
   const double pnl = r * g_pg_risk_money;
   if(!g_pg_replay)
      SHT_RiskAddPnl(pnl);

   if(r < 0.0)
   {
      g_pg_consec_loss++;
      if(g_pg_consec_loss >= 2)
      {
         g_pg_cd_until = t + (datetime)(PG_CD_HOURS * 3600.0);
         SHT_Info("cooldown 2h after two losses until "
                  + TimeToString(g_pg_cd_until, TIME_DATE | TIME_MINUTES));
      }
   }
   else
      g_pg_consec_loss = 0;

   PG_Mark("x", t, px, 251, (r > 0.0 ? clrLimeGreen : clrTomato));
   SHT_Info((g_pg_replay ? "replay " : (g_live ? "LIVE " : "shadow "))
            + "close #" + IntegerToString(g_pg_trade_id)
            + " " + reason
            + " px=" + DoubleToString(px, _Digits)
            + " R=" + DoubleToString(r, 3)
            + " consecLoss=" + IntegerToString(g_pg_consec_loss));

   g_pg_pos        = false;
   g_pg_ticket     = 0;
   g_pg_entry      = 0.0;
   g_pg_sl         = 0.0;
   g_pg_highest    = 0.0;
   g_pg_trail_on   = false;
   g_pg_lots       = 0.0;
   g_pg_risk_money = 0.0;
   g_pg_entry_t    = 0;
   if(!g_pg_replay)
      PG_LevelsDraw();
}

bool PG_CloseNow(const datetime t, const double px, const string reason)
{
   if(!g_pg_pos)
      return true;
   if(g_live && !g_pg_replay && g_pg_ticket != 0)
   {
      if(!SHT_ExecCloseTicket(g_pg_ticket))
         return false;
   }
   PG_OnClosed(t, px, reason);
   return true;
}

double PG_TrailStop()
{
   const double emerg = g_pg_entry * (1.0 - PG_EMERG_SL);
   if(!g_pg_trail_on)
      return emerg;
   const double trail = g_pg_highest * (1.0 - PG_TRAIL_DIST);
   return MathMax(emerg, trail);
}

void PG_ManageBar(const datetime t, const double high, const double low)
{
   if(!g_pg_pos || t <= g_pg_entry_t)
      return;

   g_pg_highest = MathMax(g_pg_highest, high);
   if(g_pg_highest >= g_pg_entry * (1.0 + PG_TRAIL_ACT))
      g_pg_trail_on = true;

   const double stop = PG_TrailStop();
   g_pg_sl = stop;
   if(low <= stop)
   {
      const bool trail_hit = (g_pg_trail_on && stop > g_pg_entry * (1.0 - PG_EMERG_SL) + 1e-8);
      PG_CloseNow(t, stop, (trail_hit ? "trail" : "emerg_sl"));
   }
}

void PG_ManageTick()
{
   if(!g_pg_pos || g_pg_replay)
      return;

   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   g_pg_highest = MathMax(g_pg_highest, bid);
   g_pg_highest = MathMax(g_pg_highest, ask);
   if(g_pg_highest >= g_pg_entry * (1.0 + PG_TRAIL_ACT))
      g_pg_trail_on = true;

   const double stop = PG_TrailStop();
   if(stop > g_pg_sl + SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 0.5)
   {
      g_pg_sl = stop;
      if(g_live && g_pg_ticket != 0)
         SHT_ExecModify(g_pg_sl, 0.0);
      PG_LevelsDraw();
   }
}

bool PG_TryEnter(const datetime bar_time, const double close_px)
{
   g_pg_last_why = "";
   if(g_pg_pos)
      return false;
   if(PG_InCooldown(bar_time))
   {
      g_pg_last_why = "cooldown";
      return false;
   }
   if(PG_Weekend(bar_time))
   {
      g_pg_last_why = "weekend";
      return false;
   }
   if(!g_pg_replay && SHT_NewsBlocks(bar_time))
   {
      g_pg_last_why = "news window";
      return false;
   }

   bool sig = false;
   if(!PG_M30Signal(bar_time, sig) || !sig)
   {
      g_pg_last_why = (sig ? "" : "no M30 signal");
      return false;
   }

   double lots = 0.0;
   const double pre_entry = (g_live && !g_pg_replay)
                            ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                            : close_px;
   const double pre_sl = pre_entry * (1.0 - PG_EMERG_SL);
   const double floating = PG_NowFloating();
   if(!PG_RiskCanEnterLive(bar_time, g_pg_replay, 1, pre_entry, pre_sl, floating, lots))
   {
      g_pg_last_why = g_risk_why;
      return false;
   }

   const double sl = pre_sl;
   ulong ticket = 0;
   double entry_px = close_px;
   if(g_live && !g_pg_replay)
   {
      if(SHT_ExecCount() > 0)
      {
         g_pg_last_why = "broker already has this magic";
         return false;
      }
      g_pg_trade_id++;
      ticket = SHT_ExecSend(1, lots, sl, 0.0, "PG#" + IntegerToString(g_pg_trade_id));
      if(ticket == 0)
      {
         g_pg_last_why = g_risk_why;
         g_pg_trade_id--;
         return false;
      }
      if(SHT_ExecSelectTicket(ticket))
         entry_px = PositionGetDouble(POSITION_PRICE_OPEN);
      const double live_sl = entry_px * (1.0 - PG_EMERG_SL);
      if(!SHT_ExecModify(live_sl, 0.0))
      {
         SHT_ExecCloseTicket(ticket);
         g_risk_why = "failed to align SL after fill";
         g_pg_last_why = g_risk_why;
         g_pg_trade_id--;
         return false;
      }
   }
   else
      g_pg_trade_id++;

   g_pg_pos        = true;
   g_pg_ticket     = ticket;
   g_pg_entry      = entry_px;
   g_pg_entry_t    = bar_time;
   g_pg_sl         = entry_px * (1.0 - PG_EMERG_SL);
   g_pg_highest    = entry_px;
   g_pg_trail_on   = false;
   g_pg_lots       = lots;
   g_pg_risk_money = AccountInfoDouble(ACCOUNT_EQUITY) * g_risk_pct;

   PG_Mark("e", bar_time, entry_px, 233, clrDodgerBlue);
   if(!g_pg_replay)
      PG_LevelsDraw();
   const double risk_money = PG_LossMoneyForLots(1, lots, entry_px, g_pg_sl);
   SHT_Info((g_pg_replay ? "replay " : (g_live ? "LIVE " : "shadow "))
            + "open #" + IntegerToString(g_pg_trade_id)
            + " long entry=" + DoubleToString(entry_px, _Digits)
            + " sl=" + DoubleToString(g_pg_sl, _Digits)
            + " lots=" + DoubleToString(lots, 2)
            + " risk$=" + DoubleToString(risk_money, 2));
   return true;
}

bool PG_EngineOnBar(const int shift, const bool replay)
{
   g_pg_replay = replay;
   const datetime t = iTime(_Symbol, PERIOD_H1, shift);
   const double h = iHigh(_Symbol, PERIOD_H1, shift);
   const double l = iLow(_Symbol, PERIOD_H1, shift);
   const double c = iClose(_Symbol, PERIOD_H1, shift);
   if(t <= 0 || h <= 0.0)
      return false;

   SHT_RiskOnBar(t);
   PG_ClearCd(t);

   bool sig = false;
   PG_M30Signal(t, sig);
   g_pg_last_sig = sig;

   PG_ManageBar(t, h, l);
   if(shift > 0)
      PG_TryEnter(t, c);
   return true;
}

void PG_EngineReplay()
{
   ObjectsDeleteAll(0, PG_MRK);
   g_pg_pos         = false;
   g_pg_ticket      = 0;
   g_pg_consec_loss = 0;
   g_pg_cd_until    = 0;
   g_pg_trade_id    = 0;

   const int bars = Bars(_Symbol, PERIOD_H1);
   int start = bars - 2;
   if(start > PG_REPLAY_BARS)
      start = PG_REPLAY_BARS;
   for(int sh = start; sh >= 1; sh--)
   {
      if(!PG_EngineOnBar(sh, true))
         break;
   }
   g_pg_replay = false;
   SHT_Info("PG replay done trades#" + IntegerToString(g_pg_trade_id)
            + " pos=" + (g_pg_pos ? "yes" : "no")
            + " consecLoss=" + IntegerToString(g_pg_consec_loss));
}

void PG_LiveAfterReplay()
{
   const bool live_pos = (g_live && SHT_ExecHasPos());
   if(live_pos)
   {
      const ulong ticket = SHT_ExecTicket();
      if(!SHT_ExecSelectTicket(ticket))
         return;
      g_pg_pos        = true;
      g_pg_ticket     = ticket;
      g_pg_entry      = PositionGetDouble(POSITION_PRICE_OPEN);
      g_pg_entry_t    = (datetime)PositionGetInteger(POSITION_TIME);
      g_pg_sl         = PositionGetDouble(POSITION_SL);
      g_pg_lots       = PositionGetDouble(POSITION_VOLUME);
      g_pg_risk_money = AccountInfoDouble(ACCOUNT_EQUITY) * g_risk_pct;
      const double emerg = g_pg_entry * (1.0 - PG_EMERG_SL);
      g_pg_trail_on = (g_pg_sl > emerg + SymbolInfoDouble(_Symbol, SYMBOL_POINT));
      g_pg_highest  = (g_pg_trail_on && PG_TRAIL_DIST > 0.0)
                      ? (g_pg_sl / (1.0 - PG_TRAIL_DIST))
                      : MathMax(g_pg_entry, SymbolInfoDouble(_Symbol, SYMBOL_BID));
      if(g_pg_trade_id <= 0)
         g_pg_trade_id = 1;
      SHT_Warn("adopted LIVE ticket=" + IntegerToString((long)ticket)
               + " entry=" + DoubleToString(g_pg_entry, _Digits)
               + " sl=" + DoubleToString(g_pg_sl, _Digits));
      PG_LevelsDraw();
      return;
   }

   if(g_pg_pos && (!g_live || !SHT_ExecHasPos()))
   {
      SHT_Info("replay shadow position dropped — no live ticket");
      g_pg_pos      = false;
      g_pg_ticket   = 0;
      g_pg_entry    = 0.0;
      g_pg_trail_on = false;
   }
}

void PG_LiveTick()
{
   if(g_pg_replay)
      return;
   if(g_pg_pos && g_live && g_pg_ticket != 0 && !SHT_ExecSelectTicket(g_pg_ticket))
   {
      const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      PG_OnClosed(TimeCurrent(), bid, "broker_exit");
      return;
   }
   if(g_pg_pos)
      PG_ManageTick();
}

void PG_NewsTickFlatten()
{
   if(!g_pg_pos || g_pg_replay)
      return;
   if(!SHT_NewsShouldFlatten(g_pg_entry_t, TimeCurrent()))
      return;
   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   PG_CloseNow(TimeCurrent(), bid, "news_flatten");
}

bool PG_Ready()
{
   return (Bars(_Symbol, PERIOD_H1) > PG_WARMUP
           && Bars(_Symbol, PG_SIGNAL_TF) > PG_WARMUP + PG_VWMA_LEN);
}

string PG_EngineComment()
{
   string cd = "cd off";
   if(PG_InCooldown(TimeCurrent()))
   {
      const int m = (int)((g_pg_cd_until - TimeCurrent()) / 60);
      cd = "cd " + IntegerToString(m) + "m";
   }
   string pos = "flat";
   if(g_pg_pos)
      pos = "LONG #" + IntegerToString(g_pg_trade_id)
            + "  entry " + DoubleToString(g_pg_entry, _Digits)
            + "  sl " + DoubleToString(g_pg_sl, _Digits)
            + (g_pg_trail_on ? "  TRAIL" : "");
   return "M30 signal " + (g_pg_last_sig ? "ON" : "off")
          + "  " + pos + "\n"
          + cd + "  consecLoss=" + IntegerToString(g_pg_consec_loss) + "\n"
          + SHT_RiskLine(PG_NowFloating()) + "\n"
          + SHT_NewsLine() + "\n"
          + "weekend: close by hand — EA does not flatten Friday\n"
          + (g_pg_last_why != "" ? ("last skip: " + g_pg_last_why) : "");
}

#endif
