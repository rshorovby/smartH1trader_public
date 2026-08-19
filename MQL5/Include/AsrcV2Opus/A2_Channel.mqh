#ifndef A2_CHANNEL_MQH
#define A2_CHANNEL_MQH

#include "A2_Config.mqh"
#include "A2_Log.mqh"
#include "A2_Time.mqh"

// Indicator reads.
//
// The one change that matters: higher-timeframe values come from bars that have
// already closed at the moment the M5 bar closes. v1 asked iBarShift for the bar
// *containing* the M5 stamp, which in replay is a finished bar and in live is a
// forming one — so the EA's live channel disagreed with both its own replay and
// the Python backtest, and the backtest itself was reading 15 and 60 minutes into
// the future on most bars.
//
// Second change: reading a snapshot no longer mutates anything. v1 advanced the
// latched breakout bias inside its read function, which the comment refresh
// called every 15 seconds, so the display path was writing trading state.

struct A2Snap
{
   datetime bar_time;
   datetime decision_t;   // when this bar closes; the moment we are allowed to act
   double   open;
   double   high;
   double   low;
   double   close;
   double   ch_mid;
   double   ch_up;
   double   ch_lo;
   double   ema21;
   double   ht_ema;
   double   rsi;
   double   bb_width;
   double   sqz;
   bool     in_channel;
   bool     ema_buy;
   bool     ema_sell;
   bool     ht_buy;
   bool     ht_sell;
   bool     rsi_buy;
   bool     rsi_sell;
   bool     sqz_long;
   bool     sqz_short;
   bool     low_vol;
   int      ny_min;
   int      ny_wday;
   bool     valid;
};

int      g_a2_h_ch      = INVALID_HANDLE;
int      g_a2_h_ht      = INVALID_HANDLE;
int      g_a2_h_ltf     = INVALID_HANDLE;
int      g_a2_h_rsi     = INVALID_HANDLE;
bool     g_a2_bias_long  = false;
bool     g_a2_bias_short = false;
datetime g_a2_bias_bar   = 0;

// iMA and iRSI seed their recursions from the oldest bar the terminal holds, while
// the Python reference seeds from its first close. The difference decays with the
// smoothing constant, so the engine refuses to run until history is long enough
// for it to be gone: 500 bars is more than thirty time constants for EMA55.
#define A2_MIN_BARS_M5   1000
#define A2_MIN_BARS_M15  500
#define A2_MIN_BARS_H1   500

bool A2_Init(const string symbol)
{
   g_a2_h_ch  = iMA(symbol, A2_CH_TF, A2_CH_EMA, 0, MODE_EMA, PRICE_CLOSE);
   g_a2_h_ht  = iMA(symbol, A2_HT_TF, A2_HT_EMA, 0, MODE_EMA, PRICE_CLOSE);
   g_a2_h_ltf = iMA(symbol, A2_ALLOWED_TF, A2_LTF_EMA, 0, MODE_EMA, PRICE_CLOSE);
   g_a2_h_rsi = iRSI(symbol, A2_ALLOWED_TF, A2_RSI_LEN, PRICE_CLOSE);
   g_a2_bias_long  = false;
   g_a2_bias_short = false;
   g_a2_bias_bar   = 0;
   return (g_a2_h_ch != INVALID_HANDLE && g_a2_h_ht != INVALID_HANDLE
           && g_a2_h_ltf != INVALID_HANDLE && g_a2_h_rsi != INVALID_HANDLE);
}

void A2_Release()
{
   if(g_a2_h_ch  != INVALID_HANDLE) IndicatorRelease(g_a2_h_ch);
   if(g_a2_h_ht  != INVALID_HANDLE) IndicatorRelease(g_a2_h_ht);
   if(g_a2_h_ltf != INVALID_HANDLE) IndicatorRelease(g_a2_h_ltf);
   if(g_a2_h_rsi != INVALID_HANDLE) IndicatorRelease(g_a2_h_rsi);
   g_a2_h_ch = g_a2_h_ht = g_a2_h_ltf = g_a2_h_rsi = INVALID_HANDLE;
   ObjectDelete(0, "A2_UP");
   ObjectDelete(0, "A2_LO");
}

bool A2_Ready(string &why)
{
   if(Bars(_Symbol, A2_ALLOWED_TF) < A2_MIN_BARS_M5)
   {
      why = "M5 bars " + IntegerToString(Bars(_Symbol, A2_ALLOWED_TF))
            + "/" + IntegerToString(A2_MIN_BARS_M5);
      return false;
   }
   if(Bars(_Symbol, A2_CH_TF) < A2_MIN_BARS_M15)
   {
      why = "M15 bars " + IntegerToString(Bars(_Symbol, A2_CH_TF))
            + "/" + IntegerToString(A2_MIN_BARS_M15);
      return false;
   }
   if(Bars(_Symbol, A2_HT_TF) < A2_MIN_BARS_H1)
   {
      why = "H1 bars " + IntegerToString(Bars(_Symbol, A2_HT_TF))
            + "/" + IntegerToString(A2_MIN_BARS_H1);
      return false;
   }
   if(BarsCalculated(g_a2_h_ch) < A2_CH_EMA || BarsCalculated(g_a2_h_ht) < A2_HT_EMA
      || BarsCalculated(g_a2_h_ltf) < A2_LTF_EMA || BarsCalculated(g_a2_h_rsi) < A2_RSI_LEN)
   {
      why = "indicators still calculating";
      return false;
   }
   why = "";
   return true;
}

double A2_TickSize()
{
   double t = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(t <= 0.0)
      t = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(t <= 0.0)
      t = 0.01;
   return t;
}

bool A2_CopyShift(const int handle, const int buffer, const int shift, double &out)
{
   double a[];
   ArraySetAsSeries(a, true);
   if(handle == INVALID_HANDLE || shift < 0)
      return false;
   if(CopyBuffer(handle, buffer, shift, 1, a) < 1)
      return false;
   if(a[0] == EMPTY_VALUE || !MathIsValidNumber(a[0]))
      return false;
   out = a[0];
   return true;
}

// Newest bar of tf that had already closed at decision_t.
int A2_ClosedShift(const ENUM_TIMEFRAMES tf, const datetime decision_t)
{
   const int per   = PeriodSeconds(tf);
   const int total = Bars(_Symbol, tf);
   if(per <= 0 || total <= 0 || decision_t <= 0)
      return -1;
   int sh = iBarShift(_Symbol, tf, decision_t - 1, false);
   if(sh < 0)
      return -1;
   while(sh < total)
   {
      const datetime bt = iTime(_Symbol, tf, sh);
      if(bt <= 0)
         return -1;
      if(bt + per <= decision_t)
         return sh;
      sh++;
   }
   return -1;
}

bool A2_ClosedValue(const int handle, const ENUM_TIMEFRAMES tf, const datetime decision_t,
                    double &out)
{
   const int sh = A2_ClosedShift(tf, decision_t);
   if(sh < 0)
      return false;
   return A2_CopyShift(handle, 0, sh, out);
}

// Bollinger width computed here rather than through iBands: pandas uses the
// sample standard deviation and iBands the population one, and this filter is a
// hard gate, so the two must not differ.
bool A2_BollWidth(const int shift, double &width)
{
   double c[];
   ArraySetAsSeries(c, true);
   if(CopyClose(_Symbol, A2_ALLOWED_TF, shift, A2_BB_LEN, c) < A2_BB_LEN)
      return false;
   double sum = 0.0;
   for(int i = 0; i < A2_BB_LEN; i++)
      sum += c[i];
   const double mean = sum / A2_BB_LEN;
   if(mean <= 0.0)
      return false;
   double sq = 0.0;
   for(int i = 0; i < A2_BB_LEN; i++)
      sq += (c[i] - mean) * (c[i] - mean);
   const double sd = MathSqrt(sq / (A2_BB_LEN - 1));
   width = 2.0 * A2_BB_MULT * sd / mean;
   return true;
}

double A2_Squeeze(const int shift)
{
   const int n = A2_SQZ_LEN;
   const int need = 2 * n - 1;
   double c[], hi[], lo[];
   ArraySetAsSeries(c, true);
   ArraySetAsSeries(hi, true);
   ArraySetAsSeries(lo, true);
   if(CopyClose(_Symbol, A2_ALLOWED_TF, shift, need, c) < need)
      return EMPTY_VALUE;
   if(CopyHigh(_Symbol, A2_ALLOWED_TF, shift, need, hi) < need)
      return EMPTY_VALUE;
   if(CopyLow(_Symbol, A2_ALLOWED_TF, shift, need, lo) < need)
      return EMPTY_VALUE;

   double y[];
   ArrayResize(y, n);
   double ymean = 0.0;
   for(int k = 0; k < n; k++)
   {
      double sum = 0.0, hh = hi[k], ll = lo[k];
      for(int j = 0; j < n; j++)
      {
         const int idx = k + j;
         sum += c[idx];
         if(hi[idx] > hh)
            hh = hi[idx];
         if(lo[idx] < ll)
            ll = lo[idx];
      }
      const double yk = c[k] - ((((hh + ll) / 2.0) + sum / n) / 2.0);
      y[n - 1 - k] = yk;
      ymean += yk;
   }
   ymean /= n;

   const double xmean = (n - 1) / 2.0;
   double num = 0.0, den = 0.0;
   for(int i = 0; i < n; i++)
   {
      const double xd = i - xmean;
      num += xd * (y[i] - ymean);
      den += xd * xd;
   }
   if(den == 0.0)
      return EMPTY_VALUE;
   return ymean + (num / den) * xmean;
}

// Pure. Reads nothing but market data and writes nothing but the snapshot.
bool A2_Snapshot(const int shift, A2Snap &s)
{
   s.valid = false;
   s.bar_time = iTime(_Symbol, A2_ALLOWED_TF, shift);
   if(s.bar_time <= 0)
      return false;
   s.decision_t = s.bar_time + PeriodSeconds(A2_ALLOWED_TF);
   s.open  = iOpen(_Symbol, A2_ALLOWED_TF, shift);
   s.high  = iHigh(_Symbol, A2_ALLOWED_TF, shift);
   s.low   = iLow(_Symbol, A2_ALLOWED_TF, shift);
   s.close = iClose(_Symbol, A2_ALLOWED_TF, shift);
   if(s.close <= 0.0 || s.open <= 0.0)
      return false;

   if(!A2_ClosedValue(g_a2_h_ch, A2_CH_TF, s.decision_t, s.ch_mid))
      return false;
   if(!A2_ClosedValue(g_a2_h_ht, A2_HT_TF, s.decision_t, s.ht_ema))
      return false;
   if(!A2_CopyShift(g_a2_h_ltf, 0, shift, s.ema21))
      return false;
   if(!A2_CopyShift(g_a2_h_rsi, 0, shift, s.rsi))
      return false;
   if(!A2_BollWidth(shift, s.bb_width))
      return false;

   const double half = s.close * (A2_CH_PCT / 100.0) / 2.0;
   s.ch_up = s.ch_mid + half;
   s.ch_lo = s.ch_mid - half;
   s.in_channel = (s.open >= s.ch_lo && s.open <= s.ch_up);

   s.ema_buy  = (s.close > s.ema21);
   s.ema_sell = (s.close < s.ema21);
   s.ht_buy   = (s.close > s.ht_ema);
   s.ht_sell  = (s.close < s.ht_ema);
   s.rsi_buy  = (s.rsi <= 70.0);
   s.rsi_sell = (s.rsi >= 30.0);
   s.low_vol  = (s.bb_width < A2_BB_THR);

   s.sqz = A2_Squeeze(shift);
   if(s.sqz == EMPTY_VALUE || !MathIsValidNumber(s.sqz))
   {
      s.sqz_long  = true;
      s.sqz_short = true;
   }
   else
   {
      s.sqz_long  = (s.sqz <= 0.0);
      s.sqz_short = (s.sqz >= 0.0);
   }

   MqlDateTime ny;
   A2_NyStruct(s.bar_time, ny);
   s.ny_min  = ny.hour * 60 + ny.min;
   s.ny_wday = ny.day_of_week;
   s.valid = true;
   return true;
}

// Latched breakout bias: two consecutive closes outside the channel arm one side.
// Called once per closed bar and keyed on the bar stamp, so a repeated call cannot
// advance it twice.
void A2_BiasAdvance(const int shift, const A2Snap &s)
{
   if(!s.valid || s.bar_time == g_a2_bias_bar)
      return;
   g_a2_bias_bar = s.bar_time;

   const datetime t1 = iTime(_Symbol, A2_ALLOWED_TF, shift + 1);
   const double   c1 = iClose(_Symbol, A2_ALLOWED_TF, shift + 1);
   if(t1 <= 0 || c1 <= 0.0)
      return;
   double mid1;
   if(!A2_ClosedValue(g_a2_h_ch, A2_CH_TF, t1 + PeriodSeconds(A2_ALLOWED_TF), mid1))
      return;
   const double half1 = c1 * (A2_CH_PCT / 100.0) / 2.0;
   if(c1 > mid1 + half1 && s.close > s.ch_up)
   {
      g_a2_bias_long  = true;
      g_a2_bias_short = false;
   }
   if(c1 < mid1 - half1 && s.close < s.ch_lo)
   {
      g_a2_bias_short = true;
      g_a2_bias_long  = false;
   }
}

void A2_BiasReset()
{
   g_a2_bias_long  = false;
   g_a2_bias_short = false;
   g_a2_bias_bar   = 0;
}

void A2_DrawChannel(const double up, const double lo)
{
   if(ObjectFind(0, "A2_UP") < 0)
      ObjectCreate(0, "A2_UP", OBJ_HLINE, 0, 0, up);
   if(ObjectFind(0, "A2_LO") < 0)
      ObjectCreate(0, "A2_LO", OBJ_HLINE, 0, 0, lo);
   ObjectSetDouble(0, "A2_UP", OBJPROP_PRICE, up);
   ObjectSetDouble(0, "A2_LO", OBJPROP_PRICE, lo);
   const string names[2] = {"A2_UP", "A2_LO"};
   for(int i = 0; i < 2; i++)
   {
      ObjectSetInteger(0, names[i], OBJPROP_COLOR, clrDodgerBlue);
      ObjectSetInteger(0, names[i], OBJPROP_STYLE, STYLE_DOT);
      ObjectSetInteger(0, names[i], OBJPROP_SELECTABLE, false);
   }
}

string A2_ChannelLine(const A2Snap &s)
{
   string bias = "flat";
   if(g_a2_bias_long)
      bias = "LONG";
   if(g_a2_bias_short)
      bias = "SHORT";
   return "ch " + DoubleToString(s.ch_lo, _Digits) + ".." + DoubleToString(s.ch_up, _Digits)
          + " bias=" + bias
          + (s.in_channel ? " in" : " out")
          + " ema21=" + (s.ema_buy ? "buy" : "sell")
          + " ht=" + (s.ht_buy ? "buy" : "sell")
          + " rsi=" + DoubleToString(s.rsi, 1)
          + " bbw=" + DoubleToString(s.bb_width, 4)
          + (s.low_vol ? " LOWVOL" : "")
          + " ny=" + IntegerToString(s.ny_min / 60) + ":"
          + StringFormat("%02d", s.ny_min % 60);
}

#endif
