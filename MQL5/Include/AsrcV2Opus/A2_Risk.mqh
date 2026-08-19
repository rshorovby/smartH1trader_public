#ifndef A2_RISK_MQH
#define A2_RISK_MQH

#include "A2_Config.mqh"
#include "A2_Log.mqh"
#include "A2_Time.mqh"

// Sizing and the loss brakes.
//
// v1 sized from SYMBOL_TRADE_TICK_VALUE and never checked the money it had
// actually put at risk. A safer OrderCalcProfit path existed in the repo but was
// wired to nothing and was not deployed. Here the verified path is the only path,
// and it runs the same way in shadow, replay and live, so a lot size can never
// differ between what was tested and what is sent.
//
// Three independent brakes, in order of how quickly they bite:
//   per leg      — 0.5% of equity, verified against the broker's own money maths;
//   per session  — the total of open leg risk may not exceed 1.0% of equity;
//   per day      — new entries stop after the daily loss limit, realised plus
//                  floating, on the New York 17:00 day boundary;
//   per account  — a peak-to-trough kill switch that survives a restart, because
//                  the peak lives in a terminal global variable.

double   g_a2_risk_pct     = 0.005;
double   g_a2_total_pct    = 0.010;
double   g_a2_halt_pct     = 0.020;
double   g_a2_kill_pct     = 0.060;
datetime g_a2_risk_day     = 0;
double   g_a2_day_start_eq = 0.0;
double   g_a2_day_pnl      = 0.0;
int      g_a2_day_skips    = 0;
string   g_a2_why          = "";
string   g_a2_peak_key     = "A2_PEAK_EQ";
bool     g_a2_killed       = false;

double A2_Equity()
{
   return AccountInfoDouble(ACCOUNT_EQUITY);
}

void A2_RiskInit(const double risk_pct, const double total_pct, const double halt_pct,
                 const double kill_pct, const long magic)
{
   g_a2_risk_pct  = risk_pct;
   g_a2_total_pct = total_pct;
   g_a2_halt_pct  = halt_pct;
   g_a2_kill_pct  = kill_pct;
   g_a2_peak_key  = "A2_PEAK_EQ_" + IntegerToString(magic);
   g_a2_killed    = false;

   const double eq = A2_Equity();
   if(!GlobalVariableCheck(g_a2_peak_key) || GlobalVariableGet(g_a2_peak_key) <= 0.0)
      GlobalVariableSet(g_a2_peak_key, eq);
   A2_Info("risk " + DoubleToString(risk_pct * 100.0, 2) + "%/leg, cap "
           + DoubleToString(total_pct * 100.0, 2) + "% open, halt "
           + DoubleToString(halt_pct * 100.0, 2) + "%/day, kill "
           + DoubleToString(kill_pct * 100.0, 2) + "% from peak "
           + DoubleToString(GlobalVariableGet(g_a2_peak_key), 2));
}

double A2_NormalizeLots(double lots)
{
   const double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   const double vmax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   const double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0 || vmin <= 0.0)
      return 0.0;
   lots = MathFloor(lots / step + 1e-8) * step;
   if(lots > vmax)
      lots = vmax;
   if(lots < vmin - 1e-12)
      return 0.0;
   int digits = 2;
   if(step < 0.01 - 1e-12)
      digits = 3;
   return NormalizeDouble(lots, digits);
}

// Money lost if this many lots ran from entry to sl, as the broker computes it.
double A2_LossForLots(const int side, const double lots, const double entry, const double sl)
{
   if(lots <= 0.0 || entry <= 0.0 || sl <= 0.0)
      return 0.0;
   double profit = 0.0;
   const ENUM_ORDER_TYPE typ = (side > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   if(!OrderCalcProfit(typ, _Symbol, lots, entry, sl, profit))
      return 0.0;
   return MathMax(0.0, -profit);
}

// OrderCalcProfit is linear in volume, so one probe gives the exact scale; the
// loop below only trims for lot-step rounding.
double A2_LotsForRisk(const int side, const double entry, const double sl,
                      const double risk_money)
{
   const double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   const double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(vmin <= 0.0 || step <= 0.0 || risk_money <= 0.0 || entry <= 0.0 || sl <= 0.0)
   {
      g_a2_why = "no volume step or no risk budget";
      return 0.0;
   }

   const double unit = A2_LossForLots(side, vmin, entry, sl) / vmin;
   if(unit <= 0.0)
   {
      g_a2_why = "OrderCalcProfit gave no loss for the stop distance";
      return 0.0;
   }

   double lots = A2_NormalizeLots(risk_money / unit);
   for(int i = 0; i < 8 && lots > 0.0; i++)
   {
      if(A2_LossForLots(side, lots, entry, sl) <= risk_money + 0.01)
         break;
      lots = A2_NormalizeLots(lots - step);
   }
   if(lots <= 0.0)
   {
      g_a2_why = "min lot risks " + DoubleToString(A2_LossForLots(side, vmin, entry, sl), 2)
                 + " > budget " + DoubleToString(risk_money, 2);
      return 0.0;
   }
   return lots;
}

void A2_RiskResetDay(const datetime t)
{
   g_a2_risk_day     = A2_DayStamp(t);
   g_a2_day_start_eq = A2_Equity();
   g_a2_day_pnl      = 0.0;
   g_a2_day_skips    = 0;
   g_a2_why          = "";
}

void A2_RiskOnBar(const datetime t)
{
   if(A2_DayStamp(t) != g_a2_risk_day)
      A2_RiskResetDay(t);
}

void A2_RiskAddPnl(const double money)
{
   g_a2_day_pnl += money;
}

double A2_RiskDayPct(const double floating)
{
   if(g_a2_day_start_eq <= 0.0)
      return 0.0;
   return (g_a2_day_pnl + floating) / g_a2_day_start_eq * 100.0;
}

bool A2_RiskHalted(const double floating)
{
   if(g_a2_day_start_eq <= 0.0)
      return false;
   const double loss = -(g_a2_day_pnl + floating) / g_a2_day_start_eq;
   if(loss >= g_a2_halt_pct - 1e-12)
   {
      g_a2_why = "daily halt " + DoubleToString(loss * 100.0, 2) + "%";
      return true;
   }
   return false;
}

// Peak survives restarts so the kill switch cannot be reset by reloading the EA.
bool A2_RiskKilled(const double floating)
{
   const double eq = A2_Equity() + floating;
   double peak = GlobalVariableCheck(g_a2_peak_key) ? GlobalVariableGet(g_a2_peak_key) : eq;
   if(eq > peak)
   {
      peak = eq;
      GlobalVariableSet(g_a2_peak_key, peak);
   }
   if(peak <= 0.0)
      return false;
   const double dd = (peak - eq) / peak;
   if(dd >= g_a2_kill_pct - 1e-12)
   {
      g_a2_why = "kill switch: " + DoubleToString(dd * 100.0, 2) + "% below peak "
                 + DoubleToString(peak, 2);
      if(!g_a2_killed)
      {
         g_a2_killed = true;
         A2_Error("KILL SWITCH — " + g_a2_why + ". No new entries until it is cleared.");
      }
      return true;
   }
   g_a2_killed = false;
   return false;
}

// One gate for every entry, in shadow, replay and live alike.
bool A2_RiskCanEnter(const datetime t, const int side, const double entry, const double sl,
                     const double open_risk_money, const double floating, double &lots,
                     double &risk_money)
{
   lots       = 0.0;
   risk_money = 0.0;
   A2_RiskOnBar(t);

   const double eq = A2_Equity();
   if(eq <= 0.0)
   {
      g_a2_why = "no account equity";
      return false;
   }
   if(A2_RiskKilled(floating))
      return false;
   if(A2_RiskHalted(floating))
   {
      g_a2_day_skips++;
      return false;
   }

   double budget = eq * g_a2_risk_pct;
   const double room = eq * g_a2_total_pct - open_risk_money;
   if(room <= 0.0)
   {
      g_a2_why = "open risk " + DoubleToString(open_risk_money, 2)
                 + " already fills the " + DoubleToString(g_a2_total_pct * 100.0, 2) + "% cap";
      return false;
   }
   if(budget > room)
      budget = room;

   lots = A2_LotsForRisk(side, entry, sl, budget);
   if(lots <= 0.0)
      return false;

   risk_money = A2_LossForLots(side, lots, entry, sl);
   if(risk_money > budget + 0.01)
   {
      g_a2_why = "verified risk " + DoubleToString(risk_money, 2)
                 + " > budget " + DoubleToString(budget, 2);
      lots = 0.0;
      return false;
   }
   g_a2_why = "";
   return true;
}

// The lot step quantises risk downward. On a small account that error stops being
// a rounding detail, so the size the broker would actually accept for a typical
// stop is reported once at startup instead of being discovered in the numbers.
void A2_RiskProbe(const double price, const double stop_frac)
{
   if(price <= 0.0 || stop_frac <= 0.0)
      return;
   const double eq = A2_Equity();
   const double budget = eq * g_a2_risk_pct;
   const double sl = price * (1.0 - stop_frac);
   const double lots = A2_LotsForRisk(+1, price, sl, budget);
   if(lots <= 0.0)
   {
      A2_Warn("risk probe: no lot fits " + DoubleToString(budget, 2)
              + " over a " + DoubleToString(stop_frac * 100.0, 2) + "% stop — "
              + g_a2_why + ". This account is too small to size the strategy.");
      return;
   }
   const double got = A2_LossForLots(+1, lots, price, sl);
   const double err = (budget > 0.0 ? (budget - got) / budget * 100.0 : 0.0);
   const string msg = "risk probe: " + DoubleToString(stop_frac * 100.0, 2) + "% stop at "
                      + DoubleToString(price, _Digits) + " sizes " + DoubleToString(lots, 2)
                      + " lots, risking " + DoubleToString(got, 2)
                      + " of a " + DoubleToString(budget, 2) + " budget ("
                      + DoubleToString(err, 1) + "% under target)";
   if(err > 10.0)
      A2_Warn(msg + " — lot step is coarse for this equity, real risk per leg will run light");
   else
      A2_Info(msg);
}

string A2_RiskLine(const double floating, const double open_risk_money)
{
   const double eq = A2_Equity();
   double peak = GlobalVariableCheck(g_a2_peak_key) ? GlobalVariableGet(g_a2_peak_key) : eq;
   const double dd = (peak > 0.0 ? (peak - eq - floating) / peak * 100.0 : 0.0);
   return "risk " + DoubleToString(g_a2_risk_pct * 100.0, 2) + "%/leg"
          + "  open " + DoubleToString(open_risk_money, 2)
          + "/" + DoubleToString(eq * g_a2_total_pct, 2)
          + "  day " + DoubleToString(A2_RiskDayPct(floating), 2)
          + "%/-" + DoubleToString(g_a2_halt_pct * 100.0, 1) + "%"
          + "  peakDD " + DoubleToString(dd, 2)
          + "%/-" + DoubleToString(g_a2_kill_pct * 100.0, 1) + "%"
          + (A2_RiskHalted(floating) ? "  HALT" : "")
          + (g_a2_killed ? "  KILLED" : "")
          + (g_a2_day_skips > 0 ? ("  skips=" + IntegerToString(g_a2_day_skips)) : "");
}

#endif
