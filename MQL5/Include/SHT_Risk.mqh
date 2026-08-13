#ifndef SHT_RISK_MQH
#define SHT_RISK_MQH

#include "SHT_Config.mqh"
#include "SHT_Log.mqh"

// Defaults match the Python backtest (0.5% / trade) and sit under typical
// FundingPips daily loss (often 3–5%). Halt is a soft brake, not the firm rule.
double   g_risk_pct        = 0.005;
double   g_daily_halt_pct  = 0.02;
datetime g_risk_day        = 0;
double   g_day_start_eq    = 0.0;
double   g_day_pnl         = 0.0;   // realized shadow money today
int      g_day_skips       = 0;
string   g_risk_why        = "";
double   g_pos_lots        = 0.0;
double   g_pos_risk_money  = 0.0;
double   g_pos_eq          = 0.0;

datetime SHT_DayStamp(const datetime t)
{
   MqlDateTime dt;
   TimeToStruct(t, dt);
   dt.hour = 0;
   dt.min  = 0;
   dt.sec  = 0;
   return StructToTime(dt);
}

double SHT_NormalizeLots(double lots)
{
   const double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   const double vmax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   const double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0 || vmin <= 0.0)
      return 0.0;
   lots = MathFloor(lots / step + 1e-8) * step;
   if(lots < vmin)
      return 0.0;
   if(lots > vmax)
      lots = vmax;
   int digits = 2;
   if(step < 0.01 - 1e-12)
      digits = 3;
   return NormalizeDouble(lots, digits);
}

double SHT_LotsForStop(const double sl_distance)
{
   const double equity     = AccountInfoDouble(ACCOUNT_EQUITY);
   const double tick_size  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   const double tick_value = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(sl_distance <= 0.0 || tick_size <= 0.0 || tick_value <= 0.0 || equity <= 0.0)
   {
      g_risk_why = "no tick value / equity";
      return 0.0;
   }
   const double money = equity * g_risk_pct;
   const double ticks = sl_distance / tick_size;
   const double raw   = money / (ticks * tick_value);
   const double lots  = SHT_NormalizeLots(raw);
   if(lots <= 0.0)
   {
      g_risk_why = "lot below min for " + DoubleToString(g_risk_pct * 100.0, 2) + "% risk";
      return 0.0;
   }
   return lots;
}

void SHT_RiskResetDay(const datetime t)
{
   g_risk_day     = SHT_DayStamp(t);
   g_day_start_eq = AccountInfoDouble(ACCOUNT_EQUITY);
   g_day_pnl      = 0.0;
   g_day_skips    = 0;
   g_risk_why     = "";
}

void SHT_RiskOnBar(const datetime t)
{
   const datetime day = SHT_DayStamp(t);
   if(day != g_risk_day)
      SHT_RiskResetDay(t);
}

void SHT_RiskAddPnl(const double money)
{
   g_day_pnl += money;
}

double SHT_RiskFloating(const int side, const double entry, const double rdist,
                        const double rem, const double bid)
{
   if(rdist <= 0.0 || g_pos_risk_money <= 0.0 || rem <= 1e-12)
      return 0.0;
   const double r = (side > 0) ? (bid - entry) / rdist : (entry - bid) / rdist;
   return r * rem * g_pos_risk_money;
}

double SHT_RiskDayPct(const double floating)
{
   if(g_day_start_eq <= 0.0)
      return 0.0;
   return (g_day_pnl + floating) / g_day_start_eq * 100.0;
}

bool SHT_RiskHalted(const double floating)
{
   if(g_day_start_eq <= 0.0)
      return false;
   const double loss_frac = -(g_day_pnl + floating) / g_day_start_eq;
   if(loss_frac >= g_daily_halt_pct - 1e-12)
   {
      g_risk_why = "daily halt " + DoubleToString(loss_frac * 100.0, 2) + "%";
      return true;
   }
   return false;
}

bool SHT_RiskCanEnter(const datetime t, const bool replay, const double sl_distance,
                      const double floating, double &lots)
{
   lots = 0.0;
   SHT_RiskOnBar(t);
   lots = SHT_LotsForStop(sl_distance);
   if(replay)
   {
      if(lots <= 0.0)
         lots = SHT_NormalizeLots(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN));
      return (lots > 0.0);
   }
   if(lots <= 0.0)
      return false;
   if(SHT_RiskHalted(floating))
   {
      g_day_skips++;
      return false;
   }
   g_risk_why = "";
   return true;
}

string SHT_RiskLine(const double floating)
{
   return "risk " + DoubleToString(g_risk_pct * 100.0, 2) + "%"
          + "  halt@" + DoubleToString(g_daily_halt_pct * 100.0, 1) + "%"
          + "  day=" + DoubleToString(SHT_RiskDayPct(floating), 2) + "%"
          + (SHT_RiskHalted(floating) ? "  HALT" : "")
          + (g_day_skips > 0 ? ("  skips=" + IntegerToString(g_day_skips)) : "");
}

#endif
