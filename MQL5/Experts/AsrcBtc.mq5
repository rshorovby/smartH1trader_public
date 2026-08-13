#property copyright   "rshorovby"
#property link        "https://github.com/rshorovby/smartH1trader_public"
#property version     "0.30"
#property description "Personal BTCUSD M5 EA. ASRC shadow entries; no broker orders."

#include "../Include/ASRC_Config.mqh"
#include "../Include/SHT_Log.mqh"
#include "../Include/ASRC_Channel.mqh"
#include "../Include/ASRC_Engine.mqh"

input group "Safety"
input string          InpAllowedSymbol  = "BTCUSD";
input ENUM_TIMEFRAMES InpAllowedTF      = PERIOD_M5;
input long            InpMagic          = 26081302;
input bool            InpEnableTrading  = false;   // v0.30 never sends orders
input bool            InpLogToFile      = true;

datetime g_last_bar    = 0;
datetime g_last_ui     = 0;
bool     g_chart_ok    = false;
bool     g_replay_done = false;

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
      + "trading OFF  orders blocked\n"
      + extra
   );
}

void ASRC_RefreshComment()
{
   ASRCSnap snap;
   if(ASRC_Read(snap, 1))
   {
      ASRC_DrawChannel(snap.ch_up, snap.ch_lo);
      ASRC_Paint(ASRC_EngineComment(snap));
   }
   g_last_ui = TimeCurrent();
}

int OnInit()
{
   g_sht_log_file = InpLogToFile;
   g_sht_log_name = ASRC_LOG_FILE;
   g_last_bar     = 0;
   g_last_ui      = 0;
   g_chart_ok     = false;
   g_replay_done  = false;
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
      SHT_Warn("InpEnableTrading=true but v0.30 has no OrderSend - shadow only");

   g_chart_ok = true;
   ASRC_Paint("handles created, waiting for M15/H1 warmup then replay");
   SHT_Info("ASRC shadow engine ready - engulf/pin, SL channel+/-500 ticks, TP 3R, EOD 17:00 NY");
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

   if(!ASRC_Ready())
   {
      ASRC_Paint("warmup M5=" + IntegerToString(Bars(_Symbol, PERIOD_M5))
                 + " M15=" + IntegerToString(Bars(_Symbol, PERIOD_M15))
                 + " H1=" + IntegerToString(Bars(_Symbol, PERIOD_H1)));
      return;
   }

   if(!g_replay_done)
   {
      ASRC_EngineReplay();
      g_replay_done = true;
      g_last_bar = iTime(_Symbol, InpAllowedTF, 0);
      ASRC_RefreshComment();
      return;
   }

   const datetime bar_time = iTime(_Symbol, InpAllowedTF, 0);
   if(bar_time != 0 && bar_time != g_last_bar)
   {
      g_last_bar = bar_time;
      if(!ASRC_EngineOnBar(1, false))
      {
         SHT_Warn("engine bar failed " + TimeToString(iTime(_Symbol, InpAllowedTF, 1),
                                                      TIME_DATE | TIME_MINUTES));
         return;
      }
      ASRC_RefreshComment();
      return;
   }

   if(TimeCurrent() - g_last_ui >= 15)
      ASRC_RefreshComment();
}
