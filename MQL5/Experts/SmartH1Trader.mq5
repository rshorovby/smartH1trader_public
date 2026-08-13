#property copyright   "rshorovby"
#property link        "https://github.com/rshorovby/smartH1trader_public"
#property version     "0.60"
#property description "Personal XAUUSD H1 EA. Vegas live orders behind InpEnableTrading."

#include "../Include/SHT_Config.mqh"
#include "../Include/SHT_Log.mqh"
#include "../Include/SHT_Vegas.mqh"
#include "../Include/SHT_Risk.mqh"
#include "../Include/SHT_News.mqh"
#include "../Include/SHT_Exec.mqh"
#include "../Include/SHT_Engine.mqh"

input group "Safety"
input string          InpAllowedSymbol  = "XAUUSD";
input ENUM_TIMEFRAMES InpAllowedTF      = PERIOD_H1;
input long            InpMagic          = 26081301;
input bool            InpEnableTrading  = false;   // true = real orders (SL on broker)
input bool            InpLogToFile      = true;
input int             InpDeviation      = 50;      // max slippage in points

input group "Risk"
input double          InpRiskPct        = 0.5;     // percent of equity per trade
input double          InpDailyHaltPct   = 2.0;     // halt new entries (buffer under FP daily DD)

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

void SHT_PaintComment(const string extra)
{
   Comment(
      "SmartH1Trader " + SHT_VERSION + "\n"
      + "symbol " + _Symbol + "  " + EnumToString((ENUM_TIMEFRAMES)_Period) + "\n"
      + "trading " + (g_live ? "LIVE" : "OFF") + "\n"
      + extra
   );
}

int OnInit()
{
   g_sht_log_file = InpLogToFile;
   g_last_bar     = 0;
   g_last_ui      = 0;
   g_chart_ok     = false;
   g_replay_done  = false;
   Comment("");

   SHT_Info("SmartH1Trader " + SHT_VERSION + " init"
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
                + " — attach on " + EnumToString(InpAllowedTF));
      return INIT_FAILED;
   }

   if(!SHT_VegasInit(_Symbol, InpAllowedTF))
   {
      SHT_Error("failed to create Vegas indicator handles");
      SHT_VegasRelease();
      return INIT_FAILED;
   }

   if(InpRiskPct <= 0.0 || InpRiskPct > 2.0)
   {
      SHT_Error("InpRiskPct must be in (0, 2]");
      SHT_VegasRelease();
      return INIT_FAILED;
   }
   if(InpDailyHaltPct < InpRiskPct)
   {
      SHT_Error("InpDailyHaltPct must be >= InpRiskPct");
      SHT_VegasRelease();
      return INIT_FAILED;
   }
   g_risk_pct       = InpRiskPct / 100.0;
   g_daily_halt_pct = InpDailyHaltPct / 100.0;

   if(InpNewsBufferMin < 6 || InpNewsBufferMin > 15)
   {
      SHT_Error("InpNewsBufferMin must be 6-15 (FP rule is +/-5; we keep extra buffer)");
      SHT_VegasRelease();
      return INIT_FAILED;
   }
   if(InpNewsHoldHours < 0 || InpNewsHoldHours > 24)
   {
      SHT_Error("InpNewsHoldHours must be 0-24");
      SHT_VegasRelease();
      return INIT_FAILED;
   }
   g_news_enabled    = InpNewsFilter;
   g_news_buffer_sec = InpNewsBufferMin * 60;
   g_news_hold_sec   = InpNewsHoldHours * 3600;

   SHT_ExecInit(InpMagic, InpDeviation, InpEnableTrading);
   if(g_live && !SHT_ExecAllowed())
   {
      SHT_Error("live trading requested but " + g_risk_why);
      SHT_VegasRelease();
      return INIT_FAILED;
   }
   if(g_live)
      SHT_Warn("LIVE ORDERS ARMED - broker SL/TP, 0.5% risk, news flatten");
   else
      SHT_Info("shadow mode - set InpEnableTrading=true to send orders");

   g_chart_ok = true;
   SHT_PaintComment("waiting for indicator warmup, then history replay");
   SHT_Info("vegas handles ready");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   Comment("");
   SHT_VegasRelease();
   SHT_Info("deinit reason=" + IntegerToString(reason));
}

void SHT_RefreshComment()
{
   SHTVegasSnap snap;
   if(SHT_VegasRead(snap, 1))
      SHT_PaintComment(SHT_EngineComment(snap));
   g_last_ui = TimeCurrent();
}

void OnTick()
{
   if(!g_chart_ok)
      return;

   if(!SHT_VegasReady())
   {
      const int have = Bars(_Symbol, InpAllowedTF);
      SHT_PaintComment("warmup bars=" + IntegerToString(have) + " need>=" + IntegerToString(SHT_WARMUP));
      return;
   }

   if(!g_replay_done)
   {
      SHT_EngineReplay();
      g_replay_done = true;
      g_last_bar = iTime(_Symbol, InpAllowedTF, 0);
      SHT_LiveAfterReplay();
      SHT_NewsPoll();
      SHT_RefreshComment();
      return;
   }

   SHT_NewsPoll();
   SHT_LiveTick();

   // News window is minutes, not hours — flatten on tick, not on H1 close.
   if(g_pos_on && SHT_NewsShouldFlatten(g_pos_time, TimeCurrent()))
   {
      const double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      SHT_ShadowClose(TimeCurrent(), bid, "news_flatten");
      SHT_RefreshComment();
   }

   const datetime bar_time = iTime(_Symbol, InpAllowedTF, 0);
   if(bar_time != 0 && bar_time != g_last_bar)
   {
      g_last_bar = bar_time;
      if(!SHT_EngineOnBar(1, false))
      {
         SHT_Warn("engine bar failed " + TimeToString(iTime(_Symbol, InpAllowedTF, 1),
                                                      TIME_DATE | TIME_MINUTES));
         return;
      }
      SHT_Info("bar " + TimeToString(iTime(_Symbol, InpAllowedTF, 1), TIME_DATE | TIME_MINUTES)
               + " armL=" + IntegerToString(g_long_state)
               + " armS=" + IntegerToString(g_short_state)
               + " pos=" + (g_pos_on ? (g_pos_side > 0 ? "L" : "S") : "flat")
               + " " + SHT_NewsLine());
      SHT_RefreshComment();
      return;
   }

   if(TimeCurrent() - g_last_ui >= 15)
      SHT_RefreshComment();
}
