# Crypto tracker

The Notch currently supports **Binance Spot crypto pairs only**. Open the notch, choose
**Crypto**, then **Add pair**. Search for an exact Spot pair such as `BTC/USDT`. The public
catalog and ticker need no account, API key, or connection setup.

The detail view shows the latest Binance Spot price, its rolling 24-hour percentage change,
the quote timestamp, and whether the quote is live or stale. Pin a pair to show its price
while the notch is closed. Agent attention and the system HUD retain priority over the pin.

## Removed feeds and saved data

US stocks, IDX stocks, and forex are no longer offered in search, settings, the watchlist,
or live subscriptions. Their provider code and MT5 helper are removed from the app. The
crypto-only preferences migration writes `NotchTradingPreferences.v3` and retains the previous
record under `NotchTradingPreferences.preCryptoBackup` before hiding old noncrypto assets.
Pins and selections pointing to removed assets are cleared. Existing Alpaca/MT5 Keychain
items are left untouched so this app update does not delete account information.

## Feed behavior

- Search uses Binance's public Spot catalog and only offers active Spot pairs.
- Prices use the exact exchange-qualified pair. `BTC/USD` is not silently changed to
  `BTC/USDT`; add the desired Binance pair explicitly.
- The `@ticker` stream supplies the last price and rolling 24-hour change. A cached or old
  quote cannot regain a live label merely because a socket reconnects.
- The app reconnects transient failures and renews a WebSocket before its 24-hour lifetime.
  Sleep stops the stream; wake resubscribes. The expanded panel subscribes to the watchlist,
  while the closed notch subscribes only to its pin.
- Quote rendering is coalesced to at most four updates per second. New additions are capped
  at 100 pairs.

## Verification

Run from the repository root:

```sh
rtk proxy bash tools/trading-tests/run.sh
rtk proxy bash tools/session-tests/run.sh
rtk proxy bash tools/integration-tests/run.sh
rtk xcodebuild -project "The Notch.xcodeproj" -scheme "The Notch" build
```

The trading tests cover crypto-only migration, Binance pair/tick decoding, decimal precision,
pinning, streaming updates, stale prices, sleep, and late callbacks. Hardware interaction and
an extended endurance run remain open checks.

Sources: [Binance public market data](https://github.com/binance/binance-spot-api-docs/blob/master/faqs/market_data_only.md),
[Binance streams](https://github.com/binance/binance-spot-api-docs/blob/master/web-socket-streams.md).
