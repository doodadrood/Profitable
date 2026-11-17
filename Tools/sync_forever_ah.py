#!/usr/bin/env python3
"""
Blizzard WoW: Forever Ruleset Auction House & Commodities Sync Tool for Profitable.

Fetches hourly AH + Commodities snapshots from the Battle.net Game Data API
(Ruleset endpoints for WoW: Forever), persists rolling historical observations
in SQLite to compute 14-day median prices (buyout-spike protection), and writes
an ancillary data-only WoW addon (`Profitable_MarketFeed`) that `Profitable`
reads automatically on `/reload`.

Zero external Python dependencies (uses Python 3 standard library only).
"""

from __future__ import annotations

import argparse
import base64
import gzip
import json
import os
import sqlite3
import statistics
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import defaultdict
from pathlib import Path
from typing import Any

DEFAULT_ADDONS_DIR = Path(
    "/run/media/system/Data/Games/Faugus/battlenet/drive_c/Program Files (x86)"
    "/World of Warcraft/_forever_/Interface/AddOns"
)
DEFAULT_DB_PATH = Path.home() / ".local" / "share" / "profitable" / "forever_ah.db"
DEFAULT_CONFIG_PATH = Path.home() / ".config" / "profitable" / "bnet.json"

RULESET_NAMES = {
    1: "PvP",
    2: "Normal",
    3: "Roleplay",
    15: "Roleplay PvP",
}

MAX_ORDER_BOOK_TIERS = 12
DEFAULT_HISTORY_DAYS = 14
DEFAULT_RETENTION_DAYS = 30


def load_credentials(
    client_id_arg: str | None,
    client_secret_arg: str | None,
    config_path: Path,
) -> tuple[str, str]:
    """Load Battle.net API credentials from CLI flags, env vars, or config JSON."""
    client_id = client_id_arg or os.environ.get("BNET_CLIENT_ID")
    client_secret = client_secret_arg or os.environ.get("BNET_CLIENT_SECRET")

    if (not client_id or not client_secret) and config_path.exists():
        data = json.loads(config_path.read_text(encoding="utf-8"))
        client_id = client_id or data.get("client_id")
        client_secret = client_secret or data.get("client_secret")

    if not client_id or not client_secret:
        raise RuntimeError(
            "Missing Battle.net API credentials. Run with `--setup` or set "
            "BNET_CLIENT_ID and BNET_CLIENT_SECRET (or pass --client-id/--client-secret)."
        )
    return client_id.strip(), client_secret.strip()


def save_credentials_interactive(config_path: Path) -> None:
    """Prompt for Battle.net Client ID & Secret and save to ~/.config/profitable/bnet.json."""
    print("Battle.net API Credential Setup (https://develop.battle.net/)")
    client_id = input("Enter Client ID: ").strip()
    client_secret = input("Enter Client Secret: ").strip()
    if not client_id or not client_secret:
        raise RuntimeError("Client ID and Client Secret must not be empty.")

    config_path.parent.mkdir(parents=True, exist_ok=True)
    payload = json.dumps({"client_id": client_id, "client_secret": client_secret}, indent=2)
    config_path.write_text(payload + "\n", encoding="utf-8")
    try:
        os.chmod(config_path, 0o600)
    except OSError:
        pass
    print(f"Saved credentials to {config_path}")


def http_request_json(
    url: str,
    headers: dict[str, str] | None = None,
    post_data: bytes | None = None,
    timeout: int = 45,
) -> dict[str, Any]:
    """Execute an HTTP request and parse JSON (handling gzip responses)."""
    req_headers = {"Accept-Encoding": "gzip", "User-Agent": "Profitable-Forever-Sync/1.0"}
    if headers:
        req_headers.update(headers)

    req = urllib.request.Request(url, data=post_data, headers=req_headers)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        raw = resp.read()
        encoding = resp.headers.get("Content-Encoding", "").lower()
        if "gzip" in encoding:
            raw = gzip.decompress(raw)
        return json.loads(raw.decode("utf-8"))


def fetch_oauth_token(region: str, client_id: str, client_secret: str) -> str:
    """Acquire an OAuth2 client_credentials bearer token from Battle.net."""
    auth_bytes = f"{client_id}:{client_secret}".encode("utf-8")
    b64_auth = base64.b64encode(auth_bytes).decode("ascii")
    token_url = f"https://{region}.battle.net/oauth/token"
    body = urllib.parse.urlencode({"grant_type": "client_credentials"}).encode("ascii")
    resp = http_request_json(
        token_url,
        headers={
            "Authorization": f"Basic {b64_auth}",
            "Content-Type": "application/x-www-form-urlencoded",
        },
        post_data=body,
    )
    token = resp.get("access_token")
    if not token:
        raise RuntimeError(f"Failed to obtain Battle.net OAuth token: {resp}")
    return token


def api_get_forever(region: str, path: str, token: str) -> dict[str, Any]:
    """Query a dynamic-forever-{region} Game Data API endpoint."""
    namespace = f"dynamic-forever-{region}"
    sep = "&" if "?" in path else "?"
    url = f"https://{region}.api.blizzard.com{path}{sep}namespace={namespace}&locale=en_US"
    return http_request_json(url, headers={"Authorization": f"Bearer {token}"})


def fetch_ruleset_houses(region: str, ruleset_id: int, token: str) -> list[dict[str, Any]]:
    """Fetch available auction houses under a WoW: Forever ruleset."""
    for suffix in ("/auctions/index", "/auctions/", "/auctions"):
        try:
            data = api_get_forever(region, f"/data/wow/ruleset/{ruleset_id}{suffix}", token)
            houses = data.get("auctions") or []
            if houses:
                return houses
        except urllib.error.HTTPError as exc:
            if exc.code in (404, 400):
                continue
            raise
    raise RuntimeError(
        f"No auction houses returned for region={region}, ruleset={ruleset_id}."
    )


def select_house(
    houses: list[dict[str, Any]],
    faction: str,
    house_id_override: int | None = None,
) -> tuple[int, str]:
    """Select the target auction house ID and display name by override or faction keyword."""
    if house_id_override is not None:
        for h in houses:
            if h.get("id") == house_id_override:
                return int(house_id_override), str(h.get("name") or f"House {house_id_override}")
        return int(house_id_override), f"House {house_id_override}"

    target = faction.strip().lower()
    for h in houses:
        name = str(h.get("name") or "")
        if target in name.lower():
            return int(h["id"]), name

    available = ", ".join(f"{h.get('id')}:{h.get('name')}" for h in houses)
    raise RuntimeError(f"Could not match faction '{faction}' in houses: {available}")


def aggregate_auction_snapshot(
    item_auctions: list[dict[str, Any]],
    commodity_auctions: list[dict[str, Any]],
    max_tiers: int = MAX_ORDER_BOOK_TIERS,
) -> dict[int, dict[str, Any]]:
    """Aggregate raw Blizzard item auctions and commodities into stepped per-item order books."""
    tier_map: dict[int, dict[int, int]] = defaultdict(lambda: defaultdict(int))
    listing_counts: dict[int, int] = defaultdict(int)

    for row in item_auctions:
        item = row.get("item") or {}
        item_id = int(item.get("id") or 0)
        buyout = int(row.get("buyout") or 0)
        qty = int(row.get("quantity") or 1)
        if item_id > 0 and buyout > 0 and qty > 0:
            unit_price = max(1, buyout // qty)
            tier_map[item_id][unit_price] += qty
            listing_counts[item_id] += 1

    for row in commodity_auctions:
        item = row.get("item") or {}
        item_id = int(item.get("id") or 0)
        unit_price = int(row.get("unit_price") or 0)
        qty = int(row.get("quantity") or 0)
        if item_id > 0 and unit_price > 0 and qty > 0:
            tier_map[item_id][unit_price] += qty
            listing_counts[item_id] += 1

    aggregated: dict[int, dict[str, Any]] = {}
    for item_id, prices_dict in tier_map.items():
        sorted_tiers = sorted(prices_dict.items(), key=lambda pair: pair[0])
        min_unit = sorted_tiers[0][0]
        total_qty = sum(q for _, q in sorted_tiers)

        # Compute quantity-weighted 25th percentile price for snapshot analytics
        target_p25 = max(1, total_qty // 4)
        running_qty = 0
        p25_unit = min_unit
        for up, q in sorted_tiers:
            running_qty += q
            if running_qty >= target_p25:
                p25_unit = up
                break

        aggregated[item_id] = {
            "min_unit_price": min_unit,
            "p25_unit_price": p25_unit,
            "total_quantity": total_qty,
            "listing_count": listing_counts[item_id],
            "tiers": sorted_tiers[:max_tiers],
        }

    return aggregated


def init_sqlite(conn: sqlite3.Connection) -> None:
    """Initialize SQLite schema for historical Forever AH snapshots."""
    conn.executescript(
        """
        PRAGMA journal_mode = WAL;
        CREATE TABLE IF NOT EXISTS snapshots (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            fetched_at INTEGER NOT NULL,
            region TEXT NOT NULL,
            ruleset_id INTEGER NOT NULL,
            house_id INTEGER NOT NULL,
            house_name TEXT NOT NULL,
            item_count INTEGER NOT NULL,
            auction_count INTEGER NOT NULL
        );
        CREATE TABLE IF NOT EXISTS item_observations (
            snapshot_id INTEGER NOT NULL,
            item_id INTEGER NOT NULL,
            min_unit_price INTEGER NOT NULL,
            p25_unit_price INTEGER NOT NULL,
            total_quantity INTEGER NOT NULL,
            listing_count INTEGER NOT NULL,
            PRIMARY KEY (snapshot_id, item_id),
            FOREIGN KEY (snapshot_id) REFERENCES snapshots(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_obs_item_snap
            ON item_observations (item_id, snapshot_id);
        CREATE INDEX IF NOT EXISTS idx_snap_scope_time
            ON snapshots (region, ruleset_id, house_id, fetched_at);
        """
    )
    conn.commit()


def store_snapshot_and_compute_medians(
    db_path: Path,
    fetched_at: int,
    region: str,
    ruleset_id: int,
    house_id: int,
    house_name: str,
    aggregated: dict[int, dict[str, Any]],
    total_raw_auctions: int,
    history_days: int = DEFAULT_HISTORY_DAYS,
    retention_days: int = DEFAULT_RETENTION_DAYS,
) -> dict[int, tuple[int, int]]:
    """Insert snapshot into SQLite, prune old data, and return {item_id: (median14d, obs_count)}."""
    db_path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(db_path))
    try:
        conn.execute("PRAGMA foreign_keys = ON;")
        init_sqlite(conn)

        cur = conn.execute(
            """
            INSERT INTO snapshots (
                fetched_at, region, ruleset_id, house_id, house_name, item_count, auction_count
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            (fetched_at, region, ruleset_id, house_id, house_name, len(aggregated), total_raw_auctions),
        )
        snapshot_id = int(cur.lastrowid)

        obs_rows = [
            (
                snapshot_id,
                item_id,
                data["min_unit_price"],
                data["p25_unit_price"],
                data["total_quantity"],
                data["listing_count"],
            )
            for item_id, data in aggregated.items()
        ]
        conn.executemany(
            """
            INSERT INTO item_observations (
                snapshot_id, item_id, min_unit_price, p25_unit_price, total_quantity, listing_count
            ) VALUES (?, ?, ?, ?, ?, ?)
            """,
            obs_rows,
        )

        # Prune snapshots older than retention_days
        retention_cutoff = fetched_at - (retention_days * 86400)
        conn.execute("DELETE FROM snapshots WHERE fetched_at < ?", (retention_cutoff,))

        # Compute rolling historical median over history_days for this ruleset + house
        history_cutoff = fetched_at - (history_days * 86400)
        rows = conn.execute(
            """
            SELECT o.item_id, o.min_unit_price
            FROM item_observations o
            JOIN snapshots s ON s.id = o.snapshot_id
            WHERE s.region = ?
              AND s.ruleset_id = ?
              AND s.house_id = ?
              AND s.fetched_at >= ?
            """,
            (region, ruleset_id, house_id, history_cutoff),
        ).fetchall()

        conn.commit()
    finally:
        conn.close()

    by_item: dict[int, list[int]] = defaultdict(list)
    for item_id, price in rows:
        by_item[int(item_id)].append(int(price))

    medians: dict[int, tuple[int, int]] = {}
    for item_id, prices in by_item.items():
        med = int(statistics.median(prices))
        medians[item_id] = (med, len(prices))
    return medians


def lua_escape(value: str) -> str:
    """Escape a Python string for safe embedding inside a Lua double-quoted string."""
    return value.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")


def write_market_feed_addon(
    addons_dir: Path,
    fetched_at: int,
    region: str,
    ruleset_id: int,
    house_id: int,
    house_name: str,
    aggregated: dict[int, dict[str, Any]],
    medians: dict[int, tuple[int, int]],
) -> Path:
    """Write the ancillary `Profitable_MarketFeed` WoW addon directory."""
    addon_dir = addons_dir / "Profitable_MarketFeed"
    addon_dir.mkdir(parents=True, exist_ok=True)

    toc_path = addon_dir / "Profitable_MarketFeed.toc"
    toc_content = "\n".join(
        [
            "## Interface: 16001",
            "## Title: Profitable MarketFeed |cff00ccff(Local API Cache)|r",
            "## Notes: Optional offline Blizzard Forever API snapshot & 14-day SQLite historical median feed for Profitable.",
            "## Author: Profitable Local Sync",
            "## Version: 1.0.0",
            "## Dependencies: Profitable",
            "",
            "MarketFeed.lua",
            "",
        ]
    )
    toc_path.write_text(toc_content, encoding="utf-8")

    lua_path = addon_dir / "MarketFeed.lua"
    lines = [
        "-- Auto-generated by Profitable/Tools/sync_forever_ah.py. Do not edit manually.",
        "_G.Profitable_MarketFeed = {",
        f"    timestamp = {fetched_at},",
        f'    region = "{lua_escape(region)}",',
        f"    rulesetId = {ruleset_id},",
        f'    rulesetName = "{lua_escape(RULESET_NAMES.get(ruleset_id, str(ruleset_id)))}",',
        f"    houseId = {house_id},",
        f'    houseName = "{lua_escape(house_name)}",',
        f"    itemCount = {len(aggregated)},",
        "    items = {",
    ]

    for item_id in sorted(aggregated.keys()):
        data = aggregated[item_id]
        med, obs = medians.get(item_id, (data["min_unit_price"], 1))
        tier_strs = [f"{{{up},{qty}}}" for up, qty in data["tiers"]]
        tiers_lua = "{" + ",".join(tier_strs) + "}"
        lines.append(
            f"        [{item_id}] = {{ m = {data['min_unit_price']}, q = {data['total_quantity']}, "
            f"med = {med}, obs = {obs}, tiers = {tiers_lua} }},"
        )

    lines.extend(
        [
            "    },",
            "}",
            "",
            "if _G.PF and _G.PF.MarketFeed and _G.PF.MarketFeed.OnFeedLoaded then",
            "    _G.PF.MarketFeed.OnFeedLoaded()",
            "end",
            "",
        ]
    )
    lua_path.write_text("\n".join(lines), encoding="utf-8")
    return lua_path


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Sync WoW: Forever Blizzard API auctions + SQLite history into Profitable_MarketFeed."
    )
    parser.add_argument("--setup", action="store_true", help="Interactively save Battle.net Client ID & Secret.")
    parser.add_argument("--list-houses", action="store_true", help="List ruleset auction houses and exit.")
    parser.add_argument("--region", default="us", choices=["us", "eu"], help="Battle.net region (default: us).")
    parser.add_argument(
        "--ruleset",
        type=int,
        default=1,
        help="WoW: Forever ruleset ID: 1=PvP, 2=Normal, 3=RP, 15=RP-PvP (default: 1).",
    )
    parser.add_argument(
        "--faction",
        default="horde",
        help="Faction auction house name substring to select (default: horde).",
    )
    parser.add_argument("--house-id", type=int, default=None, help="Explicit house ID override.")
    parser.add_argument("--client-id", default=None, help="Battle.net Client ID.")
    parser.add_argument("--client-secret", default=None, help="Battle.net Client Secret.")
    parser.add_argument("--config-path", type=Path, default=DEFAULT_CONFIG_PATH, help="Credentials JSON path.")
    parser.add_argument("--db-path", type=Path, default=DEFAULT_DB_PATH, help="SQLite history DB path.")
    parser.add_argument("--addons-dir", type=Path, default=DEFAULT_ADDONS_DIR, help="WoW _forever_/Interface/AddOns dir.")
    parser.add_argument("--history-days", type=int, default=DEFAULT_HISTORY_DAYS, help="Rolling median window in days.")
    parser.add_argument("--retention-days", type=int, default=DEFAULT_RETENTION_DAYS, help="SQLite retention in days.")
    parser.add_argument(
        "--json-snapshot",
        type=Path,
        default=None,
        help="Optional local JSON file ({auctions:[...], commodities:[...]}) for offline testing.",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)

    if args.setup:
        save_credentials_interactive(args.config_path)
        return 0

    fetched_at = int(time.time())

    if args.json_snapshot:
        payload = json.loads(args.json_snapshot.read_text(encoding="utf-8"))
        house_id = int(payload.get("house_id") or args.house_id or 6)
        house_name = str(payload.get("house_name") or f"{args.faction.title()} Auction House")
        item_auctions = payload.get("auctions") or []
        commodity_auctions = payload.get("commodities") or []
    else:
        client_id, client_secret = load_credentials(
            args.client_id, args.client_secret, args.config_path
        )
        token = fetch_oauth_token(args.region, client_id, client_secret)
        houses = fetch_ruleset_houses(args.region, args.ruleset, token)

        if args.list_houses:
            print(f"Houses for region={args.region}, ruleset={args.ruleset} ({RULESET_NAMES.get(args.ruleset, 'Unknown')}):")
            for h in houses:
                print(f"  id={h.get('id')}  name={h.get('name')}")
            return 0

        house_id, house_name = select_house(houses, args.faction, args.house_id)
        item_resp = api_get_forever(
            args.region, f"/data/wow/ruleset/{args.ruleset}/auctions/{house_id}", token
        )
        item_auctions = item_resp.get("auctions") or []

        commodity_auctions = []
        try:
            comm_resp = api_get_forever(
                args.region,
                f"/data/wow/ruleset/{args.ruleset}/auctions/{house_id}/commodities",
                token,
            )
            commodity_auctions = comm_resp.get("auctions") or []
        except urllib.error.HTTPError as exc:
            if exc.code != 404:
                raise

    aggregated = aggregate_auction_snapshot(item_auctions, commodity_auctions)
    total_raw = len(item_auctions) + len(commodity_auctions)

    medians = store_snapshot_and_compute_medians(
        db_path=args.db_path,
        fetched_at=fetched_at,
        region=args.region,
        ruleset_id=args.ruleset,
        house_id=house_id,
        house_name=house_name,
        aggregated=aggregated,
        total_raw_auctions=total_raw,
        history_days=args.history_days,
        retention_days=args.retention_days,
    )

    lua_path = write_market_feed_addon(
        addons_dir=args.addons_dir,
        fetched_at=fetched_at,
        region=args.region,
        ruleset_id=args.ruleset,
        house_id=house_id,
        house_name=house_name,
        aggregated=aggregated,
        medians=medians,
    )

    print(
        f"[Profitable Sync] {house_name} (region={args.region}, ruleset={args.ruleset}, house={house_id}): "
        f"{total_raw} raw listings -> {len(aggregated)} unique items written to {lua_path} "
        f"(SQLite history: {args.db_path}). /reload in WoW to load."
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"[Profitable Sync Error] {exc}", file=sys.stderr)
        raise SystemExit(1)
