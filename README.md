# SmartH1Trader

Personal MetaTrader 5 expert advisor. Built and owned by [rshorovby](https://github.com/rshorovby).

This repository is the source of truth for the live bot. Research, broker dumps, and strategy screening live elsewhere.

## Current status

**v0.60 — live orders behind `InpEnableTrading` (default off).** Vegas Channel Tunnel on XAUUSD H1. 0.5% risk, daily halt −2%, USD red news ±7 minutes. When trading is enabled the EA sends market orders with **broker-side SL** (and 3R TP unless ride). Partial 1.5R, BE and trail are managed by the EA. Replay stays paper-only and is not sent to the broker.

## Layout

```
MQL5/Experts/SmartH1Trader.mq5   // expert
MQL5/Include/SHT_Config.mqh      // constants
MQL5/Include/SHT_Log.mqh         // journal + file logger
MQL5/Include/SHT_Vegas.mqh       // EMA tunnel / ATR / ADX
MQL5/Include/SHT_Engine.mqh      // entries / exits
MQL5/Include/SHT_Risk.mqh        // lot size + daily halt
MQL5/Include/SHT_News.mqh        // red USD window
MQL5/Include/SHT_Exec.mqh        // OrderSend / modify / close
```

## Compile (FundingPips MT5)

1. Copy `MQL5/Experts/SmartH1Trader.mq5` into the terminal `MQL5/Experts/` folder.
2. Copy `MQL5/Include/SHT_*.mqh` into the terminal `MQL5/Include/` folder.
3. Open the `.mq5` in MetaEditor and compile. Keep the `.mq5` / `.mqh` files; a compiled `.ex5` alone is not authorship proof.
4. Attach to an **XAUUSD H1** chart.

Relative includes (`../Include/...`) resolve when the repo tree is copied as-is into the terminal `MQL5` directory.

## Going live

1. Comment must show upcoming USD news (`news next ...`), not `calendar EMPTY`.
2. Enable the AutoTrading button (Algo Trading).
3. In EA inputs set `InpEnableTrading = true`. Re-attach. Experts should log `LIVE ORDERS ARMED`.
4. Comment says `trading LIVE`. The next H1 signal can place a real order. SL is on the broker even if Wine/MT5 dies.

Leave `InpEnableTrading = false` to stay in shadow mode.

## Roadmap

1. Scaffold
2. Vegas indicators
3. Shadow entries / exits
4. Risk 0.5% + daily halt
5. News window
6. Broker orders *(this version)*
