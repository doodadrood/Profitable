package.path = package.path .. ";../?.lua;./?.lua"

local Mock = require("Tests.MockWoWAPI")

-- Setup PriceCheckerForever Mock DB
_G.PCF_DB = {
    prices = {},
    lastFullScan = Mock.currentTime,
}

require("Config")
require("Utils.Formatter")
require("Data.VendorDatabase")
require("Data.DisenchantDatabase")
require("Data.RecipeDatabase")
require("Modules.RecipeScanner")
require("Modules.MarketFeed")
require("Modules.AuctionatorSource")
require("Modules.OpportunityEngine")
require("Modules.AHVerifier")
require("UI.DetailWindow")
require("UI.SideWindow")
require("Core")

PF.Initialize()

local function Assert(condition, testName)
    if condition then
        print(string.format("[PASS] %s", testName))
    else
        print(string.format("[FAIL] %s", testName))
        error("Test assertion failed: " .. testName)
    end
end

-- 1. Formatter Tests
Assert(PF.Formatter.FormatMoney(220000) == "22g", "Format 22g")
Assert(PF.Formatter.FormatMoney(24500) == "2g 45s", "Format 2g 45s")
Assert(PF.Formatter.FormatMoneyShort(24500) == "2g45s", "Format compact 2g45s")
Assert(PF.Formatter.FormatMoneyShort(220000) == "22g", "Format compact 22g")
Assert(PF.Formatter.GetPlayerGold() == 220000, "Read player gold from GetMoney()")

-- 2. Vendor Database Tests
Assert(PF.VendorDatabase.GetVendorBuyPrice(2320) == 10, "Coarse Thread vendor buy price is 10c")
Assert(PF.VendorDatabase.GetVendorBuyPrice(2880) == 100, "Weak Flux vendor buy price is 1s (100c)")
Assert(PF.VendorDatabase.GetVendorBuyPrice(3857) == 500, "Coal vendor buy price is 5s (500c)")
Assert(PF.VendorDatabase.GetVendorSellPrice(2852) == 67, "Copper Chain Pants vendor sell price is 67c")

-- 3. Disenchant Database & 3:1 Essence Conversion Tests
Assert(PF.DisenchantDatabase.CanDisenchant(5541) == true, "Iridescent Hammer (Green Weapon) is disenchantable")
Assert(PF.DisenchantDatabase.CanDisenchant(2447) == false, "Peacebloom (Trade Good) is not disenchantable")
Assert(PF.DisenchantDatabase.CanDisenchant(11288) == false, "Greater Magic Wand (Crafted Wand) is excluded from DE")
Assert(PF.DisenchantDatabase.CanDisenchant(217287) == false, "Greater Mystic Wand (WoW: Forever Crafted Wand) is excluded from DE")

-- Set enchanting mat prices in PCF_DB:
-- Iridescent Hammer (5541) is ilvl 28 Uncommon Weapon:
-- 75% Greater Astral Essence (11082, 1-2 avg 1.5), 20% Soul Dust (11083, 1-2 avg 1.5), 5% Large Glimmering Shard (11084, 1)
_G.PCF_DB.prices[11082] = { minBuyout = 40000, count = 20, lastUpdated = Mock.currentTime } -- 4g ea
_G.PCF_DB.prices[11083] = { minBuyout = 5000,  count = 50, lastUpdated = Mock.currentTime } -- 50s ea
_G.PCF_DB.prices[11084] = { minBuyout = 80000, count = 10, lastUpdated = Mock.currentTime } -- 8g ea

local deHammer = PF.DisenchantDatabase.EvaluateDisenchant(5541, nil, PF.OpportunityEngine.ResolveAHPrice, 0.05)
-- Expected gross: 0.75 * 1.5 * 40000 (45000) + 0.20 * 1.5 * 5000 (1500) + 0.05 * 1 * 80000 (4000) = 50500 (5g 05s)
-- Expected net (after 5% cut): 50500 * 0.95 = 47975
Assert(deHammer ~= nil and deHammer.grossValue == 50500 and deHammer.netValue == 47975, "Compute exact expected DE value for Iridescent Hammer")

-- Test 3:1 Lesser -> Greater Essence conversion when Greater Essence is more valuable
_G.PCF_DB.prices[10938] = { minBuyout = 500,  count = 30, lastUpdated = Mock.currentTime } -- Lesser Magic: 5s
_G.PCF_DB.prices[10939] = { minBuyout = 3000, count = 30, lastUpdated = Mock.currentTime } -- Greater Magic: 30s (so 1 Lesser = 10s when combined 3->1!)
_G.PCF_DB.prices[10940] = { minBuyout = 200,  count = 50, lastUpdated = Mock.currentTime } -- Strange Dust: 2s
local deRobe = PF.DisenchantDatabase.EvaluateDisenchant(6238, nil, PF.OpportunityEngine.ResolveAHPrice, 0.05)
Assert(deRobe ~= nil and deRobe.drops[2].unitPrice == 1000 and deRobe.drops[2].conversionNote ~= nil, "Auto-detect profitable 3->1 Lesser to Greater Magic Essence conversion")

-- 4. Recipe Scanner Tests
Mock.tradeSkillLine = "Blacksmithing"
Mock.tradeSkills = {
    {
        name = "Copper Chain Pants",
        outputItemId = 2852,
        minMade = 1,
        maxMade = 1,
        reagents = {
            { itemId = 2840, name = "Copper Bar", count = 4 },
        },
    },
    {
        name = "Solid Grinding Stone",
        outputItemId = 7966,
        minMade = 1,
        maxMade = 1,
        reagents = {
            { itemId = 7912, name = "Solid Stone", count = 4 },
        },
    },
    {
        name = "Iridescent Hammer",
        outputItemId = 5541,
        minMade = 1,
        maxMade = 1,
        reagents = {
            { itemId = 2841, name = "Bronze Bar", count = 10 },
            { itemId = 5500, name = "Iridescent Pearl", count = 1 },
            { itemId = 2880, name = "Weak Flux", count = 2 }, -- Vendor reagent (1s each)
        },
    },
    {
        name = "Mithril Shield Spike",
        outputItemId = 7967,
        minMade = 1,
        maxMade = 1,
        reagents = {
            { itemId = 3860, name = "Mithril Bar", count = 4 },
            { itemId = 6037, name = "Truesilver Bar", count = 2 },
            { itemId = 7966, name = "Solid Grinding Stone", count = 4 },
        },
    },
}
local scannedCount = PF.RecipeScanner.ScanCurrentProfessionWindow()
Assert(scannedCount == 4, "Scan 4 Blacksmithing recipes from TradeSkill window")

-- 5. Stepped Order-Book Pricing & Marginal Profit Cutoff Test (Peacebloom Example!)
-- Peacebloom (2447) vendor sell is 10c.
-- Suppose live AH has:
--   Listing 1: 1x Peacebloom @ 2c  (+8c profit)
--   Listing 2: 4x Peacebloom @ 6c  (+4c profit each = +16c)
--   Listing 3: 50x Peacebloom @ 15c (-5c loss each — MUST NOT BUY!)
local steppedBooks = {
    [2447] = {
        { unitPrice = 2,  quantity = 1 },
        { unitPrice = 6,  quantity = 4 },
        { unitPrice = 15, quantity = 50 },
    }
}
local peacebloomCand = {
    actionType = "VENDOR",
    itemId = 2447,
    itemName = "Peacebloom",
    unitGrossRevenue = 10,
    unitNetRevenue = 10,
    maxUnits = 200,
    rawReagents = { { itemId = 2447, name = "Peacebloom", count = 1 } },
}
-- Note: lower minProfitCopper temporarily to test copper-level Peacebloom math
Profitable_DB.settings.minProfitCopper = 10
local pbOpp = PF.OpportunityEngine.CalculateSteppedOpportunity(peacebloomCand, 220000, steppedBooks)
Assert(pbOpp ~= nil, "Calculate stepped Peacebloom opportunity")
Assert(pbOpp.quantity == 5, "Buy exactly 5 Peacebloom (1 @ 2c + 4 @ 6c) and stop before unprofitable 15c listing")
Assert(pbOpp.totalCost == 26, "Exact stepped cost is 1*2c + 4*6c = 26c")
Assert(pbOpp.totalProfit == 24, "Exact stepped profit is 50c - 26c = 24c")
Assert(pbOpp.stoppedReason == "PRICE_TIER_UNPROFITABLE", "Record stop reason as PRICE_TIER_UNPROFITABLE")
Profitable_DB.settings.minProfitCopper = 100

-- 6. Top 5 End-to-End Discovery, Live AH Verification, SideWindow & DetailWindow Test
-- Configure PCF_DB prices so all 5 example plays are profitable within 22g (220,000c) budget:
-- 1) Vendor [Peacebloom] (temporarily give Peacebloom a custom vendor sell in itemCache to simulate a 22g vendor flip)
Profitable_DB.itemCache[2447] = { name = "Peacebloom", quality = 1, itemLevel = 1, classID = 7, vendorSell = 13500 }
_G.PCF_DB.prices[2447] = { minBuyout = 11000, count = 20, lastUpdated = Mock.currentTime } -- Cost 22g (20*1g10s), Vendor 27g (20*1g35s) -> Profit 5g!

-- 2) Craft and Vendor [Copper Chain Pants] (2852)
-- Give Copper Chain Pants vendorSell = 12500 (1g 25s), Copper Bar (2840) = 2750 (27s 50c) x 4 = 1g 10s per craft -> 20 crafts = Cost 22g, Profit 3g!
Profitable_DB.itemCache[2852] = { name = "Copper Chain Pants", quality = 2, itemLevel = 10, classID = 4, invType = "INVTYPE_LEGS", vendorSell = 12500 }
_G.PCF_DB.prices[2840] = { minBuyout = 2750, count = 80, lastUpdated = Mock.currentTime }

-- 3) Craft and AH [Solid Grinding Stone] (7966)
-- Solid Stone (7912) = 275c x 4 = 1100c (11s) per craft. 20 crafts = Cost 22g (220,000c -> let's set Solid Stone = 2750c (27s50c) x 4 = 1g10s * 20 = 22g)
-- Solid Grinding Stone AH buyout = 12868c -> after 5% cut = 12225c * 20 = 244,500c -> Profit 2g 45s!
_G.PCF_DB.prices[7912] = { minBuyout = 2750, count = 80, lastUpdated = Mock.currentTime }
_G.PCF_DB.prices[7966] = { minBuyout = 12868, count = 20, lastUpdated = Mock.currentTime }

-- 4) Craft and DE [Iridescent Hammer] (5541)
-- Net DE value is 47,975c (~4g 80s). Make 5 crafts cost 20g (40,000c per craft):
-- 10x Bronze Bar (2841) @ 3500c (35s) = 35,000c + 1x Iridescent Pearl (5500) @ 4800c + 2x Weak Flux (vendor 100c) = 200c -> 40,000c (4g) per craft!
-- 5 crafts = Cost 20g (200,000c), Net DE Rev = 239,875c -> Profit ~3g 98s!
_G.PCF_DB.prices[2841] = { minBuyout = 3500, count = 50, lastUpdated = Mock.currentTime }
_G.PCF_DB.prices[5500] = { minBuyout = 4800, count = 5,  lastUpdated = Mock.currentTime }

-- 5) Craft and AH [Mithril Shield Spike] (7967)
-- Uses 4x Mithril Bar (3860) @ 1000c + 2x Truesilver Bar (6037) @ 1000c + 4x Solid Grinding Stone (crafted from 16x Solid Stone @ 2750c = 44,000c) -> 50,000c (5g) per craft.
-- 4 crafts = Cost 20g (200,000c). Sell on AH @ 58,000c gross (55,100c net) * 4 = 220,400c -> Profit 2g 04s!
_G.PCF_DB.prices[3860] = { minBuyout = 1000, count = 20, lastUpdated = Mock.currentTime }
_G.PCF_DB.prices[6037] = { minBuyout = 1000, count = 20, lastUpdated = Mock.currentTime }
_G.PCF_DB.prices[7967] = { minBuyout = 58000, count = 10, lastUpdated = Mock.currentTime }

-- Populate live AH listings for verification
Mock.auctionListingsByQuery["Peacebloom"] = {
    { itemId = 2447, name = "Peacebloom", count = 5,  buyoutPrice = 5 * 10400 }, -- 5 cheap @ 1g 04s
    { itemId = 2447, name = "Peacebloom", count = 15, buyoutPrice = 15 * 11200 }, -- 15 @ 1g 12s (total = 52,000 + 168,000 = 220,000c = 22g!)
}

-- Trigger SideWindow search + live AH verification
PF.SideWindow.eventFrame:Trigger("AUCTION_HOUSE_SHOW")
PF.SideWindow.RunSearch()
Mock.FlushTimers(50)

local topPlays = Profitable_DB.lastTopPlays
Assert(type(topPlays) == "table" and #topPlays == 5, "Discover and verify Top 5 opportunities")
Assert(topPlays[1].actionLabel == "Vendor" and topPlays[1].itemId == 2447, "Top #1 play is Vendor [Peacebloom]")
Assert(topPlays[1].verified == true, "Top #1 play is marked Verified after live AH check")
Assert(#topPlays[1].shoppingList[1].tiersUsed == 2, "Top #1 play uses stepped 2-tier order book from live AH verification")

-- Verify summary line format matches user specification: "1. Vendor [Peacebloom] (Cost 22g, Profit 5g)"
Assert(topPlays[1].summaryLine:find("^1%. Vendor .*Peacebloom.* %(Cost 22g, Profit 5g%)") ~= nil, "Format Top #1 summary line matching requested layout")

-- 7. Test Clicking Play #1 -> Opens DetailWindow, Tracks Bags/Mailbox, and Searches AH
local row1Btn = _G["PF_SideWindowPlayButton1"]
Assert(row1Btn ~= nil, "SideWindow play button 1 exists")
row1Btn:Click()

local detailFrame = PF.DetailWindow.frame
Assert(detailFrame ~= nil and detailFrame:IsShown(), "Clicking play #1 opens DetailWindow")

-- Simulate looting 8 Peacebloom from Mailbox and triggering BAG_UPDATE
Mock.bagCounts[2447] = 8
detailFrame:Trigger("BAG_UPDATE")
local row1Shop = detailFrame.shoppingRows[1]
Assert(row1Shop.statusText:GetText():find("Have: 8 / 20") ~= nil, "DetailWindow live-tracks inventory count (8 / 20) on BAG_UPDATE")

-- Click "Search AH" button on Shopping Row 1
row1Shop.searchBtn:Click()
Assert(Mock.lastAuctionQuery == "Peacebloom" and _G.BrowseName:GetText() == "Peacebloom", "Clicking Search AH populates BrowseName and queries AH for Peacebloom")

-- Test DetailWindow stays open when Auction House closes
PF.SideWindow.eventFrame:Trigger("AUCTION_HOUSE_CLOSED")
Assert(detailFrame:IsShown() == true, "DetailWindow stays open outside the Auction House for Mailbox/Crafting tracking")

-- Test Open Recipe button on a Crafting play
Mock.selectedTradeSkill = nil
Mock.castSpells = {}
PF.DetailWindow.ShowOpportunity(topPlays[2])
detailFrame.recipeBtn:Click()
Assert(Mock.selectedTradeSkill ~= nil, "Clicking Open Recipe opens crafting window and selects recipe")
Assert(Mock.craftedTradeSkill == nil, "Clicking Open Recipe does not auto-craft without user crafting")
PF.RecipeScanner.CraftRecipe(topPlays[2].recipe, 1)
Assert(Mock.craftedTradeSkill ~= nil, "CraftRecipe directly triggers crafting when called explicitly")

-- 8. Test One-Click "Buy Next" Button in DetailWindow
PF.DetailWindow.ShowOpportunity(topPlays[1])
Mock.placedBids = {}
Mock.currentAuctionResults = Mock.auctionListingsByQuery["Peacebloom"]
row1Shop.buyBtn:Click()
Assert(#Mock.placedBids == 1 and Mock.placedBids[1].index == 1 and Mock.placedBids[1].amount == (5 * 10400), "Clicking Buy Next purchases the cheapest qualifying AH listing (5x @ 1g 04s)")

-- 9. Test 5% Faction AH Cut vs 15% Neutral AH Cut & Gear Deposit Risk
local solidPlay = nil
for _, p in ipairs(topPlays) do
    if p.itemId == 7966 then solidPlay = p end
end
Assert(solidPlay ~= nil and solidPlay.ahCutRate == 0.05 and solidPlay.totalAHCut > 0, "5% Faction AH cut is deducted and recorded on Craft and AH plays")

Mock.depositRate = 25 -- Simulate Neutral AH (Gadgetzan / Booty Bay)
Assert(PF.GetEffectiveAHCutRate() == 0.15, "Auto-detect 15% AH cut when at a Neutral Auction House")
Mock.depositRate = 5
Assert(PF.GetEffectiveAHCutRate() == 0.05, "Restore 5% AH cut at Faction Auction House")

-- Verify slow-moving gear Craft and AH deducts expected 15% vendor deposit risk and caps units at maxAHGearUnits (3)
local gearCand = {
    actionType = "CRAFT_AH",
    itemId = 5541, -- Iridescent Hammer (Weapon, vendorSell = 3693)
    itemName = "Iridescent Hammer",
    ahCutRate = 0.05,
    unitGrossRevenue = 60000,
    unitAHCut = 3000,
    unitDepositRisk = math.floor(3693 * 0.15),
    unitNetRevenue = 60000 - 3000 - math.floor(3693 * 0.15),
    maxUnits = Profitable_DB.settings.maxAHGearUnits,
    rawReagents = { { itemId = 2841, name = "Bronze Bar", count = 10 } },
}
local gearOpp = PF.OpportunityEngine.CalculateSteppedOpportunity(gearCand, 220000)
Assert(gearOpp ~= nil and gearOpp.quantity == 3 and gearOpp.totalDepositRisk == (3 * math.floor(3693 * 0.15)), "Cap slow-moving AH gear crafts at 3 units and deduct expected AH deposit risk")

-- 10. Test Baseline Skill-Matched Recipes & Trainer Recommendations
Mock.skillLines = {
    { name = "Blacksmithing", isHeader = false, rank = 250, maxRank = 300 },
    { name = "Tailoring", isHeader = false, rank = 240, maxRank = 300 },
}
local allKnownAndRecommended = PF.RecipeScanner.GetKnownRecipes()
local foundRuneclothBeltTrainer = false
for _, rec in ipairs(allKnownAndRecommended) do
    if rec.outputItemId == 13856 and rec.isTrainerRecommendation then
        foundRuneclothBeltTrainer = true
    end
end
Assert(foundRuneclothBeltTrainer == true, "Recommend Runecloth Belt (Skill 255) for a 240 Tailoring character via Trainer Lookahead")
Mock.skillLines = {}

-- 11. Test Limited-Supply NPC Vendor Arbitrage Alert (after 5% AH cut)
Mock.merchantItems = {
    { itemId = 10940, name = "Strange Dust", price = 80, quantity = 1, numAvailable = 5 }, -- 80c at vendor, 50s on AH (47s 50c net after 5% cut)
}
_G.PCF_DB.prices[10940] = { minBuyout = 5000, count = 40, lastUpdated = Mock.currentTime }
PF.VendorDatabase.ScanOpenMerchant()
Assert(#Profitable_DB.vendorAlerts == 1 and Profitable_DB.vendorAlerts[1].itemId == 10940 and Profitable_DB.vendorAlerts[1].unitAHNet == 4750, "Detect limited-supply vendor arbitrage opportunity with 5% AH cut deducted")

-- 12. Test Modern C_AuctionHouse + Auctionator Navigation & 2-Step Commodity Purchase Flow
_G.AuctionHouseFrame = _G.CreateFrame("Frame", "AuctionHouseFrame", _G.UIParent)
local selectedBrowseRow = nil
_G.AuctionHouseFrame.SelectBrowseResult = function(self, rowData)
    selectedBrowseRow = rowData
end

local startedPurchase = nil
local confirmedPurchase = nil
local cancelledPurchase = false
local itemKeyCache = {}

_G.C_AuctionHouse = {
    MakeItemKey = function(itemId)
        return { itemID = itemId, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 }
    end,
    GetItemKeyInfo = function(itemKey)
        return itemKeyCache[itemKey.itemID]
    end,
    SendSearchQuery = function(itemKey, sorts, splitOwned)
        Mock.lastModernSearchKey = itemKey
    end,
    GetNumCommoditySearchResults = function(itemId)
        if itemId == 2447 then return 3 end
        return 0
    end,
    GetCommoditySearchResultInfo = function(itemId, idx)
        if itemId == 2447 then
            local tiers = {
                { unitPrice = 10400, quantity = 5 },  -- 5 @ 1g 04s (<= max 1g 12s)
                { unitPrice = 11200, quantity = 15 }, -- 15 @ 1g 12s (<= max 1g 12s)
                { unitPrice = 18000, quantity = 50 }, -- 50 @ 1g 80s (> max 1g 12s, must NOT buy!)
            }
            return tiers[idx]
        end
        return nil
    end,
    StartCommoditiesPurchase = function(itemId, qty)
        startedPurchase = { itemId = itemId, quantity = qty }
    end,
    ConfirmCommoditiesPurchase = function(itemId, qty)
        confirmedPurchase = { itemId = itemId, quantity = qty }
    end,
    CancelCommoditiesPurchase = function()
        cancelledPurchase = true
    end,
}

-- Simulate delayed ItemKeyInfo arrival via ITEM_KEY_ITEM_INFO_RECEIVED
Mock.bagCounts[2447] = 0
PF.DetailWindow.ShowOpportunity(topPlays[1])
row1Shop.searchBtn:Click()
Assert(selectedBrowseRow == nil, "Wait for ITEM_KEY_ITEM_INFO_RECEIVED when GetItemKeyInfo is not yet cached")
itemKeyCache[2447] = { itemID = 2447, itemName = "Peacebloom", isCommodity = true, quality = 1 }
PF.AHVerifier.frame:Trigger("ITEM_KEY_ITEM_INFO_RECEIVED", 2447)
Assert(selectedBrowseRow ~= nil and selectedBrowseRow.itemKey.itemID == 2447, "SelectBrowseResult opens item Buy screen once ITEM_KEY_ITEM_INFO_RECEIVED fires")

-- Refresh DetailWindow and verify button now shows "Buy 20x" (5 + 15, ignoring the 50 @ 1g 80s)
PF.DetailWindow.RefreshIfShown()
Assert(row1Shop.buyBtn:GetText() == "Buy 20x", "Buy button updates to 'Buy 20x' when commodity search results are loaded")

-- Click 1: Starts commodity purchase for 20 units and updates button to "Confirm (20)"
row1Shop.buyBtn:Click()
Assert(startedPurchase ~= nil and startedPurchase.itemId == 2447 and startedPurchase.quantity == 20, "Click 1 calls C_AuctionHouse.StartCommoditiesPurchase(2447, 20)")
Assert(row1Shop.buyBtn:GetText() == "Confirm (20)", "Button updates to 'Confirm (20)' awaiting hardware click confirmation")

-- Simulate server COMMODITY_PRICE_UPDATED within allowed maxUnitPrice
PF.AHVerifier.frame:Trigger("COMMODITY_PRICE_UPDATED", 11000, 220000)

-- Click 2: Confirms the commodity purchase
row1Shop.buyBtn:Click()
Assert(confirmedPurchase ~= nil and confirmedPurchase.itemId == 2447 and confirmedPurchase.quantity == 20, "Click 2 calls C_AuctionHouse.ConfirmCommoditiesPurchase(2447, 20)")

-- Verify price spike protection cancels purchase if COMMODITY_PRICE_UPDATED exceeds maxUnitPrice
row1Shop.buyBtn:Click() -- Start another quote
PF.AHVerifier.frame:Trigger("COMMODITY_PRICE_UPDATED", 19000, 380000) -- Spiked above 11200 max!
Assert(cancelledPurchase == true and row1Shop.buyBtn:GetText() == "Buy 20x", "Auto-cancel commodity purchase if server price spikes above maxUnitPrice")

-- 13. Test Non-Commodity Equipment Purchase (Duskwoven Sash / Silver-lined Belt)
-- Ensure:
-- (a) Exact itemKey with non-zero itemLevel/itemSuffix is harvested from BrowseResults
-- (b) PlaceBid is called WITHOUT calling SelectBrowseResult/SendSearchQuery on the same click (avoiding throttle drop)
-- (c) Clicking Buy 1x twice buys auctionID #101 first and auctionID #102 second (never re-bidding on #101)
local placedModernBids = {}
local selectBrowseCallsDuringBuy = 0
_G.C_AuctionHouse.GetBrowseResults = function()
    return {
        {
            itemKey = { itemID = 10056, itemLevel = 31, itemSuffix = 12, battlePetSpeciesID = 0 },
            minPrice = 3400,
            totalQuantity = 2,
        }
    }
end
itemKeyCache[10056] = { itemID = 10056, itemName = "Duskwoven Sash", isCommodity = false, quality = 2 }
_G.C_AuctionHouse.GetNumItemSearchResults = function(key)
    -- Only returns > 0 when queried with the real itemLevel=31, itemSuffix=12 itemKey!
    if type(key) == "table" and key.itemID == 10056 and key.itemLevel == 31 and key.itemSuffix == 12 then
        return 2
    end
    return 0
end
_G.C_AuctionHouse.GetItemSearchResultInfo = function(key, idx)
    if type(key) == "table" and key.itemID == 10056 and key.itemLevel == 31 then
        local rows = {
            { auctionID = 101, buyoutAmount = 3400, quantity = 1, containsOwnerItem = false },
            { auctionID = 102, buyoutAmount = 3500, quantity = 1, containsOwnerItem = false },
        }
        return rows[idx]
    end
    return nil
end
_G.C_AuctionHouse.PlaceBid = function(auctionID, buyoutAmount)
    table.insert(placedModernBids, { auctionID = auctionID, buyoutAmount = buyoutAmount })
end

-- Harvest browse itemKey and open Duskwoven Sash
PF.AHVerifier.frame:Trigger("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
PF.AHVerifier.SearchItemOnAH(10056, "Duskwoven Sash", nil, 2)

_G.AuctionHouseFrame.SelectBrowseResult = function(self, rowData)
    selectBrowseCallsDuringBuy = selectBrowseCallsDuringBuy + 1
end

local okBuy1 = PF.AHVerifier.BuyNextCheapListing(10056, "Duskwoven Sash", 4000, 2)
Assert(okBuy1 == true and #placedModernBids == 1 and placedModernBids[1].auctionID == 101 and placedModernBids[1].buyoutAmount == 3400, "First click on non-commodity equipment calls PlaceBid(101, 3400)")
Assert(selectBrowseCallsDuringBuy == 0, "Do NOT call SelectBrowseResult/SendSearchQuery on the same click before PlaceBid")

local okBuy2 = PF.AHVerifier.BuyNextCheapListing(10056, "Duskwoven Sash", 4000, 2)
Assert(okBuy2 == true and #placedModernBids == 2 and placedModernBids[2].auctionID == 102 and placedModernBids[2].buyoutAmount == 3500, "Second click advances to next auctionID (102 @ 35s) instead of repeating auctionID 101")

-- 14. Test End-Result DE Material Lane Aggregation & Honorable Mentions (Craft & Vendor)
-- Simulate 5 different Rare (Blue) items at ilvl 28 that ALL disenchant into Large Glimmering Shard (11084, 8g on AH)
for i = 1, 5 do
    local blueId = 90000 + i
    Profitable_DB.itemCache[blueId] = {
        name = "Rare Blue Sword #" .. i,
        quality = 3,
        itemLevel = 28,
        classID = 2,
        invType = "INVTYPE_WEAPON",
        vendorSell = 5000,
    }
    -- Listed at 1g + i*10s each (all well below 7g 60s net DE value of Large Glimmering Shard!)
    _G.PCF_DB.prices[blueId] = { minBuyout = 10000 + (i * 1000), count = 1, lastUpdated = Mock.currentTime }
end

-- Also add 2 extra lower-profit DE material markets so Top 5 can be filled by distinct DE mats, pushing Craft/Vendor to Honorable Mentions
_G.PCF_DB.prices[11137] = { minBuyout = 40000, count = 50, lastUpdated = Mock.currentTime } -- Vision Dust = 4g
_G.PCF_DB.prices[11176] = { minBuyout = 50000, count = 50, lastUpdated = Mock.currentTime } -- Dream Dust = 5g
Profitable_DB.itemCache[90010] = { name = "Vision Green Armor", quality = 2, itemLevel = 38, classID = 4, invType = "INVTYPE_CHEST", vendorSell = 1000 }
_G.PCF_DB.prices[90010] = { minBuyout = 10000, count = 5, lastUpdated = Mock.currentTime }
Profitable_DB.itemCache[90011] = { name = "Dream Green Armor", quality = 2, itemLevel = 48, classID = 4, invType = "INVTYPE_CHEST", vendorSell = 1000 }
_G.PCF_DB.prices[90011] = { minBuyout = 10000, count = 5, lastUpdated = Mock.currentTime }

local top5Lanes, _, honorableMentions = PF.OpportunityEngine.FindTopOpportunities(220000)

-- Count how many rows in Top 5 have endResultKey == "DE_MAT:11084" (Large Glimmering Shard)
local lgsCount = 0
local lgsPlay = nil
for _, p in ipairs(top5Lanes) do
    if p.endResultKey == "DE_MAT:11084" then
        lgsCount = lgsCount + 1
        lgsPlay = p
    end
end
Assert(lgsCount == 1, "All 5 Rare items that DE into Large Glimmering Shard aggregate into exactly 1 Top-5 row")
Assert(lgsPlay ~= nil and lgsPlay.distinctItemCount == 5 and #lgsPlay.shoppingList == 5, "Aggregated Large Glimmering Shard play contains all 5 distinct blue items in its shopping list")
Assert(lgsPlay.summaryLine:find("Large Glimmering Shard") ~= nil and lgsPlay.summaryLine:find("5 items") ~= nil, "Summary line shows aggregated target DE material and item count")

-- Verify no two plays in Top 5 share the same endResultKey
local seenKeys = {}
local anyDuplicateKey = false
for _, p in ipairs(top5Lanes) do
    if seenKeys[p.endResultKey] then anyDuplicateKey = true end
    seenKeys[p.endResultKey] = true
end
Assert(anyDuplicateKey == false, "Zero duplicate end-result markets across all Top 5 rows")

-- Verify Honorable Mentions surface Top Craft and/or Top Vendor plays not in Top 5
Assert(type(honorableMentions) == "table" and #honorableMentions >= 1, "Compute Honorable Mentions for best Craft / Vendor plays")
Profitable_DB.lastTopPlays = top5Lanes
Profitable_DB.lastHonorableMentions = honorableMentions
PF.SideWindow.RefreshRows()
local hmBtn1 = _G["PF_SideWindowHMButton1"]
Assert(hmBtn1 ~= nil and hmBtn1:IsShown() and hmBtn1._opportunity ~= nil, "SideWindow displays Honorable Mention button 1")

-- 15. Test DetailWindow Dynamic Anchoring & Mouse-Wheel ScrollFrame for Multi-Step Plays
PF.DetailWindow.ShowOpportunity(lgsPlay) -- Has 5 shopping list rows + multi-line explanation
local sf = PF.DetailWindow.frame.scrollFrame
local sb = PF.DetailWindow.frame.scrollBar
Assert(sf ~= nil and sb ~= nil, "DetailWindow creates ScrollFrame and ScrollBar")
-- Trigger mouse-wheel scroll down (-1) when content exceeds viewport
local longOpp = {
    actionLabel = "Craft and AH",
    itemId = 7941,
    itemName = "Ornate Mithril Pants",
    itemLink = "[Ornate Mithril Pants]",
    quantity = 3,
    totalCost = 41397,
    totalNetRevenue = 99918,
    totalAHCut = 5400,
    totalDepositRisk = 2676,
    totalProfit = 58521,
    roiPercent = 141,
    explanation = string.rep("Intermediate Crafting Step: Craft 12x Mithril Bar from raw materials.\n\n", 8),
    shoppingList = lgsPlay.shoppingList,
}
PF.DetailWindow.ShowOpportunity(longOpp)
Assert(sf._maxScroll > 0 and sb:IsShown() == true, "DetailWindow activates ScrollBar when multi-step explanation + shopping list exceeds viewport height")
sf.scripts["OnMouseWheel"](sf, -1)
Assert(sf._currentScroll > 0, "Mouse wheel down scrolls DetailWindow content")
sf.scripts["OnMouseWheel"](sf, 1)
Assert(sf._currentScroll == 0, "Mouse wheel up scrolls DetailWindow back to top")

-- 16. Test Ancillary MarketFeed Stepped Order Books, Non-Destructive PCF Mirror & 14-Day Historical Spike Guard
_G.PCF_DB.prices[11084] = { minBuyout = 80000, count = 10, lastUpdated = Mock.currentTime } -- Fresh in-game scan (8g)
_G.Profitable_MarketFeed = {
    timestamp = math.floor(Mock.currentTime) - 300, -- 5 min old offline feed
    region = "us",
    rulesetId = 1,
    houseId = 6,
    houseName = "Horde Auction House",
    items = {
        -- Large Glimmering Shard (11084): 14d median is 1g 50s across 12 observations, live is spiked to 8g!
        [11084] = { m = 75000, q = 12, med = 15000, obs = 12, tiers = { { 75000, 5 }, { 80000, 7 } } },
        -- Item only present in API Feed (not yet scanned in PCF_DB)
        [774] = { m = 150, q = 25, med = 140, obs = 10, tiers = { { 150, 10 }, { 200, 15 } } },
    },
}

local mirroredCount = PF.MarketFeed.MirrorToPCF()
Assert(mirroredCount == 1, "MirrorToPCF fills missing items (774) without overwriting fresher in-game PCF scan (11084)")
Assert(_G.PCF_DB.prices[11084].minBuyout == 80000, "Fresher in-game PCF_DB scan takes precedence over older API feed")
Assert(_G.PCF_DB.prices[774].minBuyout == 150 and _G.PCF_DB.prices[774].source == "API Feed", "API Feed populates missing item in PCF_DB when both Profitable and MarketFeed are active")

-- Verify 14-day historical spike guard caps spiked exit price (8g -> 1.25 * 1g50s = 1g87s50c)
local cappedExit, wasSpiked, spikeDetails = PF.MarketFeed.GetExitPrice(11084, 80000)
Assert(wasSpiked == true and cappedExit == 18750 and spikeDetails.medianPrice == 15000, "Spike guard caps >2x spiked exit price (8g) down to 1.25x 14d median (1g 87s 50c)")

-- Verify MarketFeed stepped order book works automatically in OpportunityEngine.GetOrderBook
local feedBook = PF.OpportunityEngine.GetOrderBook(774)
Assert(#feedBook == 2 and feedBook[1].unitPrice == 150 and feedBook[2].quantity == 15, "OpportunityEngine reads stepped order-book tiers from MarketFeed")

-- Clean up Profitable_MarketFeed before AHVerifier skip/throttle regression tests
_G.Profitable_MarketFeed = nil

-- 17. Test MarketFeed Verification Skip, Force Live Shift-Click, Sell-Frame Tab Guard & ItemKey Cleanup
do
    local origSendSearchQuery = _G.C_AuctionHouse.SendSearchQuery
    local origGetItemKeyInfo = _G.C_AuctionHouse.GetItemKeyInfo
    local origIsThrottledReady = _G.C_AuctionHouse.IsThrottledMessageSystemReady
    local origIsAuctionHouseShown = _G.AuctionHouseFrame.IsShown
    local origDisplayModeEnum = _G.AuctionHouseFrameDisplayMode
    local origSetDisplayMode = _G.AuctionHouseFrame.SetDisplayMode
    local origCommSell = _G.AuctionHouseFrame.CommoditiesSellFrame

    _G.AuctionHouseFrame.IsShown = function() return true end
    local searchCalls = 0
    _G.C_AuctionHouse.SendSearchQuery = function(...)
        searchCalls = searchCalls + 1
    end
    _G.C_AuctionHouse.IsThrottledMessageSystemReady = function() return true end

    -- Populate fresh MarketFeed (< 2h) covering every AH item in current candidates
    local topCand, _, hmCand = PF.OpportunityEngine.FindTopOpportunities(nil, nil, 10)
    local feedItems = {}
    local function AddFeedEntries(list)
        if type(list) ~= "table" then return end
        for _, opp in ipairs(list) do
            if opp.shoppingList then
                for _, s in ipairs(opp.shoppingList) do
                    if s.source == "AH" then
                        feedItems[s.itemId] = { m = s.unitPrice or 100, q = 20, tiers = { { s.unitPrice or 100, 20 } } }
                    end
                end
            end
            if opp.actionType == "CRAFT_AH" and opp.itemId then
                feedItems[opp.itemId] = { m = 5000, q = 5, tiers = { { 5000, 5 } } }
            elseif opp.actionType == "BUY_DE" or opp.actionType == "CRAFT_DE" then
                if opp.targetMatId then
                    feedItems[opp.targetMatId] = { m = 5000, q = 20, tiers = { { 5000, 20 } } }
                end
                if opp.deBreakdown and type(opp.deBreakdown.drops) == "table" then
                    for _, d in ipairs(opp.deBreakdown.drops) do
                        local matId = d.sellItemId or d.itemId
                        if matId then
                            feedItems[matId] = { m = d.unitPrice or 5000, q = 20, tiers = { { d.unitPrice or 5000, 20 } } }
                        end
                    end
                end
            end
        end
    end
    AddFeedEntries(topCand)
    AddFeedEntries(hmCand)

    Profitable_DB.orderBookCache = {}
    _G.Profitable_MarketFeed = {
        timestamp = math.floor(Mock.currentTime) - 600, -- 10m old (< 2h default)
        region = "us",
        rulesetId = 1,
        houseId = 113,
        items = feedItems,
    }

    Assert(PF.MarketFeed.IsFresh(7200) == true and PF.MarketFeed.IsFresh(300) == false, "MarketFeed.IsFresh supports custom maxAgeSeconds window")

    -- By default (marketFeedVerifySkipSeconds = 0), clicking Find Top 5 Plays at the AH ALWAYS runs live queries
    -- even when MarketFeed is fresh (<2h), so stale/sold-out deals are never falsely shown as [Verified AH]!
    _G.C_AuctionHouse.GetItemKeyInfo = function(key)
        return { itemID = key.itemID, isCommodity = true }
    end
    Mock.timers = {}
    searchCalls = 0
    PF.AHVerifier.StartDiscoveryAndVerification()
    Assert(PF.AHVerifier.IsRunning() == true, "Default StartDiscoveryAndVerification runs live AH verification even when MarketFeed is fresh")
    local defaultStep = table.remove(Mock.timers, 1)
    if defaultStep and defaultStep.callback then defaultStep.callback() end
    Assert(searchCalls == 1, "Default click sends live C_AuctionHouse.SendSearchQuery instead of blindly trusting MarketFeed")
    PF.AHVerifier.Stop("TEST_DEFAULT_LIVE")
    Mock.timers = {}

    -- Opt-in marketFeedVerifySkipSeconds = 7200 skips live queries ONLY when MarketFeed is newer than PCF_DB,
    -- and never falsely stamps offline-feed-only plays as Verified AH.
    local origSkipSec = Profitable_DB.settings.marketFeedVerifySkipSeconds
    Profitable_DB.settings.marketFeedVerifySkipSeconds = 7200
    _G.Profitable_MarketFeed.timestamp = math.floor(Mock.currentTime) + 60 -- Newer than PCF_DB entries
    Mock.timers = {}
    searchCalls = 0
    local playsFromFeed = PF.AHVerifier.StartDiscoveryAndVerification()
    Assert(PF.AHVerifier.IsRunning() == false, "Opt-in marketFeedVerifySkipSeconds skips live queries when MarketFeed is fresher than PCF_DB")
    Assert(searchCalls == 0, "Opt-in MarketFeed skip avoids C_AuctionHouse.SendSearchQuery when MarketFeed is active source")
    Assert(playsFromFeed and playsFromFeed[1] and playsFromFeed[1].verified == false, "Offline MarketFeed-only plays are NOT falsely marked [Verified AH]")

    -- Even with opt-in marketFeedVerifySkipSeconds = 7200, if PCF_DB is NEWER than MarketFeed (e.g. a 1-unit sniff),
    -- AHVerifier MUST still run live verification!
    _G.Profitable_MarketFeed.timestamp = math.floor(Mock.currentTime) - 600 -- Older than PCF_DB entries
    Mock.timers = {}
    searchCalls = 0
    PF.AHVerifier.StartDiscoveryAndVerification()
    Assert(PF.AHVerifier.IsRunning() == true, "Opt-in MarketFeed skip still runs live verification when PCF_DB overrides MarketFeed")
    PF.AHVerifier.Stop("TEST_OPTIN_PCF_OVERRIDE")
    Mock.timers = {}
    Profitable_DB.settings.marketFeedVerifySkipSeconds = origSkipSec

    -- Shift-click (forceLiveVerify = true) must still run live AH queries AND switch away from CommoditiesSellFrame
    local switchedDisplayMode = nil
    _G.AuctionHouseFrameDisplayMode = { Buy = 1, Sell = 2 }
    _G.AuctionHouseFrame.CommoditiesSellFrame = {
        shown = true,
        IsShown = function(self) return self.shown end,
    }
    _G.AuctionHouseFrame.SetDisplayMode = function(self, mode)
        switchedDisplayMode = mode
        if mode == 1 then self.CommoditiesSellFrame.shown = false end
    end
    _G.C_AuctionHouse.GetItemKeyInfo = function(key)
        return { itemID = key.itemID, isCommodity = true }
    end

    Mock.timers = {}
    searchCalls = 0
    PF.AHVerifier.StartDiscoveryAndVerification({ forceLiveVerify = true })
    Assert(switchedDisplayMode == 1 and _G.AuctionHouseFrame.CommoditiesSellFrame.shown == false, "Force live verify switches AuctionHouseFrame off CommoditiesSellFrame before querying")
    Assert(PF.AHVerifier.IsRunning() == true, "forceLiveVerify = true queues live verification even when MarketFeed is loaded")
    -- Run initial scheduled verification step (do not spin 2.5s fallback timers)
    local firstTimer = table.remove(Mock.timers, 1)
    if firstTimer and firstTimer.callback then firstTimer.callback() end
    Assert(searchCalls == 1, "forceLiveVerify = true sends live C_AuctionHouse.SendSearchQuery")
    PF.AHVerifier.Stop("TEST_CLEANUP")
    Mock.timers = {}

    -- Verify re-entrant PollPendingItemKeys invokes callback once and clears watchers cleanly
    local cached9999 = nil
    _G.C_AuctionHouse.GetItemKeyInfo = function(key)
        return (key.itemID == 9999) and cached9999 or nil
    end
    local keyCbCalls = 0
    local wasQueued = not PF.AHVerifier.WithItemKeyInfo(9999, function()
        keyCbCalls = keyCbCalls + 1
        PF.AHVerifier.frame:Trigger("ITEM_KEY_ITEM_INFO_RECEIVED", 9999)
    end)
    Assert(wasQueued and PF.AHVerifier.frame.events["ITEM_KEY_ITEM_INFO_RECEIVED"] == true and PF.AHVerifier.frame.scripts["OnUpdate"] ~= nil, "Uncached ItemKey registers ITEM_KEY_ITEM_INFO_RECEIVED and OnUpdate")
    cached9999 = { itemID = 9999, isCommodity = true }
    PF.AHVerifier.frame:Trigger("ITEM_KEY_ITEM_INFO_RECEIVED", 9999)
    Assert(keyCbCalls == 1, "PollPendingItemKeys clears itemKeyCallbacks before invoking so re-entrant events cannot double-fire")
    Assert(PF.AHVerifier.frame.events["ITEM_KEY_ITEM_INFO_RECEIVED"] == nil and PF.AHVerifier.frame.scripts["OnUpdate"] == nil, "PollPendingItemKeys unregisters watchers once queue is empty")

    -- Verify Stop() cancels pending uncached SendSearchQuery callbacks cleanly
    _G.Profitable_MarketFeed = nil
    cached9999 = nil
    searchCalls = 0
    Mock.timers = {}
    PF.AHVerifier.StartDiscoveryAndVerification({ forceLiveVerify = true })
    local stepTimer = table.remove(Mock.timers, 1)
    if stepTimer and stepTimer.callback then stepTimer.callback() end
    Assert(searchCalls == 0 and PF.AHVerifier.frame.scripts["OnUpdate"] ~= nil, "Uncached item during live verify waits on ItemKeyInfo instead of querying immediately")
    PF.AHVerifier.Stop("USER_STOPPED")
    Assert(PF.AHVerifier.frame.scripts["OnUpdate"] == nil and PF.AHVerifier.frame.events["ITEM_KEY_ITEM_INFO_RECEIVED"] == nil, "Stop() clears pending ItemKey OnUpdate and event watchers")
    _G.C_AuctionHouse.GetItemKeyInfo = function(key) return { itemID = key.itemID, isCommodity = true } end
    PF.AHVerifier.frame:Trigger("ITEM_KEY_ITEM_INFO_RECEIVED", 2447)
    Assert(searchCalls == 0, "Late ITEM_KEY_ITEM_INFO_RECEIVED after Stop() never fires stale SendSearchQuery")

    -- Restore globals
    _G.Profitable_MarketFeed = nil
    _G.C_AuctionHouse.SendSearchQuery = origSendSearchQuery
    _G.C_AuctionHouse.GetItemKeyInfo = origGetItemKeyInfo
    _G.C_AuctionHouse.IsThrottledMessageSystemReady = origIsThrottledReady
    _G.AuctionHouseFrame.IsShown = origIsAuctionHouseShown
    _G.AuctionHouseFrameDisplayMode = origDisplayModeEnum
    _G.AuctionHouseFrame.SetDisplayMode = origSetDisplayMode
    _G.AuctionHouseFrame.CommoditiesSellFrame = origCommSell
end

-- 18. Test Embedded PriceCheckerForever (Profitable.toc + Embed.xml), Out-of-the-Box Scan Button & Coexistence
do
    local function ResetRuntimeGlobals()
        _G.PF = nil
        _G.Profitable = nil
        _G.PF_INITIALIZED = nil
        _G.PF_API = nil
        _G.Profitable_API = nil
        _G.PCF = nil
        _G.GPC = nil
        _G.PCF_INITIALIZED = nil
        _G.PCF_API = nil
        _G.PCF_DB = nil
        _G.GPC_DB = nil
        _G.SlashCmdList["PROFITABLE"] = nil
        _G.SlashCmdList["PRICECHECKERFOREVER"] = nil
        _G.PCF_AuctionScanButton = nil
        _G.PCF_AuctionScanStatusContainer = nil
        _G.PCF_AuctionScanProgressBar = nil
    end

    local function LoadScriptFile(path, addonName, sharedTable)
        local chunk, err = loadfile(path)
        Assert(chunk ~= nil, "TOC/XML script loadable: " .. path .. (err and (" (" .. err .. ")") or ""))
        chunk(addonName, sharedTable)
    end

    local function LoadProfitableTOC(savedProfitableDB)
        _G.Profitable_DB = savedProfitableDB
        local sharedAddonTable = {}
        for line in io.lines("Profitable.toc") do
            local trimmed = line:match("^%s*(.-)%s*$")
            if trimmed ~= "" and not trimmed:match("^#") then
                local normalized = trimmed:gsub("\\", "/")
                if normalized:match("%.xml$") then
                    local xmlDir = normalized:match("^(.*)/[^/]+$") or "."
                    local xmlFile = io.open(normalized, "r")
                    Assert(xmlFile ~= nil, "Embedded XML file exists: " .. normalized)
                    local xmlText = xmlFile:read("*a")
                    xmlFile:close()
                    for scriptPath in xmlText:gmatch('<Script%s+file="(.-)"%s*/>') do
                        local fullScript = xmlDir .. "/" .. scriptPath:gsub("\\", "/")
                        LoadScriptFile(fullScript, "Profitable", sharedAddonTable)
                    end
                elseif normalized:match("%.lua$") then
                    LoadScriptFile(normalized, "Profitable", sharedAddonTable)
                end
            end
        end
        return sharedAddonTable
    end

    local origCAddOns = _G.C_AddOns
    local origIsAddOnLoaded = _G.IsAddOnLoaded
    local origAuctionator = _G.Auctionator
    local origTSMAPI = _G.TSM_API
    local origChatInfo = _G.C_ChatInfo
    local origAuctionFrame = _G.AuctionFrame
    local origAuctionHouseFrame = _G.AuctionHouseFrame

    _G.C_ChatInfo = {
        RegisterAddonMessagePrefix = function() end,
        SendAddonMessage = function() end,
    }
    _G.AuctionFrame = nil
    _G.AuctionHouseFrame = _G.CreateFrame("Frame", "AuctionHouseFrame", _G.UIParent)

    -- 18A. Fresh standalone Profitable with NO external AH addons and NO standalone PCF
    ResetRuntimeGlobals()
    _G.Auctionator = nil
    _G.TSM_API = nil
    _G.C_AddOns = { IsAddOnLoaded = function() return false end }
    _G.IsAddOnLoaded = _G.C_AddOns.IsAddOnLoaded

    local tocSharedA = LoadProfitableTOC(nil)
    Assert(_G.PF ~= _G.PCF, "Profitable PF namespace stays isolated from embedded PCF table")
    Assert(type(_G.PF.Formatter.FormatMoneyShort) == "function" and type(_G.PCF.Formatter.FormatRelativeAge) == "function", "Both PF.Formatter and embedded PCF.Formatter stay intact")
    Assert(_G.PF.LoadConfig ~= _G.PCF.LoadConfig and _G.PF.Initialize ~= _G.PCF.Initialize, "Profitable LoadConfig/Initialize do not overwrite embedded PCF functions")

    tocSharedA.coreFrame:Trigger("ADDON_LOADED", "Profitable")
    _G.PF.coreFrame:Trigger("ADDON_LOADED", "Profitable")

    Assert(_G.PCF_INITIALIZED == true and _G.PF_INITIALIZED == true, "Embedded PCF and Profitable both initialize on ADDON_LOADED")
    Assert(_G.PCF_DB == _G.Profitable_DB.embeddedPCF, "Embedded PCF stores SavedVariables in Profitable_DB.embeddedPCF")
    Assert(_G.PCF_DB.settings.showScanButton == true and _G.PCF_DB.settings.showTooltip == true, "Embedded PCF defaults showScanButton and showTooltip ON without /pcf reset")
    Assert(_G.PCF_DB.settings.autoScanOnOpen == false and _G.PCF_DB.settings.preferReplicateScan == true, "Embedded PCF preserves autoScanOnOpen=false and preferReplicateScan=true defaults")
    _G.PCF.Scanner.frame:Trigger("AUCTION_HOUSE_SHOW")
    Assert(_G.PCF.Scanner.scanButton ~= nil and _G.PCF.Scanner.scanButton:IsShown() == true, "Embedded PCF creates and shows PCF_AuctionScanButton on AUCTION_HOUSE_SHOW")

    -- 18B. Fresh standalone Profitable WITH Auctionator & TSM installed (previously hid scan button!)
    ResetRuntimeGlobals()
    _G.Auctionator = { API = { v1 = {} } }
    _G.TSM_API = {}
    _G.C_AddOns = { IsAddOnLoaded = function(name) return name == "Auctionator" or name == "TradeSkillMaster" end }
    _G.IsAddOnLoaded = _G.C_AddOns.IsAddOnLoaded

    local tocSharedB = LoadProfitableTOC(nil)
    tocSharedB.coreFrame:Trigger("ADDON_LOADED", "Profitable")
    _G.PF.coreFrame:Trigger("ADDON_LOADED", "Profitable")

    Assert(_G.PCF_DB.settings.showScanButton == true and _G.PCF_DB.settings.userSetScanButton == false, "Profitable enables PCF scan button out of the box even when Auctionator/TSM are loaded")
    Assert(_G.PCF_DB.settings.showTooltip == false, "Embedded PCF still suppresses duplicate PCF tooltip when Auctionator/TSM are loaded")
    _G.PCF.Scanner.frame:Trigger("AUCTION_HOUSE_SHOW")
    Assert(_G.PCF.Scanner.scanButton ~= nil and _G.PCF.Scanner.scanButton:IsShown() == true, "PCF Scan button displays immediately on AUCTION_HOUSE_SHOW alongside Auctionator/TSM without /pcf reset")

    -- Simulate user scanning an item, toggling /pcf button OFF explicitly, and reloading
    _G.PCF_DB.prices[2589] = { minBuyout = 45, minBid = 45, lastUpdated = 1700000000, count = 20, source = "Scan" }
    _G.SlashCmdList["PRICECHECKERFOREVER"]("button")
    Assert(_G.PCF_DB.settings.showScanButton == false and _G.PCF_DB.settings.userSetScanButton == true, "/pcf button toggles scan button OFF and records explicit user preference")

    local persistedDB = _G.Profitable_DB
    ResetRuntimeGlobals()
    local tocSharedReload = LoadProfitableTOC(persistedDB)
    tocSharedReload.coreFrame:Trigger("ADDON_LOADED", "Profitable")
    _G.PF.coreFrame:Trigger("ADDON_LOADED", "Profitable")

    Assert(_G.PCF_DB == persistedDB.embeddedPCF and _G.PCF_DB.prices[2589].minBuyout == 45, "Embedded PCF price cache survives /reload via Profitable_DB.embeddedPCF")
    Assert(_G.PCF_DB.settings.showScanButton == false and _G.PCF_DB.settings.userSetScanButton == true, "Explicit /pcf button OFF preference is preserved across /reload")

    -- 18C. Standalone PriceCheckerForever already initialized before Profitable loads
    ResetRuntimeGlobals()
    local updateVisCalls = 0
    local standalonePCF = {
        _isStandaloneSentinel = true,
        Scanner = {
            UpdateVisibility = function()
                updateVisCalls = updateVisCalls + 1
            end,
        },
    }
    local standalonePCFDB = {
        settings = { showScanButton = false, userSetScanButton = false },
        prices = { [2589] = { minBuyout = 88, lastUpdated = 1700000100 } },
    }
    local standalonePCFAPI = {
        _isStandaloneAPISentinel = true,
        IsReady = function() return true end,
    }
    _G.PCF = standalonePCF
    _G.GPC = standalonePCF
    _G.PCF_DB = standalonePCFDB
    _G.GPC_DB = standalonePCFDB
    _G.PCF_API = standalonePCFAPI
    _G.PCF_INITIALIZED = true
    _G.C_AddOns = { IsAddOnLoaded = function(name) return name == "PriceCheckerForever" or name == "Auctionator" end }
    _G.IsAddOnLoaded = _G.C_AddOns.IsAddOnLoaded

    LoadProfitableTOC(nil)
    _G.PF.coreFrame:Trigger("ADDON_LOADED", "Profitable")

    Assert(_G.PCF == standalonePCF and _G.PCF._isStandaloneSentinel == true, "Embedded load preserves already-initialized standalone PCF namespace")
    Assert(_G.PCF_API == standalonePCFAPI and _G.PCF_API._isStandaloneAPISentinel == true, "Embedded load preserves standalone PCF_API")
    Assert(_G.PCF_DB == standalonePCFDB and _G.Profitable_DB.embeddedPCF == nil, "Profitable uses standalone PCF_DB instead of creating embeddedPCF when standalone PCF is active")
    Assert(_G.PCF_DB.settings.showScanButton == true and updateVisCalls == 1, "Profitable enables scan button on standalone PCF when userSetScanButton is false")

    -- 19. Onboarding Popup, Missing AH Data Prompt, Stale (>24h) AH Data Guard & 1-Click AH Scan
    -- 19A. First-run Onboarding Popup appears until user clicks Accept / OK
    ResetRuntimeGlobals()
    _G.Auctionator = nil
    _G.TSM_API = nil
    _G.C_AddOns = { IsAddOnLoaded = function() return false end }
    _G.IsAddOnLoaded = _G.C_AddOns.IsAddOnLoaded

    local tocShared19 = LoadProfitableTOC(nil)
    tocShared19.coreFrame:Trigger("ADDON_LOADED", "Profitable")
    _G.PF.coreFrame:Trigger("ADDON_LOADED", "Profitable")

    local popup1 = _G.PF_OnboardingPopup
    Assert(popup1 ~= nil and popup1:IsShown() == true, "Onboarding popup automatically displays on first run before user accepts")
    Assert(_G.Profitable_DB.settings.onboardingDismissed == false, "onboardingDismissed remains false before clicking OK")

    -- Closing via X button hides for session but still pops up on next run
    _G.PF_OnboardingCloseButton:Click()
    Assert(popup1:IsShown() == false and _G.Profitable_DB.settings.onboardingDismissed == false, "Close button hides popup for session without marking onboardingDismissed")

    local savedUnacceptedDB = _G.Profitable_DB
    ResetRuntimeGlobals()
    local tocShared19Reload1 = LoadProfitableTOC(savedUnacceptedDB)
    tocShared19Reload1.coreFrame:Trigger("ADDON_LOADED", "Profitable")
    _G.PF.coreFrame:Trigger("ADDON_LOADED", "Profitable")
    Assert(_G.PF_OnboardingPopup ~= nil and _G.PF_OnboardingPopup:IsShown() == true, "Onboarding popup appears again on next run when user has not clicked OK/Accept")

    -- Clicking 'OK, Got It!' sets onboardingDismissed = true and suppresses startup popup on subsequent runs
    _G.PF_OnboardingAcceptButton:Click()
    Assert(_G.PF_OnboardingPopup:IsShown() == false and _G.Profitable_DB.settings.onboardingDismissed == true, "Clicking Accept/OK hides popup and persists onboardingDismissed = true")

    local savedAcceptedDB = _G.Profitable_DB
    ResetRuntimeGlobals()
    local tocShared19Reload2 = LoadProfitableTOC(savedAcceptedDB)
    tocShared19Reload2.coreFrame:Trigger("ADDON_LOADED", "Profitable")
    _G.PF.coreFrame:Trigger("ADDON_LOADED", "Profitable")
    Assert(_G.PF_OnboardingPopup == nil or _G.PF_OnboardingPopup:IsShown() == false, "Onboarding popup does not auto-open once user has confirmed/accepted it")

    -- /pf welcome re-opens the popup on demand even after dismissal
    _G.SlashCmdList["PROFITABLE"]("welcome")
    Assert(_G.PF_OnboardingPopup ~= nil and _G.PF_OnboardingPopup:IsShown() == true, "/pf welcome opens the onboarding guide popup on demand")
    _G.PF_OnboardingPopup:Hide()

    -- 19B. Missing AH Data ("NO_DATA") at Auction House hides old plays and directs user to scan
    local statusNoData, infoNoData = _G.PF.GetAHDataStatus()
    Assert(statusNoData == "NO_DATA" and infoNoData.itemCount == 0, "GetAHDataStatus reports NO_DATA when PCF_DB.prices is empty")

    -- Seed fake leftover plays in lastTopPlays to verify they are NOT displayed when AH data is missing
    _G.Profitable_DB.lastTopPlays = {
        { id = "VENDOR:2447", itemId = 2447, itemName = "Peacebloom", itemLink = "[Peacebloom]", actionLabel = "Vendor", quantity = 10, totalCost = 100, totalProfit = 200, roiPercent = 200 },
        { id = "VENDOR:2840", itemId = 2840, itemName = "Copper Bar", itemLink = "[Copper Bar]", actionLabel = "Vendor", quantity = 5, totalCost = 100, totalProfit = 150, roiPercent = 150 },
    }
    _G.Profitable_DB.lastHonorableMentions = {
        { id = "CRAFT_VENDOR:2852", itemId = 2852, itemName = "Copper Chain Pants", itemLink = "[Copper Chain Pants]", actionLabel = "Craft and Vendor", hmCategory = "Top Vendor", quantity = 1, totalCost = 50, totalProfit = 50, roiPercent = 100 },
    }

    _G.AuctionHouseFrame:Show()
    _G.PCF.Scanner.frame:Trigger("AUCTION_HOUSE_SHOW")
    _G.PF.SideWindow.eventFrame:Trigger("AUCTION_HOUSE_SHOW")

    Assert(_G.PF_FindOpportunitiesButton:GetText() == "Scan AH Now", "SideWindow primary button reads 'Scan AH Now' at AH when no AH data exists")
    Assert(_G.PF_SideWindowPlayButton1:IsShown() == true and _G.PF_SideWindowPlayButton1.mainText:GetText():find("No Auction House Data Found") ~= nil, "Row 1 directs user to scan AH when no data exists")
    Assert(_G.PF_SideWindowPlayButton2:IsShown() == false and _G.PF_SideWindowHMButton1:IsShown() == false, "Old cached plays and Honorable Mentions are hidden when no AH data exists")

    -- Running /pf run with NO_DATA refuses to calculate stale plays and clears lastTopPlays
    local noDataPlays = _G.PF.SideWindow.RunSearch()
    Assert(#noDataPlays == 0 and #_G.Profitable_DB.lastTopPlays == 0, "RunSearch returns empty and clears lastTopPlays when NO_DATA")

    -- Clicking 'Scan AH Now' in Profitable directly starts the PCF AH scan
    local pcfScanTriggered = 0
    local origStartScan = _G.PCF.Scanner.StartScan
    _G.PCF.Scanner.StartScan = function(...)
        pcfScanTriggered = pcfScanTriggered + 1
        if _G.PCF.Scanner.scanButton then
            _G.PCF.Scanner.scanButton:SetText("Stop Scan")
        end
    end
    _G.PF_FindOpportunitiesButton:Click()
    Assert(pcfScanTriggered == 1, "Clicking 'Scan AH Now' in Profitable triggers PCF.Scanner.StartScan()")
    Assert(_G.PF_FindOpportunitiesButton:GetText() == "Scanning AH...", "Profitable button updates to 'Scanning AH...' while PCF scan runs")
    _G.PCF.Scanner.StartScan = origStartScan

    -- 19C. Very Stale AH Data ("STALE", >24h old) hides old plays and directs user to rescan
    local threeDaysAgo = math.floor(Mock.currentTime) - (3 * 86400)
    _G.PCF_DB.lastFullScan = threeDaysAgo
    _G.PCF_DB.prices[2447] = { minBuyout = 5, minBid = 5, count = 20, lastUpdated = threeDaysAgo, source = "Scan" }
    _G.Profitable_DB.lastTopPlays = {
        { id = "VENDOR:2447", itemId = 2447, itemName = "Peacebloom", itemLink = "[Peacebloom]", actionLabel = "Vendor", quantity = 20, totalCost = 100, totalProfit = 100, roiPercent = 100 },
        { id = "VENDOR:2840", itemId = 2840, itemName = "Copper Bar", itemLink = "[Copper Bar]", actionLabel = "Vendor", quantity = 5, totalCost = 100, totalProfit = 150, roiPercent = 150 },
    }
    if _G.PCF.Scanner.scanButton then
        _G.PCF.Scanner.scanButton:SetText("PCF Scan")
    end

    local statusStale, infoStale = _G.PF.GetAHDataStatus()
    Assert(statusStale == "STALE" and infoStale.ageText == "3d 0h", "GetAHDataStatus reports STALE (3d 0h) when last scan is >24h old")

    _G.PF.SideWindow.Refresh()
    Assert(_G.PF_FindOpportunitiesButton:GetText() == "Scan AH Now", "SideWindow primary button reads 'Scan AH Now' when AH data is stale")
    Assert(_G.PF_SideWindowPlayButton1.mainText:GetText():find("AH Data is Stale %(3d 0h old%)") ~= nil, "Row 1 warns that AH data is stale and old plays are hidden")
    Assert(_G.PF_SideWindowPlayButton2:IsShown() == false, "Row 2+ old plays are hidden when AH data is stale")

    -- Simulate PCF scan completing with fresh timestamp -> SideWindow automatically transitions to 'Find Top 5 Plays'
    _G.PCF_DB.lastFullScan = math.floor(Mock.currentTime)
    _G.PCF_DB.prices[2447].lastUpdated = math.floor(Mock.currentTime)
    if _G.PCF.Scanner.scanButton then
        _G.PCF.Scanner.scanButton:SetText("PCF Scan")
    end
    local statusFresh = _G.PF.GetAHDataStatus()
    Assert(statusFresh == "FRESH" and _G.PF_FindOpportunitiesButton:GetText() == "Find Top 5 Plays", "SideWindow automatically switches to 'Find Top 5 Plays' as soon as PCF scan completes")

    -- 20. Test Buyout-Only Exclusion (Evicting Bid-Only Listings), Second-Run Live Re-Verification & Quick-Filter Tag Bubbles / Options Window
    local nowTs = math.floor(Mock.currentTime)
    _G.PCF_DB.lastFullScan = nowTs

    -- 20A. Bid-Only item exclusion & live eviction
    -- Item 95001 ("Bid-Only Rare Sword", DEs into Large Glimmering Shard 11084 worth 8g)
    -- Initially appears in PCF_DB.prices at 100c (1s) from browse minPrice, but live AH has ONLY bid listings (no buyout)!
    _G.Profitable_DB.itemCache[95001] = {
        name = "Bid-Only Rare Sword",
        quality = 3,
        itemLevel = 28,
        classID = 2,
        invType = "INVTYPE_WEAPON",
        vendorSell = 5000,
    }
    _G.PCF_DB.prices[11084] = { minBuyout = 80000, count = 10, lastUpdated = nowTs, source = "Scan" }
    _G.PCF_DB.prices[95001] = { minBuyout = 100, count = 2, lastUpdated = nowTs, source = "PCF Sniff" }

    local origCAH20 = _G.C_AuctionHouse
    _G.C_AuctionHouse = {
        MakeItemKey = function(id) return { itemID = id, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 } end,
        GetItemKeyInfo = function(key) return { itemID = key.itemID, isCommodity = false } end,
        SendSearchQuery = function() end,
        GetNumItemSearchResults = function(key)
            if type(key) == "table" and key.itemID == 95001 then return 2 end
            return 0
        end,
        GetItemSearchResultInfo = function(key, idx)
            if type(key) == "table" and key.itemID == 95001 then
                local bidRows = {
                    { auctionID = 501, minBid = 100, bidAmount = 150, buyoutAmount = nil, quantity = 1 },
                    { auctionID = 502, minBid = 200, bidAmount = 0,   buyoutAmount = 0,   quantity = 1 },
                }
                return bidRows[idx]
            end
            return nil
        end,
    }

    Assert(_G.Profitable_DB.settings.buyoutOnly == true, "buyoutOnly defaults to true (exclude bid-only auctions)")
    _G.PF.AHVerifier.frame:Trigger("ITEM_SEARCH_RESULTS_UPDATED", { itemID = 95001 })
    Assert(_G.PCF_DB.prices[95001] == nil, "Live verification evicts bid-only item from PCF_DB.prices when buyoutOnly is ON")
    Assert(_G.Profitable_DB.orderBookCache[95001] and _G.Profitable_DB.orderBookCache[95001].unavailable == true, "OrderBookCache marks bid-only item as unavailable")
    Assert(_G.PF.OpportunityEngine.ResolveAHPrice(95001) == nil, "ResolveAHPrice returns nil for evicted bid-only item")

    -- Toggling [Buyout Only] pill OFF allows bid-only listings; toggling back ON evicts them again
    Assert(_G.PF_FilterTag_BuyoutOnly ~= nil, "Quick-filter tag bubble [Buyout Only] exists on SideWindow")
    _G.PF_FilterTag_BuyoutOnly:Click()
    Assert(_G.Profitable_DB.settings.buyoutOnly == false, "Clicking [Buyout Only] tag bubble toggles buyoutOnly OFF")
    _G.PF.AHVerifier.frame:Trigger("ITEM_SEARCH_RESULTS_UPDATED", { itemID = 95001 })
    Assert(_G.PF.OpportunityEngine.ResolveAHPrice(95001) == 150, "When buyoutOnly is OFF, bid-only listings are accepted at their bid amount")

    _G.PF_FilterTag_BuyoutOnly:Click()
    Assert(_G.Profitable_DB.settings.buyoutOnly == true, "Clicking [Buyout Only] tag bubble toggles buyoutOnly back ON")
    _G.PF.AHVerifier.frame:Trigger("ITEM_SEARCH_RESULTS_UPDATED", { itemID = 95001 })
    Assert(_G.PF.OpportunityEngine.ResolveAHPrice(95001) == nil, "Re-enabling buyoutOnly evicts bid-only item again")

    -- 20B. Second-run live AH re-verification (never skip items just because orderBookCache is <10m old)
    _G.Profitable_DB.itemCache[2447] = { name = "Peacebloom", quality = 1, itemLevel = 1, classID = 7, vendorSell = 13500 }
    _G.PCF_DB.prices[2447] = { minBuyout = 11000, count = 20, lastUpdated = nowTs, source = "Scan" }
    _G.Profitable_DB.orderBookCache[2447] = {
        timestamp = nowTs - 15, -- Checked only 15 seconds ago on first run
        listings = { { unitPrice = 11000, quantity = 20 } },
        unavailable = false,
    }
    local secondRunQueries = 0
    _G.C_AuctionHouse.GetItemKeyInfo = function(key) return { itemID = key.itemID, isCommodity = true } end
    _G.C_AuctionHouse.SendSearchQuery = function() secondRunQueries = secondRunQueries + 1 end
    _G.AuctionHouseFrame.IsShown = function() return true end
    Mock.timers = {}
    _G.PF.AHVerifier.StartDiscoveryAndVerification()
    Assert(_G.PF.AHVerifier.IsRunning() == true, "Second run of StartDiscoveryAndVerification still runs live verification even when orderBookCache is <10m old")
    local step20Timer = table.remove(Mock.timers, 1)
    if step20Timer and step20Timer.callback then step20Timer.callback() end
    Assert(secondRunQueries == 1, "Second run queries the live Auction House again to validate current price")
    _G.PF.AHVerifier.Stop("TEST_20B_DONE")
    Mock.timers = {}
    _G.C_AuctionHouse = origCAH20

    -- 20C. Quick-Toggle Filter Tag Bubbles ([Disenchant], [Craft], [Vendor]) & Options Panel (PF_SettingsWindow)
    -- Seed all 3 play categories:
    -- 1) BUY_DE: Item 95002 (Rare sword @ 1g -> Large Glimmering Shard 11084 @ 8g)
    _G.Profitable_DB.itemCache[95002] = { name = "Buyout Rare Sword", quality = 3, itemLevel = 28, classID = 2, invType = "INVTYPE_WEAPON", vendorSell = 5000 }
    _G.PCF_DB.prices[95002] = { minBuyout = 10000, count = 5, lastUpdated = nowTs, source = "Scan" }
    -- 2) CRAFT_VENDOR: Copper Chain Pants (2852, vendorSell 1g 25s, crafted from 4x Copper Bar 2840 @ 20s = 80s)
    _G.Profitable_DB.itemCache[2852] = { name = "Copper Chain Pants", quality = 2, itemLevel = 10, classID = 4, invType = "INVTYPE_LEGS", vendorSell = 12500 }
    _G.PCF_DB.prices[2840] = { minBuyout = 2000, count = 80, lastUpdated = nowTs, source = "Scan" }
    _G.PF.RecipeScanner.RegisterRecipe({
        name = "Copper Chain Pants",
        profession = "Blacksmithing",
        outputItemId = 2852,
        minMade = 1,
        maxMade = 1,
        avgMade = 1,
        reagents = { { itemId = 2840, name = "Copper Bar", count = 4 } },
    })
    -- 3) VENDOR: Peacebloom (2447, vendorSell 1g 35s, AH buyout 1g 10s)
    _G.PF.SideWindow.ApplyFilterChange()

    local function CountActionTypes(plays)
        local counts = { DE = 0, CRAFT = 0, VENDOR = 0 }
        for _, p in ipairs(plays or {}) do
            if p.actionType == "BUY_DE" or p.actionType == "CRAFT_DE" then
                counts.DE = counts.DE + 1
            elseif p.actionType == "CRAFT_AH" or p.actionType == "CRAFT_VENDOR" then
                counts.CRAFT = counts.CRAFT + 1
            elseif p.actionType == "VENDOR" then
                counts.VENDOR = counts.VENDOR + 1
            end
        end
        return counts
    end

    local cAll = CountActionTypes(_G.Profitable_DB.lastTopPlays)
    Assert(cAll.DE >= 1 and cAll.CRAFT >= 1 and cAll.VENDOR >= 1, "All 3 play categories (DE, Craft, Vendor) present when all filter tags are ON")

    -- Click [Disenchant] tag bubble OFF -> all DE plays immediately hidden
    _G.PF_FilterTag_Disenchant:Click()
    Assert(_G.Profitable_DB.settings.assumeCanDisenchant == false, "Clicking [Disenchant] tag bubble turns assumeCanDisenchant OFF")
    local cNoDE = CountActionTypes(_G.Profitable_DB.lastTopPlays)
    Assert(cNoDE.DE == 0 and cNoDE.CRAFT >= 1 and cNoDE.VENDOR >= 1, "Toggling [Disenchant] OFF immediately removes DE plays and keeps Craft/Vendor plays")

    -- Click [Craft] tag bubble OFF -> all Craft plays immediately hidden
    _G.PF_FilterTag_Craft:Click()
    Assert(_G.Profitable_DB.settings.showCraftPlays == false, "Clicking [Craft] tag bubble turns showCraftPlays OFF")
    local cOnlyVendor = CountActionTypes(_G.Profitable_DB.lastTopPlays)
    Assert(cOnlyVendor.DE == 0 and cOnlyVendor.CRAFT == 0 and cOnlyVendor.VENDOR >= 1, "Toggling [Craft] OFF immediately removes Craft plays, leaving only Vendor plays")

    -- Open Options Window via SideWindow 'Options' button and click 'Reset Filter Defaults'
    Assert(_G.PF_SideWindowSettingsButton ~= nil, "SideWindow 'Options' button exists")
    _G.PF_SideWindowSettingsButton:Click()
    Assert(_G.PF_SettingsWindow ~= nil and _G.PF_SettingsWindow:IsShown() == true, "Clicking 'Options' opens PF_SettingsWindow")
    _G.PF_SettingsResetButton:Click()
    Assert(
        _G.Profitable_DB.settings.assumeCanDisenchant == true
            and _G.Profitable_DB.settings.showCraftPlays == true
            and _G.Profitable_DB.settings.showVendorPlays == true
            and _G.Profitable_DB.settings.buyoutOnly == true,
        "Clicking 'Reset Filter Defaults' restores all filter settings to ON"
    )
    local cRestored = CountActionTypes(_G.Profitable_DB.lastTopPlays)
    Assert(cRestored.DE >= 1 and cRestored.CRAFT >= 1 and cRestored.VENDOR >= 1, "Resetting filter defaults immediately restores DE, Craft, and Vendor plays")

    -- Restore outer test environment
    _G.C_AddOns = origCAddOns
    _G.IsAddOnLoaded = origIsAddOnLoaded
    _G.Auctionator = origAuctionator
    _G.TSM_API = origTSMAPI
    _G.C_ChatInfo = origChatInfo
    _G.AuctionFrame = origAuctionFrame
    _G.AuctionHouseFrame = origAuctionHouseFrame
end

-- 21. Regression Tests: Hot Wolf Ribs Live AH Validation, Per-Recipe Profession Detection, Self-Healing & Open Cooking Button
do
    local origCTradeSkillUI = _G.C_TradeSkillUI
    local origProfessionsFrame = _G.ProfessionsFrame
    local origCAH = _G.C_AuctionHouse
    local origAHFrame = _G.AuctionHouseFrame
    local origAuctionFrame = _G.AuctionFrame
    local origMarketFeed = _G.Profitable_MarketFeed
    local origGetNumTradeSkills = _G.GetNumTradeSkills

    -- 21A. Config v1 -> v4 migration resets old default marketFeedVerifySkipSeconds = 7200 to 0
    local legacyV1DB = {
        version = 1,
        settings = {
            marketFeedVerifySkipSeconds = 7200,
        },
    }
    _G.PF.LoadConfig(legacyV1DB)
    Assert(legacyV1DB.version == 4 and legacyV1DB.settings.marketFeedVerifySkipSeconds == 0, "v1 -> v4 migration resets legacy marketFeedVerifySkipSeconds (7200 -> 0)")

    -- 21B. Modern C_TradeSkillUI per-recipe profession resolution (immune to window-switch race conditions)
    _G.GetNumTradeSkills = function() return 0 end -- Force modern C_TradeSkillUI path
    local openedTradeSkillIds = {}
    local openedRecipeIds = {}
    local craftedRecipeIds = {}
    local selectedModernRecipes = {}

    local profByRecipe = {
        [15856] = { professionID = 2548, professionName = "Classic Cooking", parentProfessionID = 185, parentProfessionName = "Cooking" },
        [2541]  = { professionID = 2548, professionName = "Classic Cooking" }, -- Missing parentProfessionID: must still normalize to base 185 ("Cooking")!
        [2657]  = { professionID = 2572, professionName = "Classic Mining",  parentProfessionID = 186, parentProfessionName = "Mining" },
        [14807] = { professionID = 2494, professionName = "Classic Enchanting", parentProfessionID = 333, parentProfessionName = "Enchanting" },
        [10001] = { professionID = 2477, professionName = "Classic Blacksmithing", parentProfessionID = 164, parentProfessionName = "Blacksmithing" },
    }
    local modernRecipes = {
        [15856] = {
            info = { recipeID = 15856, name = "Hot Wolf Ribs", learned = true, itemID = 13851 },
            schematic = {
                outputItemID = 13851,
                quantityMin = 1,
                quantityMax = 1,
                reagentSlotSchematics = {
                    { quantityRequired = 1, reagents = { { itemID = 12203 } } },
                    { quantityRequired = 1, reagents = { { itemID = 2692 } } },
                },
            },
        },
    }

    _G.ProfessionsFrame = _G.CreateFrame("Frame", "ProfessionsFrame", _G.UIParent)
    _G.ProfessionsFrame:Hide()
    _G.ProfessionsFrame.CraftingPage = {
        SelectRecipe = function(_, rInfo)
            table.insert(selectedModernRecipes, rInfo and rInfo.recipeID)
        end,
    }

    _G.C_TradeSkillUI = {
        IsTradeSkillLinked = function() return false end,
        IsTradeSkillGuild = function() return false end,
        IsTradeSkillReady = function() return true end,
        GetAllRecipeIDs = function() return { 15856 } end,
        -- Simulate the exact WoW: Forever window-switch race bug where GetChildProfessionInfo/GetBaseProfessionInfo
        -- report "Mining" while GetAllRecipeIDs still returns Cooking recipes!
        GetChildProfessionInfo = function() return { professionID = 186, professionName = "Mining" } end,
        GetBaseProfessionInfo = function() return { professionID = 186, professionName = "Mining" } end,
        GetProfessionInfoByRecipeID = function(rId) return profByRecipe[rId] end,
        GetRecipeInfo = function(rId) return modernRecipes[rId] and modernRecipes[rId].info or nil end,
        GetRecipeSchematic = function(rId) return modernRecipes[rId] and modernRecipes[rId].schematic or nil end,
        OpenTradeSkill = function(skillLineId)
            table.insert(openedTradeSkillIds, skillLineId)
            _G.ProfessionsFrame:Show()
            return true
        end,
        OpenRecipe = function(rId)
            table.insert(openedRecipeIds, rId)
        end,
        CraftRecipe = function(rId, qty)
            table.insert(craftedRecipeIds, { recipeId = rId, qty = qty })
        end,
    }

    _G.Profitable_DB.itemCache[13851] = { name = "Hot Wolf Ribs", quality = 1, itemLevel = 35, classID = 0, subClassID = 5, itemSubType = "Food & Drink", vendorSell = 312 }
    _G.Profitable_DB.itemCache[12203] = { name = "Red Wolf Meat", quality = 1, itemLevel = 30, classID = 7, subClassID = 8, itemSubType = "Cooking", vendorSell = 87 }
    _G.Profitable_DB.charRecipes = {}

    local modernScanned = _G.PF.RecipeScanner.ScanCurrentProfessionWindow()
    Assert(modernScanned == 1, "ScanModernTradeSkillUI scans Hot Wolf Ribs recipe")
    local charKey = _G.PF.GetCharacterKey()
    local scannedRibs = _G.Profitable_DB.charRecipes[charKey]["15856:Hot Wolf Ribs"]
    Assert(
        scannedRibs ~= nil and scannedRibs.profession == "Cooking" and scannedRibs.professionId == 185,
        "Hot Wolf Ribs resolves to Cooking (185) via GetProfessionInfoByRecipeID even when window reports Mining"
    )

    -- 21C. Self-healing corrupted SavedVariables recipes (Mining/Fishing/Crafting -> Cooking/Mining/Enchanting/Blacksmithing)
    _G.Profitable_DB.charRecipes[charKey] = {
        ["15856:Hot Wolf Ribs"] = {
            recipeId = 15856, name = "Hot Wolf Ribs", profession = "Mining", outputItemId = 13851, avgMade = 1,
            reagents = { { itemId = 12203, name = "Red Wolf Meat", count = 1 }, { itemId = 2692, name = "Hot Spices", count = 1 } },
        },
        ["2657:Smelt Copper"] = {
            recipeId = 2657, name = "Smelt Copper", profession = "Fishing", outputItemId = 2840, avgMade = 1,
            reagents = { { itemId = 2770, name = "Copper Ore", count = 1 } },
        },
        ["14807:Greater Magic Wand"] = {
            recipeId = 14807, name = "Greater Magic Wand", profession = "Crafting", outputItemId = 11288, avgMade = 1,
            reagents = { { itemId = 4470, name = "Simple Wood", count = 1 }, { itemId = 10939, name = "Greater Magic Essence", count = 1 } },
        },
        ["10001:Big Black Mace"] = {
            recipeId = 10001, name = "Big Black Mace", profession = "Mining", outputItemId = 7945, avgMade = 1,
            reagents = { { itemId = 3860, name = "Mithril Bar", count = 16 } },
        },
    }
    local repairedCount = _G.PF.RecipeScanner.RepairSavedRecipeProfessions()
    Assert(repairedCount >= 4, "RepairSavedRecipeProfessions heals all corrupted saved recipes")
    Assert(_G.Profitable_DB.charRecipes[charKey]["15856:Hot Wolf Ribs"].profession == "Cooking", "Saved Hot Wolf Ribs healed from Mining -> Cooking")
    Assert(_G.Profitable_DB.charRecipes[charKey]["2657:Smelt Copper"].profession == "Mining", "Saved Smelt Copper healed from Fishing -> Mining")
    Assert(_G.Profitable_DB.charRecipes[charKey]["14807:Greater Magic Wand"].profession == "Enchanting", "Saved Greater Magic Wand healed from Crafting -> Enchanting")
    Assert(_G.Profitable_DB.charRecipes[charKey]["10001:Big Black Mace"].profession == "Blacksmithing", "Saved Big Black Mace healed from Mining -> Blacksmithing")
    local childOnlyRecipe = { recipeId = 2541, name = "Coyote Steak", profession = "Mining", outputItemId = 2684 }
    _G.PF.RecipeScanner.NormalizeRecipeProfession(childOnlyRecipe)
    Assert(childOnlyRecipe.profession == "Cooking" and childOnlyRecipe.professionId == 185, "Child-only expansion ProfessionInfo ('Classic Cooking' / 2548) normalizes to base Cooking (185)")

    -- 21D. Open Cooking button opens Cooking window (185) and selects Hot Wolf Ribs (15856) instead of silently calling CraftRecipe
    local ribsOppForBtn = {
        id = "CRAFT_VENDOR:13851",
        actionType = "CRAFT_VENDOR",
        actionLabel = "Craft and Vendor",
        itemId = 13851,
        itemName = "Hot Wolf Ribs",
        itemLink = "|cffffffff|Hitem:13851:0:0:0|h[Hot Wolf Ribs]|h|r",
        recipe = _G.Profitable_DB.charRecipes[charKey]["15856:Hot Wolf Ribs"],
        quantity = 200,
        totalCost = 41400,
        totalNetRevenue = 62400,
        totalProfit = 21000,
        roiPercent = 51,
        verified = false,
        shoppingList = {
            { itemId = 12203, name = "Red Wolf Meat", link = "[Red Wolf Meat]", source = "AH", totalQuantity = 200, avgUnitPrice = 167, minUnitPrice = 167, maxUnitPrice = 167, totalCost = 33400 },
            { itemId = 2692, name = "Hot Spices", link = "[Hot Spices]", source = "Vendor", totalQuantity = 200, avgUnitPrice = 40, minUnitPrice = 40, maxUnitPrice = 40, totalCost = 8000 },
        },
    }
    _G.PF.DetailWindow.ShowOpportunity(ribsOppForBtn)
    Assert(_G.PF.DetailWindow.frame.recipeBtn:GetText() == "Open Cooking", "DetailWindow recipe button reads 'Open Cooking' for Hot Wolf Ribs")
    Assert(_G.PF.DetailWindow.frame.descText:GetText():find("%(Cooking%)") ~= nil, "DetailWindow explanation displays '(Cooking)' for Hot Wolf Ribs")

    _G.PF.DetailWindow.frame.recipeBtn:Click()
    Assert(#openedTradeSkillIds == 1 and openedTradeSkillIds[1] == 185, "Clicking 'Open Cooking' calls C_TradeSkillUI.OpenTradeSkill(185)")
    Assert(#openedRecipeIds >= 1 and openedRecipeIds[1] == 15856, "Clicking 'Open Cooking' selects Hot Wolf Ribs recipe (15856)")
    Assert(#craftedRecipeIds == 0, "Clicking 'Open Cooking' NEVER calls C_TradeSkillUI.CraftRecipe")

    -- Simulate TRADE_SKILL_DATA_SOURCE_CHANGED firing after OpenTradeSkill opens ProfessionsFrame
    -- Must select via C-side C_TradeSkillUI.OpenRecipe and NEVER touch ProfessionsFrame.CraftingPage:SelectRecipe (taint!)
    local openRecipeCallsBeforeEvent = #openedRecipeIds
    _G.PF.RecipeScanner.frame:Trigger("TRADE_SKILL_DATA_SOURCE_CHANGED")
    Assert(#openedRecipeIds == openRecipeCallsBeforeEvent + 1 and openedRecipeIds[#openedRecipeIds] == 15856, "TRADE_SKILL_DATA_SOURCE_CHANGED selects pending recipe via C_TradeSkillUI.OpenRecipe")
    Assert(#selectedModernRecipes == 0, "TRADE_SKILL_DATA_SOURCE_CHANGED NEVER calls ProfessionsFrame.CraftingPage:SelectRecipe directly (prevents UIPanel/ProfessionsFrame taint)")

    -- 21E. Hot Wolf Ribs stale 1s67c price is live-validated on AH and eliminated when real AH price is 3s+
    local now21 = math.floor(Mock.currentTime)
    _G.PCF_DB.prices = {
        [12203] = { minBuyout = 167, minBid = 167, count = 3731, lastUpdated = now21, source = "PCF Sniff" },
    }
    _G.PCF_DB.lastFullScan = now21
    _G.Profitable_DB.orderBookCache = {}
    _G.Profitable_DB.settings.includeSkillMatchedBaselineRecipes = false
    -- Keep ONLY Hot Wolf Ribs in charRecipes so it starts as #1 before live AH validation
    _G.Profitable_DB.charRecipes[charKey] = {
        ["15856:Hot Wolf Ribs"] = _G.Profitable_DB.charRecipes[charKey]["15856:Hot Wolf Ribs"],
    }
    _G.Profitable_MarketFeed = {
        timestamp = now21 - 600, -- 10 min old MarketFeed (previously caused AHVerifier to SKIP live check!)
        region = "us",
        rulesetId = 1,
        houseId = 113,
        items = {
            [12203] = { m = 290, q = 3731, med = 265, obs = 28, tiers = { { 290, 311 }, { 300, 156 } } },
        },
    }

    _G.AuctionFrame = nil
    _G.AuctionHouseFrame = _G.CreateFrame("Frame", "AuctionHouseFrame", _G.UIParent)
    _G.AuctionHouseFrame:Show()
    local liveQueries21 = {}
    _G.C_AuctionHouse = {
        MakeItemKey = function(id) return { itemID = id, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 } end,
        GetItemKeyInfo = function(key) return { itemID = key.itemID, isCommodity = true } end,
        IsThrottledMessageSystemReady = function() return true end,
        SendSearchQuery = function(itemKey)
            table.insert(liveQueries21, itemKey.itemID)
            if itemKey.itemID == 12203 then
                _G.PF.AHVerifier.frame:Trigger("COMMODITY_SEARCH_RESULTS_UPDATED", 12203)
            end
        end,
        GetNumCommoditySearchResults = function(id)
            if id == 12203 then return 2 end
            return 0
        end,
        GetCommoditySearchResultInfo = function(id, idx)
            if id == 12203 then
                local liveRows = {
                    { unitPrice = 300, quantity = 150 }, -- 3s each (300c + 40c spices = 340c > 312c vendor = LOSS!)
                    { unitPrice = 350, quantity = 200 },
                }
                return liveRows[idx]
            end
            return nil
        end,
    }

    Mock.timers = {}
    _G.PF.AHVerifier.StartDiscoveryAndVerification()
    Mock.FlushTimers(50)

    Assert(#liveQueries21 >= 1 and liveQueries21[1] == 12203, "Live AH verification queries Red Wolf Meat (12203) even when MarketFeed < 2h")
    local foundRibsAfterVerify = false
    for _, opp in ipairs(_G.Profitable_DB.lastTopPlays or {}) do
        if opp.itemId == 13851 then foundRibsAfterVerify = true end
    end
    Assert(foundRibsAfterVerify == false, "Hot Wolf Ribs is eliminated after live AH check confirms Red Wolf Meat is 3s+ (loss to vendor)")
    Assert(_G.PCF_DB.prices[12203] and _G.PCF_DB.prices[12203].minBuyout == 300, "Live AH check updates PCF_DB price for Red Wolf Meat from 1s67c to 3s")

    -- 21F. DetailWindow live revalidation flags an already-open play as [No Longer Profitable] when AH prices jump
    _G.PF.DetailWindow.ShowOpportunity(ribsOppForBtn)
    _G.PF.AHVerifier.frame:Trigger("COMMODITY_SEARCH_RESULTS_UPDATED", 12203)
    Assert(
        _G.PF.DetailWindow.frame.titleText:GetText():find("No Longer Profitable") ~= nil,
        "DetailWindow immediately updates badge to [No Longer Profitable] when live AH price exceeds max profitable cost"
    )
    Assert(
        _G.PF.DetailWindow.frame.shoppingRows[1].priceText:GetText():find("Live AH: 3s ea") ~= nil,
        "DetailWindow shopping row displays live AH unit price warning (3s ea > max 1s 67c)"
    )

    -- Restore globals
    _G.C_TradeSkillUI = origCTradeSkillUI
    _G.ProfessionsFrame = origProfessionsFrame
    _G.C_AuctionHouse = origCAH
    _G.AuctionHouseFrame = origAHFrame
    _G.AuctionFrame = origAuctionFrame
    _G.Profitable_MarketFeed = origMarketFeed
    _G.GetNumTradeSkills = origGetNumTradeSkills
end

-- 22. Regression Tests: "Open in AH" Throttle Queue & Stall Recovery + Multi-Step Inventory & Craft Sub-Rows (Ornate Mithril Helm)
do
    local origCTradeSkillUI = _G.C_TradeSkillUI
    local origProfessionsFrame = _G.ProfessionsFrame
    local origCAH = _G.C_AuctionHouse
    local origAHFrame = _G.AuctionHouseFrame
    local origAuctionFrame = _G.AuctionFrame
    local origGetNumTradeSkills = _G.GetNumTradeSkills

    -- 22A. "Open in AH" waits for throttle readiness, preserves AuctionHouseFrame.displayMode, and recovers from "Searching..." stalls
    _G.AuctionFrame = nil
    local throttleReady = false
    local selectBrowseCalls = {}
    local sendSearchCalls = {}
    local qtyInputCalls = {}
    local onQtyChangedCalls = 0

    _G.AuctionHouseFrame = _G.CreateFrame("Frame", "AuctionHouseFrame", _G.UIParent)
    _G.AuctionHouseFrame:Show()
    _G.AuctionHouseFrame.displayMode = "CommoditiesBuy"
    _G.AuctionHouseFrame.SearchBar = { SearchBox = { SetText = function() end } }
    _G.AuctionHouseFrame.CommoditiesBuyFrame = {
        IsShown = function() return true end,
        BuyList = { itemID = nil },
        BuyDisplay = {
            QuantityInput = {
                SetQuantity = function(_, q) table.insert(qtyInputCalls, { mode = "SetQuantity", q = q }) end,
                InputBox = {
                    SetNumber = function(_, q) table.insert(qtyInputCalls, { mode = "SetNumber", q = q }) end,
                },
            },
        },
        OnQuantityChanged = function() onQtyChangedCalls = onQtyChangedCalls + 1 end,
    }
    _G.AuctionHouseFrame.SelectBrowseResult = function(self, rowData)
        table.insert(selectBrowseCalls, rowData)
        self.displayMode = "CommoditiesBuy"
        self.CommoditiesBuyFrame.BuyList.itemID = rowData.itemKey.itemID
    end

    _G.C_AuctionHouse = {
        MakeItemKey = function(id) return { itemID = id, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 } end,
        GetItemKeyInfo = function(key) return { itemID = key.itemID, isCommodity = true } end,
        IsThrottledMessageSystemReady = function() return throttleReady end,
        SendSearchQuery = function(itemKey, sorts, isItem)
            table.insert(sendSearchCalls, { itemID = itemKey.itemID, isItem = isItem })
        end,
        GetNumCommoditySearchResults = function(id) return (id == 7971) and 1 or 0 end,
        GetCommoditySearchResultInfo = function(id, idx)
            if id == 7971 and idx == 1 then return { unitPrice = 1376, quantity = 10 } end
            return nil
        end,
    }

    Mock.timers = {}
    -- Click "Open in AH" on Black Pearl (7971) while throttled -> MUST defer instead of dropping search!
    _G.PF.AHVerifier.SearchItemOnAH(7971, "Black Pearl", nil, 3)
    Assert(#selectBrowseCalls == 0, "Open in AH defers SelectBrowseResult while C_AuctionHouse throttle is busy")

    -- Throttle clears -> AUCTION_HOUSE_THROTTLED_SYSTEM_READY flushes SelectBrowseResult cleanly!
    throttleReady = true
    _G.PF.AHVerifier.frame:Trigger("AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
    Assert(#selectBrowseCalls == 1 and selectBrowseCalls[1].itemKey.itemID == 7971, "AUCTION_HOUSE_THROTTLED_SYSTEM_READY triggers deferred SelectBrowseResult for Black Pearl")
    Assert(_G.AuctionHouseFrame.displayMode == "CommoditiesBuy", "OpenItemKeyInDefaultAH preserves AuctionHouseFrame.displayMode (never wipes to nil)")
    Assert(onQtyChangedCalls == 0, "Does NOT invoke OnQuantityChanged prematurely before search results arrive")

    -- Simulate stall (no COMMODITY_SEARCH_RESULTS_UPDATED received) -> stall watchdog fires SendSearchQuery!
    Assert(#sendSearchCalls == 0, "No duplicate SendSearchQuery on the same tick as SelectBrowseResult")
    Mock.FlushTimers(5)
    Assert(#sendSearchCalls >= 1 and sendSearchCalls[1].itemID == 7971, "Stall-recovery watchdog automatically re-sends SendSearchQuery when 'Searching...' hangs")

    -- When COMMODITY_SEARCH_RESULTS_UPDATED finally arrives, quantity updates cleanly via OnQuantityChanged
    _G.PF.AHVerifier.frame:Trigger("COMMODITY_SEARCH_RESULTS_UPDATED", 7971)
    Assert(onQtyChangedCalls == 1, "COMMODITY_SEARCH_RESULTS_UPDATED triggers OnQuantityChanged cleanly once listings arrive")

    -- 22B. Multi-step Ornate Mithril Helm (x3): live intermediate inventory awareness, craft sub-rows & per-step Open buttons
    _G.GetNumTradeSkills = function() return 0 end
    local openedProfIds22 = {}
    local openedRecipeIds22 = {}
    local profMap22 = {
        [9980]  = { professionID = 164, professionName = "Blacksmithing", parentProfessionID = 164, parentProfessionName = "Blacksmithing" },
        [10097] = { professionID = 186, professionName = "Mining",        parentProfessionID = 186, parentProfessionName = "Mining" },
        [10098] = { professionID = 186, professionName = "Mining",        parentProfessionID = 186, parentProfessionName = "Mining" },
        [9920]  = { professionID = 164, professionName = "Blacksmithing", parentProfessionID = 164, parentProfessionName = "Blacksmithing" },
    }
    _G.ProfessionsFrame = _G.CreateFrame("Frame", "ProfessionsFrame", _G.UIParent)
    _G.ProfessionsFrame:Hide()
    _G.C_TradeSkillUI = {
        GetProfessionInfoByRecipeID = function(rId) return profMap22[rId] end,
        OpenTradeSkill = function(skillId)
            table.insert(openedProfIds22, skillId)
            return true
        end,
        OpenRecipe = function(rId)
            table.insert(openedRecipeIds22, rId)
        end,
    }

    local charKey22 = _G.PF.GetCharacterKey()
    local now22 = math.floor(Mock.currentTime)
    _G.Profitable_DB.settings.includeSkillMatchedBaselineRecipes = false
    _G.Profitable_DB.settings.useIntermediateCrafting = true
    _G.Profitable_DB.itemCache[7937] = { name = "Ornate Mithril Helm", quality = 2, itemLevel = 44, classID = 4, invType = "INVTYPE_HEAD", vendorSell = 2028 }
    _G.Profitable_DB.charRecipes[charKey22] = {
        ["9980:Ornate Mithril Helm"] = {
            recipeId = 9980, name = "Ornate Mithril Helm", profession = "Blacksmithing", professionId = 164,
            outputItemId = 7937, avgMade = 1,
            reagents = {
                { itemId = 3860, name = "Mithril Bar", count = 16 },
                { itemId = 6037, name = "Truesilver Bar", count = 2 },
                { itemId = 7971, name = "Black Pearl", count = 1 },
                { itemId = 7966, name = "Solid Grinding Stone", count = 1 },
            },
        },
        ["10097:Smelt Mithril"] = {
            recipeId = 10097, name = "Smelt Mithril", profession = "Mining", professionId = 186,
            outputItemId = 3860, avgMade = 1,
            reagents = { { itemId = 3858, name = "Mithril Ore", count = 1 } },
        },
        ["10098:Smelt Truesilver"] = {
            recipeId = 10098, name = "Smelt Truesilver", profession = "Mining", professionId = 186,
            outputItemId = 6037, avgMade = 1,
            reagents = { { itemId = 7911, name = "Truesilver Ore", count = 1 } },
        },
        ["9920:Solid Grinding Stone"] = {
            recipeId = 9920, name = "Solid Grinding Stone", profession = "Blacksmithing", professionId = 164,
            outputItemId = 7966, avgMade = 1,
            reagents = { { itemId = 7912, name = "Solid Stone", count = 4 } },
        },
    }

    -- Prices: Ore/Stone cheaper than Bars/Grinding Stone, Helm profitable to Craft & AH
    _G.Profitable_DB.orderBookCache = {}
    _G.PCF_DB.prices = {
        [3858] = { minBuyout = 1040, count = 100, lastUpdated = now22, source = "Scan" }, -- Mithril Ore 10s40c
        [3860] = { minBuyout = 1500, count = 100, lastUpdated = now22, source = "Scan" }, -- Mithril Bar 15s (more expensive than ore)
        [7911] = { minBuyout = 1225, count = 50,  lastUpdated = now22, source = "Scan" }, -- Truesilver Ore 12s25c
        [6037] = { minBuyout = 1800, count = 50,  lastUpdated = now22, source = "Scan" }, -- Truesilver Bar 18s
        [7971] = { minBuyout = 1376, count = 10,  lastUpdated = now22, source = "Scan" }, -- Black Pearl 13s76c
        [7912] = { minBuyout = 133,  count = 100, lastUpdated = now22, source = "Scan" }, -- Solid Stone 1s33c
        [7966] = { minBuyout = 900,  count = 50,  lastUpdated = now22, source = "Scan" }, -- Solid Grinding Stone 9s
        [7937] = { minBuyout = 35069, count = 5,  lastUpdated = now22, source = "Scan" }, -- Ornate Mithril Helm 3g50s69c
    }

    Mock.bagCounts = { [7912] = 40 } -- 40 Solid Stone in bags, 0 bars/ores/pearls
    Mock.bankCounts = {}
    local helmTop = _G.PF.OpportunityEngine.FindTopOpportunities(500000)
    local helmOpp = nil
    for _, o in ipairs(helmTop) do
        if o.itemId == 7937 then helmOpp = o end
    end
    Assert(helmOpp ~= nil and helmOpp.quantity == 3, "Calculate Craft & AH Ornate Mithril Helm (x3) with intermediate steps")
    Assert(helmOpp.intermediateSteps and #helmOpp.intermediateSteps == 3, "Ornate Mithril Helm records all 3 intermediate craft steps (Mithril Bar, Truesilver Bar, Solid Grinding Stone)")

    _G.PF.DetailWindow.ShowOpportunity(helmOpp)
    local rows22 = _G.PF.DetailWindow.frame.shoppingRows
    -- Expected interleaved rows:
    -- 1: SHOP Mithril Ore (48x)
    -- 2: CRAFT Mithril Bar (48x) -> Open Mining
    -- 3: SHOP Truesilver Ore (6x)
    -- 4: CRAFT Truesilver Bar (6x) -> Open Mining
    -- 5: SHOP Black Pearl (3x)
    -- 6: SHOP Solid Stone (12x) -> Ready: 40 / 12
    -- 7: CRAFT Solid Grinding Stone (3x) -> Open Blacksmithing (mats ready!)
    Assert(rows22[1]._rowKind == "SHOP" and rows22[1]._itemData.itemId == 3858, "Row 1 is Mithril Ore shopping item")
    Assert(rows22[2]._rowKind == "CRAFT" and rows22[2]._stepData.outputItemId == 3860, "Row 2 is indented Mithril Bar craft sub-row")
    Assert(rows22[2].craftBtn:IsShown() == true and rows22[2].craftBtn:GetText() == "Open Mining", "Mithril Bar sub-row displays 'Open Mining' button")
    Assert(rows22[7]._rowKind == "CRAFT" and rows22[7]._stepData.outputItemId == 7966, "Row 7 is indented Solid Grinding Stone craft sub-row")
    Assert(rows22[7].craftBtn:GetText() == "Open Blacksmithing", "Solid Grinding Stone sub-row displays 'Open Blacksmithing' button")
    Assert(rows22[7].statusText:GetText():find("mats ready") ~= nil, "Solid Grinding Stone sub-row shows '(mats ready!)' when 40 Solid Stone are in bags")
    Assert(_G.PF.DetailWindow.frame.recipeBtn:GetText() == "Open Blacksmithing", "Footer recipe button displays 'Open Blacksmithing' for final Ornate Mithril Helm")

    -- Clicking sub-row "Open Mining" opens Mining (186) to Smelt Mithril (10097)
    rows22[2].craftBtn:Click()
    Assert(openedProfIds22[1] == 186 and openedRecipeIds22[1] == 10097, "Clicking Mithril Bar sub-row 'Open Mining' opens Mining (186) to Smelt Mithril (10097)")

    -- Clicking sub-row "Open Blacksmithing" opens Blacksmithing (164) to Solid Grinding Stone (9920)
    rows22[7].craftBtn:Click()
    Assert(openedProfIds22[2] == 164 and openedRecipeIds22[2] == 9920, "Clicking Solid Grinding Stone sub-row 'Open Blacksmithing' opens Blacksmithing (164) to Solid Grinding Stone (9920)")

    -- Clicking footer "Open Blacksmithing" opens Blacksmithing (164) to Ornate Mithril Helm (9980)
    _G.PF.DetailWindow.frame.recipeBtn:Click()
    Assert(openedProfIds22[3] == 164 and openedRecipeIds22[3] == 9980, "Clicking footer 'Open Blacksmithing' opens Blacksmithing (164) to Ornate Mithril Helm (9980)")

    -- Scenario 1: Player ALREADY has 48 Mithril Bars in bags (0 Mithril Ore) -> Mithril Ore is completely satisfied!
    Mock.bagCounts[3860] = 48
    Mock.bagCounts[3858] = 0
    _G.PF.DetailWindow.RefreshIfShown()
    Assert(rows22[1]._itemData.effectiveQuantity == 0 and rows22[1]._itemData.remainingToBuy == 0, "Having 48 Mithril Bars sets Mithril Ore effective needed & remainingToBuy to 0")
    Assert(rows22[1].statusText:GetText():find("Covered by 48 / 48 Mithril Bar") ~= nil, "Mithril Ore status shows 'Covered by 48 / 48 Mithril Bar'")
    Assert(rows22[1].buyBtn:GetText() == "Ready", "Mithril Ore buy button shows 'Ready' when satisfied by Mithril Bars")
    Assert(rows22[2].statusText:GetText():find("Ready: 48 / 48") ~= nil, "Mithril Bar sub-row shows 'Ready: 48 / 48'")

    -- Verify OpenNextNeededItemInDefaultAH SKIPS Mithril Ore (satisfied by bars) and opens Truesilver Ore (7911)!
    selectBrowseCalls = {}
    _G.PF.AHVerifier.OpenNextNeededItemInDefaultAH(helmOpp)
    Assert(#selectBrowseCalls == 1 and selectBrowseCalls[1].itemKey.itemID == 7911, "OpenNextNeededItemInDefaultAH skips Mithril Ore when 48 Mithril Bars are already owned and opens Truesilver Ore")

    -- Scenario 2: Partial intermediate inventory (20 Mithril Bars + 10 Mithril Ore in bags) -> only need 18 more Mithril Ore!
    Mock.bagCounts[3860] = 20
    Mock.bagCounts[3858] = 10
    _G.PF.DetailWindow.RefreshIfShown()
    Assert(rows22[1]._itemData.effectiveQuantity == 28 and rows22[1]._itemData.remainingToBuy == 18, "Having 20 Mithril Bars + 10 Mithril Ore reduces Mithril Ore needed to 28 and remainingToBuy to 18")
    Assert(rows22[2].statusText:GetText():find("Have: 20 / 48") ~= nil and rows22[2].statusText:GetText():find("Craft 28") ~= nil and rows22[2].statusText:GetText():find("10 ready now") ~= nil, "Mithril Bar sub-row shows 'Have: 20 / 48 — Craft 28 (10 ready now)'")

    -- Restore globals
    _G.C_TradeSkillUI = origCTradeSkillUI
    _G.ProfessionsFrame = origProfessionsFrame
    _G.C_AuctionHouse = origCAH
    _G.AuctionHouseFrame = origAHFrame
    _G.AuctionFrame = origAuctionFrame
    _G.GetNumTradeSkills = origGetNumTradeSkills
end

-- 23. Regression Tests: Collapsed Non-Commodity C_AuctionHouse.GetItemSearchResultInfo Rows (Linen Reagent Bag 253664)
do
    local origCAH = _G.C_AuctionHouse
    local origAHFrame = _G.AuctionHouseFrame
    local origAuctionFrame = _G.AuctionFrame
    local origDB = _G.Profitable_DB

    -- 23A. v2 -> v3 migration purges tainted non-commodity orderBookCache and PCF Sniff / Profitable Live entries
    _G.PCF_DB.prices[253664] = { minBuyout = 18, minBid = 18, count = 129, lastUpdated = math.floor(Mock.currentTime), source = "Profitable Live" }
    _G.PCF_DB.prices[2589]   = { minBuyout = 15, minBid = 15, count = 500, lastUpdated = math.floor(Mock.currentTime), source = "PCF Full Scan" }
    local legacyV2DB = {
        version = 2,
        orderBookCache = {
            [253664] = {
                timestamp = math.floor(Mock.currentTime),
                listings = { { unitPrice = 18, quantity = 43 } },
            },
        },
        embeddedPCF = {
            prices = {
                [253664] = { minBuyout = 18, minBid = 18, count = 129, lastUpdated = math.floor(Mock.currentTime), source = "PCF Sniff" },
            },
        },
        lastTopPlays = { { id = "VENDOR:253664", itemId = 253664 } },
        activePlay = { id = "VENDOR:253664", itemId = 253664 },
    }
    _G.PF.LoadConfig(legacyV2DB)
    Assert(legacyV2DB.version == 4, "v2 -> v4 migration upgrades config version to 4")
    Assert(next(legacyV2DB.orderBookCache) == nil, "v2 -> v3 migration flushes poisoned orderBookCache")
    Assert(_G.PCF_DB.prices[253664] == nil and legacyV2DB.embeddedPCF.prices[253664] == nil, "v2 -> v3 migration purges tainted PCF Sniff / Profitable Live entries")
    Assert(_G.PCF_DB.prices[2589] and _G.PCF_DB.prices[2589].minBuyout == 15, "v2 -> v3 migration preserves intact PCF Full Scan prices")
    Assert(#legacyV2DB.lastTopPlays == 0 and legacyV2DB.activePlay == nil, "v2 -> v3 migration clears stale lastTopPlays and activePlay")
    _G.Profitable_DB = origDB
    _G.PF.LoadConfig(origDB)

    -- 23B. Collapsed non-commodity rows in C_AuctionHouse.GetItemSearchResultInfo (Linen Reagent Bag: 253664)
    -- In WoW's C_AuctionHouse API, non-commodity items collapse identical 1-item auctions into a single row where
    -- buyoutAmount is the per-item buyout (7s 77c = 777c) and quantity is the count of collapsed auctions (43).
    _G.Profitable_DB.itemCache[253664] = {
        name = "Linen Reagent Bag",
        link = "|cffffffff|Hitem:253664:0:0:0|h[Linen Reagent Bag]|h|r",
        quality = 1,
        itemLevel = 5,
        classID = 1,
        subClassID = 1,
        invType = "INVTYPE_BAG",
        vendorSell = 200, -- 2s vendor sell price
    }

    local collapsedBagRows = {
        { auctionID = 9001, buyoutAmount = 776,     minBid = 0,   quantity = 7  }, -- 7x @ 7s 76c each (NOT 1s 10c!)
        { auctionID = 9002, buyoutAmount = 777,     minBid = 0,   quantity = 43 }, -- 43x @ 7s 77c each (NOT 18c!)
        { auctionID = 9003, buyoutAmount = 800,     minBid = 0,   quantity = 7  }, -- 7x @ 8s 00c each (NOT 1s 14c!)
        { auctionID = 9004, buyoutAmount = 850,     minBid = 0,   quantity = 17 }, -- 17x @ 8s 50c each (NOT 50c!)
        { auctionID = 9005, buyoutAmount = 900,     minBid = 0,   quantity = 12 }, -- 12x @ 9s 00c each (NOT 75c!)
        { auctionID = 9006, buyoutAmount = 949,     minBid = 0,   quantity = 1  }, -- 1x @ 9s 49c
        { auctionID = 9007, buyoutAmount = 950,     minBid = 0,   quantity = 13 }, -- 13x @ 9s 50c each (NOT 73c!)
        { auctionID = 9008, buyoutAmount = 999,     minBid = 0,   quantity = 27 }, -- 27x @ 9s 99c each (NOT 37c!)
        { auctionID = 9009, buyoutAmount = 700640,  minBid = 640, quantity = 1  }, -- 1x @ 70g 6s 40c (bid 6s 40c)
        { auctionID = 9010, buyoutAmount = 1000539, minBid = 445, quantity = 1  }, -- 1x @ 100g 5s 39c (bid 4s 45c)
    }

    _G.AuctionFrame = nil
    _G.AuctionHouseFrame = _G.CreateFrame("Frame", "AuctionHouseFrame", _G.UIParent)
    _G.AuctionHouseFrame:Show()
    local placedBids23 = {}
    _G.C_AuctionHouse = {
        MakeItemKey = function(id) return { itemID = id, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 } end,
        GetItemKeyInfo = function(key) return { itemID = key.itemID, isCommodity = false } end,
        IsThrottledMessageSystemReady = function() return true end,
        GetNumItemSearchResults = function(itemKey)
            if type(itemKey) == "table" and itemKey.itemID == 253664 then
                return #collapsedBagRows
            end
            return 0
        end,
        GetItemSearchResultInfo = function(itemKey, index)
            if type(itemKey) == "table" and itemKey.itemID == 253664 then
                return collapsedBagRows[index]
            end
            return nil
        end,
        PlaceBid = function(auctionID, buyoutAmount)
            table.insert(placedBids23, { auctionID = auctionID, buyoutAmount = buyoutAmount })
        end,
    }

    -- Verify PCF.Scanner.SniffItemSearchResults records unit buyout 776c (7s 76c) and count 129, NEVER 777/43 = 18c
    local sniffed23 = _G.PCF.Scanner.SniffItemSearchResults({ itemID = 253664 })
    Assert(sniffed23 == 1, "PCF.Scanner.SniffItemSearchResults processes Linen Reagent Bag search results")
    Assert(
        _G.PCF_DB.prices[253664] and _G.PCF_DB.prices[253664].minBuyout == 776 and _G.PCF_DB.prices[253664].count == 129,
        "PCF.Scanner.SniffItemSearchResults records 7s 76c (776c) unit buyout and 129 total count for collapsed rows (never 18c)"
    )

    -- Verify PF.AHVerifier ITEM_SEARCH_RESULTS_UPDATED records unitPrice = 776c (qty 7) and updates PCF_DB
    _G.Profitable_DB.orderBookCache = {}
    _G.PF.AHVerifier.frame:Trigger("ITEM_SEARCH_RESULTS_UPDATED", { itemID = 253664 })
    local bagBook = _G.Profitable_DB.orderBookCache[253664]
    Assert(bagBook ~= nil and type(bagBook.listings) == "table" and #bagBook.listings == 10, "AHVerifier records all 10 listing tiers for Linen Reagent Bag")
    Assert(
        bagBook.listings[1].unitPrice == 776 and bagBook.listings[1].quantity == 7,
        "Cheapest Linen Reagent Bag tier is 7x @ 7s 76c (776c), never dividing 777/43 = 18c"
    )
    Assert(
        bagBook.listings[2].unitPrice == 777 and bagBook.listings[2].quantity == 43,
        "Second Linen Reagent Bag tier is 43x @ 7s 77c (777c)"
    )

    -- Verify OpportunityEngine never suggests vendoring Linen Reagent Bag (7s 76c AH > 2s vendor sell)
    local top23 = _G.PF.OpportunityEngine.FindTopOpportunities(87207)
    local foundBagVendorPlay = false
    for _, opp in ipairs(top23) do
        if opp.itemId == 253664 then
            foundBagVendorPlay = true
        end
    end
    Assert(foundBagVendorPlay == false, "Linen Reagent Bag is NOT suggested as a Vendor play when AH buyout is 7s 76c+ vs 2s vendor sell")

    -- Verify BuyNextCheapListing refuses to purchase when maxUnitPrice is 200c (2s) and cheapest AH listing is 776c (7s 76c)
    local bought23, _, _, status23 = _G.PF.AHVerifier.BuyNextCheapListing(253664, "Linen Reagent Bag", 200, 1)
    Assert(bought23 == false and status23 == "NO_CHEAP_LISTING" and #placedBids23 == 0, "BuyNextCheapListing refuses to buy 7s 76c Linen Reagent Bag when max profitable price is 2s")

    -- Restore globals
    _G.C_AuctionHouse = origCAH
    _G.AuctionHouseFrame = origAHFrame
    _G.AuctionFrame = origAuctionFrame
end

-- 24. Regression Tests: Blizzard UI Taint Prevention (GameTooltip / ContainerFrame / ProfessionsFrame / AuctionHouseFrame)
do
    local origTooltip = _G.GameTooltip
    local origTooltipProcessor = _G.TooltipDataProcessor
    local origEnum = _G.Enum
    local origInCombat = _G.InCombatLockdown
    local origHookSecure = _G.hooksecurefunc
    local origCContainer = _G.C_Container

    -- 24A. GameTooltip must NEVER receive custom fields (_pcfHooked / _pcfStackCount) or Show() calls inside TooltipDataProcessor
    local showCalls24 = 0
    local addedLines24 = {}
    local tooltipHooks24 = {}
    local bagItemHookCb = nil
    local postCallCb = nil

    _G.hooksecurefunc = function(tbl, method, fn)
        if tbl == _G.GameTooltip and method == "SetBagItem" then
            bagItemHookCb = fn
        end
    end
    _G.C_Container = {
        GetContainerItemInfo = function(bag, slot)
            if bag == 0 and slot == 1 then
                return { itemID = 2589, stackCount = 5 }
            end
            return nil
        end,
    }
    _G.Enum = { TooltipDataType = { Item = 0 } }
    _G.TooltipDataProcessor = {
        AddTooltipPostCall = function(dataType, cb)
            if dataType == 0 then postCallCb = cb end
        end,
    }

    local strictTooltip = {
        shown = true,
        IsShown = function(self) return self.shown end,
        IsForbidden = function() return false end,
        GetName = function() return "GameTooltip" end,
        NumLines = function() return #addedLines24 end,
        GetItem = function() return "Linen Cloth", "|cffffffff|Hitem:2589:0:0:0|h[Linen Cloth]|h|r" end,
        SetBagItem = function() end,
        AddLine = function(_, text) table.insert(addedLines24, text) end,
        Show = function() showCalls24 = showCalls24 + 1 end,
        HookScript = function(_, script, fn) tooltipHooks24[script] = fn end,
    }
    _G.GameTooltip = strictTooltip
    _G.PCF_DB.prices[2589] = { minBuyout = 25, minBid = 25, count = 200, lastUpdated = math.floor(Mock.currentTime), source = "Scan" }
    _G.PCF_DB.settings.showTooltip = true
    _G.PCF.Tooltip._processorHooked = nil

    _G.PCF.Tooltip.Init()
    Assert(strictTooltip._pcfHooked == nil, "PCF.Tooltip.Init NEVER writes _pcfHooked onto GameTooltip")
    Assert(tooltipHooks24["OnTooltipSetItem"] == nil, "PCF.Tooltip.Init skips legacy OnTooltipSetItem HookScript when TooltipDataProcessor is present")
    Assert(type(bagItemHookCb) == "function" and type(postCallCb) == "function", "PCF.Tooltip.Init registers SetBagItem hook and TooltipDataProcessor post-call")

    -- Simulate hovering a 5-stack bag item (SetBagItem -> TooltipDataProcessor post-call)
    bagItemHookCb(strictTooltip, 0, 1)
    Assert(strictTooltip._pcfStackCount == nil, "SetBagItem hook stores stack count in local weak table and NEVER writes _pcfStackCount onto GameTooltip")
    postCallCb(strictTooltip, { id = 2589 })
    Assert(#addedLines24 == 1 and addedLines24[1]:find("^AH%s+Price:") ~= nil and addedLines24[1]:find("1|T") ~= nil, "TooltipDataProcessor post-call appends stack + unit AH Price line using local weak-table stack count")
    Assert(showCalls24 == 0, "TooltipDataProcessor post-call NEVER calls GameTooltip:Show() (prevents GameTooltip/ContainerFrame taint)")

    -- Simulate OnTooltipCleared / OnHide -> must NOT write _pcfStackCount onto GameTooltip
    tooltipHooks24["OnTooltipCleared"](strictTooltip)
    tooltipHooks24["OnHide"](strictTooltip)
    Assert(strictTooltip._pcfStackCount == nil, "OnTooltipCleared/OnHide never touch properties on GameTooltip")

    -- Simulate forbidden tooltip passed to TooltipDataProcessor -> must be ignored completely
    local forbiddenAdded = 0
    local forbiddenTooltip = {
        IsForbidden = function() return true end,
        AddLine = function() forbiddenAdded = forbiddenAdded + 1 end,
    }
    postCallCb(forbiddenTooltip, { id = 2589 })
    Assert(forbiddenAdded == 0, "TooltipDataProcessor post-call ignores forbidden tooltips")

    -- Simulate RefreshVisibleTooltip -> must NEVER call GameTooltip:Show() and must skip during combat
    _G.PCF.Tooltip.RefreshVisibleTooltip()
    Assert(showCalls24 == 0, "PCF.Tooltip.RefreshVisibleTooltip never calls GameTooltip:Show()")

    _G.InCombatLockdown = function() return true end
    local combatOpened = _G.PF.RecipeScanner.OpenRecipe({ recipeId = 15856, name = "Hot Wolf Ribs", profession = "Cooking" })
    Assert(combatOpened == false, "PF.RecipeScanner.OpenRecipe refuses to open profession window during combat lockdown")

    -- Restore globals
    _G.GameTooltip = origTooltip
    _G.TooltipDataProcessor = origTooltipProcessor
    _G.Enum = origEnum
    _G.InCombatLockdown = origInCombat
    _G.hooksecurefunc = origHookSecure
    _G.C_Container = origCContainer
end

-- 25. Regression Tests: Classic Epic Disenchant Yield (Lifestone iLvl 56 -> 1x Nexus Crystal, NOT 1.5x)
do
    local now25 = math.floor(Mock.currentTime)
    _G.Profitable_DB.itemCache[833] = {
        name = "Lifestone",
        link = "|cffa335ee|Hitem:833:0:0:0|h[Lifestone]|h|r",
        quality = 4,
        itemLevel = 56,
        classID = 4,
        subClassID = 0,
        invType = "INVTYPE_TRINKET",
        vendorSell = 25000,
    }

    local drops833 = _G.PF.DisenchantDatabase.GetDisenchantDrops(833)
    Assert(
        drops833 ~= nil and #drops833 == 1 and drops833[1].itemId == 20725 and drops833[1].avgQty == 1.0 and drops833[1].maxQty == 1,
        "Lifestone (iLvl 56 Epic) yields exactly 1.0x Nexus Crystal (never 1.5x)"
    )

    local eval833 = _G.PF.DisenchantDatabase.EvaluateDisenchant(833, nil, function(id)
        if id == 20725 then return 445000 end -- 44g 50s
        return nil
    end, 0.05)
    Assert(
        eval833 ~= nil and eval833.grossValue == 445000 and eval833.netValue == math.floor(445000 * 0.95 + 0.5),
        "Lifestone DE net expected revenue at 44g 50s Nexus Crystal is 42g 27s 50c (not 63g+)"
    )

    _G.Profitable_DB.orderBookCache = {}
    _G.PCF_DB.prices = {
        [833]   = { minBuyout = 470000, count = 1,  lastUpdated = now25, source = "Scan" }, -- Lifestone @ 47g
        [20725] = { minBuyout = 445000, count = 20, lastUpdated = now25, source = "Scan" }, -- Nexus Crystal @ 44g 50s
    }
    _G.Profitable_DB.settings.assumeCanDisenchant = true
    local topUnprofitable = _G.PF.OpportunityEngine.FindTopOpportunities(5000000)
    local foundBadLifestone = false
    for _, opp in ipairs(topUnprofitable) do
        if opp.itemId == 833 or (opp.deTargetMatId == 20725) then
            foundBadLifestone = true
        end
    end
    Assert(foundBadLifestone == false, "Lifestone at 47g is NOT suggested as profitable when Nexus Crystal is 44g 50s")

    -- When Lifestone IS genuinely cheap (35g vs 44g 50s Nexus Crystal -> 42g 27s 50c net), profit is +7g 27s 50c
    _G.PCF_DB.prices[833].minBuyout = 350000
    local topProfitable = _G.PF.OpportunityEngine.FindTopOpportunities(5000000)
    local foundGoodLifestone = nil
    for _, opp in ipairs(topProfitable) do
        if opp.itemId == 833 or (opp.deBreakdown and opp.deBreakdown.primaryMat and opp.deBreakdown.primaryMat.itemId == 20725) then
            foundGoodLifestone = opp
        end
    end
    Assert(
        foundGoodLifestone ~= nil and foundGoodLifestone.totalProfit == (math.floor(445000 * 0.95 + 0.5) - 350000),
        "Cheap Lifestone (35g) is accurately evaluated for 1x Nexus Crystal profit (+7g 27s 50c)"
    )
end

-- 26. Regression Tests: Window Layering (MEDIUM + SetToplevel) & AH Verification / Search Performance
do
    local origCAH = _G.C_AuctionHouse
    local origAHFrame = _G.AuctionHouseFrame
    local origAuctionFrame = _G.AuctionFrame
    local origGetItemInfo = _G.GetItemInfo
    local origCItem = _G.C_Item
    local origFindTop = _G.PF.OpportunityEngine.FindTopOpportunities

    -- 26A. All primary Profitable windows use MEDIUM strata + SetToplevel(true) so Professions/AH windows can pull to front
    Assert(
        _G.PF.DetailWindow.frame:GetFrameStrata() == "MEDIUM" and _G.PF.DetailWindow.frame:IsToplevel() == true,
        "DetailWindow uses MEDIUM strata + SetToplevel(true) so clicking Professions/Crafting pulls it in front"
    )
    Assert(
        _G.PF.SideWindow.frame:GetFrameStrata() == "MEDIUM" and _G.PF.SideWindow.frame:IsToplevel() == true,
        "SideWindow uses MEDIUM strata + SetToplevel(true) so Blizzard panels and Profitable swap focus cleanly"
    )
    _G.PF.SideWindow.ToggleSettingsWindow()
    local settingsWin = _G.PF.SideWindow.settingsFrame
    Assert(
        settingsWin and settingsWin:GetFrameStrata() == "MEDIUM" and settingsWin:IsToplevel() == true,
        "SettingsWindow uses MEDIUM strata + SetToplevel(true)"
    )
    _G.PF.SideWindow.ToggleSettingsWindow()

    -- 26B. GetItemMetadata hits itemCache in O(1) without calling GetItemInfo or RequestLoadItemDataByID on cached items
    local getItemInfoCalls = 0
    local serverLoadRequests = 0
    _G.GetItemInfo = function(id)
        getItemInfoCalls = getItemInfoCalls + 1
        return origGetItemInfo(id)
    end
    _G.C_Item = {
        GetItemInfo = _G.GetItemInfo,
        RequestLoadItemDataByID = function()
            serverLoadRequests = serverLoadRequests + 1
        end,
    }
    _G.Profitable_DB.itemCache[2589] = { name = "Linen Cloth", quality = 1, itemLevel = 5, classID = 7, subClassID = 5, invType = "", vendorSell = 13 }
    local meta26 = _G.PF.VendorDatabase.GetItemMetadata(2589)
    Assert(meta26 and meta26.name == "Linen Cloth" and getItemInfoCalls == 0, "GetItemMetadata serves cached items in O(1) with zero GetItemInfo calls")

    -- Uncached item during bulk scan (skipServerRequest = true) sends ZERO RequestLoadItemDataByID packets
    _G.Profitable_DB.itemCache[999123] = nil
    _G.PF.VendorDatabase.GetItemMetadata(999123, nil, true)
    Assert(serverLoadRequests == 0, "Bulk scan GetItemMetadata(id, nil, true) sends zero RequestLoadItemDataByID server packets")

    -- 26C. HarvestBrowseResultItemKeys caches GetBrowseResults once per browse batch instead of looping 7,000+ items per click
    local getBrowseCalls26 = 0
    local commodityRowReads26 = 0
    _G.AuctionFrame = nil
    _G.AuctionHouseFrame = _G.CreateFrame("Frame", "AuctionHouseFrame", _G.UIParent)
    _G.AuctionHouseFrame:Show()
    _G.AuctionHouseFrame.SelectBrowseResult = function() end
    _G.C_AuctionHouse = {
        MakeItemKey = function(id) return { itemID = id, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 } end,
        GetItemKeyInfo = function(key) return { itemID = key.itemID, isCommodity = true } end,
        IsThrottledMessageSystemReady = function() return true end,
        GetBrowseResults = function()
            getBrowseCalls26 = getBrowseCalls26 + 1
            return { { itemKey = { itemID = 2589 }, minPrice = 15, totalQuantity = 100 } }
        end,
        SendSearchQuery = function(key)
            _G.PF.AHVerifier.frame:Trigger("COMMODITY_SEARCH_RESULTS_UPDATED", key.itemID)
        end,
        GetNumCommoditySearchResults = function(id)
            if id == 2589 then return 500 end -- 500 commodity rows!
            return 0
        end,
        GetCommoditySearchResultInfo = function(id, idx)
            commodityRowReads26 = commodityRowReads26 + 1
            return { unitPrice = 10 + idx, quantity = 50 }
        end,
    }
    _G.PF.AHVerifier.frame:Trigger("AUCTION_HOUSE_CLOSED")
    _G.PF.AHVerifier.SearchItemOnAH(2589, "Linen Cloth", nil, 20)
    _G.PF.AHVerifier.SearchItemOnAH(2589, "Linen Cloth", nil, 20)
    _G.PF.AHVerifier.SearchItemOnAH(2589, "Linen Cloth", nil, 20)
    Assert(getBrowseCalls26 == 1, "Repeated 'Open in AH' clicks harvest GetBrowseResults() only ONCE per browse batch (never re-scanning 7,000+ rows per click)")

    -- 26D. CollectModernCommodityResults stops early at MAX_ORDERBOOK_QTY (600) instead of scanning all 500 rows
    commodityRowReads26 = 0
    _G.PF.AHVerifier.frame:Trigger("COMMODITY_SEARCH_RESULTS_UPDATED", 2589)
    Assert(commodityRowReads26 <= 15, "CollectModernCommodityResults stops early once 600+ units collected instead of iterating all 500 AH rows")

    -- 26E. DetailWindow.RevalidateActiveOpportunity uses O(1) ReevaluateSingleOpportunity without calling full FindTopOpportunities()
    local findTopCalls26 = 0
    _G.PF.OpportunityEngine.FindTopOpportunities = function(...)
        findTopCalls26 = findTopCalls26 + 1
        return origFindTop(...)
    end
    local linenVendorOpp = {
        id = "VENDOR:2589",
        actionType = "VENDOR",
        actionLabel = "Vendor",
        itemId = 2589,
        itemName = "Linen Cloth",
        itemLink = "|cffffffff|Hitem:2589:0:0:0|h[Linen Cloth]|h|r",
        quantity = 20,
        totalCost = 200,
        totalNetRevenue = 260,
        totalProfit = 60,
        roiPercent = 30,
        verified = true,
        shoppingList = {
            { itemId = 2589, name = "Linen Cloth", link = "[Linen Cloth]", source = "AH", totalQuantity = 20, avgUnitPrice = 10, minUnitPrice = 10, maxUnitPrice = 10, totalCost = 200 },
        },
    }
    _G.PF.DetailWindow.ShowOpportunity(linenVendorOpp)
    findTopCalls26 = 0
    _G.PF.AHVerifier.frame:Trigger("COMMODITY_SEARCH_RESULTS_UPDATED", 2589)
    Assert(findTopCalls26 == 0, "DetailWindow.RevalidateActiveOpportunity re-evaluates active play in O(1) with ZERO full FindTopOpportunities() scans")

    -- 26F. StartDiscoveryAndVerification runs FindTopOpportunities() once at start (not twice) and NOT on every single verified item
    local now26 = math.floor(Mock.currentTime)
    _G.PCF_DB.prices = {
        [2589] = { minBuyout = 5, count = 100, lastUpdated = now26, source = "Scan" },
    }
    _G.Profitable_DB.orderBookCache = {}
    findTopCalls26 = 0
    Mock.timers = {}
    _G.PF.AHVerifier.StartDiscoveryAndVerification()
    Assert(findTopCalls26 == 1, "StartDiscoveryAndVerification calls FindTopOpportunities() ONCE at start (not twice)")
    Mock.FlushTimers(30)
    -- 1 initial + 1 end-of-pass check + 1 FinalizeRun = at most 3 (regardless of queue length, never N+3)
    Assert(findTopCalls26 <= 3, "Verification run avoids per-item FindTopOpportunities() recalculations")

    -- Restore globals
    _G.PF.OpportunityEngine.FindTopOpportunities = origFindTop
    _G.C_AuctionHouse = origCAH
    _G.AuctionHouseFrame = origAHFrame
    _G.AuctionFrame = origAuctionFrame
    _G.GetItemInfo = origGetItemInfo
    _G.C_Item = origCItem
end

-- 27. Regression Tests: Unlearned Profession Pruning, Linked/NPC Scan Guards, GetProfessions nil-slot Fix, and Strategy-Tagged Verification Progress
do
    local origGetProfessions = _G.GetProfessions
    local origGetProfessionInfo = _G.GetProfessionInfo
    local origIsLoggedIn = _G.IsLoggedIn
    local origIsTradeSkillLinked = _G.IsTradeSkillLinked
    local origIsTradeSkillGuild = _G.IsTradeSkillGuild
    local origGetNumTradeSkills = _G.GetNumTradeSkills
    local origTradeSkillLine = Mock.tradeSkillLine
    local origTradeSkills = Mock.tradeSkills
    local origSkillLines = Mock.skillLines
    local origCTradeSkillUI = _G.C_TradeSkillUI
    local origCAH = _G.C_AuctionHouse
    local origAHFrame = _G.AuctionHouseFrame
    local origAuctionFrame = _G.AuctionFrame

    Mock.skillLines = {}
    _G.IsLoggedIn = function() return true end

    -- 27A. GetCharacterSkillRanks reads ALL 6 GetProfessions() slots even when Archaeology (slot 3) is nil
    local mockProfTable = {
        [1] = { "Blacksmithing", 0, 225, 300, 1, 0, 164 },
        [2] = { "Mining",        0, 250, 300, 1, 0, 186 },
        [3] = { "Fishing",       0, 150, 300, 1, 0, 356 },
        [4] = { "Cooking",       0, 200, 300, 1, 0, 185 },
    }
    _G.GetProfessions = function() return 1, 2, nil, 3, 4, nil end
    _G.GetProfessionInfo = function(idx)
        local row = mockProfTable[idx]
        if not row then return nil end
        return row[1], row[2], row[3], row[4], row[5], row[6], row[7]
    end

    local ranks27, hasAuth27 = _G.PF.RecipeDatabase.GetCharacterSkillRanks()
    Assert(hasAuth27 == true, "GetCharacterSkillRanks reports authoritative skill data when GetProfessions is present")
    Assert(ranks27["Blacksmithing"] and ranks27["Blacksmithing"].rank == 225 and ranks27["Blacksmithing"].skillLine == 164, "Detect Blacksmithing (225 / 164) from GetProfessions")
    Assert(ranks27["Mining"] and ranks27["Mining"].rank == 250 and ranks27["Mining"].skillLine == 186, "Detect Mining (250 / 186) from GetProfessions")
    Assert(ranks27["Cooking"] and ranks27["Cooking"].rank == 200 and ranks27["Cooking"].skillLine == 185, "Detect Cooking (slot 5) even when Archaeology (slot 3) is nil")
    Assert(ranks27["Tailoring"] == nil, "Blacksmith/Miner does NOT detect Tailoring")

    -- 27B. Stale/dropped/linked Tailoring recipes in current char's charRecipes are pruned, while alts' recipes stay intact
    local charKey27 = _G.PF.GetCharacterKey()
    local altKey27 = "TailorAlt-Forever"
    _G.GetNumTradeSkills = function() return 0 end
    _G.C_TradeSkillUI = nil
    _G.Profitable_DB.settings.includeAllCharRecipes = false
    _G.Profitable_DB.settings.includeSkillMatchedBaselineRecipes = true
    _G.Profitable_DB.charRecipes = {
        [charKey27] = {
            ["3840:Runecloth Belt"] = {
                recipeId = 18401, name = "Runecloth Belt", profession = "Tailoring", professionId = 197,
                outputItemId = 13856, avgMade = 1,
                reagents = { { itemId = 14048, name = "Bolt of Runecloth", count = 2 }, { itemId = 14341, name = "Rune Thread", count = 1 } },
            },
            ["3841:Bolt of Mageweave"] = {
                recipeId = 12046, name = "Bolt of Mageweave", profession = "Tailoring", professionId = 197,
                outputItemId = 4339, avgMade = 1,
                reagents = { { itemId = 4338, name = "Mageweave Cloth", count = 5 } },
            },
            ["9920:Solid Grinding Stone"] = {
                recipeId = 9920, name = "Solid Grinding Stone", profession = "Blacksmithing", professionId = 164,
                outputItemId = 7966, avgMade = 1,
                reagents = { { itemId = 7912, name = "Solid Stone", count = 4 } },
            },
        },
        [altKey27] = {
            ["18401:Runecloth Belt"] = {
                recipeId = 18401, name = "Runecloth Belt", profession = "Tailoring", professionId = 197,
                outputItemId = 13856, avgMade = 1,
                reagents = { { itemId = 14048, name = "Bolt of Runecloth", count = 2 }, { itemId = 14341, name = "Rune Thread", count = 1 } },
            },
        },
    }
    _G.Profitable_DB.lastTopPlays = {
        { id = "CRAFT_AH:13856", actionType = "CRAFT_AH", itemId = 13856, recipe = _G.Profitable_DB.charRecipes[charKey27]["3840:Runecloth Belt"] },
        { id = "VENDOR:2447", actionType = "VENDOR", itemId = 2447 },
    }
    _G.Profitable_DB.activePlay = _G.Profitable_DB.lastTopPlays[1]

    local pruned27 = _G.PF.RecipeScanner.PruneUnlearnedCharRecipes()
    Assert(pruned27 == 2, "PruneUnlearnedCharRecipes removes both stale Tailoring recipes from Blacksmith/Miner")
    Assert(_G.Profitable_DB.charRecipes[charKey27]["3840:Runecloth Belt"] == nil and _G.Profitable_DB.charRecipes[charKey27]["3841:Bolt of Mageweave"] == nil, "Stale Tailoring recipes are purged from current character's SavedVariables")
    Assert(_G.Profitable_DB.charRecipes[charKey27]["9920:Solid Grinding Stone"] ~= nil, "Learned Blacksmithing recipe is preserved")
    Assert(_G.Profitable_DB.charRecipes[altKey27]["18401:Runecloth Belt"] ~= nil, "Other characters' (alt) Tailoring recipes are NEVER pruned")
    Assert(#_G.Profitable_DB.lastTopPlays == 1 and _G.Profitable_DB.lastTopPlays[1].id == "VENDOR:2447", "Cached Tailoring craft play is cleared from lastTopPlays while Vendor play remains")
    Assert(_G.Profitable_DB.activePlay == nil, "Cached unlearned Tailoring activePlay is cleared")

    -- Verify GetKnownRecipes returns ZERO Tailoring recipes and ZERO Tailoring intermediate bolt conversions
    local known27 = _G.PF.RecipeScanner.GetKnownRecipes()
    local foundAnyTailoring27 = false
    local foundAnyBS27 = false
    for _, rec in ipairs(known27) do
        if rec.profession == "Tailoring" then foundAnyTailoring27 = true end
        if rec.profession == "Blacksmithing" then foundAnyBS27 = true end
    end
    Assert(foundAnyTailoring27 == false, "GetKnownRecipes returns ZERO Tailoring recipes (saved or baseline/trainer) for a Blacksmith/Miner")
    Assert(foundAnyBS27 == true, "GetKnownRecipes still returns Blacksmithing recipes for a Blacksmith/Miner")
    Assert(_G.PF.RecipeScanner.GetIntermediateRecipeForItem(4339) == nil, "GetIntermediateRecipeForItem(Bolt of Mageweave) returns nil for a Blacksmith/Miner")

    -- 27C. SKILL_LINES_CHANGED automatically prunes recipes if a character unlearns a profession
    _G.Profitable_DB.charRecipes[charKey27]["3840:Runecloth Belt"] = {
        recipeId = 18401, name = "Runecloth Belt", profession = "Tailoring", professionId = 197,
        outputItemId = 13856, avgMade = 1,
        reagents = { { itemId = 14048, name = "Bolt of Runecloth", count = 2 } },
    }
    _G.PF.RecipeScanner.frame:Trigger("SKILL_LINES_CHANGED")
    Assert(_G.Profitable_DB.charRecipes[charKey27]["3840:Runecloth Belt"] == nil, "SKILL_LINES_CHANGED prunes unlearned Tailoring recipes automatically")

    -- 27D. Legacy ScanLegacyTradeSkill blocks linked profession windows and unlearned Tailoring windows
    _G.GetNumTradeSkills = origGetNumTradeSkills
    Mock.tradeSkillLine = "Tailoring"
    Mock.tradeSkills = {
        { name = "Runecloth Belt", outputItemId = 13856, reagents = { { itemId = 14048, name = "Bolt of Runecloth", count = 2 } } },
    }
    _G.IsTradeSkillLinked = function() return true end
    Assert(_G.PF.RecipeScanner.ScanLegacyTradeSkill() == 0, "ScanLegacyTradeSkill ignores linked profession windows (IsTradeSkillLinked == true)")
    _G.IsTradeSkillLinked = function() return false end
    Assert(_G.PF.RecipeScanner.ScanLegacyTradeSkill() == 0, "ScanLegacyTradeSkill rejects unlearned Tailoring window on Blacksmith/Miner")
    Assert(_G.Profitable_DB.charRecipes[charKey27]["13856:Runecloth Belt"] == nil, "Rejected Tailoring recipe is never saved to charRecipes")

    -- 27E. Modern ScanModernTradeSkillUI blocks IsNPCCrafting, IsRecipeProfessionLearned == false, and unlearned Tailoring
    _G.GetNumTradeSkills = function() return 0 end
    local npcCrafting27 = true
    local recipeProfLearned27 = true
    _G.C_TradeSkillUI = {
        IsTradeSkillLinked = function() return false end,
        IsTradeSkillGuild = function() return false end,
        IsNPCCrafting = function() return npcCrafting27 end,
        IsTradeSkillReady = function() return true end,
        IsRecipeProfessionLearned = function() return recipeProfLearned27 end,
        GetAllRecipeIDs = function() return { 18401 } end,
        GetBaseProfessionInfo = function() return { professionID = 197, professionName = "Tailoring" } end,
        GetProfessionInfoByRecipeID = function() return { professionID = 197, professionName = "Tailoring", parentProfessionID = 197, parentProfessionName = "Tailoring" } end,
        GetRecipeInfo = function() return { recipeID = 18401, name = "Runecloth Belt", learned = true, itemID = 13856 } end,
        GetRecipeSchematic = function()
            return {
                outputItemID = 13856, quantityMin = 1, quantityMax = 1,
                reagentSlotSchematics = { { quantityRequired = 2, reagents = { { itemID = 14048 } } } },
            }
        end,
    }
    Assert(_G.PF.RecipeScanner.ScanModernTradeSkillUI() == 0, "ScanModernTradeSkillUI ignores NPC crafting windows (IsNPCCrafting == true)")
    npcCrafting27 = false
    recipeProfLearned27 = false
    Assert(_G.PF.RecipeScanner.ScanModernTradeSkillUI() == 0, "ScanModernTradeSkillUI skips recipes where IsRecipeProfessionLearned == false")
    recipeProfLearned27 = true
    Assert(_G.PF.RecipeScanner.ScanModernTradeSkillUI() == 0, "ScanModernTradeSkillUI rejects Tailoring recipes not learned by Blacksmith/Miner")

    -- 27F. Early pre-login (IsLoggedIn == false) with empty GetProfessions does NOT prematurely wipe charRecipes; post-login 0-prof char DOES prune
    _G.C_TradeSkillUI = nil
    _G.GetProfessions = function() return nil, nil, nil, nil, nil, nil end
    _G.IsLoggedIn = function() return false end
    _G.Profitable_DB.charRecipes[charKey27] = {
        ["9920:Solid Grinding Stone"] = {
            recipeId = 9920, name = "Solid Grinding Stone", profession = "Blacksmithing", professionId = 164,
            outputItemId = 7966, avgMade = 1,
            reagents = { { itemId = 7912, name = "Solid Stone", count = 4 } },
        },
    }
    Assert(_G.PF.RecipeScanner.PruneUnlearnedCharRecipes() == 0, "Pre-login (IsLoggedIn == false) does NOT prematurely prune saved recipes")
    Assert(_G.Profitable_DB.charRecipes[charKey27]["9920:Solid Grinding Stone"] ~= nil, "Saved Blacksmithing recipe survives pre-login check")
    _G.IsLoggedIn = function() return true end
    Assert(_G.PF.RecipeScanner.PruneUnlearnedCharRecipes() == 1, "Logged-in character with 0 professions prunes stale saved recipes")

    -- 27G. Verification status bar tags queued items with their strategy ([Vendor], [DE], [Craft])
    _G.GetProfessions = function() return 1, 2, nil, 3, 4, nil end
    _G.Profitable_DB.settings.assumeCanDisenchant = false
    _G.Profitable_DB.settings.showCraftPlays = false
    _G.Profitable_DB.settings.showVendorPlays = true
    _G.Profitable_DB.settings.includeSkillMatchedBaselineRecipes = false
    _G.Profitable_DB.itemCache[7084] = { name = "Pattern: Green Silk Armor", quality = 2, itemLevel = 33, classID = 9, vendorSell = 1500 }
    local now27 = math.floor(Mock.currentTime)
    _G.PCF_DB.prices = {
        [7084] = { minBuyout = 200, count = 2, lastUpdated = now27, source = "Scan" },
    }
    _G.PCF_DB.lastFullScan = now27
    _G.Profitable_DB.orderBookCache = {}
    _G.Profitable_MarketFeed = nil
    _G.AuctionFrame = nil
    _G.AuctionHouseFrame = _G.CreateFrame("Frame", "AuctionHouseFrame", _G.UIParent)
    _G.AuctionHouseFrame:Show()
    local capturedStatus27 = nil
    _G.C_AuctionHouse = {
        MakeItemKey = function(id) return { itemID = id, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 } end,
        GetItemKeyInfo = function(key) return { itemID = key.itemID, isCommodity = false } end,
        IsThrottledMessageSystemReady = function() return true end,
        SendSearchQuery = function()
            capturedStatus27 = _G.PF.SideWindow.frame and _G.PF.SideWindow.frame.statusText and _G.PF.SideWindow.frame.statusText:GetText()
        end,
        GetNumItemSearchResults = function() return 0 end,
    }
    Mock.timers = {}
    _G.PF.SideWindow.RunSearch()
    -- Flush only the first verification step timer so SendSearchQuery runs and captures in-flight statusText
    if #Mock.timers > 0 then
        local firstTimer = table.remove(Mock.timers, 1)
        firstTimer.callback()
    end
    Assert(
        type(capturedStatus27) == "string" and capturedStatus27:find("%[Vendor%]") ~= nil and capturedStatus27:find("Pattern: Green Silk Armor") ~= nil,
        "SideWindow verification status tags Pattern Vendor flips with '[Vendor]: Pattern: Green Silk Armor'"
    )
    _G.PF.AHVerifier.Stop("TEST_DONE")
    _G.PF.SideWindow.UpdateProgress(2, 5, { name = "Azure Silk Vest", strategyTag = "DE" })
    Assert(_G.PF.SideWindow.frame.statusText:GetText() == "2/5 [DE]: Azure Silk Vest", "SideWindow.UpdateProgress formats [DE] tag cleanly")
    _G.PF.SideWindow.UpdateProgress(3, 5, { name = "Mithril Ore", strategyTag = "Craft" })
    Assert(_G.PF.SideWindow.frame.statusText:GetText() == "3/5 [Craft]: Mithril Ore", "SideWindow.UpdateProgress formats [Craft] tag cleanly")

    -- Restore globals
    _G.GetProfessions = origGetProfessions
    _G.GetProfessionInfo = origGetProfessionInfo
    _G.IsLoggedIn = origIsLoggedIn
    _G.IsTradeSkillLinked = origIsTradeSkillLinked
    _G.IsTradeSkillGuild = origIsTradeSkillGuild
    _G.GetNumTradeSkills = origGetNumTradeSkills
    Mock.tradeSkillLine = origTradeSkillLine
    Mock.tradeSkills = origTradeSkills
    Mock.skillLines = origSkillLines
    _G.C_TradeSkillUI = origCTradeSkillUI
    _G.C_AuctionHouse = origCAH
    _G.AuctionHouseFrame = origAHFrame
    _G.AuctionFrame = origAuctionFrame
    _G.Profitable_DB.settings.assumeCanDisenchant = true
    _G.Profitable_DB.settings.showCraftPlays = true
    _G.Profitable_DB.settings.showVendorPlays = true
end

-- 28. UX Tests: Direct Zero-Taint 'Craft Nx' Buttons & Server-Confirmed AH Purchase Tracking / Double-Buy Guard
do
    local origCTradeSkillUI = _G.C_TradeSkillUI
    local origProfFrame = _G.ProfessionsFrame
    local origGetNumTradeSkills = _G.GetNumTradeSkills
    local origInCombat = _G.InCombatLockdown
    local origCAH = _G.C_AuctionHouse
    local origAHFrame = _G.AuctionHouseFrame
    local origAuctionFrame = _G.AuctionFrame
    local origGetInboxNumItems = _G.GetInboxNumItems
    local origERR_WON = _G.ERR_AUCTION_WON_S

    _G.PF.AHVerifier.ClearPurchasedTracker()

    -- 28A. Direct Zero-Taint 'Craft Nx' Button (Intermediate Sub-Rows & Final Craft Footer)
    _G.GetNumTradeSkills = function() return 0 end
    local currentOpenProfId28 = nil
    local openedTradeSkills28 = {}
    local openedRecipes28 = {}
    local craftedCalls28 = {}

    _G.ProfessionsFrame = _G.CreateFrame("Frame", "ProfessionsFrame", _G.UIParent)
    _G.ProfessionsFrame:Hide()

    _G.C_TradeSkillUI = {
        IsTradeSkillLinked = function() return false end,
        IsTradeSkillGuild = function() return false end,
        IsTradeSkillReady = function() return currentOpenProfId28 ~= nil end,
        GetBaseProfessionInfo = function()
            if not currentOpenProfId28 then return nil end
            return { professionID = currentOpenProfId28, parentProfessionID = currentOpenProfId28 }
        end,
        GetProfessionInfoByRecipeID = function(rId)
            if rId == 10098 then return { professionID = 186, professionName = "Mining", parentProfessionID = 186, parentProfessionName = "Mining" } end
            if rId == 9995 then return { professionID = 164, professionName = "Blacksmithing", parentProfessionID = 164, parentProfessionName = "Blacksmithing" } end
            return nil
        end,
        OpenTradeSkill = function(skillId)
            table.insert(openedTradeSkills28, skillId)
            currentOpenProfId28 = skillId
            _G.ProfessionsFrame:Show()
            return true
        end,
        OpenRecipe = function(rId)
            table.insert(openedRecipes28, rId)
            return true
        end,
        CraftRecipe = function(rId, qty)
            table.insert(craftedCalls28, { recipeId = rId, quantity = qty })
            return true
        end,
    }

    local tsGauntletsOpp = {
        id = "CRAFT_AH:7938",
        actionType = "CRAFT_AH",
        actionLabel = "Craft and AH",
        itemId = 7938,
        itemName = "Truesilver Gauntlets",
        itemLink = "|cff1eff00|Hitem:7938:0:0:0|h[Truesilver Gauntlets]|h|r",
        quantity = 2,
        totalCost = 59349,
        totalNetRevenue = 86888,
        totalProfit = 27539,
        roiPercent = 46,
        verified = true,
        recipe = {
            recipeId = 9995, name = "Truesilver Gauntlets", profession = "Blacksmithing", professionId = 164,
            outputItemId = 7938, avgMade = 1,
            reagents = {
                { itemId = 6037, name = "Truesilver Bar", count = 8 },
                { itemId = 7909, name = "Aquamarine", count = 3 },
            },
        },
        intermediateSteps = {
            {
                recipeId = 10098, recipeName = "Smelt Truesilver", profession = "Mining", professionId = 186,
                outputItemId = 6037, outputName = "Truesilver Bar", outputLink = "[Truesilver Bar]",
                countPerUnit = 8, totalQuantity = 16, avgMade = 1,
                reagents = { { itemId = 7911, name = "Truesilver Ore", countPerBatch = 1 } },
            },
        },
        shoppingList = {
            { itemId = 7911, name = "Truesilver Ore", link = "[Truesilver Ore]", source = "AH", countPerUnit = 8, directQuantity = 0, totalQuantity = 16, avgUnitPrice = 1285, minUnitPrice = 1285, maxUnitPrice = 1285, totalCost = 20560 },
            { itemId = 7909, name = "Aquamarine", link = "[Aquamarine]", source = "AH", countPerUnit = 3, directQuantity = 6, totalQuantity = 6, avgUnitPrice = 1150, minUnitPrice = 1150, maxUnitPrice = 1173, totalCost = 6900 },
        },
    }

    Mock.bagCounts[7911] = 0
    Mock.bagCounts[6037] = 0
    Mock.bagCounts[7909] = 0
    _G.PF.DetailWindow.ShowOpportunity(tsGauntletsOpp)
    local rows28 = _G.PF.DetailWindow.frame.shoppingRows
    -- Row 1: Truesilver Ore (SHOP), Row 2: Truesilver Bar (CRAFT), Row 3: Aquamarine (SHOP)
    Assert(rows28[2].craftNowBtn:IsShown() == false, "Craft sub-row hides Craft Nx button when raw ores are not yet in bags")
    Assert(_G.PF.DetailWindow.frame.craftFinalBtn:IsShown() == false, "Footer hides final Craft Nx button when final mats are not yet in bags")

    -- Loot 16 Truesilver Ore into bags -> sub-row shows "Craft 16x" alongside "Open Mining"
    Mock.bagCounts[7911] = 16
    _G.PF.DetailWindow.RefreshIfShown()
    Assert(rows28[2].craftNowBtn:IsShown() == true and rows28[2].craftNowBtn:GetText() == "Craft 16x", "Craft sub-row displays 'Craft 16x' button once 16 Truesilver Ore are in bags")
    Assert(rows28[2].craftBtn:IsShown() == true and rows28[2].craftBtn:GetText() == "Open Mining", "Craft sub-row keeps 'Open Mining' button alongside 'Craft 16x'")

    -- Click 1 while Mining is closed: opens Mining cleanly without blindly calling CraftRecipe
    rows28[2].craftNowBtn:Click()
    Assert(#openedTradeSkills28 == 1 and openedTradeSkills28[1] == 186 and #craftedCalls28 == 0, "First click on 'Craft 16x' when Mining is closed opens Mining (186) to Smelt Truesilver")

    -- Click 2 now that Mining is open: directly calls C_TradeSkillUI.CraftRecipe(10098, 16)
    rows28[2].craftNowBtn:Click()
    Assert(#craftedCalls28 == 1 and craftedCalls28[1].recipeId == 10098 and craftedCalls28[1].quantity == 16, "Second click on 'Craft 16x' directly calls C_TradeSkillUI.CraftRecipe(10098, 16)")

    -- Once 16 Truesilver Bars + 6 Aquamarines are in bags: sub-row shows checkmark & hides Craft 16x; footer shows "Craft 2x"
    Mock.bagCounts[7911] = 0
    Mock.bagCounts[6037] = 16
    Mock.bagCounts[7909] = 6
    _G.PF.DetailWindow.RefreshIfShown()
    Assert(rows28[2].craftNowBtn:IsShown() == false, "Craft sub-row hides Craft Nx once all 16/16 Truesilver Bars are crafted")
    Assert(rows28[2].itemText:GetText():find("ReadyCheck%-Ready") ~= nil, "Completed Craft sub-row displays green checkmark icon")
    Assert(_G.PF.DetailWindow.frame.craftFinalBtn:IsShown() == true and _G.PF.DetailWindow.frame.craftFinalBtn:GetText() == "Craft 2x", "Footer displays 'Craft 2x' button when final Blacksmithing reagents are ready")

    -- Footer 'Craft 2x': Click 1 switches from Mining -> Blacksmithing (164), Click 2 crafts 2x Truesilver Gauntlets
    _G.PF.DetailWindow.frame.craftFinalBtn:Click()
    Assert(currentOpenProfId28 == 164 and #craftedCalls28 == 1, "Footer 'Craft 2x' opens Blacksmithing (164) first when window was still on Mining")
    _G.PF.DetailWindow.frame.craftFinalBtn:Click()
    Assert(#craftedCalls28 == 2 and craftedCalls28[2].recipeId == 9995 and craftedCalls28[2].quantity == 2, "Footer 'Craft 2x' directly calls C_TradeSkillUI.CraftRecipe(9995, 2) once Blacksmithing is open")

    -- Combat lockdown refuses CraftRecipe safely
    _G.InCombatLockdown = function() return true end
    local combatOk28, combatReason28 = _G.PF.RecipeScanner.CraftRecipe(tsGauntletsOpp.recipe, 2)
    Assert(combatOk28 == false and combatReason28 == "COMBAT", "CraftRecipe refuses to run during combat lockdown")
    _G.InCombatLockdown = origInCombat

    -- 28B. CHAT_MSG_SYSTEM ERR_AUCTION_WON_S parsing
    _G.ERR_AUCTION_WON_S = "You won an auction for %s"
    local pName1, pQty1 = _G.PF.AHVerifier.ParseAuctionWonMessage("You won an auction for Mithril Ore (x29)")
    Assert(pName1 == "Mithril Ore" and pQty1 == 29, "ParseAuctionWonMessage extracts commodity name and stack count (Mithril Ore x29)")
    local pName2, pQty2 = _G.PF.AHVerifier.ParseAuctionWonMessage("You won an auction for Guardian Gloves")
    Assert(pName2 == "Guardian Gloves" and pQty2 == 1, "ParseAuctionWonMessage extracts single-item name and quantity 1 (Guardian Gloves)")
    local pName3, pQty3 = _G.PF.AHVerifier.ParseAuctionWonMessage("You won an auction for Guardian Gloves of the Bear")
    Assert(pName3 == "Guardian Gloves of the Bear" and pQty3 == 1, "ParseAuctionWonMessage extracts random-suffix BoE item name")

    -- 28C. Server-Confirmed Commodity & Single-Item Purchase Tracking, Deduplication, Double-Buy Guard, and Bag/Mail Reconciliation
    _G.PF.AHVerifier.ClearPurchasedTracker()
    Mock.bagCounts[3858] = 0
    Mock.bagCounts[5963] = 0
    _G.AuctionFrame = nil
    _G.AuctionHouseFrame = _G.CreateFrame("Frame", "AuctionHouseFrame", _G.UIParent)
    _G.AuctionHouseFrame:Show()

    local ahThrottleReady28 = true
    local startCommCalls28 = 0
    local confirmCommCalls28 = 0
    local placeBidCalls28 = {}

    _G.C_AuctionHouse = {
        MakeItemKey = function(id) return { itemID = id, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 } end,
        GetItemKeyInfo = function(key) return { itemID = key.itemID, isCommodity = (key.itemID == 3858) } end,
        IsThrottledMessageSystemReady = function() return ahThrottleReady28 end,
        GetNumCommoditySearchResults = function(id) return (id == 3858) and 1 or 0 end,
        GetCommoditySearchResultInfo = function(id, idx)
            if id == 3858 and idx == 1 then return { unitPrice = 932, quantity = 60 } end
            return nil
        end,
        StartCommoditiesPurchase = function() startCommCalls28 = startCommCalls28 + 1 end,
        ConfirmCommoditiesPurchase = function() confirmCommCalls28 = confirmCommCalls28 + 1 end,
        GetNumItemSearchResults = function(key) return (key and key.itemID == 5963) and 4 or 0 end,
        GetItemSearchResultInfo = function(key, idx)
            if key and key.itemID == 5963 then
                local auctions = {
                    { auctionID = 144878577, buyoutAmount = 1988, quantity = 1 },
                    { auctionID = 144878498, buyoutAmount = 1988, quantity = 1 },
                    { auctionID = 144755564, buyoutAmount = 1988, quantity = 1 },
                    { auctionID = 144755999, buyoutAmount = 1988, quantity = 1 },
                }
                return auctions[idx]
            end
            return nil
        end,
        PlaceBid = function(aId, amt)
            table.insert(placeBidCalls28, { auctionID = aId, amount = amt })
        end,
    }

    local mixedBuyOpp = {
        id = "CRAFT_AH:7938",
        actionType = "CRAFT_AH",
        actionLabel = "Craft and AH",
        itemId = 7938,
        itemName = "Test Play",
        itemLink = "[Test Play]",
        quantity = 1,
        totalCost = 32992,
        totalNetRevenue = 50000,
        totalProfit = 17008,
        roiPercent = 52,
        verified = true,
        shoppingList = {
            { itemId = 3858, name = "Mithril Ore", link = "[Mithril Ore]", source = "AH", countPerUnit = 29, directQuantity = 29, totalQuantity = 29, avgUnitPrice = 932, minUnitPrice = 932, maxUnitPrice = 1000, totalCost = 27028 },
            { itemId = 5963, name = "Guardian Gloves", link = "[Guardian Gloves]", source = "AH", countPerUnit = 3, directQuantity = 3, totalQuantity = 3, avgUnitPrice = 1988, minUnitPrice = 1988, maxUnitPrice = 2000, totalCost = 5964 },
        },
    }
    _G.PF.DetailWindow.ShowOpportunity(mixedBuyOpp)

    -- Commodity: Reserve 29x Mithril Ore -> Throttled Confirm does NOT count -> Failed Confirm does NOT count -> Confirmed Succeeds ONCE (deduped against chat)
    rows28[1].buyBtn:Click()
    Assert(startCommCalls28 == 1 and rows28[1].buyBtn:GetText() == "Confirm (29)", "Click 1 reserves 29x Mithril Ore")

    ahThrottleReady28 = false
    rows28[1].buyBtn:Click()
    Assert(confirmCommCalls28 == 0 and rows28[1].buyBtn:GetText() == "Confirm (29)" and _G.PF.AHVerifier.GetPurchasedInMailCount(3858) == 0, "Throttled Confirm click preserves Confirm (29) and records ZERO purchased")

    ahThrottleReady28 = true
    rows28[1].buyBtn:Click()
    Assert(confirmCommCalls28 == 1 and rows28[1].buyBtn:GetText() == "Buying..." and _G.PF.AHVerifier.GetPurchasedInMailCount(3858) == 0, "Confirm click shows 'Buying...' while awaiting server confirmation")

    -- Simulate COMMODITY_PURCHASE_FAILED -> must remain 0 purchased
    _G.PF.AHVerifier.frame:Trigger("COMMODITY_PURCHASE_FAILED")
    Assert(_G.PF.AHVerifier.GetPurchasedInMailCount(3858) == 0 and rows28[1].buyBtn:GetText() == "Buy 29x", "COMMODITY_PURCHASE_FAILED clears in-flight state and records ZERO purchased")

    -- Retry and succeed via COMMODITY_PURCHASE_SUCCEEDED + CHAT_MSG_SYSTEM (must count 29, NOT 58!)
    rows28[1].buyBtn:Click()
    rows28[1].buyBtn:Click()
    _G.PF.AHVerifier.frame:Trigger("COMMODITY_PURCHASE_SUCCEEDED")
    _G.PF.AHVerifier.frame:Trigger("CHAT_MSG_SYSTEM", "You won an auction for Mithril Ore (x29)")
    Assert(_G.PF.AHVerifier.GetPurchasedInMailCount(3858) == 29, "COMMODITY_PURCHASE_SUCCEEDED + CHAT_MSG_SYSTEM deduplicates to exactly 29 (never 58)")
    Assert(rows28[1].buyBtn:GetText() == "Bought", "Fully purchased commodity row button changes to 'Bought'")
    Assert(rows28[1].itemText:GetText():find("ReadyCheck%-Ready") ~= nil, "Fully purchased commodity row displays green checkmark icon")
    Assert(rows28[1].statusText:GetText():find("Purchased: 29 / 29 %(Check Mail%)") ~= nil, "Fully purchased commodity row status shows 'Purchased: 29 / 29 (Check Mail)'")

    -- Double-buy protection: clicking 'Bought' must NOT call StartCommoditiesPurchase
    local prevStartComm = startCommCalls28
    rows28[1].buyBtn:Click()
    Assert(startCommCalls28 == prevStartComm, "Clicking 'Bought' blocks accidental double-buying of Mithril Ore")

    -- RevalidateActiveOpportunity after buying out Mithril Ore must NOT mark play [No Longer Profitable]
    _G.C_AuctionHouse.GetCommoditySearchResultInfo = function(id, idx)
        if id == 3858 and idx == 1 then return { unitPrice = 99999, quantity = 10 } end
        return nil
    end
    _G.PF.AHVerifier.frame:Trigger("COMMODITY_SEARCH_RESULTS_UPDATED", 3858)
    Assert(not mixedBuyOpp._liveUnprofitable, "Buying out cheap Mithril Ore does NOT falsely flag already-purchased play as [No Longer Profitable]")

    -- Single-item non-commodity flow: 3x Guardian Gloves with throttle retry, reverse event order, and random-suffix BoE chat message
    rows28[2].buyBtn:Click()
    Assert(#placeBidCalls28 == 1 and placeBidCalls28[1].auctionID == 144878577 and _G.PF.AHVerifier.GetPurchasedInMailCount(5963) == 0, "PlaceBid #1 waits for server confirmation before marking bought")
    _G.PF.AHVerifier.frame:Trigger("AUCTION_HOUSE_PURCHASE_COMPLETED", 144878577)
    _G.PF.AHVerifier.frame:Trigger("CHAT_MSG_SYSTEM", "You won an auction for Guardian Gloves")
    Assert(_G.PF.AHVerifier.GetPurchasedInMailCount(5963) == 1, "Guardian Gloves #1 confirmed by event + chat deduplicates to 1")
    Assert(rows28[2].statusText:GetText():find("Bought: 1 / 3 %(in mail%)") ~= nil, "Partial buy shows 'Bought: 1 / 3 (in mail) — Buy 2'")

    -- Throttled Click 2 must NOT submit PlaceBid or increment bought count
    ahThrottleReady28 = false
    rows28[2].buyBtn:Click()
    Assert(#placeBidCalls28 == 1 and _G.PF.AHVerifier.GetPurchasedInMailCount(5963) == 1, "Throttled single-item buy leaves Guardian Gloves at 1 / 3")

    -- Retry Click 2: CHAT_MSG_SYSTEM arrives BEFORE AUCTION_HOUSE_PURCHASE_COMPLETED (reverse order dedup!)
    ahThrottleReady28 = true
    rows28[2].buyBtn:Click()
    Assert(#placeBidCalls28 == 2 and placeBidCalls28[2].auctionID == 144878498, "Retry #2 submits next auctionID #144878498")
    _G.PF.AHVerifier.frame:Trigger("CHAT_MSG_SYSTEM", "You won an auction for Guardian Gloves")
    _G.PF.AHVerifier.frame:Trigger("AUCTION_HOUSE_PURCHASE_COMPLETED", 144878498)
    Assert(_G.PF.AHVerifier.GetPurchasedInMailCount(5963) == 2, "Reverse-order chat + event deduplicates cleanly to 2 / 3")

    -- Click 3: confirmed by random-suffix BoE system message ("Guardian Gloves of the Bear")
    rows28[2].buyBtn:Click()
    Assert(#placeBidCalls28 == 3 and placeBidCalls28[3].auctionID == 144755564, "Buy #3 submits auctionID #144755564")
    _G.PF.AHVerifier.frame:Trigger("CHAT_MSG_SYSTEM", "You won an auction for Guardian Gloves of the Bear")
    Assert(_G.PF.AHVerifier.GetPurchasedInMailCount(5963) == 3, "Random-suffix 'Guardian Gloves of the Bear' resolves to Guardian Gloves (3 / 3)")
    Assert(rows28[2].buyBtn:GetText() == "Bought", "3 / 3 Guardian Gloves button switches to 'Bought'")
    Assert(rows28[2].itemText:GetText():find("ReadyCheck%-Ready") ~= nil, "3 / 3 Guardian Gloves displays green checkmark icon")

    -- Accidental Click 4 on 'Bought' Guardian Gloves is blocked!
    rows28[2].buyBtn:Click()
    Assert(#placeBidCalls28 == 3, "Clicking 'Bought' on 3/3 Guardian Gloves prevents accidentally buying a 4th pair")

    -- Bag-loot reconciliation: looting 15 then 14 Mithril Ore transitions In Mail -> Bags smoothly
    Mock.bagCounts[3858] = 15
    _G.PF.DetailWindow.frame:Trigger("BAG_UPDATE")
    Assert(_G.PF.AHVerifier.GetPurchasedInMailCount(3858) == 14, "Looting 15 Mithril Ore from mail decrements in-mail count from 29 -> 14")
    Assert(rows28[1].statusText:GetText():find("15 bags %+ 14 mail") ~= nil, "Status shows split '15 bags + 14 mail' during partial mailbox loot")

    Mock.bagCounts[3858] = 29
    _G.PF.DetailWindow.frame:Trigger("BAG_UPDATE")
    Assert(_G.PF.AHVerifier.GetPurchasedInMailCount(3858) == 0, "Looting remaining 14 Mithril Ore clears in-mail count to 0")
    Assert(rows28[1].buyBtn:GetText() == "Ready" and rows28[1].statusText:GetText():find("Ready: 29 / 29") ~= nil, "Row smoothly transitions from 'Bought' -> 'Ready: 29 / 29' once looted")

    -- Empty mailbox auto-clears stale in-mail entries
    Mock.currentTime = Mock.currentTime + 10
    _G.GetInboxNumItems = function() return 0, 0 end
    _G.PF.AHVerifier.frame:Trigger("MAIL_INBOX_UPDATE")
    Assert(_G.PF.AHVerifier.GetPurchasedInMailCount(5963) == 0, "Empty mailbox on MAIL_INBOX_UPDATE clears remaining in-mail entries")

    -- Restore globals
    _G.PF.AHVerifier.ClearPurchasedTracker()
    Mock.bagCounts[3858] = 0
    Mock.bagCounts[5963] = 0
    Mock.bagCounts[7911] = 0
    Mock.bagCounts[6037] = 0
    Mock.bagCounts[7909] = 0
    _G.C_TradeSkillUI = origCTradeSkillUI
    _G.ProfessionsFrame = origProfFrame
    _G.GetNumTradeSkills = origGetNumTradeSkills
    _G.InCombatLockdown = origInCombat
    _G.C_AuctionHouse = origCAH
    _G.AuctionHouseFrame = origAHFrame
    _G.AuctionFrame = origAuctionFrame
    _G.GetInboxNumItems = origGetInboxNumItems
    _G.ERR_AUCTION_WON_S = origERR_WON
end

-- 29. Regression Test: In-Progress Play Quantity Lock (3x Truesilver Gauntlets Never Shrinks to 2x) & Dynamic Margin-Adjusted Max Unit Price (O(K) Fast Path)
do
    local origPlayerMoney = Mock.playerMoney
    local origCAH = _G.C_AuctionHouse
    local origAHFrame = _G.AuctionHouseFrame
    local origAuctionFrame = _G.AuctionFrame
    local origFindTop = _G.PF.OpportunityEngine.FindTopOpportunities
    local origReeval = _G.PF.OpportunityEngine.ReevaluateSingleOpportunity

    _G.PF.AHVerifier.ClearPurchasedTracker()
    _G.Profitable_DB.orderBookCache = {}
    Mock.playerMoney = 100000 -- 10g starting wallet
    Mock.bagCounts[3858] = 1  -- 1 Mithril Ore already in bags (so 29 needed for 3x = 30 total)
    Mock.bagCounts[7911] = 0
    Mock.bagCounts[7909] = 0
    Mock.bagCounts[3864] = 0
    Mock.bagCounts[5963] = 0
    Mock.bagCounts[7912] = 0

    local solidStoneLivePrice29 = 220 -- Ticked up from 1s 66c -> 2s 20c on volatile AH!
    local startedStoneBuy29 = nil
    local findTopCalls29 = 0
    local reevalCalls29 = 0

    _G.PF.OpportunityEngine.FindTopOpportunities = function(...)
        findTopCalls29 = findTopCalls29 + 1
        return origFindTop(...)
    end
    _G.PF.OpportunityEngine.ReevaluateSingleOpportunity = function(...)
        reevalCalls29 = reevalCalls29 + 1
        return origReeval(...)
    end

    _G.AuctionFrame = nil
    _G.AuctionHouseFrame = _G.CreateFrame("Frame", "AuctionHouseFrame", _G.UIParent)
    _G.AuctionHouseFrame:Show()
    _G.C_AuctionHouse = {
        MakeItemKey = function(id) return { itemID = id, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 } end,
        GetItemKeyInfo = function(key) return { itemID = key.itemID, isCommodity = true } end,
        IsThrottledMessageSystemReady = function() return true end,
        GetNumCommoditySearchResults = function(id) return (id == 7912) and 1 or 0 end,
        GetCommoditySearchResultInfo = function(id, idx)
            if id == 7912 and idx == 1 then
                return { unitPrice = solidStoneLivePrice29, quantity = 60 }
            end
            return nil
        end,
        StartCommoditiesPurchase = function(id, qty)
            startedStoneBuy29 = { itemId = id, quantity = qty }
        end,
        ConfirmCommoditiesPurchase = function() end,
    }

    local gauntlets3x = {
        id = "CRAFT_AH:7938",
        actionType = "CRAFT_AH",
        actionLabel = "Craft and AH",
        itemId = 7938,
        itemName = "Truesilver Gauntlets",
        itemLink = "|cff1eff00|Hitem:7938:0:0:0|h[Truesilver Gauntlets]|h|r",
        quantity = 3,
        unitNetRevenue = 43444,   -- 4g 34s 44c net per craft
        totalNetRevenue = 130332, -- 13g 03s 32c net for 3x!
        totalCost = 88172,        -- ~8g 81s 72c planned
        totalProfit = 42160,      -- ~4g 21s 60c profit
        roiPercent = 48,
        verified = true,
        recipe = {
            recipeId = 9995, name = "Truesilver Gauntlets", profession = "Blacksmithing", professionId = 164,
            outputItemId = 7938, avgMade = 1,
            reagents = {
                { itemId = 3860, name = "Mithril Bar", count = 10 },
                { itemId = 6037, name = "Truesilver Bar", count = 8 },
                { itemId = 7909, name = "Aquamarine", count = 3 },
                { itemId = 3864, name = "Citrine", count = 3 },
                { itemId = 5963, name = "Guardian Gloves", count = 1 },
                { itemId = 7966, name = "Solid Grinding Stone", count = 2 },
            },
        },
        intermediateSteps = {
            {
                recipeId = 10097, recipeName = "Smelt Mithril", profession = "Mining", professionId = 186,
                outputItemId = 3860, outputName = "Mithril Bar", countPerUnit = 10, totalQuantity = 30, avgMade = 1,
                reagents = { { itemId = 3858, name = "Mithril Ore", countPerBatch = 1 } },
            },
            {
                recipeId = 10098, recipeName = "Smelt Truesilver", profession = "Mining", professionId = 186,
                outputItemId = 6037, outputName = "Truesilver Bar", countPerUnit = 8, totalQuantity = 24, avgMade = 1,
                reagents = { { itemId = 7911, name = "Truesilver Ore", countPerBatch = 1 } },
            },
            {
                recipeId = 9920, recipeName = "Solid Grinding Stone", profession = "Blacksmithing", professionId = 164,
                outputItemId = 7966, outputName = "Solid Grinding Stone", countPerUnit = 2, totalQuantity = 6, avgMade = 1,
                reagents = { { itemId = 7912, name = "Solid Stone", countPerBatch = 4 } },
            },
        },
        shoppingList = {
            { itemId = 3858, name = "Mithril Ore",     link = "[Mithril Ore]",     source = "AH", countPerUnit = 10, directQuantity = 0, totalQuantity = 30, avgUnitPrice = 932,  minUnitPrice = 932,  maxUnitPrice = 932,  totalCost = 27960 },
            { itemId = 7911, name = "Truesilver Ore",  link = "[Truesilver Ore]",  source = "AH", countPerUnit = 8,  directQuantity = 0, totalQuantity = 24, avgUnitPrice = 1285, minUnitPrice = 1285, maxUnitPrice = 1285, totalCost = 30840 },
            { itemId = 7909, name = "Aquamarine",      link = "[Aquamarine]",      source = "AH", countPerUnit = 3,  directQuantity = 9, totalQuantity = 9,  avgUnitPrice = 1162, minUnitPrice = 1150, maxUnitPrice = 1173, totalCost = 10465 },
            { itemId = 3864, name = "Citrine",         link = "[Citrine]",         source = "AH", countPerUnit = 3,  directQuantity = 9, totalQuantity = 9,  avgUnitPrice = 1099, minUnitPrice = 1099, maxUnitPrice = 1099, totalCost = 9891  },
            { itemId = 5963, name = "Guardian Gloves", link = "[Guardian Gloves]", source = "AH", countPerUnit = 1,  directQuantity = 3, totalQuantity = 3,  avgUnitPrice = 1988, minUnitPrice = 1988, maxUnitPrice = 1988, totalCost = 5964  },
            { itemId = 7912, name = "Solid Stone",     link = "[Solid Stone]",     source = "AH", countPerUnit = 8,  directQuantity = 0, totalQuantity = 24, avgUnitPrice = 166,  minUnitPrice = 166,  maxUnitPrice = 166,  totalCost = 3984  },
        },
    }

    _G.PF.DetailWindow.ShowOpportunity(gauntlets3x)

    -- Confirm purchases of the first 5 reagents (8g 41s 88c spent -> wallet drops to 1g 58s 12c!)
    _G.PF.AHVerifier.RecordConfirmedPurchase(3858, "Mithril Ore",     29, "EVENT", 27028)
    _G.PF.AHVerifier.RecordConfirmedPurchase(7911, "Truesilver Ore",  24, "EVENT", 30840)
    _G.PF.AHVerifier.RecordConfirmedPurchase(7909, "Aquamarine",       9, "EVENT", 10465)
    _G.PF.AHVerifier.RecordConfirmedPurchase(3864, "Citrine",          9, "EVENT", 9891)
    _G.PF.AHVerifier.RecordConfirmedPurchase(5963, "Guardian Gloves",  3, "EVENT", 5964)
    Mock.playerMoney = 100000 - (27028 + 30840 + 10465 + 9891 + 5964) -- 1g 58s 12c left!

    -- Now open Solid Stone (live price ticked up from 1s 66c -> 2s 20c, and wallet only has 1g 58s left!)
    findTopCalls29 = 0
    reevalCalls29 = 0
    _G.PF.AHVerifier.frame:Trigger("COMMODITY_SEARCH_RESULTS_UPDATED", 7912)

    Assert(findTopCalls29 == 0 and reevalCalls29 == 0, "In-progress revalidation runs in O(K) with ZERO FindTopOpportunities or ReevaluateSingleOpportunity scans")
    Assert(_G.Profitable_DB.activePlay.quantity == 3, "Target quantity stays LOCKED at 3x (never shrinks to 2x because earlier purchases reduced wallet gold)")
    local stoneShop29 = _G.Profitable_DB.activePlay.shoppingList[6]
    Assert(stoneShop29.remainingToBuy == 24, "Solid Stone still requests all 24x needed for 3x Truesilver Gauntlets (not 16x)")
    Assert(stoneShop29.effectiveMaxUnitPrice == 332, "Solid Stone dynamic max unit price expands cleanly to 3s 32c (2x planned, within 4g+ remaining headroom)")
    Assert(_G.Profitable_DB.activePlay._liveUnprofitable == false, "Play remains profitable when Solid Stone ticks up to 2s 20c (within dyn max 3s 32c)")

    -- Find Solid Stone row in DetailWindow and verify Buy 24x works at 2s 20c!
    local stoneRow29 = nil
    for _, r in ipairs(_G.PF.DetailWindow.frame.shoppingRows) do
        if r._itemData and r._itemData.itemId == 7912 then stoneRow29 = r; break end
    end
    Assert(stoneRow29 ~= nil and stoneRow29.buyBtn:GetText() == "Buy 24x", "Solid Stone button shows 'Buy 24x' at live 2s 20c using dynamic max ceiling")
    Assert(stoneRow29.priceText:GetText():find("within dyn max 3s 32c") ~= nil, "Solid Stone row displays 'Live AH: 2s 20c ea (within dyn max 3s 32c)'")
    stoneRow29.buyBtn:Click()
    Assert(startedStoneBuy29 ~= nil and startedStoneBuy29.itemId == 7912 and startedStoneBuy29.quantity == 24, "Clicking 'Buy 24x' reserves all 24x Solid Stone @ 2s 20c")

    -- Verify absurd spike (Solid Stone @ 50s > 3s 32c cap) is STILL rejected and flagged!
    solidStoneLivePrice29 = 5000
    startedStoneBuy29 = nil
    _G.PF.AHVerifier.frame:Trigger("COMMODITY_SEARCH_RESULTS_UPDATED", 7912)
    Assert(_G.Profitable_DB.activePlay._liveUnprofitable == true, "Absurd 50s Solid Stone spike exceeds 3s 32c volatility cap and flags play")
    Assert(stoneRow29.priceText:GetText():find("above max 3s 32c") ~= nil, "Solid Stone row warns 'above max 3s 32c' when spiked to 50s")

    -- Restore globals
    _G.PF.AHVerifier.ClearPurchasedTracker()
    Mock.playerMoney = origPlayerMoney
    Mock.bagCounts[3858] = 0
    _G.C_AuctionHouse = origCAH
    _G.AuctionHouseFrame = origAHFrame
    _G.AuctionFrame = origAuctionFrame
    _G.PF.OpportunityEngine.FindTopOpportunities = origFindTop
    _G.PF.OpportunityEngine.ReevaluateSingleOpportunity = origReeval
end

-- 30. Customizable Spending Budget Cap Tests (Defaults to Player Gold, Settings UI, Slash Command, Engine Enforcement)
do
    local origPlayerMoney = Mock.playerMoney
    local origPrices = _G.PCF_DB.prices
    local origOrderBooks = _G.Profitable_DB.orderBookCache
    local origItemCache2447 = _G.Profitable_DB.itemCache[2447]

    -- 30A. ParseGoldToCopper handles plain gold numbers, g/s/c formats, auto/reset, and rejects invalid text
    Assert(_G.PF.ParseGoldToCopper("10") == 100000, "ParseGoldToCopper('10') parses plain gold as 10g (100000c)")
    Assert(_G.PF.ParseGoldToCopper("10.5") == 105000, "ParseGoldToCopper('10.5') parses decimal gold as 10g 50s")
    Assert(_G.PF.ParseGoldToCopper("10g 50s") == 105000, "ParseGoldToCopper('10g 50s') parses mixed gold+silver")
    Assert(_G.PF.ParseGoldToCopper("2g 5s 25c") == 20525, "ParseGoldToCopper('2g 5s 25c') parses full g/s/c")
    Assert(_G.PF.ParseGoldToCopper("50s") == 5000, "ParseGoldToCopper('50s') parses silver-only input")
    Assert(_G.PF.ParseGoldToCopper("auto") == 0 and _G.PF.ParseGoldToCopper("") == 0 and _G.PF.ParseGoldToCopper("0") == 0, "ParseGoldToCopper('auto' / '' / '0') returns 0 (All Gold)")
    Assert(_G.PF.ParseGoldToCopper("notgold") == nil, "ParseGoldToCopper rejects invalid text cleanly")

    -- 30B. GetEffectiveBudget defaults to full player gold (50g), caps to 10g when configured, and never exceeds actual wallet
    Mock.playerMoney = 500000 -- 50g in wallet
    _G.Profitable_DB.settings.customBudgetCopper = 0
    local eff0, capped0, wallet0 = _G.PF.GetEffectiveBudget()
    Assert(eff0 == 500000 and capped0 == false and wallet0 == 500000, "Default budget uses full player gold (50g, uncapped)")

    -- Configure a 10g cap via Settings Window input box + Apply button
    _G.PF.SideWindow.ToggleSettingsWindow()
    local sf30 = _G.PF.SideWindow.settingsFrame
    Assert(sf30 ~= nil and sf30.budgetInput ~= nil and sf30.budgetApplyBtn ~= nil and sf30.budgetAutoBtn ~= nil, "Settings window creates budget input, Apply, and Use All Gold controls")

    -- Populate Peacebloom vendor flip costing 1g each (up to 40 available -> would spend 40g uncapped, must cap at 10g = 10 units!)
    local now30 = math.floor(Mock.currentTime)
    _G.Profitable_DB.itemCache[2447] = { name = "Peacebloom", quality = 1, itemLevel = 1, classID = 7, vendorSell = 15000 } -- 1g 50s vendor
    _G.PCF_DB.prices = {
        [2447] = { minBuyout = 10000, count = 40, lastUpdated = now30, source = "Scan" }, -- 1g each x 40 available
    }
    _G.PCF_DB.lastFullScan = now30
    _G.Profitable_DB.orderBookCache = {}

    sf30.budgetInput:SetText("10g")
    sf30.budgetApplyBtn:Click()
    local eff10, capped10, _, capVal10 = _G.PF.GetEffectiveBudget()
    Assert(eff10 == 100000 and capped10 == true and capVal10 == 100000, "Applying '10g' in Settings caps effective budget at 10g out of 50g wallet")
    Assert(_G.PF.SideWindow.frame.infoText:GetText():find("10g %(Cap%)") ~= nil, "SideWindow header displays '10g (Cap)' when custom budget cap is active")
    Assert(sf30.budgetTitleText:GetText():find("10g Cap") ~= nil and sf30.budgetTitleText:GetText():find("Wallet: 50g") ~= nil, "Settings card shows '10g Cap (Wallet: 50g)'")

    local playsAt10g = _G.PF.OpportunityEngine.FindTopOpportunities()
    Assert(#playsAt10g == 1 and playsAt10g[1].itemId == 2447 and playsAt10g[1].quantity == 10 and playsAt10g[1].totalCost == 100000, "FindTopOpportunities caps spending at 10g (10x @ 1g) even when player has 50g")

    -- Explicit budgetOverride still works independently of customBudgetCopper
    local playsOverride = _G.PF.OpportunityEngine.FindTopOpportunities(250000)
    Assert(#playsOverride == 1 and playsOverride[1].quantity == 25 and playsOverride[1].totalCost == 250000, "Explicit budgetOverride (25g) still takes precedence over custom cap")

    -- If player's actual wallet drops below custom cap (e.g. 6g < 10g cap), effective budget respects real wallet (6g)
    Mock.playerMoney = 60000 -- 6g
    local effLow, cappedLow = _G.PF.GetEffectiveBudget()
    Assert(effLow == 60000 and cappedLow == true, "Effective budget never exceeds actual player wallet (6g < 10g cap)")
    local playsAt6g = _G.PF.OpportunityEngine.FindTopOpportunities()
    Assert(#playsAt6g == 1 and playsAt6g[1].quantity == 6 and playsAt6g[1].totalCost == 60000, "FindTopOpportunities caps at actual 6g wallet when wallet < 10g cap")

    -- Slash command '/pf budget 15' updates cap cleanly; '/pf budget auto' resets to All Gold (50g)
    Mock.playerMoney = 500000
    SlashCmdList["PROFITABLE"]("budget 15")
    Assert(_G.Profitable_DB.settings.customBudgetCopper == 150000, "'/pf budget 15' sets 15g budget cap")
    local playsAt15g = _G.PF.OpportunityEngine.FindTopOpportunities()
    Assert(#playsAt15g == 1 and playsAt15g[1].quantity == 15, "FindTopOpportunities updates to 15x after '/pf budget 15'")

    -- Clicking 'Use All Gold' resets customBudgetCopper to 0 and unlocks full 40g play within 50g wallet
    sf30.budgetAutoBtn:Click()
    Assert(_G.Profitable_DB.settings.customBudgetCopper == 0 and sf30.budgetInput:GetText() == "", "Clicking 'Use All Gold' clears custom budget cap")
    local playsUncapped = _G.PF.OpportunityEngine.FindTopOpportunities()
    Assert(#playsUncapped == 1 and playsUncapped[1].quantity == 40 and playsUncapped[1].totalCost == 400000, "Uncapped FindTopOpportunities uses full 50g wallet (40x @ 1g = 40g)")

    -- Reset Filter Defaults also clears customBudgetCopper
    SlashCmdList["PROFITABLE"]("budget 12g 50s")
    Assert(_G.Profitable_DB.settings.customBudgetCopper == 125000, "'/pf budget 12g 50s' sets 12g 50s budget cap")
    _G["PF_SettingsResetButton"]:Click()
    Assert(_G.Profitable_DB.settings.customBudgetCopper == 0, "'Reset Filter Defaults' also resets customBudgetCopper to 0 (All Gold)")

    -- Restore globals
    sf30:Hide()
    Mock.playerMoney = origPlayerMoney
    _G.PCF_DB.prices = origPrices
    _G.Profitable_DB.orderBookCache = origOrderBooks
    _G.Profitable_DB.itemCache[2447] = origItemCache2447
end

-- 31. Regression Tests: RecipeDatabase Item ID & Reagent Accuracy, Baseline Integrity Guard,
--     Modern Scanner Required-Reagent Validation & Stale Baseline Play Invalidation
do
    local origDB31 = _G.Profitable_DB
    local origPrices31 = _G.PCF_DB.prices
    local origSkillLines31 = Mock.skillLines
    local origTradeSkills31 = Mock.tradeSkills
    local origGetNumTradeSkills31 = _G.GetNumTradeSkills
    local origCTSU31 = _G.C_TradeSkillUI
    local origEnum31 = _G.Enum
    local origTimers31 = Mock.timers

    -- 31A. Audit every single baseline recipe: unique outputItemId, valid reagents, and seed metadata name match
    local baseline = _G.PF.RecipeDatabase.GetAllBaselineRecipes()
    local byOutput = {}
    local seenIds = {}
    local savedItemCache = _G.Profitable_DB.itemCache
    _G.Profitable_DB.itemCache = {} -- Force seed metadata check cleanly without earlier test mocks
    for _, rec in ipairs(baseline) do
        Assert(type(rec.outputItemId) == "number" and rec.outputItemId > 0, "Baseline recipe has valid outputItemId: " .. tostring(rec.name))
        Assert(not seenIds[rec.outputItemId], "Baseline recipe outputItemId is unique: " .. tostring(rec.outputItemId))
        seenIds[rec.outputItemId] = true
        byOutput[rec.outputItemId] = rec
        Assert(type(rec.reagents) == "table" and #rec.reagents > 0, "Baseline recipe has non-empty reagents: " .. tostring(rec.name))
        for _, rg in ipairs(rec.reagents) do
            Assert(type(rg.itemId) == "number" and rg.itemId > 0 and type(rg.count) == "number" and rg.count > 0,
                "Baseline reagent has valid itemId/count for " .. tostring(rec.name))
        end
        local meta = _G.PF.VendorDatabase.GetItemMetadata(rec.outputItemId, nil, true)
        local expectedName = rec.outputName or rec.name
        Assert(meta ~= nil and meta.name == expectedName,
            string.format("Baseline [%d] name matches VendorDatabase seed ('%s' == '%s')", rec.outputItemId, tostring(meta and meta.name), tostring(expectedName)))
    end
    _G.Profitable_DB.itemCache = savedItemCache

    local function ReagentCount(rec, itemId)
        for _, rg in ipairs((rec and rec.reagents) or {}) do
            if rg.itemId == itemId then return rg.count end
        end
        return 0
    end

    -- Verify Turtle Scale Helm (8191), Turtle Scale Breastplate (8189), Nightscape Tunic (8175), Nightscape Headband (8176)
    Assert(byOutput[8191] and byOutput[8191].name == "Turtle Scale Helm"
        and ReagentCount(byOutput[8191], 4304) == 14
        and ReagentCount(byOutput[8191], 8167) == 24
        and ReagentCount(byOutput[8191], 8343) == 1,
        "Turtle Scale Helm (8191) requires 14x Thick Leather, 24x Turtle Scale, 1x Heavy Silken Thread")
    Assert(byOutput[8189] and byOutput[8189].name == "Turtle Scale Breastplate"
        and ReagentCount(byOutput[8189], 4304) == 6
        and ReagentCount(byOutput[8189], 8167) == 12
        and ReagentCount(byOutput[8189], 8343) == 1,
        "Turtle Scale Breastplate (8189) requires 6x Thick Leather, 12x Turtle Scale, 1x Heavy Silken Thread")
    Assert(byOutput[8175] and byOutput[8175].name == "Nightscape Tunic"
        and ReagentCount(byOutput[8175], 4304) == 7
        and ReagentCount(byOutput[8175], 4291) == 2,
        "Nightscape Tunic uses correct itemId 8175 (never Turtle Scale Breastplate 8189)")
    Assert(byOutput[8176] and byOutput[8176].name == "Nightscape Headband"
        and ReagentCount(byOutput[8176], 4304) == 5
        and ReagentCount(byOutput[8176], 4291) == 2,
        "Nightscape Headband uses correct itemId 8176 (never Turtle Scale Helm 8191)")

    -- Verify other previously broken baseline recipes
    Assert(byOutput[4255] and ReagentCount(byOutput[4255], 4234) == 9 and ReagentCount(byOutput[4255], 2319) == 0,
        "Green Leather Armor (4255) requires 9x Heavy Leather (not Medium Leather)")
    Assert(byOutput[4252] and ReagentCount(byOutput[4252], 3390) == 1,
        "Dark Leather Shoulders (4252) includes 1x Elixir of Lesser Agility")
    Assert(byOutput[7387] and ReagentCount(byOutput[7387], 7071) == 1 and ReagentCount(byOutput[7387], 3575) == 0,
        "Dusky Belt (7387) requires 1x Iron Buckle (not Iron Bar)")
    Assert(byOutput[7059] and byOutput[7059].name == "Crimson Silk Shoulders" and ReagentCount(byOutput[7059], 6371) == 2,
        "Crimson Silk Shoulders uses 7059 and includes 2x Fire Oil")
    Assert(byOutput[13864] and ReagentCount(byOutput[13864], 14227) == 2 and ReagentCount(byOutput[13864], 8170) == 4 and ReagentCount(byOutput[13864], 3575) == 0,
        "Runecloth Boots (13864) requires Ironweb Spider Silk + Rugged Leather (not Iron Bar / Thick Leather)")
    Assert(byOutput[13866] and ReagentCount(byOutput[13866], 14227) == 2 and ReagentCount(byOutput[13866], 3575) == 0,
        "Runecloth Headband (13866) requires 2x Ironweb Spider Silk (not Iron Bar)")
    Assert(byOutput[5541] and byOutput[5541].name == "Iridescent Hammer"
        and ReagentCount(byOutput[5541], 3466) == 1 and ReagentCount(byOutput[5541], 3478) == 2 and ReagentCount(byOutput[5541], 2319) == 2,
        "Iridescent Hammer uses 5541 and includes Strong Flux, Coarse Grinding Stone, and Medium Leather")
    Assert(byOutput[7918] and byOutput[7918].name == "Heavy Mithril Shoulder"
        and byOutput[7919] and byOutput[7919].name == "Heavy Mithril Gauntlet" and ReagentCount(byOutput[7919], 4338) == 4
        and byOutput[7921] and byOutput[7921].name == "Heavy Mithril Pants" and ReagentCount(byOutput[7921], 3466) == 0,
        "Heavy Mithril Shoulder (7918), Gauntlet (7919 with Mageweave Cloth), and Pants (7921) use exact IDs and reagents")
    Assert(byOutput[4324] and ReagentCount(byOutput[4324], 6260) == 4 and ReagentCount(byOutput[4324], 2321) == 0,
        "Azure Silk Vest (4324) requires 5x Bolt of Silk Cloth and 4x Blue Dye")
    Assert(byOutput[11288] and ReagentCount(byOutput[11288], 10938) == 2,
        "Greater Magic Wand (11288) matches WoW: Forever 2x Lesser Magic Essence")
    Assert(byOutput[217287] and byOutput[217287].name == "Greater Mystic Wand" and ReagentCount(byOutput[217287], 11134) == 1 and ReagentCount(byOutput[217287], 11137) == 1,
        "Greater Mystic Wand uses WoW: Forever itemId 217287 with Star Wood, Lesser Mystic Essence, Vision Dust")

    -- 31B. Pricing Turtle Scale Helm (8191) accounts for all 24x Turtle Scale (never fake 352% ROI)
    local now31 = math.floor(Mock.currentTime)
    _G.Profitable_DB = _G.PF.LoadConfig({})
    _G.Profitable_DB.settings.assumeCanDisenchant = false
    _G.Profitable_DB.settings.showVendorPlays = false
    _G.Profitable_DB.settings.showCraftPlays = true
    _G.PCF_DB.lastFullScan = now31
    _G.PCF_DB.prices = {
        [4304] = { minBuyout = 525,   count = 100, lastUpdated = now31, source = "Scan" }, -- Thick Leather 5s 25c
        [8167] = { minBuyout = 3828,  count = 100, lastUpdated = now31, source = "Scan" }, -- Turtle Scale 38s 28c (24x = 91s 87c!)
        [8343] = { minBuyout = 2000,  count = 50,  lastUpdated = now31, source = "Scan" }, -- Heavy Silken Thread 20s
        [8191] = { minBuyout = 18098, count = 5,   lastUpdated = now31, source = "Scan" }, -- Turtle Scale Helm 1g 80s 98c
    }
    -- Cost per craft: 14*525 (7350) + 24*3828 (91872) + 1*2000 (2000) = 101222c (~10g? wait: 38s 28c = 3828 -> 24x = 9g 18s 72c, far above 1g 80s 98c -> unprofitable!)
    -- Also verify exact cost when Turtle Scale is 3s 83c (383c): 14*525 (7350) + 24*383 (9192) + 2000 = 18542c (1g 85s 42c) > 1g 80s 98c AH -> unprofitable, just like screenshot!
    _G.PCF_DB.prices[8167].minBuyout = 383
    Mock.tradeSkills = {}
    Mock.skillLines = { { name = "Leatherworking", isHeader = false, rank = 250, maxRank = 300 } }
    local lwPlays = _G.PF.OpportunityEngine.FindTopOpportunities(500000)
    local foundTurtleHelm = false
    for _, opp in ipairs(lwPlays) do
        if opp.itemId == 8191 then foundTurtleHelm = true end
    end
    Assert(foundTurtleHelm == false, "Turtle Scale Helm (8191) is NOT falsely recommended when 24x Turtle Scale pushes craft cost (1g 85s 42c) above AH value (1g 80s 98c)")

    -- Lower Turtle Scale to 1s (100c) -> cost = 14*525 (7350) + 24*100 (2400) + 2000 = 11750c (1g 17s 50c) -> profitable and shopping list MUST include 24x Turtle Scale per craft!
    _G.PCF_DB.prices[8167].minBuyout = 100
    local lwPlaysProfitable = _G.PF.OpportunityEngine.FindTopOpportunities(500000)
    local turtleOpp = nil
    for _, opp in ipairs(lwPlaysProfitable) do
        if opp.itemId == 8191 then turtleOpp = opp end
    end
    Assert(turtleOpp ~= nil and turtleOpp.quantity == 3, "Turtle Scale Helm becomes profitable when Turtle Scale drops to 1s")
    local hasTurtleScalesInList = false
    for _, shop in ipairs((turtleOpp and turtleOpp.shoppingList) or {}) do
        if shop.itemId == 8167 and shop.countPerUnit == 24 and shop.totalQuantity == 72 then
            hasTurtleScalesInList = true
        end
    end
    Assert(hasTurtleScalesInList == true, "Turtle Scale Helm shopping list includes all 24x Turtle Scale per craft (72x for 3x)")

    -- 31C. Baseline Output-Item Name Integrity Guard rejects mismatched live itemCache names
    _G.Profitable_DB.itemCache[8191] = { name = "Completely Different Item", quality = 2, itemLevel = 46, classID = 4, invType = "INVTYPE_HEAD", vendorSell = 7780 }
    local knownWithMismatch = _G.PF.RecipeScanner.GetKnownRecipes()
    local emittedMismatched8191 = false
    for _, rec in ipairs(knownWithMismatch) do
        if rec.outputItemId == 8191 then emittedMismatched8191 = true end
    end
    Assert(emittedMismatched8191 == false, "Baseline integrity guard rejects baseline recipe when live itemCache name mismatches expected output item")
    _G.Profitable_DB.itemCache[8191] = nil

    -- 31D. Modern ScanModernTradeSkillUI: skips optional slots, rejects incomplete required slots, merges duplicate reagents, and invalidates stale baseline plays
    _G.GetNumTradeSkills = function() return 0 end
    _G.Enum = { CraftingReagentType = { Modifying = 0, Basic = 1, Finishing = 2, Automatic = 3 } }
    local tradeSkillReady31 = false
    _G.C_TradeSkillUI = {
        IsTradeSkillReady = function() return tradeSkillReady31 end,
        GetBaseProfessionInfo = function() return { parentProfessionID = 165, parentProfessionName = "Leatherworking" } end,
        GetProfessionInfoByRecipeID = function() return { parentProfessionID = 165, parentProfessionName = "Leatherworking" } end,
        GetAllRecipeIDs = function() return { 10630, 999001 } end,
        GetRecipeInfo = function(id)
            if id == 10630 then return { recipeID = 10630, name = "Turtle Scale Helm", learned = true, itemID = 8191 } end
            if id == 999001 then return { recipeID = 999001, name = "Broken Missing Reagent Helm", learned = true, itemID = 999002 } end
            return nil
        end,
        GetRecipeSchematic = function(id)
            if id == 10630 then
                return {
                    outputItemID = 8191,
                    quantityMin = 1,
                    quantityMax = 1,
                    reagentSlotSchematics = {
                        { required = true,  reagentType = 1, quantityRequired = 10, reagents = { { itemID = 4304 } } }, -- Thick Leather part 1
                        { required = true,  reagentType = 1, quantityRequired = 4,  reagents = { { itemID = 4304 } } }, -- Thick Leather part 2 (merged -> 14)
                        { required = true,  reagentType = 1, quantityRequired = 24, reagents = { { itemID = 8167 } } }, -- Turtle Scale
                        { required = true,  reagentType = 1, quantityRequired = 1,  reagents = { { itemID = 8343 } } }, -- Heavy Silken Thread
                        { required = false, reagentType = 2, quantityRequired = 1,  reagents = { { itemID = 2325 } } }, -- Optional finishing slot -> MUST be ignored
                    },
                }
            elseif id == 999001 then
                return {
                    outputItemID = 999002,
                    quantityMin = 1,
                    quantityMax = 1,
                    reagentSlotSchematics = {
                        { required = true, reagentType = 1, quantityRequired = 5, reagents = { { itemID = 4304 } } },
                        { required = true, reagentType = 1, quantityRequired = 24, reagents = {} }, -- Unresolved required reagent -> MUST reject whole recipe!
                    },
                }
            end
            return nil
        end,
    }

    -- Seed a stale baseline play for 8191 with wrong reagents (old 5x Thick Leather, 2x Silken Thread)
    local staleTurtleOpp = {
        id = "CRAFT_AH:8191",
        itemId = 8191,
        recipe = {
            name = "Nightscape Headband",
            outputItemId = 8191,
            isTrainerRecommendation = true,
            reagents = { { itemId = 4304, count = 5 }, { itemId = 4291, count = 2 } },
        },
    }
    _G.Profitable_DB.lastTopPlays = { staleTurtleOpp }
    _G.Profitable_DB.activePlay = staleTurtleOpp

    -- Fire TRADE_SKILL_SHOW while IsTradeSkillReady() == false -> schedules deferred retry timer
    Mock.timers = {}
    _G.PF.RecipeScanner.frame:Trigger("TRADE_SKILL_SHOW")
    Assert(#Mock.timers == 1, "TRADE_SKILL_SHOW schedules deferred scan retry when C_TradeSkillUI is not ready yet")

    -- Profession finishes loading before timer fires -> retry scans Turtle Scale Helm and rejects broken recipe
    tradeSkillReady31 = true
    Mock.FlushTimers(10)
    local charTbl31 = _G.Profitable_DB.charRecipes[_G.PF.GetCharacterKey()]
    local scannedTurtle = charTbl31 and charTbl31["10630:Turtle Scale Helm"]
    local scannedBroken = charTbl31 and charTbl31["999001:Broken Missing Reagent Helm"]
    Assert(scannedTurtle ~= nil, "Deferred retry successfully scans Turtle Scale Helm once C_TradeSkillUI becomes ready")
    Assert(scannedBroken == nil, "ScanModernTradeSkillUI refuses to save incomplete recipe with unresolved required reagent")
    Assert(#scannedTurtle.reagents == 3
        and ReagentCount(scannedTurtle, 4304) == 14
        and ReagentCount(scannedTurtle, 8167) == 24
        and ReagentCount(scannedTurtle, 8343) == 1
        and ReagentCount(scannedTurtle, 2325) == 0,
        "ScanModernTradeSkillUI merges duplicate reagents (14x Thick Leather), captures 24x Turtle Scale + 1x Heavy Silken Thread, and skips optional finishing slot")
    Assert(#_G.Profitable_DB.lastTopPlays == 0 and _G.Profitable_DB.activePlay == nil,
        "Scanning real Turtle Scale Helm invalidates stale baseline play with mismatched reagents")

    -- 31E. Config v3 -> v4 migration flushes cached plays while preserving charRecipes and settings
    local legacyV3DB = {
        version = 3,
        settings = { customBudgetCopper = 50000 },
        charRecipes = { ["Tester-Forever"] = { ["10630:Turtle Scale Helm"] = scannedTurtle } },
        lastTopPlays = { staleTurtleOpp },
        lastHonorableMentions = { staleTurtleOpp },
        activePlay = staleTurtleOpp,
    }
    _G.PF.LoadConfig(legacyV3DB)
    Assert(legacyV3DB.version == 4, "v3 -> v4 migration upgrades config version to 4")
    Assert(#legacyV3DB.lastTopPlays == 0 and #legacyV3DB.lastHonorableMentions == 0 and legacyV3DB.activePlay == nil,
        "v3 -> v4 migration flushes stale cached plays")
    Assert(legacyV3DB.settings.customBudgetCopper == 50000 and legacyV3DB.charRecipes["Tester-Forever"]["10630:Turtle Scale Helm"] ~= nil,
        "v3 -> v4 migration preserves user settings and scanned charRecipes")

    -- Restore globals
    Mock.timers = origTimers31
    _G.Enum = origEnum31
    _G.C_TradeSkillUI = origCTSU31
    _G.GetNumTradeSkills = origGetNumTradeSkills31
    Mock.tradeSkills = origTradeSkills31
    Mock.skillLines = origSkillLines31
    _G.PCF_DB.prices = origPrices31
    _G.Profitable_DB = origDB31
    _G.PF.LoadConfig(origDB31)
end

-- =============================================================================
-- 32. User Feedback Features: Auctionator Source, Auto-Open Toggle, AH & Minimap
--     Buttons (OneForAll/LibDBIcon-compatible), Manual 24h/Perm Snooze, and
--     12h Auto-Snooze on Craft
-- =============================================================================
do
    local origDB32 = _G.Profitable_DB
    local origPCF32 = _G.PCF_DB
    local origAtr32 = _G.Auctionator
    local origAtrDB32 = _G.AUCTIONATOR_PRICE_DATABASE
    local origTime32 = Mock.currentTime
    local origShift32 = _G.IsShiftKeyDown
    local origPCFBtn32 = _G.PCF_AuctionScanButton

    local db32 = {
        version = 4,
        settings = {
            onboardingDismissed = true,
            includeSkillMatchedBaselineRecipes = false,
            includeTrainerRecommendations = false,
            assumeCanDisenchant = false,
            showCraftPlays = true,
            showVendorPlays = true,
            showSideWindow = true,
            autoSnoozeOnCraft = true,
            priceSource = "AUTO",
            minimap = { hide = false, minimapPos = 220 },
        },
        charRecipes = {
            [PF.GetCharacterKey()] = {
                ["CraftTest:7966"] = {
                    name = "Solid Grinding Stone",
                    profession = "Blacksmithing",
                    recipeId = 9920,
                    outputItemId = 7966,
                    avgMade = 1,
                    reagents = { { itemId = 7912, name = "Solid Stone", count = 4 } },
                },
                ["CraftTest:2852"] = {
                    name = "Copper Chain Pants",
                    profession = "Blacksmithing",
                    recipeId = 2663,
                    outputItemId = 2852,
                    avgMade = 1,
                    reagents = { { itemId = 2840, name = "Copper Bar", count = 4 } },
                },
            },
        },
        itemCache = {
            [2447] = { name = "Peacebloom", quality = 1, itemLevel = 1, classID = 7, vendorSell = 15000 },
            [2852] = { name = "Copper Chain Pants", quality = 2, itemLevel = 10, classID = 4, invType = "INVTYPE_LEGS", vendorSell = 14000 },
            [7966] = { name = "Solid Grinding Stone", quality = 1, itemLevel = 30, classID = 7, vendorSell = 100 },
            [7912] = { name = "Solid Stone", quality = 1, itemLevel = 30, classID = 7, vendorSell = 50 },
            [2840] = { name = "Copper Bar", quality = 1, itemLevel = 5, classID = 7, vendorSell = 10 },
        },
        orderBookCache = {},
        snoozedPlays = {},
        lastTopPlays = {},
        lastHonorableMentions = {},
    }
    PF.LoadConfig(db32)

    -- 32A. Auctionator-Only Data Source (empty PCF_DB!)
    _G.PCF_DB = { prices = {}, lastFullScan = 0, settings = { showScanButton = true } }
    local statusNoData = PF.GetAHDataStatus()
    Assert(statusNoData == "NO_DATA", "Empty PCF_DB and no Auctionator reports NO_DATA")

    local atrDBUpdateCallback = nil
    local atrRealmTable = {
        ["2447"] = { m = 10000, a = { ["100"] = 20 } }, -- Peacebloom 1g -> vendor 1g50s (+10g profit!)
        ["7912"] = { m = 1000,  a = { ["100"] = 80 } }, -- Solid Stone 10s (4x = 40s per craft)
        ["7966"] = { m = 9000,  a = { ["100"] = 20 } }, -- Solid Grinding Stone 90s on AH (net 85.5s -> +45.5s * 20 = +9g10s)
        ["2840"] = { m = 1500,  a = { ["100"] = 80 } }, -- Copper Bar 15s (4x = 60s per craft) -> Pants vendor 1g40s (+80s * 20 = +16g)
        ["p:123"] = { m = 500,  a = { ["100"] = 1 } },  -- Battle pet entry must be skipped safely
    }
    _G.AUCTIONATOR_PRICE_DATABASE = {
        __dbversion = 7,
        ["Forever Alliance"] = atrRealmTable,
    }
    _G.Auctionator = {
        SavedState = { TimeOfLastFullScan = math.floor(Mock.currentTime) - 120 },
        Database = { db = atrRealmTable },
        API = {
            v1 = {
                GetAuctionPriceByItemID = function(_, id)
                    local row = atrRealmTable[tostring(id)]
                    return row and row.m or nil
                end,
                GetAuctionAgeByItemID = function(_, id)
                    return atrRealmTable[tostring(id)] and 0 or nil
                end,
                RegisterForDBUpdate = function(_, cb)
                    atrDBUpdateCallback = cb
                end,
            },
        },
    }
    PF.AuctionatorSource.Init()
    Assert(type(atrDBUpdateCallback) == "function", "AuctionatorSource registers for Auctionator.API.v1.RegisterForDBUpdate")

    local atrStatus, atrInfo = PF.GetAHDataStatus()
    Assert(atrStatus == "FRESH" and atrInfo.activeSource == "Auctionator" and atrInfo.auctionatorItems == 4,
        "GetAHDataStatus detects FRESH Auctionator data (4 items, skipping battle pets) even when PCF_DB is empty")

    local atrPlays = PF.OpportunityEngine.FindTopOpportunities(220000)
    Assert(#atrPlays == 3, "OpportunityEngine discovers all 3 plays purely from Auctionator scan data")
    Assert(atrPlays[1].itemId == 2852 and atrPlays[2].itemId == 2447 and atrPlays[3].itemId == 7966,
        "Auctionator-sourced plays rank accurately by profit (Copper Chain Pants > Peacebloom > Solid Grinding Stone)")

    -- AUTO mode picks whichever source has the fresher timestamp
    _G.PCF_DB.prices[2447] = { minBuyout = 12000, count = 20, lastUpdated = math.floor(Mock.currentTime) - 600 }
    local autoPriceOlderPCF, _, autoSrc1 = PF.OpportunityEngine.ResolveAHPrice(2447)
    Assert(autoPriceOlderPCF == 10000 and autoSrc1 == "Auctionator",
        "AUTO mode prefers Auctionator when Auctionator scan is fresher than PCF_DB")

    _G.PCF_DB.prices[2447].lastUpdated = math.floor(Mock.currentTime) - 10
    local autoPriceNewerPCF, _, autoSrc2 = PF.OpportunityEngine.ResolveAHPrice(2447)
    Assert(autoPriceNewerPCF == 12000 and autoSrc2 ~= "Auctionator",
        "AUTO mode prefers PCF_DB when PCF scan is fresher than Auctionator")

    -- Explicit AUCTIONATOR mode ignores PCF_DB and auto-hides PCF Scan button (unless userSetScanButton)
    PF.SideWindow.SetPriceSource("auctionator", true)
    Assert(PF.GetPriceSourceMode() == "AUCTIONATOR", "SetPriceSource switches mode to AUCTIONATOR")
    local atrOnlyPrice, _, atrOnlySrc = PF.OpportunityEngine.ResolveAHPrice(2447)
    Assert(atrOnlyPrice == 10000 and atrOnlySrc == "Auctionator",
        "AUCTIONATOR mode strictly uses Auctionator even when PCF_DB has a newer entry")
    Assert(_G.PCF_DB.settings.showScanButton == false,
        "AUCTIONATOR mode hides embedded PCF Scan button when user has not explicitly pinned it")

    -- Explicit PCF mode ignores Auctionator
    PF.SideWindow.SetPriceSource("pcf", true)
    Assert(PF.GetPriceSourceMode() == "PCF" and _G.PCF_DB.settings.showScanButton == true,
        "PCF mode switches back and restores PCF Scan button")
    local pcfOnlyPrice = PF.OpportunityEngine.ResolveAHPrice(7966)
    Assert(pcfOnlyPrice == nil, "PCF mode ignores Auctionator-only items")

    -- Switch back to AUTO and clear PCF_DB for clean snooze tests
    PF.SideWindow.SetPriceSource("auto", true)
    _G.PCF_DB.prices = {}

    -- 32B. Auto-Open Side Window Toggle + AH Frame Toggle Button + Minimap Button (OneForAll/LibDBIcon compatible)
    PF.SideWindow.frame:Hide()
    Profitable_DB.settings.showSideWindow = false
    local activeAHParent32 = (_G.AuctionHouseFrame and _G.AuctionHouseFrame:IsShown()) and _G.AuctionHouseFrame or _G.AuctionFrame
    _G.PCF_AuctionScanButton = CreateFrame("Button", "PCF_AuctionScanButton", activeAHParent32)
    _G.PCF_AuctionScanButton:Show()

    PF.SideWindow.eventFrame:Trigger("AUCTION_HOUSE_SHOW")
    Mock.FlushTimers(10)
    Assert(not PF.SideWindow.frame:IsShown(), "SideWindow stays hidden on AUCTION_HOUSE_SHOW when showSideWindow == false")
    Assert(PF.SideWindow.ahToggleButton ~= nil and PF.SideWindow.ahToggleButton:IsShown(),
        "Profitable AH toggle button is shown on AuctionFrame even when auto-open is disabled")
    Assert(PF.SideWindow.ahToggleButton.points and PF.SideWindow.ahToggleButton.points[1]
        and PF.SideWindow.ahToggleButton.points[1][2] == _G.PCF_AuctionScanButton,
        "AH toggle button anchors cleanly to the left of PCF_AuctionScanButton when visible")

    -- Clicking AH toggle button opens SideWindow; clicking again hides it
    PF.SideWindow.ahToggleButton:Click("LeftButton")
    Assert(PF.SideWindow.frame:IsShown(), "Clicking AH toggle button opens Profitable SideWindow")
    PF.SideWindow.ahToggleButton:Click("LeftButton")
    Assert(not PF.SideWindow.frame:IsShown(), "Clicking AH toggle button again closes Profitable SideWindow")

    -- When PCF_AuctionScanButton is hidden, AH toggle button anchors to active AH frame TOPRIGHT
    _G.PCF_AuctionScanButton:Hide()
    PF.SideWindow.UpdateAHToggleButtonAnchor()
    Assert(PF.SideWindow.ahToggleButton.points and PF.SideWindow.ahToggleButton.points[1]
        and PF.SideWindow.ahToggleButton.points[1][2] == activeAHParent32,
        "AH toggle button anchors cleanly to AH frame TOPRIGHT when PCF Scan button is hidden")

    -- Minimap button uses LibDBIcon10_Profitable naming + Minimap parent + dataObject for OneForAll/MBB/HidingBar
    local mmBtn = _G["LibDBIcon10_Profitable"]
    Assert(mmBtn ~= nil and mmBtn == PF.SideWindow.minimapButton, "Minimap button created with LibDBIcon10_Profitable name")
    Assert(mmBtn:GetParent() == _G.Minimap and mmBtn.width == 31 and mmBtn.height == 31,
        "Minimap button is parented to Minimap with standard 31x31 LibDBIcon dimensions")
    Assert(mmBtn.icon ~= nil and mmBtn.overlay ~= nil and mmBtn.dataObject ~= nil and mmBtn.dataObject.type == "launcher",
        "Minimap button exposes standard LibDBIcon icon/overlay/dataObject fields for collector addons like OneForAll")
    Assert(mmBtn:IsShown(), "Minimap button is shown by default")

    mmBtn:Click("LeftButton")
    Assert(PF.SideWindow.frame:IsShown(), "Left-clicking Minimap button opens Profitable SideWindow")
    PF.SideWindow.SetMinimapButtonShown(false)
    Assert(not mmBtn:IsShown() and Profitable_DB.settings.minimap.hide == true,
        "SetMinimapButtonShown(false) hides Minimap button and persists LibDBIcon minimap.hide = true")
    SlashCmdList["PROFITABLE"]("minimap")
    Assert(mmBtn:IsShown() and Profitable_DB.settings.minimap.hide == false,
        "/pf minimap toggles Minimap button back ON")

    -- Verify /pf autoopen toggles showSideWindow
    SlashCmdList["PROFITABLE"]("autoopen")
    Assert(Profitable_DB.settings.showSideWindow == true, "/pf autoopen toggles auto-open back ON")

    -- 32C. Manual Snooze (24h & Permanent) + Rotation + Expiry + Unhide UI
    PF.AHVerifier.RecalculateFromCache()
    PF.SideWindow.Refresh()
    Assert(#Profitable_DB.lastTopPlays == 3 and Profitable_DB.lastTopPlays[1].itemId == 2852,
        "Top plays initialized with Copper Chain Pants (#1), Peacebloom (#2), Solid Grinding Stone (#3)")

    -- Click the compact 'x' snooze button on Row 1 (24h snooze)
    _G.IsShiftKeyDown = function() return false end
    local row1SnoozeBtn = _G["PF_SideWindowPlayButton1_Snooze"]
    Assert(row1SnoozeBtn ~= nil and row1SnoozeBtn:IsShown(), "Row 1 displays compact 'x' snooze button")
    row1SnoozeBtn:Click("LeftButton")

    Assert(PF.IsPlaySnoozed({ actionType = "CRAFT_VENDOR", itemId = 2852 }) == true,
        "Clicking Row 1 'x' snoozes Copper Chain Pants")
    Assert(#Profitable_DB.lastTopPlays == 2 and Profitable_DB.lastTopPlays[1].itemId == 2447,
        "Snoozing #1 immediately removes it and promotes Peacebloom to #1")

    -- Shift-Right-Click Row 1 (Peacebloom) -> Permanent hide
    _G.IsShiftKeyDown = function() return true end
    _G["PF_SideWindowPlayButton1"]:Click("RightButton")
    local _, pbSnoozeEntry = PF.IsPlaySnoozed({ actionType = "VENDOR", itemId = 2447 })
    Assert(pbSnoozeEntry ~= nil and pbSnoozeEntry.expiresAt == 0 and pbSnoozeEntry.reason == "permanent",
        "Shift-Right-Click on a row permanently hides the play (expiresAt == 0)")
    Assert(#Profitable_DB.lastTopPlays == 1 and Profitable_DB.lastTopPlays[1].itemId == 7966,
        "Permanent hide immediately promotes Solid Grinding Stone to #1")
    _G.IsShiftKeyDown = function() return false end

    -- DetailWindow Snooze button also snoozes and closes DetailWindow
    PF.DetailWindow.ShowOpportunity(Profitable_DB.lastTopPlays[1])
    Assert(PF.DetailWindow.frame:IsShown() and PF.DetailWindow.frame.snoozeBtn ~= nil,
        "DetailWindow displays header 'Snooze 24h' button")
    PF.DetailWindow.frame.snoozeBtn:Click("LeftButton")
    Assert(not PF.DetailWindow.frame:IsShown(), "Clicking DetailWindow 'Snooze 24h' closes DetailWindow")
    Assert(PF.IsPlaySnoozed({ actionType = "CRAFT_AH", itemId = 7966 }) == true and #Profitable_DB.lastTopPlays == 0,
        "DetailWindow 'Snooze 24h' snoozes Solid Grinding Stone and clears it from Top 5")

    -- Snoozed Plays Manager UI lists all 3 active snoozes and lets user unhide individually
    PF.SideWindow.ToggleSnoozedWindow()
    Assert(PF.SideWindow.snoozedFrame ~= nil and PF.SideWindow.snoozedFrame:IsShown(),
        "Snoozed Plays management window opens cleanly")
    Assert(#PF.GetActiveSnoozedPlays() == 3, "GetActiveSnoozedPlays reports 3 active snoozed plays")

    -- Advance time by 24h + 1s -> 24h snoozes expire automatically, permanent hide remains!
    Mock.currentTime = Mock.currentTime + 86401
    _G.Auctionator.SavedState.TimeOfLastFullScan = math.floor(Mock.currentTime) - 60
    PF.SideWindow.ApplyFilterChange()
    Assert(not PF.IsPlaySnoozed({ actionType = "CRAFT_VENDOR", itemId = 2852 }),
        "24h snooze on Copper Chain Pants automatically expires after 24 hours")
    Assert(not PF.IsPlaySnoozed({ actionType = "CRAFT_AH", itemId = 7966 }),
        "24h snooze on Solid Grinding Stone automatically expires after 24 hours")
    Assert(PF.IsPlaySnoozed({ actionType = "VENDOR", itemId = 2447 }) == true,
        "Permanent hide on Peacebloom persists after 24 hours")

    -- Slash command /pf unhide Peacebloom restores permanent hide
    SlashCmdList["PROFITABLE"]("unhide Peacebloom")
    Assert(not PF.IsPlaySnoozed({ actionType = "VENDOR", itemId = 2447 }) and #Profitable_DB.lastTopPlays == 3,
        "/pf unhide <name> restores a permanently hidden play and refreshes Top 5")

    -- 32D. Auto-Snooze on Craft (12 Hours)
    -- Crafting Solid Grinding Stone (7966) via TRADE_SKILL_ITEM_CRAFTED_RESULT auto-snoozes it for 12h!
    PF.RecipeScanner.frame:Trigger("TRADE_SKILL_ITEM_CRAFTED_RESULT", {
        itemID = 7966,
        hyperlink = "|cffffffff|Hitem:7966:0:0:0|h[Solid Grinding Stone]|h|r",
    })
    local isCraftSnoozed, craftEntry = PF.IsPlaySnoozed({ actionType = "CRAFT_AH", itemId = 7966 })
    Assert(isCraftSnoozed == true and craftEntry.reason == "crafted" and craftEntry.durationSeconds == 43200,
        "Completing craft (TRADE_SKILL_ITEM_CRAFTED_RESULT) auto-snoozes Solid Grinding Stone for 12 hours")
    Assert(#Profitable_DB.lastTopPlays == 2,
        "Auto-snooze on craft immediately removes crafted item from Top 5")

    -- Crafting an unrelated/intermediate item (e.g. Copper Bar 2840) must NOT be auto-snoozed
    PF.RecipeScanner.frame:Trigger("CHAT_MSG_LOOT", "You create: |cffffffff|Hitem:2840:0:0:0|h[Copper Bar]|h|r.")
    Assert(not PF.IsPlaySnoozed({ actionType = "CRAFT_AH", itemId = 2840 }),
        "Crafting an unrelated/intermediate item does not trigger auto-snooze")

    -- Crafting Copper Chain Pants via Classic CHAT_MSG_LOOT ("You create: ...") also auto-snoozes for 12h
    PF.RecipeScanner.frame:Trigger("CHAT_MSG_LOOT", "You create: |cff1eff00|Hitem:2852:0:0:0|h[Copper Chain Pants]|h|r.")
    local isLootCraftSnoozed, lootCraftEntry = PF.IsPlaySnoozed({ actionType = "CRAFT_VENDOR", itemId = 2852 })
    Assert(isLootCraftSnoozed == true and lootCraftEntry.reason == "crafted" and lootCraftEntry.durationSeconds == 43200,
        "Completing craft (CHAT_MSG_LOOT 'You create:') auto-snoozes Copper Chain Pants for 12 hours")

    -- Still snoozed at 11 hours, automatically restored after 12 hours
    Mock.currentTime = Mock.currentTime + (11 * 3600)
    _G.Auctionator.SavedState.TimeOfLastFullScan = math.floor(Mock.currentTime) - 60
    Assert(PF.IsPlaySnoozed({ actionType = "CRAFT_AH", itemId = 7966 }) == true,
        "12h craft auto-snooze remains active at 11 hours")
    Mock.currentTime = Mock.currentTime + (2 * 3600)
    _G.Auctionator.SavedState.TimeOfLastFullScan = math.floor(Mock.currentTime) - 60
    PF.SideWindow.ApplyFilterChange()
    Assert(not PF.IsPlaySnoozed({ actionType = "CRAFT_AH", itemId = 7966 }) and #Profitable_DB.lastTopPlays == 3,
        "12h craft auto-snooze automatically expires after 12 hours and restores plays")

    -- Disabling autoSnoozeOnCraft (via Options / /pf autosnooze) prevents auto-snoozing on craft
    SlashCmdList["PROFITABLE"]("autosnooze")
    Assert(Profitable_DB.settings.autoSnoozeOnCraft == false, "/pf autosnooze toggles auto-snooze on craft OFF")
    PF.RecipeScanner.frame:Trigger("TRADE_SKILL_ITEM_CRAFTED_RESULT", { itemID = 7966 })
    Assert(not PF.IsPlaySnoozed({ actionType = "CRAFT_AH", itemId = 7966 }),
        "Craft completion does NOT auto-snooze when autoSnoozeOnCraft is OFF")

    -- Restore globals cleanly
    _G.PCF_AuctionScanButton = origPCFBtn32
    _G.IsShiftKeyDown = origShift32
    Mock.currentTime = origTime32
    _G.Auctionator = origAtr32
    _G.AUCTIONATOR_PRICE_DATABASE = origAtrDB32
    _G.PCF_DB = origPCF32
    _G.Profitable_DB = origDB32
    PF.LoadConfig(origDB32)
end

-- =============================================================================
-- 33. Snooze / Unsnooze Fast-Path Performance, O(1) Auctionator Suffixed-Gear
--     Indexing, Batch Recipe Lookup, and Zero-Rescan UI Refresh Regressions
-- =============================================================================
do
    local origDB33 = _G.Profitable_DB
    local origPCF33 = _G.PCF_DB
    local origAtr33 = _G.Auctionator
    local origAtrDB33 = _G.AUCTIONATOR_PRICE_DATABASE
    local origCTSU33 = _G.C_TradeSkillUI
    local origShift33 = _G.IsShiftKeyDown
    local origBagCounts33 = Mock.bagCounts

    local charKey33 = PF.GetCharacterKey()
    local now33 = math.floor(Mock.currentTime)

    -- Build a realistic 15,000-entry Auctionator + PCF dataset (including 3,000 suffixed "g:<id>:..." gear keys)
    local largeAtrDB = {}
    local largePCFPrices = {}
    local itemCache33 = {}

    for i = 1, 12000 do
        local id = 200000 + i
        largeAtrDB[tostring(id)] = { m = 50000, a = { ["100"] = 10 } }
        largePCFPrices[id] = { minBuyout = 52000, count = 10, lastUpdated = now33 - 300, source = "Scan" }
    end
    for i = 1, 3000 do
        local gearId = 300000 + i
        largeAtrDB[string.format("g:%d:0:1200", gearId)] = { m = 95000, a = { ["100"] = 2 } }
        largeAtrDB[string.format("gr:%d:15:1200", gearId)] = { m = 90000, a = { ["100"] = 1 } }
    end

    -- Add 8 distinct profitable vendor/craft plays so Top 5 + reserves (#6, #7, #8) + Honorable Mentions rotate cleanly
    local charRecipes33 = {}
    for idx = 1, 8 do
        local outId = 410000 + idx
        local regId = 420000 + idx
        itemCache33[outId] = {
            name = "Perf Crafted Play #" .. idx,
            quality = 2,
            itemLevel = 35,
            classID = 7,
            vendorSell = 100,
        }
        itemCache33[regId] = {
            name = "Perf Reagent #" .. idx,
            quality = 1,
            itemLevel = 20,
            classID = 7,
            vendorSell = 10,
        }
        -- Reagent costs 10s, crafted item sells for (100 - idx*5)s on AH -> strictly descending profit #1..#8
        largeAtrDB[tostring(regId)] = { m = 1000, a = { ["100"] = 100 } }
        largeAtrDB[tostring(outId)] = { m = (100 - (idx * 5)) * 100, a = { ["100"] = 20 } }
        charRecipes33["Perf:" .. idx] = {
            name = "Perf Crafted Play #" .. idx,
            profession = "Blacksmithing",
            professionId = 164,
            recipeId = 510000 + idx,
            outputItemId = outId,
            avgMade = 1,
            reagents = {
                { itemId = regId, name = "Perf Reagent #" .. idx, count = 2 },
                { itemId = 3860, name = "Mithril Bar", count = 1 }, -- Triggers GetIntermediateRecipeForItem!
            },
        }
    end
    -- Include Mithril Ore / Bar prices for intermediate conversion evaluation
    itemCache33[3860] = { name = "Mithril Bar", quality = 1, itemLevel = 35, classID = 7, vendorSell = 400 }
    itemCache33[3858] = { name = "Mithril Ore", quality = 1, itemLevel = 35, classID = 7, vendorSell = 250 }
    largeAtrDB["3860"] = { m = 1200, a = { ["100"] = 200 } }
    largeAtrDB["3858"] = { m = 900,  a = { ["100"] = 200 } }

    -- Also add a suffixed gear item in Auctionator ("gr:5541:...") to verify O(1) gearBestByItemId resolution
    itemCache33[5541] = { name = "Iridescent Hammer", quality = 2, itemLevel = 28, classID = 2, invType = "INVTYPE_WEAPON", vendorSell = 20000 }
    largeAtrDB["g:5541:0:100"] = { m = 8000, a = { ["100"] = 2 } }
    largeAtrDB["gr:5541:12:100"] = { m = 5000, a = { ["100"] = 3 } } -- Cheapest suffixed gear listing = 50s (< 2g vendor!)

    -- Mock an open 250-recipe C_TradeSkillUI window to verify GetKnownRecipes / Snooze NEVER re-scans TradeSkill UI
    local getAllRecipeIDsCalls = 0
    local mockRecipeIds = {}
    for i = 1, 250 do mockRecipeIds[i] = 600000 + i end
    _G.C_TradeSkillUI = {
        IsTradeSkillReady = function() return true end,
        GetAllRecipeIDs = function()
            getAllRecipeIDsCalls = getAllRecipeIDsCalls + 1
            return mockRecipeIds
        end,
        GetRecipeInfo = function(id)
            return { recipeID = id, name = "Mock Recipe " .. id, learned = true, itemID = id }
        end,
    }

    _G.PCF_DB = { prices = largePCFPrices, lastFullScan = now33 - 300, settings = { showScanButton = true } }
    _G.AUCTIONATOR_PRICE_DATABASE = { __dbversion = 7, ["Forever Alliance"] = largeAtrDB }
    _G.Auctionator = {
        SavedState = { TimeOfLastFullScan = now33 - 30 },
        Database = { db = largeAtrDB },
        API = {
            v1 = {
                GetAuctionPriceByItemID = function(_, id)
                    local r = largeAtrDB[tostring(id)]
                    return r and r.m or nil
                end,
                GetAuctionAgeByItemID = function(_, id)
                    return largeAtrDB[tostring(id)] and 0 or nil
                end,
            },
        },
    }

    local db33 = {
        version = 4,
        settings = {
            onboardingDismissed = true,
            includeSkillMatchedBaselineRecipes = false,
            includeTrainerRecommendations = false,
            assumeCanDisenchant = false,
            showCraftPlays = true,
            showVendorPlays = true,
            showSideWindow = true,
            autoSnoozeOnCraft = true,
            priceSource = "AUTO",
        },
        charRecipes = { [charKey33] = charRecipes33 },
        itemCache = itemCache33,
        orderBookCache = {},
        snoozedPlays = {},
        lastTopPlays = {},
        lastHonorableMentions = {},
    }
    PF.LoadConfig(db33)
    PF.AuctionatorSource.InvalidateCache()
    Mock.bagCounts = { [420006] = 7 } -- Pre-populate 7x Perf Reagent #6 in bags to test lazy inventory computation on rotation!

    -- 33A. Verify suffixed gear ("gr:5541:...") resolves minimum buyout (5000c) in O(1) and full 15,000-item scan is fast
    local hammerAtr = PF.AuctionatorSource.GetItemData(5541)
    Assert(hammerAtr ~= nil and hammerAtr.minBuyout == 5000 and hammerAtr.count == 3,
        "Indexed AuctionatorSource resolves lowest suffixed gear entry (gr:5541 -> 50s, qty 3) in O(1)")

    local t0Scan = os.clock()
    PF.AHVerifier.RecalculateFromCache()
    PF.SideWindow.frame:Show()
    PF.SideWindow.Refresh()
    local fullScanMs = (os.clock() - t0Scan) * 1000

    Assert(getAllRecipeIDsCalls == 0,
        "RecalculateFromCache and SideWindow.Refresh NEVER trigger C_TradeSkillUI.GetAllRecipeIDs re-scans")
    Assert(#Profitable_DB.lastTopPlays == 5,
        "Full 15,000-item calculation populates Top 5 plays")
    Assert(fullScanMs < 500,
        string.format("Full 15,000-item PCF+Auctionator calculation completes in <500ms (actual: %.2fms)", fullScanMs))

    -- 33B. Spy on FindTopOpportunities and DetailWindow.RefreshIfShown during Snooze / Unsnooze / Craft Auto-Snooze
    local findTopCalls33 = 0
    local origFindTop33 = PF.OpportunityEngine.FindTopOpportunities
    PF.OpportunityEngine.FindTopOpportunities = function(...)
        findTopCalls33 = findTopCalls33 + 1
        return origFindTop33(...)
    end

    _G.IsShiftKeyDown = function() return false end
    local t0Snooze = os.clock()

    -- Snooze #1..#4 sequentially via UI buttons -> #6, #7, #8 rotate into Top 5 with ZERO FindTopOpportunities calls!
    local firstId = Profitable_DB.lastTopPlays[1].itemId
    _G["PF_SideWindowPlayButton1_Snooze"]:Click("LeftButton")
    Assert(findTopCalls33 == 0, "Clicking Row 1 'x' snooze rotates Top 5 with ZERO FindTopOpportunities() calls")
    Assert(#Profitable_DB.lastTopPlays == 5 and Profitable_DB.lastTopPlays[1].itemId ~= firstId,
        "Snoozing #1 immediately promotes reserve play #6 into Top 5")
    Assert(Profitable_DB.lastTopPlays[1].summaryLine:find("^1%.") ~= nil
        and Profitable_DB.lastTopPlays[5].summaryLine:find("^5%.") ~= nil,
        "Fast-path snooze rotation renumbers ranks 1..5 cleanly")

    -- Snooze via Right-Click
    _G["PF_SideWindowPlayButton1"]:Click("RightButton")
    Assert(findTopCalls33 == 0 and #Profitable_DB.lastTopPlays == 5,
        "Right-Click snooze rotates reserve play #7 into Top 5 with ZERO FindTopOpportunities() calls")

    -- Snooze via DetailWindow 'Snooze 24h' button -> hides DetailWindow BEFORE snoozing (zero wasted DetailWindow redraw)
    PF.DetailWindow.ShowOpportunity(Profitable_DB.lastTopPlays[1])
    local detailRefreshDuringSnooze = 0
    local origDetailRefresh33 = PF.DetailWindow.RefreshIfShown
    PF.DetailWindow.RefreshIfShown = function(...)
        if PF.DetailWindow.frame and PF.DetailWindow.frame:IsShown() then
            detailRefreshDuringSnooze = detailRefreshDuringSnooze + 1
        end
        return origDetailRefresh33(...)
    end
    PF.DetailWindow.frame.snoozeBtn:Click("LeftButton")
    PF.DetailWindow.RefreshIfShown = origDetailRefresh33
    Assert(detailRefreshDuringSnooze == 0 and not PF.DetailWindow.frame:IsShown(),
        "DetailWindow 'Snooze 24h' hides window before snooze update so DetailWindow is not wastefully redrawn")
    Assert(findTopCalls33 == 0, "DetailWindow 'Snooze 24h' uses O(M) fast path with ZERO FindTopOpportunities() calls")

    -- Auto-snooze on craft (12h) while C_TradeSkillUI has 250 recipes open -> ZERO FindTopOpportunities & ZERO TradeSkill scans!
    local craftTarget = Profitable_DB.lastTopPlays[1]
    PF.RecipeScanner.frame:Trigger("TRADE_SKILL_ITEM_CRAFTED_RESULT", { itemID = craftTarget.itemId })
    Assert(findTopCalls33 == 0 and getAllRecipeIDsCalls == 0,
        "Auto-snooze on craft rotates plays with ZERO FindTopOpportunities() and ZERO TradeSkill UI scans")

    -- Verify promoted reserve play (410006) lazily computed live bag inventory (7x Perf Reagent #6 in bags)
    local promotedPlay6 = nil
    for _, p in ipairs(Profitable_DB.lastTopPlays) do
        if p.itemId == 410006 then promotedPlay6 = p end
    end
    if promotedPlay6 then
        local reg6Shop = nil
        for _, s in ipairs(promotedPlay6.shoppingList or {}) do
            if s.itemId == 420006 then reg6Shop = s end
        end
        Assert(reg6Shop ~= nil and reg6Shop.haveInBags == 7,
            "Reserve play promoted during fast-path snooze rotation lazily computes exact live bag counts (7 in bags)")
    end

    -- Unsnooze individual play via Snoozed Window button AND '/pf unhide all' -> BOTH use O(M) fast path!
    PF.SideWindow.ToggleSnoozedWindow()
    local snoozeRow1Btn = _G["PF_SnoozedRow1"] and _G["PF_SnoozedRow1"].unhideBtn
    Assert(snoozeRow1Btn ~= nil, "Snoozed window row 1 unhide button exists")
    snoozeRow1Btn:Click("LeftButton")
    Assert(findTopCalls33 == 0, "Clicking 'Unhide' in Snoozed Plays window restores play with ZERO FindTopOpportunities() calls")

    SlashCmdList["PROFITABLE"]("unhide all")
    local totalSnoozeCycleMs = (os.clock() - t0Snooze) * 1000
    Assert(findTopCalls33 == 0 and #PF.GetActiveSnoozedPlays() == 0 and Profitable_DB.lastTopPlays[1].itemId == firstId,
        "'/pf unhide all' restores original #1 play in O(M) with ZERO FindTopOpportunities() calls")
    Assert(totalSnoozeCycleMs < 25,
        string.format("Entire 6-action Snooze/Auto-Snooze/Unhide cycle on 15,000-item DB completes in <25ms (actual: %.2fms)", totalSnoozeCycleMs))

    -- 33C. Changing budget or filter settings invalidates the pool signature and triggers a fresh calculation
    SlashCmdList["PROFITABLE"]("budget 5g")
    Assert(findTopCalls33 == 1, "Changing spending budget invalidates cached pool and recalculates cleanly")

    -- Restore globals cleanly
    PF.OpportunityEngine.FindTopOpportunities = origFindTop33
    Mock.bagCounts = origBagCounts33
    _G.IsShiftKeyDown = origShift33
    _G.C_TradeSkillUI = origCTSU33
    _G.Auctionator = origAtr33
    _G.AUCTIONATOR_PRICE_DATABASE = origAtrDB33
    _G.PCF_DB = origPCF33
    _G.Profitable_DB = origDB33
    PF.LoadConfig(origDB33)
end

print("\nAll Profitable test assertions passed successfully!")
