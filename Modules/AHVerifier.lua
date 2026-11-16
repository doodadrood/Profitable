local _, PF = ...
PF = type(PF) == "table" and PF or _G.PF or {}
_G.PF = PF

PF.AHVerifier = {}

local verifierFrame = CreateFrame("Frame")
local isRunning = false
local runToken = 0
local startTime = 0
local verifyQueue = {}
local verifyIndex = 0
local currentQueryItem = nil
local currentCandidates = {}
local onUpdateCallback = nil
local onFinishCallback = nil

local function SafeRegisterEvent(frame, eventName)
    if frame and frame.RegisterEvent then
        pcall(frame.RegisterEvent, frame, eventName)
    end
end

local function SafeUnregisterEvent(frame, eventName)
    if frame and frame.UnregisterEvent then
        pcall(frame.UnregisterEvent, frame, eventName)
    end
end

function PF.AHVerifier.IsAuctionHouseOpen()
    if _G.AuctionFrame and (not _G.AuctionFrame.IsShown or _G.AuctionFrame:IsShown()) then
        return true
    end
    if _G.AuctionHouseFrame and (not _G.AuctionHouseFrame.IsShown or _G.AuctionHouseFrame:IsShown()) then
        return true
    end
    return false
end

function PF.AHVerifier.IsRunning()
    return isRunning
end

function PF.AHVerifier.RecordOrderBook(itemId, listings)
    if not itemId or itemId <= 0 or type(listings) ~= "table" then
        return
    end

    local byPrice = {}
    local merged = {}
    local minUnit = nil
    local totalCount = 0

    for _, row in ipairs(listings) do
        local up = row and row.unitPrice and math.floor(row.unitPrice)
        local qty = row and row.quantity and math.floor(row.quantity)
        if up and up > 0 and qty and qty > 0 then
            totalCount = totalCount + qty
            if not minUnit or up < minUnit then
                minUnit = up
            end
            if not byPrice[up] then
                byPrice[up] = { unitPrice = up, quantity = qty }
                table.insert(merged, byPrice[up])
            else
                byPrice[up].quantity = byPrice[up].quantity + qty
            end
        end
    end

    table.sort(merged, function(a, b) return a.unitPrice < b.unitPrice end)

    Profitable_DB = Profitable_DB or {}
    Profitable_DB.orderBookCache = Profitable_DB.orderBookCache or {}
    Profitable_DB.orderBookCache[itemId] = {
        timestamp = time(),
        listings = merged,
    }

    -- Also keep PCF_DB.prices in sync with the freshly verified minBuyout and total count
    if minUnit and totalCount > 0 then
        _G.PCF_DB = _G.PCF_DB or {}
        _G.PCF_DB.prices = _G.PCF_DB.prices or {}
        _G.PCF_DB.prices[itemId] = {
            minBuyout = minUnit,
            minBid = minUnit,
            lastUpdated = time(),
            count = totalCount,
            source = "Scan",
        }
    end
end

local function MarkVerifiedOpportunities(opportunities, verifiedItemMap)
    if type(opportunities) ~= "table" then return end
    for _, opp in ipairs(opportunities) do
        local allVerified = true
        if opp.shoppingList then
            for _, shop in ipairs(opp.shoppingList) do
                if shop.source == "AH" then
                    local ob = Profitable_DB and Profitable_DB.orderBookCache and Profitable_DB.orderBookCache[shop.itemId]
                    local isFresh = ob and (time() - (ob.timestamp or 0)) <= 600
                    if not isFresh and not (verifiedItemMap and verifiedItemMap[shop.itemId]) then
                        allVerified = false
                        break
                    end
                end
            end
        end
        opp.verified = allVerified
    end
end

local verifiedInSession = {}

local function FinalizeRun(reason)
    isRunning = false
    currentQueryItem = nil
    runToken = runToken + 1
    SafeUnregisterEvent(verifierFrame, "AUCTION_ITEM_LIST_UPDATE")
    SafeUnregisterEvent(verifierFrame, "COMMODITY_SEARCH_RESULTS_UPDATED")
    SafeUnregisterEvent(verifierFrame, "ITEM_SEARCH_RESULTS_UPDATED")
    SafeUnregisterEvent(verifierFrame, "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")

    local topPlays = PF.OpportunityEngine.FindTopOpportunities()
    MarkVerifiedOpportunities(topPlays, verifiedInSession)

    Profitable_DB = Profitable_DB or {}
    Profitable_DB.lastTopPlays = topPlays

    if onFinishCallback then
        onFinishCallback(topPlays, reason or "COMPLETE")
    end
    if PF.SideWindow and PF.SideWindow.Refresh then
        PF.SideWindow.Refresh()
    end
    if PF.DetailWindow and PF.DetailWindow.RefreshIfShown then
        PF.DetailWindow.RefreshIfShown()
    end
end

function PF.AHVerifier.Stop(reason)
    if not isRunning then return end
    FinalizeRun(reason or "STOPPED")
end

local function ShouldContinuePastTimeout()
    local settings = (Profitable_DB and Profitable_DB.settings) or {}
    local maxSec = settings.maxCalculationSeconds or 90
    local graceSec = settings.extremeGraceSeconds or 30
    local mult = settings.extremeProfitMultiplier or 2.0
    local elapsed = GetTime() - startTime

    if elapsed < maxSec then
        return true
    end
    if elapsed >= (maxSec + graceSec) then
        return false
    end

    -- Check if an unverified candidate has "extremely profitable" potential (>= mult * current best verified play)
    local currentTop = PF.OpportunityEngine.FindTopOpportunities()
    MarkVerifiedOpportunities(currentTop, verifiedInSession)

    local bestVerifiedProfit = 0
    local bestUnverifiedProfit = 0
    for _, opp in ipairs(currentTop) do
        if opp.verified then
            if opp.totalProfit > bestVerifiedProfit then
                bestVerifiedProfit = opp.totalProfit
            end
        else
            if opp.totalProfit > bestUnverifiedProfit then
                bestUnverifiedProfit = opp.totalProfit
            end
        end
    end

    if bestUnverifiedProfit > 0 and (bestVerifiedProfit == 0 or bestUnverifiedProfit >= (bestVerifiedProfit * mult)) then
        return true
    end

    return false
end

local ScheduleNextVerification

local function CollectLegacyQueryResults(targetItem)
    if not _G.GetNumAuctionItems or not _G.GetAuctionItemInfo then
        return false
    end
    local numBatch = _G.GetNumAuctionItems("list") or 0
    local listings = {}

    for i = 1, numBatch do
        local name, _, count, _, _, _, _, minBid, _, buyoutPrice, _, _, _, _, _, _, itemId = _G.GetAuctionItemInfo("list", i)
        if (not itemId or itemId <= 0) and _G.GetAuctionItemLink then
            local link = _G.GetAuctionItemLink("list", i)
            if type(link) == "string" then
                itemId = tonumber(link:match("item:(%d+)"))
            end
        end
        local matchesId = (itemId and itemId == targetItem.itemId)
        local matchesName = (not itemId and name and targetItem.name and name:lower() == targetItem.name:lower())
        if (matchesId or matchesName) and buyoutPrice and buyoutPrice > 0 and count and count > 0 then
            local unitPrice = math.floor(buyoutPrice / count)
            if unitPrice > 0 then
                table.insert(listings, { unitPrice = unitPrice, quantity = count })
            end
        end
    end

    if #listings > 0 then
        PF.AHVerifier.RecordOrderBook(targetItem.itemId, listings)
        verifiedInSession[targetItem.itemId] = true
        return true
    end
    return false
end

local function CollectModernCommodityResults(itemId)
    if not _G.C_AuctionHouse or not _G.C_AuctionHouse.GetNumCommoditySearchResults or not _G.C_AuctionHouse.GetCommoditySearchResultInfo then
        return false
    end
    local okNum, num = pcall(_G.C_AuctionHouse.GetNumCommoditySearchResults, itemId)
    if not okNum or not num or num <= 0 then
        return false
    end
    local listings = {}
    for i = 1, num do
        local okRow, row = pcall(_G.C_AuctionHouse.GetCommoditySearchResultInfo, itemId, i)
        if okRow and type(row) == "table" and row.unitPrice and row.unitPrice > 0 and row.quantity and row.quantity > 0 then
            table.insert(listings, { unitPrice = math.floor(row.unitPrice), quantity = math.floor(row.quantity) })
        end
    end
    if #listings > 0 then
        PF.AHVerifier.RecordOrderBook(itemId, listings)
        verifiedInSession[itemId] = true
        return true
    end
    return false
end

local function CollectModernItemResults(itemId)
    if not _G.C_AuctionHouse or not _G.C_AuctionHouse.GetNumItemSearchResults or not _G.C_AuctionHouse.GetItemSearchResultInfo then
        return false
    end
    local itemKey = { itemID = itemId, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 }
    local okNum, num = pcall(_G.C_AuctionHouse.GetNumItemSearchResults, itemKey)
    if not okNum or not num or num <= 0 then
        return false
    end
    local listings = {}
    for i = 1, num do
        local okRow, row = pcall(_G.C_AuctionHouse.GetItemSearchResultInfo, itemKey, i)
        if okRow and type(row) == "table" then
            local buyout = row.buyoutAmount or row.minBid or row.bidAmount
            local qty = (row.quantity and row.quantity > 0) and row.quantity or 1
            if buyout and buyout > 0 then
                local unitPrice = math.floor(buyout / qty)
                if unitPrice > 0 then
                    table.insert(listings, { unitPrice = unitPrice, quantity = qty })
                end
            end
        end
    end
    if #listings > 0 then
        PF.AHVerifier.RecordOrderBook(itemId, listings)
        verifiedInSession[itemId] = true
        return true
    end
    return false
end

ScheduleNextVerification = function(delay)
    if not isRunning then return end
    local myToken = runToken

    C_Timer.After(delay or 0.15, function()
        if not isRunning or runToken ~= myToken then return end

        if not ShouldContinuePastTimeout() then
            FinalizeRun("TIMEOUT_TOP5_ACCEPTED")
            return
        end

        verifyIndex = verifyIndex + 1
        if verifyIndex > #verifyQueue then
            FinalizeRun("COMPLETE")
            return
        end

        local target = verifyQueue[verifyIndex]
        currentQueryItem = target

        local topPlays = PF.OpportunityEngine.FindTopOpportunities()
        MarkVerifiedOpportunities(topPlays, verifiedInSession)
        Profitable_DB.lastTopPlays = topPlays

        if onUpdateCallback then
            onUpdateCallback(verifyIndex, #verifyQueue, target, topPlays)
        end
        if PF.SideWindow and PF.SideWindow.UpdateProgress then
            PF.SideWindow.UpdateProgress(verifyIndex, #verifyQueue, target)
        end

        -- Check if we can query the live AH right now
        if PF.AHVerifier.IsAuctionHouseOpen() then
            if _G.QueryAuctionItems and _G.CanSendAuctionQuery then
                if _G.CanSendAuctionQuery() then
                    SafeRegisterEvent(verifierFrame, "AUCTION_ITEM_LIST_UPDATE")
                    pcall(_G.QueryAuctionItems, target.name or "", nil, nil, 0, 0, 0, 0, false, -1, false)
                    -- Watchdog in case AUCTION_ITEM_LIST_UPDATE doesn't fire within 2.5s
                    C_Timer.After(2.5, function()
                        if isRunning and runToken == myToken and currentQueryItem == target then
                            ScheduleNextVerification(0.05)
                        end
                    end)
                    return
                else
                    -- Wait briefly for CanSendAuctionQuery() cooldown
                    verifyIndex = verifyIndex - 1
                    ScheduleNextVerification(0.25)
                    return
                end
            elseif _G.C_AuctionHouse and _G.C_AuctionHouse.SendSearchQuery then
                SafeRegisterEvent(verifierFrame, "COMMODITY_SEARCH_RESULTS_UPDATED")
                SafeRegisterEvent(verifierFrame, "ITEM_SEARCH_RESULTS_UPDATED")
                local itemKey = (_G.C_AuctionHouse.MakeItemKey and _G.C_AuctionHouse.MakeItemKey(target.itemId))
                    or { itemID = target.itemId, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 }
                local sortOrder = (_G.Enum and _G.Enum.AuctionHouseSortOrder and _G.Enum.AuctionHouseSortOrder.Price) or 0
                pcall(_G.C_AuctionHouse.SendSearchQuery, itemKey, { { sortOrder = sortOrder, reverseSort = false } }, false)
                C_Timer.After(2.0, function()
                    if isRunning and runToken == myToken and currentQueryItem == target then
                        ScheduleNextVerification(0.05)
                    end
                end)
                return
            end
        end

        -- If AH query API is not active, mark from existing cache and advance immediately
        verifiedInSession[target.itemId] = true
        ScheduleNextVerification(0.01)
    end)
end

function PF.AHVerifier.StartDiscoveryAndVerification(callbacks)
    callbacks = callbacks or {}
    onUpdateCallback = callbacks.onUpdate
    onFinishCallback = callbacks.onFinish

    isRunning = true
    runToken = runToken + 1
    startTime = GetTime()
    verifiedInSession = {}
    verifyQueue = {}
    verifyIndex = 0
    currentQueryItem = nil

    local settings = (Profitable_DB and Profitable_DB.settings) or {}
    local candidateCount = settings.verifyCandidateCount or 10

    -- Step 1: Discover top candidate plays from PCF_DB + known character recipes
    local initialTop = PF.OpportunityEngine.FindTopOpportunities(nil, nil, candidateCount)
    currentCandidates = initialTop
    Profitable_DB = Profitable_DB or {}
    Profitable_DB.lastTopPlays = PF.OpportunityEngine.FindTopOpportunities()

    -- Step 2: Build prioritized verification queue of unique AH items across the top candidates
    local queuedIds = {}
    local function EnqueueItem(itemId, itemName)
        if not itemId or itemId <= 0 or queuedIds[itemId] then return end
        if PF.VendorDatabase.IsVendorReagent(itemId) then return end
        queuedIds[itemId] = true
        local meta = PF.VendorDatabase.GetItemMetadata(itemId)
        local resolvedName = itemName or (meta and meta.name) or string.format("Item #%d", itemId)
        table.insert(verifyQueue, {
            itemId = itemId,
            name = resolvedName,
        })
    end

    for _, opp in ipairs(initialTop) do
        if opp.shoppingList then
            for _, shop in ipairs(opp.shoppingList) do
                if shop.source == "AH" then
                    EnqueueItem(shop.itemId, shop.name)
                end
            end
        end
        if opp.actionType == "CRAFT_AH" then
            EnqueueItem(opp.itemId, opp.itemName)
        end
    end

    if #verifyQueue == 0 or not PF.AHVerifier.IsAuctionHouseOpen() then
        for _, q in ipairs(verifyQueue) do
            verifiedInSession[q.itemId] = true
        end
        FinalizeRun("COMPLETE")
        return Profitable_DB.lastTopPlays
    end

    ScheduleNextVerification(0.05)
    return Profitable_DB.lastTopPlays
end

-- Fills the AH search bar and executes a live AH search for the given item
function PF.AHVerifier.SearchItemOnAH(itemId, itemName, itemLink)
    local meta = PF.VendorDatabase.GetItemMetadata(itemId, itemLink)
    local searchName = itemName or (meta and meta.name)
    if not searchName and type(itemLink) == "string" then
        searchName = itemLink:match("%[(.-)%]")
    end
    if not searchName or searchName == "" then
        print("|cffff5555[Profitable]|r Could not determine item name to search.")
        return false
    end

    -- 1. Legacy AuctionFrame (BrowseTab)
    if _G.AuctionFrame then
        if _G.AuctionFrameTab1 and _G.AuctionFrameTab1.Click and (not _G.AuctionFrameBrowse or not _G.AuctionFrameBrowse:IsShown()) then
            pcall(_G.AuctionFrameTab1.Click, _G.AuctionFrameTab1)
        end
        if _G.BrowseName and _G.BrowseName.SetText then
            pcall(_G.BrowseName.SetText, _G.BrowseName, searchName)
        end
        if _G.QueryAuctionItems and (not _G.CanSendAuctionQuery or _G.CanSendAuctionQuery()) then
            pcall(_G.QueryAuctionItems, searchName, nil, nil, 0, 0, 0, 0, false, -1, false)
            return true
        elseif _G.BrowseSearchButton and _G.BrowseSearchButton.Click then
            pcall(_G.BrowseSearchButton.Click, _G.BrowseSearchButton)
            return true
        end
    end

    -- 2. Modern AuctionHouseFrame
    if _G.AuctionHouseFrame then
        local searchBar = _G.AuctionHouseFrame.SearchBar
        if searchBar and searchBar.SearchBox and searchBar.SearchBox.SetText then
            pcall(searchBar.SearchBox.SetText, searchBar.SearchBox, searchName)
        end
        if searchBar and searchBar.SearchButton and searchBar.SearchButton.Click then
            pcall(searchBar.SearchButton.Click, searchBar.SearchButton)
            return true
        end
        if _G.C_AuctionHouse and _G.C_AuctionHouse.SendBrowseQuery then
            local sortOrder = (_G.Enum and _G.Enum.AuctionHouseSortOrder and _G.Enum.AuctionHouseSortOrder.Price) or 0
            pcall(_G.C_AuctionHouse.SendBrowseQuery, {
                searchString = searchName,
                sorts = { { sortOrder = sortOrder, reverseSort = false } },
                filters = {},
            })
            return true
        end
    end

    print(string.format("|cffff9900[Profitable]|r Open the Auction House to search for [%s].", searchName))
    return false
end

-- TSM-style One-Click Buyout Queue:
-- Buys the cheapest currently visible AH listing for itemId that is at or below maxUnitPrice
-- (or buys from an open NPC Merchant if the item is a Vendor reagent).
function PF.AHVerifier.BuyNextCheapListing(itemId, itemName, maxUnitPrice, neededQty)
    if not itemId or itemId <= 0 then return false end
    neededQty = math.max(1, math.floor(tonumber(neededQty) or 1))
    local playerGold = PF.Formatter.GetPlayerGold()

    -- 1. If Merchant window is open and sells this item, buy from Merchant
    if _G.GetMerchantNumItems and _G.GetMerchantItemInfo and _G.BuyMerchantItem then
        local okNum, numMerchant = pcall(_G.GetMerchantNumItems)
        if okNum and type(numMerchant) == "number" and numMerchant > 0 then
            for i = 1, numMerchant do
                local link = _G.GetMerchantItemLink and _G.GetMerchantItemLink(i)
                local mId = link and tonumber(link:match("item:(%d+)"))
                local _, mName, _, price, batchQty, numAvailable = pcall(_G.GetMerchantItemInfo, i)
                if mId == itemId or (not mId and mName and itemName and mName:lower() == itemName:lower()) then
                    batchQty = (batchQty and batchQty > 0) and batchQty or 1
                    local batches = math.max(1, math.ceil(neededQty / batchQty))
                    if numAvailable and numAvailable > 0 then
                        batches = math.min(batches, numAvailable)
                    end
                    pcall(_G.BuyMerchantItem, i, batches)
                    print(string.format("|cff00ff88[Profitable]|r Purchased %dx [%s] from Merchant.", batches * batchQty, itemName or mName or ("Item #" .. itemId)))
                    return true, batches * batchQty, (price or 0) * batches
                end
            end
        end
    end

    if not PF.AHVerifier.IsAuctionHouseOpen() then
        print("|cffff5555[Profitable]|r Open the Auction House first to buy listings.")
        return false
    end

    -- 2. Legacy Auction House Buyout Path
    if _G.GetNumAuctionItems and _G.GetAuctionItemInfo and _G.PlaceAuctionBid then
        local numBatch = _G.GetNumAuctionItems("list") or 0
        local bestIdx = nil
        local bestUnitPrice = nil
        local bestBuyout = nil
        local bestCount = nil
        local anyMatchOnPage = false

        for i = 1, numBatch do
            local name, _, count, _, _, _, _, minBid, _, buyoutPrice, _, _, _, _, _, _, rowItemId = _G.GetAuctionItemInfo("list", i)
            if (not rowItemId or rowItemId <= 0) and _G.GetAuctionItemLink then
                local link = _G.GetAuctionItemLink("list", i)
                if type(link) == "string" then
                    rowItemId = tonumber(link:match("item:(%d+)"))
                end
            end
            local matches = (rowItemId and rowItemId == itemId)
                or (not rowItemId and name and itemName and name:lower() == itemName:lower())

            if matches then
                anyMatchOnPage = true
                if buyoutPrice and buyoutPrice > 0 and count and count > 0 and buyoutPrice <= playerGold then
                    local unitPrice = math.floor(buyoutPrice / count)
                    if (not maxUnitPrice or unitPrice <= maxUnitPrice) then
                        if not bestUnitPrice or unitPrice < bestUnitPrice or (unitPrice == bestUnitPrice and count <= neededQty) then
                            bestIdx = i
                            bestUnitPrice = unitPrice
                            bestBuyout = buyoutPrice
                            bestCount = count
                        end
                    end
                end
            end
        end

        if not anyMatchOnPage then
            PF.AHVerifier.SearchItemOnAH(itemId, itemName)
            print(string.format("|cff00ff88[Profitable]|r Searching AH for [%s]... Click 'Buy Next' again once results load.", itemName or ("Item #" .. itemId)))
            return false, 0, 0, "SEARCH_STARTED"
        end

        if bestIdx and bestBuyout then
            if _G.SetSelectedAuctionItem then
                pcall(_G.SetSelectedAuctionItem, "list", bestIdx)
            end
            pcall(_G.PlaceAuctionBid, "list", bestIdx, bestBuyout)
            print(string.format(
                "|cff00ff88[Profitable]|r Buying %dx [%s] for %s (%s ea, max allowed %s ea).",
                bestCount,
                itemName or ("Item #" .. itemId),
                PF.Formatter.FormatMoney(bestBuyout),
                PF.Formatter.FormatMoney(bestUnitPrice),
                PF.Formatter.FormatMoney(maxUnitPrice or bestUnitPrice)
            ))
            return true, bestCount, bestBuyout, "BOUGHT"
        else
            print(string.format(
                "|cffff5555[Profitable]|r No listings on current page for [%s] at or below max price %s.",
                itemName or ("Item #" .. itemId),
                PF.Formatter.FormatMoney(maxUnitPrice or 0)
            ))
            return false, 0, 0, "NO_CHEAP_LISTING"
        end
    end

    -- 3. Modern C_AuctionHouse Commodity / Item Buyout Path
    if _G.C_AuctionHouse then
        if _G.C_AuctionHouse.GetNumCommoditySearchResults and _G.C_AuctionHouse.GetCommoditySearchResultInfo and _G.C_AuctionHouse.StartCommoditiesPurchase then
            local okNum, num = pcall(_G.C_AuctionHouse.GetNumCommoditySearchResults, itemId)
            if okNum and num and num > 0 then
                local okRow, row = pcall(_G.C_AuctionHouse.GetCommoditySearchResultInfo, itemId, 1)
                if okRow and type(row) == "table" and row.unitPrice and (not maxUnitPrice or row.unitPrice <= maxUnitPrice) then
                    local buyQty = math.min(neededQty, row.quantity or neededQty)
                    pcall(_G.C_AuctionHouse.StartCommoditiesPurchase, itemId, buyQty)
                    if _G.C_AuctionHouse.ConfirmCommoditiesPurchase then
                        pcall(_G.C_AuctionHouse.ConfirmCommoditiesPurchase, itemId, buyQty)
                    end
                    return true, buyQty, row.unitPrice * buyQty, "BOUGHT"
                end
            end
        end
        PF.AHVerifier.SearchItemOnAH(itemId, itemName)
        return false, 0, 0, "SEARCH_STARTED"
    end

    return false
end

function PF.AHVerifier.Init()
    if PF.AHVerifier._initialized then return end
    PF.AHVerifier._initialized = true

    verifierFrame:SetScript("OnEvent", function(_, event, arg1)
        if not isRunning or not currentQueryItem then
            return
        end

        local target = currentQueryItem
        if event == "AUCTION_ITEM_LIST_UPDATE" then
            CollectLegacyQueryResults(target)
            currentQueryItem = nil
            ScheduleNextVerification(0.10)
        elseif event == "COMMODITY_SEARCH_RESULTS_UPDATED" then
            if not arg1 or arg1 == target.itemId then
                CollectModernCommodityResults(target.itemId)
                currentQueryItem = nil
                ScheduleNextVerification(0.10)
            end
        elseif event == "ITEM_SEARCH_RESULTS_UPDATED" then
            CollectModernItemResults(target.itemId)
            currentQueryItem = nil
            ScheduleNextVerification(0.10)
        end
    end)

    PF.AHVerifier.frame = verifierFrame
end
