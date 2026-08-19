#property copyright   "rshorovby"
#property link        "https://github.com/rshorovby/smartH1trader_public"
#property version     "2.00"
#property description "ASRC V2_OPUS. XAGUSD M5, 0.5% per leg / 1.0% per signal."
#property description "Same engine as AsrcBtcV2Opus. Honest XAG backtest is net negative."
#property description "Ships in shadow mode; live orders need the arming phrase."

#include "../Include/AsrcV2Opus/A2_Config.mqh"
#include "../Include/AsrcV2Opus/A2_Log.mqh"
#include "../Include/AsrcV2Opus/A2_Time.mqh"
#include "../Include/AsrcV2Opus/A2_News.mqh"
#include "../Include/AsrcV2Opus/A2_Risk.mqh"
#include "../Include/AsrcV2Opus/A2_Exec.mqh"
#include "../Include/AsrcV2Opus/A2_Channel.mqh"
#include "../Include/AsrcV2Opus/A2_Engine.mqh"

#define A2_XAG_LOG   "AsrcXagV2Opus.log"
#define A2_XAG_CSV   "AsrcXagV2Opus_trades.csv"

input group "Safety"
input string          InpAllowedSymbol = "XAGUSD";
input ENUM_TIMEFRAMES InpAllowedTF     = PERIOD_M5;
input long            InpMagic         = 26081311;
input bool            InpEnableTrading = false;      // true plus the phrase below sends real orders
input string          InpArmPhrase     = "";         // must read exactly: ARM V2 OPUS
input int             InpDeviation     = 200;        // slippage allowance in points (XAG point 0.001)
input double          InpMaxSlipPct    = 0.08;       // reject a fill this far from the signal, percent
input bool            InpLogToFile     = true;

input group "Risk"
input double          InpRiskPct       = 0.5;        // percent of equity per leg
input double          InpTotalRiskPct  = 1.0;        // cap on open risk; two legs of 0.5%
input double          InpDailyHaltPct  = 2.0;        // stop new entries after this daily loss
// Honest XAG sample already prints −5% / 14.5% mtm DD. 12% kill is meant to stop
// a live run before it repeats that path, not to "leave room" for the backtest.
input double          InpKillPct       = 12.0;       // stop new entries this far below peak equity

input group "News"
input bool            InpNewsFilter    = true;
input int             InpNewsBufferMin = 7;          // minutes each side of red USD (FundingPips is 5)
input int             InpNewsHoldHours = 5;          // swing exception: hold if opened this long before

datetime g_last_bar    = 0;
datetime g_last_ui     = 0;
bool     g_chart_ok    = false;
bool     g_replay_done = false;

void A2_Paint(const string extra)
{
   Comment("AsrcXag V2_OPUS " + A2_VERSION + "\n"
           + "symbol " + _Symbol + "  " + EnumToString((ENUM_TIMEFRAMES)_Period) + "\n"
           + "trading " + (g_a2_live ? "LIVE" : "OFF") + "\n"
           + extra);
}

void A2_RefreshComment()
{
   A2Snap s;
   if(A2_Snapshot(1, s))
   {
      A2_DrawChannel(s.ch_up, s.ch_lo);
      A2_Paint(A2_EngineComment(s));
   }
   g_last_ui = TimeCurrent();
}

bool A2_ValidateInputs()
{
   if(StringFind(_Symbol, InpAllowedSymbol) != 0)
   {
      A2_Error("refusing chart " + _Symbol + " — allowed prefix is " + InpAllowedSymbol);
      return false;
   }
   if(_Period != InpAllowedTF)
   {
      A2_Error("refusing timeframe " + EnumToString((ENUM_TIMEFRAMES)_Period)
               + " — attach on " + EnumToString(InpAllowedTF));
      return false;
   }
   if(InpRiskPct <= 0.0 || InpRiskPct > 1.0)
   {
      A2_Error("InpRiskPct must be in (0, 1]");
      return false;
   }
   if(InpTotalRiskPct < InpRiskPct || InpTotalRiskPct > 2.0)
   {
      A2_Error("InpTotalRiskPct must be between InpRiskPct and 2.0");
      return false;
   }
   if(InpDailyHaltPct < InpTotalRiskPct || InpDailyHaltPct > 5.0)
   {
      A2_Error("InpDailyHaltPct must be between InpTotalRiskPct and 5.0");
      return false;
   }
   if(InpKillPct < InpDailyHaltPct || InpKillPct > 20.0)
   {
      A2_Error("InpKillPct must be between InpDailyHaltPct and 20.0");
      return false;
   }
   if(InpMaxSlipPct < 0.0 || InpMaxSlipPct > 1.0)
   {
      A2_Error("InpMaxSlipPct must be in [0, 1]");
      return false;
   }
   if(InpNewsBufferMin < 6 || InpNewsBufferMin > 15)
   {
      A2_Error("InpNewsBufferMin must be 6-15; the FundingPips rule is 5 and we keep a buffer");
      return false;
   }
   if(InpNewsHoldHours < 0 || InpNewsHoldHours > 24)
   {
      A2_Error("InpNewsHoldHours must be 0-24");
      return false;
   }
   return true;
}

bool A2_LiveRequested()
{
   if(!InpEnableTrading)
      return false;
   if(InpArmPhrase != "ARM V2 OPUS")
   {
      A2_Warn("InpEnableTrading is on but the arming phrase is missing — staying in shadow. "
              "Set InpArmPhrase to: ARM V2 OPUS");
      return false;
   }
   return true;
}

int OnInit()
{
   g_a2_log_file = InpLogToFile;
   g_a2_log_name = A2_XAG_LOG;
   g_a2_csv_name = A2_XAG_CSV;
   g_last_bar    = 0;
   g_last_ui     = 0;
   g_chart_ok    = false;
   g_replay_done = false;
   Comment("");

   A2_Info("AsrcXag V2_OPUS " + A2_VERSION + " init symbol=" + _Symbol
           + " tf=" + EnumToString((ENUM_TIMEFRAMES)_Period)
           + " magic=" + IntegerToString(InpMagic));
   A2_Warn("XAG honest sample is net negative (E[R] −0.05, ret −5%). "
           "Do not arm live orders on this symbol.");

   if(!A2_ValidateInputs())
      return INIT_FAILED;

   string why = "";
   if(!A2_TimeVerify(why))
   {
      A2_Error("clock check failed: " + why);
      return INIT_FAILED;
   }
   A2_TimeSelfTest(6000);

   g_a2_news_on       = InpNewsFilter;
   g_a2_news_buf_sec  = InpNewsBufferMin * 60;
   g_a2_news_hold_sec = InpNewsHoldHours * 3600;
   g_a2_max_slip_pct  = InpMaxSlipPct;

   A2_RiskInit(InpRiskPct / 100.0, InpTotalRiskPct / 100.0, InpDailyHaltPct / 100.0,
               InpKillPct / 100.0, InpMagic);
   A2_RiskProbe(SymbolInfoDouble(_Symbol, SYMBOL_BID), 0.002);

   if(!A2_Init(_Symbol))
   {
      A2_Error("failed to create indicator handles");
      A2_Release();
      return INIT_FAILED;
   }

   const bool live = A2_LiveRequested();
   A2_ExecInit(InpMagic, InpDeviation, live);
   if(live && !A2_ExecAllowed())
   {
      A2_Error("live trading requested but " + g_a2_why);
      A2_Release();
      return INIT_FAILED;
   }
   if(live && !A2_ExecIsHedge())
      A2_Warn("account is netting — a second same-side leg will not be sent, "
              "so live risk per signal caps at 0.5% instead of 1.0%");
   if(live)
      A2_Warn("LIVE ORDERS ARMED on XAG — honest backtest is negative. "
              + DoubleToString(InpRiskPct, 2) + "% per leg");
   else
      A2_Info("shadow mode — no OrderSend. Arm with InpEnableTrading and InpArmPhrase.");

   g_chart_ok = true;
   A2_Paint("handles created, waiting for M15/H1 history then replay");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   Comment("");
   A2_Release();
   A2_Info("AsrcXag V2_OPUS deinit reason=" + IntegerToString(reason)
           + " warns=" + IntegerToString(g_a2_warns)
           + " errors=" + IntegerToString(g_a2_errors));
}

void OnTick()
{
   if(!g_chart_ok)
      return;

   string why = "";
   if(!A2_Ready(why))
   {
      A2_Paint("warmup: " + why);
      return;
   }

   if(!g_replay_done)
   {
      A2_EngineReplay();
      g_replay_done = true;
      g_last_bar    = iTime(_Symbol, InpAllowedTF, 0);
      A2_AdoptLive();
      A2_NewsPoll();
      A2_RefreshComment();
      return;
   }

   A2_NewsPoll();
   A2_LiveTick();

   if(A2_OpenCount() > 0)
   {
      const int before = A2_OpenCount();
      A2_NewsTickFlatten();
      if(A2_OpenCount() != before)
         A2_RefreshComment();
   }

   const datetime bar_time = iTime(_Symbol, InpAllowedTF, 0);
   if(bar_time != 0 && bar_time != g_last_bar)
   {
      g_last_bar = bar_time;
      if(!A2_EngineOnBar(1, false))
      {
         A2_Warn("engine could not read bar "
                 + TimeToString(iTime(_Symbol, InpAllowedTF, 1), TIME_DATE | TIME_MINUTES));
         return;
      }
      A2_RefreshComment();
      return;
   }

   if(TimeCurrent() - g_last_ui >= 15)
      A2_RefreshComment();
}
