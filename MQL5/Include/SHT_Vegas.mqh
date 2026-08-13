#ifndef SHT_VEGAS_MQH
#define SHT_VEGAS_MQH

// Vegas Channel Tunnel v1.1 indicator layer. No entries in this module.
#define SHT_EMA_TRIG   8
#define SHT_EMA_TF     55
#define SHT_EMA_TS     89
#define SHT_EMA_MF     576
#define SHT_EMA_MS     676
#define SHT_ATR_LEN    14
#define SHT_ADX_LEN    14
#define SHT_SLOPE_LEN  20
#define SHT_ADX_TH     25.0
#define SHT_WARMUP     (SHT_EMA_MS + SHT_SLOPE_LEN + 5)

struct SHTVegasSnap
{
   double ema_trig;
   double ema_tf;
   double ema_ts;
   double ema_mf;
   double ema_ms;
   double tunnel_up;
   double tunnel_lo;
   double macro_up;
   double macro_lo;
   double atr;
   double adx;
   bool   macro_rising;
   bool   strong;
   bool   strong_up;
   bool   strong_dn;
   bool   valid;
};

int g_h_trig = INVALID_HANDLE;
int g_h_tf   = INVALID_HANDLE;
int g_h_ts   = INVALID_HANDLE;
int g_h_mf   = INVALID_HANDLE;
int g_h_ms   = INVALID_HANDLE;
int g_h_atr  = INVALID_HANDLE;
int g_h_adx  = INVALID_HANDLE;

bool SHT_CopyAt(const int handle, const int buffer, const int shift, double &out)
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

bool SHT_VegasInit(const string symbol, const ENUM_TIMEFRAMES tf)
{
   g_h_trig = iMA(symbol, tf, SHT_EMA_TRIG, 0, MODE_EMA, PRICE_CLOSE);
   g_h_tf   = iMA(symbol, tf, SHT_EMA_TF,   0, MODE_EMA, PRICE_CLOSE);
   g_h_ts   = iMA(symbol, tf, SHT_EMA_TS,   0, MODE_EMA, PRICE_CLOSE);
   g_h_mf   = iMA(symbol, tf, SHT_EMA_MF,   0, MODE_EMA, PRICE_CLOSE);
   g_h_ms   = iMA(symbol, tf, SHT_EMA_MS,   0, MODE_EMA, PRICE_CLOSE);
   g_h_atr  = iATR(symbol, tf, SHT_ATR_LEN);
   g_h_adx  = iADX(symbol, tf, SHT_ADX_LEN);

   if(g_h_trig == INVALID_HANDLE || g_h_tf == INVALID_HANDLE || g_h_ts == INVALID_HANDLE
      || g_h_mf == INVALID_HANDLE || g_h_ms == INVALID_HANDLE
      || g_h_atr == INVALID_HANDLE || g_h_adx == INVALID_HANDLE)
      return false;
   return true;
}

void SHT_VegasRelease()
{
   if(g_h_trig != INVALID_HANDLE) IndicatorRelease(g_h_trig);
   if(g_h_tf   != INVALID_HANDLE) IndicatorRelease(g_h_tf);
   if(g_h_ts   != INVALID_HANDLE) IndicatorRelease(g_h_ts);
   if(g_h_mf   != INVALID_HANDLE) IndicatorRelease(g_h_mf);
   if(g_h_ms   != INVALID_HANDLE) IndicatorRelease(g_h_ms);
   if(g_h_atr  != INVALID_HANDLE) IndicatorRelease(g_h_atr);
   if(g_h_adx  != INVALID_HANDLE) IndicatorRelease(g_h_adx);
   g_h_trig = g_h_tf = g_h_ts = g_h_mf = g_h_ms = g_h_atr = g_h_adx = INVALID_HANDLE;
}

bool SHT_VegasReady()
{
   const int need = SHT_WARMUP;
   return (
      BarsCalculated(g_h_trig) >= need &&
      BarsCalculated(g_h_tf)   >= need &&
      BarsCalculated(g_h_ts)   >= need &&
      BarsCalculated(g_h_mf)   >= need &&
      BarsCalculated(g_h_ms)   >= need &&
      BarsCalculated(g_h_atr)  >= SHT_ATR_LEN &&
      BarsCalculated(g_h_adx)  >= SHT_ADX_LEN
   );
}

bool SHT_VegasRead(SHTVegasSnap &s, const int shift)
{
   s.valid = false;

   if(!SHT_CopyAt(g_h_trig, 0, shift, s.ema_trig)) return false;
   if(!SHT_CopyAt(g_h_tf,   0, shift, s.ema_tf))   return false;
   if(!SHT_CopyAt(g_h_ts,   0, shift, s.ema_ts))   return false;
   if(!SHT_CopyAt(g_h_ms,   0, shift, s.ema_ms))   return false;
   if(!SHT_CopyAt(g_h_atr,  0, shift, s.atr))      return false;
   if(!SHT_CopyAt(g_h_adx,  0, shift, s.adx))      return false;

   double mf[];
   ArraySetAsSeries(mf, true);
   if(CopyBuffer(g_h_mf, 0, shift, SHT_SLOPE_LEN + 1, mf) < SHT_SLOPE_LEN + 1)
      return false;
   if(mf[0] == EMPTY_VALUE || mf[SHT_SLOPE_LEN] == EMPTY_VALUE)
      return false;
   s.ema_mf = mf[0];
   s.macro_rising = (mf[0] > mf[SHT_SLOPE_LEN]);

   s.tunnel_up = MathMax(s.ema_tf, s.ema_ts);
   s.tunnel_lo = MathMin(s.ema_tf, s.ema_ts);
   s.macro_up  = MathMax(s.ema_mf, s.ema_ms);
   s.macro_lo  = MathMin(s.ema_mf, s.ema_ms);
   s.strong    = (s.adx >= SHT_ADX_TH);
   s.strong_up = s.strong && s.macro_rising;
   s.strong_dn = s.strong && !s.macro_rising;
   s.valid     = (s.atr > 0.0);
   return s.valid;
}

string SHT_VegasLine(const SHTVegasSnap &s)
{
   return "ema8=" + DoubleToString(s.ema_trig, _Digits)
          + " tun=" + DoubleToString(s.tunnel_lo, _Digits)
          + ".." + DoubleToString(s.tunnel_up, _Digits)
          + " mac=" + DoubleToString(s.macro_lo, _Digits)
          + ".." + DoubleToString(s.macro_up, _Digits)
          + " atr=" + DoubleToString(s.atr, _Digits)
          + " adx=" + DoubleToString(s.adx, 1)
          + " slope=" + (s.macro_rising ? "up" : "dn")
          + (s.strong_up ? " strong_up" : "")
          + (s.strong_dn ? " strong_dn" : "");
}

#endif
