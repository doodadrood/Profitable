local PF = _G.PF or {}
_G.PF = PF
_G.Profitable = PF

PF.MarketFeed = {}

local MAX_FEED_AGE_SECONDS = 86400 -- Treat external snapshots older than 24h as stale

function PF.MarketFeed.GetFeedTable()
    local feed = _G.Profitable_MarketFeed
    if type(feed) ~= "table" or type(feed.items) ~= "table" then
        return nil
    end
    return feed
end

function PF.MarketFeed.IsAvailable()
    local feed = PF.MarketFeed.GetFeedTable()
    return feed ~= nil and (feed.timestamp or 0) > 0
end

function PF.MarketFeed.GetFeedAgeSeconds()
    local feed = PF.MarketFeed.GetFeedTable()
    if not feed or not feed.timestamp or feed.timestamp <= 0 then
        return nil
    end
    return math.max(0, time() - feed.timestamp)
end

function PF.MarketFeed.IsFresh(maxAgeSeconds)
    local age = PF.MarketFeed.GetFeedAgeSeconds()
    local limit = (type(maxAgeSeconds) == "number" and maxAgeSeconds > 0) and maxAgeSeconds or MAX_FEED_AGE_SECONDS
    return age ~= nil and age <= limit
end

function PF.MarketFeed.GetItemData(itemId)
    if not itemId or itemId <= 0 then return nil end
    local feed = PF.MarketFeed.GetFeedTable()
    if not feed then return nil end
    local row = feed.items[itemId]
    if type(row) ~= "table" or not row.m or row.m <= 0 then
        return nil
    end
    return {
        minBuyout = row.m,
        totalQuantity = row.q or 1,
        median14d = row.med or row.m,
        observations = row.obs or 1,
        tiers = row.tiers,
        timestamp = feed.timestamp or 0,
    }
end

function PF.MarketFeed.GetOrderBook(itemId)
    local data = PF.MarketFeed.GetItemData(itemId)
    if not data or type(data.tiers) ~= "table" or #data.tiers == 0 then
        return nil, 0
    end
    local out = {}
    for _, t in ipairs(data.tiers) do
        local up = t[1]
        local qty = t[2]
        if up and up > 0 and qty and qty > 0 then
            table.insert(out, { unitPrice = up, quantity = qty })
        end
    end
    if #out == 0 then
        return nil, 0
    end
    return out, data.timestamp
end

-- Applies SQLite 14-day historical median spike protection on an exit/sale price.
-- Returns: effectivePrice, isSpiked, spikeDetails
function PF.MarketFeed.GetExitPrice(itemId, rawAHPrice)
    if not rawAHPrice or rawAHPrice <= 0 then
        return nil, false, nil
    end
    local settings = (Profitable_DB and Profitable_DB.settings) or {}
    if settings.useHistoricalSpikeGuard == false then
        return rawAHPrice, false, nil
    end

    local data = PF.MarketFeed.GetItemData(itemId)
    if not data or not data.median14d or data.median14d <= 0 then
        return rawAHPrice, false, nil
    end

    local minObs = settings.minHistoricalSamples or 3
    if (data.observations or 0) < minObs then
        return rawAHPrice, false, nil
    end

    local maxSpikeMult = settings.maxSpikeMultiplier or 2.0
    local capMult = settings.spikeCapMultiplier or 1.25
    if rawAHPrice > (data.median14d * maxSpikeMult) then
        local capped = math.max(1, math.floor(data.median14d * capMult))
        return capped, true, {
            itemId = itemId,
            livePrice = rawAHPrice,
            medianPrice = data.median14d,
            cappedPrice = capped,
            observations = data.observations,
        }
    end

    return rawAHPrice, false, nil
end

function PF.MarketFeed.CollectAllItemIds(targetSet)
    local feed = PF.MarketFeed.GetFeedTable()
    if not feed then return end
    for itemId, row in pairs(feed.items) do
        if type(itemId) == "number" and itemId > 0 and type(row) == "table" and row.m and row.m > 0 then
            targetSet[itemId] = true
        end
    end
end

-- Optionally mirrors newer API feed prices into PCF_DB.prices for the local player when
-- BOTH Profitable and Profitable_MarketFeed are active. Never overwrites newer in-game
-- PCF scans, and never affects traditional PCF users who don't use Profitable + MarketFeed.
function PF.MarketFeed.MirrorToPCF()
    local settings = (Profitable_DB and Profitable_DB.settings) or {}
    if settings.mirrorFeedToPCF == false then
        return 0
    end
    if type(_G.PCF_DB) ~= "table" then
        return 0
    end
    local feed = PF.MarketFeed.GetFeedTable()
    if not feed or not PF.MarketFeed.IsFresh() then
        return 0
    end

    local feedTs = feed.timestamp or 0
    _G.PCF_DB.prices = _G.PCF_DB.prices or {}
    local mirrored = 0

    for itemId, row in pairs(feed.items) do
        if type(itemId) == "number" and itemId > 0 and type(row) == "table" and row.m and row.m > 0 then
            local existing = _G.PCF_DB.prices[itemId]
            local existingTs = (existing and existing.lastUpdated) or 0
            if not existing or existingTs < feedTs then
                _G.PCF_DB.prices[itemId] = {
                    minBuyout = row.m,
                    minBid = row.m,
                    lastUpdated = feedTs,
                    count = row.q or 1,
                    source = "API Feed",
                }
                mirrored = mirrored + 1
            end
        end
    end
    if mirrored > 0 and PF.InvalidateAHStatusCache then
        PF.InvalidateAHStatusCache()
    end
    return mirrored
end

function PF.MarketFeed.OnFeedLoaded()
    if _G.PF_INITIALIZED then
        PF.MarketFeed.MirrorToPCF()
    end
end
