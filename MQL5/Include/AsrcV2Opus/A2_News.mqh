#ifndef A2_NEWS_MQH
#define A2_NEWS_MQH

#include "A2_Log.mqh"

// Red-folder USD window. FundingPips forbids opening or closing within 5 minutes
// of a high-importance print; the default buffer here is wider so both ends stay
// clear of their rule.
//
// Difference from the SHT version: this one fails closed. If the filter is on but
// the calendar could not be read, entries are blocked instead of waved through,
// because "calendar unavailable" is exactly when an unfiltered entry is most
// likely to breach the rule.

bool     g_a2_news_on       = true;
int      g_a2_news_buf_sec  = 7 * 60;
int      g_a2_news_hold_sec = 5 * 3600;
int      g_a2_news_n        = 0;
datetime g_a2_news_time[];
string   g_a2_news_name[];
datetime g_a2_news_fetched  = 0;
bool     g_a2_news_ok       = false;
ulong    g_a2_news_flat_id  = 0;

#define A2_NEWS_MAX     128
#define A2_NEWS_REFRESH 600

bool A2_NewsReload()
{
   ArrayResize(g_a2_news_time, A2_NEWS_MAX);
   ArrayResize(g_a2_news_name, A2_NEWS_MAX);
   g_a2_news_n  = 0;
   g_a2_news_ok = false;

   MqlCalendarValue vals[];
   const int n = CalendarValueHistory(vals, TimeCurrent() - 86400,
                                      TimeCurrent() + 8 * 86400, NULL, "USD");
   g_a2_news_fetched = TimeCurrent();
   if(n < 0)
   {
      if(A2_LogOnce(0, "news_fail", 600))
         A2_Warn("news calendar request failed err=" + IntegerToString(GetLastError())
                 + " — entries blocked while the filter has no data");
      return false;
   }

   for(int i = 0; i < n && g_a2_news_n < A2_NEWS_MAX; i++)
   {
      if(vals[i].time <= 0)
         continue;
      MqlCalendarEvent ev;
      if(!CalendarEventById(vals[i].event_id, ev))
         continue;
      if(ev.importance != CALENDAR_IMPORTANCE_HIGH)
         continue;
      if(g_a2_news_n > 0 && g_a2_news_time[g_a2_news_n - 1] == vals[i].time)
         continue;
      g_a2_news_time[g_a2_news_n] = vals[i].time;
      g_a2_news_name[g_a2_news_n] = ev.name;
      g_a2_news_n++;
   }

   g_a2_news_ok = true;
   A2_Info("news loaded high-USD=" + IntegerToString(g_a2_news_n)
           + " buffer=" + IntegerToString(g_a2_news_buf_sec / 60) + "m");
   return true;
}

void A2_NewsPoll()
{
   if(!g_a2_news_on)
      return;
   if(g_a2_news_fetched == 0 || (TimeCurrent() - g_a2_news_fetched) >= A2_NEWS_REFRESH)
      A2_NewsReload();
}

int A2_NewsHit(const datetime t)
{
   if(!g_a2_news_on || !g_a2_news_ok)
      return -1;
   for(int i = 0; i < g_a2_news_n; i++)
   {
      const datetime dt = g_a2_news_time[i];
      if(t >= dt - g_a2_news_buf_sec && t <= dt + g_a2_news_buf_sec)
         return i;
   }
   return -1;
}

// Fail closed: an enabled filter with no calendar blocks entries.
bool A2_NewsBlocks(const datetime t)
{
   if(!g_a2_news_on)
      return false;
   if(!g_a2_news_ok)
   {
      if(A2_LogOnce(1, "news_blind", 900))
         A2_Warn("news filter enabled but calendar empty — blocking entries");
      return true;
   }
   return (A2_NewsHit(t) >= 0);
}

bool A2_NewsYoung(const datetime opened, const datetime t)
{
   return ((t - opened) < g_a2_news_hold_sec);
}

// Flatten only in the pre-print window [event - buffer, event), so the close
// itself never lands inside the forbidden band.
bool A2_NewsShouldFlatten(const datetime opened, const datetime now)
{
   if(!g_a2_news_on || !g_a2_news_ok || opened <= 0)
      return false;
   if(!A2_NewsYoung(opened, now))
      return false;
   for(int i = 0; i < g_a2_news_n; i++)
   {
      const datetime dt = g_a2_news_time[i];
      if(now >= dt - g_a2_news_buf_sec && now < dt)
      {
         if(g_a2_news_flat_id == (ulong)dt)
            return false;
         g_a2_news_flat_id = (ulong)dt;
         A2_Warn("news flatten before " + g_a2_news_name[i]
                 + " at " + TimeToString(dt, TIME_DATE | TIME_MINUTES));
         return true;
      }
   }
   return false;
}

string A2_NewsLine()
{
   if(!g_a2_news_on)
      return "news off";
   if(!g_a2_news_ok)
      return "news calendar EMPTY — entries blocked";

   const datetime now = TimeCurrent();
   const int hit = A2_NewsHit(now);
   if(hit >= 0)
      return "news WINDOW " + g_a2_news_name[hit] + " "
             + TimeToString(g_a2_news_time[hit], TIME_MINUTES);

   datetime best = 0;
   string   nm   = "";
   for(int i = 0; i < g_a2_news_n; i++)
   {
      if(g_a2_news_time[i] < now)
         continue;
      if(best == 0 || g_a2_news_time[i] < best)
      {
         best = g_a2_news_time[i];
         nm   = g_a2_news_name[i];
      }
   }
   if(best == 0)
      return "news: no red USD ahead";
   return "news next " + nm + " in " + IntegerToString((int)((best - now) / 60)) + "m";
}

#endif
