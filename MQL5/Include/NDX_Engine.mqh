#ifndef NDX_ENGINE_MQH
#define NDX_ENGINE_MQH

#include "NDX_Config.mqh"
#include "SHT_Log.mqh"
#include "SHT_Risk.mqh"
#include "SHT_News.mqh"
#include "SHT_Exec.mqh"

// NDX 8AM sweep + M1 CISD — same rules as backtest_ndx_8am_sweep.py run_cisd.
#define NDX_RANGE_START   800
#define NDX_RANGE_END     900
#define NDX_SIGNAL_START  900
#define NDX_SIGNAL_END    1100
#define NDX_FLAT_HHMM     1600
#define NDX_WARMUP        120
#define NDX_MRK           "NDX8e_"
#define NDX_LVL           "NDX8l_"

int      g_ndx_max_tr       = 3;
bool     g_ndx_replay       = false;
int      g_ndx_day          = 0;
bool     g_ndx_have_rng     = false;
bool     g_ndx_ready        = false;
double   g_ndx_rng_hi       = 0.0;
double   g_ndx_rng_lo       = 0.0;
datetime g_ndx_rng_t0       = 0;
int      g_ndx_trades_today = 0;

bool     g_ndx_long_armed   = false;
bool     g_ndx_short_armed  = false;
double   g_ndx_long_ext     = 0.0;
double   g_ndx_short_ext    = 0.0;
datetime g_ndx_long_ref_t   = 0;
datetime g_ndx_short_ref_t  = 0;
double   g_ndx_long_ref_h   = 0.0;
double   g_ndx_long_ref_l   = 0.0;
double   g_ndx_short_ref_h  = 0.0;
double   g_ndx_short_ref_l  = 0.0;

bool     g_ndx_pos          = false;
int      g_ndx_side         = 0;
int      g_ndx_id           = 0;
datetime g_ndx_entry_t      = 0;
double   g_ndx_entry        = 0.0;
double   g_ndx_sl           = 0.0;
double   g_ndx_tp           = 0.0;
double   g_ndx_risk         = 0.0;
double   g_ndx_lots         = 0.0;
double   g_ndx_risk_money   = 0.0;
ulong    g_ndx_ticket       = 0;
int      g_ndx_closed_n     = 0;
int      g_ndx_trade_id     = 0;

int NDX_NthSunday(const int year, const int month, const int n)
{
   MqlDateTime dt;
   ZeroMemory(dt);
   dt.year = year;
   dt.mon  = month;
   dt.day  = 1;
   datetime t = StructToTime(dt);
   TimeToStruct(t, dt);
   const int first_sun = (dt.day_of_week == 0) ? 1 : (8 - dt.day_of_week);
   return first_sun + (n - 1) * 7;
}

bool NDX_UsDst(const datetime gmt)
{
   MqlDateTime dt;
   TimeToStruct(gmt, dt);
   if(dt.mon > 3 && dt.mon < 11)
      return true;
   if(dt.mon < 3 || dt.mon > 11)
      return false;
   if(dt.mon == 3)
      return (dt.day >= NDX_NthSunday(dt.year, 3, 2));
   return (dt.day < NDX_NthSunday(dt.year, 11, 1));
}

datetime NDX_BarGmt(const datetime server_t)
{
   return server_t - (TimeCurrent() - TimeGMT());
}

void NDX_NyStamp(const datetime server_t, MqlDateTime &ny)
{
   const datetime gmt = NDX_BarGmt(server_t);
   const int off = NDX_UsDst(gmt) ? 4 : 5;
   TimeToStruct(gmt - off * 3600, ny);
}

int NDX_NyDay(const datetime server_t)
{
   MqlDateTime ny;
   NDX_NyStamp(server_t, ny);
   return ny.year * 10000 + ny.mon * 100 + ny.day;
}

int NDX_NyHhmm(const datetime server_t)
{
   MqlDateTime ny;
   NDX_NyStamp(server_t, ny);
   return ny.hour * 100 + ny.min;
}

double NDX_TickSize()
{
   double t = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(t <= 0.0)
      t = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(t <= 0.0)
      t = 0.1;
   return t;
}

double NDX_NowFloating()
{
   if(!g_ndx_pos || g_ndx_risk <= 0.0 || g_ndx_risk_money <= 0.0)
      return 0.0;
   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const double r = (g_ndx_side > 0)
                    ? (bid - g_ndx_entry) / g_ndx_risk
                    : (g_ndx_entry - bid) / g_ndx_risk;
   return r * g_ndx_risk_money;
}

void NDX_ObjectsWipe()
{
   ObjectsDeleteAll(0, NDX_MRK);
   ObjectsDeleteAll(0, NDX_LVL);
}

void NDX_Mark(const string tag, const datetime t, const double px,
              const int arrow, const color clr)
{
   const string n = NDX_MRK + tag;
   if(ObjectFind(0, n) >= 0)
      ObjectDelete(0, n);
   ObjectCreate(0, n, OBJ_ARROW, 0, t, px);
   ObjectSetInteger(0, n, OBJPROP_ARROWCODE, arrow);
   ObjectSetInteger(0, n, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, n, OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
}

void NDX_HLine(const string tag, const double px, const color clr, const ENUM_LINE_STYLE st)
{
   const string n = NDX_LVL + tag;
   if(ObjectFind(0, n) < 0)
      ObjectCreate(0, n, OBJ_HLINE, 0, 0, px);
   ObjectSetDouble(0, n, OBJPROP_PRICE, px);
   ObjectSetInteger(0, n, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, n, OBJPROP_STYLE, st);
   ObjectSetInteger(0, n, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
}

void NDX_LevelsDraw()
{
   ObjectsDeleteAll(0, NDX_LVL);
   if(g_ndx_ready && g_ndx_have_rng)
   {
      NDX_HLine("HI", g_ndx_rng_hi, clrDodgerBlue, STYLE_SOLID);
      NDX_HLine("LO", g_ndx_rng_lo, clrDodgerBlue, STYLE_SOLID);
      if(g_ndx_rng_t0 > 0)
      {
         const string box = NDX_LVL + "BOX";
         datetime t2 = g_ndx_rng_t0 + 3600;
         if(ObjectFind(0, box) < 0)
            ObjectCreate(0, box, OBJ_RECTANGLE, 0, g_ndx_rng_t0, g_ndx_rng_hi, t2, g_ndx_rng_lo);
         ObjectSetInteger(0, box, OBJPROP_TIME, 0, g_ndx_rng_t0);
         ObjectSetInteger(0, box, OBJPROP_TIME, 1, t2);
         ObjectSetDouble(0, box, OBJPROP_PRICE, 0, g_ndx_rng_hi);
         ObjectSetDouble(0, box, OBJPROP_PRICE, 1, g_ndx_rng_lo);
         ObjectSetInteger(0, box, OBJPROP_COLOR, clrDodgerBlue);
         ObjectSetInteger(0, box, OBJPROP_STYLE, STYLE_DOT);
         ObjectSetInteger(0, box, OBJPROP_FILL, false);
         ObjectSetInteger(0, box, OBJPROP_BACK, true);
         ObjectSetInteger(0, box, OBJPROP_SELECTABLE, false);
      }
   }
   if(!g_ndx_pos)
      return;
   NDX_HLine("SL", g_ndx_sl, clrOrangeRed, STYLE_DASH);
   NDX_HLine("TP", g_ndx_tp, clrLimeGreen, STYLE_DASH);
}

void NDX_ResetSession()
{
   g_ndx_have_rng     = false;
   g_ndx_ready        = false;
   g_ndx_rng_hi       = 0.0;
   g_ndx_rng_lo       = 0.0;
   g_ndx_rng_t0       = 0;
   g_ndx_trades_today = 0;
   g_ndx_long_armed   = false;
   g_ndx_short_armed  = false;
   g_ndx_long_ext     = 0.0;
   g_ndx_short_ext    = 0.0;
   g_ndx_long_ref_t   = 0;
   g_ndx_short_ref_t  = 0;
   g_ndx_long_ref_h   = 0.0;
   g_ndx_long_ref_l   = 0.0;
   g_ndx_short_ref_h  = 0.0;
   g_ndx_short_ref_l  = 0.0;
}

void NDX_ShadowClose(const datetime t, const double px, const string reason)
{
   if(!g_ndx_pos)
      return;
   if(g_live && !g_ndx_replay)
   {
      if(g_ndx_ticket != 0 && !SHT_ExecCloseTicket(g_ndx_ticket))
         return;
      if(g_ndx_ticket == 0 && !SHT_ExecClose())
         return;
   }

   double r = 0.0;
   if(g_ndx_risk > 0.0)
      r = (g_ndx_side > 0) ? (px - g_ndx_entry) / g_ndx_risk
                           : (g_ndx_entry - px) / g_ndx_risk;
   if(!g_ndx_replay && g_ndx_risk_money > 0.0)
      SHT_RiskAddPnl(r * g_ndx_risk_money);
   g_ndx_closed_n++;
   NDX_Mark("X" + IntegerToString(g_ndx_id), t, px, 251,
            (r > 0.0 ? clrLimeGreen : clrOrangeRed));
   SHT_Info((g_ndx_replay ? "replay " : (g_live ? "LIVE " : "shadow "))
            + "close #" + IntegerToString(g_ndx_id)
            + " " + (g_ndx_side > 0 ? "long" : "short")
            + " " + reason
            + " exit=" + DoubleToString(px, _Digits)
            + " R=" + DoubleToString(r, 3)
            + " lots=" + DoubleToString(g_ndx_lots, 2)
            + (g_ndx_ticket != 0 ? (" ticket=" + IntegerToString((long)g_ndx_ticket)) : ""));
   g_ndx_pos        = false;
   g_ndx_side       = 0;
   g_ndx_entry      = 0.0;
   g_ndx_sl         = 0.0;
   g_ndx_tp         = 0.0;
   g_ndx_risk       = 0.0;
   g_ndx_lots       = 0.0;
   g_ndx_risk_money = 0.0;
   g_ndx_ticket     = 0;
   g_ndx_entry_t    = 0;
   if(!g_ndx_replay)
      NDX_LevelsDraw();
}

void NDX_Manage(const datetime t, const double high, const double low, const double open_px,
                const bool at_flat)
{
   if(!g_ndx_pos)
      return;
   if(t < g_ndx_entry_t)
      return;

   if(at_flat)
   {
      NDX_ShadowClose(t, open_px, "eod");
      return;
   }

   const bool news_win = (!g_ndx_replay && SHT_NewsBlocks(t));
   if(news_win && SHT_NewsYoung(g_ndx_entry_t, t))
   {
      SHT_Info("hold through news window — no shadow close");
      return;
   }

   // Same-bar SL and TP → stop wins, as in run_cisd.
   if(g_ndx_side > 0)
   {
      if(low <= g_ndx_sl)
         NDX_ShadowClose(t, g_ndx_sl, "stop");
      else if(high >= g_ndx_tp)
         NDX_ShadowClose(t, g_ndx_tp, "tp");
   }
   else
   {
      if(high >= g_ndx_sl)
         NDX_ShadowClose(t, g_ndx_sl, "stop");
      else if(low <= g_ndx_tp)
         NDX_ShadowClose(t, g_ndx_tp, "tp");
   }
}

bool NDX_ShadowOpen(const datetime fill_t, const double fill_px, const int side,
                    const double sl, const double tp)
{
   if(g_ndx_pos)
      return false;
   if(g_live && !g_ndx_replay && SHT_ExecHasPos())
      return false;

   const double tick = NDX_TickSize();
   const double risk = (side > 0) ? (fill_px - sl) : (sl - fill_px);
   const double rew  = (side > 0) ? (tp - fill_px) : (fill_px - tp);
   if(risk <= tick || rew <= 0.0)
   {
      if(!g_ndx_replay)
         SHT_Info("skip " + (side > 0 ? "long" : "short") + ": no room to opposite 8AM");
      return false;
   }

   double lots = 0.0;
   if(!SHT_RiskCanEnter(fill_t, g_ndx_replay, risk, NDX_NowFloating(), lots))
   {
      if(!g_ndx_replay)
         SHT_Info("skip " + (side > 0 ? "long" : "short") + ": " + g_risk_why);
      return false;
   }

   if(!g_ndx_replay && SHT_NewsBlocks(fill_t))
   {
      SHT_Info("skip entry: news window " + SHT_NewsLine());
      return false;
   }

   ulong ticket = 0;
   double entry_px = fill_px;
   double risk_use = risk;
   if(g_live && !g_ndx_replay)
   {
      ticket = SHT_ExecSend(side, lots, sl, tp, "NDX8#" + IntegerToString(g_ndx_trade_id + 1));
      if(ticket == 0)
      {
         SHT_Info("skip live open: " + g_risk_why);
         return false;
      }
      if(SHT_ExecSelectTicket(ticket))
         entry_px = PositionGetDouble(POSITION_PRICE_OPEN);
      const double filled_risk = (side > 0) ? (entry_px - sl) : (sl - entry_px);
      if(filled_risk > 0.0)
         risk_use = filled_risk;
   }

   g_ndx_trade_id++;
   g_ndx_pos        = true;
   g_ndx_side       = side;
   g_ndx_id         = g_ndx_trade_id;
   g_ndx_entry_t    = fill_t;
   g_ndx_entry      = entry_px;
   g_ndx_sl         = sl;
   g_ndx_tp         = tp;
   g_ndx_risk       = risk_use;
   g_ndx_lots       = lots;
   g_ndx_risk_money = AccountInfoDouble(ACCOUNT_EQUITY) * g_risk_pct;
   g_ndx_ticket     = ticket;
   g_ndx_trades_today++;
   if(side > 0)
   {
      g_ndx_long_armed = false;
      g_ndx_long_ref_t = 0;
   }
   else
   {
      g_ndx_short_armed = false;
      g_ndx_short_ref_t = 0;
   }

   NDX_Mark("E" + IntegerToString(g_ndx_id), fill_t, entry_px,
            (side > 0 ? 233 : 234),
            (side > 0 ? clrDodgerBlue : clrOrchid));
   if(!g_ndx_replay)
      NDX_LevelsDraw();
   SHT_Info((g_ndx_replay ? "replay " : (g_live ? "LIVE " : "shadow "))
            + "open #" + IntegerToString(g_ndx_id)
            + " " + (side > 0 ? "long" : "short")
            + " entry=" + DoubleToString(entry_px, _Digits)
            + " sl=" + DoubleToString(sl, _Digits)
            + " tp=" + DoubleToString(tp, _Digits)
            + " r=" + DoubleToString(risk_use, _Digits)
            + " lots=" + DoubleToString(lots, 2)
            + " day=" + IntegerToString(g_ndx_trades_today) + "/" + IntegerToString(g_ndx_max_tr)
            + (ticket != 0 ? (" ticket=" + IntegerToString((long)ticket)) : ""));
   return true;
}

void NDX_TryFill(const int cisd_shift, const int side, const double sl, const double tp)
{
   const int fill_shift = cisd_shift - 1;
   if(fill_shift < 0)
      return;
   const datetime fill_t = iTime(_Symbol, PERIOD_M1, fill_shift);
   if(fill_t <= 0)
      return;
   const int hhmm = NDX_NyHhmm(fill_t);
   if(hhmm < NDX_SIGNAL_START || hhmm >= NDX_SIGNAL_END)
   {
      if(!g_ndx_replay)
         SHT_Info("CISD fill missed 09:00-11:00 NY window");
      return;
   }
   const double fill_px = iOpen(_Symbol, PERIOD_M1, fill_shift);
   if(fill_px <= 0.0)
      return;
   NDX_ShadowOpen(fill_t, fill_px, side, sl, tp);
}

void NDX_ClearRef(const int side)
{
   if(side > 0)
   {
      g_ndx_long_ref_t = 0;
      g_ndx_long_ref_h = 0.0;
      g_ndx_long_ref_l = 0.0;
   }
   else
   {
      g_ndx_short_ref_t = 0;
      g_ndx_short_ref_h = 0.0;
      g_ndx_short_ref_l = 0.0;
   }
}

bool NDX_EngineOnBar(const int shift, const bool replay)
{
   g_ndx_replay = replay;

   const datetime t = iTime(_Symbol, PERIOD_M1, shift);
   const double o = iOpen(_Symbol, PERIOD_M1, shift);
   const double h = iHigh(_Symbol, PERIOD_M1, shift);
   const double l = iLow(_Symbol, PERIOD_M1, shift);
   const double c = iClose(_Symbol, PERIOD_M1, shift);
   if(t <= 0 || o <= 0.0 || c <= 0.0)
      return false;

   SHT_RiskOnBar(t);

   const int ny_day = NDX_NyDay(t);
   const int hhmm   = NDX_NyHhmm(t);
   if(g_ndx_day != 0 && ny_day != g_ndx_day)
   {
      if(g_ndx_pos)
      {
         const double prev_c = iClose(_Symbol, PERIOD_M1, shift + 1);
         NDX_ShadowClose(iTime(_Symbol, PERIOD_M1, shift + 1),
                         (prev_c > 0.0 ? prev_c : c), "eod");
      }
      NDX_ResetSession();
   }
   g_ndx_day = ny_day;

   const bool in_range = (hhmm >= NDX_RANGE_START && hhmm < NDX_RANGE_END);
   const bool in_sig   = (hhmm >= NDX_SIGNAL_START && hhmm < NDX_SIGNAL_END);
   const bool at_flat  = (hhmm >= NDX_FLAT_HHMM);

   if(in_range)
   {
      if(!g_ndx_have_rng)
      {
         g_ndx_rng_hi = h;
         g_ndx_rng_lo = l;
         g_ndx_rng_t0 = t;
         g_ndx_have_rng = true;
      }
      else
      {
         if(h > g_ndx_rng_hi)
            g_ndx_rng_hi = h;
         if(l < g_ndx_rng_lo)
            g_ndx_rng_lo = l;
      }
      g_ndx_ready = false;
   }
   else if(g_ndx_have_rng && g_ndx_rng_hi > g_ndx_rng_lo)
      g_ndx_ready = true;

   NDX_Manage(t, h, l, o, at_flat);

   if(g_ndx_pos || !g_ndx_ready || !in_sig || at_flat)
      return true;
   if(g_ndx_trades_today >= g_ndx_max_tr)
      return true;

   if(l < g_ndx_rng_lo)
   {
      if(!g_ndx_long_armed)
      {
         g_ndx_long_armed = true;
         g_ndx_long_ext   = l;
         g_ndx_long_ref_t = t;
         g_ndx_long_ref_h = h;
         g_ndx_long_ref_l = l;
      }
      else if(l < g_ndx_long_ext)
      {
         g_ndx_long_ext   = l;
         g_ndx_long_ref_t = t;
         g_ndx_long_ref_h = h;
         g_ndx_long_ref_l = l;
      }
   }
   if(h > g_ndx_rng_hi)
   {
      if(!g_ndx_short_armed)
      {
         g_ndx_short_armed = true;
         g_ndx_short_ext   = h;
         g_ndx_short_ref_t = t;
         g_ndx_short_ref_h = h;
         g_ndx_short_ref_l = l;
      }
      else if(h > g_ndx_short_ext)
      {
         g_ndx_short_ext   = h;
         g_ndx_short_ref_t = t;
         g_ndx_short_ref_h = h;
         g_ndx_short_ref_l = l;
      }
   }

   const bool cisd_long =
      g_ndx_long_armed && g_ndx_long_ref_t > 0 && t != g_ndx_long_ref_t
      && c > g_ndx_long_ref_h && c > g_ndx_rng_lo;
   const bool cisd_short =
      g_ndx_short_armed && g_ndx_short_ref_t > 0 && t != g_ndx_short_ref_t
      && c < g_ndx_short_ref_l && c < g_ndx_rng_hi;

   if(cisd_long && cisd_short)
   {
      NDX_ClearRef(+1);
      NDX_ClearRef(-1);
      if(!replay)
         SHT_Info("skip CISD: both sides on the same bar");
      return true;
   }

   const double tick = NDX_TickSize();
   if(cisd_long)
   {
      const double sl = g_ndx_long_ext - tick;
      const double tp = g_ndx_rng_hi;
      NDX_ClearRef(+1);
      NDX_TryFill(shift, +1, sl, tp);
   }
   else if(cisd_short)
   {
      const double sl = g_ndx_short_ext + tick;
      const double tp = g_ndx_rng_lo;
      NDX_ClearRef(-1);
      NDX_TryFill(shift, -1, sl, tp);
   }
   return true;
}

int NDX_EngineReplay()
{
   NDX_ObjectsWipe();
   NDX_ResetSession();
   g_ndx_pos      = false;
   g_ndx_side     = 0;
   g_ndx_ticket   = 0;
   g_ndx_day      = 0;
   g_ndx_trade_id = 0;
   g_ndx_closed_n = 0;

   const int total = Bars(_Symbol, PERIOD_M1);
   int shift = total - 2;
   if(shift < 1 || total < NDX_WARMUP)
   {
      SHT_Warn("replay skipped: bars=" + IntegerToString(total)
               + " need>=" + IntegerToString(NDX_WARMUP));
      return 0;
   }

   SHT_Info("replay start bars=" + IntegerToString(shift));
   int ok = 0;
   for(; shift >= 1; shift--)
   {
      if(NDX_EngineOnBar(shift, true))
         ok++;
   }
   g_ndx_replay = false;
   SHT_RiskResetDay(TimeCurrent());
   NDX_LevelsDraw();
   ChartRedraw(0);
   SHT_Info("replay bars=" + IntegerToString(ok)
            + " closed=" + IntegerToString(g_ndx_closed_n)
            + " open=" + (g_ndx_pos ? "yes" : "no")
            + " today=" + IntegerToString(g_ndx_trades_today));
   return ok;
}

void NDX_PaperDrop(const string why)
{
   if(!g_ndx_pos)
      return;
   SHT_Info("drop paper position: " + why);
   if(g_ndx_entry_t > 0 && NDX_NyDay(g_ndx_entry_t) == NDX_NyDay(TimeCurrent())
      && g_ndx_trades_today > 0)
      g_ndx_trades_today--;
   g_ndx_pos        = false;
   g_ndx_side       = 0;
   g_ndx_lots       = 0.0;
   g_ndx_ticket     = 0;
   g_ndx_risk_money = 0.0;
   NDX_LevelsDraw();
}

void NDX_LiveAfterReplay()
{
   if(!g_live)
      return;
   if(SHT_ExecHasPos())
   {
      g_ndx_pos        = true;
      g_ndx_side       = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
      g_ndx_entry      = PositionGetDouble(POSITION_PRICE_OPEN);
      g_ndx_sl         = PositionGetDouble(POSITION_SL);
      g_ndx_tp         = PositionGetDouble(POSITION_TP);
      g_ndx_risk       = MathAbs(g_ndx_entry - g_ndx_sl);
      if(g_ndx_risk <= 0.0)
         g_ndx_risk = NDX_TickSize();
      g_ndx_lots       = PositionGetDouble(POSITION_VOLUME);
      g_ndx_ticket     = (ulong)PositionGetInteger(POSITION_TICKET);
      g_ndx_entry_t    = (datetime)PositionGetInteger(POSITION_TIME);
      g_ndx_risk_money = AccountInfoDouble(ACCOUNT_EQUITY) * g_risk_pct;
      g_ndx_trade_id++;
      g_ndx_id = g_ndx_trade_id;
      SHT_Warn("adopted LIVE ticket=" + IntegerToString((long)g_ndx_ticket)
               + " " + (g_ndx_side > 0 ? "long" : "short")
               + " lots=" + DoubleToString(g_ndx_lots, 2));
      NDX_LevelsDraw();
      return;
   }
   if(g_ndx_pos)
      NDX_PaperDrop("replay paper was not sent to the broker");
}

void NDX_LiveTick()
{
   if(!g_live || g_ndx_replay || !g_ndx_pos)
      return;
   if(g_ndx_ticket != 0 && SHT_ExecSelectTicket(g_ndx_ticket))
      return;
   if(g_ndx_ticket == 0 && SHT_ExecHasPos())
      return;
   const double px = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   NDX_ShadowClose(TimeCurrent(), px, "broker_exit");
}

void NDX_NewsTickFlatten()
{
   if(g_ndx_replay || !g_ndx_pos)
      return;
   if(!SHT_NewsShouldFlatten(g_ndx_entry_t, TimeCurrent()))
      return;
   NDX_ShadowClose(TimeCurrent(), SymbolInfoDouble(_Symbol, SYMBOL_BID), "news_flatten");
}

void NDX_EodTickFlatten()
{
   if(g_ndx_replay || !g_ndx_pos)
      return;
   if(NDX_NyHhmm(TimeCurrent()) < NDX_FLAT_HHMM)
      return;
   NDX_ShadowClose(TimeCurrent(), SymbolInfoDouble(_Symbol, SYMBOL_BID), "eod");
}

bool NDX_Ready()
{
   return (Bars(_Symbol, PERIOD_M1) >= NDX_WARMUP);
}

string NDX_StateLine()
{
   string rng = "8AM none";
   if(g_ndx_have_rng)
      rng = "8AM " + DoubleToString(g_ndx_rng_lo, _Digits)
            + ".." + DoubleToString(g_ndx_rng_hi, _Digits)
            + (g_ndx_ready ? " ready" : " building");
   string arm = "arm";
   if(g_ndx_long_armed)
      arm += " L@" + DoubleToString(g_ndx_long_ext, _Digits);
   if(g_ndx_short_armed)
      arm += " S@" + DoubleToString(g_ndx_short_ext, _Digits);
   if(!g_ndx_long_armed && !g_ndx_short_armed)
      arm += " none";
   return rng + "  " + arm
          + "  today=" + IntegerToString(g_ndx_trades_today) + "/" + IntegerToString(g_ndx_max_tr);
}

string NDX_PosLine()
{
   if(!g_ndx_pos)
      return "flat  closed=" + IntegerToString(g_ndx_closed_n);
   return (g_ndx_side > 0 ? "LONG" : "SHORT")
          + " #" + IntegerToString(g_ndx_id)
          + " @" + DoubleToString(g_ndx_entry, _Digits)
          + " sl=" + DoubleToString(g_ndx_sl, _Digits)
          + " tp=" + DoubleToString(g_ndx_tp, _Digits)
          + " lots=" + DoubleToString(g_ndx_lots, 2)
          + (g_ndx_ticket != 0 ? (" t=" + IntegerToString((long)g_ndx_ticket)) : "")
          + "  closed=" + IntegerToString(g_ndx_closed_n);
}

string NDX_EngineComment()
{
   MqlDateTime ny;
   NDX_NyStamp(TimeCurrent(), ny);
   const string ny_clk = StringFormat("NY %02d:%02d", ny.hour, ny.min);
   const int hhmm = ny.hour * 100 + ny.min;
   string win = "idle";
   if(hhmm >= NDX_RANGE_START && hhmm < NDX_RANGE_END)
      win = "RANGE 08:00-09:00";
   else if(hhmm >= NDX_SIGNAL_START && hhmm < NDX_SIGNAL_END)
      win = "SIGNAL 09:00-11:00";
   else if(hhmm >= NDX_FLAT_HHMM)
      win = "FLAT >=16:00";
   return ny_clk + "  " + win
          + "\n" + NDX_StateLine()
          + "\n" + NDX_PosLine()
          + "\n" + SHT_RiskLine(NDX_NowFloating())
          + "\n" + SHT_NewsLine()
          + "\n" + (g_live ? "LIVE orders  halt local (not shared with Vegas/ASRC)"
                           : "shadow only — no OrderSend  halt local (not shared with Vegas/ASRC)");
}

#endif
