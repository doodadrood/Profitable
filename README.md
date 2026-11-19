# Profitable (PF) — WoW: Forever Gold-Making Companion for PriceCheckerForever

**Profitable** bundles [PriceCheckerForever (PCF)](https://github.com/doodadrood/PriceCheckerForever) out of the box (and cooperates cleanly if standalone PCF is also installed) to analyze local Auction House scan data, your character's current gold balance, known crafting recipes, NPC vendor reagent prices, and Classic/Forever disenchant tables to surface the **Top 5 most profitable plays** you can make right now.

## Features

1. **Five Core Gold-Making Strategies**:
   - **Vendor `[Item]`**: Buy underpriced items on the AH below their NPC vendor sell price.
   - **Craft and Vendor `[Item]`**: Buy raw materials (using NPC vendor buy prices for threads, fluxes, vials, spices, coal, salt, etc., and AH prices for trade goods) to craft items whose NPC vendor sell price exceeds total material cost.
   - **Craft and AH `[Item]`**: Convert raw materials (smelting ore to bars, weaving cloth to bolts, grinding stones, crafting gear/consumables/enhancements) and resell on the AH (accounting for the 5% AH cut).
   - **Craft and DE `[Item]`**: Craft uncommon/rare armor or weapons and disenchant them on your bank alt/enchanter when the expected enchanting material value (after 5% AH cut, including 3:1 Lesser/Greater Essence conversion awareness) beats crafting cost.
   - **Buy and DE `[Item]`**: Buy underpriced uncommon/rare/epic armor or weapons on the AH to disenchant for profit.
   - **Intermediate Material Chains**: Automatically evaluates whether smelting bars / weaving bolts from raw ore/cloth is cheaper than buying intermediate materials directly.

2. **Stepped AH Order-Book Verification**:
   - Double-checks the live Auction House for the top candidates' materials and outputs.
   - Walks the actual listing tiers (`1x @ 5s`, `10x @ 12s`, etc.) unit-by-unit within your character's current gold (`GetMoney()`), stopping automatically when the next price tier is no longer profitable or your gold budget is reached.

3. **Auction House Side Window & Persistent Execution Tracker**:
   - Docks a **Top 5 AH Plays** window to the right side of the Auction House.
   - Clicking any play (1–5) opens the **Opportunity Breakdown & Shopping List** window, which stays open outside the AH so you can track live bag/mailbox quantities (`Have: X / Y`) as you collect mail and click **Open Recipe** to craft.
   - Includes 1-click **Search AH** buttons and clickable `[Item Links]` (Shift+Click to fill the AH search bar).

## Slash Commands

- `/pf` or `/profitable` — Toggle the Profitable AH side window
- `/pf run` — Discover and verify the Top 5 profitable plays
- `/pf detail <1-5>` — Open the breakdown & shopping tracker for play #1–#5
- `/pf de` — Toggle Disenchant plays on/off (Default: ON)
- `/pf alts` — Toggle including recipes scanned on your other characters
