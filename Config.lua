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
    version = 1,
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
        assumeCanDisenchant = true,              -- Bank alt can always DE
        useIntermediateCrafting = true,          -- Consider smelting ore->bars / cloth->bolts when cheaper than buying bar/bolt
        useHistoricalSpikeGuard = true,          -- Cap spiked exit prices using SQLite 14-day median when MarketFeed is present
        maxSpikeMultiplier = 2.0,                -- Flag/cap when live exit price exceeds 2.0x 14-day median
        spikeCapMultiplier = 1.25,               -- Cap estimated exit revenue to 1.25x 14-day median
        minHistoricalSamples = 3,                -- Require >= 3 hourly snapshots before enforcing spike cap
        mirrorFeedToPCF = true,                  -- Softly fill missing/older PCF_DB prices from MarketFeed when both are active
        marketFeedVerifySkipSeconds = 7200,      -- Skip live AH query if MarketFeed order book is fresher than 2h (Shift-click forces live)
        showSideWindow = true,
    },
    charRecipes = {},     -- [charKey] = { [recipeKey] = recipeTable }
    vendorBuyPrices = {}, -- [itemId] = copperPrice (learned dynamically from vendors + static DB)
    vendorAlerts = {},    -- Recent limited-supply vendor arbitrage opportunities found at NPCs
    itemCache = {},       -- [itemId] = { name, link, quality, itemLevel, classID, subClassID, invType, texture, vendorSell }
    orderBookCache = {},        -- [itemId] = { timestamp = 0, listings = { { unitPrice = 0, quantity = 0 }, ... } }
    lastTopPlays = {},          -- Cached top 5 opportunities from most recent run
    lastHonorableMentions = {}, -- Cached honorable mention plays (Top Craft & Top Vendor)
    activePlay = nil,           -- Currently tracked opportunity in DetailWindow
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

function PF.LoadConfig(customDB)
    if type(customDB) == "table" then
        Profitable_DB = customDB
    else
        Profitable_DB = (type(_G.Profitable_DB) == "table" and _G.Profitable_DB) or {}
    end
    _G.Profitable_DB = Profitable_DB
    ApplyDefaults(Profitable_DB, defaultConfig)
    return Profitable_DB
end
