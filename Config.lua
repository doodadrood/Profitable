local addonName, PF = ...
PF = (_G.PF_INITIALIZED and _G.PF) or (type(PF) == "table" and PF) or _G.PF or {}
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
        ahCutRate = 0.05,                -- Standard 5% faction AH cut
        maxCalculationSeconds = 90,      -- 1.5 minute calculation/verification cap
        extremeProfitMultiplier = 2.0,   -- Keep finishing verification if candidate is >= 2x current #1 profit
        extremeGraceSeconds = 30,        -- Extra seconds allowed for an extremely profitable play
        topCount = 5,                    -- Number of top plays to display
        verifyCandidateCount = 10,       -- Number of top candidates to double-check on live AH
        minProfitCopper = 100,           -- Minimum 1 silver total profit to list
        minROIPercent = 5,               -- Minimum 5% ROI to avoid tying up all gold for pennies
        maxAHCraftUnits = 20,            -- Cap per-play crafted units for AH resale so market isn't flooded
        maxDEUnits = 50,                 -- Cap per-play DE units
        maxVendorUnits = 200,            -- Vendor plays have infinite demand, capped only by AH supply & gold
        includeAllCharRecipes = false,   -- false = only current logged-in character's recipes
        assumeCanDisenchant = true,      -- Bank alt can always DE
        useIntermediateCrafting = true,  -- Consider smelting ore->bars / cloth->bolts when cheaper than buying bar/bolt
        showSideWindow = true,
    },
    charRecipes = {},     -- [charKey] = { [recipeKey] = recipeTable }
    vendorBuyPrices = {}, -- [itemId] = copperPrice (learned dynamically from vendors + static DB)
    itemCache = {},       -- [itemId] = { name, link, quality, itemLevel, classID, subClassID, invType, texture, vendorSell }
    orderBookCache = {},  -- [itemId] = { timestamp = 0, listings = { { unitPrice = 0, quantity = 0 }, ... } }
    lastTopPlays = {},    -- Cached top 5 opportunities from most recent run
    activePlay = nil,     -- Currently tracked opportunity in DetailWindow
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
