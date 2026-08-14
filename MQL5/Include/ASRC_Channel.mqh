#ifndef ASRC_CHANNEL_MQH
#define ASRC_CHANNEL_MQH

#include "ASRC_Config.mqh"
#include "SHT_Log.mqh"

#define ASRC_CH_EMA      36
#define ASRC_CH_PCT      0.35
#define ASRC_LTF_EMA     21
#define ASRC_HT_EMA      55
#define ASRC_RSI_LEN     14
#define ASRC_BB_LEN      20
#define ASRC_BB_MULT     2.0
#define ASRC_BB_THR      0.002
#define ASRC_SQZ_LEN     20
#define ASRC_WARMUP      80

struct ASRCSnap
{
   datetime bar_time;
   double   close;
   double   open;
   double   ch_mid;
   double   ch_up;
   double   ch_lo;
   double   ema21;
   double   ht_ema;
   double   rsi;
   double   bb_width;
   double   sqz;
   bool     bias_long;
   bool     bias_short;
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
   bool     friday;
   bool     monday;
   bool     asia;          // NY 20:00–03:59
   bool     no_trade;
   bool     session_reset;
   bool     eod;
   bool     valid;
};

bool g_asrc_skip_monday = false;
bool g_asrc_skip_asia   = false;
int  g_asrc_h_ch  = INVALID_HANDLE;
int  g_asrc_h_ht  = INVALID_HANDLE;
int  g_asrc_h_ltf = INVALID_HANDLE;
int  g_asrc_h_rsi = INVALID_HANDLE;
int  g_asrc_h_bb  = INVALID_HANDLE;
bool g_asrc_bias_l = false;
bool g_asrc_bias_s = false;

bool ASRC_CopyShift(const int handle, const int buffer, const int shift, double &out)
{
   double a[];
   ArraySetAsSeries(a, true);
   if(handle == INVALID_HANDLE)
      return false;
   if(CopyBuffer(handle, buffer, shift, 1, a) < 1)
      return false;
   if(a[0] == EMPTY_VALUE || !MathIsValidNumber(a[0]))
      return false;
   out = a[0];
   return true;
}

bool ASRC_CopyAtTime(const int handle, const ENUM_TIMEFRAMES tf, const datetime t, double &out)
{
   const int sh = iBarShift(_Symbol, tf, t, false);
   if(sh < 0)
      return false;
   return ASRC_CopyShift(handle, 0, sh, out);
}

int ASRC_NthSunday(const int year, const int month, const int n)
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

bool ASRC_UsDst(const datetime gmt)
{
   MqlDateTime dt;
   TimeToStruct(gmt, dt);
   if(dt.mon > 3 && dt.mon < 11)
      return true;
   if(dt.mon < 3 || dt.mon > 11)
      return false;
   if(dt.mon == 3)
      return (dt.day >= ASRC_NthSunday(dt.year, 3, 2));
   return (dt.day < ASRC_NthSunday(dt.year, 11, 1));
}

datetime ASRC_BarGmt(const datetime server_t)
{
   return server_t - (TimeCurrent() - TimeGMT());
}

void ASRC_NyStamp(const datetime server_t, MqlDateTime &ny)
{
   datetime gmt = ASRC_BarGmt(server_t);
   const int off = ASRC_UsDst(gmt) ? 4 : 5;
   TimeToStruct(gmt - off * 3600, ny);
}

double ASRC_TickSize()
{
   double t = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(t <= 0.0)
      t = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(t <= 0.0)
      t = 0.01;
   return t;
}

void ASRC_ResetBias()
{
   g_asrc_bias_l = false;
   g_asrc_bias_s = false;
}

double ASRC_Squeeze(const int shift)
{
   const int n = ASRC_SQZ_LEN;
   const int need = 2 * n - 1;
   double c[], hi[], lo[];
   ArraySetAsSeries(c, true);
   ArraySetAsSeries(hi, true);
   ArraySetAsSeries(lo, true);
   if(CopyClose(_Symbol, PERIOD_M5, shift, need, c) < need)
      return EMPTY_VALUE;
   if(CopyHigh(_Symbol, PERIOD_M5, shift, need, hi) < need)
      return EMPTY_VALUE;
   if(CopyLow(_Symbol, PERIOD_M5, shift, need, lo) < need)
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
      const double sma = sum / n;
      const double avg3 = (((hh + ll) / 2.0) + sma) / 2.0;
      const double yk = c[k] - avg3;
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
   const double slope = num / den;
   return ymean + slope * ((n - 1) / 2.0);
}

bool ASRC_Init(const string symbol)
{
   g_asrc_h_ch  = iMA(symbol, PERIOD_M15, ASRC_CH_EMA, 0, MODE_EMA, PRICE_CLOSE);
   g_asrc_h_ht  = iMA(symbol, PERIOD_H1,  ASRC_HT_EMA, 0, MODE_EMA, PRICE_CLOSE);
   g_asrc_h_ltf = iMA(symbol, PERIOD_M5,  ASRC_LTF_EMA, 0, MODE_EMA, PRICE_CLOSE);
   g_asrc_h_rsi = iRSI(symbol, PERIOD_M5, ASRC_RSI_LEN, PRICE_CLOSE);
   g_asrc_h_bb  = iBands(symbol, PERIOD_M5, ASRC_BB_LEN, 0, ASRC_BB_MULT, PRICE_CLOSE);
   g_asrc_bias_l = false;
   g_asrc_bias_s = false;
   return (
      g_asrc_h_ch  != INVALID_HANDLE &&
      g_asrc_h_ht  != INVALID_HANDLE &&
      g_asrc_h_ltf != INVALID_HANDLE &&
      g_asrc_h_rsi != INVALID_HANDLE &&
      g_asrc_h_bb  != INVALID_HANDLE
   );
}

void ASRC_Release()
{
   if(g_asrc_h_ch  != INVALID_HANDLE) IndicatorRelease(g_asrc_h_ch);
   if(g_asrc_h_ht  != INVALID_HANDLE) IndicatorRelease(g_asrc_h_ht);
   if(g_asrc_h_ltf != INVALID_HANDLE) IndicatorRelease(g_asrc_h_ltf);
   if(g_asrc_h_rsi != INVALID_HANDLE) IndicatorRelease(g_asrc_h_rsi);
   if(g_asrc_h_bb  != INVALID_HANDLE) IndicatorRelease(g_asrc_h_bb);
   g_asrc_h_ch = g_asrc_h_ht = g_asrc_h_ltf = g_asrc_h_rsi = g_asrc_h_bb = INVALID_HANDLE;
   ObjectDelete(0, "ASRC_UP");
   ObjectDelete(0, "ASRC_LO");
}

bool ASRC_Ready()
{
   return (
      BarsCalculated(g_asrc_h_ch)  >= ASRC_CH_EMA &&
      BarsCalculated(g_asrc_h_ht)  >= ASRC_HT_EMA &&
      BarsCalculated(g_asrc_h_ltf) >= ASRC_LTF_EMA &&
      BarsCalculated(g_asrc_h_rsi) >= ASRC_RSI_LEN &&
      BarsCalculated(g_asrc_h_bb)  >= ASRC_BB_LEN &&
      Bars(_Symbol, PERIOD_M5)     >= ASRC_WARMUP &&
      Bars(_Symbol, PERIOD_M15)    >= ASRC_CH_EMA &&
      Bars(_Symbol, PERIOD_H1)     >= ASRC_HT_EMA
   );
}

void ASRC_DrawChannel(const double up, const double lo)
{
   if(ObjectFind(0, "ASRC_UP") < 0)
      ObjectCreate(0, "ASRC_UP", OBJ_HLINE, 0, 0, up);
   if(ObjectFind(0, "ASRC_LO") < 0)
      ObjectCreate(0, "ASRC_LO", OBJ_HLINE, 0, 0, lo);
   ObjectSetDouble(0, "ASRC_UP", OBJPROP_PRICE, up);
   ObjectSetDouble(0, "ASRC_LO", OBJPROP_PRICE, lo);
   ObjectSetInteger(0, "ASRC_UP", OBJPROP_COLOR, clrDodgerBlue);
   ObjectSetInteger(0, "ASRC_LO", OBJPROP_COLOR, clrDodgerBlue);
   ObjectSetInteger(0, "ASRC_UP", OBJPROP_STYLE, STYLE_DOT);
   ObjectSetInteger(0, "ASRC_LO", OBJPROP_STYLE, STYLE_DOT);
   ObjectSetInteger(0, "ASRC_UP", OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, "ASRC_LO", OBJPROP_SELECTABLE, false);
}

bool ASRC_Read(ASRCSnap &s, const int shift)
{
   s.valid = false;
   s.bar_time = iTime(_Symbol, PERIOD_M5, shift);
   s.open     = iOpen(_Symbol, PERIOD_M5, shift);
   s.close    = iClose(_Symbol, PERIOD_M5, shift);
   if(s.bar_time <= 0 || s.close <= 0.0)
      return false;

   if(!ASRC_CopyAtTime(g_asrc_h_ch, PERIOD_M15, s.bar_time, s.ch_mid))
      return false;
   if(!ASRC_CopyAtTime(g_asrc_h_ht, PERIOD_H1, s.bar_time, s.ht_ema))
      return false;
   if(!ASRC_CopyShift(g_asrc_h_ltf, 0, shift, s.ema21))
      return false;
   if(!ASRC_CopyShift(g_asrc_h_rsi, 0, shift, s.rsi))
      return false;

   double bb_up, bb_lo, bb_mid;
   if(!ASRC_CopyShift(g_asrc_h_bb, 1, shift, bb_up))
      return false;
   if(!ASRC_CopyShift(g_asrc_h_bb, 2, shift, bb_lo))
      return false;
   if(!ASRC_CopyShift(g_asrc_h_bb, 0, shift, bb_mid))
      return false;
   if(bb_mid <= 0.0)
      return false;
   s.bb_width = (bb_up - bb_lo) / bb_mid;

   const double half = s.close * (ASRC_CH_PCT / 100.0) / 2.0;
   s.ch_up = s.ch_mid + half;
   s.ch_lo = s.ch_mid - half;
   s.in_channel = (s.open >= s.ch_lo && s.open <= s.ch_up);

   if(shift + 1 <= Bars(_Symbol, PERIOD_M5) - 1)
   {
      const datetime t1 = iTime(_Symbol, PERIOD_M5, shift + 1);
      const double c1 = iClose(_Symbol, PERIOD_M5, shift + 1);
      double mid1;
      if(ASRC_CopyAtTime(g_asrc_h_ch, PERIOD_M15, t1, mid1))
      {
         const double half1 = c1 * (ASRC_CH_PCT / 100.0) / 2.0;
         if(c1 > mid1 + half1 && s.close > s.ch_up)
         {
            g_asrc_bias_l = true;
            g_asrc_bias_s = false;
         }
         if(c1 < mid1 - half1 && s.close < s.ch_lo)
         {
            g_asrc_bias_s = true;
            g_asrc_bias_l = false;
         }
      }
   }
   s.bias_long  = g_asrc_bias_l;
   s.bias_short = g_asrc_bias_s;

   s.ema_buy  = (s.close > s.ema21);
   s.ema_sell = (s.close < s.ema21);
   s.ht_buy   = (s.close > s.ht_ema);
   s.ht_sell  = (s.close < s.ht_ema);
   s.rsi_buy  = (s.rsi <= 70.0);
   s.rsi_sell = (s.rsi >= 30.0);
   s.low_vol  = (s.bb_width < ASRC_BB_THR);

   s.sqz = ASRC_Squeeze(shift);
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
   ASRC_NyStamp(s.bar_time, ny);
   s.friday = (ny.day_of_week == 5);
   s.monday = (ny.day_of_week == 1);
   s.asia   = (ny.hour >= 20 || ny.hour < 4);
   const int mins = ny.hour * 60 + ny.min;
   s.no_trade = (mins >= (16 * 60 + 45) && mins <= (19 * 60 + 5));
   s.session_reset = ((ny.hour == 9 && ny.min == 30)
                      || (ny.hour == 20 && ny.min == 0)
                      || (ny.hour == 3 && ny.min == 30));
   s.eod = (ny.hour == 17 && ny.min == 0);
   s.valid = true;
   return true;
}

string ASRC_Line(const ASRCSnap &s)
{
   string bias = "flat";
   if(s.bias_long)
      bias = "LONG";
   if(s.bias_short)
      bias = "SHORT";
   return "ch " + DoubleToString(s.ch_lo, _Digits) + ".." + DoubleToString(s.ch_up, _Digits)
          + " bias=" + bias
          + (s.in_channel ? " in" : " out")
          + " ema21=" + (s.ema_buy ? "buy" : "sell")
          + " ht=" + (s.ht_buy ? "buy" : "sell")
          + " rsi=" + DoubleToString(s.rsi, 1)
          + " bbw=" + DoubleToString(s.bb_width, 4)
          + (s.low_vol ? " LOWVOL" : "")
          + (s.friday ? " FRI" : "")
          + (s.monday ? " MON" : "")
          + (s.asia ? " ASIA" : "")
          + (s.no_trade ? " NT" : "");
}

#endif
