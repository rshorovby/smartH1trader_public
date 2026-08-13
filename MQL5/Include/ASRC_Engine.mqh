#ifndef ASRC_ENGINE_MQH
#define ASRC_ENGINE_MQH

#include "ASRC_Config.mqh"
#include "SHT_Log.mqh"
#include "SHT_Risk.mqh"
#include "ASRC_Channel.mqh"

// Alpha S/R Channel — same numbers as backtest_alpha_sr_channel.py (BTC tick 0.01).
#define ASRC_RR              3.0
#define ASRC_ENG_MIN         0.098
#define ASRC_ENG_MAX         0.550
#define ASRC_PREV_RAN        0.60
#define ASRC_PIN_WICK_RATIO  3.0
#define ASRC_PIN_BODY_MAX    0.20
#define ASRC_PIN_WICK_MIN    0.70
#define ASRC_PIN_PCT         0.70
#define ASRC_SWEEP_LB        10
#define ASRC_GAP_TICKS       250
#define ASRC_SL_BUF_TICKS    500
#define ASRC_MAX_FIRST       2
#define ASRC_BARS_GAP        4
#define ASRC_MAX_LEGS        2
#define ASRC_ALLOW_SECOND    true
#define ASRC_MRK             "ASRCe_"
#define ASRC_LVL             "ASRCl_"

struct ASRCLeg
{
   bool     on;
   int      side;
   int      which;
   int      id;
   datetime bar_time;
   double   entry;
   double   sl;
   double   tp;
   double   risk;
   double   lots;
   double   risk_money;
};

ASRCLeg  g_asrc_legs[ASRC_MAX_LEGS];
int      g_asrc_trade_id   = 0;
int      g_asrc_closed_n   = 0;
int      g_asrc_session_n  = 0;
datetime g_asrc_last_entry = 0;
bool     g_asrc_replay     = false;
string   g_asrc_last_pat   = "";

int ASRC_OpenCount()
{
   int n = 0;
   for(int i = 0; i < ASRC_MAX_LEGS; i++)
      if(g_asrc_legs[i].on)
         n++;
   return n;
}

int ASRC_SameSideCount(const int side)
{
   int n = 0;
   for(int i = 0; i < ASRC_MAX_LEGS; i++)
      if(g_asrc_legs[i].on && g_asrc_legs[i].side == side)
         n++;
   return n;
}

double ASRC_NowFloating()
{
   const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double f = 0.0;
   for(int i = 0; i < ASRC_MAX_LEGS; i++)
   {
      if(!g_asrc_legs[i].on || g_asrc_legs[i].risk <= 0.0 || g_asrc_legs[i].risk_money <= 0.0)
         continue;
      const double r = (g_asrc_legs[i].side > 0)
                       ? (bid - g_asrc_legs[i].entry) / g_asrc_legs[i].risk
                       : (g_asrc_legs[i].entry - bid) / g_asrc_legs[i].risk;
      f += r * g_asrc_legs[i].risk_money;
   }
   return f;
}

void ASRC_LegsClear()
{
   for(int i = 0; i < ASRC_MAX_LEGS; i++)
      ZeroMemory(g_asrc_legs[i]);
}

void ASRC_ObjectsWipe()
{
   ObjectsDeleteAll(0, ASRC_MRK);
   ObjectsDeleteAll(0, ASRC_LVL);
}

void ASRC_Mark(const string tag, const datetime t, const double px,
               const int arrow, const color clr)
{
   const string n = ASRC_MRK + tag;
   if(ObjectFind(0, n) >= 0)
      ObjectDelete(0, n);
   ObjectCreate(0, n, OBJ_ARROW, 0, t, px);
   ObjectSetInteger(0, n, OBJPROP_ARROWCODE, arrow);
   ObjectSetInteger(0, n, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, n, OBJPROP_WIDTH, 2);
   ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
}

void ASRC_HLine(const string tag, const double px, const color clr, const ENUM_LINE_STYLE st)
{
   const string n = ASRC_LVL + tag;
   if(ObjectFind(0, n) < 0)
      ObjectCreate(0, n, OBJ_HLINE, 0, 0, px);
   ObjectSetDouble(0, n, OBJPROP_PRICE, px);
   ObjectSetInteger(0, n, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, n, OBJPROP_STYLE, st);
   ObjectSetInteger(0, n, OBJPROP_WIDTH, 1);
   ObjectSetInteger(0, n, OBJPROP_SELECTABLE, false);
}

void ASRC_LevelsDraw()
{
   ObjectsDeleteAll(0, ASRC_LVL);
   for(int i = 0; i < ASRC_MAX_LEGS; i++)
   {
      if(!g_asrc_legs[i].on)
         continue;
      const string id = IntegerToString(g_asrc_legs[i].id);
      ASRC_HLine("SL" + id, g_asrc_legs[i].sl, clrOrangeRed, STYLE_DASH);
      ASRC_HLine("TP" + id, g_asrc_legs[i].tp, clrLimeGreen, STYLE_DASH);
   }
}

void ASRC_Patterns(const int shift, const double px, const double tick,
                   bool &bull_eng, bool &bear_eng, bool &pin_bull, bool &pin_bear)
{
   bull_eng = false;
   bear_eng = false;
   pin_bull = false;
   pin_bear = false;
   g_asrc_last_pat = "";

   const int bars = Bars(_Symbol, PERIOD_M5);
   if(shift + 1 >= bars)
      return;

   const double o  = iOpen(_Symbol, PERIOD_M5, shift);
   const double cl = iClose(_Symbol, PERIOD_M5, shift);
   const double o1 = iOpen(_Symbol, PERIOD_M5, shift + 1);
   const double h1 = iHigh(_Symbol, PERIOD_M5, shift + 1);
   const double l1 = iLow(_Symbol, PERIOD_M5, shift + 1);
   const double c1 = iClose(_Symbol, PERIOD_M5, shift + 1);
   if(o <= 0.0 || cl <= 0.0 || o1 <= 0.0)
      return;

   const double eng_min = px * (ASRC_ENG_MIN / 100.0);
   const double eng_max = px * (ASRC_ENG_MAX / 100.0);
   const double prev_allow = eng_min * ASRC_PREV_RAN;
   const double gap_allow = tick * ASRC_GAP_TICKS;
   const double body = MathAbs(cl - o);
   const bool in_eng = (body >= eng_min && body <= eng_max);

   if(in_eng)
   {
      const bool prev_bear = (c1 < o1);
      const bool prev_bull = (c1 > o1);
      const bool prev_small_bull = prev_bull && ((c1 - o1) <= prev_allow);
      const bool prev_small_bear = prev_bear && ((o1 - c1) <= prev_allow);
      if((prev_bear || prev_small_bull) && cl > o)
      {
         const double prev_lvl = prev_bear ? o1 : h1;
         if(o <= c1 + gap_allow && cl > prev_lvl)
            bull_eng = true;
      }
      if((prev_bull || prev_small_bear) && cl < o)
      {
         const double prev_lvl = prev_bull ? o1 : l1;
         if(o >= c1 - gap_allow && cl < prev_lvl)
            bear_eng = true;
      }
   }

   if(shift + 1 + ASRC_SWEEP_LB >= bars)
   {
      if(bull_eng)
         g_asrc_last_pat = "bull_eng";
      else if(bear_eng)
         g_asrc_last_pat = "bear_eng";
      return;
   }

   const double rng1 = h1 - l1;
   const double pin_min = eng_min * ASRC_PIN_PCT;
   if(rng1 >= pin_min && rng1 > 0.0)
   {
      const double body1 = MathAbs(c1 - o1);
      if(body1 > 0.0 && (body1 / rng1) <= ASRC_PIN_BODY_MAX)
      {
         const double up_w = h1 - MathMax(o1, c1);
         const double dn_w = MathMin(o1, c1) - l1;
         const double long_w = MathMax(up_w, dn_w);
         if((long_w / rng1) >= ASRC_PIN_WICK_MIN && (long_w / body1) >= ASRC_PIN_WICK_RATIO)
         {
            double last_bot = iLow(_Symbol, PERIOD_M5, shift + 2);
            double last_top = iHigh(_Symbol, PERIOD_M5, shift + 2);
            for(int k = 3; k < 2 + ASRC_SWEEP_LB; k++)
            {
               const double lk = iLow(_Symbol, PERIOD_M5, shift + k);
               const double hk = iHigh(_Symbol, PERIOD_M5, shift + k);
               if(lk < last_bot)
                  last_bot = lk;
               if(hk > last_top)
                  last_top = hk;
            }
            const double cur_body = MathAbs(cl - o);
            const bool body_ok = (cur_body >= eng_min * ASRC_PIN_PCT && cur_body <= eng_max);
            if(dn_w > up_w && last_bot > l1 && cl > o && cl > h1 && body_ok)
               pin_bull = true;
            if(up_w >= dn_w && last_top < h1 && cl < o && cl < l1 && body_ok)
               pin_bear = true;
         }
      }
   }

   if(pin_bull)
      g_asrc_last_pat = "pin_bull";
   else if(pin_bear)
      g_asrc_last_pat = "pin_bear";
   else if(bull_eng)
      g_asrc_last_pat = "bull_eng";
   else if(bear_eng)
      g_asrc_last_pat = "bear_eng";
}

void ASRC_ShadowClose(const int idx, const datetime t, const double px, const string reason)
{
   ASRCLeg leg = g_asrc_legs[idx];
   if(!leg.on)
      return;
   const double r = (leg.side > 0)
                    ? (px - leg.entry) / leg.risk
                    : (leg.entry - px) / leg.risk;
   if(!g_asrc_replay && leg.risk_money > 0.0)
      SHT_RiskAddPnl(r * leg.risk_money);
   g_asrc_closed_n++;
   ASRC_Mark("X" + IntegerToString(leg.id), t, px, 251,
             (r > 0.0 ? clrLimeGreen : clrOrangeRed));
   if(!g_asrc_replay)
      SHT_Info("shadow close #" + IntegerToString(leg.id)
               + " " + (leg.side > 0 ? "long" : "short")
               + " " + reason
               + " exit=" + DoubleToString(px, _Digits)
               + " R=" + DoubleToString(r, 3)
               + " which=" + IntegerToString(leg.which)
               + " lots=" + DoubleToString(leg.lots, 2));
   else
      SHT_Info("replay close #" + IntegerToString(leg.id)
               + " " + (leg.side > 0 ? "long" : "short")
               + " " + reason
               + " R=" + DoubleToString(r, 3));
   ZeroMemory(g_asrc_legs[idx]);
   if(!g_asrc_replay)
      ASRC_LevelsDraw();
}

void ASRC_FlattenAll(const datetime t, const double px, const string reason)
{
   for(int i = 0; i < ASRC_MAX_LEGS; i++)
   {
      if(g_asrc_legs[i].on)
         ASRC_ShadowClose(i, t, px, reason);
   }
}

void ASRC_Manage(const datetime t, const double high, const double low)
{
   for(int i = 0; i < ASRC_MAX_LEGS; i++)
   {
      if(!g_asrc_legs[i].on)
         continue;
      if(t <= g_asrc_legs[i].bar_time)
         continue;
      if(g_asrc_legs[i].side > 0)
      {
         if(high >= g_asrc_legs[i].tp)
            ASRC_ShadowClose(i, t, g_asrc_legs[i].tp, "tp");
         else if(low <= g_asrc_legs[i].sl)
            ASRC_ShadowClose(i, t, g_asrc_legs[i].sl, "stop");
      }
      else
      {
         if(low <= g_asrc_legs[i].tp)
            ASRC_ShadowClose(i, t, g_asrc_legs[i].tp, "tp");
         else if(high >= g_asrc_legs[i].sl)
            ASRC_ShadowClose(i, t, g_asrc_legs[i].sl, "stop");
      }
   }
}

bool ASRC_BarsGapOk(const int shift)
{
   if(g_asrc_last_entry <= 0)
      return true;
   const int last_sh = iBarShift(_Symbol, PERIOD_M5, g_asrc_last_entry, true);
   if(last_sh < 0)
      return true;
   return ((last_sh - shift) > ASRC_BARS_GAP);
}

void ASRC_ShadowOpen(const ASRCSnap &s, const int side, const int which, const double tick)
{
   int slot = -1;
   for(int i = 0; i < ASRC_MAX_LEGS; i++)
   {
      if(!g_asrc_legs[i].on)
      {
         slot = i;
         break;
      }
   }
   if(slot < 0)
      return;

   const double sl_buf = tick * ASRC_SL_BUF_TICKS;
   double sl, risk;
   if(side > 0)
   {
      sl = s.ch_lo - sl_buf;
      risk = s.close - sl;
   }
   else
   {
      sl = s.ch_up + sl_buf;
      risk = sl - s.close;
   }
   if(risk <= 0.0)
      return;
   const double tp = (side > 0)
                     ? s.close + ASRC_RR * risk
                     : s.close - ASRC_RR * risk;

   double lots = 0.0;
   if(!SHT_RiskCanEnter(s.bar_time, g_asrc_replay, risk, ASRC_NowFloating(), lots))
   {
      if(!g_asrc_replay)
         SHT_Info("skip " + (side > 0 ? "long" : "short") + ": " + g_risk_why);
      return;
   }

   const double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   g_asrc_trade_id++;
   g_asrc_legs[slot].on         = true;
   g_asrc_legs[slot].side       = side;
   g_asrc_legs[slot].which      = which;
   g_asrc_legs[slot].id         = g_asrc_trade_id;
   g_asrc_legs[slot].bar_time   = s.bar_time;
   g_asrc_legs[slot].entry      = s.close;
   g_asrc_legs[slot].sl         = sl;
   g_asrc_legs[slot].tp         = tp;
   g_asrc_legs[slot].risk       = risk;
   g_asrc_legs[slot].lots       = lots;
   g_asrc_legs[slot].risk_money = eq * g_risk_pct;
   g_asrc_last_entry            = s.bar_time;
   if(which == 1)
      g_asrc_session_n++;

   ASRC_Mark("E" + IntegerToString(g_asrc_trade_id), s.bar_time, s.close,
             (side > 0 ? 233 : 234),
             (side > 0 ? clrDodgerBlue : clrOrchid));
   if(!g_asrc_replay)
      ASRC_LevelsDraw();
   SHT_Info((g_asrc_replay ? "replay " : "shadow ")
            + "open #" + IntegerToString(g_asrc_trade_id)
            + " " + (side > 0 ? "long" : "short")
            + " which=" + IntegerToString(which)
            + " " + g_asrc_last_pat
            + " entry=" + DoubleToString(s.close, _Digits)
            + " sl=" + DoubleToString(sl, _Digits)
            + " tp=" + DoubleToString(tp, _Digits)
            + " r=" + DoubleToString(risk, _Digits)
            + " lots=" + DoubleToString(lots, 2));
}

bool ASRC_EngineOnBar(const int shift, const bool replay)
{
   g_asrc_replay = replay;

   ASRCSnap s;
   if(!ASRC_Read(s, shift))
      return false;

   const datetime t = s.bar_time;
   const double high = iHigh(_Symbol, PERIOD_M5, shift);
   const double low  = iLow(_Symbol, PERIOD_M5, shift);
   if(t <= 0)
      return false;

   SHT_RiskOnBar(t);

   if(s.session_reset)
      g_asrc_session_n = 0;

   if(s.eod && ASRC_OpenCount() > 0)
   {
      ASRC_FlattenAll(t, s.close, "eod");
      return true;
   }

   ASRC_Manage(t, high, low);

   if(s.no_trade || s.friday || g_asrc_session_n >= ASRC_MAX_FIRST)
      return true;
   if(!ASRC_BarsGapOk(shift))
      return true;
   if(ASRC_OpenCount() >= ASRC_MAX_LEGS)
      return true;
   if(s.low_vol)
      return true;

   const double tick = ASRC_TickSize();
   bool bull_eng, bear_eng, pin_bull, pin_bear;
   ASRC_Patterns(shift, s.close, tick, bull_eng, bear_eng, pin_bull, pin_bear);
   const bool long_pat  = bull_eng || pin_bull;
   const bool short_pat = bear_eng || pin_bear;

   const bool long_ok =
      s.bias_long && s.in_channel && long_pat && s.rsi_buy
      && (s.ema_buy || pin_bull) && s.sqz_long && s.ht_buy;
   const bool short_ok =
      s.bias_short && s.in_channel && short_pat && s.rsi_sell
      && (s.ema_sell || pin_bear) && s.sqz_short && s.ht_sell;

   const int n = ASRC_OpenCount();
   const bool flat = (n == 0);
   const bool same_long  = (n == 1 && ASRC_SameSideCount(+1) == 1);
   const bool same_short = (n == 1 && ASRC_SameSideCount(-1) == 1);

   if(long_ok && flat)
      ASRC_ShadowOpen(s, +1, 1, tick);
   else if(long_ok && ASRC_ALLOW_SECOND && same_long)
      ASRC_ShadowOpen(s, +1, 2, tick);
   else if(short_ok && flat)
      ASRC_ShadowOpen(s, -1, 1, tick);
   else if(short_ok && ASRC_ALLOW_SECOND && same_short)
      ASRC_ShadowOpen(s, -1, 2, tick);

   return true;
}

int ASRC_EngineReplay()
{
   ASRC_ObjectsWipe();
   ASRC_LegsClear();
   ASRC_ResetBias();
   g_asrc_trade_id   = 0;
   g_asrc_closed_n   = 0;
   g_asrc_session_n  = 0;
   g_asrc_last_entry = 0;

   const int total = Bars(_Symbol, PERIOD_M5);
   int shift = total - ASRC_WARMUP - 1;
   if(shift < 1)
   {
      SHT_Warn("replay skipped: bars=" + IntegerToString(total)
               + " need>" + IntegerToString(ASRC_WARMUP + 1));
      return 0;
   }

   SHT_Info("replay start bars=" + IntegerToString(shift));
   int ok = 0;
   for(; shift >= 1; shift--)
   {
      if(ASRC_EngineOnBar(shift, true))
         ok++;
   }
   g_asrc_replay = false;
   SHT_RiskResetDay(TimeCurrent());
   ASRC_LevelsDraw();
   ChartRedraw(0);
   SHT_Info("replay bars=" + IntegerToString(ok)
            + " closed=" + IntegerToString(g_asrc_closed_n)
            + " open=" + IntegerToString(ASRC_OpenCount())
            + " session=" + IntegerToString(g_asrc_session_n));
   return ok;
}

string ASRC_PosLine()
{
   const int n = ASRC_OpenCount();
   if(n == 0)
      return "flat  closed=" + IntegerToString(g_asrc_closed_n)
             + "  session=" + IntegerToString(g_asrc_session_n) + "/" + IntegerToString(ASRC_MAX_FIRST);
   string line = "open " + IntegerToString(n);
   for(int i = 0; i < ASRC_MAX_LEGS; i++)
   {
      if(!g_asrc_legs[i].on)
         continue;
      line += " | " + (g_asrc_legs[i].side > 0 ? "LONG" : "SHORT")
              + " #" + IntegerToString(g_asrc_legs[i].id)
              + " @" + DoubleToString(g_asrc_legs[i].entry, _Digits)
              + " sl=" + DoubleToString(g_asrc_legs[i].sl, _Digits)
              + " tp=" + DoubleToString(g_asrc_legs[i].tp, _Digits)
              + " lots=" + DoubleToString(g_asrc_legs[i].lots, 2)
              + " w" + IntegerToString(g_asrc_legs[i].which);
   }
   return line + "  closed=" + IntegerToString(g_asrc_closed_n)
          + "  session=" + IntegerToString(g_asrc_session_n) + "/" + IntegerToString(ASRC_MAX_FIRST);
}

string ASRC_EngineComment(const ASRCSnap &s)
{
   return ASRC_Line(s)
          + "\n" + ASRC_PosLine()
          + "\n" + SHT_RiskLine(ASRC_NowFloating())
          + "\nshadow only — no OrderSend  halt local (not shared with Vegas)";
}

#endif
