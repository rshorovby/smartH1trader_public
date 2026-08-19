#property copyright   "rshorovby"
#property link        "https://github.com/rshorovby/smartH1trader_public"
#property version     "0.10"
#property description "Personal NDX M1 EA. 8AM sweep + CISD; live orders behind InpEnableTrading."

#include "../Include/NDX_Config.mqh"
#include "../Include/SHT_Log.mqh"
#include "../Include/SHT_Risk.mqh"
#include "../Include/SHT_News.mqh"
#include "../Include/SHT_Exec.mqh"
#include "../Include/NDX_Engine.mqh"

input group "Safety"
input string          InpAllowedSymbol  = "NDX";
input ENUM_TIMEFRAMES InpAllowedTF      = PERIOD_M1;
input long            InpMagic          = 26081303;
input bool            InpEnableTrading  = false;   // true = real orders (SL/TP on broker)
input bool            InpLogToFile      = true;
input int             InpDeviation      = 30;      // max slippage in points

input group "Risk"
input double          InpRiskPct        = 0.5;     // percent of equity per trade
input double          InpDailyHaltPct   = 2.0;     // halt new entries (local to this EA)
input int             InpMaxTrades      = 3;       // per NY day; shortlist canon is 3

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

void NDX_Paint(const string extra)
{
   Comment(
      "Ndx8amSweep " + NDX_VERSION + "\n"
      + "symbol " + _Symbol + "  " + EnumToString((ENUM_TIMEFRAMES)_Period) + "\n"
      + "trading " + (g_live ? "LIVE" : "OFF") + "\n"
      + extra
   );
}

void NDX_RefreshComment()
{
   NDX_LevelsDraw();
   NDX_Paint(NDX_EngineComment());
   g_last_ui = TimeCurrent();
}

int OnInit()
{
   g_sht_log_file = InpLogToFile;
   g_sht_log_name = NDX_LOG_FILE;
   g_last_bar     = 0;
   g_last_ui      = 0;
   g_chart_ok     = false;
   g_replay_done  = false;
   Comment("");

   SHT_Info("Ndx8amSweep " + NDX_VERSION + " init"
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
   if(InpMaxTrades < 1 || InpMaxTrades > 10)
   {
      SHT_Error("InpMaxTrades must be 1-10 (canon is 3)");
      return INIT_FAILED;
   }
   g_risk_pct       = InpRiskPct / 100.0;
   g_daily_halt_pct = InpDailyHaltPct / 100.0;
   g_ndx_max_tr     = InpMaxTrades;

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

   SHT_ExecInit(InpMagic, InpDeviation, InpEnableTrading);
   if(g_live && !SHT_ExecAllowed())
   {
      SHT_Error("live trading requested but " + g_risk_why);
      return INIT_FAILED;
   }
   if(g_live)
      SHT_Warn("LIVE ORDERS ARMED - broker SL/TP, 0.5% risk, news flatten, 16:00 NY flatten");
   else
      SHT_Info("shadow mode - set InpEnableTrading=true to send orders");

   g_chart_ok = true;
   NDX_Paint("waiting for M1 bars, then history replay");
   SHT_Info("NDX 8AM CISD risk " + DoubleToString(InpRiskPct, 2) + "% per trade, local halt -"
            + DoubleToString(InpDailyHaltPct, 1) + "%, max " + IntegerToString(InpMaxTrades)
            + "/NY day, news +/-" + IntegerToString(InpNewsBufferMin) + "m USD");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   Comment("");
   SHT_Info("Ndx8amSweep deinit reason=" + IntegerToString(reason));
}

void OnTick()
{
   if(!g_chart_ok)
      return;

   if(!NDX_Ready())
   {
      NDX_Paint("warmup M1=" + IntegerToString(Bars(_Symbol, PERIOD_M1))
                + " need>=" + IntegerToString(NDX_WARMUP));
      return;
   }

   if(!g_replay_done)
   {
      NDX_EngineReplay();
      g_replay_done = true;
      g_last_bar = iTime(_Symbol, InpAllowedTF, 0);
      NDX_LiveAfterReplay();
      SHT_NewsPoll();
      NDX_RefreshComment();
      return;
   }

   SHT_NewsPoll();
   NDX_LiveTick();

   if(g_ndx_pos)
   {
      NDX_NewsTickFlatten();
      NDX_EodTickFlatten();
   }

   const datetime bar_time = iTime(_Symbol, InpAllowedTF, 0);
   if(bar_time != 0 && bar_time != g_last_bar)
   {
      g_last_bar = bar_time;
      if(!NDX_EngineOnBar(1, false))
      {
         SHT_Warn("engine bar failed " + TimeToString(iTime(_Symbol, InpAllowedTF, 1),
                                                      TIME_DATE | TIME_MINUTES));
         return;
      }
      SHT_Info("bar " + TimeToString(iTime(_Symbol, InpAllowedTF, 1), TIME_DATE | TIME_MINUTES)
               + " " + NDX_StateLine()
               + " pos=" + (g_ndx_pos ? (g_ndx_side > 0 ? "L" : "S") : "flat")
               + " " + SHT_NewsLine());
      NDX_RefreshComment();
      return;
   }

   if(TimeCurrent() - g_last_ui >= 15)
      NDX_RefreshComment();
}
