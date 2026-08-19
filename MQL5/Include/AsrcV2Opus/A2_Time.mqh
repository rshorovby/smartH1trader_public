#ifndef A2_TIME_MQH
#define A2_TIME_MQH

#include "A2_Log.mqh"

// Historical-safe clock.
//
// v1 converted every bar with the offset in force at the moment of the call
// (TimeCurrent() - TimeGMT()), which is right for the newest bar and wrong for
// every bar on the other side of a daylight-saving transition. Replay therefore
// mislabelled New York time by an hour from early November to mid March, in the
// same direction as the Python ingest, so the backtest and the replay agreed with
// each other and disagreed with live trading.
//
// This broker's server clock follows US daylight saving: UTC+3 while US DST is on
// and UTC+2 otherwise. Verified on the NDX100 feed, where the CME clearing halt
// leaves New York hour 17 empty in all twelve months only under this mapping.
// A useful consequence: New York time is server time minus 7 hours all year, and
// the server's midnight is New York 17:00, which is also the trading-day
// boundary this EA uses for its daily loss halt.
//
// The mapping is asserted against the live terminal at startup instead of being
// trusted, so a broker that changes its clock produces a refusal, not silence.

int  g_a2_std_off_sec = 2 * 3600;   // server offset from UTC outside US DST
bool g_a2_time_ok     = false;

int A2_NthSundayDay(const int year, const int month, const int n)
{
   MqlDateTime dt;
   ZeroMemory(dt);
   dt.year = year;
   dt.mon  = month;
   dt.day  = 1;
   const datetime first = StructToTime(dt);
   TimeToStruct(first, dt);
   const int first_sunday = (dt.day_of_week == 0) ? 1 : (8 - dt.day_of_week);
   return first_sunday + (n - 1) * 7;
}

datetime A2_UtcStamp(const int year, const int month, const int day, const int hour)
{
   MqlDateTime dt;
   ZeroMemory(dt);
   dt.year = year;
   dt.mon  = month;
   dt.day  = day;
   dt.hour = hour;
   return StructToTime(dt);
}

// US DST runs from the second Sunday of March 02:00 EST (07:00 UTC) to the first
// Sunday of November 02:00 EDT (06:00 UTC).
bool A2_UsDstUtc(const datetime utc)
{
   MqlDateTime dt;
   TimeToStruct(utc, dt);
   const datetime start = A2_UtcStamp(dt.year, 3, A2_NthSundayDay(dt.year, 3, 2), 7);
   const datetime end   = A2_UtcStamp(dt.year, 11, A2_NthSundayDay(dt.year, 11, 1), 6);
   return (utc >= start && utc < end);
}

// Two passes: the first guess can only be wrong inside the transition hour
// itself, and the second pass resolves every case outside it.
int A2_ServerOffsetSec(const datetime server_t)
{
   int off = g_a2_std_off_sec + (A2_UsDstUtc(server_t - g_a2_std_off_sec - 3600) ? 3600 : 0);
   off = g_a2_std_off_sec + (A2_UsDstUtc(server_t - off) ? 3600 : 0);
   return off;
}

datetime A2_ServerToUtc(const datetime server_t)
{
   return server_t - A2_ServerOffsetSec(server_t);
}

datetime A2_ServerToNy(const datetime server_t)
{
   const datetime utc = A2_ServerToUtc(server_t);
   return utc - (A2_UsDstUtc(utc) ? 4 * 3600 : 5 * 3600);
}

void A2_NyStruct(const datetime server_t, MqlDateTime &ny)
{
   TimeToStruct(A2_ServerToNy(server_t), ny);
}

int A2_NyMinuteOfDay(const datetime server_t)
{
   MqlDateTime ny;
   A2_NyStruct(server_t, ny);
   return ny.hour * 60 + ny.min;
}

int A2_NyWeekday(const datetime server_t)
{
   MqlDateTime ny;
   A2_NyStruct(server_t, ny);
   return ny.day_of_week;   // 0 = Sunday
}

// Trading day boundary. Server midnight is New York 17:00 under this broker's
// clock, which is also where the CME session rolls, so the daily loss halt and
// the end-of-day flatten share one boundary.
datetime A2_DayStamp(const datetime server_t)
{
   MqlDateTime dt;
   TimeToStruct(server_t, dt);
   dt.hour = 0;
   dt.min  = 0;
   dt.sec  = 0;
   return StructToTime(dt);
}

// True when a boundary minute of the New York day sits in (prev, now].
bool A2_CrossedNyMinute(const int prev_min, const int now_min, const int boundary)
{
   if(prev_min == now_min)
      return false;
   if(now_min > prev_min)
      return (boundary > prev_min && boundary <= now_min);
   return (boundary > prev_min || boundary <= now_min);   // wrapped past midnight
}

bool A2_TimeVerify(string &why)
{
   g_a2_time_ok = false;
   const datetime srv = TimeCurrent();
   const datetime gmt = TimeGMT();
   if(srv <= 0 || gmt <= 0)
   {
      why = "terminal has no server or GMT time yet";
      return false;
   }

   // Round the measured offset to the nearest quarter hour: broker clocks drift
   // by seconds and a few brokers sit on a half-hour offset.
   const int meas = (int)MathRound((double)(srv - gmt) / 900.0) * 900;
   const int rule = A2_ServerOffsetSec(srv);
   if(meas != rule)
   {
      why = "server offset is " + DoubleToString(meas / 3600.0, 2)
            + "h but the US-DST rule expects " + DoubleToString(rule / 3600.0, 2)
            + "h — refusing to guess New York time";
      return false;
   }

   const datetime ny = A2_ServerToNy(srv);
   A2_Info("clock verified: server=" + TimeToString(srv, TIME_DATE | TIME_MINUTES)
           + " utc=" + TimeToString(A2_ServerToUtc(srv), TIME_DATE | TIME_MINUTES)
           + " ny=" + TimeToString(ny, TIME_DATE | TIME_MINUTES)
           + " offset=+" + DoubleToString(rule / 3600.0, 1) + "h"
           + " usDst=" + (A2_UsDstUtc(A2_ServerToUtc(srv)) ? "on" : "off"));
   g_a2_time_ok = true;
   why = "";
   return true;
}

// Makes the daylight-saving transition visible in the log instead of leaving the
// operator to trust it.
void A2_TimeSelfTest(const int bars_to_scan)
{
   const int total = Bars(_Symbol, PERIOD_H1);
   const int n = (int)MathMin(total, bars_to_scan);
   if(n < 2)
      return;
   int changes = 0;
   int prev_off = A2_ServerOffsetSec(iTime(_Symbol, PERIOD_H1, n - 1));
   string when = "";
   for(int i = n - 2; i >= 0; i--)
   {
      const datetime t = iTime(_Symbol, PERIOD_H1, i);
      if(t <= 0)
         continue;
      const int off = A2_ServerOffsetSec(t);
      if(off != prev_off)
      {
         changes++;
         when += " " + TimeToString(t, TIME_DATE) + "(+"
                 + DoubleToString(prev_off / 3600.0, 0) + "h->+"
                 + DoubleToString(off / 3600.0, 0) + "h)";
         prev_off = off;
      }
   }
   A2_Info("clock history: " + IntegerToString(n) + " H1 bars, "
           + IntegerToString(changes) + " DST transition(s)" + when);
}

#endif
