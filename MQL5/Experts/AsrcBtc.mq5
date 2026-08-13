#property copyright   "rshorovby"
#property link        "https://github.com/rshorovby/smartH1trader_public"
#property version     "0.10"
#property description "Personal BTCUSD M5 EA scaffold (ASRC). No orders until strategy modules land."

#include "../Include/ASRC_Config.mqh"
#include "../Include/SHT_Log.mqh"

input group "Safety"
input string          InpAllowedSymbol  = "BTCUSD";
input ENUM_TIMEFRAMES InpAllowedTF      = PERIOD_M5;
input long            InpMagic          = 26081302;
input bool            InpEnableTrading  = false;   // kill switch; v0.10 never sends orders
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

int OnInit()
{
   g_sht_log_file = InpLogToFile;
   g_sht_log_name = ASRC_LOG_FILE;
   g_last_bar     = 0;
   g_chart_ok     = false;

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

   if(InpEnableTrading)
      SHT_Warn("InpEnableTrading=true but v0.10 has no strategy - orders stay blocked");

   g_chart_ok = true;
   SHT_Info("ASRC scaffold ready: heartbeat on each new M5 bar, OrderSend not compiled in");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
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

   const long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   SHT_Info("heartbeat"
            + " bar=" + TimeToString(bar_time, TIME_DATE | TIME_MINUTES)
            + " bid=" + DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_BID), _Digits)
            + " spread=" + IntegerToString(spread)
            + " equity=" + DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2)
            + " trading=" + (InpEnableTrading ? "ON" : "OFF")
            + " strategy=none");
}
