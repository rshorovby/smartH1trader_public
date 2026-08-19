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

double SHT_LossMoneyForLots(const int side, const double lots, const double entry, const double sl)
{
   if(lots <= 0.0 || entry <= 0.0 || sl <= 0.0)
      return 0.0;
   double profit = 0.0;
   const ENUM_ORDER_TYPE typ = (side > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   if(!OrderCalcProfit(typ, _Symbol, lots, entry, sl, profit))
      return 0.0;
   return MathMax(0.0, -profit);
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

double SHT_LotsForStopLive(const int side, const double entry, const double sl)
{
   const double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   const double risk_money = equity * g_risk_pct;
   const double vmin = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   const double vmax = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   const double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(equity <= 0.0 || risk_money <= 0.0 || vmin <= 0.0 || step <= 0.0)
   {
      g_risk_why = "no equity / volume step";
      return 0.0;
   }

   double lo = vmin;
   double hi = vmax;
   double best = 0.0;
   for(int i = 0; i < 32; i++)
   {
      const double mid = SHT_NormalizeLots((lo + hi) * 0.5);
      if(mid <= 0.0)
         break;
      const double loss = SHT_LossMoneyForLots(side, mid, entry, sl);
      if(loss <= risk_money + 1e-6)
      {
         best = mid;
         lo = mid + step;
      }
      else
         hi = mid - step;
   }

   if(best <= 0.0)
   {
      const double min_loss = SHT_LossMoneyForLots(side, vmin, entry, sl);
      g_risk_why = "min lot risks " + DoubleToString(min_loss, 2)
                   + " > target " + DoubleToString(risk_money, 2);
      return 0.0;
   }
   return best;
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

bool SHT_RiskCanEnterLive(const datetime t, const bool replay, const int side,
                          const double entry, const double sl, const double floating,
                          double &lots)
{
   lots = 0.0;
   SHT_RiskOnBar(t);
   if(replay)
      return SHT_RiskCanEnter(t, replay, MathAbs(entry - sl), floating, lots);

   if(SHT_RiskHalted(floating))
   {
      g_day_skips++;
      return false;
   }

   lots = SHT_LotsForStopLive(side, entry, sl);
   if(lots <= 0.0)
      return false;

   const double loss = SHT_LossMoneyForLots(side, lots, entry, sl);
   const double risk_money = AccountInfoDouble(ACCOUNT_EQUITY) * g_risk_pct;
   if(loss > risk_money + 0.01)
   {
      g_risk_why = "calc risk " + DoubleToString(loss, 2)
                   + " > target " + DoubleToString(risk_money, 2);
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
