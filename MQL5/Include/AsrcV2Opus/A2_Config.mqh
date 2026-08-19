#ifndef A2_CONFIG_MQH
#define A2_CONFIG_MQH

// ASRC V2_OPUS — Alpha S/R Channel, BTCUSD M5.
//
// Signal logic is deliberately identical to backtest_asrc_v2_opus.py, which in
// turn keeps v1's entry rules untouched. Everything that changed sits in the
// measurement and the plumbing:
//   * higher-timeframe series read only from bars that have already closed, in
//     live and in replay alike, so the two cannot disagree;
//   * New York time derived from the broker's real clock rule instead of the
//     offset that happens to be in force right now;
//   * lot size verified with OrderCalcProfit rather than inferred from tick
//     value, on the same code path in shadow, replay and live;
//   * every entry counted against the session cap, so one session cannot exceed
//     the intended 1.0% of equity;
//   * session resets and the end-of-day flatten fire on time crossings, so a
//     missing bar cannot silently skip them;
//   * news filter fails closed when the calendar is unavailable.

#define A2_VERSION            "2.00-OPUS"
#define A2_LOG_FILE           "AsrcBtcV2Opus.log"
#define A2_ALLOWED_SYMBOL     "BTCUSD"
#define A2_ALLOWED_TF         PERIOD_M5

// ---- indicators (unchanged from v1)
#define A2_CH_TF              PERIOD_M15
#define A2_CH_EMA             36
#define A2_CH_PCT             0.35     // total channel width, percent of price
#define A2_HT_TF              PERIOD_H1
#define A2_HT_EMA             55
#define A2_LTF_EMA            21
#define A2_RSI_LEN            14
#define A2_BB_LEN             20
#define A2_BB_MULT            2.0
#define A2_BB_THR             0.002    // below this Bollinger width we stand down
#define A2_SQZ_LEN            20
#define A2_WARMUP             80

// ---- entry pattern (unchanged from v1)
#define A2_RR                 3.0
#define A2_ENG_MIN            0.098    // percent of price
#define A2_ENG_MAX            0.550
#define A2_PREV_RAN           0.60
#define A2_PIN_WICK_RATIO     3.0
#define A2_PIN_BODY_MAX       0.20
#define A2_PIN_WICK_MIN       0.70
#define A2_PIN_PCT            0.70
#define A2_SWEEP_LB           10
#define A2_GAP_TICKS          250
#define A2_SL_BUF_TICKS       500
#define A2_BARS_GAP           4

// ---- exposure
#define A2_MAX_LEGS           2        // 2 x 0.5% = the accepted 1.0% per signal
#define A2_MAX_ENTRIES_SESS   2        // counts every entry, first legs included

// ---- session clock, New York
#define A2_EOD_MIN            (17 * 60)
#define A2_NT_START_MIN       (16 * 60 + 45)
#define A2_NT_END_MIN         (19 * 60 + 5)

#define A2_MRK                "A2e_"
#define A2_LVL                "A2l_"

#endif
