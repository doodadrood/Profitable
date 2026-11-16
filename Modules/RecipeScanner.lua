local _, PF = ...
PF = type(PF) == "table" and PF or _G.PF or {}
_G.PF = PF

PF.RecipeScanner = {}

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

    local okIds, recipeIDs = pcall(_G.C_TradeSkillUI.GetAllRecipeIDs)
    if not okIds or type(recipeIDs) ~= "table" or #recipeIDs == 0 then
        return 0
    end

    local professionName = "Profession"
    if _G.C_TradeSkillUI.GetBaseProfessionInfo then
        local okProf, profInfo = pcall(_G.C_TradeSkillUI.GetBaseProfessionInfo)
        if okProf and type(profInfo) == "table" and profInfo.professionName then
            professionName = profInfo.professionName
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
                    local saved = SaveRecipe(charRecipes, {
                        recipeId = recipeID,
                        name = info.name or string.format("Recipe #%d", recipeID),
                        profession = professionName,
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
                seenByOutput[recipe.outputItemId] = true
                if recipe.profession then
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

function PF.RecipeScanner.OpenRecipe(recipe)
    if not recipe then return false end

    -- Modern C_TradeSkillUI path
    if recipe.recipeId and _G.C_TradeSkillUI and _G.C_TradeSkillUI.OpenRecipe then
        local ok = pcall(_G.C_TradeSkillUI.OpenRecipe, recipe.recipeId)
        if ok then return true end
    end

    -- Open the profession window by spell name if not currently visible
    if recipe.profession and _G.CastSpellByName then
        pcall(_G.CastSpellByName, recipe.profession)
    end

    -- Select the recipe in the legacy TradeSkillFrame
    if _G.GetNumTradeSkills and _G.GetTradeSkillInfo and _G.SelectTradeSkill then
        local num = _G.GetNumTradeSkills() or 0
        for i = 1, num do
            local name, skillType = _G.GetTradeSkillInfo(i)
            local link = _G.GetTradeSkillItemLink and _G.GetTradeSkillItemLink(i)
            local outId = link and tonumber(link:match("item:(%d+)"))
            if skillType ~= "header" and (outId == recipe.outputItemId or name == recipe.name) then
                pcall(_G.SelectTradeSkill, i)
                if _G.TradeSkillFrame_SetSelection then
                    pcall(_G.TradeSkillFrame_SetSelection, i)
                end
                return true
            end
        end
    end

    return false
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
            if skillType ~= "header" and (outId == recipe.outputItemId or name == recipe.name) then
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

    local frame = CreateFrame("Frame")
    if frame and frame.RegisterEvent then
        pcall(frame.RegisterEvent, frame, "TRADE_SKILL_SHOW")
        pcall(frame.RegisterEvent, frame, "TRADE_SKILL_UPDATE")
        pcall(frame.RegisterEvent, frame, "CRAFT_SHOW")
        pcall(frame.RegisterEvent, frame, "CRAFT_UPDATE")
        frame:SetScript("OnEvent", function()
            PF.RecipeScanner.ScanCurrentProfessionWindow()
        end)
    end
    PF.RecipeScanner.frame = frame
end
