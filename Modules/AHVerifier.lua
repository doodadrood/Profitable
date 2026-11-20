local PF = _G.PF or {}
_G.PF = PF
_G.Profitable = PF

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
local browseResultsHarvested = false
local pendingBrowseResolve = nil -- { itemId, itemName, desiredQuantity }
local pollItemKeyElapsed = 0
local MAX_ORDERBOOK_ROWS = 60
local MAX_ORDERBOOK_QTY = 600
local MAX_VERIFY_QUEUE = 25

-- Active / Pending Default AH UI Purchase State
local activeSearchItemId = nil
local activeSearchItemKey = nil
local activeSearchDesiredQty = 1
local openSearchToken = 0
local pendingOpenItemKey = nil      -- { itemId, itemKey, itemKeyInfo, desiredQuantity, token }
local pendingSearchCheck = nil      -- { itemId, itemKey, itemKeyInfo, desiredQuantity, token, retries }
local pendingCommodityConfirm = nil -- { itemId, itemName, quantity, unitPrice, totalPrice, maxUnitPrice }
local inFlightCommodityPurchase = nil -- { itemId, itemName, quantity, unitPrice, totalPrice, sentAt }
local inFlightItemPurchases = {}      -- [auctionID] = { itemId, itemName, quantity, buyout, sentAt }
local purchaseDedupQueue = {}         -- FIFO { source = "EVENT"|"CHAT", itemId, qty, expiresAt }
local purchasedAuctionIds = {}        -- [auctionID] = true (prevents bidding on the same auctionID twice)
local PURCHASED_MAIL_TTL_SECONDS = 7200

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
-- from C_AuctionHouse.GetBrowseResults() once per browse batch (or incrementally from delta batches).
local function HarvestBrowseResultItemKeys(results)
    if type(results) ~= "table" then
        if browseResultsHarvested then
            return
        end
        if _G.C_AuctionHouse and _G.C_AuctionHouse.GetBrowseResults then
            local ok, br = pcall(_G.C_AuctionHouse.GetBrowseResults)
            if ok and type(br) == "table" then
                results = br
                browseResultsHarvested = true
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

local function ClearPendingItemKeyWatchers()
    if next(itemKeyCallbacks) == nil then
        pollItemKeyElapsed = 0
        SafeUnregisterEvent(verifierFrame, "ITEM_KEY_ITEM_INFO_RECEIVED")
        if verifierFrame.SetScript then
            verifierFrame:SetScript("OnUpdate", nil)
        end
    end
end

local function PollPendingItemKeys()
    if not _G.C_AuctionHouse or not _G.C_AuctionHouse.GetItemKeyInfo then
        itemKeyCallbacks = {}
        ClearPendingItemKeyWatchers()
        return
    end
    local now = (_G.GetTime and _G.GetTime()) or 0
    local ready = {}
    local expired = {}
    for itemId, entry in pairs(itemKeyCallbacks) do
        local key = PF.AHVerifier.MakeItemKey(itemId)
        local ok, info = pcall(_G.C_AuctionHouse.GetItemKeyInfo, key)
        if ok and info then
            table.insert(ready, { itemId = itemId, key = key, info = info, callbacks = entry.callbacks })
        elseif entry.expiresAt and now > entry.expiresAt then
            table.insert(expired, itemId)
        end
    end
    for _, itemId in ipairs(expired) do
        itemKeyCallbacks[itemId] = nil
    end
    for _, entry in ipairs(ready) do
        itemKeyCallbacks[entry.itemId] = nil
    end
    ClearPendingItemKeyWatchers()
    for _, entry in ipairs(ready) do
        for _, cb in ipairs(entry.callbacks) do
            pcall(cb, entry.key, entry.info)
        end
    end
    ClearPendingItemKeyWatchers()
end

local function OnUpdatePollPendingItemKeys(_, elapsed)
    pollItemKeyElapsed = pollItemKeyElapsed + (tonumber(elapsed) or 0)
    if pollItemKeyElapsed < 0.20 then
        return
    end
    pollItemKeyElapsed = 0
    PollPendingItemKeys()
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

    local now = (_G.GetTime and _G.GetTime()) or 0
    if not itemKeyCallbacks[itemId] then
        itemKeyCallbacks[itemId] = { callbacks = {}, expiresAt = now + 3.0 }
    else
        itemKeyCallbacks[itemId].expiresAt = now + 3.0
    end
    table.insert(itemKeyCallbacks[itemId].callbacks, callback)
    SafeRegisterEvent(verifierFrame, "ITEM_KEY_ITEM_INFO_RECEIVED")
    if verifierFrame.SetScript then
        pollItemKeyElapsed = 0
        verifierFrame:SetScript("OnUpdate", OnUpdatePollPendingItemKeys)
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
        unavailable = false,
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

-- Evicts an item from orderBookCache and PCF_DB.prices when a live AH check confirms
-- there are zero qualifying buyout listings (e.g. bid-only auctions or sold out).
function PF.AHVerifier.EvictUnavailableItem(itemId)
    if not itemId or itemId <= 0 then return end
    Profitable_DB = Profitable_DB or {}
    Profitable_DB.orderBookCache = Profitable_DB.orderBookCache or {}
    Profitable_DB.orderBookCache[itemId] = {
        timestamp = time(),
        listings = {},
        unavailable = true,
    }
    if _G.PCF_DB and type(_G.PCF_DB.prices) == "table" then
        _G.PCF_DB.prices[itemId] = nil
    end
end

local function IsBuyoutOnlyEnabled()
    if Profitable_DB and Profitable_DB.settings and Profitable_DB.settings.buyoutOnly == false then
        return false
    end
    return true
end

local function IsItemLiveVerified(itemId, verifiedItemMap)
    if not itemId or itemId <= 0 then return true end
    if verifiedItemMap and verifiedItemMap[itemId] == true then
        return true
    end
    local ob = Profitable_DB and Profitable_DB.orderBookCache and Profitable_DB.orderBookCache[itemId]
    if ob and not ob.unavailable and type(ob.listings) == "table" and #ob.listings > 0 and (time() - (ob.timestamp or 0)) <= 600 then
        return true
    end
    return false
end

local function MarkVerifiedOpportunities(opportunities, verifiedItemMap)
    if type(opportunities) ~= "table" then return end
    for _, opp in ipairs(opportunities) do
        local allVerified = true
        if opp.shoppingList then
            for _, shop in ipairs(opp.shoppingList) do
                if shop.source == "AH" then
                    if not IsItemLiveVerified(shop.itemId, verifiedItemMap) then
                        allVerified = false
                        break
                    end
                end
            end
        end
        if allVerified and opp.actionType == "CRAFT_AH" and opp.itemId then
            if not IsItemLiveVerified(opp.itemId, verifiedItemMap) then
                allVerified = false
            end
        elseif allVerified and (opp.actionType == "BUY_DE" or opp.actionType == "CRAFT_DE") and opp.targetMatId then
            if not IsItemLiveVerified(opp.targetMatId, verifiedItemMap) then
                allVerified = false
            end
        end
        opp.verified = allVerified
    end
end

PF.AHVerifier.MarkVerifiedOpportunities = MarkVerifiedOpportunities

local verifiedInSession = {}
local activeQueuedIds = {}
local activeForceLiveVerify = false
local activeFeedFreshWindow = false

local ACTION_VERIFY_TAGS = {
    VENDOR       = "Vendor",
    BUY_DE       = "DE",
    CRAFT_VENDOR = "Craft",
    CRAFT_AH     = "Craft",
    CRAFT_DE     = "Craft DE",
}

local function EnqueueVerificationItem(itemId, itemName, actionType)
    if not itemId or itemId <= 0 or activeQueuedIds[itemId] then return end
    if #verifyQueue >= MAX_VERIFY_QUEUE then return end
    if PF.VendorDatabase.IsVendorReagent(itemId) then return end
    activeQueuedIds[itemId] = true
    if not activeForceLiveVerify and activeFeedFreshWindow then
        local feedData = PF.MarketFeed and PF.MarketFeed.GetItemData and PF.MarketFeed.GetItemData(itemId)
        if feedData then
            -- Only allow opt-in MarketFeed skip if MarketFeed is actually the active price source
            -- (not overridden by a newer single-price PCF_DB scan/sniff entry!), and NEVER mark
            -- an unverified offline feed item in verifiedInSession.
            local pcfEntry = (_G.PCF_DB and type(_G.PCF_DB.prices) == "table") and _G.PCF_DB.prices[itemId] or nil
            local pcfTs = (pcfEntry and pcfEntry.minBuyout and pcfEntry.minBuyout > 0 and pcfEntry.lastUpdated) or 0
            if (feedData.timestamp or 0) >= pcfTs then
                return
            end
        end
    end
    local meta = PF.VendorDatabase.GetItemMetadata(itemId, nil, true)
    local resolvedName = itemName or (meta and meta.name) or string.format("Item #%d", itemId)
    table.insert(verifyQueue, {
        itemId = itemId,
        name = resolvedName,
        actionType = actionType,
        strategyTag = actionType and ACTION_VERIFY_TAGS[actionType] or nil,
    })
end

local function EnqueuePlayList(list)
    if type(list) ~= "table" then return end
    for _, opp in ipairs(list) do
        local aType = opp.actionType
        if opp.shoppingList then
            for _, shop in ipairs(opp.shoppingList) do
                if shop.source == "AH" then
                    EnqueueVerificationItem(shop.itemId, shop.name, aType)
                end
            end
        end
        if aType == "CRAFT_AH" then
            EnqueueVerificationItem(opp.itemId, opp.itemName, aType)
        elseif aType == "BUY_DE" or aType == "CRAFT_DE" then
            if opp.targetMatId then
                EnqueueVerificationItem(opp.targetMatId, opp.targetMatName, aType)
            end
            if opp.deBreakdown and type(opp.deBreakdown.drops) == "table" then
                for _, d in ipairs(opp.deBreakdown.drops) do
                    local matId = d.sellItemId or d.itemId
                    if matId then
                        EnqueueVerificationItem(matId, d.name, aType)
                    end
                end
            end
        end
    end
end

function PF.AHVerifier.RecalculateFromCache()
    local topPlays, allEvaluated, honorableMentions = PF.OpportunityEngine.FindTopOpportunities()
    MarkVerifiedOpportunities(topPlays, verifiedInSession)
    MarkVerifiedOpportunities(honorableMentions, verifiedInSession)
    MarkVerifiedOpportunities(allEvaluated, verifiedInSession)
    Profitable_DB = Profitable_DB or {}
    Profitable_DB.lastTopPlays = topPlays
    Profitable_DB.lastHonorableMentions = honorableMentions
    return topPlays, honorableMentions, allEvaluated
end

local function FinalizeRun(reason)
    isRunning = false
    currentQueryItem = nil
    runToken = runToken + 1
    itemKeyCallbacks = {}
    ClearPendingItemKeyWatchers()

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
    local buyoutOnly = IsBuyoutOnlyEnabled()
    local listings = {}
    local sawMatchingItem = false

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
        if matchesId or matchesName then
            sawMatchingItem = true
            local effectivePrice = (buyoutPrice and buyoutPrice > 0) and buyoutPrice or nil
            if not effectivePrice and not buyoutOnly then
                effectivePrice = (minBid and minBid > 0) and minBid or nil
            end
            if effectivePrice and effectivePrice > 0 and count and count > 0 then
                local unitPrice = math.floor(effectivePrice / count)
                if unitPrice > 0 then
                    table.insert(listings, { unitPrice = unitPrice, quantity = count })
                end
            end
        end
    end

    if #listings > 0 then
        PF.AHVerifier.RecordOrderBook(targetItem.itemId, listings)
        verifiedInSession[targetItem.itemId] = true
        return true
    end
    if sawMatchingItem then
        PF.AHVerifier.EvictUnavailableItem(targetItem.itemId)
    end
    return false
end

local function CollectModernCommodityResults(itemId)
    if not _G.C_AuctionHouse or not _G.C_AuctionHouse.GetNumCommoditySearchResults or not _G.C_AuctionHouse.GetCommoditySearchResultInfo then
        return false
    end
    local okNum, num = pcall(_G.C_AuctionHouse.GetNumCommoditySearchResults, itemId)
    if not okNum or not num or num <= 0 then
        if okNum and num == 0 then
            PF.AHVerifier.EvictUnavailableItem(itemId)
        end
        return false
    end
    local listings = {}
    local limit = math.min(num, MAX_ORDERBOOK_ROWS)
    local accumQty = 0
    for i = 1, limit do
        local okRow, row = pcall(_G.C_AuctionHouse.GetCommoditySearchResultInfo, itemId, i)
        if okRow and type(row) == "table" and row.unitPrice and row.unitPrice > 0 and row.quantity and row.quantity > 0 then
            local availQty = math.floor(row.quantity) - math.floor(tonumber(row.numOwnerItems) or 0)
            if availQty > 0 then
                table.insert(listings, { unitPrice = math.floor(row.unitPrice), quantity = availQty })
                accumQty = accumQty + availQty
                if accumQty >= MAX_ORDERBOOK_QTY then
                    break
                end
            end
        end
    end
    if #listings > 0 then
        PF.AHVerifier.RecordOrderBook(itemId, listings)
        verifiedInSession[itemId] = true
        return true
    end
    PF.AHVerifier.EvictUnavailableItem(itemId)
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
        if okNum and num == 0 then
            PF.AHVerifier.EvictUnavailableItem(itemId)
        end
        return false
    end
    local buyoutOnly = IsBuyoutOnlyEnabled()
    local listings = {}
    local limit = math.min(num, MAX_ORDERBOOK_ROWS)
    local accumQty = 0
    for i = 1, limit do
        local okRow, row = pcall(_G.C_AuctionHouse.GetItemSearchResultInfo, itemKey, i)
        if okRow and type(row) == "table" and not row.containsOwnerItem and not row.containsAccountItem then
            local buyout = (row.buyoutAmount and row.buyoutAmount > 0) and row.buyoutAmount or nil
            if not buyout and not buyoutOnly then
                buyout = row.bidAmount or row.minBid
            end
            local qty = (row.quantity and row.quantity > 0) and math.floor(row.quantity) or 1
            if buyout and buyout > 0 then
                -- In C_AuctionHouse.GetItemSearchResultInfo (non-commodity items), buyoutAmount is
                -- ALREADY the per-item buyout price for 1 auction, while quantity is the number of
                -- identical single-item auctions collapsed at that price (do NOT divide buyout by qty!).
                local unitPrice = math.floor(buyout)
                if unitPrice > 0 then
                    table.insert(listings, { unitPrice = unitPrice, quantity = qty })
                    accumQty = accumQty + qty
                    if accumQty >= MAX_ORDERBOOK_QTY then
                        break
                    end
                end
            end
        end
    end
    if #listings > 0 then
        PF.AHVerifier.RecordOrderBook(itemId, listings)
        verifiedInSession[itemId] = true
        return true
    end
    -- Listings exist on the AH (num > 0), but none have a buyout price (all bid-only)
    PF.AHVerifier.EvictUnavailableItem(itemId)
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
            if PF.AHVerifier.IsAuctionHouseOpen() and #verifyQueue < MAX_VERIFY_QUEUE and ShouldContinuePastTimeout() then
                local currentTop, _, currentHM = PF.OpportunityEngine.FindTopOpportunities()
                MarkVerifiedOpportunities(currentTop, verifiedInSession)
                MarkVerifiedOpportunities(currentHM, verifiedInSession)
                Profitable_DB.lastTopPlays = currentTop
                Profitable_DB.lastHonorableMentions = currentHM
                EnqueuePlayList(currentTop)
                EnqueuePlayList(currentHM)
            end
            if verifyIndex > #verifyQueue then
                FinalizeRun("COMPLETE")
                return
            end
        end

        local target = verifyQueue[verifyIndex]
        currentQueryItem = target

        -- Lightweight progress update only (never re-scan all 7,000+ AH items on every single verified item)
        if onUpdateCallback then
            onUpdateCallback(verifyIndex, #verifyQueue, target, Profitable_DB and Profitable_DB.lastTopPlays)
        elseif PF.SideWindow and PF.SideWindow.UpdateProgress then
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
                    if _G.C_AuctionHouse.IsThrottledMessageSystemReady and not _G.C_AuctionHouse.IsThrottledMessageSystemReady() then
                        currentQueryItem = nil
                        verifyIndex = math.max(0, verifyIndex - 1)
                        ScheduleNextVerification(0.25)
                        return
                    end
                    local sorts = PF.AHVerifier.GetAppropriateSorts(itemKeyInfo)
                    local isItem = (itemKeyInfo and itemKeyInfo.isCommodity == false)
                    pcall(_G.C_AuctionHouse.SendSearchQuery, itemKey, sorts, isItem)
                end)
                C_Timer.After(2.5, function()
                    if isRunning and runToken == myToken and currentQueryItem == target then
                        if target and target.itemId then
                            itemKeyCallbacks[target.itemId] = nil
                            ClearPendingItemKeyWatchers()
                        end
                        ScheduleNextVerification(0.05)
                    end
                end)
                return
            end
        end

        FinalizeRun("AH_CLOSED")
    end)
end

local function EnsureAuctionBuyViewOpen()
    if _G.InCombatLockdown and _G.InCombatLockdown() then return end
    local ah = _G.AuctionHouseFrame
    if not ah then return end
    local sellShown = (ah.CommoditiesSellFrame and ah.CommoditiesSellFrame.IsShown and ah.CommoditiesSellFrame:IsShown())
        or (ah.ItemSellFrame and ah.ItemSellFrame.IsShown and ah.ItemSellFrame:IsShown())
    if not sellShown then return end
    if ah.SetDisplayMode and _G.AuctionHouseFrameDisplayMode and _G.AuctionHouseFrameDisplayMode.Buy then
        pcall(ah.SetDisplayMode, ah, _G.AuctionHouseFrameDisplayMode.Buy)
    elseif ah.BuyTab and ah.BuyTab.Click then
        pcall(ah.BuyTab.Click, ah.BuyTab)
    end
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
    pendingOpenItemKey = nil
    pendingSearchCheck = nil

    local settings = (Profitable_DB and Profitable_DB.settings) or {}
    local candidateCount = settings.verifyCandidateCount or 10
    local forceLiveVerify = (callbacks.forceLiveVerify == true)
    local feedSkipAge = tonumber(settings.marketFeedVerifySkipSeconds) or 0
    local feedFreshWindow = (feedSkipAge > 0)
        and PF.MarketFeed and PF.MarketFeed.IsFresh and PF.MarketFeed.IsFresh(feedSkipAge)
        or false

    local topCount = settings.topCount or 5
    local initialTop, _, initialHM = PF.OpportunityEngine.FindTopOpportunities(nil, nil, math.max(candidateCount, topCount))
    local top5 = {}
    for i = 1, math.min(topCount, #initialTop) do
        top5[i] = initialTop[i]
    end
    Profitable_DB = Profitable_DB or {}
    Profitable_DB.lastTopPlays = top5
    Profitable_DB.lastHonorableMentions = initialHM

    activeQueuedIds = {}
    activeForceLiveVerify = forceLiveVerify
    activeFeedFreshWindow = feedFreshWindow

    EnqueuePlayList(initialTop)
    EnqueuePlayList(initialHM)

    if #verifyQueue == 0 or not PF.AHVerifier.IsAuctionHouseOpen() then
        FinalizeRun("COMPLETE")
        return Profitable_DB.lastTopPlays
    end

    EnsureAuctionBuyViewOpen()
    ScheduleNextVerification(0.05)
    return Profitable_DB.lastTopPlays
end

-- Sets the quantity in the default Blizzard AuctionHouseFrame.CommoditiesBuyFrame.
-- Only invoke OnQuantityChanged once commodity listings are loaded so we never interfere
-- with an in-flight search query while CommoditiesBuyFrame is still "Searching...".
local function SetDefaultCommoditiesUIQuantity(desiredQuantity, triggerChangeHandler)
    if _G.InCombatLockdown and _G.InCombatLockdown() then return end
    local ahFrame = _G.AuctionHouseFrame
    local commFrame = ahFrame and ahFrame.CommoditiesBuyFrame
    if not commFrame or not commFrame.BuyDisplay then return end

    local qInput = commFrame.BuyDisplay.QuantityInput
    if qInput then
        if qInput.SetQuantity and triggerChangeHandler then
            pcall(qInput.SetQuantity, qInput, desiredQuantity)
        elseif qInput.InputBox then
            if qInput.InputBox.SetNumber then
                pcall(qInput.InputBox.SetNumber, qInput.InputBox, desiredQuantity)
            elseif qInput.InputBox.SetText then
                pcall(qInput.InputBox.SetText, qInput.InputBox, tostring(desiredQuantity))
            end
        elseif qInput.SetQuantity then
            pcall(qInput.SetQuantity, qInput, desiredQuantity)
        end
    end
    if triggerChangeHandler then
        if commFrame.OnQuantityChanged then
            pcall(commFrame.OnQuantityChanged, commFrame)
        elseif commFrame.BuyDisplay.OnQuantityChanged then
            pcall(commFrame.BuyDisplay.OnQuantityChanged, commFrame.BuyDisplay)
        end
    end
end

local OpenItemKeyInDefaultAH
local ScheduleSearchStallWatchdog

local function FlushPendingOpenItemKey()
    if not pendingOpenItemKey then return end
    if isRunning or not PF.AHVerifier.IsAuctionHouseOpen() then
        return
    end
    if _G.C_AuctionHouse and _G.C_AuctionHouse.IsThrottledMessageSystemReady and not _G.C_AuctionHouse.IsThrottledMessageSystemReady() then
        return
    end
    local req = pendingOpenItemKey
    pendingOpenItemKey = nil
    if req.token ~= openSearchToken then
        return
    end
    OpenItemKeyInDefaultAH(req.itemId, req.itemKey, req.itemKeyInfo, req.desiredQuantity, req.token)
end

ScheduleSearchStallWatchdog = function(checkRef, delaySeconds)
    if not checkRef or not _G.C_Timer or not _G.C_Timer.After then return end
    _G.C_Timer.After(delaySeconds or 1.0, function()
        if isRunning or not pendingSearchCheck or pendingSearchCheck ~= checkRef or checkRef.token ~= openSearchToken then
            return
        end
        if not PF.AHVerifier.IsAuctionHouseOpen() or not _G.C_AuctionHouse or not _G.C_AuctionHouse.SendSearchQuery then
            pendingSearchCheck = nil
            return
        end
        if _G.C_AuctionHouse.IsThrottledMessageSystemReady and not _G.C_AuctionHouse.IsThrottledMessageSystemReady() then
            if checkRef.retries < 3 then
                checkRef.retries = checkRef.retries + 1
                ScheduleSearchStallWatchdog(checkRef, 0.35)
            else
                pendingSearchCheck = nil
            end
            return
        end

        -- Stall recovery: Blizzard's CommoditiesBuyFrame / ItemBuyFrame never received search results
        -- (e.g. its initial internal query was dropped by throttle), so re-send the search query cleanly!
        local sorts = PF.AHVerifier.GetAppropriateSorts(checkRef.itemKeyInfo)
        local isItem = (checkRef.itemKeyInfo and checkRef.itemKeyInfo.isCommodity == false)
        pcall(_G.C_AuctionHouse.SendSearchQuery, checkRef.itemKey, sorts, isItem)

        checkRef.retries = (checkRef.retries or 0) + 1
        if checkRef.retries < 2 then
            ScheduleSearchStallWatchdog(checkRef, 1.5)
        else
            pendingSearchCheck = nil
        end
    end)
end

OpenItemKeyInDefaultAH = function(itemId, itemKey, itemKeyInfo, desiredQuantity, existingToken)
    if not _G.AuctionHouseFrame then return end
    if _G.InCombatLockdown and _G.InCombatLockdown() then return end

    local myToken = existingToken
    if not myToken then
        openSearchToken = openSearchToken + 1
        myToken = openSearchToken
    end

    activeSearchItemId = itemId
    activeSearchItemKey = itemKey
    activeSearchDesiredQty = desiredQuantity or 1
    knownItemKeys[itemId] = itemKey

    -- Never send SelectBrowseResult / SendSearchQuery while the C_AuctionHouse throttle system is busy
    -- (e.g. right after confirming a purchase or finishing another query), otherwise Blizzard's internal
    -- search packet gets silently dropped and CommoditiesBuyFrame sits on "Searching..." indefinitely!
    if _G.C_AuctionHouse and _G.C_AuctionHouse.IsThrottledMessageSystemReady and not _G.C_AuctionHouse.IsThrottledMessageSystemReady() then
        pendingOpenItemKey = {
            itemId = itemId,
            itemKey = itemKey,
            itemKeyInfo = itemKeyInfo,
            desiredQuantity = desiredQuantity,
            token = myToken,
        }
        SafeRegisterEvent(verifierFrame, "AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
        if _G.C_Timer and _G.C_Timer.After then
            _G.C_Timer.After(0.25, function()
                if pendingOpenItemKey and pendingOpenItemKey.token == myToken then
                    FlushPendingOpenItemKey()
                end
            end)
        end
        return
    end

    pendingOpenItemKey = nil
    local minPrice = (PF.OpportunityEngine and PF.OpportunityEngine.ResolveAHPrice and PF.OpportunityEngine.ResolveAHPrice(itemId)) or 0

    local checkRef = {
        itemId = itemId,
        itemKey = itemKey,
        itemKeyInfo = itemKeyInfo,
        desiredQuantity = desiredQuantity,
        token = myToken,
        retries = 0,
    }
    pendingSearchCheck = checkRef

    -- SelectBrowseResult switches AuctionHouseFrame into CommoditiesBuyFrame or ItemBuyFrame
    -- AND sends the internal C_AuctionHouse.SendSearchQuery for that itemKey.
    -- IMPORTANT:
    -- 1. Do NOT wipe AuctionHouseFrame.displayMode = nil (doing so corrupts Blizzard's displayMode tracking
    --    and can leave CommoditiesBuyFrame stuck on "Searching..."!).
    -- 2. Do NOT call SendSearchQuery a second time on the same tick if SelectBrowseResult exists;
    --    instead let our 1.0s stall watchdog recover automatically if no search result event arrives.
    local ahFrame = _G.AuctionHouseFrame
    local alreadyShowingSameCommodity = ahFrame.CommoditiesBuyFrame
        and ahFrame.CommoditiesBuyFrame.IsShown and ahFrame.CommoditiesBuyFrame:IsShown()
        and ahFrame.CommoditiesBuyFrame.BuyList
        and ahFrame.CommoditiesBuyFrame.BuyList.itemID == itemId

    if alreadyShowingSameCommodity and _G.C_AuctionHouse and _G.C_AuctionHouse.SendSearchQuery then
        local sorts = PF.AHVerifier.GetAppropriateSorts(itemKeyInfo)
        pcall(_G.C_AuctionHouse.SendSearchQuery, itemKey, sorts, false)
        SetDefaultCommoditiesUIQuantity(desiredQuantity, false)
    elseif ahFrame.SelectBrowseResult then
        pcall(ahFrame.SelectBrowseResult, ahFrame, {
            itemKey = itemKey,
            minPrice = minPrice,
            totalQuantity = desiredQuantity,
        })
        SetDefaultCommoditiesUIQuantity(desiredQuantity, false)
    elseif _G.C_AuctionHouse and _G.C_AuctionHouse.SendSearchQuery then
        local sorts = PF.AHVerifier.GetAppropriateSorts(itemKeyInfo)
        local isItem = (itemKeyInfo and itemKeyInfo.isCommodity == false)
        pcall(_G.C_AuctionHouse.SendSearchQuery, itemKey, sorts, isItem)
    end

    ScheduleSearchStallWatchdog(checkRef, 0.8)
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
            local availQty = math.floor(row.quantity) - math.floor(tonumber(row.numOwnerItems) or 0)
            if availQty > 0 then
                totalAvailable = totalAvailable + availQty
                if not maxUnitPrice or row.unitPrice <= maxUnitPrice then
                    local remNeeded = neededQty - buyQty
                    if remNeeded > 0 then
                        local maxAffordable = (playerGold and playerGold > totalCost)
                            and math.floor((playerGold - totalCost) / row.unitPrice)
                            or availQty
                        local take = math.min(remNeeded, availQty, maxAffordable)
                        if take > 0 then
                            buyQty = buyQty + take
                            totalCost = totalCost + (take * row.unitPrice)
                        end
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
                if buyout and buyout > 0 and (not playerGold or buyout <= playerGold) then
                    local unitPrice = math.floor(buyout)
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

    if PF.OpportunityEngine and PF.OpportunityEngine.ComputeLiveInventoryState then
        PF.OpportunityEngine.ComputeLiveInventoryState(opp)
    end

    for _, item in ipairs(opp.shoppingList) do
        if item.source == "AH" then
            local rem = item.remainingToBuy
            if rem == nil then
                local inBags = PF.Formatter.GetInventoryCount(item.itemId, false)
                rem = math.max(0, (item.totalQuantity or 1) - inBags)
            end
            if rem > 0 then
                PF.AHVerifier.SearchItemOnAH(item.itemId, item.name, item.link, rem)
                return
            end
        end
    end
end

local function GetCharPurchasedMailTable(createIfMissing)
    if type(Profitable_DB) ~= "table" then return nil end
    if type(Profitable_DB.purchasedInMail) ~= "table" then
        if not createIfMissing then return nil end
        Profitable_DB.purchasedInMail = {}
    end
    local charKey = PF.GetCharacterKey()
    if type(Profitable_DB.purchasedInMail[charKey]) ~= "table" then
        if not createIfMissing then return nil end
        Profitable_DB.purchasedInMail[charKey] = {}
    end
    return Profitable_DB.purchasedInMail[charKey]
end

local function PrunePurchaseDedup(now)
    local kept = {}
    for _, entry in ipairs(purchaseDedupQueue) do
        if entry.expiresAt and entry.expiresAt > now then
            table.insert(kept, entry)
        end
    end
    purchaseDedupQueue = kept
end

function PF.AHVerifier.ClearPurchasedTracker(itemId)
    local tbl = GetCharPurchasedMailTable(false)
    if tbl then
        if itemId then
            tbl[itemId] = nil
        else
            local charKey = PF.GetCharacterKey()
            Profitable_DB.purchasedInMail[charKey] = {}
        end
    end
    if not itemId then
        inFlightCommodityPurchase = nil
        inFlightItemPurchases = {}
        purchaseDedupQueue = {}
    end
end

-- Returns the server-confirmed purchased quantity (and actual copper spent) currently
-- awaiting mailbox pickup, automatically decrementing as items arrive in bags on loot.
function PF.AHVerifier.GetPurchasedInMailInfo(itemId)
    if not itemId or itemId <= 0 then return 0, 0 end
    local tbl = GetCharPurchasedMailTable(false)
    if not tbl then return 0, 0 end
    local entry = tbl[itemId]
    if type(entry) ~= "table" or (entry.count or 0) <= 0 then
        tbl[itemId] = nil
        return 0, 0
    end
    local now = (_G.time and _G.time()) or 0
    if (now - (entry.updatedAt or 0)) > PURCHASED_MAIL_TTL_SECONDS then
        tbl[itemId] = nil
        return 0, 0
    end
    local currentBags = PF.Formatter.GetInventoryCount(itemId, false)
    if type(entry.lastBagCount) == "number" and currentBags > entry.lastBagCount then
        local oldCount = entry.count or 0
        local gained = currentBags - entry.lastBagCount
        local newCount = math.max(0, oldCount - gained)
        if type(entry.spentCopper) == "number" and entry.spentCopper > 0 and oldCount > 0 then
            entry.spentCopper = math.floor((entry.spentCopper * (newCount / oldCount)) + 0.5)
        end
        entry.count = newCount
    end
    entry.lastBagCount = currentBags
    if entry.count <= 0 then
        tbl[itemId] = nil
        return 0, 0
    end
    return entry.count, tonumber(entry.spentCopper) or 0
end

function PF.AHVerifier.GetPurchasedInMailCount(itemId)
    local count = PF.AHVerifier.GetPurchasedInMailInfo(itemId)
    return count
end

-- Records a server-confirmed AH purchase (waiting in mailbox) with symmetric FIFO
-- deduplication between API purchase events ("EVENT") and CHAT_MSG_SYSTEM ("CHAT").
function PF.AHVerifier.RecordConfirmedPurchase(itemId, itemName, qty, source, spentCopper)
    qty = math.floor(tonumber(qty) or 0)
    if not itemId or itemId <= 0 or qty <= 0 then
        return false
    end
    local now = (_G.GetTime and _G.GetTime()) or (_G.time and _G.time()) or 0
    PrunePurchaseDedup(now)

    if source == "EVENT" or source == "CHAT" then
        local opposite = (source == "EVENT") and "CHAT" or "EVENT"
        for idx, tok in ipairs(purchaseDedupQueue) do
            if tok.source == opposite and tok.itemId == itemId and tok.qty == qty then
                table.remove(purchaseDedupQueue, idx)
                return false
            end
        end
        table.insert(purchaseDedupQueue, {
            source = source,
            itemId = itemId,
            qty = qty,
            expiresAt = now + 6.0,
        })
    end

    local tbl = GetCharPurchasedMailTable(true)
    if not tbl then return false end

    local existingCount, existingSpent = PF.AHVerifier.GetPurchasedInMailInfo(itemId)
    local currentBags = PF.Formatter.GetInventoryCount(itemId, false)
    local addedSpent = (type(spentCopper) == "number" and spentCopper > 0) and math.floor(spentCopper) or 0
    tbl[itemId] = {
        count = existingCount + qty,
        spentCopper = existingSpent + addedSpent,
        itemName = itemName,
        updatedAt = (_G.time and _G.time()) or 0,
        lastBagCount = currentBags,
    }

    -- Lock target quantity & record actual spend on activePlay so mid-play revalidation
    -- never shrinks an in-progress craft (e.g., 3x -> 2x) after earlier reagents are bought!
    local activeOpp = Profitable_DB and Profitable_DB.activePlay
    if type(activeOpp) == "table" and type(activeOpp.shoppingList) == "table" then
        for _, shop in ipairs(activeOpp.shoppingList) do
            if shop and shop.itemId == itemId then
                activeOpp._hasActivePurchases = true
                activeOpp._lockedSpentByItem = activeOpp._lockedSpentByItem or {}
                local rec = activeOpp._lockedSpentByItem[itemId] or { qty = 0, spentCopper = 0 }
                rec.qty = (rec.qty or 0) + qty
                if addedSpent > 0 then
                    rec.spentCopper = (rec.spentCopper or 0) + addedSpent
                elseif shop.avgUnitPrice and shop.avgUnitPrice > 0 then
                    rec.spentCopper = (rec.spentCopper or 0) + (shop.avgUnitPrice * qty)
                end
                activeOpp._lockedSpentByItem[itemId] = rec
                break
            end
        end
    end

    return true
end

local function BuildAuctionWonPattern()
    local fmt = (type(_G.ERR_AUCTION_WON_S) == "string" and _G.ERR_AUCTION_WON_S ~= "")
        and _G.ERR_AUCTION_WON_S
        or "You won an auction for %s"
    local escaped = fmt:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
    local pattern = escaped:gsub("%%%%s", "(.+)", 1)
    return "^" .. pattern .. "%.?$"
end

-- Parses WoW system chat messages such as:
--   "You won an auction for Mithril Ore (x29)" -> "Mithril Ore", 29, nil
--   "You won an auction for Guardian Gloves"   -> "Guardian Gloves", 1, nil
function PF.AHVerifier.ParseAuctionWonMessage(msg)
    if type(msg) ~= "string" or msg == "" then
        return nil, nil, nil
    end
    local wonText = msg:match(BuildAuctionWonPattern())
    if not wonText or wonText == "" then
        wonText = msg:match("^You won an auction for (.+)%.?$")
    end
    if not wonText or wonText == "" then
        return nil, nil, nil
    end

    local qty = 1
    local stripped, countStr = wonText:match("^(.-)%s*%(x(%d+)%)%s*$")
    if not stripped then
        stripped, countStr = wonText:match("^(.-)%s*%((%d+)%)%s*$")
    end
    if stripped and countStr then
        wonText = stripped
        qty = math.max(1, tonumber(countStr) or 1)
    end

    local linkedItemId = tonumber(wonText:match("item:(%d+)"))
    local linkBracketName = wonText:match("%[(.-)%]")
    local cleanName = linkBracketName or wonText:gsub("^%s+", ""):gsub("%s+$", "")
    if cleanName == "" then
        return nil, nil, nil
    end
    return cleanName, qty, linkedItemId
end

local function ResolvePurchasedItemIdByName(itemName, linkedItemId)
    if linkedItemId and linkedItemId > 0 then
        return linkedItemId
    end
    if type(itemName) ~= "string" or itemName == "" then
        return nil
    end
    local lowerTarget = itemName:lower()

    if inFlightCommodityPurchase and inFlightCommodityPurchase.itemName
        and inFlightCommodityPurchase.itemName:lower() == lowerTarget then
        return inFlightCommodityPurchase.itemId
    end

    for _, entry in pairs(inFlightItemPurchases) do
        if entry and entry.itemName then
            local eLower = entry.itemName:lower()
            if eLower == lowerTarget or lowerTarget:sub(1, #eLower + 1) == (eLower .. " ") then
                return entry.itemId
            end
        end
    end

    local function MatchInShoppingList(opp)
        if type(opp) ~= "table" or type(opp.shoppingList) ~= "table" then return nil end
        local prefixMatch = nil
        for _, shop in ipairs(opp.shoppingList) do
            if shop and shop.itemId and type(shop.name) == "string" and shop.name ~= "" then
                local sLower = shop.name:lower()
                if sLower == lowerTarget then
                    return shop.itemId
                elseif not prefixMatch and lowerTarget:sub(1, #sLower + 1) == (sLower .. " ") then
                    prefixMatch = shop.itemId
                end
            end
        end
        return prefixMatch
    end

    if type(Profitable_DB) == "table" then
        local fromActive = MatchInShoppingList(Profitable_DB.activePlay)
        if fromActive then return fromActive end

        if type(Profitable_DB.lastTopPlays) == "table" then
            for _, opp in ipairs(Profitable_DB.lastTopPlays) do
                local found = MatchInShoppingList(opp)
                if found then return found end
            end
        end
        if type(Profitable_DB.lastHonorableMentions) == "table" then
            for _, opp in ipairs(Profitable_DB.lastHonorableMentions) do
                local found = MatchInShoppingList(opp)
                if found then return found end
            end
        end
        if type(Profitable_DB.itemCache) == "table" then
            for cachedId, meta in pairs(Profitable_DB.itemCache) do
                if type(meta) == "table" and type(meta.name) == "string" and meta.name:lower() == lowerTarget then
                    return cachedId
                end
            end
        end
    end

    return nil
end

-- Returns the dynamic label for the "Buy Next" button in DetailWindow
function PF.AHVerifier.GetBuyButtonLabel(item)
    if not item then return "Buy Next" end
    if item.source == "Vendor" then
        if item.remainingToBuy == 0 then
            return "Ready"
        end
        return "Buy Vendor"
    end
    if item.remainingToBuy == 0 then
        if item.purchasedCovered or ((item.purchasedInMail or 0) > 0 and (item.haveInBags or 0) < (item.effectiveQuantity or item.totalQuantity or 1)) then
            return "Bought"
        end
        return "Ready"
    end
    if pendingCommodityConfirm and pendingCommodityConfirm.itemId == item.itemId then
        return string.format("Confirm (%d)", pendingCommodityConfirm.quantity)
    end
    if inFlightCommodityPurchase and inFlightCommodityPurchase.itemId == item.itemId then
        local now = (_G.GetTime and _G.GetTime()) or 0
        if (now - (inFlightCommodityPurchase.sentAt or 0)) <= 6.0 then
            return "Buying..."
        else
            inFlightCommodityPurchase = nil
        end
    end
    if _G.C_AuctionHouse then
        local effectiveMax = item.effectiveMaxUnitPrice or item.maxUnitPrice
        local numComm, buyQty = GetLoadedQualifyingCommodityQty(
            item.itemId,
            effectiveMax,
            math.max(1, item.remainingToBuy or item.totalQuantity or 1),
            PF.Formatter.GetPlayerGold()
        )
        if numComm > 0 and buyQty > 0 then
            return string.format("Buy %dx", buyQty)
        end
        local numItem, bestAuction = GetLoadedQualifyingItemAuction(
            item.itemId,
            effectiveMax,
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

    -- Cancel any pending open/watchdog retry so it cannot collide with a purchase packet
    pendingOpenItemKey = nil
    pendingSearchCheck = nil

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
            if _G.C_AuctionHouse.IsThrottledMessageSystemReady and not _G.C_AuctionHouse.IsThrottledMessageSystemReady() then
                print("|cffff9900[Profitable]|r Auction House is busy — click 'Confirm' again in a moment.")
                return false, 0, 0, "THROTTLED"
            end

            local conf = pendingCommodityConfirm
            pendingCommodityConfirm = nil
            inFlightCommodityPurchase = {
                itemId = conf.itemId,
                itemName = conf.itemName or itemName,
                quantity = conf.quantity,
                unitPrice = conf.unitPrice,
                totalPrice = conf.totalPrice,
                sentAt = (_G.GetTime and _G.GetTime()) or 0,
            }

            if _G.C_AuctionHouse.ConfirmCommoditiesPurchase then
                pcall(_G.C_AuctionHouse.ConfirmCommoditiesPurchase, conf.itemId, conf.quantity)
            end

            print(string.format(
                "|cff00ff88[Profitable]|r Confirming purchase of %dx [%s] for %s (%s ea)...",
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

            inFlightCommodityPurchase = nil
            SetDefaultCommoditiesUIQuantity(buyQty, true)

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

            -- Call PlaceBid directly using the auctionID WITHOUT mutating ItemBuyFrame or calling
            -- SearchItemOnAH (which would send a new search query and drop PlaceBid)!
            if _G.C_AuctionHouse.PlaceBid then
                purchasedAuctionIds[bestAuction.auctionID] = true
                inFlightItemPurchases[bestAuction.auctionID] = {
                    itemId = itemId,
                    itemName = itemName,
                    quantity = 1,
                    buyout = bestAuction.buyoutAmount,
                    sentAt = (_G.GetTime and _G.GetTime()) or 0,
                }
                pcall(_G.C_AuctionHouse.PlaceBid, bestAuction.auctionID, bestAuction.buyoutAmount)
                local qty = 1
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

    SafeRegisterEvent(verifierFrame, "AUCTION_HOUSE_CLOSED")
    SafeRegisterEvent(verifierFrame, "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    SafeRegisterEvent(verifierFrame, "AUCTION_HOUSE_BROWSE_RESULTS_ADDED")
    SafeRegisterEvent(verifierFrame, "AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
    SafeRegisterEvent(verifierFrame, "AUCTION_HOUSE_PURCHASE_COMPLETED")
    SafeRegisterEvent(verifierFrame, "COMMODITY_SEARCH_RESULTS_UPDATED")
    SafeRegisterEvent(verifierFrame, "ITEM_SEARCH_RESULTS_UPDATED")
    SafeRegisterEvent(verifierFrame, "COMMODITY_PURCHASE_SUCCEEDED")
    SafeRegisterEvent(verifierFrame, "COMMODITY_PURCHASE_FAILED")
    SafeRegisterEvent(verifierFrame, "COMMODITY_PRICE_UNAVAILABLE")
    SafeRegisterEvent(verifierFrame, "CHAT_MSG_SYSTEM")
    SafeRegisterEvent(verifierFrame, "MAIL_INBOX_UPDATE")

    verifierFrame:SetScript("OnEvent", function(_, event, arg1, arg2)
        if event == "AUCTION_HOUSE_CLOSED" then
            browseResultsHarvested = false
            knownItemKeys = {}
            purchasedAuctionIds = {}
            pendingOpenItemKey = nil
            pendingSearchCheck = nil
            pendingBrowseResolve = nil
            pendingCommodityConfirm = nil
            inFlightCommodityPurchase = nil
            inFlightItemPurchases = {}
            itemKeyCallbacks = {}
            ClearPendingItemKeyWatchers()
            if isRunning then
                FinalizeRun("AH_CLOSED")
            end
            return
        end

        if event == "CHAT_MSG_SYSTEM" then
            local wonName, wonQty, linkedId = PF.AHVerifier.ParseAuctionWonMessage(arg1)
            if wonName and wonQty and wonQty > 0 then
                local resolvedId = ResolvePurchasedItemIdByName(wonName, linkedId)
                if resolvedId then
                    local matchedSpent = nil
                    if inFlightCommodityPurchase and inFlightCommodityPurchase.itemId == resolvedId
                        and inFlightCommodityPurchase.quantity == wonQty then
                        matchedSpent = inFlightCommodityPurchase.totalPrice
                        inFlightCommodityPurchase = nil
                    else
                        for aId, entry in pairs(inFlightItemPurchases) do
                            if entry and entry.itemId == resolvedId then
                                matchedSpent = entry.buyout
                                inFlightItemPurchases[aId] = nil
                                break
                            end
                        end
                    end
                    if PF.AHVerifier.RecordConfirmedPurchase(resolvedId, wonName, wonQty, "CHAT", matchedSpent) then
                        if PF.DetailWindow and PF.DetailWindow.RefreshIfShown then
                            PF.DetailWindow.RefreshIfShown()
                        end
                    end
                end
            end
            return
        end

        if event == "MAIL_INBOX_UPDATE" then
            if _G.GetInboxNumItems then
                local okInbox, numItems, totalItems = pcall(_G.GetInboxNumItems)
                if okInbox and numItems == 0 and (totalItems == nil or totalItems == 0) then
                    local tbl = GetCharPurchasedMailTable(false)
                    if tbl then
                        local now = (_G.time and _G.time()) or 0
                        for mItemId, entry in pairs(tbl) do
                            if type(entry) ~= "table" or (now - (entry.updatedAt or 0)) >= 3 then
                                tbl[mItemId] = nil
                            end
                        end
                    end
                end
            end
            if PF.DetailWindow and PF.DetailWindow.RefreshIfShown then
                PF.DetailWindow.RefreshIfShown()
            end
            return
        end

        if event == "AUCTION_HOUSE_PURCHASE_COMPLETED" then
            local auctionId = tonumber(arg1) or arg1
            local entry = (auctionId ~= nil) and inFlightItemPurchases[auctionId] or nil
            if entry then
                inFlightItemPurchases[auctionId] = nil
            else
                local now = (_G.GetTime and _G.GetTime()) or 0
                local oldestKey, oldestTime = nil, nil
                for aId, e in pairs(inFlightItemPurchases) do
                    if e and (now - (e.sentAt or 0)) <= 10.0 then
                        if not oldestTime or (e.sentAt or 0) < oldestTime then
                            oldestKey = aId
                            oldestTime = e.sentAt or 0
                        end
                    end
                end
                if oldestKey then
                    entry = inFlightItemPurchases[oldestKey]
                    inFlightItemPurchases[oldestKey] = nil
                end
            end
            if entry and entry.itemId then
                PF.AHVerifier.RecordConfirmedPurchase(entry.itemId, entry.itemName, entry.quantity or 1, "EVENT", entry.buyout)
                if PF.DetailWindow and PF.DetailWindow.RefreshIfShown then
                    PF.DetailWindow.RefreshIfShown()
                end
            end
            return
        end

        if event == "ITEM_KEY_ITEM_INFO_RECEIVED" then
            PollPendingItemKeys()
            return
        end

        if event == "AUCTION_HOUSE_THROTTLED_SYSTEM_READY" then
            FlushPendingOpenItemKey()
            return
        end

        if event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" or event == "AUCTION_HOUSE_BROWSE_RESULTS_ADDED" then
            if event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" then
                browseResultsHarvested = false
                HarvestBrowseResultItemKeys(type(arg1) == "table" and arg1 or nil)
            elseif type(arg1) == "table" and #arg1 > 0 then
                HarvestBrowseResultItemKeys(arg1)
            end
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
            inFlightCommodityPurchase = nil
            if PF.DetailWindow and PF.DetailWindow.RefreshIfShown then
                PF.DetailWindow.RefreshIfShown()
            end
            return
        elseif event == "COMMODITY_PURCHASE_SUCCEEDED" then
            local completed = inFlightCommodityPurchase or pendingCommodityConfirm
            inFlightCommodityPurchase = nil
            pendingCommodityConfirm = nil
            if completed and completed.itemId then
                local spent = completed.totalPrice or ((completed.unitPrice or 0) * (completed.quantity or 1))
                PF.AHVerifier.RecordConfirmedPurchase(completed.itemId, completed.itemName, completed.quantity or 1, "EVENT", spent)
                print(string.format(
                    "|cff00ff88[Profitable]|r Purchase confirmed: %dx [%s] — check your mailbox!",
                    completed.quantity or 1,
                    completed.itemName or ("Item #" .. tostring(completed.itemId))
                ))
            end
            if PF.DetailWindow and PF.DetailWindow.RefreshIfShown then
                PF.DetailWindow.RefreshIfShown()
            end
            return
        end

        if not isRunning then
            if event == "COMMODITY_SEARCH_RESULTS_UPDATED" then
                local itemId = tonumber(arg1) or activeSearchItemId
                if itemId then
                    if pendingSearchCheck and pendingSearchCheck.itemId == itemId then
                        pendingSearchCheck = nil
                    end
                    CollectModernCommodityResults(itemId)
                    if itemId == activeSearchItemId and activeSearchDesiredQty and activeSearchDesiredQty > 0 then
                        SetDefaultCommoditiesUIQuantity(activeSearchDesiredQty, true)
                    end
                    if PF.DetailWindow and PF.DetailWindow.RevalidateActiveOpportunity then
                        PF.DetailWindow.RevalidateActiveOpportunity(itemId)
                    elseif PF.DetailWindow and PF.DetailWindow.RefreshIfShown then
                        PF.DetailWindow.RefreshIfShown()
                    end
                end
            elseif event == "ITEM_SEARCH_RESULTS_UPDATED" then
                local itemKey = type(arg1) == "table" and arg1 or nil
                local itemId = (itemKey and itemKey.itemID) or activeSearchItemId
                if itemId then
                    if pendingSearchCheck and pendingSearchCheck.itemId == itemId then
                        pendingSearchCheck = nil
                    end
                    CollectModernItemResults(itemId, itemKey)
                    if PF.DetailWindow and PF.DetailWindow.RevalidateActiveOpportunity then
                        PF.DetailWindow.RevalidateActiveOpportunity(itemId)
                    elseif PF.DetailWindow and PF.DetailWindow.RefreshIfShown then
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
            ScheduleNextVerification(0.15)
        elseif event == "COMMODITY_SEARCH_RESULTS_UPDATED" then
            local updatedId = tonumber(arg1)
            if not updatedId or updatedId == target.itemId then
                CollectModernCommodityResults(target.itemId)
                currentQueryItem = nil
                ScheduleNextVerification(0.15)
            end
        elseif event == "ITEM_SEARCH_RESULTS_UPDATED" then
            local keyId = (type(arg1) == "table" and arg1.itemID) or tonumber(arg1)
            if not keyId or keyId == target.itemId then
                CollectModernItemResults(target.itemId, type(arg1) == "table" and arg1 or nil)
                currentQueryItem = nil
                ScheduleNextVerification(0.15)
            end
        end
    end)

    PF.AHVerifier.frame = verifierFrame
end
