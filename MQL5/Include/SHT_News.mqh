#ifndef SHT_NEWS_MQH
#define SHT_NEWS_MQH

#include "SHT_Config.mqh"
#include "SHT_Log.mqh"

// FundingPips official window is ±5 minutes on red-folder USD.
// We use a wider buffer (default 7) so opens/closes stay outside their rule.
bool     g_news_enabled     = true;
int      g_news_buffer_sec  = 7 * 60;
int      g_news_hold_sec    = 5 * 3600;
int      g_news_n           = 0;
datetime g_news_time[];
string   g_news_name[];
datetime g_news_fetched     = 0;
bool     g_news_ok          = false;
ulong    g_news_flat_id     = 0;

#define SHT_NEWS_MAX 128
#define SHT_NEWS_REFRESH 600

bool SHT_NewsReload()
{
   ArrayResize(g_news_time, SHT_NEWS_MAX);
   ArrayResize(g_news_name, SHT_NEWS_MAX);
   g_news_n = 0;
   g_news_ok = false;

   MqlCalendarValue vals[];
   const datetime from = TimeCurrent() - 86400;
   const datetime till = TimeCurrent() + 8 * 86400;
   const int n = CalendarValueHistory(vals, from, till, NULL, "USD");
   if(n < 0)
   {
      SHT_Warn("news calendar request failed err=" + IntegerToString(GetLastError()));
      g_news_fetched = TimeCurrent();
      return false;
   }

   for(int i = 0; i < n && g_news_n < SHT_NEWS_MAX; i++)
   {
      if(vals[i].time <= 0)
         continue;
      MqlCalendarEvent ev;
      if(!CalendarEventById(vals[i].event_id, ev))
         continue;
      if(ev.importance != CALENDAR_IMPORTANCE_HIGH)
         continue;
      // Drop duplicates at the same timestamp.
      if(g_news_n > 0 && g_news_time[g_news_n - 1] == vals[i].time)
         continue;
      g_news_time[g_news_n] = vals[i].time;
      g_news_name[g_news_n] = ev.name;
      g_news_n++;
   }

   g_news_ok = true;
   g_news_fetched = TimeCurrent();
   SHT_Info("news loaded high-USD=" + IntegerToString(g_news_n)
            + " buffer=" + IntegerToString(g_news_buffer_sec / 60) + "m");
   return true;
}

void SHT_NewsPoll()
{
   if(!g_news_enabled)
      return;
   if(g_news_fetched == 0 || (TimeCurrent() - g_news_fetched) >= SHT_NEWS_REFRESH)
      SHT_NewsReload();
}

int SHT_NewsHit(const datetime t)
{
   if(!g_news_enabled || !g_news_ok)
      return -1;
   for(int i = 0; i < g_news_n; i++)
   {
      const datetime dt = g_news_time[i];
      if(t >= dt - g_news_buffer_sec && t <= dt + g_news_buffer_sec)
         return i;
   }
   return -1;
}

bool SHT_NewsBlocks(const datetime t)
{
   return (SHT_NewsHit(t) >= 0);
}

bool SHT_NewsYoung(const datetime opened, const datetime t)
{
   return ((t - opened) < g_news_hold_sec);
}

// Flatten in the pre-window only: [event-buffer, event). Close stays before the print.
bool SHT_NewsShouldFlatten(const datetime opened, const datetime now)
{
   if(!g_news_enabled || !g_news_ok || opened <= 0)
      return false;
   if(!SHT_NewsYoung(opened, now))
      return false;
   for(int i = 0; i < g_news_n; i++)
   {
      const datetime dt = g_news_time[i];
      if(now >= dt - g_news_buffer_sec && now < dt)
      {
         if(g_news_flat_id == (ulong)dt)
            return false;
         g_news_flat_id = (ulong)dt;
         SHT_Warn("news flatten before " + g_news_name[i]
                  + " at " + TimeToString(dt, TIME_DATE | TIME_MINUTES));
         return true;
      }
   }
   return false;
}

string SHT_NewsLine()
{
   if(!g_news_enabled)
      return "news off";
   if(!g_news_ok)
      return "news calendar EMPTY — filter inactive";

   const datetime now = TimeCurrent();
   const int hit = SHT_NewsHit(now);
   if(hit >= 0)
      return "news WINDOW " + g_news_name[hit]
             + " " + TimeToString(g_news_time[hit], TIME_MINUTES);

   datetime best = 0;
   string   nm   = "";
   for(int i = 0; i < g_news_n; i++)
   {
      if(g_news_time[i] < now)
         continue;
      if(best == 0 || g_news_time[i] < best)
      {
         best = g_news_time[i];
         nm   = g_news_name[i];
      }
   }
   if(best == 0)
      return "news: no red USD ahead";
   const int mins = (int)((best - now) / 60);
   return "news next " + nm + " in " + IntegerToString(mins) + "m";
}

#endif
