#property copyright   "rshorovby"
#property link        "https://github.com/rshorovby/smartH1trader_public"
#property version     "2.00"
#property description "ASRC V2_OPUS. XAUUSD M5, 0.5% per leg / 1.0% per signal."
#property description "Same engine as AsrcBtcV2Opus. Honest XAU sample is the strongest V2 cell."
#property description "Ships in shadow mode; set InpEnableTrading=true for live orders."

#include "../Include/AsrcV2Opus/A2_Config.mqh"
#include "../Include/AsrcV2Opus/A2_Log.mqh"
#include "../Include/AsrcV2Opus/A2_Time.mqh"
#include "../Include/AsrcV2Opus/A2_News.mqh"
#include "../Include/AsrcV2Opus/A2_Risk.mqh"
#include "../Include/AsrcV2Opus/A2_Exec.mqh"
#include "../Include/AsrcV2Opus/A2_Channel.mqh"
#include "../Include/AsrcV2Opus/A2_Engine.mqh"

#define A2_XAU_LOG   "AsrcXauV2Opus.log"
#define A2_XAU_CSV   "AsrcXauV2Opus_trades.csv"

input group "Safety"
input string          InpAllowedSymbol = "XAUUSD";
input ENUM_TIMEFRAMES InpAllowedTF     = PERIOD_M5;
input long            InpMagic         = 26081312;
input bool            InpEnableTrading = false;      // set true to send real orders
input int             InpDeviation     = 400;        // slippage allowance in points (XAU point 0.01)
input double          InpMaxSlipPct    = 0.05;       // reject a fill this far from the signal, percent
input bool            InpLogToFile     = true;

input group "Risk"
input double          InpRiskPct       = 0.5;        // percent of equity per leg
input double          InpTotalRiskPct  = 1.0;        // cap on open risk; two legs of 0.5%
input double          InpDailyHaltPct  = 2.0;        // stop new entries after this daily loss
// Honest XAU sample: realised +32.9%, mtm DD 5.3%, t=2.47. 12% kill sits
// above the measured path and still stops a broken live run.
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
   Comment("AsrcXau V2_OPUS " + A2_VERSION + "\n"
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
   return InpEnableTrading;
}

int OnInit()
{
   g_a2_log_file = InpLogToFile;
   g_a2_log_name = A2_XAU_LOG;
   g_a2_csv_name = A2_XAU_CSV;
   g_last_bar    = 0;
   g_last_ui     = 0;
   g_chart_ok    = false;
   g_replay_done = false;
   Comment("");

   A2_Info("AsrcXau V2_OPUS " + A2_VERSION + " init symbol=" + _Symbol
           + " tf=" + EnumToString((ENUM_TIMEFRAMES)_Period)
           + " magic=" + IntegerToString(InpMagic));
   A2_Info("XAU honest sample: n=229 E[R]=+0.257 t=2.47 ret=+32.9% DD=5.3%. "
           "Strongest V2 cell; still start in shadow.");

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
   // Typical stop is half the channel plus the buffer, so a little under 0.2% of
   // price; the probe reports what the lot step does to that budget.
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
      A2_Warn("LIVE ORDERS ARMED — broker stop and target per leg, "
              + DoubleToString(InpRiskPct, 2) + "% per leg");
   else
      A2_Info("shadow mode — no OrderSend. Set InpEnableTrading=true to arm live orders.");

   g_chart_ok = true;
   A2_Paint("handles created, waiting for M15/H1 history then replay");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   Comment("");
   A2_Release();
   A2_Info("AsrcXau V2_OPUS deinit reason=" + IntegerToString(reason)
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
