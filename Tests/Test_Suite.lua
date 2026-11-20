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
Assert(PF.VendorDatabase.GetVendorSellPrice(2846) == 107, "Copper Chain Pants vendor sell price is 1s 7c (107c)")

-- 3. Disenchant Database & 3:1 Essence Conversion Tests
Assert(PF.DisenchantDatabase.CanDisenchant(5540) == true, "Iridescent Hammer (Green Weapon) is disenchantable")
Assert(PF.DisenchantDatabase.CanDisenchant(2447) == false, "Peacebloom (Trade Good) is not disenchantable")
Assert(PF.DisenchantDatabase.CanDisenchant(11288) == false, "Greater Magic Wand (Crafted Wand) is excluded from DE")

-- Set enchanting mat prices in PCF_DB:
-- Iridescent Hammer (5540) is ilvl 26 Uncommon Weapon:
-- 75% Greater Astral Essence (11082, 1-2 avg 1.5), 20% Soul Dust (11083, 1-2 avg 1.5), 5% Large Glimmering Shard (11084, 1)
_G.PCF_DB.prices[11082] = { minBuyout = 40000, count = 20, lastUpdated = Mock.currentTime } -- 4g ea
_G.PCF_DB.prices[11083] = { minBuyout = 5000,  count = 50, lastUpdated = Mock.currentTime } -- 50s ea
_G.PCF_DB.prices[11084] = { minBuyout = 80000, count = 10, lastUpdated = Mock.currentTime } -- 8g ea

local deHammer = PF.DisenchantDatabase.EvaluateDisenchant(5540, nil, PF.OpportunityEngine.ResolveAHPrice, 0.05)
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
        outputItemId = 2846,
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
        outputItemId = 5540,
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

-- 2) Craft and Vendor [Copper Chain Pants] (2846)
-- Give Copper Chain Pants vendorSell = 12500 (1g 25s), Copper Bar (2840) = 2750 (27s 50c) x 4 = 1g 10s per craft -> 20 crafts = Cost 22g, Profit 3g!
Profitable_DB.itemCache[2846] = { name = "Copper Chain Pants", quality = 1, itemLevel = 9, classID = 4, invType = "INVTYPE_LEGS", vendorSell = 12500 }
_G.PCF_DB.prices[2840] = { minBuyout = 2750, count = 80, lastUpdated = Mock.currentTime }

-- 3) Craft and AH [Solid Grinding Stone] (7966)
-- Solid Stone (7912) = 275c x 4 = 1100c (11s) per craft. 20 crafts = Cost 22g (220,000c -> let's set Solid Stone = 2750c (27s50c) x 4 = 1g10s * 20 = 22g)
-- Solid Grinding Stone AH buyout = 12868c -> after 5% cut = 12225c * 20 = 244,500c -> Profit 2g 45s!
_G.PCF_DB.prices[7912] = { minBuyout = 2750, count = 80, lastUpdated = Mock.currentTime }
_G.PCF_DB.prices[7966] = { minBuyout = 12868, count = 20, lastUpdated = Mock.currentTime }

-- 4) Craft and DE [Iridescent Hammer] (5540)
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
    itemId = 5540, -- Iridescent Hammer (Weapon, vendorSell = 3194)
    itemName = "Iridescent Hammer",
    ahCutRate = 0.05,
    unitGrossRevenue = 60000,
    unitAHCut = 3000,
    unitDepositRisk = math.floor(3194 * 0.15),
    unitNetRevenue = 60000 - 3000 - math.floor(3194 * 0.15),
    maxUnits = Profitable_DB.settings.maxAHGearUnits,
    rawReagents = { { itemId = 2841, name = "Bronze Bar", count = 10 } },
}
local gearOpp = PF.OpportunityEngine.CalculateSteppedOpportunity(gearCand, 220000)
Assert(gearOpp ~= nil and gearOpp.quantity == 3 and gearOpp.totalDepositRisk == (3 * math.floor(3194 * 0.15)), "Cap slow-moving AH gear crafts at 3 units and deduct expected AH deposit risk")

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
        { id = "CRAFT_VENDOR:2846", itemId = 2846, itemName = "Copper Chain Pants", itemLink = "[Copper Chain Pants]", actionLabel = "Craft and Vendor", hmCategory = "Top Vendor", quantity = 1, totalCost = 50, totalProfit = 50, roiPercent = 100 },
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
    -- 2) CRAFT_VENDOR: Copper Chain Pants (2846, vendorSell 1g 25s, crafted from 4x Copper Bar 2840 @ 20s = 80s)
    _G.Profitable_DB.itemCache[2846] = { name = "Copper Chain Pants", quality = 1, itemLevel = 9, classID = 4, invType = "INVTYPE_LEGS", vendorSell = 12500 }
    _G.PCF_DB.prices[2840] = { minBuyout = 2000, count = 80, lastUpdated = nowTs, source = "Scan" }
    _G.PF.RecipeScanner.RegisterRecipe({
        name = "Copper Chain Pants",
        profession = "Blacksmithing",
        outputItemId = 2846,
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

    -- 21A. Config v1 -> v3 migration resets old default marketFeedVerifySkipSeconds = 7200 to 0
    local legacyV1DB = {
        version = 1,
        settings = {
            marketFeedVerifySkipSeconds = 7200,
        },
    }
    _G.PF.LoadConfig(legacyV1DB)
    Assert(legacyV1DB.version == 3 and legacyV1DB.settings.marketFeedVerifySkipSeconds == 0, "v1 -> v3 migration resets legacy marketFeedVerifySkipSeconds (7200 -> 0)")

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
    Assert(legacyV2DB.version == 3, "v2 -> v3 migration upgrades config version to 3")
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

print("\nAll Profitable test assertions passed successfully!")
