# Linux Blizzard WoW: Forever Market Feed Sync (`Tools/sync_forever_ah.py`)

This optional companion script pulls live Auction House & Commodity order-book snapshots directly from Blizzard's Battle.net Game Data API (`dynamic-forever-us` / `dynamic-forever-eu` Ruleset endpoints), stores rolling hourly history in a local SQLite database (`~/.local/share/profitable/forever_ah.db`), and generates a lightweight data-only addon (`Interface/AddOns/Profitable_MarketFeed`) that `Profitable` picks up automatically on `/reload`.

- **Zero dependencies**: Uses Python 3 standard library only (`sqlite3`, `urllib.request`, `json`).
- **Completely optional / non-invasive**: Traditional `PriceCheckerForever` users without `Profitable`, and `Profitable` users who don't run this script, are unaffected.

## 1. Create Free Battle.net API Credentials

1. Visit **https://develop.battle.net/** and sign in with your Battle.net account.
2. Open **API Access** → **Create Client**.
3. Fill in:
   - **Client Name**: e.g. `ProfitableLocalSync`
   - **Redirect URL**: `http://localhost` (required by the form even for background scripts)
4. Save to reveal your **Client ID** and **Client Secret** (copy the Secret immediately).

## 2. One-Time Setup & Test Run (US PvP Horde)

```bash
python3 /home/T/Projects/Profitable/Tools/sync_forever_ah.py --setup
python3 /home/T/Projects/Profitable/Tools/sync_forever_ah.py --region us --ruleset 1 --house-id 113
```

*(House ID `113` corresponds to **US PvP Horde** on WoW: Forever.)*

To inspect available auction house IDs on your ruleset:

```bash
python3 /home/T/Projects/Profitable/Tools/sync_forever_ah.py --region us --ruleset 1 --list-houses
```

## 3. Optional Hourly Background Sync (systemd user timer)

```bash
mkdir -p ~/.config/systemd/user
cp /home/T/Projects/Profitable/Tools/systemd/profitable-ah-sync.* ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now profitable-ah-sync.timer
```
