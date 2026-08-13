#ifndef SHT_LOG_MQH
#define SHT_LOG_MQH

bool   g_sht_log_file = true;
string g_sht_log_name = "SmartH1Trader.log";

void SHT_Log(const string level, const string msg)
{
   const string line = TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS)
                       + " [" + level + "] " + msg;
   Print(line);

   if(!g_sht_log_file)
      return;

   const int h = FileOpen(
      g_sht_log_name,
      FILE_READ | FILE_WRITE | FILE_TXT | FILE_ANSI | FILE_COMMON | FILE_SHARE_READ
   );
   if(h == INVALID_HANDLE)
      return;

   FileSeek(h, 0, SEEK_END);
   FileWriteString(h, line + "\r\n");
   FileClose(h);
}

void SHT_Info(const string msg)  { SHT_Log("INFO",  msg); }
void SHT_Warn(const string msg)  { SHT_Log("WARN",  msg); }
void SHT_Error(const string msg) { SHT_Log("ERROR", msg); }

#endif
