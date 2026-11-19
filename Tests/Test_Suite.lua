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
PF.DetailWindow.ShowOpportunity(topPlays[2])
detailFrame.recipeBtn:Click()
Assert(Mock.craftedTradeSkill ~= nil, "Clicking Open Recipe triggers crafting / selects recipe")

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

    Mock.timers = {}
    searchCalls = 0
    local playsFromFeed = PF.AHVerifier.StartDiscoveryAndVerification()
    Assert(PF.AHVerifier.IsRunning() == false, "StartDiscoveryAndVerification finishes immediately without live queries when MarketFeed < 2h")
    Assert(searchCalls == 0, "Normal click skips C_AuctionHouse.SendSearchQuery when items are covered by fresh MarketFeed")
    Assert(playsFromFeed and playsFromFeed[1] and playsFromFeed[1].verified == true, "Top plays backed by fresh MarketFeed are marked verified")

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

    -- Restore outer test environment
    _G.C_AddOns = origCAddOns
    _G.IsAddOnLoaded = origIsAddOnLoaded
    _G.Auctionator = origAuctionator
    _G.TSM_API = origTSMAPI
    _G.C_ChatInfo = origChatInfo
    _G.AuctionFrame = origAuctionFrame
    _G.AuctionHouseFrame = origAuctionHouseFrame
end

print("\nAll Profitable test assertions passed successfully!")
