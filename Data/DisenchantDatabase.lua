local _, PF = ...
PF = type(PF) == "table" and PF or _G.PF or {}
_G.PF = PF

PF.DisenchantDatabase = {}

-- Crafted enchanting wands & special items that cannot be disenchanted in Classic / Forever
local NON_DISENCHANTABLE_ITEMS = {
    [11287] = true, -- Lesser Magic Wand (cannot be DE'd; great Craft & Vendor play instead)
    [11288] = true, -- Greater Magic Wand
    [11289] = true, -- Lesser Mystic Wand
    [11290] = true, -- Greater Mystic Wand
}

local NON_DISENCHANTABLE_INVTYPES = {
    ["INVTYPE_BODY"] = true,       -- Shirts
    ["INVTYPE_TABARD"] = true,     -- Tabards
    ["INVTYPE_BAG"] = true,        -- Bags
    ["INVTYPE_QUIVER"] = true,     -- Quivers
    ["INVTYPE_AMMO"] = true,       -- Projectiles
    ["INVTYPE_THROWN"] = true,     -- Thrown weapons
}

-- 3 Lesser Essence <-> 1 Greater Essence right-click conversions
local ESSENCE_CONVERSIONS = {
    [10938] = { partnerId = 10939, ratio = 1 / 3, action = "combine 3->1 Greater Magic Essence" },
    [10939] = { partnerId = 10938, ratio = 3,     action = "split 1->3 Lesser Magic Essence" },
    [10998] = { partnerId = 11082, ratio = 1 / 3, action = "combine 3->1 Greater Astral Essence" },
    [11082] = { partnerId = 10998, ratio = 3,     action = "split 1->3 Lesser Astral Essence" },
    [11134] = { partnerId = 11135, ratio = 1 / 3, action = "combine 3->1 Greater Mystic Essence" },
    [11135] = { partnerId = 11134, ratio = 3,     action = "split 1->3 Lesser Mystic Essence" },
    [11174] = { partnerId = 11175, ratio = 1 / 3, action = "combine 3->1 Greater Nether Essence" },
    [11175] = { partnerId = 11174, ratio = 3,     action = "split 1->3 Lesser Nether Essence" },
    [16202] = { partnerId = 16203, ratio = 1 / 3, action = "combine 3->1 Greater Eternal Essence" },
    [16203] = { partnerId = 16202, ratio = 3,     action = "split 1->3 Lesser Eternal Essence" },
}

-- Uncommon (Quality = 2) bracket table
-- In Classic/Forever: Armor is Dust-heavy (75% Dust / 20% Essence / 5% Shard),
-- while Weapons are Essence-heavy (75% Essence / 20% Dust / 5% Shard).
local UNCOMMON_BRACKETS = {
    {
        minIlvl = 1, maxIlvl = 15,
        dustId = 10940, dustMin = 1, dustMax = 2,
        essenceId = 10938, essenceMin = 1, essenceMax = 2,
        shardId = nil,
        armorDustProb = 0.80, armorEssProb = 0.20, armorShardProb = 0.00,
        weapDustProb  = 0.20, weapEssProb  = 0.80, weapShardProb  = 0.00,
    },
    {
        minIlvl = 16, maxIlvl = 20,
        dustId = 10940, dustMin = 2, dustMax = 3,
        essenceId = 10939, essenceMin = 1, essenceMax = 2,
        shardId = 10978,
        armorDustProb = 0.75, armorEssProb = 0.20, armorShardProb = 0.05,
        weapDustProb  = 0.20, weapEssProb  = 0.75, weapShardProb  = 0.05,
    },
    {
        minIlvl = 21, maxIlvl = 25,
        dustId = 10940, dustMin = 4, dustMax = 6,
        essenceId = 10998, essenceMin = 1, essenceMax = 2,
        shardId = 10978,
        armorDustProb = 0.75, armorEssProb = 0.15, armorShardProb = 0.10,
        weapDustProb  = 0.15, weapEssProb  = 0.75, weapShardProb  = 0.10,
    },
    {
        minIlvl = 26, maxIlvl = 30,
        dustId = 11083, dustMin = 1, dustMax = 2,
        essenceId = 11082, essenceMin = 1, essenceMax = 2,
        shardId = 11084,
        armorDustProb = 0.75, armorEssProb = 0.20, armorShardProb = 0.05,
        weapDustProb  = 0.20, weapEssProb  = 0.75, weapShardProb  = 0.05,
    },
    {
        minIlvl = 31, maxIlvl = 35,
        dustId = 11083, dustMin = 2, dustMax = 5,
        essenceId = 11134, essenceMin = 1, essenceMax = 2,
        shardId = 11138,
        armorDustProb = 0.75, armorEssProb = 0.20, armorShardProb = 0.05,
        weapDustProb  = 0.20, weapEssProb  = 0.75, weapShardProb  = 0.05,
    },
    {
        minIlvl = 36, maxIlvl = 40,
        dustId = 11137, dustMin = 1, dustMax = 2,
        essenceId = 11135, essenceMin = 1, essenceMax = 2,
        shardId = 11139,
        armorDustProb = 0.75, armorEssProb = 0.20, armorShardProb = 0.05,
        weapDustProb  = 0.20, weapEssProb  = 0.75, weapShardProb  = 0.05,
    },
    {
        minIlvl = 41, maxIlvl = 45,
        dustId = 11137, dustMin = 2, dustMax = 5,
        essenceId = 11174, essenceMin = 1, essenceMax = 2,
        shardId = 11177,
        armorDustProb = 0.75, armorEssProb = 0.20, armorShardProb = 0.05,
        weapDustProb  = 0.20, weapEssProb  = 0.75, weapShardProb  = 0.05,
    },
    {
        minIlvl = 46, maxIlvl = 50,
        dustId = 11176, dustMin = 1, dustMax = 2,
        essenceId = 11175, essenceMin = 1, essenceMax = 2,
        shardId = 11178,
        armorDustProb = 0.75, armorEssProb = 0.20, armorShardProb = 0.05,
        weapDustProb  = 0.20, weapEssProb  = 0.75, weapShardProb  = 0.05,
    },
    {
        minIlvl = 51, maxIlvl = 55,
        dustId = 11176, dustMin = 2, dustMax = 5,
        essenceId = 16202, essenceMin = 1, essenceMax = 2,
        shardId = 14343,
        armorDustProb = 0.75, armorEssProb = 0.20, armorShardProb = 0.05,
        weapDustProb  = 0.20, weapEssProb  = 0.75, weapShardProb  = 0.05,
    },
    {
        minIlvl = 56, maxIlvl = 60,
        dustId = 16204, dustMin = 1, dustMax = 2,
        essenceId = 16203, essenceMin = 1, essenceMax = 2,
        shardId = 14344,
        armorDustProb = 0.75, armorEssProb = 0.20, armorShardProb = 0.05,
        weapDustProb  = 0.20, weapEssProb  = 0.75, weapShardProb  = 0.05,
    },
    {
        minIlvl = 61, maxIlvl = 999,
        dustId = 16204, dustMin = 2, dustMax = 5,
        essenceId = 16203, essenceMin = 2, essenceMax = 3,
        shardId = 14344,
        armorDustProb = 0.75, armorEssProb = 0.20, armorShardProb = 0.05,
        weapDustProb  = 0.20, weapEssProb  = 0.75, weapShardProb  = 0.05,
    },
}

local RARE_BRACKETS = {
    { minIlvl = 1,  maxIlvl = 25, shardId = 10978, shardProb = 1.00 },
    { minIlvl = 26, maxIlvl = 30, shardId = 11084, shardProb = 1.00 },
    { minIlvl = 31, maxIlvl = 35, shardId = 11138, shardProb = 1.00 },
    { minIlvl = 36, maxIlvl = 40, shardId = 11139, shardProb = 1.00 },
    { minIlvl = 41, maxIlvl = 45, shardId = 11177, shardProb = 1.00 },
    { minIlvl = 46, maxIlvl = 50, shardId = 11178, shardProb = 1.00 },
    { minIlvl = 51, maxIlvl = 55, shardId = 14343, shardProb = 0.995, nexusProb = 0.005 },
    { minIlvl = 56, maxIlvl = 999, shardId = 14344, shardProb = 0.995, nexusProb = 0.005 },
}

local EPIC_BRACKETS = {
    { minIlvl = 1,  maxIlvl = 45, itemId = 11177, minQty = 2, maxQty = 4 },
    { minIlvl = 46, maxIlvl = 50, itemId = 11178, minQty = 2, maxQty = 4 },
    { minIlvl = 51, maxIlvl = 55, itemId = 14343, minQty = 2, maxQty = 4 },
    { minIlvl = 56, maxIlvl = 999, itemId = 20725, minQty = 1, maxQty = 2 },
}

function PF.DisenchantDatabase.CanDisenchant(itemId, itemLink)
    if Profitable_DB and Profitable_DB.settings and Profitable_DB.settings.assumeCanDisenchant == false then
        return false
    end
    if not itemId or NON_DISENCHANTABLE_ITEMS[itemId] then
        return false
    end

    local meta = PF.VendorDatabase and PF.VendorDatabase.GetItemMetadata(itemId, itemLink)
    if not meta then
        return false
    end

    local quality = meta.quality or 0
    if quality < 2 or quality > 4 then
        return false
    end

    local classID = meta.classID
    if classID ~= 2 and classID ~= 4 then
        return false
    end

    local invType = meta.invType or ""
    if NON_DISENCHANTABLE_INVTYPES[invType] then
        return false
    end
    -- Armor pieces must have a valid equippable slot (excludes non-equippable armor tokens/shields spikes)
    if classID == 4 and invType == "" then
        return false
    end

    return true
end

function PF.DisenchantDatabase.GetDisenchantDrops(itemId, itemLink)
    if not PF.DisenchantDatabase.CanDisenchant(itemId, itemLink) then
        return nil
    end

    local meta = PF.VendorDatabase.GetItemMetadata(itemId, itemLink)
    if not meta then return nil end

    local quality = meta.quality
    local ilvl = math.max(1, meta.itemLevel or 1)
    local isWeapon = (meta.classID == 2)
    local drops = {}

    if quality == 2 then
        for _, b in ipairs(UNCOMMON_BRACKETS) do
            if ilvl >= b.minIlvl and ilvl <= b.maxIlvl then
                local dustProb = isWeapon and b.weapDustProb or b.armorDustProb
                local essProb = isWeapon and b.weapEssProb or b.armorEssProb
                local shardProb = isWeapon and b.weapShardProb or b.armorShardProb

                if b.dustId and dustProb > 0 then
                    table.insert(drops, {
                        itemId = b.dustId,
                        prob = dustProb,
                        minQty = b.dustMin,
                        maxQty = b.dustMax,
                        avgQty = (b.dustMin + b.dustMax) / 2,
                    })
                end
                if b.essenceId and essProb > 0 then
                    table.insert(drops, {
                        itemId = b.essenceId,
                        prob = essProb,
                        minQty = b.essenceMin,
                        maxQty = b.essenceMax,
                        avgQty = (b.essenceMin + b.essenceMax) / 2,
                    })
                end
                if b.shardId and shardProb > 0 then
                    table.insert(drops, {
                        itemId = b.shardId,
                        prob = shardProb,
                        minQty = 1,
                        maxQty = 1,
                        avgQty = 1.0,
                    })
                end
                break
            end
        end
    elseif quality == 3 then
        for _, b in ipairs(RARE_BRACKETS) do
            if ilvl >= b.minIlvl and ilvl <= b.maxIlvl then
                table.insert(drops, {
                    itemId = b.shardId,
                    prob = b.shardProb,
                    minQty = 1,
                    maxQty = 1,
                    avgQty = 1.0,
                })
                if b.nexusProb and b.nexusProb > 0 then
                    table.insert(drops, {
                        itemId = 20725,
                        prob = b.nexusProb,
                        minQty = 1,
                        maxQty = 1,
                        avgQty = 1.0,
                    })
                end
                break
            end
        end
    elseif quality == 4 then
        for _, b in ipairs(EPIC_BRACKETS) do
            if ilvl >= b.minIlvl and ilvl <= b.maxIlvl then
                table.insert(drops, {
                    itemId = b.itemId,
                    prob = 1.0,
                    minQty = b.minQty,
                    maxQty = b.maxQty,
                    avgQty = (b.minQty + b.maxQty) / 2,
                })
                break
            end
        end
    end

    if #drops == 0 then
        return nil
    end
    return drops
end

function PF.DisenchantDatabase.EvaluateDisenchant(itemId, itemLink, resolveAHPriceFunc, ahCutRate)
    local drops = PF.DisenchantDatabase.GetDisenchantDrops(itemId, itemLink)
    if not drops then
        return nil
    end

    local cut = (type(ahCutRate) == "number" and ahCutRate >= 0 and ahCutRate < 1)
        and ahCutRate
        or ((Profitable_DB and Profitable_DB.settings and Profitable_DB.settings.ahCutRate) or 0.05)

    local grossExpected = 0
    local breakdown = {}
    local anyPriceFound = false

    for _, drop in ipairs(drops) do
        local unitPrice = resolveAHPriceFunc and resolveAHPriceFunc(drop.itemId) or nil
        local conversionNote = nil
        local targetSellItemId = drop.itemId

        -- Check if converting Lesser <-> Greater Essence yields a higher AH value
        local conv = ESSENCE_CONVERSIONS[drop.itemId]
        if conv and resolveAHPriceFunc then
            local partnerPrice = resolveAHPriceFunc(conv.partnerId)
            if partnerPrice and partnerPrice > 0 then
                local convertedUnitValue = math.floor(partnerPrice * conv.ratio)
                if not unitPrice or convertedUnitValue > unitPrice then
                    unitPrice = convertedUnitValue
                    conversionNote = conv.action
                    targetSellItemId = conv.partnerId
                end
            end
        end

        if unitPrice and unitPrice > 0 then
            anyPriceFound = true
            local expectedUnits = drop.prob * drop.avgQty
            local expectedGross = expectedUnits * unitPrice
            grossExpected = grossExpected + expectedGross

            local dropMeta = PF.VendorDatabase.GetItemMetadata(targetSellItemId) or PF.VendorDatabase.GetItemMetadata(drop.itemId)
            local dropName = (dropMeta and dropMeta.name) or string.format("Item #%d", targetSellItemId)
            local dropQuality = (dropMeta and dropMeta.quality) or 1
            table.insert(breakdown, {
                itemId = drop.itemId,
                sellItemId = targetSellItemId,
                name = dropName,
                quality = dropQuality,
                link = PF.Formatter.BuildItemLink(targetSellItemId, dropName, dropQuality),
                prob = drop.prob,
                minQty = drop.minQty,
                maxQty = drop.maxQty,
                avgQty = drop.avgQty,
                unitPrice = unitPrice,
                expectedGross = math.floor(expectedGross + 0.5),
                expectedNet = math.floor(expectedGross * (1 - cut) + 0.5),
                conversionNote = conversionNote,
            })
        end
    end

    if not anyPriceFound or grossExpected <= 0 then
        return nil
    end

    local grossCopper = math.floor(grossExpected + 0.5)
    local netCopper = math.floor(grossExpected * (1 - cut) + 0.5)

    -- Identify the primary target enchanting material (the drop contributing the most net value)
    local primaryMat = breakdown[1]
    for _, d in ipairs(breakdown) do
        if d.expectedNet > (primaryMat and primaryMat.expectedNet or -1) then
            primaryMat = d
        end
    end

    return {
        grossValue = grossCopper,
        netValue = netCopper,
        ahCut = grossCopper - netCopper,
        drops = breakdown,
        primaryMat = primaryMat,
        isShardOrCrystal = (primaryMat and (primaryMat.quality or 1) >= 3) or false,
    }
end
