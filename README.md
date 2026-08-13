# SmartH1Trader

Personal MetaTrader 5 expert advisor. Built and owned by [rshorovby](https://github.com/rshorovby).

This repository is the source of truth for the live bot. Research, broker dumps, and strategy screening live elsewhere.

## Current status

**v0.40 — shadow + risk, no broker orders.** Vegas Channel Tunnel on XAUUSD H1: replay closed bars, then live closed-bar signals. Position size is 0.5% of equity (ATR×2 stop). New shadow entries halt if the day's shadow P&amp;L (closed + floating) reaches −2% — a buffer under typical FundingPips daily loss. `OrderSend` is still not compiled in.

## Layout

```
MQL5/Experts/SmartH1Trader.mq5   // expert
MQL5/Include/SHT_Config.mqh      // constants
MQL5/Include/SHT_Log.mqh         // journal + file logger
MQL5/Include/SHT_Vegas.mqh       // EMA tunnel / ATR / ADX
MQL5/Include/SHT_Engine.mqh      // shadow entries / exits
MQL5/Include/SHT_Risk.mqh        // lot size + daily halt
```

## Compile (FundingPips MT5)

1. Copy `MQL5/Experts/SmartH1Trader.mq5` into the terminal `MQL5/Experts/` folder.
2. Copy `MQL5/Include/SHT_*.mqh` into the terminal `MQL5/Include/` folder.
3. Open the `.mq5` in MetaEditor and compile. Keep the `.mq5` / `.mqh` files; a compiled `.ex5` alone is not authorship proof.
4. Attach to an **XAUUSD H1** chart. Leave `InpEnableTrading = false`. Restart the terminal if Navigator does not list the EA.

Relative includes (`../Include/...`) resolve when the repo tree is copied as-is into the terminal `MQL5` directory.

## What you should see after attach

- Experts: `replay ... closed=N` and each open line includes `lots=...` (typically ~0.01 on a small challenge if gold SL is wide).
- Comment: `risk 0.50%  halt@2.0%  day=0.00%` plus `lots=` on an open shadow trade.
- Trade tab: still empty. Daily halt is paper-only until orders exist.

## Roadmap

1. Scaffold: symbol, magic, kill switch, logs.
2. Vegas indicators: EMA 8 / 55·89 / 576·676, ATR, ADX.
3. Entries, stop, take-profit / trail (shadow).
4. Risk 0.5% equity per trade and daily halt. *(this version)*
5. High-impact news window.
