#ifndef A2_ENGINE_MQH
#define A2_ENGINE_MQH

#include "A2_Config.mqh"
#include "A2_Log.mqh"
#include "A2_Time.mqh"
#include "A2_News.mqh"
#include "A2_Risk.mqh"
#include "A2_Exec.mqh"
#include "A2_Channel.mqh"

// The engine.
//
// Entry rules are v1's, unchanged. What is different:
//
//   * a signal on a closed bar is filled at the price of the bar that follows it,
//     which is what a market order sent on a new bar actually gets. Replay uses
//     that next bar's open, live uses the current quote, and both then recompute
//     risk and target from the price they really got;
//   * both the stop and the target inside one bar resolve to the stop, because the
//     path inside a bar is unknown;
//   * every entry counts against the session cap, so a session cannot exceed the
//     intended two legs;
//   * the session reset and the end-of-day flatten fire on a crossing of their New
//     York minute, so a missing bar cannot skip them;
//   * closed trades are appended to a CSV, so live results can be diffed against
//     the backtest instead of being eyeballed in the log.

struct A2Leg
{
   bool     on;
   int      side;
   int      which;
   int      id;
   datetime signal_bar;
   datetime fill_bar;
   double   entry;
   double   sl;
   double   tp;
   double   risk;
   double   lots;
   double   risk_money;
   ulong    ticket;
};

A2Leg    g_a2_legs[A2_MAX_LEGS];
int      g_a2_trade_id    = 0;
int      g_a2_closed_n    = 0;
int      g_a2_sess_n      = 0;
datetime g_a2_last_entry  = 0;
datetime g_a2_prev_bar    = 0;
int      g_a2_prev_ny_min = -1;
datetime g_a2_eod_day     = 0;
datetime g_a2_done_bar    = 0;
bool     g_a2_replay      = false;
string   g_a2_last_pat    = "";
double   g_a2_sum_r       = 0.0;
string   g_a2_csv_name    = "AsrcBtcV2Opus_trades.csv";
double   g_a2_max_slip_pct = 0.05;   // percent of price; 0 disables the guard

int A2_OpenCount()
{
   int n = 0;
   for(int i = 0; i < A2_MAX_LEGS; i++)
      if(g_a2_legs[i].on)
         n++;
   return n;
}

int A2_SameSideCount(const int side)
{
   int n = 0;
   for(int i = 0; i < A2_MAX_LEGS; i++)
      if(g_a2_legs[i].on && g_a2_legs[i].side == side)
         n++;
   return n;
}

double A2_OpenRiskMoney()
{
   double m = 0.0;
   for(int i = 0; i < A2_MAX_LEGS; i++)
      if(g_a2_legs[i].on)
         m += g_a2_legs[i].risk_money;
   return m;
}

double A2_Floating(const double px)
{
   double f = 0.0;
   for(int i = 0; i < A2_MAX_LEGS; i++)
   {
      if(!g_a2_legs[i].on || g_a2_legs[i].risk <= 0.0 || g_a2_legs[i].risk_money <= 0.0)
         continue;
      const double r = (g_a2_legs[i].side > 0)
                       ? (px - g_a2_legs[i].entry) / g_a2_legs[i].risk
                       : (g_a2_legs[i].entry - px) / g_a2_legs[i].risk;
      f += r * g_a2_legs[i].risk_money;
   }
   return f;
}

double A2_FloatingNow()
{
   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   if(bid <= 0.0)
      return 0.0;
   return A2_Floating(bid);
}

void A2_KnownTickets(ulong &out[], int &n)
{
   ArrayResize(out, A2_MAX_LEGS);
   n = 0;
   for(int i = 0; i < A2_MAX_LEGS; i++)
      if(g_a2_legs[i].on && g_a2_legs[i].ticket != 0)
         out[n++] = g_a2_legs[i].ticket;
}

void A2_LegsClear()
{
   for(int i = 0; i < A2_MAX_LEGS; i++)
      ZeroMemory(g_a2_legs[i]);
}

void A2_ObjectsWipe()
{
   ObjectsDeleteAll(0, A2_MRK);
   ObjectsDeleteAll(0, A2_LVL);
}

void A2_Mark(const string tag, const datetime t, const double px, const int arrow,
             const color clr)
{
   const string n = A2_MRK + tag;
   if(ObjectFind(0, n) >= 0)
      ObjectDelete(0, n);
   ObjectCreate(0, n, OBJ_ARROW, 0, t, px);
   ObjectSetInteger(0, n, OBJPROP_ARROWCODE, arrow);
   ObjectSetInteger(0, n, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, n, OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
}

void A2_HLine(const string tag, const double px, const color clr, const ENUM_LINE_STYLE st)
{
   const string n = A2_LVL + tag;
   if(ObjectFind(0, n) < 0)
      ObjectCreate(0, n, OBJ_HLINE, 0, 0, px);
   ObjectSetDouble(0, n, OBJPROP_PRICE, px);
   ObjectSetInteger(0, n, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, n, OBJPROP_STYLE, st);
   ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
}

void A2_LevelsDraw()
{
   ObjectsDeleteAll(0, A2_LVL);
   for(int i = 0; i < A2_MAX_LEGS; i++)
   {
      if(!g_a2_legs[i].on)
         continue;
      const string id = IntegerToString(g_a2_legs[i].id);
      A2_HLine("SL" + id, g_a2_legs[i].sl, clrOrangeRed, STYLE_DASH);
      A2_HLine("TP" + id, g_a2_legs[i].tp, clrLimeGreen, STYLE_DASH);
   }
}

void A2_CsvAppend(const A2Leg &leg, const datetime exit_t, const double exit_px,
                  const string reason, const double r)
{
   const bool fresh = !FileIsExist(g_a2_csv_name, FILE_COMMON);
   const int h = FileOpen(g_a2_csv_name,
                          FILE_READ | FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_COMMON
                          | FILE_SHARE_READ, ',');
   if(h == INVALID_HANDLE)
      return;
   FileSeek(h, 0, SEEK_END);
   if(fresh)
      FileWrite(h, "mode", "id", "side", "which", "signal_bar", "fill_bar", "exit_time",
                "entry", "exit", "stop", "tp", "risk", "lots", "risk_money", "reason", "r");
   FileWrite(h,
             (g_a2_replay ? "replay" : (g_a2_live ? "live" : "shadow")),
             IntegerToString(leg.id),
             (leg.side > 0 ? "long" : "short"),
             IntegerToString(leg.which),
             TimeToString(leg.signal_bar, TIME_DATE | TIME_MINUTES),
             TimeToString(leg.fill_bar, TIME_DATE | TIME_MINUTES),
             TimeToString(exit_t, TIME_DATE | TIME_MINUTES),
             DoubleToString(leg.entry, _Digits),
             DoubleToString(exit_px, _Digits),
             DoubleToString(leg.sl, _Digits),
             DoubleToString(leg.tp, _Digits),
             DoubleToString(leg.risk, _Digits),
             DoubleToString(leg.lots, 2),
             DoubleToString(leg.risk_money, 2),
             reason,
             DoubleToString(r, 4));
   FileClose(h);
}

void A2_CloseLeg(const int idx, const datetime t, const double px, const string reason)
{
   A2Leg leg = g_a2_legs[idx];
   if(!leg.on)
      return;
   if(g_a2_live && !g_a2_replay && leg.ticket != 0)
   {
      if(!A2_ExecCloseTicket(leg.ticket))
         return;   // keep the leg so the next tick tries again
   }

   const double r = (leg.side > 0) ? (px - leg.entry) / leg.risk
                                   : (leg.entry - px) / leg.risk;
   if(leg.risk_money > 0.0)
      A2_RiskAddPnl(r * leg.risk_money);
   g_a2_closed_n++;
   g_a2_sum_r += r;

   A2_Mark("X" + IntegerToString(leg.id), t, px, 251, (r > 0.0 ? clrLimeGreen : clrOrangeRed));
   A2_CsvAppend(leg, t, px, reason, r);
   A2_Info((g_a2_replay ? "replay " : (g_a2_live ? "LIVE " : "shadow "))
           + "close #" + IntegerToString(leg.id)
           + " " + (leg.side > 0 ? "long" : "short")
           + " " + reason
           + " exit=" + DoubleToString(px, _Digits)
           + " R=" + DoubleToString(r, 3)
           + " which=" + IntegerToString(leg.which)
           + " lots=" + DoubleToString(leg.lots, 2)
           + (leg.ticket != 0 ? (" ticket=" + IntegerToString((long)leg.ticket)) : ""));

   ZeroMemory(g_a2_legs[idx]);
   if(!g_a2_replay)
      A2_LevelsDraw();
}

// Both levels inside one bar resolve to the stop: the intrabar path is unknown and
// resolving it in the target's favour is how a backtest flatters itself.
void A2_Manage(const A2Snap &s)
{
   const bool news_win = (!g_a2_replay && A2_NewsBlocks(s.bar_time));
   bool held = false;
   for(int i = 0; i < A2_MAX_LEGS; i++)
   {
      if(!g_a2_legs[i].on)
         continue;
      if(s.bar_time < g_a2_legs[i].fill_bar)
         continue;
      if(news_win && A2_NewsYoung(g_a2_legs[i].fill_bar, s.bar_time))
      {
         held = true;
         continue;
      }
      const int side = g_a2_legs[i].side;
      const bool tp_hit = (side > 0) ? (s.high >= g_a2_legs[i].tp) : (s.low <= g_a2_legs[i].tp);
      const bool sl_hit = (side > 0) ? (s.low <= g_a2_legs[i].sl) : (s.high >= g_a2_legs[i].sl);
      // A bar that opened past a level could not have been filled at the level.
      if(sl_hit)
      {
         const double px = (side > 0) ? MathMin(g_a2_legs[i].sl, s.open)
                                      : MathMax(g_a2_legs[i].sl, s.open);
         A2_CloseLeg(i, s.bar_time, px, "stop");
      }
      else if(tp_hit)
      {
         const double px = (side > 0) ? MathMax(g_a2_legs[i].tp, s.open)
                                      : MathMin(g_a2_legs[i].tp, s.open);
         A2_CloseLeg(i, s.bar_time, px, "tp");
      }
   }
   if(held && A2_LogOnce(2, "news_hold", 900))
      A2_Info("holding through the news window — no close inside the forbidden band");
}

void A2_EodFlatten(const A2Snap &s)
{
   const bool news_win = (!g_a2_replay && A2_NewsBlocks(s.bar_time));
   for(int i = 0; i < A2_MAX_LEGS; i++)
   {
      if(!g_a2_legs[i].on)
         continue;
      if(s.bar_time < g_a2_legs[i].fill_bar)
         continue;
      if(news_win && A2_NewsYoung(g_a2_legs[i].fill_bar, s.bar_time))
         continue;
      A2_CloseLeg(i, s.bar_time, s.close, "eod");
   }
}

void A2_NewsTickFlatten()
{
   if(g_a2_replay || A2_OpenCount() == 0)
      return;
   datetime oldest = 0;
   for(int i = 0; i < A2_MAX_LEGS; i++)
   {
      if(!g_a2_legs[i].on)
         continue;
      if(!A2_NewsYoung(g_a2_legs[i].fill_bar, TimeCurrent()))
         continue;
      if(oldest == 0 || g_a2_legs[i].fill_bar < oldest)
         oldest = g_a2_legs[i].fill_bar;
   }
   if(oldest <= 0 || !A2_NewsShouldFlatten(oldest, TimeCurrent()))
      return;

   const datetime now = TimeCurrent();
   for(int i = 0; i < A2_MAX_LEGS; i++)
   {
      if(!g_a2_legs[i].on)
         continue;
      if(!A2_NewsYoung(g_a2_legs[i].fill_bar, now))
         continue;
      const double px = (g_a2_legs[i].side > 0 ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                                               : SymbolInfoDouble(_Symbol, SYMBOL_ASK));
      A2_CloseLeg(i, now, px, "news_flatten");
   }
}

bool A2_BarsGapOk(const int shift)
{
   if(g_a2_last_entry <= 0)
      return true;
   const int last_sh = iBarShift(_Symbol, A2_ALLOWED_TF, g_a2_last_entry, true);
   if(last_sh < 0)
      return true;
   return ((last_sh - shift) > A2_BARS_GAP);
}

void A2_Patterns(const int shift, const double px, const double tick,
                 bool &bull_eng, bool &bear_eng, bool &pin_bull, bool &pin_bear)
{
   bull_eng = false;
   bear_eng = false;
   pin_bull = false;
   pin_bear = false;
   g_a2_last_pat = "";

   const int bars = Bars(_Symbol, A2_ALLOWED_TF);
   if(shift + 1 >= bars)
      return;

   const double o  = iOpen(_Symbol, A2_ALLOWED_TF, shift);
   const double cl = iClose(_Symbol, A2_ALLOWED_TF, shift);
   const double o1 = iOpen(_Symbol, A2_ALLOWED_TF, shift + 1);
   const double h1 = iHigh(_Symbol, A2_ALLOWED_TF, shift + 1);
   const double l1 = iLow(_Symbol, A2_ALLOWED_TF, shift + 1);
   const double c1 = iClose(_Symbol, A2_ALLOWED_TF, shift + 1);
   if(o <= 0.0 || cl <= 0.0 || o1 <= 0.0)
      return;

   const double eng_min    = px * (A2_ENG_MIN / 100.0);
   const double eng_max    = px * (A2_ENG_MAX / 100.0);
   const double prev_allow = eng_min * A2_PREV_RAN;
   const double gap_allow  = tick * A2_GAP_TICKS;
   const double body       = MathAbs(cl - o);

   if(body >= eng_min && body <= eng_max)
   {
      const bool prev_bear = (c1 < o1);
      const bool prev_bull = (c1 > o1);
      const bool small_bull = prev_bull && ((c1 - o1) <= prev_allow);
      const bool small_bear = prev_bear && ((o1 - c1) <= prev_allow);
      if((prev_bear || small_bull) && cl > o)
      {
         const double lvl = prev_bear ? o1 : h1;
         if(o <= c1 + gap_allow && cl > lvl)
            bull_eng = true;
      }
      if((prev_bull || small_bear) && cl < o)
      {
         const double lvl = prev_bull ? o1 : l1;
         if(o >= c1 - gap_allow && cl < lvl)
            bear_eng = true;
      }
   }

   if(shift + 1 + A2_SWEEP_LB < bars)
   {
      const double rng1 = h1 - l1;
      const double body1 = MathAbs(c1 - o1);
      if(rng1 >= eng_min * A2_PIN_PCT && rng1 > 0.0 && body1 > 0.0
         && (body1 / rng1) <= A2_PIN_BODY_MAX)
      {
         const double up_w = h1 - MathMax(o1, c1);
         const double dn_w = MathMin(o1, c1) - l1;
         const double long_w = MathMax(up_w, dn_w);
         if((long_w / rng1) >= A2_PIN_WICK_MIN && (long_w / body1) >= A2_PIN_WICK_RATIO)
         {
            double last_bot = iLow(_Symbol, A2_ALLOWED_TF, shift + 2);
            double last_top = iHigh(_Symbol, A2_ALLOWED_TF, shift + 2);
            for(int k = 3; k < 2 + A2_SWEEP_LB; k++)
            {
               const double lk = iLow(_Symbol, A2_ALLOWED_TF, shift + k);
               const double hk = iHigh(_Symbol, A2_ALLOWED_TF, shift + k);
               if(lk < last_bot)
                  last_bot = lk;
               if(hk > last_top)
                  last_top = hk;
            }
            const bool body_ok = (body >= eng_min * A2_PIN_PCT && body <= eng_max);
            if(dn_w > up_w && last_bot > l1 && cl > o && cl > h1 && body_ok)
               pin_bull = true;
            if(up_w >= dn_w && last_top < h1 && cl < o && cl < l1 && body_ok)
               pin_bear = true;
         }
      }
   }

   if(pin_bull)
      g_a2_last_pat = "pin_bull";
   else if(pin_bear)
      g_a2_last_pat = "pin_bear";
   else if(bull_eng)
      g_a2_last_pat = "bull_eng";
   else if(bear_eng)
      g_a2_last_pat = "bear_eng";
}

// Fill price of a market order sent when this bar closed: the next bar's open in
// replay, the live quote otherwise.
double A2_FillPrice(const int shift, const int side)
{
   if(g_a2_replay)
   {
      const double px = iOpen(_Symbol, A2_ALLOWED_TF, shift - 1);
      return (px > 0.0 ? px : 0.0);
   }
   return (side > 0 ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                    : SymbolInfoDouble(_Symbol, SYMBOL_BID));
}

datetime A2_FillBar(const int shift)
{
   const datetime t = iTime(_Symbol, A2_ALLOWED_TF, shift - 1);
   return (t > 0 ? t : iTime(_Symbol, A2_ALLOWED_TF, shift));
}

void A2_Open(const A2Snap &s, const int shift, const int side, const int which,
             const double tick)
{
   int slot = -1;
   for(int i = 0; i < A2_MAX_LEGS; i++)
   {
      if(!g_a2_legs[i].on)
      {
         slot = i;
         break;
      }
   }
   if(slot < 0)
      return;

   const double sl_buf = tick * A2_SL_BUF_TICKS;
   const double sl = (side > 0) ? (s.ch_lo - sl_buf) : (s.ch_up + sl_buf);

   const double fill = A2_FillPrice(shift, side);
   if(fill <= 0.0)
      return;
   const double risk = (side > 0) ? (fill - sl) : (sl - fill);
   if(risk <= 0.0)
   {
      A2_Info("skip " + (side > 0 ? "long" : "short")
              + ": price already through the stop at fill time");
      return;
   }
   const double tp = (side > 0) ? (fill + A2_RR * risk) : (fill - A2_RR * risk);

   double lots = 0.0, risk_money = 0.0;
   if(!A2_RiskCanEnter(s.bar_time, side, fill, sl, A2_OpenRiskMoney(),
                       A2_Floating(g_a2_replay ? s.close : SymbolInfoDouble(_Symbol, SYMBOL_BID)),
                       lots, risk_money))
   {
      if(!g_a2_replay && A2_LogOnce(3, g_a2_why, 300))
         A2_Info("skip " + (side > 0 ? "long" : "short") + ": " + g_a2_why);
      return;
   }

   if(g_a2_live && !g_a2_replay)
   {
      if(which == 2 && !A2_ExecIsHedge())
      {
         A2_Info("skip the second live leg: this account is netting, not hedging");
         return;
      }
      if(A2_ExecCount() >= A2_MAX_LEGS)
      {
         A2_Warn("skip live open: the broker already holds " + IntegerToString(A2_MAX_LEGS)
                 + " of our positions");
         return;
      }
   }

   g_a2_trade_id++;
   ulong ticket = 0;
   double entry = fill;
   if(g_a2_live && !g_a2_replay)
   {
      ulong known[];
      int known_n = 0;
      A2_KnownTickets(known, known_n);
      double filled = 0.0;
      const double max_slip = fill * g_a2_max_slip_pct / 100.0;
      ticket = A2_ExecSend(side, lots, sl, tp, "A2#" + IntegerToString(g_a2_trade_id),
                           fill, max_slip, known, known_n, filled);
      if(ticket == 0)
      {
         A2_Warn("live open #" + IntegerToString(g_a2_trade_id) + " not taken: " + g_a2_why);
         g_a2_trade_id--;
         return;
      }
      entry = (filled > 0.0 ? filled : fill);
   }

   const double real_risk = (side > 0) ? (entry - sl) : (sl - entry);
   if(real_risk <= 0.0)
   {
      A2_Error("fill landed on the wrong side of the stop — closing #"
               + IntegerToString(g_a2_trade_id));
      if(ticket != 0)
         A2_ExecCloseTicket(ticket);
      g_a2_trade_id--;
      return;
   }

   g_a2_legs[slot].on         = true;
   g_a2_legs[slot].side       = side;
   g_a2_legs[slot].which      = which;
   g_a2_legs[slot].id         = g_a2_trade_id;
   g_a2_legs[slot].signal_bar = s.bar_time;
   g_a2_legs[slot].fill_bar   = A2_FillBar(shift);
   g_a2_legs[slot].entry      = entry;
   g_a2_legs[slot].sl         = sl;
   g_a2_legs[slot].tp         = (side > 0) ? (entry + A2_RR * real_risk)
                                           : (entry - A2_RR * real_risk);
   g_a2_legs[slot].risk       = real_risk;
   g_a2_legs[slot].lots       = lots;
   g_a2_legs[slot].risk_money = risk_money;
   g_a2_legs[slot].ticket     = ticket;
   // The minimum gap between entries counts from the bar we filled on, not the
   // bar that produced the signal, so it matches the reference backtest.
   g_a2_last_entry            = g_a2_legs[slot].fill_bar;
   g_a2_sess_n++;   // every entry counts, first legs included

   A2_Mark("E" + IntegerToString(g_a2_trade_id), g_a2_legs[slot].fill_bar, entry,
           (side > 0 ? 233 : 234), (side > 0 ? clrDodgerBlue : clrOrchid));
   if(!g_a2_replay)
      A2_LevelsDraw();
   A2_Info((g_a2_replay ? "replay " : (g_a2_live ? "LIVE " : "shadow "))
           + "open #" + IntegerToString(g_a2_trade_id)
           + " " + (side > 0 ? "long" : "short")
           + " which=" + IntegerToString(which)
           + " " + g_a2_last_pat
           + " signal=" + TimeToString(s.bar_time, TIME_MINUTES)
           + " entry=" + DoubleToString(entry, _Digits)
           + " sl=" + DoubleToString(sl, _Digits)
           + " tp=" + DoubleToString(g_a2_legs[slot].tp, _Digits)
           + " r=" + DoubleToString(real_risk, _Digits)
           + " lots=" + DoubleToString(lots, 2)
           + " risk$=" + DoubleToString(risk_money, 2)
           + " sess=" + IntegerToString(g_a2_sess_n) + "/" + IntegerToString(A2_MAX_ENTRIES_SESS)
           + (ticket != 0 ? (" ticket=" + IntegerToString((long)ticket)) : ""));
}

bool A2_EngineOnBar(const int shift, const bool replay)
{
   g_a2_replay = replay;

   A2Snap s;
   if(!A2_Snapshot(shift, s))
      return false;
   if(s.bar_time == g_a2_done_bar)
      return true;   // already processed; never act on one bar twice
   g_a2_done_bar = s.bar_time;

   A2_RiskOnBar(s.bar_time);

   // session resets and the end of day fire on crossings, so a gap in the feed
   // cannot silently skip them
   const int prev_min = g_a2_prev_ny_min;
   const bool have_prev = (g_a2_prev_bar > 0 && prev_min >= 0);
   g_a2_prev_bar    = s.bar_time;
   g_a2_prev_ny_min = s.ny_min;

   if(have_prev)
   {
      if(A2_CrossedNyMinute(prev_min, s.ny_min, 9 * 60 + 30)
         || A2_CrossedNyMinute(prev_min, s.ny_min, 20 * 60)
         || A2_CrossedNyMinute(prev_min, s.ny_min, 3 * 60 + 30))
         g_a2_sess_n = 0;
   }

   A2_Manage(s);

   const datetime day = A2_DayStamp(s.bar_time);
   if(have_prev && A2_OpenCount() > 0 && g_a2_eod_day != day
      && A2_CrossedNyMinute(prev_min, s.ny_min, A2_EOD_MIN))
   {
      A2_EodFlatten(s);
      g_a2_eod_day = day;
      return true;
   }

   A2_BiasAdvance(shift, s);

   if(s.ny_min >= A2_NT_START_MIN && s.ny_min <= A2_NT_END_MIN)
      return true;
   if(s.ny_wday == 5)   // no Friday entries; the position would face the weekend
      return true;
   if(g_a2_sess_n >= A2_MAX_ENTRIES_SESS)
      return true;
   if(!A2_BarsGapOk(shift))
      return true;
   if(A2_OpenCount() >= A2_MAX_LEGS)
      return true;
   if(s.low_vol)
      return true;

   const double tick = A2_TickSize();
   bool bull_eng, bear_eng, pin_bull, pin_bear;
   A2_Patterns(shift, s.close, tick, bull_eng, bear_eng, pin_bull, pin_bear);

   const bool long_ok = g_a2_bias_long && s.in_channel && (bull_eng || pin_bull)
                        && s.rsi_buy && (s.ema_buy || pin_bull) && s.sqz_long && s.ht_buy;
   const bool short_ok = g_a2_bias_short && s.in_channel && (bear_eng || pin_bear)
                         && s.rsi_sell && (s.ema_sell || pin_bear) && s.sqz_short && s.ht_sell;
   if(!long_ok && !short_ok)
      return true;

   if(!replay && A2_NewsBlocks(s.bar_time))
   {
      A2_Info("skip entry: " + A2_NewsLine());
      return true;
   }

   const int n = A2_OpenCount();
   if(long_ok && n == 0)
      A2_Open(s, shift, +1, 1, tick);
   else if(long_ok && n == 1 && A2_SameSideCount(+1) == 1)
      A2_Open(s, shift, +1, 2, tick);
   else if(short_ok && n == 0)
      A2_Open(s, shift, -1, 1, tick);
   else if(short_ok && n == 1 && A2_SameSideCount(-1) == 1)
      A2_Open(s, shift, -1, 2, tick);

   return true;
}

int A2_EngineReplay()
{
   A2_ObjectsWipe();
   A2_LegsClear();
   A2_BiasReset();
   g_a2_trade_id    = 0;
   g_a2_closed_n    = 0;
   g_a2_sess_n      = 0;
   g_a2_sum_r       = 0.0;
   g_a2_last_entry  = 0;
   g_a2_prev_bar    = 0;
   g_a2_prev_ny_min = -1;
   g_a2_eod_day     = 0;
   g_a2_done_bar    = 0;

   const int total = Bars(_Symbol, A2_ALLOWED_TF);
   int shift = total - A2_WARMUP - 1;
   if(shift < 2)
   {
      A2_Warn("replay skipped: only " + IntegerToString(total) + " M5 bars");
      return 0;
   }

   A2_Info("replay start over " + IntegerToString(shift) + " bars");
   int ok = 0;
   for(; shift >= 1; shift--)
      if(A2_EngineOnBar(shift, true))
         ok++;

   g_a2_replay = false;
   A2_RiskResetDay(TimeCurrent());
   A2_LevelsDraw();
   ChartRedraw(0);
   A2_Info("replay bars=" + IntegerToString(ok)
           + " closed=" + IntegerToString(g_a2_closed_n)
           + " sumR=" + DoubleToString(g_a2_sum_r, 2)
           + " open=" + IntegerToString(A2_OpenCount()));
   return ok;
}

// Replay legs are paper. Drop them and adopt whatever the broker really holds.
void A2_AdoptLive()
{
   const int paper = A2_OpenCount();
   if(paper > 0)
   {
      A2_Info("dropping " + IntegerToString(paper) + " replay paper leg(s)");
      A2_LegsClear();
   }
   g_a2_sess_n     = 0;
   g_a2_last_entry = 0;
   g_a2_done_bar   = 0;
   if(!g_a2_live)
      return;

   int slot = 0;
   for(int i = PositionsTotal() - 1; i >= 0 && slot < A2_MAX_LEGS; i--)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != g_a2_magic)
         continue;

      const int    side  = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
      const double entry = PositionGetDouble(POSITION_PRICE_OPEN);
      const double sl    = PositionGetDouble(POSITION_SL);
      const double tp    = PositionGetDouble(POSITION_TP);
      if(sl <= 0.0)
      {
         A2_Error("adopted ticket " + IntegerToString((long)ticket)
                  + " has no stop — closing it, an unprotected position is not ours to keep");
         A2_ExecCloseTicket(ticket);
         continue;
      }
      const double risk = MathAbs(entry - sl);
      const datetime opened = (datetime)PositionGetInteger(POSITION_TIME);

      g_a2_trade_id++;
      g_a2_legs[slot].on         = true;
      g_a2_legs[slot].side       = side;
      g_a2_legs[slot].which      = slot + 1;
      g_a2_legs[slot].id         = g_a2_trade_id;
      g_a2_legs[slot].signal_bar = opened;
      g_a2_legs[slot].fill_bar   = opened;
      g_a2_legs[slot].entry      = entry;
      g_a2_legs[slot].sl         = sl;
      g_a2_legs[slot].tp         = tp;
      g_a2_legs[slot].risk       = risk;
      g_a2_legs[slot].lots       = PositionGetDouble(POSITION_VOLUME);
      g_a2_legs[slot].risk_money = A2_LossForLots(side, g_a2_legs[slot].lots, entry, sl);
      g_a2_legs[slot].ticket     = ticket;
      g_a2_sess_n++;
      A2_Warn("adopted live ticket=" + IntegerToString((long)ticket)
              + " " + (side > 0 ? "long" : "short")
              + " lots=" + DoubleToString(g_a2_legs[slot].lots, 2)
              + " risk$=" + DoubleToString(g_a2_legs[slot].risk_money, 2));
      slot++;
   }
   A2_LevelsDraw();
}

// A broker-side stop or target closes the position without telling the engine.
void A2_LiveTick()
{
   if(!g_a2_live || g_a2_replay)
      return;
   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   for(int i = 0; i < A2_MAX_LEGS; i++)
   {
      if(!g_a2_legs[i].on || g_a2_legs[i].ticket == 0)
         continue;
      if(A2_ExecSelectTicket(g_a2_legs[i].ticket))
         continue;
      const double px = (g_a2_legs[i].side > 0 ? bid : ask);
      g_a2_legs[i].ticket = 0;   // gone at the broker; do not try to close it again
      A2_CloseLeg(i, TimeCurrent(), px, "broker_exit");
   }
}

string A2_PosLine()
{
   const string tail = "  closed=" + IntegerToString(g_a2_closed_n)
                       + "  sumR=" + DoubleToString(g_a2_sum_r, 2)
                       + "  session=" + IntegerToString(g_a2_sess_n)
                       + "/" + IntegerToString(A2_MAX_ENTRIES_SESS);
   if(A2_OpenCount() == 0)
      return "flat" + tail;
   string line = "open " + IntegerToString(A2_OpenCount());
   for(int i = 0; i < A2_MAX_LEGS; i++)
   {
      if(!g_a2_legs[i].on)
         continue;
      line += " | " + (g_a2_legs[i].side > 0 ? "LONG" : "SHORT")
              + " #" + IntegerToString(g_a2_legs[i].id)
              + " @" + DoubleToString(g_a2_legs[i].entry, _Digits)
              + " sl=" + DoubleToString(g_a2_legs[i].sl, _Digits)
              + " tp=" + DoubleToString(g_a2_legs[i].tp, _Digits)
              + " lots=" + DoubleToString(g_a2_legs[i].lots, 2)
              + " w" + IntegerToString(g_a2_legs[i].which)
              + (g_a2_legs[i].ticket != 0
                 ? (" t=" + IntegerToString((long)g_a2_legs[i].ticket)) : "");
   }
   return line + tail;
}

string A2_EngineComment(const A2Snap &s)
{
   return A2_ChannelLine(s)
          + "\n" + A2_PosLine()
          + "\n" + A2_RiskLine(A2_FloatingNow(), A2_OpenRiskMoney())
          + "\n" + A2_NewsLine()
          + "\n" + (g_a2_time_ok ? "clock verified US-DST (NY = server-7h)"
                                 : "CLOCK UNVERIFIED — trading refused")
          + "\n" + (g_a2_live ? "LIVE orders armed" : "shadow only — no OrderSend");
}

#endif
