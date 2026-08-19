#ifndef A2_LOG_MQH
#define A2_LOG_MQH

// Self-contained logger. V2_OPUS shares no globals with the SHT_* family so that
// a change made for another EA cannot alter this one's behaviour.

bool   g_a2_log_file = true;
string g_a2_log_name = "AsrcBtcV2Opus.log";
int    g_a2_errors   = 0;
int    g_a2_warns    = 0;

void A2_Log(const string level, const string msg)
{
   const string line = TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS)
                       + " [" + level + "] " + msg;
   Print(line);

   if(!g_a2_log_file)
      return;

   const int h = FileOpen(
      g_a2_log_name,
      FILE_READ | FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON | FILE_SHARE_READ
   );
   if(h == INVALID_HANDLE)
      return;
   FileSeek(h, 0, SEEK_END);
   FileWriteString(h, line + "\r\n");
   FileClose(h);
}

void A2_Info(const string msg) { A2_Log("INFO", msg); }
void A2_Warn(const string msg) { g_a2_warns++;  A2_Log("WARN", msg); }
void A2_Error(const string msg) { g_a2_errors++; A2_Log("ERROR", msg); }

// Same message repeated on every tick is noise; let callers throttle by key.
datetime g_a2_throttle_at[8];
string   g_a2_throttle_key[8];

bool A2_LogOnce(const int slot, const string key, const int cooldown_sec)
{
   if(slot < 0 || slot >= 8)
      return true;
   if(g_a2_throttle_key[slot] == key
      && (TimeCurrent() - g_a2_throttle_at[slot]) < cooldown_sec)
      return false;
   g_a2_throttle_key[slot] = key;
   g_a2_throttle_at[slot]  = TimeCurrent();
   return true;
}

#endif
