# SmartH1Trader

Personal MetaTrader 5 expert advisor. Built and owned by [rshorovby](https://github.com/rshorovby).

This repository is the source of truth for the live bot. Research, broker dumps, and strategy screening live elsewhere.

## Current status

**v0.2.0 — Vegas indicators, no orders.** The EA attaches to **XAUUSD H1**, computes EMA 8 / 55·89 / 576·676, ATR(14) and ADX(14), and prints a snapshot on each new H1 bar (chart comment + Experts log). It does **not** place, modify, or close orders.

Intended strategy (entries not compiled in yet): Vegas Channel Tunnel on XAUUSD H1.

## Layout

```
MQL5/Experts/SmartH1Trader.mq5   // expert
MQL5/Include/SHT_Config.mqh      // constants
MQL5/Include/SHT_Log.mqh         // journal + file logger
MQL5/Include/SHT_Vegas.mqh       // EMA tunnel / ATR / ADX
```

## Compile (FundingPips MT5)

1. Copy `MQL5/Experts/SmartH1Trader.mq5` into the terminal `MQL5/Experts/` folder.
2. Copy `MQL5/Include/SHT_*.mqh` into the terminal `MQL5/Include/` folder.
3. Open the `.mq5` in MetaEditor and compile. Keep the `.mq5` / `.mqh` files; a compiled `.ex5` alone is not authorship proof.
4. Attach to an **XAUUSD H1** chart. Leave `InpEnableTrading = false`. Restart the terminal if Navigator does not list the EA.

Relative includes (`../Include/...`) resolve when the repo tree is copied as-is into the terminal `MQL5` directory.

## Roadmap

1. Scaffold: symbol, magic, kill switch, logs.
2. Vegas indicators: EMA 8 / 55·89 / 576·676, ATR, ADX. *(this version)*
3. Entries, stop, take-profit / trail.
4. Risk 0.5% equity per trade and daily halt.
5. High-impact news window.
