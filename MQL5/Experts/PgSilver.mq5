#property copyright   "rshorovby"
#property link        "https://github.com/rshorovby/smartH1trader_public"
#property version     "1.00"
#property description "Personal XAGUSD H1 EA. PG Silver Long V6; live orders behind InpEnableTrading."

#include "../Include/PG_Config.mqh"
#include "../Include/SHT_Log.mqh"
#include "../Include/SHT_Risk.mqh"
#include "../Include/SHT_News.mqh"
#include "../Include/SHT_Exec.mqh"
#include "../Include/PG_Engine.mqh"

input group "Safety"
input string          InpAllowedSymbol  = "XAG";
input ENUM_TIMEFRAMES InpAllowedTF      = PERIOD_H1;
input long            InpMagic          = 26081704;
input bool            InpEnableTrading  = false;   // true = real orders (SL on broker)
input bool            InpLogToFile      = true;
input int             InpDeviation      = 80;      // max slippage in points (XAG point often 0.001)

input group "Risk"
input double          InpRiskPct        = 0.5;     // percent of equity per trade
input double          InpDailyHaltPct   = 2.0;     // halt NEW entries only; no profit cap

input group "News"
input bool            InpNewsFilter     = true;
input int             InpNewsBufferMin  = 7;       // minutes each side of red USD (FP is 5)
input int             InpNewsHoldHours  = 5;       // hold through news if opened this long before

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

void PG_Paint(const string extra)
{
   Comment(
      "PgSilver " + PG_VERSION + "\n"
      + "symbol " + _Symbol + "  " + EnumToString((ENUM_TIMEFRAMES)_Period) + "\n"
      + "trading " + (g_live ? "LIVE" : "OFF") + "\n"
      + extra
   );
}

void PG_RefreshComment()
{
   PG_LevelsDraw();
   PG_Paint(PG_EngineComment());
   g_last_ui = TimeCurrent();
}

int OnInit()
{
   g_sht_log_file = InpLogToFile;
   g_sht_log_name = PG_LOG_FILE;
   g_last_bar     = 0;
   g_last_ui      = 0;
   g_chart_ok     = false;
   g_replay_done  = false;
   Comment("");

   SHT_Info("PgSilver " + PG_VERSION + " init"
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

   SHT_ExecInit(InpMagic, InpDeviation, InpEnableTrading);
   if(g_live && !SHT_ExecAllowed())
   {
      SHT_Error("live trading requested but " + g_risk_why);
      return INIT_FAILED;
   }
   if(g_live)
      SHT_Warn("LIVE ORDERS ARMED - XAG long-only, broker SL 1.5%, trail +0.5%/0.5%, news flatten, NO Friday flatten");
   else
      SHT_Info("shadow mode - set InpEnableTrading=true to send orders");

   g_chart_ok = true;
   PG_Paint("waiting for H1/M30 bars, then history replay");
   SHT_Info("PG Silver risk " + DoubleToString(InpRiskPct, 2) + "% per trade, local halt -"
            + DoubleToString(InpDailyHaltPct, 1) + "%, news +/-"
            + IntegerToString(InpNewsBufferMin) + "m USD, no profit cap, no weekend flatten");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   Comment("");
   SHT_Info("PgSilver deinit reason=" + IntegerToString(reason));
}

void OnTick()
{
   if(!g_chart_ok)
      return;

   if(!PG_Ready())
   {
      PG_Paint("warmup H1=" + IntegerToString(Bars(_Symbol, PERIOD_H1))
               + " M30=" + IntegerToString(Bars(_Symbol, PERIOD_M30)));
      return;
   }

   if(!g_replay_done)
   {
      PG_EngineReplay();
      g_replay_done = true;
      g_last_bar = iTime(_Symbol, InpAllowedTF, 0);
      PG_LiveAfterReplay();
      SHT_NewsPoll();
      PG_RefreshComment();
      return;
   }

   SHT_NewsPoll();
   PG_LiveTick();

   if(g_pg_pos)
      PG_NewsTickFlatten();

   const datetime bar_time = iTime(_Symbol, InpAllowedTF, 0);
   if(bar_time != 0 && bar_time != g_last_bar)
   {
      g_last_bar = bar_time;
      if(!PG_EngineOnBar(1, false))
      {
         SHT_Warn("engine bar failed " + TimeToString(iTime(_Symbol, InpAllowedTF, 1),
                                                      TIME_DATE | TIME_MINUTES));
         return;
      }
      SHT_Info("bar " + TimeToString(iTime(_Symbol, InpAllowedTF, 1), TIME_DATE | TIME_MINUTES)
               + " pos=" + (g_pg_pos ? "1" : "0")
               + " sig=" + (g_pg_last_sig ? "on" : "off")
               + " " + SHT_NewsLine());
      PG_RefreshComment();
      return;
   }

   if(TimeCurrent() - g_last_ui >= 15)
      PG_RefreshComment();
}
