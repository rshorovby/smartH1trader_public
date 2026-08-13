#property copyright   "rshorovby"
#property link        "https://github.com/rshorovby/smartH1trader_public"
#property version     "0.40"
#property description "Personal XAUUSD H1 EA. Vegas shadow with 0.5% risk and daily halt; no broker orders."

#include "../Include/SHT_Config.mqh"
#include "../Include/SHT_Log.mqh"
#include "../Include/SHT_Vegas.mqh"
#include "../Include/SHT_Risk.mqh"
#include "../Include/SHT_Engine.mqh"

input group "Safety"
input string          InpAllowedSymbol  = "XAUUSD";
input ENUM_TIMEFRAMES InpAllowedTF      = PERIOD_H1;
input long            InpMagic          = 26081301;
input bool            InpEnableTrading  = false;   // v0.40 still never sends orders
input bool            InpLogToFile      = true;

input group "Risk"
input double          InpRiskPct        = 0.5;     // percent of equity per trade
input double          InpDailyHaltPct   = 2.0;     // halt new entries (buffer under FP daily DD)

datetime g_last_bar    = 0;
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
      + "trading " + (InpEnableTrading ? "ON" : "OFF") + "  orders blocked\n"
      + extra
   );
}

int OnInit()
{
   g_sht_log_file = InpLogToFile;
   g_last_bar     = 0;
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

   if(InpEnableTrading)
      SHT_Warn("InpEnableTrading=true but v0.40 is shadow-only — orders stay blocked");

   g_chart_ok = true;
   SHT_PaintComment("waiting for indicator warmup, then history replay");
   SHT_Info("vegas handles ready — shadow engine, no OrderSend");
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
      SHTVegasSnap snap;
      if(SHT_VegasRead(snap, 1))
         SHT_PaintComment(SHT_EngineComment(snap));
      return;
   }

   const datetime bar_time = iTime(_Symbol, InpAllowedTF, 0);
   if(bar_time == 0 || bar_time == g_last_bar)
      return;
   g_last_bar = bar_time;

   // The bar that just closed is shift 1 — same closed-bar logic as the backtest.
   if(!SHT_EngineOnBar(1, false))
   {
      SHT_Warn("engine bar failed " + TimeToString(iTime(_Symbol, InpAllowedTF, 1),
                                                   TIME_DATE | TIME_MINUTES));
      return;
   }

   SHTVegasSnap snap;
   if(!SHT_VegasRead(snap, 1))
      return;
   SHT_PaintComment(SHT_EngineComment(snap));
   SHT_Info("bar " + TimeToString(iTime(_Symbol, InpAllowedTF, 1), TIME_DATE | TIME_MINUTES)
            + " " + SHT_VegasLine(snap)
            + " armL=" + IntegerToString(g_long_state)
            + " armS=" + IntegerToString(g_short_state)
            + " pos=" + (g_pos_on ? (g_pos_side > 0 ? "L" : "S") : "flat"));
}
