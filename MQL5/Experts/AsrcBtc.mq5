#property copyright   "rshorovby"
#property link        "https://github.com/rshorovby/smartH1trader_public"
#property version     "0.60"
#property description "Personal BTCUSD M5 EA. ASRC live orders behind InpEnableTrading."

#include "../Include/ASRC_Config.mqh"
#include "../Include/SHT_Log.mqh"
#include "../Include/SHT_Risk.mqh"
#include "../Include/SHT_News.mqh"
#include "../Include/SHT_Exec.mqh"
#include "../Include/ASRC_Channel.mqh"
#include "../Include/ASRC_Engine.mqh"

input group "Safety"
input string          InpAllowedSymbol  = "BTCUSD";
input ENUM_TIMEFRAMES InpAllowedTF      = PERIOD_M5;
input long            InpMagic          = 26081302;
input bool            InpEnableTrading  = false;   // true = real orders (SL on broker)
input bool            InpLogToFile      = true;
input int             InpDeviation      = 500;     // max slippage in points (BTC point is 0.01)

input group "Risk"
input double          InpRiskPct        = 0.5;     // percent of equity per leg
input double          InpDailyHaltPct   = 2.0;     // halt new entries (local to this EA)

input group "News"
input bool            InpNewsFilter     = true;
input int             InpNewsBufferMin  = 7;       // minutes each side of red USD (FP is 5)
input int             InpNewsHoldHours  = 5;       // FP swing exception: hold if opened this long before

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
      + "trading " + (g_live ? "LIVE" : "OFF") + "\n"
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

   if(InpRiskPct <= 0.0 || InpRiskPct > 2.0)
   {
      SHT_Error("InpRiskPct must be in (0, 2]");
      return INIT_FAILED;
   }
   if(InpDailyHaltPct < InpRiskPct)
   {
      SHT_Error("InpDailyHaltPct must be >= InpRiskPct");
      return INIT_FAILED;
   }
   g_risk_pct       = InpRiskPct / 100.0;
   g_daily_halt_pct = InpDailyHaltPct / 100.0;

   if(InpNewsBufferMin < 6 || InpNewsBufferMin > 15)
   {
      SHT_Error("InpNewsBufferMin must be 6-15 (FP rule is +/-5; we keep extra buffer)");
      return INIT_FAILED;
   }
   if(InpNewsHoldHours < 0 || InpNewsHoldHours > 24)
   {
      SHT_Error("InpNewsHoldHours must be 0-24");
      return INIT_FAILED;
   }
   g_news_enabled    = InpNewsFilter;
   g_news_buffer_sec = InpNewsBufferMin * 60;
   g_news_hold_sec   = InpNewsHoldHours * 3600;

   if(!ASRC_Init(_Symbol))
   {
      SHT_Error("failed to create ASRC indicator handles");
      ASRC_Release();
      return INIT_FAILED;
   }

   SHT_ExecInit(InpMagic, InpDeviation, InpEnableTrading);
   if(g_live && !SHT_ExecAllowed())
   {
      SHT_Error("live trading requested but " + g_risk_why);
      ASRC_Release();
      return INIT_FAILED;
   }
   if(g_live && !SHT_ExecIsHedge())
      SHT_Warn("account is netting — a second same-side ASRC leg will not be sent live");
   if(g_live)
      SHT_Warn("LIVE ORDERS ARMED - broker SL/TP per leg, 0.5% risk, news flatten");
   else
      SHT_Info("shadow mode - set InpEnableTrading=true to send orders");

   g_chart_ok = true;
   ASRC_Paint("handles created, waiting for M15/H1 warmup then replay");
   SHT_Info("ASRC risk " + DoubleToString(InpRiskPct, 2) + "% per leg, local halt -"
            + DoubleToString(InpDailyHaltPct, 1) + "%, news +/-"
            + IntegerToString(InpNewsBufferMin) + "m USD");
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
      ASRC_LiveAfterReplay();
      SHT_NewsPoll();
      ASRC_RefreshComment();
      return;
   }

   SHT_NewsPoll();
   ASRC_LiveTick();

   if(ASRC_OpenCount() > 0)
   {
      const int before = ASRC_OpenCount();
      ASRC_NewsTickFlatten();
      if(ASRC_OpenCount() != before)
         ASRC_RefreshComment();
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
      SHT_Info("bar " + TimeToString(iTime(_Symbol, InpAllowedTF, 1), TIME_DATE | TIME_MINUTES)
               + " open=" + IntegerToString(ASRC_OpenCount())
               + " " + SHT_NewsLine());
      ASRC_RefreshComment();
      return;
   }

   if(TimeCurrent() - g_last_ui >= 15)
      ASRC_RefreshComment();
}
