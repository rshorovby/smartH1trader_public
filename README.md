# SmartH1Trader

Personal MetaTrader 5 expert advisor. Built and owned by [rshorovby](https://github.com/rshorovby).

This repository is the source of truth for the live bot. Research, broker dumps, and strategy screening live elsewhere.

## Current status

**v0.3.0 — Vegas shadow engine, no broker orders.** On attach the EA replays closed XAUUSD H1 bars, then on each new hour it evaluates the just-closed bar: tunnel arm → retrace entry, ATR×2 stop, TP1 1.5R (50%), final 3R, BE + ATR×3 trail, ADX regime / ride. Signals are logged and marked on the chart. `OrderSend` is still not compiled in.

## Layout

```
MQL5/Experts/SmartH1Trader.mq5   // expert
MQL5/Include/SHT_Config.mqh      // constants
MQL5/Include/SHT_Log.mqh         // journal + file logger
MQL5/Include/SHT_Vegas.mqh       // EMA tunnel / ATR / ADX
MQL5/Include/SHT_Engine.mqh      // shadow entries / exits
```

## Compile (FundingPips MT5)

1. Copy `MQL5/Experts/SmartH1Trader.mq5` into the terminal `MQL5/Experts/` folder.
2. Copy `MQL5/Include/SHT_*.mqh` into the terminal `MQL5/Include/` folder.
3. Open the `.mq5` in MetaEditor and compile. Keep the `.mq5` / `.mqh` files; a compiled `.ex5` alone is not authorship proof.
4. Attach to an **XAUUSD H1** chart. Leave `InpEnableTrading = false`. Restart the terminal if Navigator does not list the EA.

Relative includes (`../Include/...`) resolve when the repo tree is copied as-is into the terminal `MQL5` directory.

## What you should see after attach

- Experts: `replay bars=... closed=N` (N should be in the same ballpark as the Python backtest on this history).
- Chart: entry/exit arrows; if a shadow position is open, SL / TP1 / TP lines.
- Comment: `arm L/S`, `flat` or `LONG/SHORT #id`, `shadow only — no OrderSend`.
- Trade tab: still empty.

## Roadmap

1. Scaffold: symbol, magic, kill switch, logs.
2. Vegas indicators: EMA 8 / 55·89 / 576·676, ATR, ADX.
3. Entries, stop, take-profit / trail. *(this version, shadow)*
4. Risk 0.5% equity per trade and daily halt.
5. High-impact news window.
