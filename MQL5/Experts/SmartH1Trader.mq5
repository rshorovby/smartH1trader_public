#property copyright   "rshorovby"
#property link        "https://github.com/rshorovby/smartH1trader_public"
#property version     "0.2.0"
#property description "Personal XAUUSD H1 EA. Vegas indicators live; no orders yet."

#include "../Include/SHT_Config.mqh"
#include "../Include/SHT_Log.mqh"
#include "../Include/SHT_Vegas.mqh"

input group "Safety"
input string          InpAllowedSymbol  = "XAUUSD";
input ENUM_TIMEFRAMES InpAllowedTF      = PERIOD_H1;
input long            InpMagic          = 26081301;
input bool            InpEnableTrading  = false;   // kill switch; v0.2 never sends orders
input bool            InpLogToFile      = true;

datetime g_last_bar = 0;
bool     g_chart_ok = false;

bool SymbolIsAllowed()
{
   // Prefix match so broker suffixes (XAUUSD.r, XAUUSD.s) still pass.
   return (StringFind(_Symbol, InpAllowedSymbol) == 0);
}

bool TimeframeIsAllowed()
{
   return (_Period == InpAllowedTF);
}

void SHT_PaintComment(const string extra)
{
   Comment(
      "SmartH1Trader " + SHT_VERSION + "\n"
      + "symbol " + _Symbol + "  " + EnumToString((ENUM_TIMEFRAMES)_Period) + "\n"
      + "trading " + (InpEnableTrading ? "ON" : "OFF") + "  orders blocked\n"
      + extra
   );
}

int OnInit()
{
   g_sht_log_file = InpLogToFile;
   g_last_bar     = 0;
   g_chart_ok     = false;
   Comment("");

   SHT_Info("SmartH1Trader " + SHT_VERSION + " init"
            + " symbol=" + _Symbol
            + " tf=" + EnumToString((ENUM_TIMEFRAMES)_Period)
            + " magic=" + IntegerToString(InpMagic)
            + " trading=" + (InpEnableTrading ? "ON" : "OFF"));

   if(!SymbolIsAllowed())
   {
      SHT_Error("refusing chart " + _Symbol + " — allowed prefix is " + InpAllowedSymbol);
      return INIT_FAILED;
   }

   if(!TimeframeIsAllowed())
   {
      SHT_Error("refusing timeframe " + EnumToString((ENUM_TIMEFRAMES)_Period)
                + " — attach on " + EnumToString(InpAllowedTF));
      return INIT_FAILED;
   }

   if(!SHT_VegasInit(_Symbol, InpAllowedTF))
   {
      SHT_Error("failed to create Vegas indicator handles");
      SHT_VegasRelease();
      return INIT_FAILED;
   }

   if(InpEnableTrading)
      SHT_Warn("InpEnableTrading=true but v0.2 has no entries — orders stay blocked");

   g_chart_ok = true;
   SHT_PaintComment("vegas handles created, waiting for warmup");
   SHT_Info("vegas handles ready: EMA 8/55/89/576/676 ATR14 ADX14 — no OrderSend");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   Comment("");
   SHT_VegasRelease();
   SHT_Info("deinit reason=" + IntegerToString(reason));
}

void OnTick()
{
   if(!g_chart_ok)
      return;

   const datetime bar_time = iTime(_Symbol, InpAllowedTF, 0);
   if(bar_time == 0 || bar_time == g_last_bar)
      return;
   g_last_bar = bar_time;

   if(!SHT_VegasReady())
   {
      const int have = Bars(_Symbol, InpAllowedTF);
      SHT_Warn("vegas warmup bars=" + IntegerToString(have) + " need>=" + IntegerToString(SHT_WARMUP));
      SHT_PaintComment("warmup bars=" + IntegerToString(have) + " need>=" + IntegerToString(SHT_WARMUP));
      return;
   }

   SHTVegasSnap snap;
   if(!SHT_VegasRead(snap))
   {
      SHT_Warn("vegas read failed on " + TimeToString(bar_time, TIME_DATE | TIME_MINUTES));
      SHT_PaintComment("vegas read failed");
      return;
   }

   const string line = SHT_VegasLine(snap);
   SHT_PaintComment(line);
   SHT_Info("vegas " + TimeToString(bar_time, TIME_DATE | TIME_MINUTES) + " " + line);
}
