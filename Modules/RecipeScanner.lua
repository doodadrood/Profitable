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
            if base.outputItemId == outputItemId and type(base.profession) == "string" and not INVALID_CRAFTING_PROFESSIONS[base.profession] then
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
            local okProfs, p1, p2, arch, fish, cook = pcall(_G.GetProfessions)
            if okProfs then
                local targetLower = profName:lower()
                for _, idx in ipairs({ p1, p2, arch, fish, cook }) do
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

function PF.RecipeScanner.RepairSavedRecipeProfessions()
    if type(Profitable_DB) ~= "table" then
        return 0
    end
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
    return true
end

function PF.RecipeScanner.ScanLegacyTradeSkill()
    if not _G.GetNumTradeSkills or not _G.GetTradeSkillInfo then
        return 0
    end

    local okNum, numSkills = pcall(_G.GetNumTradeSkills)
    if not okNum or type(numSkills) ~= "number" or numSkills <= 0 then
        return 0
    end

    local professionName = "TradeSkill"
    if _G.GetTradeSkillLine then
        local okLine, lineName = pcall(_G.GetTradeSkillLine)
        if okLine and type(lineName) == "string" and lineName ~= "" and lineName ~= "UNKNOWN" then
            professionName = lineName
        end
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
                        professionId = PROFESSION_TO_SKILL_LINE_ID[professionName],
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

    local okNum, numCrafts = pcall(_G.GetNumCrafts)
    if not okNum or type(numCrafts) ~= "number" or numCrafts <= 0 then
        return 0
    end

    local professionName = "Enchanting"
    if _G.GetCraftDisplaySkillLine then
        local okLine, lineName = pcall(_G.GetCraftDisplaySkillLine)
        if okLine and type(lineName) == "string" and lineName ~= "" then
            professionName = lineName
        end
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
                        professionId = PROFESSION_TO_SKILL_LINE_ID[professionName],
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

    -- Never save another player's linked or guild profession recipes as the character's own
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

    local charRecipes = EnsureCharRecipeTable()
    local scanned = 0

    for _, recipeID in ipairs(recipeIDs) do
        local okInfo, info = pcall(_G.C_TradeSkillUI.GetRecipeInfo, recipeID)
        if okInfo and type(info) == "table" and info.learned then
            local schematic = _G.C_TradeSkillUI.GetRecipeSchematic and _G.C_TradeSkillUI.GetRecipeSchematic(recipeID, false)
            local outputItemId = (schematic and schematic.outputItemID) or info.itemID
            if outputItemId and outputItemId > 0 and schematic and type(schematic.reagentSlotSchematics) == "table" then
                local minMade = schematic.quantityMin or 1
                local maxMade = schematic.quantityMax or minMade
                local reagents = {}
                for _, slot in ipairs(schematic.reagentSlotSchematics) do
                    local rItemId = slot.reagents and slot.reagents[1] and slot.reagents[1].itemID
                    local rCount = slot.quantityRequired or 1
                    if rItemId and rItemId > 0 and rCount > 0 then
                        local meta = PF.VendorDatabase.GetItemMetadata(rItemId)
                        table.insert(reagents, {
                            itemId = rItemId,
                            name = (meta and meta.name) or string.format("Item #%d", rItemId),
                            count = rCount,
                        })
                    end
                end
                if #reagents > 0 then
                    local recipeName = info.name or string.format("Recipe #%d", recipeID)
                    local key = tostring(recipeID) .. ":" .. tostring(recipeName)
                    local existingRecipe = charRecipes[key]
                    local recipeProf, recipeProfId = ResolveRecipeProfession(recipeID, windowProfName, windowProfId, outputItemId, existingRecipe)
                    local saved = SaveRecipe(charRecipes, {
                        recipeId = recipeID,
                        name = recipeName,
                        profession = recipeProf,
                        professionId = recipeProfId,
                        outputItemId = outputItemId,
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

function PF.RecipeScanner.GetKnownRecipes()
    PF.RecipeScanner.ScanCurrentProfessionWindow()

    local list = {}
    local seenByOutput = {}
    local knownProfessions = {}

    local function AddFromTable(tbl)
        if type(tbl) ~= "table" then return end
        for key, recipe in pairs(tbl) do
            if type(recipe) == "table" and recipe.outputItemId and not seenByOutput[recipe.outputItemId] then
                if (recipe.recipeId and not recipe.professionId) or INVALID_CRAFTING_PROFESSIONS[recipe.profession or ""] then
                    PF.RecipeScanner.NormalizeRecipeProfession(recipe)
                end
                seenByOutput[recipe.outputItemId] = true
                if recipe.profession and not INVALID_CRAFTING_PROFESSIONS[recipe.profession] then
                    knownProfessions[recipe.profession] = math.max(knownProfessions[recipe.profession] or 0, recipe.skillReq or 1)
                end
                table.insert(list, recipe)
            end
        end
    end

    if Profitable_DB and Profitable_DB.charRecipes then
        if Profitable_DB.settings and Profitable_DB.settings.includeAllCharRecipes then
            for _, charTbl in pairs(Profitable_DB.charRecipes) do
                AddFromTable(charTbl)
            end
        else
            local charKey = PF.GetCharacterKey()
            AddFromTable(Profitable_DB.charRecipes[charKey])
        end
    end

    -- Incorporate skill-matched baseline recipes and Trainer/Unlearned recipe recommendations
    local settings = (Profitable_DB and Profitable_DB.settings) or {}
    if settings.includeSkillMatchedBaselineRecipes ~= false and PF.RecipeDatabase and PF.RecipeDatabase.GetAllBaselineRecipes then
        local skillRanks = PF.RecipeDatabase.GetCharacterSkillRanks()
        for prof, info in pairs(skillRanks) do
            knownProfessions[prof] = math.max(knownProfessions[prof] or 0, info.rank or 0)
        end

        local lookahead = (settings.includeTrainerRecommendations ~= false) and (settings.trainerSkillLookahead or 25) or 0
        for _, base in ipairs(PF.RecipeDatabase.GetAllBaselineRecipes()) do
            if not seenByOutput[base.outputItemId] and base.profession and knownProfessions[base.profession] then
                local charRank = knownProfessions[base.profession]
                local req = base.skillReq or 1
                if req <= (charRank + lookahead) then
                    seenByOutput[base.outputItemId] = true
                    local isUnlearned = (req > charRank) or (base.source and base.source ~= "Trainer")
                    table.insert(list, {
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
                    })
                end
            end
        end
    end

    return list
end

function PF.RecipeScanner.GetIntermediateRecipeForItem(itemId)
    if not itemId then return nil end
    -- Prefer the character's own scanned recipe if known
    local known = PF.RecipeScanner.GetKnownRecipes()
    for _, recipe in ipairs(known) do
        if recipe.outputItemId == itemId then
            return recipe
        end
    end
    -- Check if the character has any recipe in that profession before using static intermediate conversion
    local staticConv = INTERMEDIATE_CONVERSIONS[itemId]
    if staticConv then
        for _, recipe in ipairs(known) do
            if recipe.profession == staticConv.profession then
                return staticConv
            end
        end
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
    local targetId = FindModernRecipeIdInOpenWindow(recipe)
    if not targetId then return false end

    local pf = _G.ProfessionsFrame
    if pf and (not pf.IsShown or pf:IsShown()) and pf.CraftingPage and pf.CraftingPage.SelectRecipe and _G.C_TradeSkillUI.GetRecipeInfo then
        local okInfo, recipeInfo = pcall(_G.C_TradeSkillUI.GetRecipeInfo, targetId)
        if okInfo and type(recipeInfo) == "table" then
            local okSel = pcall(pf.CraftingPage.SelectRecipe, pf.CraftingPage, recipeInfo)
            if okSel then
                return true
            end
        end
    end

    if _G.C_TradeSkillUI.OpenRecipe then
        local okOpen = pcall(_G.C_TradeSkillUI.OpenRecipe, targetId)
        if okOpen then
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
    if not recipe then return false end
    quantity = math.max(1, math.floor(tonumber(quantity) or 1))

    if recipe.recipeId and _G.C_TradeSkillUI and _G.C_TradeSkillUI.CraftRecipe then
        local ok = pcall(_G.C_TradeSkillUI.CraftRecipe, recipe.recipeId, quantity)
        if ok then return true end
    end

    if _G.GetNumTradeSkills and _G.GetTradeSkillInfo and _G.DoTradeSkill then
        local num = _G.GetNumTradeSkills() or 0
        for i = 1, num do
            local name, skillType = _G.GetTradeSkillInfo(i)
            local link = _G.GetTradeSkillItemLink and _G.GetTradeSkillItemLink(i)
            local outId = link and tonumber(link:match("item:(%d+)"))
            if skillType ~= "header" and skillType ~= "subheader" and (outId == recipe.outputItemId or name == recipe.name) then
                pcall(_G.DoTradeSkill, i, quantity)
                return true
            end
        end
    end

    return PF.RecipeScanner.OpenRecipe(recipe)
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
        pcall(frame.RegisterEvent, frame, "CRAFT_SHOW")
        pcall(frame.RegisterEvent, frame, "CRAFT_UPDATE")
        pcall(frame.RegisterEvent, frame, "PLAYER_ENTERING_WORLD")
        frame:SetScript("OnEvent", function(_, event)
            if event == "PLAYER_ENTERING_WORLD" then
                PF.RecipeScanner.RepairSavedRecipeProfessions()
                return
            end

            PF.RecipeScanner.ScanCurrentProfessionWindow()

            if pendingOpenRecipe then
                local now = (_G.GetTime and _G.GetTime()) or 0
                if pendingOpenRecipe.expiresAt and now > pendingOpenRecipe.expiresAt then
                    pendingOpenRecipe = nil
                elseif event == "TRADE_SKILL_SHOW" or event == "TRADE_SKILL_DATA_SOURCE_CHANGED" or event == "CRAFT_SHOW" then
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
