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
local onUpdateCallback = nil
local onFinishCallback = nil

-- ItemKeyInfo async callbacks: [itemId] = { callback1, callback2, ... }
local itemKeyCallbacks = {}

-- Exact itemKey cache per itemId (preserves non-zero itemLevel / itemSuffix for gear from BrowseResults)
local knownItemKeys = {}         -- [itemId] = itemKeyTable
local pendingBrowseResolve = nil -- { itemId, itemName, desiredQuantity }

-- Active / Pending Default AH UI Purchase State
local activeSearchItemId = nil
local activeSearchItemKey = nil
local pendingCommodityConfirm = nil -- { itemId, itemName, quantity, unitPrice, totalPrice, maxUnitPrice }
local purchasedAuctionIds = {}      -- [auctionID] = true (prevents bidding on the same auctionID twice)

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
    if _G.AuctionHouseFrame and (not _G.AuctionHouseFrame.IsShown or _G.AuctionHouseFrame:IsShown()) then
        return true
    end
    if _G.AuctionFrame and (not _G.AuctionFrame.IsShown or _G.AuctionFrame:IsShown()) then
        return true
    end
    return false
end

function PF.AHVerifier.IsRunning()
    return isRunning
end

-- Harvests exact itemKeys (including itemLevel and itemSuffix for green/blue gear)
-- from C_AuctionHouse.GetBrowseResults() whenever browse results arrive.
local function HarvestBrowseResultItemKeys(results)
    if type(results) ~= "table" then
        if _G.C_AuctionHouse and _G.C_AuctionHouse.GetBrowseResults then
            local ok, br = pcall(_G.C_AuctionHouse.GetBrowseResults)
            if ok and type(br) == "table" then
                results = br
            end
        end
    end
    if type(results) ~= "table" then return end

    local bestPriceById = {}
    for _, row in ipairs(results) do
        local key = row and row.itemKey
        local itemId = key and key.itemID
        local minPrice = row and row.minPrice
        local totalQty = row and row.totalQuantity
        if itemId and itemId > 0 and totalQty and totalQty > 0 then
            if not knownItemKeys[itemId] or (minPrice and minPrice > 0 and (not bestPriceById[itemId] or minPrice < bestPriceById[itemId])) then
                knownItemKeys[itemId] = key
                if minPrice and minPrice > 0 then
                    bestPriceById[itemId] = minPrice
                end
            end
        end
    end
end

function PF.AHVerifier.MakeItemKey(itemId)
    if itemId and knownItemKeys[itemId] then
        return knownItemKeys[itemId]
    end
    if _G.C_AuctionHouse and _G.C_AuctionHouse.MakeItemKey then
        local ok, key = pcall(_G.C_AuctionHouse.MakeItemKey, itemId)
        if ok and type(key) == "table" then
            return key
        end
    end
    return { itemID = itemId, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 }
end

local function PollPendingItemKeys()
    if not _G.C_AuctionHouse or not _G.C_AuctionHouse.GetItemKeyInfo then
        return
    end
    local anyRemaining = false
    for itemId, callbacks in pairs(itemKeyCallbacks) do
        local key = PF.AHVerifier.MakeItemKey(itemId)
        local ok, info = pcall(_G.C_AuctionHouse.GetItemKeyInfo, key)
        if ok and info then
            itemKeyCallbacks[itemId] = nil
            for _, cb in ipairs(callbacks) do
                pcall(cb, key, info)
            end
        else
            anyRemaining = true
        end
    end
    if not anyRemaining and verifierFrame.SetScript then
        verifierFrame:SetScript("OnUpdate", nil)
    end
end

function PF.AHVerifier.WithItemKeyInfo(itemId, callback)
    if not itemId or itemId <= 0 or type(callback) ~= "function" then
        return false
    end

    local itemKey = PF.AHVerifier.MakeItemKey(itemId)
    if not _G.C_AuctionHouse or not _G.C_AuctionHouse.GetItemKeyInfo then
        callback(itemKey, nil)
        return true
    end

    local ok, info = pcall(_G.C_AuctionHouse.GetItemKeyInfo, itemKey)
    if ok and info then
        callback(itemKey, info)
        return true
    end

    itemKeyCallbacks[itemId] = itemKeyCallbacks[itemId] or {}
    table.insert(itemKeyCallbacks[itemId], callback)
    SafeRegisterEvent(verifierFrame, "ITEM_KEY_ITEM_INFO_RECEIVED")
    if verifierFrame.SetScript then
        verifierFrame:SetScript("OnUpdate", PollPendingItemKeys)
    end
    return false
end

function PF.AHVerifier.GetAppropriateSorts(itemKeyInfo)
    if itemKeyInfo and itemKeyInfo.isCommodity == false then
        return { { sortOrder = 4, reverseSort = false } }
    end
    return { { sortOrder = 0, reverseSort = false } }
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

    local topPlays, _, honorableMentions = PF.OpportunityEngine.FindTopOpportunities()
    MarkVerifiedOpportunities(topPlays, verifiedInSession)
    MarkVerifiedOpportunities(honorableMentions, verifiedInSession)

    Profitable_DB = Profitable_DB or {}
    Profitable_DB.lastTopPlays = topPlays
    Profitable_DB.lastHonorableMentions = honorableMentions

    if onFinishCallback then
        onFinishCallback(topPlays, reason or "COMPLETE", honorableMentions)
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

local function CollectModernItemResults(itemId, itemKey)
    if not _G.C_AuctionHouse or not _G.C_AuctionHouse.GetNumItemSearchResults or not _G.C_AuctionHouse.GetItemSearchResultInfo then
        return false
    end
    if type(itemKey) == "table" and itemKey.itemID then
        knownItemKeys[itemKey.itemID] = itemKey
        activeSearchItemKey = itemKey
    end
    itemKey = itemKey or activeSearchItemKey or PF.AHVerifier.MakeItemKey(itemId)
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

        local topPlays, _, honorableMentions = PF.OpportunityEngine.FindTopOpportunities()
        MarkVerifiedOpportunities(topPlays, verifiedInSession)
        MarkVerifiedOpportunities(honorableMentions, verifiedInSession)
        Profitable_DB.lastTopPlays = topPlays
        Profitable_DB.lastHonorableMentions = honorableMentions

        if onUpdateCallback then
            onUpdateCallback(verifyIndex, #verifyQueue, target, topPlays)
        end
        if PF.SideWindow and PF.SideWindow.UpdateProgress then
            PF.SideWindow.UpdateProgress(verifyIndex, #verifyQueue, target)
        end

        if PF.AHVerifier.IsAuctionHouseOpen() then
            if _G.QueryAuctionItems and _G.CanSendAuctionQuery and (not _G.AuctionHouseFrame or not _G.AuctionHouseFrame:IsShown()) then
                if _G.CanSendAuctionQuery() then
                    SafeRegisterEvent(verifierFrame, "AUCTION_ITEM_LIST_UPDATE")
                    pcall(_G.QueryAuctionItems, target.name or "", nil, nil, 0, 0, 0, 0, false, -1, false)
                    C_Timer.After(2.5, function()
                        if isRunning and runToken == myToken and currentQueryItem == target then
                            ScheduleNextVerification(0.05)
                        end
                    end)
                    return
                else
                    verifyIndex = verifyIndex - 1
                    ScheduleNextVerification(0.25)
                    return
                end
            elseif _G.C_AuctionHouse and _G.C_AuctionHouse.SendSearchQuery then
                if _G.C_AuctionHouse.IsThrottledMessageSystemReady and not _G.C_AuctionHouse.IsThrottledMessageSystemReady() then
                    verifyIndex = verifyIndex - 1
                    ScheduleNextVerification(0.25)
                    return
                end
                SafeRegisterEvent(verifierFrame, "COMMODITY_SEARCH_RESULTS_UPDATED")
                SafeRegisterEvent(verifierFrame, "ITEM_SEARCH_RESULTS_UPDATED")
                PF.AHVerifier.WithItemKeyInfo(target.itemId, function(itemKey, itemKeyInfo)
                    if not isRunning or runToken ~= myToken or currentQueryItem ~= target then return end
                    local sorts = PF.AHVerifier.GetAppropriateSorts(itemKeyInfo)
                    local isItem = (itemKeyInfo and itemKeyInfo.isCommodity == false)
                    pcall(_G.C_AuctionHouse.SendSearchQuery, itemKey, sorts, isItem)
                end)
                C_Timer.After(2.5, function()
                    if isRunning and runToken == myToken and currentQueryItem == target then
                        ScheduleNextVerification(0.05)
                    end
                end)
                return
            end
        end

        verifiedInSession[target.itemId] = true
        ScheduleNextVerification(0.01)
    end)
end

function PF.AHVerifier.StartDiscoveryAndVerification(callbacks)
    callbacks = callbacks or {}
    onUpdateCallback = callbacks.onUpdate
    onFinishCallback = callbacks.onFinish

    HarvestBrowseResultItemKeys()

    isRunning = true
    runToken = runToken + 1
    startTime = GetTime()
    verifiedInSession = {}
    verifyQueue = {}
    verifyIndex = 0
    currentQueryItem = nil

    local settings = (Profitable_DB and Profitable_DB.settings) or {}
    local candidateCount = settings.verifyCandidateCount or 10

    local initialTop, _, initialHM = PF.OpportunityEngine.FindTopOpportunities(nil, nil, candidateCount)
    local top5, _, hm = PF.OpportunityEngine.FindTopOpportunities()
    Profitable_DB = Profitable_DB or {}
    Profitable_DB.lastTopPlays = top5
    Profitable_DB.lastHonorableMentions = hm

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

    local function EnqueuePlayList(list)
        if type(list) ~= "table" then return end
        for _, opp in ipairs(list) do
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
    end

    EnqueuePlayList(initialTop)
    EnqueuePlayList(initialHM)

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

-- Sets the quantity in the default Blizzard AuctionHouseFrame.CommoditiesBuyFrame
local function SetDefaultCommoditiesUIQuantity(desiredQuantity)
    local ahFrame = _G.AuctionHouseFrame
    local commFrame = ahFrame and ahFrame.CommoditiesBuyFrame
    if not commFrame or not commFrame.BuyDisplay then return end

    local qInput = commFrame.BuyDisplay.QuantityInput
    if qInput then
        if qInput.SetQuantity then
            pcall(qInput.SetQuantity, qInput, desiredQuantity)
        elseif qInput.InputBox then
            if qInput.InputBox.SetNumber then
                pcall(qInput.InputBox.SetNumber, qInput.InputBox, desiredQuantity)
            elseif qInput.InputBox.SetText then
                pcall(qInput.InputBox.SetText, qInput.InputBox, tostring(desiredQuantity))
            end
        end
    end
    if commFrame.OnQuantityChanged then
        pcall(commFrame.OnQuantityChanged, commFrame)
    elseif commFrame.BuyDisplay.OnQuantityChanged then
        pcall(commFrame.BuyDisplay.OnQuantityChanged, commFrame.BuyDisplay)
    end
end

local function OpenItemKeyInDefaultAH(itemId, itemKey, itemKeyInfo, desiredQuantity)
    if not _G.AuctionHouseFrame then return end
    activeSearchItemId = itemId
    activeSearchItemKey = itemKey
    knownItemKeys[itemId] = itemKey

    local minPrice = (PF.OpportunityEngine and PF.OpportunityEngine.ResolveAHPrice and PF.OpportunityEngine.ResolveAHPrice(itemId)) or 0

    -- SelectBrowseResult automatically switches AuctionHouseFrame into CommoditiesBuyFrame or ItemBuyFrame
    -- AND sends the internal C_AuctionHouse.SendSearchQuery for that itemKey!
    -- IMPORTANT: Do NOT call C_AuctionHouse.SendSearchQuery a second time if SelectBrowseResult exists,
    -- because sending two throttled queries on the same tick causes C_AuctionHouse to drop the message!
    if _G.AuctionHouseFrame.SelectBrowseResult then
        pcall(_G.AuctionHouseFrame.SelectBrowseResult, _G.AuctionHouseFrame, {
            itemKey = itemKey,
            minPrice = minPrice,
            totalQuantity = desiredQuantity,
        })
        _G.AuctionHouseFrame.displayMode = nil
        SetDefaultCommoditiesUIQuantity(desiredQuantity)
    elseif _G.C_AuctionHouse and _G.C_AuctionHouse.SendSearchQuery then
        local sorts = PF.AHVerifier.GetAppropriateSorts(itemKeyInfo)
        local isItem = (itemKeyInfo and itemKeyInfo.isCommodity == false)
        pcall(_G.C_AuctionHouse.SendSearchQuery, itemKey, sorts, isItem)
    end
end

-- Navigates the Default WoW: Forever Auction House UI (AuctionHouseFrame) directly into
-- the item's purchase view (CommoditiesBuyFrame or ItemBuyFrame).
-- For non-commodity gear (whose itemKey on the AH may have a non-zero itemLevel or itemSuffix),
-- if we don't yet have its exact browse itemKey, it resolves it from GetBrowseResults() first.
function PF.AHVerifier.SearchItemOnAH(itemId, itemName, itemLink, desiredQuantity)
    local meta = PF.VendorDatabase.GetItemMetadata(itemId, itemLink)
    local searchName = itemName or (meta and meta.name)
    if not searchName and type(itemLink) == "string" then
        searchName = itemLink:match("%[(.-)%]")
    end
    if (not searchName or searchName == "") and not itemId then
        print("|cffff5555[Profitable]|r Could not determine item to open.")
        return false
    end

    desiredQuantity = math.max(1, math.floor(tonumber(desiredQuantity) or 1))
    activeSearchItemId = itemId
    purchasedAuctionIds = {}

    -- 1. Legacy AuctionFrame (BrowseTab) fallback
    if _G.AuctionFrame and (not _G.AuctionHouseFrame or not _G.AuctionHouseFrame:IsShown()) then
        if _G.AuctionFrameTab1 and _G.AuctionFrameTab1.Click and (not _G.AuctionFrameBrowse or not _G.AuctionFrameBrowse:IsShown()) then
            pcall(_G.AuctionFrameTab1.Click, _G.AuctionFrameTab1)
        end
        if _G.BrowseName and _G.BrowseName.SetText and searchName then
            pcall(_G.BrowseName.SetText, _G.BrowseName, searchName)
        end
        if _G.QueryAuctionItems and (not _G.CanSendAuctionQuery or _G.CanSendAuctionQuery()) then
            pcall(_G.QueryAuctionItems, searchName or "", nil, nil, 0, 0, 0, 0, false, -1, false)
            return true
        elseif _G.BrowseSearchButton and _G.BrowseSearchButton.Click then
            pcall(_G.BrowseSearchButton.Click, _G.BrowseSearchButton)
            return true
        end
    end

    -- 2. Default WoW: Forever AuctionHouseFrame UI
    if _G.AuctionHouseFrame then
        HarvestBrowseResultItemKeys()

        local searchBar = _G.AuctionHouseFrame.SearchBar
        if searchBar and searchBar.SearchBox and searchBar.SearchBox.SetText and searchName then
            pcall(searchBar.SearchBox.SetText, searchBar.SearchBox, searchName)
        end

        if itemId and itemId > 0 and _G.C_AuctionHouse then
            SafeRegisterEvent(verifierFrame, "COMMODITY_SEARCH_RESULTS_UPDATED")
            SafeRegisterEvent(verifierFrame, "ITEM_SEARCH_RESULTS_UPDATED")
            SafeRegisterEvent(verifierFrame, "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
            SafeRegisterEvent(verifierFrame, "AUCTION_HOUSE_BROWSE_RESULTS_ADDED")

            PF.AHVerifier.WithItemKeyInfo(itemId, function(itemKey, itemKeyInfo)
                -- For non-commodity equipment (weapons/armor), if we don't yet have a specific itemKey
                -- from GetBrowseResults (which carries the exact itemLevel/itemSuffix listed on the AH),
                -- run a quick Browse query by name first so we open the exact itemKey that has listings!
                local isNonCommodity = (itemKeyInfo and itemKeyInfo.isCommodity == false)
                if isNonCommodity and not knownItemKeys[itemId] and searchName and _G.C_AuctionHouse.SendBrowseQuery then
                    pendingBrowseResolve = {
                        itemId = itemId,
                        itemName = searchName,
                        desiredQuantity = desiredQuantity,
                    }
                    pcall(_G.C_AuctionHouse.SendBrowseQuery, {
                        searchString = searchName,
                        sorts = {},
                        filters = {},
                    })
                    -- Fallback if browse results don't resolve a more specific key within 0.6s
                    C_Timer.After(0.6, function()
                        if pendingBrowseResolve and pendingBrowseResolve.itemId == itemId then
                            pendingBrowseResolve = nil
                            OpenItemKeyInDefaultAH(itemId, knownItemKeys[itemId] or itemKey, itemKeyInfo, desiredQuantity)
                        end
                    end)
                    return
                end

                OpenItemKeyInDefaultAH(itemId, knownItemKeys[itemId] or itemKey, itemKeyInfo, desiredQuantity)
            end)
            return true
        end

        if _G.C_AuctionHouse and _G.C_AuctionHouse.SendBrowseQuery and searchName then
            pcall(_G.C_AuctionHouse.SendBrowseQuery, {
                searchString = searchName,
                sorts = {},
                filters = {},
            })
            return true
        end
    end

    print(string.format("|cffff9900[Profitable]|r Open the Auction House to view [%s].", searchName or "Item"))
    return false
end

-- Computes how many units of a commodity are currently loaded at or below maxUnitPrice
local function GetLoadedQualifyingCommodityQty(itemId, maxUnitPrice, neededQty, playerGold)
    if not _G.C_AuctionHouse or not _G.C_AuctionHouse.GetNumCommoditySearchResults or not _G.C_AuctionHouse.GetCommoditySearchResultInfo then
        return 0, 0, 0
    end
    local okNum, num = pcall(_G.C_AuctionHouse.GetNumCommoditySearchResults, itemId)
    if not okNum or not num or num <= 0 then
        return 0, 0, 0
    end

    local totalAvailable = 0
    local buyQty = 0
    local totalCost = 0

    for i = 1, num do
        local okRow, row = pcall(_G.C_AuctionHouse.GetCommoditySearchResultInfo, itemId, i)
        if okRow and type(row) == "table" and row.unitPrice and row.unitPrice > 0 and row.quantity and row.quantity > 0 then
            totalAvailable = totalAvailable + row.quantity
            if not maxUnitPrice or row.unitPrice <= maxUnitPrice then
                local remNeeded = neededQty - buyQty
                if remNeeded > 0 then
                    local maxAffordable = (playerGold and playerGold > totalCost)
                        and math.floor((playerGold - totalCost) / row.unitPrice)
                        or row.quantity
                    local take = math.min(remNeeded, row.quantity, maxAffordable)
                    if take > 0 then
                        buyQty = buyQty + take
                        totalCost = totalCost + (take * row.unitPrice)
                    end
                end
            end
        end
    end

    return num, buyQty, totalCost
end

-- Finds the cheapest loaded non-commodity auction at or below maxUnitPrice
-- Checks both the cached/active itemKey AND the currently open AuctionHouseFrame.ItemBuyFrame.itemKey!
local function GetLoadedQualifyingItemAuction(itemId, maxUnitPrice, playerGold)
    if not _G.C_AuctionHouse or not _G.C_AuctionHouse.GetNumItemSearchResults or not _G.C_AuctionHouse.GetItemSearchResultInfo then
        return 0, nil, nil
    end

    local candidateKeys = {}
    if _G.AuctionHouseFrame and _G.AuctionHouseFrame.ItemBuyFrame and _G.AuctionHouseFrame.ItemBuyFrame.itemKey then
        local uiKey = _G.AuctionHouseFrame.ItemBuyFrame.itemKey
        if uiKey.itemID == itemId then
            table.insert(candidateKeys, uiKey)
        end
    end
    if activeSearchItemKey and activeSearchItemKey.itemID == itemId then
        table.insert(candidateKeys, activeSearchItemKey)
    end
    if knownItemKeys[itemId] then
        table.insert(candidateKeys, knownItemKeys[itemId])
    end
    table.insert(candidateKeys, { itemID = itemId, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 })

    local matchedKey = nil
    local num = 0
    for _, key in ipairs(candidateKeys) do
        local okNum, n = pcall(_G.C_AuctionHouse.GetNumItemSearchResults, key)
        if okNum and n and n > 0 then
            matchedKey = key
            num = n
            break
        end
    end

    if not matchedKey or num <= 0 then
        return 0, nil, nil
    end

    local bestResult = nil
    local bestUnitPrice = nil

    for i = 1, num do
        local okRow, row = pcall(_G.C_AuctionHouse.GetItemSearchResultInfo, matchedKey, i)
        if okRow and type(row) == "table" and not row.containsOwnerItem and not row.containsAccountItem then
            if not row.auctionID or not purchasedAuctionIds[row.auctionID] then
                local buyout = row.buyoutAmount
                local qty = (row.quantity and row.quantity > 0) and row.quantity or 1
                if buyout and buyout > 0 and (not playerGold or buyout <= playerGold) then
                    local unitPrice = math.floor(buyout / qty)
                    if not maxUnitPrice or unitPrice <= maxUnitPrice then
                        if not bestUnitPrice or unitPrice < bestUnitPrice then
                            bestUnitPrice = unitPrice
                            bestResult = row
                        end
                    end
                end
            end
        end
    end

    return num, bestResult, matchedKey
end

-- Automatically opens the next unpurchased AH item from the active opportunity in the default AH UI
function PF.AHVerifier.OpenNextNeededItemInDefaultAH(opp)
    if not PF.AHVerifier.IsAuctionHouseOpen() then return end
    opp = opp or (Profitable_DB and Profitable_DB.activePlay)
    if not opp or type(opp.shoppingList) ~= "table" then return end

    for _, item in ipairs(opp.shoppingList) do
        if item.source == "AH" then
            local inBags = PF.Formatter.GetInventoryCount(item.itemId, false)
            local rem = math.max(0, (item.totalQuantity or 1) - inBags)
            if rem > 0 then
                PF.AHVerifier.SearchItemOnAH(item.itemId, item.name, item.link, rem)
                return
            end
        end
    end
end

-- Returns the dynamic label for the "Buy Next" button in DetailWindow
function PF.AHVerifier.GetBuyButtonLabel(item)
    if not item then return "Buy Next" end
    if item.source == "Vendor" then
        return "Buy Vendor"
    end
    if pendingCommodityConfirm and pendingCommodityConfirm.itemId == item.itemId then
        return string.format("Confirm (%d)", pendingCommodityConfirm.quantity)
    end
    if _G.C_AuctionHouse then
        local numComm, buyQty = GetLoadedQualifyingCommodityQty(
            item.itemId,
            item.maxUnitPrice,
            math.max(1, item.remainingToBuy or item.totalQuantity or 1),
            PF.Formatter.GetPlayerGold()
        )
        if numComm > 0 and buyQty > 0 then
            return string.format("Buy %dx", buyQty)
        end
        local numItem, bestAuction = GetLoadedQualifyingItemAuction(
            item.itemId,
            item.maxUnitPrice,
            PF.Formatter.GetPlayerGold()
        )
        if numItem > 0 and bestAuction then
            return "Buy 1x"
        end
    end
    return "Buy Next"
end

-- Executes purchasing through the Default WoW: Forever Auction House UI:
-- IMPORTANT: Never call SearchItemOnAH / SendSearchQuery on the same click right before
-- StartCommoditiesPurchase or PlaceBid, because sending a search query consumes the single
-- C_AuctionHouse throttled message slot and causes the purchase packet to be dropped!
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
                    return true, batches * batchQty, (price or 0) * batches, "BOUGHT"
                end
            end
        end
    end

    if not PF.AHVerifier.IsAuctionHouseOpen() then
        print("|cffff5555[Profitable]|r Open the Auction House first to buy listings.")
        return false
    end

    -- 2. Legacy AuctionFrame Buyout Path (when Modern AuctionHouseFrame is not active)
    if _G.GetNumAuctionItems and _G.GetAuctionItemInfo and _G.PlaceAuctionBid and (not _G.AuctionHouseFrame or not _G.AuctionHouseFrame:IsShown()) then
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
                    if not maxUnitPrice or unitPrice <= maxUnitPrice then
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
            PF.AHVerifier.SearchItemOnAH(itemId, itemName, nil, neededQty)
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

    -- 3. Default WoW: Forever C_AuctionHouse + AuctionHouseFrame Path
    if _G.C_AuctionHouse then
        -- Step 3A: Confirm a pending commodity quote from StartCommoditiesPurchase
        if pendingCommodityConfirm and pendingCommodityConfirm.itemId == itemId then
            local conf = pendingCommodityConfirm
            pendingCommodityConfirm = nil

            if _G.C_AuctionHouse.ConfirmCommoditiesPurchase then
                pcall(_G.C_AuctionHouse.ConfirmCommoditiesPurchase, conf.itemId, conf.quantity)
            end

            print(string.format(
                "|cff00ff88[Profitable]|r Confirmed purchase of %dx [%s] for %s (%s ea)!",
                conf.quantity,
                conf.itemName or itemName or ("Item #" .. itemId),
                PF.Formatter.FormatMoney(conf.totalPrice or (conf.unitPrice * conf.quantity)),
                PF.Formatter.FormatMoney(conf.unitPrice or 0)
            ))
            if PF.DetailWindow and PF.DetailWindow.RefreshIfShown then
                PF.DetailWindow.RefreshIfShown()
            end
            return true, conf.quantity, conf.totalPrice or 0, "BOUGHT"
        end

        -- Step 3B: Commodity Search Results are ALREADY loaded for this itemId -> StartCommoditiesPurchase directly!
        local numComm, buyQty, estTotalCost = GetLoadedQualifyingCommodityQty(itemId, maxUnitPrice, neededQty, playerGold)
        if numComm > 0 then
            if buyQty <= 0 then
                print(string.format(
                    "|cffff5555[Profitable]|r No [%s] listings available at or below %s (within your gold).",
                    itemName or ("Item #" .. itemId),
                    PF.Formatter.FormatMoney(maxUnitPrice or 0)
                ))
                return false, 0, 0, "NO_CHEAP_LISTING"
            end

            if _G.C_AuctionHouse.IsThrottledMessageSystemReady and not _G.C_AuctionHouse.IsThrottledMessageSystemReady() then
                print("|cffff9900[Profitable]|r Auction House is busy — click again in a moment.")
                return false, 0, 0, "THROTTLED"
            end

            SetDefaultCommoditiesUIQuantity(buyQty)

            SafeRegisterEvent(verifierFrame, "COMMODITY_PRICE_UPDATED")
            SafeRegisterEvent(verifierFrame, "COMMODITY_PRICE_UNAVAILABLE")
            SafeRegisterEvent(verifierFrame, "COMMODITY_PURCHASE_SUCCEEDED")
            SafeRegisterEvent(verifierFrame, "COMMODITY_PURCHASE_FAILED")

            local avgEstUnit = math.floor((estTotalCost / buyQty) + 0.5)
            pendingCommodityConfirm = {
                itemId = itemId,
                itemName = itemName,
                quantity = buyQty,
                unitPrice = avgEstUnit,
                totalPrice = estTotalCost,
                maxUnitPrice = maxUnitPrice,
            }

            if _G.C_AuctionHouse.StartCommoditiesPurchase then
                pcall(_G.C_AuctionHouse.StartCommoditiesPurchase, itemId, buyQty)
            end

            print(string.format(
                "|cff00ff88[Profitable]|r Reserved %dx [%s] (~%s total, %s ea). Click 'Confirm (%d)' to complete buyout!",
                buyQty,
                itemName or ("Item #" .. itemId),
                PF.Formatter.FormatMoney(estTotalCost),
                PF.Formatter.FormatMoney(avgEstUnit),
                buyQty
            ))
            if PF.DetailWindow and PF.DetailWindow.RefreshIfShown then
                PF.DetailWindow.RefreshIfShown()
            end
            return true, buyQty, estTotalCost, "QUOTE_STARTED"
        end

        -- Step 3C: Non-Commodity Item Search Results are ALREADY loaded -> PlaceBid directly!
        local numItem, bestAuction = GetLoadedQualifyingItemAuction(itemId, maxUnitPrice, playerGold)
        if numItem > 0 then
            if not bestAuction or not bestAuction.auctionID or not bestAuction.buyoutAmount then
                print(string.format(
                    "|cffff5555[Profitable]|r No remaining [%s] listings available at or below %s.",
                    itemName or ("Item #" .. itemId),
                    PF.Formatter.FormatMoney(maxUnitPrice or 0)
                ))
                return false, 0, 0, "NO_CHEAP_LISTING"
            end

            if _G.C_AuctionHouse.IsThrottledMessageSystemReady and not _G.C_AuctionHouse.IsThrottledMessageSystemReady() then
                print("|cffff9900[Profitable]|r Auction House is busy — click again in a moment.")
                return false, 0, 0, "THROTTLED"
            end

            -- Select the auction in the Default Blizzard ItemBuyFrame if exposed, then call PlaceBid directly
            -- WITHOUT calling SearchItemOnAH (which would send a new search query and drop PlaceBid)!
            if _G.AuctionHouseFrame and _G.AuctionHouseFrame.ItemBuyFrame and _G.AuctionHouseFrame.ItemBuyFrame.SetAuction then
                pcall(_G.AuctionHouseFrame.ItemBuyFrame.SetAuction, _G.AuctionHouseFrame.ItemBuyFrame, bestAuction.auctionID)
            end

            if _G.C_AuctionHouse.PlaceBid then
                purchasedAuctionIds[bestAuction.auctionID] = true
                pcall(_G.C_AuctionHouse.PlaceBid, bestAuction.auctionID, bestAuction.buyoutAmount)
                local qty = (bestAuction.quantity and bestAuction.quantity > 0) and bestAuction.quantity or 1
                print(string.format(
                    "|cff00ff88[Profitable]|r Buying %dx [%s] (auction #%s) for %s!",
                    qty,
                    itemName or ("Item #" .. itemId),
                    tostring(bestAuction.auctionID),
                    PF.Formatter.FormatMoney(bestAuction.buyoutAmount)
                ))
                if PF.DetailWindow and PF.DetailWindow.RefreshIfShown then
                    PF.DetailWindow.RefreshIfShown()
                end
                return true, qty, bestAuction.buyoutAmount, "BOUGHT"
            end
        end

        -- Step 3D: Listings for this item aren't loaded yet — open the item in Default AuctionHouseFrame now!
        PF.AHVerifier.SearchItemOnAH(itemId, itemName, nil, neededQty)
        print(string.format(
            "|cff00ff88[Profitable]|r Opening [%s] (x%d) in the Auction House... Wait 1s for listings to appear, then click Buy!",
            itemName or ("Item #" .. itemId),
            neededQty
        ))
        return false, 0, 0, "OPENING_ITEM"
    end

    return false
end

function PF.AHVerifier.Init()
    if PF.AHVerifier._initialized then return end
    PF.AHVerifier._initialized = true

    SafeRegisterEvent(verifierFrame, "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    SafeRegisterEvent(verifierFrame, "AUCTION_HOUSE_BROWSE_RESULTS_ADDED")

    verifierFrame:SetScript("OnEvent", function(_, event, arg1, arg2)
        if event == "ITEM_KEY_ITEM_INFO_RECEIVED" then
            PollPendingItemKeys()
            return
        end

        if event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" or event == "AUCTION_HOUSE_BROWSE_RESULTS_ADDED" then
            HarvestBrowseResultItemKeys(type(arg1) == "table" and arg1 or nil)
            if pendingBrowseResolve then
                local req = pendingBrowseResolve
                if knownItemKeys[req.itemId] then
                    pendingBrowseResolve = nil
                    PF.AHVerifier.WithItemKeyInfo(req.itemId, function(resolvedKey, resolvedInfo)
                        OpenItemKeyInDefaultAH(req.itemId, knownItemKeys[req.itemId] or resolvedKey, resolvedInfo, req.desiredQuantity)
                    end)
                end
            end
            return
        end

        if event == "COMMODITY_PRICE_UPDATED" then
            local updatedUnitPrice, updatedTotalPrice = tonumber(arg1), tonumber(arg2)
            if pendingCommodityConfirm and updatedUnitPrice and updatedTotalPrice then
                pendingCommodityConfirm.unitPrice = updatedUnitPrice
                pendingCommodityConfirm.totalPrice = updatedTotalPrice
                if pendingCommodityConfirm.maxUnitPrice and updatedUnitPrice > pendingCommodityConfirm.maxUnitPrice then
                    if _G.C_AuctionHouse and _G.C_AuctionHouse.CancelCommoditiesPurchase then
                        pcall(_G.C_AuctionHouse.CancelCommoditiesPurchase)
                    end
                    print(string.format(
                        "|cffff5555[Profitable]|r Cancelled purchase: unit price jumped to %s (max profitable is %s).",
                        PF.Formatter.FormatMoney(updatedUnitPrice),
                        PF.Formatter.FormatMoney(pendingCommodityConfirm.maxUnitPrice)
                    ))
                    pendingCommodityConfirm = nil
                end
                if PF.DetailWindow and PF.DetailWindow.RefreshIfShown then
                    PF.DetailWindow.RefreshIfShown()
                end
            end
            return
        elseif event == "COMMODITY_PRICE_UNAVAILABLE" or event == "COMMODITY_PURCHASE_FAILED" then
            pendingCommodityConfirm = nil
            if PF.DetailWindow and PF.DetailWindow.RefreshIfShown then
                PF.DetailWindow.RefreshIfShown()
            end
            return
        elseif event == "COMMODITY_PURCHASE_SUCCEEDED" then
            pendingCommodityConfirm = nil
            if PF.DetailWindow and PF.DetailWindow.RefreshIfShown then
                PF.DetailWindow.RefreshIfShown()
            end
            return
        end

        if not isRunning then
            if event == "COMMODITY_SEARCH_RESULTS_UPDATED" then
                local itemId = tonumber(arg1) or activeSearchItemId
                if itemId then
                    CollectModernCommodityResults(itemId)
                    if PF.DetailWindow and PF.DetailWindow.RefreshIfShown then
                        PF.DetailWindow.RefreshIfShown()
                    end
                end
            elseif event == "ITEM_SEARCH_RESULTS_UPDATED" then
                local itemKey = type(arg1) == "table" and arg1 or nil
                local itemId = (itemKey and itemKey.itemID) or activeSearchItemId
                if itemId then
                    CollectModernItemResults(itemId, itemKey)
                    if PF.DetailWindow and PF.DetailWindow.RefreshIfShown then
                        PF.DetailWindow.RefreshIfShown()
                    end
                end
            end
            return
        end

        if not currentQueryItem then
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
            local keyId = (type(arg1) == "table" and arg1.itemID) or tonumber(arg1)
            if not keyId or keyId == target.itemId then
                CollectModernItemResults(target.itemId, type(arg1) == "table" and arg1 or nil)
                currentQueryItem = nil
                ScheduleNextVerification(0.10)
            end
        end
    end)

    PF.AHVerifier.frame = verifierFrame
end
