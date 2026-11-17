local _, PF = ...
PF = type(PF) == "table" and PF or _G.PF or {}
_G.PF = PF

PF.OpportunityEngine = {}

local ACTION_LABELS = {
    VENDOR       = "Vendor",
    BUY_DE       = "Buy and DE",
    CRAFT_VENDOR = "Craft and Vendor",
    CRAFT_AH     = "Craft and AH",
    CRAFT_DE     = "Craft and DE",
}

PF.OpportunityEngine.ACTION_LABELS = ACTION_LABELS

-- Resolves pure AH unit price and available count without falling back to Vendor sell price
function PF.OpportunityEngine.ResolveAHPrice(itemId, itemLink)
    if not itemId or itemId <= 0 then
        return nil, 0, nil
    end

    -- 1. Check live verified orderBookCache if fresh (within 10 minutes)
    if Profitable_DB and Profitable_DB.orderBookCache and Profitable_DB.orderBookCache[itemId] then
        local ob = Profitable_DB.orderBookCache[itemId]
        if type(ob.listings) == "table" and #ob.listings > 0 and (time() - (ob.timestamp or 0)) <= 600 then
            local totalQty = 0
            local minUnit = nil
            for _, tier in ipairs(ob.listings) do
                if tier.unitPrice and tier.unitPrice > 0 and tier.quantity and tier.quantity > 0 then
                    totalQty = totalQty + tier.quantity
                    if not minUnit or tier.unitPrice < minUnit then
                        minUnit = tier.unitPrice
                    end
                end
            end
            if minUnit and totalQty > 0 then
                return minUnit, totalQty, "Verified AH"
            end
        end
    end

    -- 2. Check PCF_DB.prices directly (gives both minBuyout and scanned count)
    if _G.PCF_DB and type(_G.PCF_DB.prices) == "table" and _G.PCF_DB.prices[itemId] then
        local entry = _G.PCF_DB.prices[itemId]
        if entry.minBuyout and entry.minBuyout > 0 then
            local count = (entry.count and entry.count > 0) and entry.count or 1
            return entry.minBuyout, count, entry.source or "PCF Scan"
        end
    end

    -- 3. Fallback to PCF.ProviderRegistry.ResolveAHPrice (TSM / Auctionator)
    if _G.PCF and _G.PCF.ProviderRegistry and _G.PCF.ProviderRegistry.ResolveAHPrice then
        local ok, ahPrice, ahSource = pcall(_G.PCF.ProviderRegistry.ResolveAHPrice, itemLink, itemId)
        if ok and type(ahPrice) == "number" and ahPrice > 0 then
            local count = (_G.PCF_DB and _G.PCF_DB.prices and _G.PCF_DB.prices[itemId] and _G.PCF_DB.prices[itemId].count) or 20
            return math.floor(ahPrice), math.max(1, count), ahSource or "External AH"
        end
    end

    return nil, 0, nil
end

-- Returns an ascending-price array of { unitPrice = number, quantity = number }
function PF.OpportunityEngine.GetOrderBook(itemId, customOrderBooks)
    if not itemId or itemId <= 0 then
        return {}
    end

    local rawListings = nil
    if type(customOrderBooks) == "table" and type(customOrderBooks[itemId]) == "table" then
        rawListings = customOrderBooks[itemId]
    elseif Profitable_DB and Profitable_DB.orderBookCache and Profitable_DB.orderBookCache[itemId] then
        local ob = Profitable_DB.orderBookCache[itemId]
        if type(ob.listings) == "table" and #ob.listings > 0 and (time() - (ob.timestamp or 0)) <= 600 then
            rawListings = ob.listings
        end
    end

    if type(rawListings) == "table" then
        local byPrice = {}
        local tiers = {}
        for _, row in ipairs(rawListings) do
            local up = row and row.unitPrice and math.floor(row.unitPrice)
            local qty = row and row.quantity and math.floor(row.quantity)
            if up and up > 0 and qty and qty > 0 then
                if not byPrice[up] then
                    byPrice[up] = { unitPrice = up, quantity = qty }
                    table.insert(tiers, byPrice[up])
                else
                    byPrice[up].quantity = byPrice[up].quantity + qty
                end
            end
        end
        table.sort(tiers, function(a, b) return a.unitPrice < b.unitPrice end)
        return tiers
    end

    local unitPrice, count = PF.OpportunityEngine.ResolveAHPrice(itemId)
    if unitPrice and unitPrice > 0 and count and count > 0 then
        return {
            { unitPrice = unitPrice, quantity = count }
        }
    end

    return {}
end

-- Resolves whether a reagent is cheapest from Vendor, direct AH, or Intermediate Crafting
local function ResolveReagentPlan(reagentList, customOrderBooks)
    local expanded = {}
    local intermediateSteps = {}
    local allowIntermediate = not (Profitable_DB and Profitable_DB.settings and Profitable_DB.settings.useIntermediateCrafting == false)

    local function AddExpandedReagent(itemId, count, name, link)
        local vendorBuy = PF.VendorDatabase.GetVendorBuyPrice(itemId)
        local ahUnit = PF.OpportunityEngine.ResolveAHPrice(itemId, link)

        local source = "AH"
        if vendorBuy and vendorBuy > 0 then
            if not ahUnit or vendorBuy <= ahUnit then
                source = "Vendor"
            end
        end

        for _, existing in ipairs(expanded) do
            if existing.itemId == itemId and existing.source == source then
                existing.countPerUnit = existing.countPerUnit + count
                return
            end
        end

        local meta = PF.VendorDatabase.GetItemMetadata(itemId, link)
        local resolvedName = name or (meta and meta.name) or string.format("Item #%d", itemId)
        table.insert(expanded, {
            itemId = itemId,
            name = resolvedName,
            link = PF.Formatter.BuildItemLink(itemId, resolvedName, meta and meta.quality, link),
            countPerUnit = count,
            source = source,
            vendorUnitPrice = (source == "Vendor") and vendorBuy or nil,
        })
    end

    for _, r in ipairs(reagentList) do
        local itemId = r.itemId
        local countNeeded = r.count or r.countPerUnit or 1
        local vendorBuy = PF.VendorDatabase.GetVendorBuyPrice(itemId)

        if vendorBuy and vendorBuy > 0 then
            AddExpandedReagent(itemId, countNeeded, r.name, r.link)
        else
            local directBook = PF.OpportunityEngine.GetOrderBook(itemId, customOrderBooks)
            local directUnitPrice = (#directBook > 0) and directBook[1].unitPrice or nil
            local usedIntermediate = false

            if allowIntermediate and PF.RecipeScanner and PF.RecipeScanner.GetIntermediateRecipeForItem then
                local interRecipe = PF.RecipeScanner.GetIntermediateRecipeForItem(itemId)
                if interRecipe and interRecipe.reagents and #interRecipe.reagents > 0 then
                    local avgMade = (interRecipe.avgMade and interRecipe.avgMade > 0) and interRecipe.avgMade or 1
                    local subCost = 0
                    local subAvailable = true
                    for _, subR in ipairs(interRecipe.reagents) do
                        local subVendor = PF.VendorDatabase.GetVendorBuyPrice(subR.itemId)
                        local subBook = PF.OpportunityEngine.GetOrderBook(subR.itemId, customOrderBooks)
                        local subUnit = subVendor or ((#subBook > 0) and subBook[1].unitPrice) or nil
                        if subUnit and subUnit > 0 then
                            subCost = subCost + (subUnit * subR.count)
                        else
                            subAvailable = false
                            break
                        end
                    end
                    local craftUnitCost = subAvailable and math.ceil(subCost / avgMade) or nil
                    if craftUnitCost and (not directUnitPrice or craftUnitCost < directUnitPrice) then
                        usedIntermediate = true
                        local batchesPerCraft = countNeeded / avgMade
                        table.insert(intermediateSteps, {
                            recipeName = interRecipe.name,
                            profession = interRecipe.profession,
                            outputItemId = itemId,
                            countPerUnit = countNeeded,
                        })
                        for _, subR in ipairs(interRecipe.reagents) do
                            local rawCount = math.ceil(subR.count * batchesPerCraft)
                            AddExpandedReagent(subR.itemId, rawCount, subR.name, subR.link)
                        end
                    end
                end
            end

            if not usedIntermediate then
                AddExpandedReagent(itemId, countNeeded, r.name, r.link)
            end
        end
    end

    return expanded, intermediateSteps
end

local function ComputeEndResultKey(candidate)
    if candidate.endResultKey then
        return candidate.endResultKey
    end
    if (candidate.actionType == "BUY_DE" or candidate.actionType == "CRAFT_DE") and candidate.deBreakdown and candidate.deBreakdown.primaryMat then
        local pm = candidate.deBreakdown.primaryMat
        local matId = pm.sellItemId or pm.itemId
        if matId then
            return "DE_MAT:" .. tostring(matId)
        end
    end
    if candidate.actionType == "CRAFT_AH" then
        return "AH_ITEM:" .. tostring(candidate.itemId)
    end
    return "VENDOR:" .. tostring(candidate.itemId)
end

-- Core Stepped Order-Book Calculator for single-item or recipe plays
function PF.OpportunityEngine.CalculateSteppedOpportunity(candidate, budgetCopper, customOrderBooks)
    if not candidate or not candidate.unitNetRevenue or candidate.unitNetRevenue <= 0 then
        return nil
    end

    local settings = (Profitable_DB and Profitable_DB.settings) or {}
    local maxCap = candidate.maxUnits or 50
    local reagents, intermediateSteps = ResolveReagentPlan(candidate.rawReagents or {}, customOrderBooks)
    if #reagents == 0 then
        return nil
    end

    local cursors = {}
    for idx, r in ipairs(reagents) do
        if r.source == "Vendor" then
            cursors[idx] = {
                source = "Vendor",
                vendorPrice = r.vendorUnitPrice,
                tiersUsed = {},
                totalQty = 0,
                totalCost = 0,
                minUnitPrice = r.vendorUnitPrice,
                maxUnitPrice = r.vendorUnitPrice,
            }
        else
            local tiers = PF.OpportunityEngine.GetOrderBook(r.itemId, customOrderBooks)
            if #tiers == 0 then
                return nil
            end
            local copyTiers = {}
            for _, t in ipairs(tiers) do
                table.insert(copyTiers, { unitPrice = t.unitPrice, remaining = t.quantity })
            end
            cursors[idx] = {
                source = "AH",
                tiers = copyTiers,
                tierIdx = 1,
                tiersUsed = {},
                tiersUsedByPrice = {},
                totalQty = 0,
                totalCost = 0,
                minUnitPrice = nil,
                maxUnitPrice = nil,
            }
        end
    end

    local units = 0
    local totalCost = 0
    local totalGrossRevenue = 0
    local totalNetRevenue = 0
    local totalAHCut = 0
    local totalDepositRisk = 0
    local unitNetRev = candidate.unitNetRevenue
    local unitGrossRev = candidate.unitGrossRevenue or unitNetRev
    local unitAHCut = candidate.unitAHCut or math.max(0, unitGrossRev - unitNetRev - (candidate.unitDepositRisk or 0))
    local unitDeposit = candidate.unitDepositRisk or 0
    local stoppedReason = "MAX_CAP"

    while units < maxCap do
        local unitCost = 0
        local pulls = {}
        local supplyExhausted = false

        for idx, r in ipairs(reagents) do
            local needed = r.countPerUnit
            local cur = cursors[idx]

            if cur.source == "Vendor" then
                local cost = needed * cur.vendorPrice
                unitCost = unitCost + cost
                pulls[idx] = { isVendor = true, qty = needed, cost = cost, price = cur.vendorPrice }
            else
                local simTierIdx = cur.tierIdx
                local remNeeded = needed
                local simSlices = {}
                local reagentCost = 0

                while remNeeded > 0 do
                    local tier = cur.tiers[simTierIdx]
                    if not tier then
                        supplyExhausted = true
                        break
                    end
                    if tier.remaining <= 0 then
                        simTierIdx = simTierIdx + 1
                    else
                        local take = math.min(remNeeded, tier.remaining)
                        table.insert(simSlices, { tierIdx = simTierIdx, take = take, unitPrice = tier.unitPrice })
                        reagentCost = reagentCost + (take * tier.unitPrice)
                        remNeeded = remNeeded - take
                        if take == tier.remaining then
                            simTierIdx = simTierIdx + 1
                        end
                    end
                end

                if supplyExhausted then
                    break
                end

                unitCost = unitCost + reagentCost
                pulls[idx] = { isVendor = false, slices = simSlices, qty = needed, cost = reagentCost }
            end
        end

        if supplyExhausted then
            stoppedReason = "AH_SUPPLY"
            break
        end

        if unitCost >= unitNetRev then
            stoppedReason = "PRICE_TIER_UNPROFITABLE"
            break
        end

        if budgetCopper and budgetCopper > 0 and (totalCost + unitCost) > budgetCopper then
            stoppedReason = "BUDGET_LIMIT"
            break
        end

        units = units + 1
        totalCost = totalCost + unitCost
        totalGrossRevenue = totalGrossRevenue + unitGrossRev
        totalNetRevenue = totalNetRevenue + unitNetRev
        totalAHCut = totalAHCut + unitAHCut
        totalDepositRisk = totalDepositRisk + unitDeposit

        for idx, pull in ipairs(pulls) do
            local cur = cursors[idx]
            cur.totalQty = cur.totalQty + pull.qty
            cur.totalCost = cur.totalCost + pull.cost

            if not pull.isVendor then
                for _, slice in ipairs(pull.slices) do
                    local tier = cur.tiers[slice.tierIdx]
                    tier.remaining = tier.remaining - slice.take
                    if tier.remaining <= 0 and cur.tierIdx == slice.tierIdx then
                        cur.tierIdx = slice.tierIdx + 1
                    end

                    if not cur.minUnitPrice or slice.unitPrice < cur.minUnitPrice then
                        cur.minUnitPrice = slice.unitPrice
                    end
                    if not cur.maxUnitPrice or slice.unitPrice > cur.maxUnitPrice then
                        cur.maxUnitPrice = slice.unitPrice
                    end

                    local usedEntry = cur.tiersUsedByPrice[slice.unitPrice]
                    if not usedEntry then
                        usedEntry = { unitPrice = slice.unitPrice, quantity = slice.take }
                        cur.tiersUsedByPrice[slice.unitPrice] = usedEntry
                        table.insert(cur.tiersUsed, usedEntry)
                    else
                        usedEntry.quantity = usedEntry.quantity + slice.take
                    end
                end
            else
                if #cur.tiersUsed == 0 then
                    table.insert(cur.tiersUsed, { unitPrice = pull.price, quantity = pull.qty })
                else
                    cur.tiersUsed[1].quantity = cur.tiersUsed[1].quantity + pull.qty
                end
            end
        end
    end

    if units <= 0 then
        return nil
    end

    local totalProfit = totalNetRevenue - totalCost
    local minProfit = settings.minProfitCopper or 100
    if totalProfit < minProfit then
        return nil
    end

    local roiPercent = (totalCost > 0) and math.floor(((totalProfit / totalCost) * 100) + 0.5) or 0
    local minROI = settings.minROIPercent or 5
    if roiPercent < minROI then
        return nil
    end

    local shoppingList = {}
    for idx, r in ipairs(reagents) do
        local cur = cursors[idx]
        local avgUnit = (cur.totalQty > 0) and math.floor((cur.totalCost / cur.totalQty) + 0.5) or 0
        local inBags = PF.Formatter.GetInventoryCount(r.itemId, false)
        local inBank = math.max(0, PF.Formatter.GetInventoryCount(r.itemId, true) - inBags)

        table.insert(shoppingList, {
            itemId = r.itemId,
            name = r.name,
            link = r.link,
            source = r.source,
            countPerUnit = r.countPerUnit,
            totalQuantity = cur.totalQty,
            haveInBags = inBags,
            haveInBank = inBank,
            remainingToBuy = math.max(0, cur.totalQty - inBags),
            totalCost = cur.totalCost,
            minUnitPrice = cur.minUnitPrice or avgUnit,
            maxUnitPrice = cur.maxUnitPrice or avgUnit,
            avgUnitPrice = avgUnit,
            tiersUsed = cur.tiersUsed,
        })
    end

    local actionLabel = ACTION_LABELS[candidate.actionType] or candidate.actionType
    local meta = PF.VendorDatabase.GetItemMetadata(candidate.itemId, candidate.itemLink)
    local itemName = candidate.itemName or (meta and meta.name) or string.format("Item #%d", candidate.itemId)
    local itemLink = PF.Formatter.BuildItemLink(candidate.itemId, itemName, meta and meta.quality, candidate.itemLink)
    local pm = candidate.deBreakdown and candidate.deBreakdown.primaryMat

    return {
        id = string.format("%s:%d", tostring(candidate.actionType), candidate.itemId),
        endResultKey = ComputeEndResultKey(candidate),
        actionType = candidate.actionType,
        actionLabel = actionLabel,
        itemId = candidate.itemId,
        itemName = itemName,
        itemLink = itemLink,
        targetMatId = pm and (pm.sellItemId or pm.itemId) or nil,
        targetMatName = pm and pm.name or nil,
        targetMatLink = pm and pm.link or nil,
        distinctItemCount = 1,
        texture = meta and meta.texture,
        recipe = candidate.recipe,
        deBreakdown = candidate.deBreakdown,
        intermediateSteps = intermediateSteps,
        quantity = units,
        outputQuantity = math.floor(units * (candidate.avgMade or 1)),
        ahCutRate = candidate.ahCutRate or 0,
        unitGrossRevenue = unitGrossRev,
        unitNetRevenue = unitNetRev,
        unitAHCut = unitAHCut,
        unitDepositRisk = unitDeposit,
        totalCost = totalCost,
        totalGrossRevenue = totalGrossRevenue,
        totalNetRevenue = totalNetRevenue,
        totalAHCut = totalAHCut,
        totalDepositRisk = totalDepositRisk,
        totalProfit = totalProfit,
        roiPercent = roiPercent,
        stoppedReason = stoppedReason,
        shoppingList = shoppingList,
        verified = (candidate.verified == true),
    }
end

-- Aggregates all BUY_DE items that disenchant into the same primary enchanting material
-- (e.g., 5 different blue items that all DE into [Large Glimmering Shard]) into a single
-- lane so they don't occupy all 5 slots of the Top 5!
function PF.OpportunityEngine.CalculateAggregatedBuyDEOpportunity(groupCandidates, budgetCopper, customOrderBooks)
    if type(groupCandidates) ~= "table" or #groupCandidates == 0 then
        return nil
    end

    local settings = (Profitable_DB and Profitable_DB.settings) or {}
    local firstCand = groupCandidates[1]
    local pm = firstCand.deBreakdown and firstCand.deBreakdown.primaryMat
    if not pm then
        return PF.OpportunityEngine.CalculateSteppedOpportunity(firstCand, budgetCopper, customOrderBooks)
    end

    local isShard = (firstCand.deBreakdown and firstCand.deBreakdown.isShardOrCrystal) == true
    local maxUnits = isShard and (settings.maxShardDEUnits or 8) or (settings.maxDEUnits or 30)
    local maxDistinctItems = 8

    -- Collect all profitable price slices across every item in this DE material group
    local slices = {}
    for _, cand in ipairs(groupCandidates) do
        local tiers = PF.OpportunityEngine.GetOrderBook(cand.itemId, customOrderBooks)
        for _, t in ipairs(tiers) do
            if t.unitPrice and t.unitPrice > 0 and t.quantity and t.quantity > 0 and t.unitPrice < cand.unitNetRevenue then
                table.insert(slices, {
                    cand = cand,
                    itemId = cand.itemId,
                    itemName = cand.itemName,
                    unitPrice = t.unitPrice,
                    available = t.quantity,
                    unitGrossRev = cand.unitGrossRevenue,
                    unitNetRev = cand.unitNetRevenue,
                    unitAHCut = cand.unitAHCut or math.max(0, cand.unitGrossRevenue - cand.unitNetRevenue),
                    unitProfit = cand.unitNetRevenue - t.unitPrice,
                })
            end
        end
    end

    if #slices == 0 then
        return nil
    end

    -- Sort slices from highest net profit per item to lowest (tie-break by lowest cost)
    table.sort(slices, function(a, b)
        if a.unitProfit ~= b.unitProfit then
            return a.unitProfit > b.unitProfit
        end
        if a.unitPrice ~= b.unitPrice then
            return a.unitPrice < b.unitPrice
        end
        return a.itemId < b.itemId
    end)

    local units = 0
    local totalCost = 0
    local totalGrossRevenue = 0
    local totalNetRevenue = 0
    local totalAHCut = 0
    local byItemId = {}
    local itemOrder = {}
    local stoppedReason = "MAX_CAP"

    for _, slice in ipairs(slices) do
        for _ = 1, slice.available do
            if units >= maxUnits then
                stoppedReason = "MAX_CAP"
                break
            end
            if not byItemId[slice.itemId] and #itemOrder >= maxDistinctItems then
                break
            end
            if budgetCopper and budgetCopper > 0 and (totalCost + slice.unitPrice) > budgetCopper then
                stoppedReason = "BUDGET_LIMIT"
                break
            end

            units = units + 1
            totalCost = totalCost + slice.unitPrice
            totalGrossRevenue = totalGrossRevenue + slice.unitGrossRev
            totalNetRevenue = totalNetRevenue + slice.unitNetRev
            totalAHCut = totalAHCut + slice.unitAHCut

            local acc = byItemId[slice.itemId]
            if not acc then
                local meta = PF.VendorDatabase.GetItemMetadata(slice.itemId)
                local name = slice.itemName or (meta and meta.name) or string.format("Item #%d", slice.itemId)
                acc = {
                    itemId = slice.itemId,
                    name = name,
                    link = PF.Formatter.BuildItemLink(slice.itemId, name, meta and meta.quality),
                    totalQty = 0,
                    totalCost = 0,
                    minUnitPrice = slice.unitPrice,
                    maxUnitPrice = slice.unitPrice,
                    tiersUsed = {},
                    tiersByPrice = {},
                    cand = slice.cand,
                }
                byItemId[slice.itemId] = acc
                table.insert(itemOrder, acc)
            end

            acc.totalQty = acc.totalQty + 1
            acc.totalCost = acc.totalCost + slice.unitPrice
            if slice.unitPrice < acc.minUnitPrice then acc.minUnitPrice = slice.unitPrice end
            if slice.unitPrice > acc.maxUnitPrice then acc.maxUnitPrice = slice.unitPrice end

            local tierEntry = acc.tiersByPrice[slice.unitPrice]
            if not tierEntry then
                tierEntry = { unitPrice = slice.unitPrice, quantity = 1 }
                acc.tiersByPrice[slice.unitPrice] = tierEntry
                table.insert(acc.tiersUsed, tierEntry)
            else
                tierEntry.quantity = tierEntry.quantity + 1
            end
        end
    end

    if units <= 0 or #itemOrder == 0 then
        return nil
    end

    local totalProfit = totalNetRevenue - totalCost
    local minProfit = settings.minProfitCopper or 100
    if totalProfit < minProfit then
        return nil
    end

    local roiPercent = (totalCost > 0) and math.floor(((totalProfit / totalCost) * 100) + 0.5) or 0
    local minROI = settings.minROIPercent or 5
    if roiPercent < minROI then
        return nil
    end

    local shoppingList = {}
    for _, acc in ipairs(itemOrder) do
        local avgUnit = math.floor((acc.totalCost / acc.totalQty) + 0.5)
        local inBags = PF.Formatter.GetInventoryCount(acc.itemId, false)
        local inBank = math.max(0, PF.Formatter.GetInventoryCount(acc.itemId, true) - inBags)
        table.insert(shoppingList, {
            itemId = acc.itemId,
            name = acc.name,
            link = acc.link,
            source = "AH",
            countPerUnit = 1,
            totalQuantity = acc.totalQty,
            haveInBags = inBags,
            haveInBank = inBank,
            remainingToBuy = math.max(0, acc.totalQty - inBags),
            totalCost = acc.totalCost,
            minUnitPrice = acc.minUnitPrice,
            maxUnitPrice = acc.maxUnitPrice,
            avgUnitPrice = avgUnit,
            tiersUsed = acc.tiersUsed,
        })
    end

    local leadItem = itemOrder[1]
    local targetMatId = pm.sellItemId or pm.itemId
    local avgGrossRev = math.floor((totalGrossRevenue / units) + 0.5)
    local avgNetRev = math.floor((totalNetRevenue / units) + 0.5)
    local avgAHCut = math.floor((totalAHCut / units) + 0.5)

    return {
        id = string.format("BUY_DE_MAT:%d", targetMatId),
        endResultKey = "DE_MAT:" .. tostring(targetMatId),
        actionType = "BUY_DE",
        actionLabel = ACTION_LABELS.BUY_DE,
        itemId = leadItem.itemId,
        itemName = leadItem.name,
        itemLink = leadItem.link,
        targetMatId = targetMatId,
        targetMatName = pm.name,
        targetMatLink = pm.link,
        distinctItemCount = #itemOrder,
        deBreakdown = leadItem.cand.deBreakdown,
        intermediateSteps = {},
        quantity = units,
        outputQuantity = units,
        ahCutRate = firstCand.ahCutRate or 0.05,
        unitGrossRevenue = avgGrossRev,
        unitNetRevenue = avgNetRev,
        unitAHCut = avgAHCut,
        unitDepositRisk = 0,
        totalCost = totalCost,
        totalGrossRevenue = totalGrossRevenue,
        totalNetRevenue = totalNetRevenue,
        totalAHCut = totalAHCut,
        totalDepositRisk = 0,
        totalProfit = totalProfit,
        roiPercent = roiPercent,
        stoppedReason = stoppedReason,
        shoppingList = shoppingList,
        verified = false,
    }
end

function PF.OpportunityEngine.FormatOpportunityLine(rank, opp, customPrefix)
    if not opp then return "" end
    local costStr = PF.Formatter.FormatMoneyShort(opp.totalCost)
    local profitStr = PF.Formatter.FormatMoneyShort(opp.totalProfit)
    local prefix = customPrefix or ((rank and rank > 0) and string.format("%d.", rank) or nil)

    local targetDisplay = opp.itemLink
    if opp.actionType == "BUY_DE" and opp.targetMatLink then
        if opp.distinctItemCount and opp.distinctItemCount > 1 then
            targetDisplay = string.format("-> %s (%d items)", opp.targetMatLink, opp.distinctItemCount)
        else
            targetDisplay = string.format("%s -> %s", opp.itemLink, opp.targetMatLink)
        end
    end

    if prefix then
        return string.format("%s %s %s (Cost %s, Profit %s)", prefix, opp.actionLabel, targetDisplay, costStr, profitStr)
    end
    return string.format("%s %s (Cost %s, Profit %s)", opp.actionLabel, targetDisplay, costStr, profitStr)
end

function PF.OpportunityEngine.BuildDetailedExplanation(opp)
    if not opp then return "" end
    local lines = {}

    if opp.actionType == "VENDOR" then
        local shop = opp.shoppingList and opp.shoppingList[1]
        local vendorUnit = PF.Formatter.FormatMoney(opp.unitNetRevenue)
        local avgBuy = shop and PF.Formatter.FormatMoney(shop.avgUnitPrice) or "0c"
        table.insert(lines, string.format(
            "Buy %dx %s on the Auction House (avg %s each) and sell directly to any NPC vendor for %s each.",
            opp.quantity, opp.itemLink, avgBuy, vendorUnit
        ))
    elseif opp.actionType == "BUY_DE" then
        local deVal = PF.Formatter.FormatMoney(opp.unitNetRevenue)
        local cutPct = math.floor(((opp.ahCutRate or 0.05) * 100) + 0.5)
        if opp.distinctItemCount and opp.distinctItemCount > 1 and opp.targetMatLink then
            table.insert(lines, string.format(
                "Aggregated %s Disenchant Play: Buy %d total items across %d underpriced gear listings below, disenchant on your enchanter/bank alt, and sell the resulting %s on the AH (~%s net per DE after %d%% AH cut).",
                opp.targetMatLink, opp.quantity, opp.distinctItemCount, opp.targetMatLink, deVal, cutPct
            ))
        else
            local shop = opp.shoppingList and opp.shoppingList[1]
            local avgBuy = shop and PF.Formatter.FormatMoney(shop.avgUnitPrice) or "0c"
            table.insert(lines, string.format(
                "Buy %dx %s on the AH (avg %s each), disenchant on your enchanter/bank alt, and sell the resulting %s on the AH for an expected %s net per item (after %d%% AH cut).",
                opp.quantity, opp.itemLink, avgBuy, opp.targetMatLink or "enchanting materials", deVal, cutPct
            ))
        end
    elseif opp.actionType == "CRAFT_VENDOR" then
        local unitCost = PF.Formatter.FormatMoney(math.floor(opp.totalCost / math.max(1, opp.quantity)))
        local vendorUnit = PF.Formatter.FormatMoney(opp.unitNetRevenue)
        table.insert(lines, string.format(
            "Purchase materials to craft %dx %s (%s) at %s per craft and sell the crafted items directly to any NPC vendor for %s per craft (instant guaranteed gold, no AH cut).",
            opp.quantity, opp.itemLink, (opp.recipe and opp.recipe.profession) or "Crafting", unitCost, vendorUnit
        ))
    elseif opp.actionType == "CRAFT_AH" then
        local unitCost = PF.Formatter.FormatMoney(math.floor(opp.totalCost / math.max(1, opp.quantity)))
        local ahGross = PF.Formatter.FormatMoney(opp.unitGrossRevenue)
        local ahNet = PF.Formatter.FormatMoney(opp.unitNetRevenue)
        local cutPct = math.floor(((opp.ahCutRate or 0.05) * 100) + 0.5)
        local depNote = (opp.unitDepositRisk and opp.unitDepositRisk > 0)
            and string.format(" and %s est. relist deposit", PF.Formatter.FormatMoney(opp.unitDepositRisk))
            or ""
        table.insert(lines, string.format(
            "Purchase materials to craft %dx %s (%s) at %s per craft and list on the Auction House for %s (%s net after %d%% AH cut%s).",
            opp.quantity, opp.itemLink, (opp.recipe and opp.recipe.profession) or "Crafting", unitCost, ahGross, ahNet, cutPct, depNote
        ))
    elseif opp.actionType == "CRAFT_DE" then
        local unitCost = PF.Formatter.FormatMoney(math.floor(opp.totalCost / math.max(1, opp.quantity)))
        local deNet = PF.Formatter.FormatMoney(opp.unitNetRevenue)
        local cutPct = math.floor(((opp.ahCutRate or 0.05) * 100) + 0.5)
        table.insert(lines, string.format(
            "Purchase materials to craft %dx %s (%s) at %s per craft, disenchant them into %s, and sell on the AH for an expected %s net per craft (after %d%% AH cut).",
            opp.quantity, opp.itemLink, (opp.recipe and opp.recipe.profession) or "Crafting", unitCost, opp.targetMatLink or "enchanting materials", deNet, cutPct
        ))
    end

    if opp.recipe and opp.recipe.isTrainerRecommendation then
        table.insert(lines, string.format(
            "Recipe Source: %s — verify or learn this recipe in your %s window before buying materials.",
            opp.recipe.sourceHint or "Trainer", opp.recipe.profession or "Profession"
        ))
    end

    if opp.shoppingList and (opp.distinctItemCount or 1) == 1 then
        for _, shop in ipairs(opp.shoppingList) do
            if shop.source == "AH" and shop.tiersUsed and #shop.tiersUsed > 1 then
                local tierParts = {}
                for _, t in ipairs(shop.tiersUsed) do
                    table.insert(tierParts, string.format("%dx @ %s", t.quantity, PF.Formatter.FormatMoney(t.unitPrice)))
                end
                table.insert(lines, string.format(
                    "Stepped AH Pricing for %s: %s (stop buying above %s each).",
                    shop.name, table.concat(tierParts, ", "), PF.Formatter.FormatMoney(shop.maxUnitPrice)
                ))
            end
        end
    end

    if opp.intermediateSteps and #opp.intermediateSteps > 0 then
        for _, step in ipairs(opp.intermediateSteps) do
            table.insert(lines, string.format(
                "Intermediate Step (%s): Craft %dx %s per unit from raw materials instead of buying overpriced bolts/bars.",
                step.profession or "Craft", step.countPerUnit or 1, step.recipeName or "intermediate material"
            ))
        end
    end

    if opp.deBreakdown and opp.deBreakdown.drops and #opp.deBreakdown.drops > 0 then
        local dropParts = {}
        for _, d in ipairs(opp.deBreakdown.drops) do
            local pct = math.floor(d.prob * 100 + 0.5)
            local extra = d.conversionNote and (" [" .. d.conversionNote .. "]") or ""
            table.insert(dropParts, string.format(
                "%d%% %.1fx %s (%s ea%s)",
                pct, d.avgQty, d.name, PF.Formatter.FormatMoney(d.unitPrice), extra
            ))
        end
        table.insert(lines, "Expected Disenchant Yield: " .. table.concat(dropParts, " + "))
    end

    return table.concat(lines, "\n\n")
end

-- Generates all candidate plays from PCF_DB.prices and character's known recipes
function PF.OpportunityEngine.BuildAllCandidates(customOrderBooks)
    local settings = (Profitable_DB and Profitable_DB.settings) or {}
    local ahCut = (PF.GetEffectiveAHCutRate and PF.GetEffectiveAHCutRate()) or settings.ahCutRate or 0.05
    local maxVendorUnits = settings.maxVendorUnits or 200
    local maxDEUnits = settings.maxDEUnits or 30
    local maxShardDEUnits = settings.maxShardDEUnits or 8
    local maxAHCraftUnits = settings.maxAHCraftUnits or 20
    local maxAHGearUnits = settings.maxAHGearUnits or 3
    local deductDeposit = (settings.deductExpectedDeposit ~= false)

    local resolveAHUnit = function(id)
        local price = PF.OpportunityEngine.ResolveAHPrice(id)
        return price
    end

    local candidates = {}

    -- 1. Scan all items in PCF_DB.prices for direct VENDOR and BUY_DE plays
    if _G.PCF_DB and type(_G.PCF_DB.prices) == "table" then
        for itemId, entry in pairs(_G.PCF_DB.prices) do
            if type(itemId) == "number" and itemId > 0 and entry and entry.minBuyout and entry.minBuyout > 0 then
                local meta = PF.VendorDatabase.GetItemMetadata(itemId)
                local itemName = (meta and meta.name) or string.format("Item #%d", itemId)
                local vendorSell = PF.VendorDatabase.GetVendorSellPrice(itemId)

                -- Strategy A: Direct AH Buy -> Vendor
                if vendorSell and vendorSell > entry.minBuyout then
                    table.insert(candidates, {
                        actionType = "VENDOR",
                        itemId = itemId,
                        itemName = itemName,
                        ahCutRate = 0,
                        unitGrossRevenue = vendorSell,
                        unitNetRevenue = vendorSell,
                        unitAHCut = 0,
                        unitDepositRisk = 0,
                        maxUnits = maxVendorUnits,
                        rawReagents = {
                            { itemId = itemId, name = itemName, count = 1 },
                        },
                    })
                end

                -- Strategy B: Direct AH Buy -> Disenchant
                if PF.DisenchantDatabase.CanDisenchant(itemId) then
                    local deEval = PF.DisenchantDatabase.EvaluateDisenchant(itemId, nil, resolveAHUnit, ahCut)
                    if deEval and deEval.netValue > entry.minBuyout then
                        if not vendorSell or deEval.netValue > vendorSell then
                            local isShard = deEval.isShardOrCrystal == true
                            table.insert(candidates, {
                                actionType = "BUY_DE",
                                itemId = itemId,
                                itemName = itemName,
                                ahCutRate = ahCut,
                                unitGrossRevenue = deEval.grossValue,
                                unitNetRevenue = deEval.netValue,
                                unitAHCut = deEval.ahCut or (deEval.grossValue - deEval.netValue),
                                unitDepositRisk = 0,
                                deBreakdown = deEval,
                                maxUnits = isShard and maxShardDEUnits or maxDEUnits,
                                rawReagents = {
                                    { itemId = itemId, name = itemName, count = 1 },
                                },
                            })
                        end
                    end
                end
            end
        end
    end

    -- 2. Scan all known crafting recipes for CRAFT_VENDOR, CRAFT_AH, and CRAFT_DE plays
    local recipes = PF.RecipeScanner and PF.RecipeScanner.GetKnownRecipes() or {}
    for _, recipe in ipairs(recipes) do
        local outId = recipe.outputItemId
        if outId and outId > 0 and type(recipe.reagents) == "table" and #recipe.reagents > 0 then
            local avgMade = (recipe.avgMade and recipe.avgMade > 0) and recipe.avgMade or 1
            local meta = PF.VendorDatabase.GetItemMetadata(outId, recipe.outputLink)
            local itemName = recipe.name or (meta and meta.name) or string.format("Item #%d", outId)
            local isEquippableGear = meta and (meta.classID == 2 or meta.classID == 4) and (meta.invType and meta.invType ~= "")

            -- Strategy C: Craft and Vendor
            local vendorSell = PF.VendorDatabase.GetVendorSellPrice(outId, recipe.outputLink)
            local craftVendorRev = vendorSell and math.floor(vendorSell * avgMade) or 0

            -- Strategy D: Craft and AH
            local ahUnitPrice = PF.OpportunityEngine.ResolveAHPrice(outId, recipe.outputLink)
            local craftAHGross = ahUnitPrice and math.floor(ahUnitPrice * avgMade) or 0
            local craftAHCut = ahUnitPrice and math.ceil(craftAHGross * ahCut) or 0
            local craftDepositRisk = (isEquippableGear and deductDeposit and craftVendorRev > 0)
                and math.floor(craftVendorRev * 0.15)
                or 0
            local craftAHNet = math.max(0, craftAHGross - craftAHCut - craftDepositRisk)

            -- Strategy E: Craft and DE
            local deEval = nil
            local craftDEGross = 0
            local craftDENet = 0
            local craftDECut = 0
            if PF.DisenchantDatabase.CanDisenchant(outId, recipe.outputLink) then
                deEval = PF.DisenchantDatabase.EvaluateDisenchant(outId, recipe.outputLink, resolveAHUnit, ahCut)
                if deEval then
                    craftDEGross = math.floor(deEval.grossValue * avgMade)
                    craftDENet = math.floor(deEval.netValue * avgMade)
                    craftDECut = math.max(0, craftDEGross - craftDENet)
                end
            end

            if craftVendorRev > 0 then
                table.insert(candidates, {
                    actionType = "CRAFT_VENDOR",
                    itemId = outId,
                    itemName = itemName,
                    itemLink = recipe.outputLink,
                    recipe = recipe,
                    avgMade = avgMade,
                    ahCutRate = 0,
                    unitGrossRevenue = craftVendorRev,
                    unitNetRevenue = craftVendorRev,
                    unitAHCut = 0,
                    unitDepositRisk = 0,
                    maxUnits = maxVendorUnits,
                    rawReagents = recipe.reagents,
                })
            end

            if craftAHNet > 0 then
                table.insert(candidates, {
                    actionType = "CRAFT_AH",
                    itemId = outId,
                    itemName = itemName,
                    itemLink = recipe.outputLink,
                    recipe = recipe,
                    avgMade = avgMade,
                    ahCutRate = ahCut,
                    unitGrossRevenue = craftAHGross,
                    unitNetRevenue = craftAHNet,
                    unitAHCut = craftAHCut,
                    unitDepositRisk = craftDepositRisk,
                    maxUnits = isEquippableGear and maxAHGearUnits or maxAHCraftUnits,
                    rawReagents = recipe.reagents,
                })
            end

            if craftDENet > 0 then
                local isShard = deEval and deEval.isShardOrCrystal == true
                table.insert(candidates, {
                    actionType = "CRAFT_DE",
                    itemId = outId,
                    itemName = itemName,
                    itemLink = recipe.outputLink,
                    recipe = recipe,
                    avgMade = avgMade,
                    deBreakdown = deEval,
                    ahCutRate = ahCut,
                    unitGrossRevenue = craftDEGross,
                    unitNetRevenue = craftDENet,
                    unitAHCut = craftDECut,
                    unitDepositRisk = 0,
                    maxUnits = isShard and maxShardDEUnits or maxDEUnits,
                    rawReagents = recipe.reagents,
                })
            end
        end
    end

    return candidates
end

-- Evaluates, aggregates by end-result market (so multiple items that DE into the same material
-- are rolled into a single play per DE material), and computes Honorable Mentions (Top Craft & Top Vendor).
function PF.OpportunityEngine.FindTopOpportunities(budgetOverride, customOrderBooks, limitOverride)
    local budget = (type(budgetOverride) == "number" and budgetOverride >= 0)
        and budgetOverride
        or PF.Formatter.GetPlayerGold()
    local topLimit = limitOverride or ((Profitable_DB and Profitable_DB.settings and Profitable_DB.settings.topCount) or 5)

    local candidates = PF.OpportunityEngine.BuildAllCandidates(customOrderBooks)

    -- 1. Group BUY_DE candidates by their primary target DE material so items that DE
    -- into the same material (e.g. Large Glimmering Shard) aggregate into a single play!
    local buyDEGroups = {}
    local otherCandidates = {}

    for _, cand in ipairs(candidates) do
        if cand.actionType == "BUY_DE" and cand.deBreakdown and cand.deBreakdown.primaryMat then
            local matKey = ComputeEndResultKey(cand)
            buyDEGroups[matKey] = buyDEGroups[matKey] or {}
            table.insert(buyDEGroups[matKey], cand)
        else
            table.insert(otherCandidates, cand)
        end
    end

    local allEvaluated = {}

    -- Evaluate each aggregated BUY_DE material group
    for _, group in pairs(buyDEGroups) do
        local aggOpp = PF.OpportunityEngine.CalculateAggregatedBuyDEOpportunity(group, budget, customOrderBooks)
        if aggOpp and aggOpp.totalProfit > 0 then
            table.insert(allEvaluated, aggOpp)
        end
    end

    -- Evaluate all Craft & Vendor plays (keeping best exit strategy per crafted/vendored itemId)
    local bestByCraftOrVendorItem = {}
    for _, cand in ipairs(otherCandidates) do
        local opp = PF.OpportunityEngine.CalculateSteppedOpportunity(cand, budget, customOrderBooks)
        if opp and opp.totalProfit > 0 then
            local existing = bestByCraftOrVendorItem[opp.itemId]
            if not existing or opp.totalProfit > existing.totalProfit then
                bestByCraftOrVendorItem[opp.itemId] = opp
            end
        end
    end
    for _, opp in pairs(bestByCraftOrVendorItem) do
        table.insert(allEvaluated, opp)
    end

    -- Sort all evaluated plays by Total Net Profit descending
    table.sort(allEvaluated, function(a, b)
        if a.totalProfit ~= b.totalProfit then
            return a.totalProfit > b.totalProfit
        end
        if a.roiPercent ~= b.roiPercent then
            return a.roiPercent > b.roiPercent
        end
        return a.itemId < b.itemId
    end)

    -- 2. Select the True Top 5 with strict End-Result deduplication
    -- (At most ONE play per target DE material / endResultKey in the Top 5)
    local results = {}
    local usedEndResultKeys = {}
    local usedPlayIds = {}

    for _, opp in ipairs(allEvaluated) do
        local key = opp.endResultKey or opp.id
        if not usedEndResultKeys[key] and #results < topLimit then
            usedEndResultKeys[key] = true
            usedPlayIds[opp.id] = true
            opp.rank = #results + 1
            opp.summaryLine = PF.OpportunityEngine.FormatOpportunityLine(opp.rank, opp)
            opp.explanation = PF.OpportunityEngine.BuildDetailedExplanation(opp)
            table.insert(results, opp)
        end
    end

    -- 3. Build "Honorable Mentions" section:
    -- Slot 1: Top Crafting play (not already in Top 5, or best craft play overall)
    -- Slot 2: Top Vendor play (VENDOR or CRAFT_VENDOR not already in Top 5)
    local honorableMentions = {}
    local bestCraftHM = nil
    local bestVendorHM = nil

    for _, opp in ipairs(allEvaluated) do
        local isCraft = (opp.actionType == "CRAFT_AH" or opp.actionType == "CRAFT_VENDOR" or opp.actionType == "CRAFT_DE")
        local isVendor = (opp.actionType == "VENDOR" or opp.actionType == "CRAFT_VENDOR")

        if isCraft and not usedPlayIds[opp.id] and not bestCraftHM then
            bestCraftHM = opp
        end
        if isVendor and not usedPlayIds[opp.id] and (not bestCraftHM or opp.id ~= bestCraftHM.id) and not bestVendorHM then
            bestVendorHM = opp
        end
    end

    if bestCraftHM then
        bestCraftHM.hmCategory = "Top Craft"
        bestCraftHM.summaryLine = PF.OpportunityEngine.FormatOpportunityLine(nil, bestCraftHM, "|cff00ccff[Craft]|r")
        bestCraftHM.explanation = PF.OpportunityEngine.BuildDetailedExplanation(bestCraftHM)
        table.insert(honorableMentions, bestCraftHM)
    end
    if bestVendorHM then
        bestVendorHM.hmCategory = "Top Vendor"
        bestVendorHM.summaryLine = PF.OpportunityEngine.FormatOpportunityLine(nil, bestVendorHM, "|cffffd100[Vendor]|r")
        bestVendorHM.explanation = PF.OpportunityEngine.BuildDetailedExplanation(bestVendorHM)
        table.insert(honorableMentions, bestVendorHM)
    end

    return results, allEvaluated, honorableMentions
end
