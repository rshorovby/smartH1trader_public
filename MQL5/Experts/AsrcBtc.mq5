#property copyright   "rshorovby"
#property link        "https://github.com/rshorovby/smartH1trader_public"
#property version     "0.20"
#property description "Personal BTCUSD M5 EA. ASRC channel/filters live; no orders yet."

#include "../Include/ASRC_Config.mqh"
#include "../Include/SHT_Log.mqh"
#include "../Include/ASRC_Channel.mqh"

input group "Safety"
input string          InpAllowedSymbol  = "BTCUSD";
input ENUM_TIMEFRAMES InpAllowedTF      = PERIOD_M5;
input long            InpMagic          = 26081302;
input bool            InpEnableTrading  = false;   // v0.20 never sends orders
input bool            InpLogToFile      = true;

datetime g_last_bar = 0;
bool     g_chart_ok = false;

bool SymbolIsAllowed()
{
   return (StringFind(_Symbol, InpAllowedSymbol) == 0);
}

bool TimeframeIsAllowed()
{
   return (_Period == InpAllowedTF);
}

void ASRC_Paint(const string extra)
{
   Comment(
      "AsrcBtc " + ASRC_VERSION + "\n"
      + "symbol " + _Symbol + "  " + EnumToString((ENUM_TIMEFRAMES)_Period) + "\n"
      + "trading " + (InpEnableTrading ? "ON" : "OFF") + "  orders blocked\n"
      + extra
   );
}

int OnInit()
{
   g_sht_log_file = InpLogToFile;
   g_sht_log_name = ASRC_LOG_FILE;
   g_last_bar     = 0;
   g_chart_ok     = false;
   Comment("");

   SHT_Info("AsrcBtc " + ASRC_VERSION + " init"
            + " symbol=" + _Symbol
            + " tf=" + EnumToString((ENUM_TIMEFRAMES)_Period)
            + " magic=" + IntegerToString(InpMagic)
            + " trading=" + (InpEnableTrading ? "ON" : "OFF"));

   if(!SymbolIsAllowed())
   {
      SHT_Error("refusing chart " + _Symbol + " - allowed prefix is " + InpAllowedSymbol);
      return INIT_FAILED;
   }

   if(!TimeframeIsAllowed())
   {
      SHT_Error("refusing timeframe " + EnumToString((ENUM_TIMEFRAMES)_Period)
                + " - attach on " + EnumToString(InpAllowedTF));
      return INIT_FAILED;
   }

   if(!ASRC_Init(_Symbol))
   {
      SHT_Error("failed to create ASRC indicator handles");
      ASRC_Release();
      return INIT_FAILED;
   }

   if(InpEnableTrading)
      SHT_Warn("InpEnableTrading=true but v0.20 has no entries - orders stay blocked");

   g_chart_ok = true;
   ASRC_Paint("handles created, waiting for M15/H1 warmup");
   SHT_Info("ASRC handles ready: M15 EMA36 channel, M5 EMA21/RSI/BB, H1 EMA55 - no OrderSend");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   Comment("");
   ASRC_Release();
   SHT_Info("AsrcBtc deinit reason=" + IntegerToString(reason));
}

void OnTick()
{
   if(!g_chart_ok)
      return;

   const datetime bar_time = iTime(_Symbol, InpAllowedTF, 0);
   if(bar_time == 0 || bar_time == g_last_bar)
      return;
   g_last_bar = bar_time;

   if(!ASRC_Ready())
   {
      ASRC_Paint("warmup M5=" + IntegerToString(Bars(_Symbol, PERIOD_M5))
                 + " M15=" + IntegerToString(Bars(_Symbol, PERIOD_M15))
                 + " H1=" + IntegerToString(Bars(_Symbol, PERIOD_H1)));
      return;
   }

   ASRCSnap snap;
   if(!ASRC_Read(snap, 1))
   {
      SHT_Warn("ASRC read failed");
      ASRC_Paint("channel read failed - need M15/H1 history");
      return;
   }

   ASRC_DrawChannel(snap.ch_up, snap.ch_lo);
   const string line = ASRC_Line(snap);
   ASRC_Paint(line);
   SHT_Info("asrc " + TimeToString(snap.bar_time, TIME_DATE | TIME_MINUTES) + " " + line);
}
