# SmartH1Trader

Personal MetaTrader 5 expert advisor. Built and owned by [rshorovby](https://github.com/rshorovby).

This repository is the source of truth for the live bots. Research, broker dumps, and strategy screening live elsewhere.

## Experts

### SmartH1Trader — Vegas XAUUSD H1

**v0.60 — live orders behind `InpEnableTrading` (default off).** Vegas Channel Tunnel on XAUUSD H1. 0.5% risk, daily halt −2%, USD red news ±7 minutes.

### AsrcBtc — Alpha S/R Channel BTCUSD M5

**v0.20 — channel and filters, no orders.** M15 EMA36 ±0.35% channel, M5 EMA21/RSI/BB, H1 EMA55, NY Friday/no-trade flags. Comment + dotted channel lines. Magic `26081302`. Keep `InpEnableTrading = false`.

## Layout

```
MQL5/Experts/SmartH1Trader.mq5   // Vegas XAUUSD H1
MQL5/Experts/AsrcBtc.mq5         // ASRC BTCUSD M5
MQL5/Include/SHT_*.mqh           // shared log / risk / news / exec / Vegas
MQL5/Include/ASRC_Config.mqh     // ASRC constants
MQL5/Include/ASRC_Channel.mqh    // M15 channel + filters
```

## Compile (FundingPips MT5)

1. Copy `MQL5/Experts/*.mq5` into the terminal `MQL5/Experts/` folder.
2. Copy `MQL5/Include/*.mqh` into the terminal `MQL5/Include/` folder.
3. Compile each expert in MetaEditor. Keep the `.mq5` / `.mqh` files; a compiled `.ex5` alone is not authorship proof.
4. Vegas: attach `SmartH1Trader` to **XAUUSD H1**. ASRC: attach `AsrcBtc` to **BTCUSD M5**. Restart the terminal if Navigator does not list a new EA.

Relative includes (`../Include/...`) resolve when the repo tree is copied as-is into the terminal `MQL5` directory.

## Going live (Vegas only)

1. Comment must show upcoming USD news (`news next ...`), not `calendar EMPTY`.
2. Enable the AutoTrading button (Algo Trading).
3. In EA inputs set `InpEnableTrading = true`. Re-attach. Experts should log `LIVE ORDERS ARMED`.
4. Comment says `trading LIVE`. The next H1 signal can place a real order. SL is on the broker even if Wine/MT5 dies.

Leave `InpEnableTrading = false` to stay in shadow mode. **AsrcBtc must stay false** until its strategy modules exist.

## Roadmap

Vegas XAUUSD H1: done through live orders.

ASRC BTCUSD M5:

1. Scaffold
2. M15 channel + M5/H1 filters *(this version)*
3. Shadow entries / SL / TP
4. Risk 0.5% + daily halt (shared account halt comes later)
5. USD news window
6. Broker orders
