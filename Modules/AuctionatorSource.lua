local PF = _G.PF or {}
_G.PF = PF
_G.Profitable = PF

PF.AuctionatorSource = {}

local dbUpdateRegistered = false
local atrCacheRevision = 0
local realmIndexCache = {
    tableRef = nil,
    lastScanTs = -1,
    isEmpty = true,
    revision = -1,
    gearBestByItemId = {},
    itemIds = {},
    itemCount = 0,
}

function PF.AuctionatorSource.InvalidateCache()
    atrCacheRevision = atrCacheRevision + 1
    realmIndexCache.tableRef = nil
    if PF.InvalidateAHStatusCache then
        PF.InvalidateAHStatusCache()
    end
end

function PF.AuctionatorSource.GetCacheRevision()
    return atrCacheRevision
end

local function GetAuctionatorSavedState()
    if _G.Auctionator and type(_G.Auctionator.SavedState) == "table" then
        return _G.Auctionator.SavedState
    end
    if type(_G.AUCTIONATOR_SAVEDVARS) == "table" then
        return _G.AUCTIONATOR_SAVEDVARS
    end
    return nil
end

function PF.AuctionatorSource.GetLastScanTimestamp()
    local savedState = GetAuctionatorSavedState()
    if not savedState then
        return 0
    end
    local browseTs = tonumber(savedState.TimeOfLastBrowseScan) or 0
    local repTs = tonumber(savedState.TimeOfLastReplicateScan) or 0
    local fullTs = tonumber(savedState.TimeOfLastFullScan) or 0
    return math.max(browseTs, repTs, fullTs)
end

local function LooksLikePriceEntry(val)
    return type(val) == "table" and type(val.m) == "number" and val.m > 0
end

local function LooksLikeRealmPriceMap(tbl)
    if type(tbl) ~= "table" then
        return false
    end
    for k, v in pairs(tbl) do
        if k ~= "__dbversion" then
            if LooksLikePriceEntry(v) then
                return true
            end
            return false
        end
    end
    return false
end

-- Resolves the active realm/faction price table inside Auctionator's database.
function PF.AuctionatorSource.GetRealmPriceTable()
    if _G.Auctionator and type(_G.Auctionator.Database) == "table" and type(_G.Auctionator.Database.db) == "table" then
        return _G.Auctionator.Database.db
    end

    local root = _G.AUCTIONATOR_PRICE_DATABASE
    if type(root) ~= "table" then
        return nil
    end

    -- Support direct flat mock tables (itemId -> { m = ..., a = ... })
    if LooksLikeRealmPriceMap(root) then
        return root
    end

    local realm = (_G.GetRealmName and _G.GetRealmName()) or ""
    local faction = (_G.UnitFactionGroup and _G.UnitFactionGroup("player")) or ""

    local candidates = {}
    if realm ~= "" and faction ~= "" then
        table.insert(candidates, realm .. " " .. faction)
        table.insert(candidates, realm .. "-" .. faction)
    end
    if realm ~= "" then
        table.insert(candidates, realm)
    end

    for _, key in ipairs(candidates) do
        local sub = root[key]
        if type(sub) == "table" then
            return sub
        end
    end

    if realm ~= "" then
        local lowerRealm = realm:lower()
        for k, v in pairs(root) do
            if k ~= "__dbversion" and type(k) == "string" and type(v) == "table" then
                if k:lower():find(lowerRealm, 1, true) == 1 then
                    return v
                end
            end
        end
    end

    local fallback = nil
    local subTableCount = 0
    for k, v in pairs(root) do
        if k ~= "__dbversion" and type(v) == "table" then
            fallback = v
            subTableCount = subTableCount + 1
        end
    end
    if subTableCount == 1 then
        return fallback
    end

    return nil
end

function PF.AuctionatorSource.IsAvailable()
    if _G.Auctionator and type(_G.Auctionator.API) == "table" and type(_G.Auctionator.API.v1) == "table" then
        return true
    end
    return PF.AuctionatorSource.GetRealmPriceTable() ~= nil
end

local function ExtractLatestAvailableCount(entry)
    if type(entry) ~= "table" or type(entry.a) ~= "table" then
        return nil
    end
    local latestDay = nil
    local count = nil
    for dayKey, qty in pairs(entry.a) do
        local dayNum = tonumber(dayKey)
        local qtyNum = tonumber(qty)
        if dayNum and qtyNum and qtyNum > 0 then
            if not latestDay or dayNum > latestDay then
                latestDay = dayNum
                count = math.floor(qtyNum)
            end
        end
    end
    return count
end

local function ParseItemIdFromAuctionatorKey(key)
    if type(key) == "number" then
        if key > 0 and key == math.floor(key) then
            return key
        end
        return nil
    end
    if type(key) ~= "string" then
        return nil
    end
    local plain = tonumber(key)
    if plain and plain > 0 and plain == math.floor(plain) then
        return plain
    end
    -- Skip Battle Pets ("p:...")
    if key:sub(1, 2) == "p:" then
        return nil
    end
    local gearId = key:match("^gr?:(%d+)")
    if gearId then
        local num = tonumber(gearId)
        if num and num > 0 then
            return num
        end
    end
    return nil
end

-- Builds a single O(N) lookup index per Auctionator scan / DB update so per-item lookups,
-- suffixed gear ("g:<id>:..." / "gr:<id>:...") resolution, and item counts run in O(1).
local function EnsureRealmIndex(priceTable)
    if type(priceTable) ~= "table" then
        return nil
    end
    local lastScanTs = PF.AuctionatorSource.GetLastScanTimestamp()
    local isEmpty = (next(priceTable) == nil)
    if realmIndexCache.tableRef == priceTable
        and realmIndexCache.lastScanTs == lastScanTs
        and realmIndexCache.isEmpty == isEmpty
        and realmIndexCache.revision == atrCacheRevision then
        return realmIndexCache
    end

    local gearBest = {}
    local itemIds = {}
    local seen = {}

    for k, v in pairs(priceTable) do
        if type(v) == "table" and type(v.m) == "number" and v.m > 0 then
            local itemId = ParseItemIdFromAuctionatorKey(k)
            if itemId and itemId > 0 then
                if not seen[itemId] then
                    seen[itemId] = true
                    itemIds[#itemIds + 1] = itemId
                end
                if type(k) == "string" and (k:sub(1, 2) == "g:" or k:sub(1, 3) == "gr:") then
                    local cur = gearBest[itemId]
                    if not cur or v.m < cur.m then
                        gearBest[itemId] = v
                    end
                end
            end
        end
    end

    realmIndexCache.tableRef = priceTable
    realmIndexCache.lastScanTs = lastScanTs
    realmIndexCache.isEmpty = isEmpty
    realmIndexCache.revision = atrCacheRevision
    realmIndexCache.gearBestByItemId = gearBest
    realmIndexCache.itemIds = itemIds
    realmIndexCache.itemCount = #itemIds
    return realmIndexCache
end

local function FindRawDBEntry(priceTable, itemId)
    if type(priceTable) ~= "table" or not itemId then
        return nil
    end
    local direct = priceTable[tostring(itemId)] or priceTable[itemId]
    if type(direct) == "table" then
        return direct
    end
    local idx = EnsureRealmIndex(priceTable)
    return idx and idx.gearBestByItemId[itemId] or nil
end

function PF.AuctionatorSource.GetItemData(itemId, itemLink)
    if not itemId or itemId <= 0 then
        return nil
    end

    local api = _G.Auctionator and _G.Auctionator.API and _G.Auctionator.API.v1
    local price = nil

    if api then
        if itemLink and type(api.GetAuctionPriceByItemLink) == "function" then
            local ok, result = pcall(api.GetAuctionPriceByItemLink, "Profitable", itemLink)
            if ok and type(result) == "number" and result > 0 then
                price = math.floor(result)
            end
        end
        if not price and type(api.GetAuctionPriceByItemID) == "function" then
            local ok, result = pcall(api.GetAuctionPriceByItemID, "Profitable", itemId)
            if ok and type(result) == "number" and result > 0 then
                price = math.floor(result)
            end
        end
    end

    local priceTable = PF.AuctionatorSource.GetRealmPriceTable()
    local entry = priceTable and FindRawDBEntry(priceTable, itemId) or nil
    if not price and entry and type(entry.m) == "number" and entry.m > 0 then
        price = math.floor(entry.m)
    end

    if not price or price <= 0 then
        return nil
    end

    local now = (_G.time and _G.time()) or 0
    local lastScanTs = PF.AuctionatorSource.GetLastScanTimestamp()
    local ageDays = nil

    if api then
        if itemLink and type(api.GetAuctionAgeByItemLink) == "function" then
            local ok, val = pcall(api.GetAuctionAgeByItemLink, "Profitable", itemLink)
            if ok and type(val) == "number" and val >= 0 then
                ageDays = val
            end
        end
        if ageDays == nil and type(api.GetAuctionAgeByItemID) == "function" then
            local ok, val = pcall(api.GetAuctionAgeByItemID, "Profitable", itemId)
            if ok and type(val) == "number" and val >= 0 then
                ageDays = val
            end
        end
    end

    local timestamp = 0
    if type(ageDays) == "number" and ageDays > 0 then
        local baseTs = (lastScanTs > 0) and math.min(lastScanTs, now) or now
        timestamp = math.max(0, math.min(baseTs, now - (ageDays * 86400)))
    elseif lastScanTs > 0 then
        timestamp = math.min(lastScanTs, now)
    end

    local count = ExtractLatestAvailableCount(entry)
    if not count or count <= 0 then
        -- When Auctionator API returns a price without a raw DB count entry, assume modest stock
        -- (live AH verification will confirm exact order-book tiers at the AH).
        count = entry and 1 or 10
    end

    return {
        minBuyout = price,
        count = count,
        timestamp = timestamp,
        ageDays = ageDays,
        source = "Auctionator",
    }
end

function PF.AuctionatorSource.CollectAllItemIds(targetSet)
    if type(targetSet) ~= "table" then
        return 0
    end
    local priceTable = PF.AuctionatorSource.GetRealmPriceTable()
    local idx = EnsureRealmIndex(priceTable)
    if not idx then
        return 0
    end
    local added = 0
    local ids = idx.itemIds
    for i = 1, #ids do
        local itemId = ids[i]
        if not targetSet[itemId] then
            targetSet[itemId] = true
            added = added + 1
        end
    end
    return added
end

function PF.AuctionatorSource.GetStatus()
    local available = PF.AuctionatorSource.IsAvailable()
    local priceTable = PF.AuctionatorSource.GetRealmPriceTable()
    local lastScanTs = PF.AuctionatorSource.GetLastScanTimestamp()
    local idx = EnsureRealmIndex(priceTable)
    local itemCount = idx and idx.itemCount or 0

    return {
        available = available,
        itemCount = itemCount,
        lastScanTimestamp = lastScanTs,
        hasUntimestamped = (itemCount > 0 and lastScanTs <= 0),
    }
end

function PF.AuctionatorSource.Init()
    if dbUpdateRegistered then
        return true
    end
    local api = _G.Auctionator and _G.Auctionator.API and _G.Auctionator.API.v1
    if api and type(api.RegisterForDBUpdate) == "function" then
        local ok = pcall(api.RegisterForDBUpdate, "Profitable", function()
            PF.AuctionatorSource.InvalidateCache()
            if PF.SideWindow then
                if PF.SideWindow.frame and (not PF.SideWindow.frame.IsShown or PF.SideWindow.frame:IsShown()) then
                    if PF.SideWindow.Refresh then
                        PF.SideWindow.Refresh()
                    end
                elseif PF.SideWindow.RefreshOnboardingPopup then
                    PF.SideWindow.RefreshOnboardingPopup()
                end
            end
        end)
        if ok then
            dbUpdateRegistered = true
            return true
        end
    end
    return false
end
