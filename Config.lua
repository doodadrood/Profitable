local PF = _G.PF or {}
_G.PF = PF
_G.Profitable = PF

function PF.IsSecret(val)
    if val == nil then return false end
    if _G.issecretvalue then
        local ok, isSec = pcall(_G.issecretvalue, val)
        if ok and isSec then
            return true
        end
    end
    if _G.canaccessvalue then
        local ok, canAccess = pcall(_G.canaccessvalue, val)
        if ok and not canAccess then
            return true
        end
    end
    return false
end

Profitable_DB = Profitable_DB or {}
_G.Profitable_DB = Profitable_DB

local defaultConfig = {
    version = 3,
    settings = {
        enabled = true,
        ahCutRate = 0.05,                        -- Standard 5% faction AH cut (auto-switches to 15% at Neutral AH)
        deductExpectedDeposit = true,            -- Deduct expected AH deposit risk for slow-moving gear on Craft & AH
        maxCalculationSeconds = 90,              -- 1.5 minute calculation/verification cap
        extremeProfitMultiplier = 2.0,           -- Keep finishing verification if candidate is >= 2x current #1 profit
        extremeGraceSeconds = 30,                -- Extra seconds allowed for an extremely profitable play
        topCount = 5,                            -- Number of top plays to display
        verifyCandidateCount = 10,               -- Number of top candidates to double-check on live AH
        minProfitCopper = 100,                   -- Minimum 1 silver total profit to list
        minROIPercent = 5,                       -- Minimum 5% ROI to avoid tying up all gold for pennies
        maxAHCraftUnits = 20,                    -- Cap per-play crafted units for fast-moving AH trade goods/consumables
        maxAHGearUnits = 3,                      -- Cap per-play crafted units for slow-moving AH armor/weapons
        maxDEUnits = 30,                         -- Cap per-play DE units for dust/essence plays
        maxShardDEUnits = 8,                     -- Cap per-play DE units when primary target is a Shard/Crystal
        maxVendorUnits = 200,                    -- Vendor plays have infinite demand, capped only by AH supply & gold
        includeAllCharRecipes = false,           -- false = only current logged-in character's recipes
        includeSkillMatchedBaselineRecipes = true, -- Use built-in recipe DB matching character skill rank
        includeTrainerRecommendations = true,    -- Surface high-profit recipes learnable at trainer/vendor
        trainerSkillLookahead = 25,              -- Look ahead up to +25 skill points for trainer recipe recommendations
        enableVendorArbitrageAlerts = true,      -- Alert when an NPC vendor has limited-stock items profitable on AH
        assumeCanDisenchant = true,              -- Include Disenchant plays (Buy & DE and Craft & DE)
        showCraftPlays = true,                   -- Include Crafting plays (Craft & AH and Craft & Vendor)
        showVendorPlays = true,                  -- Include direct AH -> NPC Vendor arbitrage plays
        buyoutOnly = true,                       -- Strictly exclude bid-only AH listings without a buyout price
        useIntermediateCrafting = true,          -- Consider smelting ore->bars / cloth->bolts when cheaper than buying bar/bolt
        useHistoricalSpikeGuard = true,          -- Cap spiked exit prices using SQLite 14-day median when MarketFeed is present
        maxSpikeMultiplier = 2.0,                -- Flag/cap when live exit price exceeds 2.0x 14-day median
        spikeCapMultiplier = 1.25,               -- Cap estimated exit revenue to 1.25x 14-day median
        minHistoricalSamples = 3,                -- Require >= 3 hourly snapshots before enforcing spike cap
        mirrorFeedToPCF = true,                  -- Softly fill missing/older PCF_DB prices from MarketFeed when both are active
        marketFeedVerifySkipSeconds = 0,         -- 0 = always live-verify top plays at AH even when MarketFeed is loaded
        showSideWindow = true,
        onboardingDismissed = false,             -- Show welcome/AH-scan popup on startup until user clicks OK / Got It
        staleDataThresholdSeconds = 86400,       -- Require a fresh AH scan when cached data is older than 24 hours
        customBudgetCopper = 0,                  -- 0 = Auto (use full character gold); >0 = cap spending budget (in copper)
    },
    charRecipes = {},     -- [charKey] = { [recipeKey] = recipeTable }
    vendorBuyPrices = {}, -- [itemId] = copperPrice (learned dynamically from vendors + static DB)
    vendorAlerts = {},    -- Recent limited-supply vendor arbitrage opportunities found at NPCs
    itemCache = {},       -- [itemId] = { name, link, quality, itemLevel, classID, subClassID, invType, texture, vendorSell }
    orderBookCache = {},        -- [itemId] = { timestamp = 0, listings = { { unitPrice = 0, quantity = 0 }, ... } }
    lastTopPlays = {},          -- Cached top 5 opportunities from most recent run
    lastHonorableMentions = {}, -- Cached honorable mention plays (Top Craft & Top Vendor)
    activePlay = nil,           -- Currently tracked opportunity in DetailWindow
    purchasedInMail = {},       -- [charKey] = { [itemId] = { count = 0, updatedAt = 0, lastBagCount = 0 } }
}

local function ApplyDefaults(target, defaults)
    for key, value in pairs(defaults) do
        if type(value) == "table" then
            if type(target[key]) ~= "table" then
                target[key] = {}
            end
            ApplyDefaults(target[key], value)
        elseif target[key] == nil then
            target[key] = value
        end
    end
end

function PF.GetCharacterKey()
    local name = (_G.UnitName and _G.UnitName("player")) or "Player"
    local realm = (_G.GetRealmName and _G.GetRealmName()) or "Forever"
    return string.format("%s-%s", tostring(name), tostring(realm))
end

-- Parses user budget input into copper.
-- Accepts: "", "0", "auto", "all", "reset", "off" -> 0 (use full player gold)
--          Plain gold numbers like "10" or "10.5" -> 100000 / 105000 copper
--          Currency strings like "10g", "10g 50s", "50s", "2g 5s 25c" -> exact copper
-- Returns copper (number >= 0) or nil if input cannot be parsed.
function PF.ParseGoldToCopper(input)
    if input == nil then return 0 end
    if type(input) == "number" then
        if input ~= input or input < 0 or input >= math.huge then return nil end
        return math.floor(input + 0.5)
    end
    if type(input) ~= "string" then return nil end
    local trimmed = input:lower():match("^%s*(.-)%s*$") or ""
    if trimmed == "" or trimmed == "0" or trimmed == "auto" or trimmed == "all" or trimmed == "reset" or trimmed == "off" or trimmed == "none" then
        return 0
    end

    -- Plain numeric gold value (e.g. "10" -> 10g, "12.5" -> 12g 50s)
    local plainNum = tonumber(trimmed)
    if plainNum then
        if plainNum < 0 or plainNum >= math.huge then return nil end
        return math.floor((plainNum * 10000) + 0.5)
    end

    -- Explicit g / s / c tokens (e.g. "10g 50s", "50s", "1g 25s 50c")
    local remainder = trimmed:gsub("%s+", "")
    local total = 0
    local matchedAny = false
    local g = remainder:match("(%d+%.?%d*)g")
    if g then
        total = total + math.floor((tonumber(g) * 10000) + 0.5)
        remainder = remainder:gsub("%d+%.?%d*g", "", 1)
        matchedAny = true
    end
    local s = remainder:match("(%d+%.?%d*)s")
    if s then
        total = total + math.floor((tonumber(s) * 100) + 0.5)
        remainder = remainder:gsub("%d+%.?%d*s", "", 1)
        matchedAny = true
    end
    local c = remainder:match("(%d+)c")
    if c then
        total = total + math.floor(tonumber(c))
        remainder = remainder:gsub("%d+c", "", 1)
        matchedAny = true
    end

    if matchedAny and remainder == "" then
        return math.max(0, total)
    end
    return nil
end

-- Returns: effectiveBudgetCopper, isCapped, playerGoldCopper, customBudgetCopper
-- Defaults to full current character gold when customBudgetCopper == 0.
-- When a custom budget cap is set, caps to min(playerGold, customBudgetCopper).
function PF.GetEffectiveBudget()
    local playerGold = (PF.Formatter and PF.Formatter.GetPlayerGold and PF.Formatter.GetPlayerGold()) or 0
    local custom = Profitable_DB and Profitable_DB.settings and tonumber(Profitable_DB.settings.customBudgetCopper) or 0
    custom = math.max(0, math.floor(custom))
    if custom > 0 then
        return math.min(playerGold, custom), true, playerGold, custom
    end
    return playerGold, false, playerGold, 0
end

-- Returns 0.15 (15%) if at a Neutral Auction House (Booty Bay / Gadgetzan / Everlook),
-- otherwise returns the configured faction AH cut rate (default 0.05 = 5%).
function PF.GetEffectiveAHCutRate()
    if _G.GetAuctionHouseDepositRate then
        local ok, depRate = pcall(_G.GetAuctionHouseDepositRate)
        if ok and type(depRate) == "number" and depRate > 5 then
            return 0.15
        end
    end
    local configured = Profitable_DB and Profitable_DB.settings and Profitable_DB.settings.ahCutRate
    if type(configured) == "number" and configured >= 0 and configured < 1 then
        return configured
    end
    return 0.05
end

function PF.FormatAgeShort(ageSeconds)
    if type(ageSeconds) ~= "number" or ageSeconds < 0 or ageSeconds >= math.huge then
        return "never"
    end
    local secs = math.floor(ageSeconds)
    if secs >= 86400 then
        local d = math.floor(secs / 86400)
        local h = math.floor((secs % 86400) / 3600)
        return string.format("%dd %dh", d, h)
    elseif secs >= 3600 then
        local h = math.floor(secs / 3600)
        local m = math.floor((secs % 3600) / 60)
        return string.format("%dh %dm", h, m)
    elseif secs >= 60 then
        return string.format("%dm", math.floor(secs / 60))
    end
    return "0m"
end

-- Evaluates whether Auction House price data is available and fresh.
-- Returns: status ("NO_DATA" | "STALE" | "FRESH"), detailsTable
function PF.GetAHDataStatus()
    local now = (_G.time and _G.time()) or 0
    local threshold = (Profitable_DB and Profitable_DB.settings and tonumber(Profitable_DB.settings.staleDataThresholdSeconds)) or 86400

    local pcfItems = 0
    local newestEntryTs = 0
    local hasUntimestampedEntry = false

    if _G.PCF_DB and type(_G.PCF_DB.prices) == "table" then
        for itemId, entry in pairs(_G.PCF_DB.prices) do
            if type(itemId) == "number" and itemId > 0 and type(entry) == "table" and entry.minBuyout and entry.minBuyout > 0 then
                pcfItems = pcfItems + 1
                local ts = tonumber(entry.lastUpdated) or 0
                if ts > newestEntryTs then
                    newestEntryTs = ts
                elseif ts <= 0 then
                    hasUntimestampedEntry = true
                end
            end
        end
    end

    local lastScanTs = 0
    if _G.PCF_DB then
        local fullTs = tonumber(_G.PCF_DB.lastFullScan) or 0
        local repTs = tonumber(_G.PCF_DB.lastReplicateScan) or 0
        lastScanTs = math.max(fullTs, repTs)
    end

    local feedItems = 0
    local feedTs = 0
    if PF.MarketFeed and PF.MarketFeed.GetFeedTable then
        local feed = PF.MarketFeed.GetFeedTable()
        if feed and type(feed.items) == "table" then
            feedTs = tonumber(feed.timestamp) or 0
            for itemId, row in pairs(feed.items) do
                if type(itemId) == "number" and itemId > 0 and type(row) == "table" and row.m and row.m > 0 then
                    feedItems = feedItems + 1
                end
            end
        end
    end

    local totalItems = math.max(pcfItems, feedItems)
    local effectivePCFTs = 0
    if pcfItems > 0 then
        effectivePCFTs = (lastScanTs > 0) and lastScanTs or newestEntryTs
    end
    local effectiveFeedTs = (feedItems > 0) and feedTs or 0
    local bestTs = math.max(effectivePCFTs, effectiveFeedTs)

    if totalItems <= 0 then
        return "NO_DATA", {
            status = "NO_DATA",
            itemCount = 0,
            pcfItems = 0,
            feedItems = 0,
            lastScanTimestamp = 0,
            ageSeconds = nil,
            ageText = "never",
        }
    end

    if bestTs <= 0 and hasUntimestampedEntry then
        return "FRESH", {
            status = "FRESH",
            itemCount = totalItems,
            pcfItems = pcfItems,
            feedItems = feedItems,
            lastScanTimestamp = now,
            ageSeconds = 0,
            ageText = "0m",
        }
    end

    local ageSeconds = math.max(0, now - bestTs)
    local ageText = PF.FormatAgeShort(ageSeconds)
    local status = (ageSeconds > threshold) and "STALE" or "FRESH"

    return status, {
        status = status,
        itemCount = totalItems,
        pcfItems = pcfItems,
        feedItems = feedItems,
        lastScanTimestamp = bestTs,
        ageSeconds = ageSeconds,
        ageText = ageText,
    }
end

function PF.LoadConfig(customDB)
    if type(customDB) == "table" then
        Profitable_DB = customDB
    else
        Profitable_DB = (type(_G.Profitable_DB) == "table" and _G.Profitable_DB) or {}
    end
    _G.Profitable_DB = Profitable_DB

    local prevVersion = tonumber(Profitable_DB.version) or 0
    ApplyDefaults(Profitable_DB, defaultConfig)

    -- v2 migration: always live-verify top plays at the AH instead of skipping for 2h MarketFeed snapshots
    if prevVersion > 0 and prevVersion < 2 then
        if Profitable_DB.settings and Profitable_DB.settings.marketFeedVerifySkipSeconds == 7200 then
            Profitable_DB.settings.marketFeedVerifySkipSeconds = 0
        end
    end

    -- v3 migration: flush orderBookCache and any sniff/live-verify prices that may have divided
    -- collapsed non-commodity C_AuctionHouse.GetItemSearchResultInfo buyouts by quantity
    if prevVersion > 0 and prevVersion < 3 then
        local function PurgeTaintedSniffPrices(dbTable)
            if type(dbTable) == "table" and type(dbTable.prices) == "table" then
                for itemId, entry in pairs(dbTable.prices) do
                    if type(entry) == "table" and (entry.source == "Profitable Live" or entry.source == "PCF Sniff") then
                        dbTable.prices[itemId] = nil
                    end
                end
            end
        end
        PurgeTaintedSniffPrices(_G.PCF_DB)
        PurgeTaintedSniffPrices(Profitable_DB.embeddedPCF)
        Profitable_DB.orderBookCache = {}
        Profitable_DB.lastTopPlays = {}
        Profitable_DB.lastHonorableMentions = {}
        Profitable_DB.activePlay = nil
        Profitable_DB.version = 3
    end

    return Profitable_DB
end
