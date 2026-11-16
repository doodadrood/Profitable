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
require("Modules.RecipeScanner")
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

print("\nAll Profitable test assertions passed successfully!")
