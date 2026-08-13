#ifndef SHT_ENGINE_MQH
#define SHT_ENGINE_MQH

#include "SHT_Config.mqh"
#include "SHT_Log.mqh"
#include "SHT_Vegas.mqh"
#include "SHT_Risk.mqh"
#include "SHT_News.mqh"
#include "SHT_Exec.mqh"

// Vegas Channel Tunnel v1.1 — same numbers as the Python backtest.
#define SHT_RR           3.0
#define SHT_ATR_SL       2.0
#define SHT_TP1_R        1.5
#define SHT_SCALE        0.50
#define SHT_TRAIL_ATR    3.0
#define SHT_RETRACE_TOL  0.0
#define SHT_USE_PARTIAL  true
#define SHT_USE_BE       true
#define SHT_USE_TRAIL    true
#define SHT_USE_REGIME   true
#define SHT_USE_MACRO    true

#define SHT_OBJ_PFX      "SHT_"

int      g_long_state  = 0;
int      g_short_state = 0;
bool     g_pos_on      = false;
int      g_pos_side    = 0;       // +1 long, -1 short
datetime g_pos_time    = 0;
double   g_pos_entry   = 0.0;
double   g_pos_rdist   = 0.0;
double   g_pos_stop    = 0.0;
bool     g_pos_tp1     = false;
bool     g_pos_scaled  = false;
bool     g_pos_ride    = false;
double   g_pos_rem     = 1.0;
double   g_pos_R       = 0.0;
int      g_trade_id    = 0;
int      g_closed_n    = 0;
bool     g_replay      = false;

void SHT_ObjectsWipe()
{
   ObjectsDeleteAll(0, SHT_OBJ_PFX);
}

void SHT_Mark(const string tag, const datetime t, const double px,
              const int arrow, const color clr)
{
   const string n = SHT_OBJ_PFX + tag;
   if(ObjectFind(0, n) >= 0)
      ObjectDelete(0, n);
   ObjectCreate(0, n, OBJ_ARROW, 0, t, px);
   ObjectSetInteger(0, n, OBJPROP_ARROWCODE, arrow);
   ObjectSetInteger(0, n, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, n, OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
}

void SHT_HLine(const string tag, const double px, const color clr, const ENUM_LINE_STYLE st)
{
   const string n = SHT_OBJ_PFX + tag;
   if(ObjectFind(0, n) < 0)
      ObjectCreate(0, n, OBJ_HLINE, 0, 0, px);
   ObjectSetDouble(0, n, OBJPROP_PRICE, px);
   ObjectSetInteger(0, n, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, n, OBJPROP_STYLE, st);
   ObjectSetInteger(0, n, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
}

void SHT_LevelsClear()
{
   ObjectDelete(0, SHT_OBJ_PFX + "SL");
   ObjectDelete(0, SHT_OBJ_PFX + "TP1");
   ObjectDelete(0, SHT_OBJ_PFX + "TP");
}

void SHT_LevelsDraw()
{
   if(!g_pos_on)
   {
      SHT_LevelsClear();
      return;
   }
   SHT_HLine("SL", g_pos_stop, clrOrangeRed, STYLE_DASH);
   const double tp1 = (g_pos_side > 0)
                      ? g_pos_entry + SHT_TP1_R * g_pos_rdist
                      : g_pos_entry - SHT_TP1_R * g_pos_rdist;
   SHT_HLine("TP1", tp1, clrGold, STYLE_DOT);
   if(!g_pos_ride)
   {
      const double tp = (g_pos_side > 0)
                        ? g_pos_entry + SHT_RR * g_pos_rdist
                        : g_pos_entry - SHT_RR * g_pos_rdist;
      SHT_HLine("TP", tp, clrLimeGreen, STYLE_DASH);
   }
   else
      ObjectDelete(0, SHT_OBJ_PFX + "TP");
}

void SHT_ShadowFill(const double px, const double frac, const string tag)
{
   if(frac <= 1e-12 || g_pos_rem <= 1e-12)
      return;
   const double take = MathMin(frac, g_pos_rem);
   const double r = (g_pos_side > 0)
                    ? (px - g_pos_entry) / g_pos_rdist
                    : (g_pos_entry - px) / g_pos_rdist;
   g_pos_R   += r * take;
   g_pos_rem -= take;
   if(!g_replay)
   {
      SHT_RiskAddPnl(r * take * g_pos_risk_money);
      SHT_Info("shadow fill #" + IntegerToString(g_trade_id)
               + " " + tag
               + " " + DoubleToString(take * 100, 0) + "%"
               + " @" + DoubleToString(px, _Digits)
               + " " + DoubleToString(r, 2) + "R");
   }
}

void SHT_ShadowClose(const datetime t, const double px, const string reason)
{
   if(g_live && !g_replay)
   {
      if(!SHT_ExecClose())
         return;
   }
   if(g_pos_rem > 1e-12)
      SHT_ShadowFill(px, g_pos_rem, reason);
   g_closed_n++;
   SHT_Mark("X" + IntegerToString(g_trade_id), t, px, 251,
            (g_pos_R > 0.0 ? clrLimeGreen : clrOrangeRed));
   SHT_Info((g_replay ? "replay " : "")
            + "shadow close #" + IntegerToString(g_trade_id)
            + " " + (g_pos_side > 0 ? "long" : "short")
            + " " + reason
            + " exit=" + DoubleToString(px, _Digits)
            + " R=" + DoubleToString(g_pos_R, 3)
            + (g_pos_ride ? " ride" : ""));
   g_pos_on     = false;
   g_pos_side   = 0;
   g_pos_rem    = 1.0;
   g_pos_R      = 0.0;
   g_pos_tp1    = false;
   g_pos_scaled = false;
   g_pos_ride   = false;
   g_pos_lots   = 0.0;
   SHT_LevelsClear();
}

void SHT_ShadowOpen(const datetime t, const double close_px, const double atr,
                    const int side, const bool ride, const double lots)
{
   const double sl = (side > 0)
                     ? close_px - atr * SHT_ATR_SL
                     : close_px + atr * SHT_ATR_SL;
   const double sl_dist = MathAbs(close_px - sl);
   if(sl_dist <= 0.0 || lots <= 0.0)
      return;

   double entry_px = close_px;
   double sl_use   = sl;
   if(g_live && !g_replay)
   {
      const double tp_send = ride ? 0.0
                                  : (side > 0 ? close_px + SHT_RR * sl_dist
                                              : close_px - SHT_RR * sl_dist);
      if(!SHT_ExecOpen(side, lots, sl, tp_send))
         return;
      for(int w = 0; w < 20 && !SHT_ExecHasPos(); w++)
         Sleep(50);
      if(!SHT_ExecHasPos())
      {
         SHT_Error("LIVE open sent but no position appeared");
         return;
      }
      entry_px = SHT_ExecPrice();
      const double filled_dist = MathAbs(entry_px - sl);
      if(filled_dist > 0.0)
         sl_use = sl;
   }

   g_trade_id++;
   g_pos_on     = true;
   g_pos_side   = side;
   g_pos_time   = t;
   g_pos_entry  = entry_px;
   g_pos_rdist  = MathAbs(entry_px - sl_use);
   if(g_pos_rdist <= 0.0)
      g_pos_rdist = sl_dist;
   g_pos_stop   = sl_use;
   g_pos_tp1    = false;
   g_pos_scaled = false;
   g_pos_ride   = ride;
   g_pos_rem    = 1.0;
   g_pos_R      = 0.0;
   g_pos_lots   = lots;
   g_pos_eq     = AccountInfoDouble(ACCOUNT_EQUITY);
   g_pos_risk_money = g_pos_eq * g_risk_pct;

   if(g_live && !g_replay && !ride)
   {
      const double tp_adj = (side > 0)
                            ? g_pos_entry + SHT_RR * g_pos_rdist
                            : g_pos_entry - SHT_RR * g_pos_rdist;
      SHT_ExecModify(g_pos_stop, tp_adj);
   }

   SHT_Mark("E" + IntegerToString(g_trade_id), t, g_pos_entry,
            (side > 0 ? 233 : 234),
            (side > 0 ? clrDodgerBlue : clrOrchid));
   SHT_Info((g_replay ? "replay " : (g_live ? "LIVE " : "shadow "))
            + "open #" + IntegerToString(g_trade_id)
            + " " + (side > 0 ? "long" : "short")
            + " entry=" + DoubleToString(g_pos_entry, _Digits)
            + " sl=" + DoubleToString(g_pos_stop, _Digits)
            + " r=" + DoubleToString(g_pos_rdist, _Digits)
            + " lots=" + DoubleToString(lots, 2)
            + (ride ? " ride" : ""));
   if(!g_replay)
      SHT_LevelsDraw();
}

double SHT_NowFloating()
{
   if(!g_pos_on)
      return 0.0;
   return SHT_RiskFloating(g_pos_side, g_pos_entry, g_pos_rdist, g_pos_rem,
                           SymbolInfoDouble(_Symbol, SYMBOL_BID));
}

void SHT_Manage(const datetime t, const double high, const double low,
                const double close_px, const double atr)
{
   if(!g_pos_on)
      return;

   const bool do_partial = SHT_USE_PARTIAL && !g_pos_ride;
   const bool trail_eff  = SHT_USE_TRAIL || g_pos_ride;

   if(g_pos_side > 0)
   {
      const double tp1    = g_pos_entry + SHT_TP1_R * g_pos_rdist;
      const double tp_end = g_pos_entry + SHT_RR    * g_pos_rdist;
      if(high >= tp1)
         g_pos_tp1 = true;
      if(SHT_USE_BE && g_pos_tp1)
         g_pos_stop = MathMax(g_pos_stop, g_pos_entry);
      if(trail_eff && g_pos_tp1)
         g_pos_stop = MathMax(g_pos_stop, close_px - atr * SHT_TRAIL_ATR);
      if(do_partial && !g_pos_scaled && high >= tp1)
      {
         if(g_live && !g_replay)
         {
            if(SHT_ExecCloseFrac(SHT_SCALE))
               SHT_ShadowFill(tp1, SHT_SCALE, "tp1");
            else
               SHT_Info("LIVE skip partial (lot too small) - keep full size");
            g_pos_scaled = true;
         }
         else
         {
            SHT_ShadowFill(tp1, SHT_SCALE, "tp1");
            g_pos_scaled = true;
         }
      }
      if(g_live && !g_replay)
         SHT_ExecModify(g_pos_stop, g_pos_ride ? 0.0 : tp_end);
      else if(g_pos_rem > 1e-12)
      {
         if(!g_pos_ride && high >= tp_end)
            SHT_ShadowClose(t, tp_end, "tp_final");
         else if(low <= g_pos_stop)
            SHT_ShadowClose(t, g_pos_stop, g_pos_tp1 ? "trail" : "stop");
      }
   }
   else
   {
      const double tp1    = g_pos_entry - SHT_TP1_R * g_pos_rdist;
      const double tp_end = g_pos_entry - SHT_RR    * g_pos_rdist;
      if(low <= tp1)
         g_pos_tp1 = true;
      if(SHT_USE_BE && g_pos_tp1)
         g_pos_stop = MathMin(g_pos_stop, g_pos_entry);
      if(trail_eff && g_pos_tp1)
         g_pos_stop = MathMin(g_pos_stop, close_px + atr * SHT_TRAIL_ATR);
      if(do_partial && !g_pos_scaled && low <= tp1)
      {
         if(g_live && !g_replay)
         {
            if(SHT_ExecCloseFrac(SHT_SCALE))
               SHT_ShadowFill(tp1, SHT_SCALE, "tp1");
            else
               SHT_Info("LIVE skip partial (lot too small) - keep full size");
            g_pos_scaled = true;
         }
         else
         {
            SHT_ShadowFill(tp1, SHT_SCALE, "tp1");
            g_pos_scaled = true;
         }
      }
      if(g_live && !g_replay)
         SHT_ExecModify(g_pos_stop, g_pos_ride ? 0.0 : tp_end);
      else if(g_pos_rem > 1e-12)
      {
         if(!g_pos_ride && low <= tp_end)
            SHT_ShadowClose(t, tp_end, "tp_final");
         else if(high >= g_pos_stop)
            SHT_ShadowClose(t, g_pos_stop, g_pos_tp1 ? "trail" : "stop");
      }
   }
   if(g_pos_on && !g_replay)
      SHT_LevelsDraw();
}

bool SHT_EngineOnBar(const int shift, const bool replay)
{
   g_replay = replay;

   SHTVegasSnap snap;
   if(!SHT_VegasRead(snap, shift))
      return false;

   const datetime t = iTime(_Symbol, PERIOD_CURRENT, shift);
   const double h = iHigh(_Symbol, PERIOD_CURRENT, shift);
   const double l = iLow(_Symbol, PERIOD_CURRENT, shift);
   const double c = iClose(_Symbol, PERIOD_CURRENT, shift);
   if(t <= 0 || snap.atr <= 0.0)
      return false;

   const double tol = SHT_RETRACE_TOL * snap.atr;
   const bool trend_up = (!SHT_USE_MACRO) || (c > snap.macro_up);
   const bool trend_dn = (!SHT_USE_MACRO) || (c < snap.macro_lo);
   const bool broke_up = (c > snap.tunnel_up && snap.ema_trig > snap.tunnel_up);
   const bool broke_dn = (c < snap.tunnel_lo && snap.ema_trig < snap.tunnel_lo);
   const bool allow_long  = (!SHT_USE_REGIME) || (!snap.strong_dn);
   const bool allow_short = (!SHT_USE_REGIME) || (!snap.strong_up);

   const bool long_retrace =
      (g_long_state == 1 && l <= snap.tunnel_up + tol && c > snap.tunnel_up && trend_up);
   const bool short_rebound =
      (g_short_state == 1 && h >= snap.tunnel_lo - tol && c < snap.tunnel_lo && trend_dn);

   if(long_retrace)
      g_long_state = 0;
   if(short_rebound)
      g_short_state = 0;
   if(g_long_state == 1 && (!trend_up || c < snap.tunnel_up))
      g_long_state = 0;
   if(g_short_state == 1 && (!trend_dn || c > snap.tunnel_lo))
      g_short_state = 0;
   if(trend_up && broke_up)
      g_long_state = 1;
   if(trend_dn && broke_dn)
      g_short_state = 1;

   // Manage only after the entry bar, same as the Python loop (i > entry_i).
   // Skip closes inside the news window unless the swing exception (5h+) applies.
   if(g_pos_on && t > g_pos_time)
   {
      const bool news_hold = (!replay && SHT_NewsBlocks(t) && SHT_NewsYoung(g_pos_time, t));
      if(!news_hold)
         SHT_Manage(t, h, l, c, snap.atr);
      else if(!replay)
         SHT_Info("hold through news window — no shadow close");
   }

   if(!g_pos_on)
   {
      if(!replay && SHT_NewsBlocks(t))
      {
         if(long_retrace || short_rebound)
            SHT_Info("skip entry: news window " + SHT_NewsLine());
      }
      else
      {
         const double sl_dist = snap.atr * SHT_ATR_SL;
         double lots = 0.0;
         if(long_retrace && allow_long)
         {
            if(SHT_RiskCanEnter(t, replay, sl_dist, SHT_NowFloating(), lots))
               SHT_ShadowOpen(t, c, snap.atr, +1, SHT_USE_REGIME && snap.strong_up, lots);
            else if(!replay)
               SHT_Info("skip long: " + g_risk_why);
         }
         else if(short_rebound && allow_short)
         {
            if(SHT_RiskCanEnter(t, replay, sl_dist, SHT_NowFloating(), lots))
               SHT_ShadowOpen(t, c, snap.atr, -1, SHT_USE_REGIME && snap.strong_dn, lots);
            else if(!replay)
               SHT_Info("skip short: " + g_risk_why);
         }
      }
   }

   return true;
}

int SHT_EngineReplay()
{
   SHT_ObjectsWipe();
   g_long_state = g_short_state = 0;
   g_pos_on = false;
   g_trade_id = 0;
   g_closed_n = 0;

   const int total = Bars(_Symbol, PERIOD_CURRENT);
   int shift = total - SHT_WARMUP - 1;
   if(shift < 1)
   {
      SHT_Warn("replay skipped: bars=" + IntegerToString(total)
               + " need>" + IntegerToString(SHT_WARMUP + 1));
      return 0;
   }

   int ok = 0;
   for(; shift >= 1; shift--)
   {
      if(SHT_EngineOnBar(shift, true))
         ok++;
   }
   g_replay = false;
   SHT_RiskResetDay(TimeCurrent());
   if(g_pos_on)
      SHT_LevelsDraw();
   ChartRedraw(0);
   SHT_Info("replay bars=" + IntegerToString(ok)
            + " closed=" + IntegerToString(g_closed_n)
            + " open=" + (g_pos_on ? "yes" : "no")
            + (g_pos_on ? (" #" + IntegerToString(g_trade_id)) : ""));
   return ok;
}

void SHT_PaperDrop(const string why)
{
   if(!g_pos_on)
      return;
   SHT_Info("drop paper position: " + why);
   g_pos_on     = false;
   g_pos_side   = 0;
   g_pos_rem    = 1.0;
   g_pos_R      = 0.0;
   g_pos_tp1    = false;
   g_pos_scaled = false;
   g_pos_ride   = false;
   g_pos_lots   = 0.0;
   SHT_LevelsClear();
}

void SHT_LiveAfterReplay()
{
   if(!g_live)
      return;
   if(SHT_ExecHasPos())
   {
      g_pos_on     = true;
      g_pos_side   = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
      g_pos_entry  = PositionGetDouble(POSITION_PRICE_OPEN);
      g_pos_stop   = PositionGetDouble(POSITION_SL);
      g_pos_rdist  = MathAbs(g_pos_entry - g_pos_stop);
      if(g_pos_rdist <= 0.0)
         g_pos_rdist = g_pos_entry * 0.002;
      g_pos_lots   = PositionGetDouble(POSITION_VOLUME);
      g_open_lots  = g_pos_lots;
      g_pos_time   = (datetime)PositionGetInteger(POSITION_TIME);
      g_pos_ride   = (PositionGetDouble(POSITION_TP) <= 0.0);
      g_pos_tp1    = false;
      g_pos_scaled = false;
      g_pos_rem    = 1.0;
      g_pos_R      = 0.0;
      g_pos_eq     = AccountInfoDouble(ACCOUNT_EQUITY);
      g_pos_risk_money = g_pos_eq * g_risk_pct;
      g_trade_id++;
      SHT_Warn("adopted existing LIVE position lots=" + DoubleToString(g_pos_lots, 2)
               + (g_pos_ride ? " ride" : ""));
      SHT_LevelsDraw();
      return;
   }
   if(g_pos_on)
      SHT_PaperDrop("replay paper was not sent to the broker");
}

void SHT_LiveTick()
{
   if(!g_live || g_replay || !g_pos_on)
      return;

   if(!SHT_ExecHasPos())
   {
      const double px = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      SHT_ShadowClose(TimeCurrent(), px, "broker_exit");
      return;
   }

   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   const bool do_partial = SHT_USE_PARTIAL && !g_pos_ride;

   if(g_pos_side > 0)
   {
      const double tp1    = g_pos_entry + SHT_TP1_R * g_pos_rdist;
      const double tp_end = g_pos_entry + SHT_RR    * g_pos_rdist;
      if(bid >= tp1)
         g_pos_tp1 = true;
      if(SHT_USE_BE && g_pos_tp1)
         g_pos_stop = MathMax(g_pos_stop, g_pos_entry);
      if(do_partial && !g_pos_scaled && bid >= tp1)
      {
         if(SHT_ExecCloseFrac(SHT_SCALE))
            SHT_ShadowFill(tp1, SHT_SCALE, "tp1");
         g_pos_scaled = true;
      }
      SHT_ExecModify(g_pos_stop, g_pos_ride ? 0.0 : tp_end);
   }
   else
   {
      const double tp1    = g_pos_entry - SHT_TP1_R * g_pos_rdist;
      const double tp_end = g_pos_entry - SHT_RR    * g_pos_rdist;
      if(ask <= tp1)
         g_pos_tp1 = true;
      if(SHT_USE_BE && g_pos_tp1)
         g_pos_stop = MathMin(g_pos_stop, g_pos_entry);
      if(do_partial && !g_pos_scaled && ask <= tp1)
      {
         if(SHT_ExecCloseFrac(SHT_SCALE))
            SHT_ShadowFill(tp1, SHT_SCALE, "tp1");
         g_pos_scaled = true;
      }
      SHT_ExecModify(g_pos_stop, g_pos_ride ? 0.0 : tp_end);
   }
}

string SHT_EngineComment(const SHTVegasSnap &snap)
{
   string pos = "flat";
   if(g_pos_on)
      pos = (g_pos_side > 0 ? "LONG" : "SHORT")
            + " #" + IntegerToString(g_trade_id)
            + " @" + DoubleToString(g_pos_entry, _Digits)
            + " sl=" + DoubleToString(g_pos_stop, _Digits)
            + " lots=" + DoubleToString(g_pos_lots, 2)
            + " rem=" + DoubleToString(g_pos_rem * 100, 0) + "%"
            + (g_pos_ride ? " RIDE" : "")
            + (g_pos_tp1 ? " tp1" : "");
   return SHT_VegasLine(snap)
          + "\narm L=" + IntegerToString(g_long_state)
          + " S=" + IntegerToString(g_short_state)
          + "  closed=" + IntegerToString(g_closed_n)
          + "\n" + pos
          + "\n" + SHT_RiskLine(SHT_NowFloating())
          + "\n" + SHT_NewsLine()
          + "\n" + (g_live ? "LIVE orders" : "shadow only — no OrderSend");
}

#endif
