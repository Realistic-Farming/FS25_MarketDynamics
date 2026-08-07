<div align="center">

# 📈 FS25 Market Dynamics
### *Real-World Inspired Dynamic Pricing*

[![Downloads](https://img.shields.io/github/downloads/TheCodingDad-TisonK/FS25_MarketDynamics/total?style=for-the-badge&logo=github&color=4caf50&logoColor=white)](https://github.com/TheCodingDad-TisonK/FS25_MarketDynamics/releases)
[![Release](https://img.shields.io/github/v/release/TheCodingDad-TisonK/FS25_MarketDynamics?style=for-the-badge&logo=tag&color=76c442&logoColor=white)](https://github.com/TheCodingDad-TisonK/FS25_MarketDynamics/releases/latest)
[![License](https://img.shields.io/badge/license-CC%20BY--NC--ND%204.0-lightgrey?style=for-the-badge&logo=creativecommons&logoColor=white)](https://creativecommons.org/licenses/by-nc-nd/4.0/)
<a href="https://paypal.me/TheCodingDad">
  <img src="https://www.paypalobjects.com/en_US/i/btn/btn_donate_LG.gif" alt="Donate via PayPal" height="50">
</a>

<br>

> *"Sold my entire wheat harvest in October because the price looked 'good'. Two days later, a geopolitical crisis hit and prices spiked 15%. If I had just used a futures contract to lock in a price for my spring harvest, I wouldn't be kicking myself right now."*

<br>

**In base FS25, crop prices are predictable and static. This mod changes the game.**

Market Dynamics introduces real-world economic volatility. Prices fluctuate daily and intraday based on simulated market engines. Geopolitical events, weather, and trade disruptions can cause sudden spikes or crashes. You're no longer just a farmer; you're a market participant. Hedge your bets by locking in prices months in advance using the new futures contract system.

`Singleplayer` • `Multiplayer (server-authoritative)` • `Persistent saves` • `26 languages`

</div>

> [!TIP]
> Want to be part of our community? Share tips, report issues, and chat with other farmers on the **[FS25 Modding Community Discord](https://discord.gg/Th2pnq36)**!

---

## ⚙️ Features

### 📈 Dynamic Price Engine

The core of Market Dynamics is a continuous simulation of supply and demand.

| | System | What it does |
|---|---|---|
| 📉 | **Intraday Volatility** | Prices jitter continuously throughout the day. A random walk algorithm ensures no two days look exactly alike. |
| 🔄 | **Mean Reversion** | If prices spike too high or drop too low, market forces slowly pull them back toward the base vanilla price. |
| 📊 | **Live Charts** | Session price trends are graphed in real-time in the new Market Screen, helping you spot upward or downward momentum. |
| 🛠️ | **Event Tuning** | Configure which crops are affected by specific world events via the in-game UI. Includes a "Browse Types" list for easy crop selection. |

### 🌍 World Event System

Prices don't just change randomly; they react to global events. The mod periodically triggers major events that inject significant modifiers into the pricing engine.

| Event | Effect on Prices | Duration |
|---|---|---|
| ☀️ **Drought** | **+20%** to all crops | High intensity, lasts several days. |
| 🌾 **Bumper Harvest** | **-10%** to all crops | Excess supply drives prices down globally. |
| 🚢 **Trade Disruption** | **+12%** to export crops | Sudden spikes due to broken supply chains. |
| 🪲 **Pest Outbreak** | **+8%** to specific crops | Localized scarcity pushes targeted prices up. |
| ⛽ **Biofuel Initiative** | **+8%** to Maize / Canola | Increased industrial demand. |
| 🐄 **Livestock Boom** | **+8%** to feed crops | Higher demand for Corn, Soybeans, Oats. |
| 🗺️ **Geopolitical Crisis** | **+15%** to all crops | Unpredictable, high-impact market shock. |

### 📝 Futures Contracts

Why risk selling at the bottom of the market? Lock in your price before you even plant the seed.

*   **Create Contracts:** Open the Market Screen (`F10` or ESC Menu) to lock in a specific quantity of a crop at today's price.
*   **Delivery Deadlines:** You have a set number of days to deliver the crop to any sell point. Deliveries automatically count toward your active contracts first.
*   **Payouts & Defaults:** Fulfill the contract to get paid the locked-in rate, even if the market has crashed. But beware — if you miss the deadline without delivering the full quantity, you will be hit with a **15% default penalty** on the unfulfilled amount.

### 📋 In-Game Market Screen

A fully integrated tab in your ESC menu (accessible directly via an action binding, default `F10` if set).

| Tab | What you see |
|---|---|
| **Prices** | Live prices for all commodities, percentage change from base, and a real-time graph of the current session's price trend. |
| **Events** | A list of all currently active world events and their intensity levels. |
| **Contracts** | Your active futures contracts, showing locked prices, delivery progress (%), and remaining deadlines. |

---

## 🔌 Mod Integrations

Market Dynamics detects compatible mods and seamlessly integrates with them.

| Mod | Behaviour |
|---|---|
| **FS25_FuturesMission (BetterContracts)** | Bridges BetterContracts harvest missions with the MDM futures system. Harvest completions trigger a short-lived (-8%) supply spike, dropping prices temporarily. |
| **FS25_UsedPlus** | Fulfilling MDM futures contracts improves your UsedPlus credit score. Defaulting on a contract damages your credit score. A poor credit score will actively increase the penalty rate you pay for defaulting on futures! |

---

## 📥 Installation

**1. Download** `FS25_MarketDynamics.zip` from the [latest release](https://github.com/TheCodingDad-TisonK/FS25_MarketDynamics/releases/latest).

**2. Copy** the ZIP (do not extract) to your mods folder:

| Platform | Path |
|---|---|
| 🪟 Windows | `%USERPROFILE%\Documents\My Games\FarmingSimulator2025\mods\` |
| 🍎 macOS | `~/Library/Application Support/FarmingSimulator2025/mods/` |

**3. Enable** *Market Dynamics* in the in-game mod manager.

---

## 🚜 Quick Start

```
1. Load your farm — Market Dynamics immediately takes over the pricing engine.
2. Check the Market Screen (ESC menu or custom keybind) to see current trends.
3. Notice a price spike? Use the "New Contract" button to lock in that price for 30, 60, or 90 days.
4. Plant and harvest your crop.
5. Deliver the crop to any sell point before the deadline to fulfill the contract and secure the locked price.
6. Keep an eye on the "Events" tab. If a Drought hits, it might be the perfect time to sell stored inventory or write a new contract!
```

---

## 🤝 Contributing

Found a bug? [Open an issue](https://github.com/TheCodingDad-TisonK/FS25_MarketDynamics/issues/new/choose) — the template will walk you through what to include.

Want to contribute code? PRs are welcome on the `development` branch. See `CLAUDE.md` in the repo root for architecture notes and naming conventions.

---

## 📜 License

This mod is licensed under **[CC BY-NC-ND 4.0](https://creativecommons.org/licenses/by-nc-nd/4.0/)**.

You may share it in its original form with attribution. You may not sell it, modify and redistribute it, or reupload it under a different name or authorship. Contributions via pull request are explicitly permitted and encouraged.

**Author:** TisonK & LeGrizzly &nbsp;·&nbsp; **Version:** 1.3.0.0

© 2026 TisonK — See [LICENSE](LICENSE) for full terms.

---

<div align="center">

*Farming Simulator 25 is published by GIANTS Software. This is an independent fan creation, not affiliated with or endorsed by GIANTS Software.*

*Master the market.* 📈

</div>