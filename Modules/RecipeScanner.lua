local PF = _G.PF or {}
_G.PF = PF
_G.Profitable = PF

PF.RecipeScanner = {}

local SKILL_LINE_ID_TO_PROFESSION = {
    [129] = "First Aid",
    [164] = "Blacksmithing",
    [165] = "Leatherworking",
    [171] = "Alchemy",
    [182] = "Herbalism",
    [185] = "Cooking",
    [186] = "Mining",
    [197] = "Tailoring",
    [202] = "Engineering",
    [333] = "Enchanting",
    [356] = "Fishing",
    [393] = "Skinning",
    [755] = "Jewelcrafting",
    [773] = "Inscription",
}

local PROFESSION_TO_SKILL_LINE_ID = {
    ["First Aid"]      = 129,
    ["Blacksmithing"]  = 164,
    ["Leatherworking"] = 165,
    ["Alchemy"]        = 171,
    ["Herbalism"]      = 182,
    ["Cooking"]        = 185,
    ["Mining"]         = 186,
    ["Smelting"]       = 186,
    ["Tailoring"]      = 197,
    ["Engineering"]    = 202,
    ["Enchanting"]     = 333,
    ["Jewelcrafting"]  = 755,
    ["Inscription"]    = 773,
}

local INVALID_CRAFTING_PROFESSIONS = {
    [""] = true,
    ["UNKNOWN"] = true,
    ["Crafting"] = true,
    ["TradeSkill"] = true,
    ["Profession"] = true,
    ["Fishing"] = true,
}

local pendingOpenRecipe = nil
local pendingScanRetry = false
local recipeCacheRevision = 0
local recipeCountCache = nil
local activeBatchIndex = nil
local batchDepth = 0

function PF.RecipeScanner.InvalidateCache()
    recipeCacheRevision = recipeCacheRevision + 1
    recipeCountCache = nil
    activeBatchIndex = nil
    batchDepth = 0
end

function PF.RecipeScanner.GetCacheRevision()
    return recipeCacheRevision
end

local function NormalizeItemName(name)
    if type(name) ~= "string" then return nil end
    local trimmed = name:match("^%s*(.-)%s*$")
    if not trimmed or trimmed == "" then return nil end
    return trimmed:lower()
end

local function IsBaselineOutputNameValid(base)
    if type(base) ~= "table" or not base.outputItemId or base.outputItemId <= 0 then
        return false
    end
    local locale = (_G.GetLocale and _G.GetLocale()) or "enUS"
    if locale ~= "enUS" and locale ~= "enGB" then
        return true
    end
    local expected = NormalizeItemName(base.outputName or base.name)
    if not expected then
        return true
    end
    if PF.VendorDatabase and PF.VendorDatabase.GetLiveOrCachedItemMetadata then
        local liveMeta = PF.VendorDatabase.GetLiveOrCachedItemMetadata(base.outputItemId, nil, true)
        local liveName = liveMeta and NormalizeItemName(liveMeta.name) or nil
        if liveName and liveName ~= expected then
            return false
        end
    end
    return true
end

local function ReagentsMatch(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then
        return false
    end
    local countsA = {}
    local uniqueA = 0
    for _, r in ipairs(a) do
        if not r or not r.itemId then return false end
        if not countsA[r.itemId] then uniqueA = uniqueA + 1 end
        countsA[r.itemId] = (countsA[r.itemId] or 0) + (r.count or r.countPerUnit or 1)
    end
    local countsB = {}
    local uniqueB = 0
    for _, r in ipairs(b) do
        if not r or not r.itemId then return false end
        if not countsB[r.itemId] then uniqueB = uniqueB + 1 end
        countsB[r.itemId] = (countsB[r.itemId] or 0) + (r.count or r.countPerUnit or 1)
    end
    if uniqueA ~= uniqueB then
        return false
    end
    for id, cnt in pairs(countsA) do
        if countsB[id] ~= cnt then return false end
    end
    return true
end

local function InvalidateStaleBaselinePlaysForScannedRecipe(recipe)
    if type(Profitable_DB) ~= "table" or type(recipe) ~= "table" or not recipe.outputItemId then
        return
    end
    local function IsStaleBaselineOpp(opp)
        return type(opp) == "table"
            and type(opp.recipe) == "table"
            and opp.recipe.isTrainerRecommendation == true
            and (opp.itemId == recipe.outputItemId or opp.recipe.outputItemId == recipe.outputItemId)
            and not ReagentsMatch(opp.recipe.reagents, recipe.reagents)
    end
    local function FilterList(list)
        if type(list) ~= "table" then return nil end
        local kept = {}
        local removed = false
        for _, opp in ipairs(list) do
            if IsStaleBaselineOpp(opp) then
                removed = true
            else
                table.insert(kept, opp)
            end
        end
        return removed and kept or nil
    end
    local filteredTop = FilterList(Profitable_DB.lastTopPlays)
    if filteredTop then
        Profitable_DB.lastTopPlays = filteredTop
    end
    local filteredHM = FilterList(Profitable_DB.lastHonorableMentions)
    if filteredHM then
        Profitable_DB.lastHonorableMentions = filteredHM
    end
    if IsStaleBaselineOpp(Profitable_DB.activePlay) then
        Profitable_DB.activePlay = nil
    end
end

local function CleanProfessionName(rawName, skillLineId)
    if type(skillLineId) == "number" and skillLineId > 0 then
        local canonical = SKILL_LINE_ID_TO_PROFESSION[skillLineId]
        if canonical and not INVALID_CRAFTING_PROFESSIONS[canonical] then
            if _G.C_TradeSkillUI and _G.C_TradeSkillUI.GetTradeSkillDisplayName then
                local okDisp, dispName = pcall(_G.C_TradeSkillUI.GetTradeSkillDisplayName, skillLineId)
                if okDisp and type(dispName) == "string" and not INVALID_CRAFTING_PROFESSIONS[dispName] then
                    return dispName
                end
            end
            return canonical
        end
    end

    if type(rawName) ~= "string" then
        return nil
    end
    local trimmed = rawName:match("^%s*(.-)%s*$") or ""
    if INVALID_CRAFTING_PROFESSIONS[trimmed] then
        return nil
    end
    if PROFESSION_TO_SKILL_LINE_ID[trimmed] then
        return trimmed
    end
    -- Strip expansion prefixes such as "Classic Cooking" or "Outland Blacksmithing"
    for baseName in pairs(PROFESSION_TO_SKILL_LINE_ID) do
        if trimmed:sub(-(#baseName + 1)) == (" " .. baseName) then
            return baseName
        end
    end
    return trimmed
end

local function ExtractProfessionFromInfo(info)
    if type(info) ~= "table" then
        return nil, nil
    end
    local profId = nil
    if type(info.parentProfessionID) == "number" and info.parentProfessionID > 0 then
        profId = info.parentProfessionID
    elseif type(info.professionID) == "number" and info.professionID > 0 then
        profId = info.professionID
    elseif info.profession ~= nil and _G.C_TradeSkillUI and _G.C_TradeSkillUI.GetProfessionSkillLineID then
        local okId, mappedId = pcall(_G.C_TradeSkillUI.GetProfessionSkillLineID, info.profession)
        if okId and type(mappedId) == "number" and mappedId > 0 then
            profId = mappedId
        end
    end

    local rawName = nil
    if type(info.parentProfessionName) == "string" and info.parentProfessionName ~= "" and info.parentProfessionName ~= "UNKNOWN" then
        rawName = info.parentProfessionName
    elseif type(info.professionName) == "string" and info.professionName ~= "" and info.professionName ~= "UNKNOWN" then
        rawName = info.professionName
    end

    local cleanName = CleanProfessionName(rawName, profId)
    if cleanName then
        local baseId = PROFESSION_TO_SKILL_LINE_ID[cleanName]
        if baseId and (not profId or not SKILL_LINE_ID_TO_PROFESSION[profId]) then
            profId = baseId
        end
        return cleanName, profId or baseId
    end
    return nil, nil
end

local function FindBaselineProfessionByOutput(outputItemId)
    if not outputItemId or outputItemId <= 0 then return nil, nil end
    if PF.RecipeDatabase and PF.RecipeDatabase.GetAllBaselineRecipes then
        for _, base in ipairs(PF.RecipeDatabase.GetAllBaselineRecipes()) do
            if base.outputItemId == outputItemId
                and IsBaselineOutputNameValid(base)
                and type(base.profession) == "string"
                and not INVALID_CRAFTING_PROFESSIONS[base.profession] then
                return base.profession, PROFESSION_TO_SKILL_LINE_ID[base.profession]
            end
        end
    end
    return nil, nil
end

local function ResolveRecipeProfession(recipeId, fallbackName, fallbackId, outputItemId, existingRecipe)
    -- 1. Authoritative per-recipe lookup (immune to profession-window switching race conditions)
    if type(recipeId) == "number" and recipeId > 0 and _G.C_TradeSkillUI then
        if _G.C_TradeSkillUI.GetProfessionInfoByRecipeID then
            local okInfo, info = pcall(_G.C_TradeSkillUI.GetProfessionInfoByRecipeID, recipeId)
            if okInfo and type(info) == "table" then
                local name, id = ExtractProfessionFromInfo(info)
                if name then
                    return name, id
                end
            end
        end
        if _G.C_TradeSkillUI.GetTradeSkillLineForRecipe then
            local okLine, tradeSkillID, skillLineName, parentTradeSkillID = pcall(_G.C_TradeSkillUI.GetTradeSkillLineForRecipe, recipeId)
            if okLine then
                local profId = (type(parentTradeSkillID) == "number" and parentTradeSkillID > 0) and parentTradeSkillID
                    or ((type(tradeSkillID) == "number" and tradeSkillID > 0) and tradeSkillID or nil)
                local name = CleanProfessionName(skillLineName, profId)
                if name then
                    return name, profId or PROFESSION_TO_SKILL_LINE_ID[name]
                end
            end
        end
    end

    -- 2. Valid window-level fallback (never accepts Crafting/TradeSkill/Fishing)
    local fbName = CleanProfessionName(fallbackName, fallbackId)
    if fbName then
        return fbName, fallbackId or PROFESSION_TO_SKILL_LINE_ID[fbName]
    end

    -- 3. Baseline static recipe database match by output item
    local baseProf, baseId = FindBaselineProfessionByOutput(outputItemId)
    if baseProf then
        return baseProf, baseId
    end

    -- 4. Preserve an existing valid profession rather than downgrading it
    if type(existingRecipe) == "table" then
        local existingName = CleanProfessionName(existingRecipe.profession, existingRecipe.professionId)
        if existingName then
            return existingName, existingRecipe.professionId or PROFESSION_TO_SKILL_LINE_ID[existingName]
        end
    end

    -- 5. Last-resort item metadata heuristic for Food & Drink -> Cooking
    if type(outputItemId) == "number" and outputItemId > 0 and PF.VendorDatabase and PF.VendorDatabase.GetItemMetadata then
        local meta = PF.VendorDatabase.GetItemMetadata(outputItemId)
        if meta and (meta.itemSubType == "Food & Drink" or (meta.classID == 0 and meta.subClassID == 5)) then
            return "Cooking", 185
        end
    end

    return "Crafting", nil
end

local function ResolveSkillLineId(recipe)
    if not recipe then return nil end

    if type(recipe.recipeId) == "number" and recipe.recipeId > 0 and _G.C_TradeSkillUI then
        local name, id = ResolveRecipeProfession(recipe.recipeId, nil, nil, recipe.outputItemId, nil)
        if name and not INVALID_CRAFTING_PROFESSIONS[name] then
            recipe.profession = name
        end
        if type(id) == "number" and id > 0 then
            recipe.professionId = id
            return id
        end
    end

    if type(recipe.professionId) == "number" and recipe.professionId > 0 then
        return recipe.professionId
    end

    local profName = recipe.profession
    if type(profName) == "string" and profName ~= "" then
        if _G.GetProfessions and _G.GetProfessionInfo then
            local okProfs, p1, p2, arch, fish, cook, firstAid = pcall(_G.GetProfessions)
            if okProfs then
                local targetLower = profName:lower()
                local slots = { p1, p2, arch, fish, cook, firstAid }
                for slotIdx = 1, 6 do
                    local idx = slots[slotIdx]
                    if type(idx) == "number" then
                        local okInfo, pName, _, _, _, _, _, skillLine = pcall(_G.GetProfessionInfo, idx)
                        if okInfo and type(pName) == "string" and pName:lower() == targetLower and type(skillLine) == "number" and skillLine > 0 then
                            recipe.professionId = skillLine
                            return skillLine
                        end
                    end
                end
            end
        end
        local mapped = PROFESSION_TO_SKILL_LINE_ID[profName]
        if mapped then
            recipe.professionId = mapped
            return mapped
        end
    end

    return nil
end

local function GetCurrentCharacterProfessions()
    local profNames = {}
    local profNamesLower = {}
    local skillLineIds = {}
    local skillRanks = {}
    local hasAuthData = false

    if PF.RecipeDatabase and PF.RecipeDatabase.GetCharacterSkillRanks then
        local rawRanks, hasSkillData = PF.RecipeDatabase.GetCharacterSkillRanks()
        skillRanks = rawRanks or {}
        hasAuthData = (hasSkillData == true)
        for rawName, info in pairs(skillRanks) do
            local rank = (type(info) == "table" and info.rank) or 1
            local skillLine = type(info) == "table" and info.skillLine or nil
            local displayName = type(info) == "table" and info.displayName or nil
            local cleanName = CleanProfessionName(rawName, skillLine)
            if cleanName then
                profNames[cleanName] = math.max(profNames[cleanName] or 0, rank)
                profNamesLower[cleanName:lower()] = math.max(profNamesLower[cleanName:lower()] or 0, rank)
                local mappedId = skillLine or PROFESSION_TO_SKILL_LINE_ID[cleanName]
                if mappedId then
                    skillLineIds[mappedId] = math.max(skillLineIds[mappedId] or 0, rank)
                end
            end
            if type(rawName) == "string" and rawName ~= "" then
                profNames[rawName] = math.max(profNames[rawName] or 0, rank)
                profNamesLower[rawName:lower()] = math.max(profNamesLower[rawName:lower()] or 0, rank)
                local rawId = PROFESSION_TO_SKILL_LINE_ID[rawName]
                if rawId then
                    skillLineIds[rawId] = math.max(skillLineIds[rawId] or 0, rank)
                end
            end
            if type(displayName) == "string" and displayName ~= "" then
                profNames[displayName] = math.max(profNames[displayName] or 0, rank)
                profNamesLower[displayName:lower()] = math.max(profNamesLower[displayName:lower()] or 0, rank)
            end
        end
    end

    return profNames, profNamesLower, skillLineIds, hasAuthData, skillRanks
end

local function IsRecipeLearnedByCurrentCharacter(recipe, profNames, profNamesLower, skillLineIds, hasAuthData)
    if type(recipe) ~= "table" then
        return false
    end

    if type(recipe.recipeId) == "number" and recipe.recipeId > 0
        and _G.C_TradeSkillUI and _G.C_TradeSkillUI.IsRecipeProfessionLearned then
        local okLearned, isLearned = pcall(_G.C_TradeSkillUI.IsRecipeProfessionLearned, recipe.recipeId)
        if okLearned and isLearned == false then
            return false
        end
    end

    if not hasAuthData then
        return true
    end

    if type(recipe.professionId) == "number" and recipe.professionId > 0 then
        if skillLineIds[recipe.professionId] then
            return true
        end
        local canonicalFromId = SKILL_LINE_ID_TO_PROFESSION[recipe.professionId]
        if canonicalFromId and (profNames[canonicalFromId] or profNamesLower[canonicalFromId:lower()]) then
            return true
        end
    end

    if type(recipe.profession) == "string" and recipe.profession ~= "" then
        local clean = CleanProfessionName(recipe.profession, recipe.professionId) or recipe.profession
        if profNames[clean] or profNamesLower[clean:lower()] then
            return true
        end
        local mappedId = PROFESSION_TO_SKILL_LINE_ID[clean]
        if mappedId and skillLineIds[mappedId] then
            return true
        end
        if INVALID_CRAFTING_PROFESSIONS[clean] and next(skillLineIds) ~= nil then
            return true
        end
        return false
    end

    return next(skillLineIds) ~= nil
end

function PF.RecipeScanner.NormalizeRecipeProfession(recipe)
    if type(recipe) ~= "table" then return false end
    local changed = false

    if type(recipe.recipeId) == "number" and recipe.recipeId > 0 then
        local resolvedName, resolvedId = ResolveRecipeProfession(recipe.recipeId, nil, nil, recipe.outputItemId, nil)
        if resolvedName and not INVALID_CRAFTING_PROFESSIONS[resolvedName] then
            if recipe.profession ~= resolvedName then
                recipe.profession = resolvedName
                changed = true
            end
            local effectiveId = resolvedId or PROFESSION_TO_SKILL_LINE_ID[resolvedName]
            if effectiveId and recipe.professionId ~= effectiveId then
                recipe.professionId = effectiveId
                changed = true
            end
        end
    elseif type(recipe.profession) == "string" then
        local cleanName = CleanProfessionName(recipe.profession, recipe.professionId)
        if cleanName and cleanName ~= recipe.profession then
            recipe.profession = cleanName
            changed = true
        end
        if not recipe.professionId and PROFESSION_TO_SKILL_LINE_ID[recipe.profession] then
            recipe.professionId = PROFESSION_TO_SKILL_LINE_ID[recipe.profession]
            changed = true
        end
    end

    return changed
end

function PF.RecipeScanner.PruneUnlearnedCharRecipes()
    if type(Profitable_DB) ~= "table" or type(Profitable_DB.charRecipes) ~= "table" then
        return 0
    end

    local profNames, profNamesLower, skillLineIds, hasAuthData = GetCurrentCharacterProfessions()
    local canCheckPerRecipe = (_G.C_TradeSkillUI and type(_G.C_TradeSkillUI.IsRecipeProfessionLearned) == "function") == true
    if not hasAuthData and not canCheckPerRecipe then
        return 0
    end

    local charKey = PF.GetCharacterKey()
    local charTbl = Profitable_DB.charRecipes[charKey]
    local pruned = 0

    if type(charTbl) == "table" then
        local keysToPrune = {}
        for key, recipe in pairs(charTbl) do
            if type(recipe) == "table" then
                if (recipe.recipeId and not recipe.professionId) or INVALID_CRAFTING_PROFESSIONS[recipe.profession or ""] then
                    PF.RecipeScanner.NormalizeRecipeProfession(recipe)
                end
                if not IsRecipeLearnedByCurrentCharacter(recipe, profNames, profNamesLower, skillLineIds, hasAuthData) then
                    table.insert(keysToPrune, key)
                end
            end
        end
        for _, key in ipairs(keysToPrune) do
            charTbl[key] = nil
            pruned = pruned + 1
        end
    end

    local includeAlts = (Profitable_DB.settings and Profitable_DB.settings.includeAllCharRecipes == true)
    if not includeAlts and (pruned > 0 or hasAuthData) then
        local function IsCraftOppLearned(opp)
            if type(opp) ~= "table" or type(opp.recipe) ~= "table" then
                return true
            end
            return IsRecipeLearnedByCurrentCharacter(opp.recipe, profNames, profNamesLower, skillLineIds, hasAuthData)
        end

        local function FilterPlayList(list)
            if type(list) ~= "table" then return end
            local kept = {}
            for _, opp in ipairs(list) do
                if IsCraftOppLearned(opp) then
                    table.insert(kept, opp)
                end
            end
            if #kept ~= #list then
                return kept
            end
            return nil
        end

        local filteredTop = FilterPlayList(Profitable_DB.lastTopPlays)
        if filteredTop then
            Profitable_DB.lastTopPlays = filteredTop
        end
        local filteredHM = FilterPlayList(Profitable_DB.lastHonorableMentions)
        if filteredHM then
            Profitable_DB.lastHonorableMentions = filteredHM
        end
        if Profitable_DB.activePlay and not IsCraftOppLearned(Profitable_DB.activePlay) then
            Profitable_DB.activePlay = nil
        end
    end

    if pruned > 0 then
        PF.RecipeScanner.InvalidateCache()
    end
    return pruned
end

function PF.RecipeScanner.RepairSavedRecipeProfessions()
    if type(Profitable_DB) ~= "table" then
        return 0
    end
    PF.RecipeScanner.InvalidateCache()
    local repaired = 0

    if type(Profitable_DB.charRecipes) == "table" then
        for _, charTbl in pairs(Profitable_DB.charRecipes) do
            if type(charTbl) == "table" then
                for _, recipe in pairs(charTbl) do
                    if PF.RecipeScanner.NormalizeRecipeProfession(recipe) then
                        repaired = repaired + 1
                    end
                end
            end
        end
    end

    local pruned = PF.RecipeScanner.PruneUnlearnedCharRecipes()
    repaired = repaired + pruned

    local function RepairOpportunity(opp)
        if type(opp) ~= "table" then return end
        local oppChanged = false
        if type(opp.recipe) == "table" and PF.RecipeScanner.NormalizeRecipeProfession(opp.recipe) then
            repaired = repaired + 1
            oppChanged = true
        end
        if type(opp.intermediateSteps) == "table" then
            for _, step in ipairs(opp.intermediateSteps) do
                if type(step) == "table" then
                    if type(step.recipe) == "table" then
                        if PF.RecipeScanner.NormalizeRecipeProfession(step.recipe) then
                            repaired = repaired + 1
                            oppChanged = true
                        end
                        if step.recipe.profession and step.profession ~= step.recipe.profession then
                            step.profession = step.recipe.profession
                            step.professionId = step.recipe.professionId
                            oppChanged = true
                        end
                    elseif step.outputItemId then
                        local resolvedProf, resolvedId = ResolveRecipeProfession(step.recipeId, nil, nil, step.outputItemId, nil)
                        if resolvedProf and not INVALID_CRAFTING_PROFESSIONS[resolvedProf] and step.profession ~= resolvedProf then
                            step.profession = resolvedProf
                            step.professionId = resolvedId
                            repaired = repaired + 1
                            oppChanged = true
                        end
                    end
                end
            end
        end
        if oppChanged and PF.OpportunityEngine and PF.OpportunityEngine.BuildDetailedExplanation then
            opp.explanation = PF.OpportunityEngine.BuildDetailedExplanation(opp)
        end
    end

    RepairOpportunity(Profitable_DB.activePlay)
    if type(Profitable_DB.lastTopPlays) == "table" then
        for _, opp in ipairs(Profitable_DB.lastTopPlays) do
            RepairOpportunity(opp)
        end
    end
    if type(Profitable_DB.lastHonorableMentions) == "table" then
        for _, opp in ipairs(Profitable_DB.lastHonorableMentions) do
            RepairOpportunity(opp)
        end
    end

    return repaired
end

-- Intermediate material conversions (used when the character also knows the conversion recipe)
local INTERMEDIATE_CONVERSIONS = {
    -- Bolts of Cloth (Tailoring)
    [2996]  = { profession = "Tailoring",      name = "Bolt of Linen Cloth",   outputItemId = 2996,  avgMade = 1, reagents = { { itemId = 2589,  count = 2, name = "Linen Cloth" } } },
    [2997]  = { profession = "Tailoring",      name = "Bolt of Woolen Cloth",  outputItemId = 2997,  avgMade = 1, reagents = { { itemId = 2592,  count = 3, name = "Wool Cloth" } } },
    [4305]  = { profession = "Tailoring",      name = "Bolt of Silk Cloth",    outputItemId = 4305,  avgMade = 1, reagents = { { itemId = 4306,  count = 4, name = "Silk Cloth" } } },
    [4339]  = { profession = "Tailoring",      name = "Bolt of Mageweave",     outputItemId = 4339,  avgMade = 1, reagents = { { itemId = 4338,  count = 5, name = "Mageweave Cloth" } } },
    [14048] = { profession = "Tailoring",      name = "Bolt of Runecloth",     outputItemId = 14048, avgMade = 1, reagents = { { itemId = 14047, count = 5, name = "Runecloth" } } },

    -- Smelting Bars (Mining)
    [2840]  = { profession = "Mining",         name = "Smelt Copper",          outputItemId = 2840,  avgMade = 1, reagents = { { itemId = 2770,  count = 1, name = "Copper Ore" } } },
    [3576]  = { profession = "Mining",         name = "Smelt Tin",             outputItemId = 3576,  avgMade = 1, reagents = { { itemId = 2771,  count = 1, name = "Tin Ore" } } },
    [2841]  = { profession = "Mining",         name = "Smelt Bronze",          outputItemId = 2841,  avgMade = 2, reagents = { { itemId = 2840,  count = 1, name = "Copper Bar" }, { itemId = 3576, count = 1, name = "Tin Bar" } } },
    [2842]  = { profession = "Mining",         name = "Smelt Silver",          outputItemId = 2842,  avgMade = 1, reagents = { { itemId = 2775,  count = 1, name = "Silver Ore" } } },
    [3575]  = { profession = "Mining",         name = "Smelt Iron",            outputItemId = 3575,  avgMade = 1, reagents = { { itemId = 2772,  count = 1, name = "Iron Ore" } } },
    [3859]  = { profession = "Mining",         name = "Smelt Steel",           outputItemId = 3859,  avgMade = 1, reagents = { { itemId = 3575,  count = 1, name = "Iron Bar" }, { itemId = 3857, count = 1, name = "Coal" } } },
    [3577]  = { profession = "Mining",         name = "Smelt Gold",            outputItemId = 3577,  avgMade = 1, reagents = { { itemId = 2776,  count = 1, name = "Gold Ore" } } },
    [3860]  = { profession = "Mining",         name = "Smelt Mithril",         outputItemId = 3860,  avgMade = 1, reagents = { { itemId = 3858,  count = 1, name = "Mithril Ore" } } },
    [6037]  = { profession = "Mining",         name = "Smelt Truesilver",      outputItemId = 6037,  avgMade = 1, reagents = { { itemId = 7911,  count = 1, name = "Truesilver Ore" } } },
    [12359] = { profession = "Mining",         name = "Smelt Thorium",         outputItemId = 12359, avgMade = 1, reagents = { { itemId = 10620, count = 1, name = "Thorium Ore" } } },

    -- Grinding Stones (Blacksmithing)
    [3470]  = { profession = "Blacksmithing",  name = "Rough Grinding Stone",  outputItemId = 3470,  avgMade = 1, reagents = { { itemId = 2835,  count = 2, name = "Rough Stone" } } },
    [3478]  = { profession = "Blacksmithing",  name = "Coarse Grinding Stone", outputItemId = 3478,  avgMade = 1, reagents = { { itemId = 2836,  count = 2, name = "Coarse Stone" } } },
    [3486]  = { profession = "Blacksmithing",  name = "Heavy Grinding Stone",  outputItemId = 3486,  avgMade = 1, reagents = { { itemId = 2838,  count = 3, name = "Heavy Stone" } } },
    [7966]  = { profession = "Blacksmithing",  name = "Solid Grinding Stone",  outputItemId = 7966,  avgMade = 1, reagents = { { itemId = 7912,  count = 4, name = "Solid Stone" } } },
    [12644] = { profession = "Blacksmithing",  name = "Dense Grinding Stone",  outputItemId = 12644, avgMade = 1, reagents = { { itemId = 12365, count = 4, name = "Dense Stone" } } },
}

local function EnsureCharRecipeTable()
    Profitable_DB = Profitable_DB or {}
    Profitable_DB.charRecipes = Profitable_DB.charRecipes or {}
    local charKey = PF.GetCharacterKey()
    if type(Profitable_DB.charRecipes[charKey]) ~= "table" then
        Profitable_DB.charRecipes[charKey] = {}
    end
    return Profitable_DB.charRecipes[charKey], charKey
end

local function SaveRecipe(charRecipes, recipe)
    if not recipe or not recipe.outputItemId or not recipe.reagents or #recipe.reagents == 0 then
        return false
    end
    local key = tostring(recipe.recipeId or recipe.outputItemId) .. ":" .. tostring(recipe.name or "")
    recipe.key = key
    recipe.lastScanned = time()
    charRecipes[key] = recipe
    PF.RecipeScanner.InvalidateCache()
    if not recipe.isTrainerRecommendation then
        InvalidateStaleBaselinePlaysForScannedRecipe(recipe)
    end
    return true
end

function PF.RecipeScanner.ScanLegacyTradeSkill()
    if not _G.GetNumTradeSkills or not _G.GetTradeSkillInfo then
        return 0
    end

    -- Never save another player's linked or guild profession recipes as the character's own
    if _G.IsTradeSkillLinked then
        local okL, isLinked = pcall(_G.IsTradeSkillLinked)
        if okL and isLinked then
            return 0
        end
    end
    if _G.IsTradeSkillGuild then
        local okG, isGuild = pcall(_G.IsTradeSkillGuild)
        if okG and isGuild then
            return 0
        end
    end

    local okNum, numSkills = pcall(_G.GetNumTradeSkills)
    if not okNum or type(numSkills) ~= "number" or numSkills <= 0 then
        return 0
    end

    local professionName = "TradeSkill"
    if _G.GetTradeSkillLine then
        local okLine, lineName = pcall(_G.GetTradeSkillLine)
        if okLine and type(lineName) == "string" and lineName ~= "" and lineName ~= "UNKNOWN" then
            professionName = CleanProfessionName(lineName) or lineName
        end
    end
    local professionId = PROFESSION_TO_SKILL_LINE_ID[professionName]

    local profNames, profNamesLower, skillLineIds, hasAuthData = GetCurrentCharacterProfessions()
    if hasAuthData and not IsRecipeLearnedByCurrentCharacter(
        { profession = professionName, professionId = professionId },
        profNames, profNamesLower, skillLineIds, hasAuthData
    ) then
        return 0
    end

    local charRecipes = EnsureCharRecipeTable()
    local scanned = 0

    for i = 1, numSkills do
        local okInfo, skillName, skillType = pcall(_G.GetTradeSkillInfo, i)
        if okInfo and skillName and skillType ~= "header" and skillType ~= "subheader" then
            local itemLink = _G.GetTradeSkillItemLink and _G.GetTradeSkillItemLink(i)
            local outputItemId = itemLink and tonumber(itemLink:match("item:(%d+)"))
            if outputItemId and outputItemId > 0 then
                PF.VendorDatabase.GetItemMetadata(outputItemId, itemLink)

                local minMade, maxMade = 1, 1
                if _G.GetTradeSkillNumMade then
                    local okMade, mn, mx = pcall(_G.GetTradeSkillNumMade, i)
                    if okMade and mn and mn > 0 then
                        minMade = mn
                        maxMade = (mx and mx >= mn) and mx or mn
                    end
                end

                local numReagents = (_G.GetTradeSkillNumReagents and _G.GetTradeSkillNumReagents(i)) or 0
                local reagents = {}
                local allReagentsResolved = (numReagents > 0)

                for r = 1, numReagents do
                    local rName, _, rCount = _G.GetTradeSkillReagentInfo(i, r)
                    local rLink = _G.GetTradeSkillReagentItemLink and _G.GetTradeSkillReagentItemLink(i, r)
                    local rItemId = rLink and tonumber(rLink:match("item:(%d+)"))
                    if rItemId and rItemId > 0 and rCount and rCount > 0 then
                        PF.VendorDatabase.GetItemMetadata(rItemId, rLink)
                        table.insert(reagents, {
                            itemId = rItemId,
                            name = rName or (PF.VendorDatabase.GetItemMetadata(rItemId) and PF.VendorDatabase.GetItemMetadata(rItemId).name) or string.format("Item #%d", rItemId),
                            link = rLink,
                            count = rCount,
                        })
                    else
                        allReagentsResolved = false
                    end
                end

                if allReagentsResolved then
                    local saved = SaveRecipe(charRecipes, {
                        name = skillName,
                        profession = professionName,
                        professionId = professionId,
                        tradeSkillIndex = i,
                        outputItemId = outputItemId,
                        outputLink = itemLink,
                        minMade = minMade,
                        maxMade = maxMade,
                        avgMade = (minMade + maxMade) / 2,
                        reagents = reagents,
                    })
                    if saved then
                        scanned = scanned + 1
                    end
                end
            end
        end
    end

    return scanned
end

function PF.RecipeScanner.ScanLegacyCraft()
    if not _G.GetNumCrafts or not _G.GetCraftInfo then
        return 0
    end

    if _G.IsTradeSkillLinked then
        local okL, isLinked = pcall(_G.IsTradeSkillLinked)
        if okL and isLinked then
            return 0
        end
    end
    if _G.IsTradeSkillGuild then
        local okG, isGuild = pcall(_G.IsTradeSkillGuild)
        if okG and isGuild then
            return 0
        end
    end

    local okNum, numCrafts = pcall(_G.GetNumCrafts)
    if not okNum or type(numCrafts) ~= "number" or numCrafts <= 0 then
        return 0
    end

    local professionName = "Enchanting"
    if _G.GetCraftDisplaySkillLine then
        local okLine, lineName = pcall(_G.GetCraftDisplaySkillLine)
        if okLine and type(lineName) == "string" and lineName ~= "" then
            professionName = CleanProfessionName(lineName) or lineName
        end
    end
    local professionId = PROFESSION_TO_SKILL_LINE_ID[professionName]

    local profNames, profNamesLower, skillLineIds, hasAuthData = GetCurrentCharacterProfessions()
    if hasAuthData and not IsRecipeLearnedByCurrentCharacter(
        { profession = professionName, professionId = professionId },
        profNames, profNamesLower, skillLineIds, hasAuthData
    ) then
        return 0
    end

    local charRecipes = EnsureCharRecipeTable()
    local scanned = 0

    for i = 1, numCrafts do
        local okInfo, craftName, _, craftType = pcall(_G.GetCraftInfo, i)
        if okInfo and craftName and craftType ~= "header" and craftType ~= "subheader" then
            local itemLink = _G.GetCraftItemLink and _G.GetCraftItemLink(i)
            local outputItemId = itemLink and tonumber(itemLink:match("item:(%d+)"))
            if outputItemId and outputItemId > 0 then
                PF.VendorDatabase.GetItemMetadata(outputItemId, itemLink)
                local numReagents = (_G.GetCraftNumReagents and _G.GetCraftNumReagents(i)) or 0
                local reagents = {}
                local allReagentsResolved = (numReagents > 0)

                for r = 1, numReagents do
                    local rName, _, rCount = _G.GetCraftReagentInfo(i, r)
                    local rLink = _G.GetCraftReagentItemLink and _G.GetCraftReagentItemLink(i, r)
                    local rItemId = rLink and tonumber(rLink:match("item:(%d+)"))
                    if rItemId and rItemId > 0 and rCount and rCount > 0 then
                        PF.VendorDatabase.GetItemMetadata(rItemId, rLink)
                        table.insert(reagents, {
                            itemId = rItemId,
                            name = rName or string.format("Item #%d", rItemId),
                            link = rLink,
                            count = rCount,
                        })
                    else
                        allReagentsResolved = false
                    end
                end

                if allReagentsResolved then
                    local saved = SaveRecipe(charRecipes, {
                        name = craftName,
                        profession = professionName,
                        professionId = professionId,
                        craftIndex = i,
                        outputItemId = outputItemId,
                        outputLink = itemLink,
                        minMade = 1,
                        maxMade = 1,
                        avgMade = 1,
                        reagents = reagents,
                    })
                    if saved then
                        scanned = scanned + 1
                    end
                end
            end
        end
    end

    return scanned
end

function PF.RecipeScanner.ScanModernTradeSkillUI()
    if not _G.C_TradeSkillUI or not _G.C_TradeSkillUI.GetAllRecipeIDs or not _G.C_TradeSkillUI.GetRecipeInfo then
        return 0
    end

    -- Never save another player's linked, guild, or NPC crafting recipes as the character's own
    if _G.C_TradeSkillUI.IsTradeSkillLinked then
        local okL, isLinked = pcall(_G.C_TradeSkillUI.IsTradeSkillLinked)
        if okL and isLinked then
            return 0
        end
    end
    if _G.C_TradeSkillUI.IsTradeSkillGuild then
        local okG, isGuild = pcall(_G.C_TradeSkillUI.IsTradeSkillGuild)
        if okG and isGuild then
            return 0
        end
    end
    if _G.C_TradeSkillUI.IsNPCCrafting then
        local okNPC, isNPC = pcall(_G.C_TradeSkillUI.IsNPCCrafting)
        if okNPC and isNPC then
            return 0
        end
    end
    if _G.C_TradeSkillUI.IsTradeSkillReady then
        local okReady, isReady = pcall(_G.C_TradeSkillUI.IsTradeSkillReady)
        if okReady and not isReady then
            return 0
        end
    end

    local okIds, recipeIDs = pcall(_G.C_TradeSkillUI.GetAllRecipeIDs)
    if not okIds or type(recipeIDs) ~= "table" or #recipeIDs == 0 then
        return 0
    end

    -- Prefer BaseProfessionInfo over ChildProfessionInfo as window-level fallback;
    -- per-recipe resolution via GetProfessionInfoByRecipeID always takes precedence below.
    local windowProfName, windowProfId = nil, nil
    if _G.C_TradeSkillUI.GetBaseProfessionInfo then
        local okProf, profInfo = pcall(_G.C_TradeSkillUI.GetBaseProfessionInfo)
        if okProf and type(profInfo) == "table" then
            windowProfName, windowProfId = ExtractProfessionFromInfo(profInfo)
        end
    end
    if not windowProfName and _G.C_TradeSkillUI.GetChildProfessionInfo then
        local okChild, childInfo = pcall(_G.C_TradeSkillUI.GetChildProfessionInfo)
        if okChild and type(childInfo) == "table" then
            windowProfName, windowProfId = ExtractProfessionFromInfo(childInfo)
        end
    end

    local profNames, profNamesLower, skillLineIds, hasAuthData = GetCurrentCharacterProfessions()
    local charRecipes = EnsureCharRecipeTable()
    local scanned = 0

    for _, recipeID in ipairs(recipeIDs) do
        local okInfo, info = pcall(_G.C_TradeSkillUI.GetRecipeInfo, recipeID)
        if okInfo and type(info) == "table" and info.learned then
            local profAllowed = true
            if _G.C_TradeSkillUI.IsRecipeProfessionLearned then
                local okPL, isPL = pcall(_G.C_TradeSkillUI.IsRecipeProfessionLearned, recipeID)
                if okPL and isPL == false then
                    profAllowed = false
                end
            end

            if profAllowed then
                local schematic = _G.C_TradeSkillUI.GetRecipeSchematic and _G.C_TradeSkillUI.GetRecipeSchematic(recipeID, false)
                local outputItemId = (schematic and schematic.outputItemID) or info.itemID
                if outputItemId and outputItemId > 0 and schematic and type(schematic.reagentSlotSchematics) == "table" then
                    local minMade = schematic.quantityMin or 1
                    local maxMade = schematic.quantityMax or minMade
                    local reagents = {}
                    local reagentById = {}
                    local requiredSlots = 0
                    local allReagentsResolved = true
                    local basicReagentType = _G.Enum and _G.Enum.CraftingReagentType and _G.Enum.CraftingReagentType.Basic

                    for _, slot in ipairs(schematic.reagentSlotSchematics) do
                        local isOptional = (slot.required == false)
                        if not isOptional and basicReagentType ~= nil and slot.reagentType ~= nil
                            and slot.reagentType ~= basicReagentType and slot.required ~= true then
                            isOptional = true
                        end
                        if not isOptional then
                            requiredSlots = requiredSlots + 1
                            local rItemId = nil
                            if type(slot.reagents) == "table" then
                                for _, reagentOpt in ipairs(slot.reagents) do
                                    if type(reagentOpt) == "table" and type(reagentOpt.itemID) == "number" and reagentOpt.itemID > 0 then
                                        rItemId = reagentOpt.itemID
                                        break
                                    end
                                end
                            end
                            local rCount = (type(slot.quantityRequired) == "number") and slot.quantityRequired or 1
                            if rItemId and rItemId > 0 and rCount > 0 then
                                local existingEntry = reagentById[rItemId]
                                if existingEntry then
                                    existingEntry.count = existingEntry.count + rCount
                                else
                                    local meta = PF.VendorDatabase.GetItemMetadata(rItemId)
                                    local entry = {
                                        itemId = rItemId,
                                        name = (meta and meta.name) or string.format("Item #%d", rItemId),
                                        count = rCount,
                                    }
                                    reagentById[rItemId] = entry
                                    table.insert(reagents, entry)
                                end
                            else
                                allReagentsResolved = false
                            end
                        end
                    end
                    if allReagentsResolved and requiredSlots > 0 and #reagents > 0 then
                        local recipeName = info.name or string.format("Recipe #%d", recipeID)
                        local key = tostring(recipeID) .. ":" .. tostring(recipeName)
                        local existingRecipe = charRecipes[key]
                        local recipeProf, recipeProfId = ResolveRecipeProfession(recipeID, windowProfName, windowProfId, outputItemId, existingRecipe)
                        local candidate = {
                            recipeId = recipeID,
                            name = recipeName,
                            profession = recipeProf,
                            professionId = recipeProfId,
                            outputItemId = outputItemId,
                            minMade = minMade,
                            maxMade = maxMade,
                            avgMade = (minMade + maxMade) / 2,
                            reagents = reagents,
                        }
                        if IsRecipeLearnedByCurrentCharacter(candidate, profNames, profNamesLower, skillLineIds, hasAuthData) then
                            local saved = SaveRecipe(charRecipes, candidate)
                            if saved then
                                scanned = scanned + 1
                            end
                        end
                    end
                end
            end
        end
    end

    return scanned
end

function PF.RecipeScanner.ScanCurrentProfessionWindow()
    local count = PF.RecipeScanner.ScanLegacyTradeSkill()
    if count == 0 then
        count = PF.RecipeScanner.ScanModernTradeSkillUI()
    end
    if count == 0 then
        count = PF.RecipeScanner.ScanLegacyCraft()
    end
    return count
end

local function BuildKnownRecipesAndIndex()
    local list = {}
    local byOutput = {}
    local hasProfession = {}
    local knownProfessions = {}
    local profNames, profNamesLower, skillLineIds, hasAuthData, skillRanks = GetCurrentCharacterProfessions()
    local currentCharKey = PF.GetCharacterKey()

    local function AddFromTable(tbl, enforceCurrentChar)
        if type(tbl) ~= "table" then return end
        local keysToPrune = nil
        for key, recipe in pairs(tbl) do
            if type(recipe) == "table" and recipe.outputItemId then
                if (recipe.recipeId and not recipe.professionId) or INVALID_CRAFTING_PROFESSIONS[recipe.profession or ""] then
                    PF.RecipeScanner.NormalizeRecipeProfession(recipe)
                end
                if enforceCurrentChar and not IsRecipeLearnedByCurrentCharacter(recipe, profNames, profNamesLower, skillLineIds, hasAuthData) then
                    keysToPrune = keysToPrune or {}
                    table.insert(keysToPrune, key)
                elseif not byOutput[recipe.outputItemId] then
                    byOutput[recipe.outputItemId] = recipe
                    if recipe.profession and not INVALID_CRAFTING_PROFESSIONS[recipe.profession] then
                        hasProfession[recipe.profession] = true
                        knownProfessions[recipe.profession] = math.max(knownProfessions[recipe.profession] or 0, recipe.skillReq or 1)
                    end
                    table.insert(list, recipe)
                end
            end
        end
        if keysToPrune then
            for _, k in ipairs(keysToPrune) do
                tbl[k] = nil
            end
        end
    end

    if Profitable_DB and Profitable_DB.charRecipes then
        if Profitable_DB.settings and Profitable_DB.settings.includeAllCharRecipes then
            for cKey, charTbl in pairs(Profitable_DB.charRecipes) do
                AddFromTable(charTbl, cKey == currentCharKey)
            end
        else
            AddFromTable(Profitable_DB.charRecipes[currentCharKey], true)
        end
    end

    -- Incorporate skill-matched baseline recipes and Trainer/Unlearned recipe recommendations
    local settings = (Profitable_DB and Profitable_DB.settings) or {}
    if settings.includeSkillMatchedBaselineRecipes ~= false and PF.RecipeDatabase and PF.RecipeDatabase.GetAllBaselineRecipes then
        for prof, info in pairs(skillRanks) do
            knownProfessions[prof] = math.max(knownProfessions[prof] or 0, info.rank or 0)
        end

        local lookahead = (settings.includeTrainerRecommendations ~= false) and (settings.trainerSkillLookahead or 25) or 0
        for _, base in ipairs(PF.RecipeDatabase.GetAllBaselineRecipes()) do
            if not byOutput[base.outputItemId]
                and base.profession
                and knownProfessions[base.profession]
                and IsBaselineOutputNameValid(base) then
                local charRank = knownProfessions[base.profession]
                local req = base.skillReq or 1
                if req <= (charRank + lookahead) then
                    local isUnlearned = (req > charRank) or (base.source and base.source ~= "Trainer")
                    local baseRec = {
                        name = base.name,
                        profession = base.profession,
                        professionId = PROFESSION_TO_SKILL_LINE_ID[base.profession],
                        skillReq = req,
                        source = base.source or "Trainer",
                        isTrainerRecommendation = true,
                        needsLearning = isUnlearned,
                        sourceHint = string.format("%s (Skill %d)", base.source or "Trainer", req),
                        outputItemId = base.outputItemId,
                        minMade = 1,
                        maxMade = base.avgMade or 1,
                        avgMade = base.avgMade or 1,
                        reagents = base.reagents,
                    }
                    byOutput[base.outputItemId] = baseRec
                    hasProfession[base.profession] = true
                    table.insert(list, baseRec)
                end
            end
        end
    end

    recipeCountCache = {
        count = #list,
        dbRef = Profitable_DB,
        charRecipesRef = Profitable_DB and Profitable_DB.charRecipes,
        includeAlts = (settings.includeAllCharRecipes == true),
        includeBase = (settings.includeSkillMatchedBaselineRecipes ~= false),
        includeTrainer = (settings.includeTrainerRecommendations ~= false),
        lookahead = settings.trainerSkillLookahead or 25,
    }

    return list, {
        list = list,
        byOutput = byOutput,
        hasProfession = hasProfession,
    }
end

function PF.RecipeScanner.BeginBatchLookup()
    if batchDepth <= 0 or not activeBatchIndex then
        local _, idx = BuildKnownRecipesAndIndex()
        activeBatchIndex = idx
        batchDepth = 1
    else
        batchDepth = batchDepth + 1
    end
    return activeBatchIndex
end

function PF.RecipeScanner.EndBatchLookup()
    if batchDepth <= 1 then
        batchDepth = 0
        activeBatchIndex = nil
    else
        batchDepth = batchDepth - 1
    end
end

function PF.RecipeScanner.GetKnownRecipes()
    if batchDepth > 0 and activeBatchIndex then
        return activeBatchIndex.list
    end
    local list = BuildKnownRecipesAndIndex()
    return list
end

function PF.RecipeScanner.GetKnownRecipeCount()
    local settings = (Profitable_DB and Profitable_DB.settings) or {}
    if recipeCountCache
        and recipeCountCache.dbRef == Profitable_DB
        and recipeCountCache.charRecipesRef == (Profitable_DB and Profitable_DB.charRecipes)
        and recipeCountCache.includeAlts == (settings.includeAllCharRecipes == true)
        and recipeCountCache.includeBase == (settings.includeSkillMatchedBaselineRecipes ~= false)
        and recipeCountCache.includeTrainer == (settings.includeTrainerRecommendations ~= false)
        and recipeCountCache.lookahead == (settings.trainerSkillLookahead or 25) then
        return recipeCountCache.count
    end
    local list = PF.RecipeScanner.GetKnownRecipes()
    return #list
end

function PF.RecipeScanner.GetIntermediateRecipeForItem(itemId)
    if not itemId then return nil end
    local idx = activeBatchIndex
    if not idx then
        local _, built = BuildKnownRecipesAndIndex()
        idx = built
    end
    -- Prefer the character's own scanned or baseline recipe in O(1)
    local direct = idx.byOutput[itemId]
    if direct then
        return direct
    end
    -- Check if the character has any recipe in that profession before using static intermediate conversion
    local staticConv = INTERMEDIATE_CONVERSIONS[itemId]
    if staticConv and idx.hasProfession[staticConv.profession] then
        return staticConv
    end
    return nil
end

function PF.RecipeScanner.RegisterRecipe(recipe)
    local charRecipes = EnsureCharRecipeTable()
    return SaveRecipe(charRecipes, recipe)
end

local function FindModernRecipeIdInOpenWindow(recipe)
    if not recipe or not _G.C_TradeSkillUI then return nil end
    if type(recipe.recipeId) == "number" and recipe.recipeId > 0 then
        return recipe.recipeId
    end
    if not _G.C_TradeSkillUI.GetAllRecipeIDs or not _G.C_TradeSkillUI.GetRecipeInfo then
        return nil
    end
    local okIds, recipeIDs = pcall(_G.C_TradeSkillUI.GetAllRecipeIDs)
    if not okIds or type(recipeIDs) ~= "table" then
        return nil
    end
    for _, rId in ipairs(recipeIDs) do
        local okInfo, info = pcall(_G.C_TradeSkillUI.GetRecipeInfo, rId)
        if okInfo and type(info) == "table" then
            local schematic = _G.C_TradeSkillUI.GetRecipeSchematic and _G.C_TradeSkillUI.GetRecipeSchematic(rId, false)
            local outId = (schematic and schematic.outputItemID) or info.itemID
            if (recipe.outputItemId and outId == recipe.outputItemId) or (recipe.name and info.name == recipe.name) then
                return rId
            end
        end
    end
    return nil
end

local function SelectModernRecipe(recipe)
    if not recipe or not _G.C_TradeSkillUI then return false end
    if _G.InCombatLockdown and _G.InCombatLockdown() then return false end
    local targetId = FindModernRecipeIdInOpenWindow(recipe)
    if not targetId then return false end

    -- Always use Blizzard's C-side C_TradeSkillUI.OpenRecipe API rather than invoking
    -- ProfessionsFrame.CraftingPage:SelectRecipe directly from addon Lua, which taints
    -- ProfessionsFrame and Blizzard's UIPanel state.
    if _G.C_TradeSkillUI.OpenRecipe then
        local okOpen, openRes = pcall(_G.C_TradeSkillUI.OpenRecipe, targetId)
        if okOpen and openRes ~= false then
            return true
        end
    end

    return false
end

local function SelectLegacyRecipe(recipe)
    if not recipe then return false end

    -- Select the recipe in the legacy TradeSkillFrame
    if _G.GetNumTradeSkills and _G.GetTradeSkillInfo and _G.SelectTradeSkill then
        local num = _G.GetNumTradeSkills() or 0
        for i = 1, num do
            local name, skillType = _G.GetTradeSkillInfo(i)
            local link = _G.GetTradeSkillItemLink and _G.GetTradeSkillItemLink(i)
            local outId = link and tonumber(link:match("item:(%d+)"))
            if skillType ~= "header" and skillType ~= "subheader" and (outId == recipe.outputItemId or name == recipe.name) then
                pcall(_G.SelectTradeSkill, i)
                if _G.TradeSkillFrame_SetSelection then
                    pcall(_G.TradeSkillFrame_SetSelection, i)
                end
                return true
            end
        end
    end

    -- Select the recipe in the legacy CraftFrame (Enchanting)
    if _G.GetNumCrafts and _G.GetCraftInfo and _G.SelectCraft then
        local num = _G.GetNumCrafts() or 0
        for i = 1, num do
            local name, _, craftType = _G.GetCraftInfo(i)
            local link = _G.GetCraftItemLink and _G.GetCraftItemLink(i)
            local outId = link and tonumber(link:match("item:(%d+)"))
            if craftType ~= "header" and craftType ~= "subheader" and (outId == recipe.outputItemId or name == recipe.name) then
                pcall(_G.SelectCraft, i)
                if _G.CraftFrame_SetSelection then
                    pcall(_G.CraftFrame_SetSelection, i)
                end
                return true
            end
        end
    end

    return false
end

function PF.RecipeScanner.OpenRecipe(recipe)
    if not recipe then return false end
    if _G.InCombatLockdown and _G.InCombatLockdown() then
        print("|cffff9900[Profitable]|r Cannot open profession windows during combat.")
        return false
    end

    PF.RecipeScanner.NormalizeRecipeProfession(recipe)

    -- 1. Modern C_TradeSkillUI path (WoW: Forever / Dragonflight+ ProfessionsFrame)
    if _G.C_TradeSkillUI and (_G.C_TradeSkillUI.OpenTradeSkill or _G.C_TradeSkillUI.OpenRecipe) then
        local skillLineID = ResolveSkillLineId(recipe)

        if type(recipe.recipeId) == "number" and recipe.recipeId > 0 and _G.C_TradeSkillUI.IsRecipeProfessionLearned then
            local okLearned, isLearned = pcall(_G.C_TradeSkillUI.IsRecipeProfessionLearned, recipe.recipeId)
            if okLearned and isLearned == false then
                print(string.format(
                    "|cffffcc00[Profitable]|r Could not open %s — this character has not learned %s.",
                    recipe.profession or "profession",
                    recipe.profession or "this profession"
                ))
                return false
            end
        end

        local frameShown = (_G.ProfessionsFrame and _G.ProfessionsFrame.IsShown and _G.ProfessionsFrame:IsShown())
            or (_G.TradeSkillFrame and _G.TradeSkillFrame.IsShown and _G.TradeSkillFrame:IsShown())
        local currentProfId = nil
        if _G.C_TradeSkillUI.GetBaseProfessionInfo then
            local okB, baseInfo = pcall(_G.C_TradeSkillUI.GetBaseProfessionInfo)
            if okB and type(baseInfo) == "table" then
                currentProfId = (type(baseInfo.parentProfessionID) == "number" and baseInfo.parentProfessionID > 0) and baseInfo.parentProfessionID
                    or ((type(baseInfo.professionID) == "number" and baseInfo.professionID > 0) and baseInfo.professionID or nil)
            end
        end

        local opened = false
        local needOpenWindow = (not frameShown) or (skillLineID and currentProfId and currentProfId ~= skillLineID)

        if needOpenWindow and skillLineID and _G.C_TradeSkillUI.OpenTradeSkill then
            pendingOpenRecipe = {
                recipeId = recipe.recipeId,
                outputItemId = recipe.outputItemId,
                name = recipe.name,
                skillLineID = skillLineID,
                expiresAt = ((_G.GetTime and _G.GetTime()) or 0) + 3.0,
            }
            local okOpen, openRes = pcall(_G.C_TradeSkillUI.OpenTradeSkill, skillLineID)
            if okOpen and openRes == false then
                pendingOpenRecipe = nil
                print(string.format(
                    "|cffffcc00[Profitable]|r Could not open %s — make sure this character has learned %s.",
                    recipe.profession or "profession",
                    recipe.profession or "this profession"
                ))
                return false
            elseif okOpen then
                opened = true
            end
        end

        if type(recipe.recipeId) == "number" and recipe.recipeId > 0 and _G.C_TradeSkillUI.OpenRecipe then
            local okRec, recRes = pcall(_G.C_TradeSkillUI.OpenRecipe, recipe.recipeId)
            if okRec and recRes ~= false then
                opened = true
            end
        end

        if frameShown and (not skillLineID or not currentProfId or currentProfId == skillLineID) then
            if SelectModernRecipe(recipe) then
                pendingOpenRecipe = nil
                opened = true
            end
        elseif pendingOpenRecipe and _G.C_Timer and _G.C_Timer.After then
            local pendingRef = pendingOpenRecipe
            _G.C_Timer.After(0.15, function()
                if pendingOpenRecipe == pendingRef then
                    if SelectModernRecipe(pendingRef) then
                        pendingOpenRecipe = nil
                    end
                end
            end)
        end

        if opened then
            return true
        end

        print(string.format(
            "|cffffcc00[Profitable]|r Could not open %s — make sure this character has learned %s.",
            recipe.profession or "profession",
            recipe.profession or "this profession"
        ))
        return false
    end

    -- 2. Legacy TradeSkillFrame / CraftFrame path (Classic Era without C_TradeSkillUI)
    local legacyProf = recipe.profession
    if legacyProf == "Mining" then
        legacyProf = "Smelting"
    end
    local currentLegacyLine = nil
    if _G.GetTradeSkillLine then
        local okLine, lineName = pcall(_G.GetTradeSkillLine)
        if okLine and type(lineName) == "string" and lineName ~= "" and lineName ~= "UNKNOWN" then
            currentLegacyLine = lineName
        end
    end
    local legacyFrameShown = _G.TradeSkillFrame and _G.TradeSkillFrame.IsShown and _G.TradeSkillFrame:IsShown()
    local castSent = false
    if legacyProf and _G.CastSpellByName and (not legacyFrameShown or (currentLegacyLine and currentLegacyLine ~= legacyProf and currentLegacyLine ~= recipe.profession)) then
        pendingOpenRecipe = {
            recipeId = recipe.recipeId,
            outputItemId = recipe.outputItemId,
            name = recipe.name,
            expiresAt = ((_G.GetTime and _G.GetTime()) or 0) + 3.0,
        }
        local okCast = pcall(_G.CastSpellByName, legacyProf)
        castSent = okCast
    end

    if SelectLegacyRecipe(recipe) then
        pendingOpenRecipe = nil
        return true
    end

    return castSent
end

function PF.RecipeScanner.CraftRecipe(recipe, quantity)
    if not recipe then return false, "NO_RECIPE" end
    if _G.InCombatLockdown and _G.InCombatLockdown() then
        print("|cffff9900[Profitable]|r Cannot craft recipes during combat.")
        return false, "COMBAT"
    end

    quantity = math.max(1, math.floor(tonumber(quantity) or 1))
    PF.RecipeScanner.NormalizeRecipeProfession(recipe)

    -- 1. Modern C_TradeSkillUI path (WoW: Forever / Dragonflight+ ProfessionsFrame)
    if _G.C_TradeSkillUI and _G.C_TradeSkillUI.CraftRecipe then
        local skillLineID = ResolveSkillLineId(recipe)
        local isReady = (not _G.C_TradeSkillUI.IsTradeSkillReady) or (_G.C_TradeSkillUI.IsTradeSkillReady() == true)
        local frameShown = (_G.ProfessionsFrame and _G.ProfessionsFrame.IsShown and _G.ProfessionsFrame:IsShown())
            or (_G.TradeSkillFrame and _G.TradeSkillFrame.IsShown and _G.TradeSkillFrame:IsShown())
        local currentProfId = nil
        if _G.C_TradeSkillUI.GetBaseProfessionInfo then
            local okB, baseInfo = pcall(_G.C_TradeSkillUI.GetBaseProfessionInfo)
            if okB and type(baseInfo) == "table" then
                currentProfId = (type(baseInfo.parentProfessionID) == "number" and baseInfo.parentProfessionID > 0) and baseInfo.parentProfessionID
                    or ((type(baseInfo.professionID) == "number" and baseInfo.professionID > 0) and baseInfo.professionID or nil)
            end
        end

        local profMatches = isReady and (not skillLineID or not currentProfId or currentProfId == skillLineID)
        local targetId = FindModernRecipeIdInOpenWindow(recipe)
        local canCraftDirectly = profMatches and targetId and (frameShown or not _G.ProfessionsFrame)

        if not canCraftDirectly then
            local opened = PF.RecipeScanner.OpenRecipe(recipe)
            if opened then
                print(string.format(
                    "|cff00ff88[Profitable]|r Opened %s to [%s] — click 'Craft %dx' again to start crafting!",
                    recipe.profession or "profession",
                    recipe.name or "Recipe",
                    quantity
                ))
            end
            return false, "OPENING_PROFESSION"
        end

        local ok = pcall(_G.C_TradeSkillUI.CraftRecipe, targetId, quantity)
        if ok then
            print(string.format(
                "|cff00ff88[Profitable]|r Crafting %dx [%s] (%s)...",
                quantity,
                recipe.name or ("Recipe #" .. tostring(targetId)),
                recipe.profession or "Crafting"
            ))
            return true, "CRAFTING"
        end
    end

    -- 2. Legacy TradeSkillFrame path (Classic Era without C_TradeSkillUI)
    if _G.GetNumTradeSkills and _G.GetTradeSkillInfo and _G.DoTradeSkill then
        local num = _G.GetNumTradeSkills() or 0
        for i = 1, num do
            local name, skillType = _G.GetTradeSkillInfo(i)
            local link = _G.GetTradeSkillItemLink and _G.GetTradeSkillItemLink(i)
            local outId = link and tonumber(link:match("item:(%d+)"))
            if skillType ~= "header" and skillType ~= "subheader" and (outId == recipe.outputItemId or name == recipe.name) then
                pcall(_G.DoTradeSkill, i, quantity)
                print(string.format(
                    "|cff00ff88[Profitable]|r Crafting %dx [%s]...",
                    quantity,
                    recipe.name or name or "Recipe"
                ))
                return true, "CRAFTING"
            end
        end
    end

    local opened = PF.RecipeScanner.OpenRecipe(recipe)
    if opened then
        print(string.format(
            "|cff00ff88[Profitable]|r Opened %s to [%s] — click 'Craft %dx' again to start crafting!",
            recipe.profession or "profession",
            recipe.name or "Recipe",
            quantity
        ))
    end
    return false, "OPENING_PROFESSION"
end

local function IsCraftingActionType(actionType)
    return actionType == "CRAFT_AH" or actionType == "CRAFT_VENDOR" or actionType == "CRAFT_DE"
end

local function FindRecommendedCraftingPlay(itemId, spellId)
    if not Profitable_DB then
        return nil
    end
    local function CheckList(list)
        if type(list) ~= "table" then return nil end
        for _, opp in ipairs(list) do
            if type(opp) == "table" and IsCraftingActionType(opp.actionType) then
                if itemId and opp.itemId == itemId then
                    return opp
                end
                if spellId and opp.recipe and opp.recipe.recipeId == spellId then
                    return opp
                end
            end
        end
        return nil
    end

    local matched = CheckList(Profitable_DB.lastTopPlays) or CheckList(Profitable_DB.lastHonorableMentions)
    if not matched and type(Profitable_DB.activePlay) == "table" and IsCraftingActionType(Profitable_DB.activePlay.actionType) then
        local ap = Profitable_DB.activePlay
        if (itemId and ap.itemId == itemId) or (spellId and ap.recipe and ap.recipe.recipeId == spellId) then
            matched = ap
        end
    end
    return matched
end

function PF.RecipeScanner.HandleCraftCompleted(itemId, itemLink, spellId)
    if not Profitable_DB or not Profitable_DB.settings or Profitable_DB.settings.autoSnoozeOnCraft == false then
        return false
    end
    local opp = FindRecommendedCraftingPlay(itemId, spellId)
    if not opp then
        return false
    end
    if PF.IsPlaySnoozed and PF.IsPlaySnoozed(opp) then
        return false
    end
    local dur = tonumber(Profitable_DB.settings.craftAutoSnoozeSeconds) or 43200
    if PF.SnoozePlay then
        PF.SnoozePlay(opp, dur, "crafted")
    end
    local durText = (dur == 43200 and "12h")
        or (dur == 86400 and "24h")
        or (PF.FormatAgeShort and PF.FormatAgeShort(dur))
        or "12h"
    print(string.format(
        "|cff00ff88[Profitable]|r Crafted %s — auto-snoozed for %s so your Top 5 rotates to fresh plays. (Undo in Options or /pf unhide)",
        opp.itemLink or itemLink or opp.itemName or ("Item #" .. tostring(opp.itemId)),
        durText
    ))
    if PF.SideWindow then
        if PF.SideWindow.ApplySnoozeChange then
            PF.SideWindow.ApplySnoozeChange()
        elseif PF.SideWindow.ApplyFilterChange then
            PF.SideWindow.ApplyFilterChange()
        end
    end
    return true
end

PF.OnCraftedItemCompleted = PF.RecipeScanner.HandleCraftCompleted

local function ExtractCreatedLootItem(msg)
    if type(msg) ~= "string" or msg == "" then
        return nil, nil
    end
    local matched = false
    if type(_G.LOOT_ITEM_CREATED_SELF) == "string" and _G.LOOT_ITEM_CREATED_SELF ~= "" then
        local prefix = _G.LOOT_ITEM_CREATED_SELF:match("^(.-)%%s")
        if prefix and prefix ~= "" and msg:sub(1, #prefix) == prefix then
            matched = true
        end
    end
    if not matched and type(_G.LOOT_ITEM_CREATED_SELF_MULTIPLE) == "string" and _G.LOOT_ITEM_CREATED_SELF_MULTIPLE ~= "" then
        local prefix = _G.LOOT_ITEM_CREATED_SELF_MULTIPLE:match("^(.-)%%s")
        if prefix and prefix ~= "" and msg:sub(1, #prefix) == prefix then
            matched = true
        end
    end
    if not matched and msg:find("^You create:") then
        matched = true
    end
    if not matched then
        return nil, nil
    end
    local itemId = tonumber(msg:match("item:(%d+)"))
    local itemLink = msg:match("(|c%x+|Hitem:.-|h%[.-%]|h|r)")
    return itemId, itemLink
end

function PF.RecipeScanner.Init()
    if PF.RecipeScanner._initialized then return end
    PF.RecipeScanner._initialized = true

    PF.RecipeScanner.RepairSavedRecipeProfessions()

    local frame = CreateFrame("Frame")
    if frame and frame.RegisterEvent then
        pcall(frame.RegisterEvent, frame, "TRADE_SKILL_SHOW")
        pcall(frame.RegisterEvent, frame, "TRADE_SKILL_UPDATE")
        pcall(frame.RegisterEvent, frame, "TRADE_SKILL_DATA_SOURCE_CHANGED")
        pcall(frame.RegisterEvent, frame, "TRADE_SKILL_LIST_UPDATE")
        pcall(frame.RegisterEvent, frame, "TRADE_SKILL_ITEM_CRAFTED_RESULT")
        pcall(frame.RegisterEvent, frame, "NEW_RECIPE_LEARNED")
        pcall(frame.RegisterEvent, frame, "CRAFT_SHOW")
        pcall(frame.RegisterEvent, frame, "CRAFT_UPDATE")
        pcall(frame.RegisterEvent, frame, "PLAYER_ENTERING_WORLD")
        pcall(frame.RegisterEvent, frame, "SKILL_LINES_CHANGED")
        pcall(frame.RegisterEvent, frame, "CHAT_MSG_LOOT")
        pcall(frame.RegisterEvent, frame, "UNIT_SPELLCAST_SUCCEEDED")
        frame:SetScript("OnEvent", function(_, event, arg1, arg2, arg3)
            if event == "TRADE_SKILL_ITEM_CRAFTED_RESULT" then
                if type(arg1) == "table" and not (PF.IsSecret and PF.IsSecret(arg1)) then
                    local link = arg1.hyperlink
                    local itemId = tonumber(arg1.itemID) or (type(link) == "string" and tonumber(link:match("item:(%d+)")))
                    if itemId and itemId > 0 then
                        PF.RecipeScanner.HandleCraftCompleted(itemId, link, nil)
                    end
                end
                return
            end
            if event == "CHAT_MSG_LOOT" then
                if not (PF.IsSecret and PF.IsSecret(arg1)) then
                    local itemId, itemLink = ExtractCreatedLootItem(arg1)
                    if itemId and itemId > 0 then
                        PF.RecipeScanner.HandleCraftCompleted(itemId, itemLink, nil)
                    end
                end
                return
            end
            if event == "UNIT_SPELLCAST_SUCCEEDED" then
                if not (PF.IsSecret and (PF.IsSecret(arg1) or PF.IsSecret(arg3))) then
                    if arg1 == "player" and type(arg3) == "number" and arg3 > 0 then
                        PF.RecipeScanner.HandleCraftCompleted(nil, nil, arg3)
                    end
                end
                return
            end
            if event == "PLAYER_ENTERING_WORLD" or event == "SKILL_LINES_CHANGED" then
                local changed = PF.RecipeScanner.RepairSavedRecipeProfessions()
                if changed > 0 and PF.SideWindow and PF.SideWindow.frame
                    and (not PF.SideWindow.frame.IsShown or PF.SideWindow.frame:IsShown())
                    and PF.SideWindow.Refresh then
                    PF.SideWindow.Refresh()
                end
                return
            end

            local scanned = PF.RecipeScanner.ScanCurrentProfessionWindow()
            if scanned == 0 and not pendingScanRetry
                and (event == "TRADE_SKILL_SHOW" or event == "TRADE_SKILL_DATA_SOURCE_CHANGED" or event == "NEW_RECIPE_LEARNED")
                and _G.C_Timer and _G.C_Timer.After then
                pendingScanRetry = true
                _G.C_Timer.After(0.25, function()
                    pendingScanRetry = false
                    PF.RecipeScanner.ScanCurrentProfessionWindow()
                end)
            end

            if pendingOpenRecipe then
                local now = (_G.GetTime and _G.GetTime()) or 0
                if pendingOpenRecipe.expiresAt and now > pendingOpenRecipe.expiresAt then
                    pendingOpenRecipe = nil
                elseif event == "TRADE_SKILL_SHOW" or event == "TRADE_SKILL_DATA_SOURCE_CHANGED" or event == "TRADE_SKILL_LIST_UPDATE" or event == "CRAFT_SHOW" then
                    if _G.C_TradeSkillUI and SelectModernRecipe(pendingOpenRecipe) then
                        pendingOpenRecipe = nil
                    elseif SelectLegacyRecipe(pendingOpenRecipe) then
                        pendingOpenRecipe = nil
                    end
                end
            end
        end)
    end
    PF.RecipeScanner.frame = frame
end
