# SmartH1Trader

Personal MetaTrader 5 expert advisor. Built and owned by [rshorovby](https://github.com/rshorovby).

This repository is the source of truth for the live bot. Research, broker dumps, and strategy screening live elsewhere.

## Current status

**v0.1.0 — scaffold only.** The EA attaches to **XAUUSD H1**, checks symbol/timeframe, exposes a kill switch (`InpEnableTrading`), and writes a heartbeat to the Experts log (and optionally `Common/Files/SmartH1Trader.log`). It does **not** place, modify, or close orders.

Intended first strategy (not compiled in yet): Vegas Channel Tunnel on XAUUSD H1.

## Layout

```
MQL5/Experts/SmartH1Trader.mq5   // expert
MQL5/Include/SHT_Config.mqh      // constants
MQL5/Include/SHT_Log.mqh         // journal + file logger
```

## Compile (FundingPips MT5)

1. Copy `MQL5/Experts/SmartH1Trader.mq5` into the terminal `MQL5/Experts/` folder.
2. Copy `MQL5/Include/SHT_*.mqh` into the terminal `MQL5/Include/` folder.
3. Open the `.mq5` in MetaEditor and compile. Keep the `.mq5` / `.mqh` files; a compiled `.ex5` alone is not authorship proof.
4. Attach to an **XAUUSD H1** chart. Leave `InpEnableTrading = false`.

Relative includes (`../Include/...`) resolve when the repo tree is copied as-is into the terminal `MQL5` directory.

## Roadmap

1. Scaffold (this commit): symbol, magic, kill switch, logs.
2. Vegas indicators: EMA 8 / 55·89 / 576·676, ATR, ADX.
3. Entries, stop, take-profit / trail.
4. Risk 0.5% equity per trade and daily halt.
5. High-impact news window.
