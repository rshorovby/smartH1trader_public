#ifndef PG_CONFIG_MQH
#define PG_CONFIG_MQH

#define PG_VERSION              "0.10"
#define PG_LOG_FILE             "PgSilver.log"
#define PG_ALLOWED_SYMBOL       "XAG"
#define PG_ALLOWED_TF           PERIOD_H1
#define PG_SIGNAL_TF            PERIOD_M30

#define PG_VWMA_LEN             20
#define PG_ROC_LEN              8
#define PG_SD_LEN               20
#define PG_EMERG_SL             0.015
#define PG_TRAIL_ACT            0.005
#define PG_TRAIL_DIST           0.005
#define PG_CD_HOURS             2.0
#define PG_WARMUP               30
#define PG_REPLAY_BARS          400
#define PG_MRK                  "PGs_"

#endif
