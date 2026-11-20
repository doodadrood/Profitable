-- Restores standalone PriceCheckerForever globals or marks embedded PCF active
local PF = _G.PF or {}
_G.PF = PF
_G.Profitable = PF

if PF._standalonePCFActive and type(PF._savedStandalonePCF) == "table" then
    _G.PCF = PF._savedStandalonePCF
    _G.GPC = PF._savedStandalonePCF
    if PF._savedStandalonePCFAPI ~= nil then
        _G.PCF_API = PF._savedStandalonePCFAPI
    end
    if type(PF._savedStandalonePCFDB) == "table" then
        _G.PCF_DB = PF._savedStandalonePCFDB
        _G.GPC_DB = PF._savedStandalonePCFDB
    end
    PF._embeddedPCFActive = false
elseif _G.PCF_API then
    PF._embeddedPCFActive = true
else
    PF._embeddedPCFActive = false
end

PF._savedStandalonePCF = nil
PF._savedStandalonePCFDB = nil
PF._savedStandalonePCFAPI = nil

-- Ensure PCF.Scanner.SniffItemSearchResults (both embedded and standalone) treats
-- C_AuctionHouse.GetItemSearchResultInfo's buyoutAmount as the per-item buyout price
-- rather than dividing by the collapsed auction count (row.quantity).
local function GetActiveSellFrameItem()
    local ahFrame = _G.AuctionHouseFrame
    if not ahFrame then
        return nil, nil
    end

    local sellFrames = {
        ahFrame.CommoditiesSellFrame,
        ahFrame.ItemSellFrame,
    }

    for _, sellFrame in ipairs(sellFrames) do
        if sellFrame and (not sellFrame.IsShown or sellFrame:IsShown()) then
            local itemKey = sellFrame.GetItemKey and sellFrame:GetItemKey()
            local itemLoc = (sellFrame.GetItem and sellFrame:GetItem()) or sellFrame.itemLocation
            local itemId = (type(itemKey) == "table" and itemKey.itemID) or nil

            if not itemId and itemLoc then
                if _G.C_Item and _G.C_Item.GetItemID then
                    local okId, resolvedId = pcall(_G.C_Item.GetItemID, itemLoc)
                    if okId and resolvedId then
                        itemId = resolvedId
                    end
                end
                if not itemKey and _G.C_AuctionHouse and _G.C_AuctionHouse.GetItemKeyFromItem then
                    local okKey, resolvedKey = pcall(_G.C_AuctionHouse.GetItemKeyFromItem, itemLoc)
                    if okKey and type(resolvedKey) == "table" then
                        itemKey = resolvedKey
                        itemId = itemId or resolvedKey.itemID
                    end
                end
            end

            if itemId and itemId > 0 then
                return itemId, itemKey
            end
        end
    end

    return nil, nil
end

if _G.PCF and type(_G.PCF.Scanner) == "table" then
    if type(_G.PCF.Scanner.SniffCommoditySearchResults) == "function" then
        local origSniffCommodity = _G.PCF.Scanner.SniffCommoditySearchResults
        _G.PCF.Scanner.SniffCommoditySearchResults = function(itemId)
            if _G.PF and _G.PF.AHVerifier and _G.PF.AHVerifier.IsRunning and _G.PF.AHVerifier.IsRunning() then
                return 0
            end
            return origSniffCommodity(itemId)
        end
    end

    _G.PCF.Scanner.SniffItemSearchResults = function(itemKey)
        if _G.PF and _G.PF.AHVerifier and _G.PF.AHVerifier.IsRunning and _G.PF.AHVerifier.IsRunning() then
            return 0
        end
        if not (_G.PCF_DB and _G.PCF_DB.settings and _G.PCF_DB.settings.enabled ~= false and _G.PCF_DB.settings.passiveSniffing ~= false) then
            return 0
        end
        local scanBtn = _G.PCF.Scanner.scanButton
        if scanBtn and type(scanBtn.GetText) == "function" and scanBtn:GetText() == "Stop Scan" then
            return 0
        end
        if not _G.C_AuctionHouse or not _G.C_AuctionHouse.GetNumItemSearchResults or not _G.C_AuctionHouse.GetItemSearchResultInfo then
            return 0
        end

        if not itemKey then
            local activeId, activeKey = GetActiveSellFrameItem()
            itemKey = activeKey or activeId
        end

        local itemId = (type(itemKey) == "table" and itemKey.itemID) or tonumber(itemKey)
        if not itemId or itemId <= 0 then
            return 0
        end

        local queryKey = type(itemKey) == "table" and itemKey or { itemID = itemId, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 }
        local okNum, numResults = pcall(_G.C_AuctionHouse.GetNumItemSearchResults, queryKey)
        if not okNum or not numResults or numResults <= 0 then
            return 0
        end

        local now = (_G.time and _G.time()) or 0
        local limit = math.min(numResults, 50)
        local minUnitBuyout = nil
        local minUnitBid = nil
        local totalQty = 0

        for i = 1, limit do
            local okInfo, result = pcall(_G.C_AuctionHouse.GetItemSearchResultInfo, queryKey, i)
            if okInfo and type(result) == "table" then
                local unitBuyout = (result.buyoutAmount and result.buyoutAmount > 0) and math.floor(result.buyoutAmount) or nil
                if unitBuyout and unitBuyout > 0 then
                    local unitBid = (result.minBid and result.minBid > 0 and math.floor(result.minBid))
                        or (result.bidAmount and result.bidAmount > 0 and math.floor(result.bidAmount))
                        or unitBuyout
                    local quantity = (result.quantity and result.quantity > 0) and math.floor(result.quantity) or 1
                    totalQty = totalQty + quantity
                    if not minUnitBuyout or unitBuyout < minUnitBuyout then
                        minUnitBuyout = unitBuyout
                    end
                    if not minUnitBid or unitBid < minUnitBid then
                        minUnitBid = unitBid
                    end
                end
            end
        end

        if not minUnitBuyout or minUnitBuyout <= 0 or totalQty <= 0 then
            return 0
        end

        _G.PCF_DB.prices = _G.PCF_DB.prices or {}
        local existing = _G.PCF_DB.prices[itemId]
        if existing then
            existing.minBuyout = minUnitBuyout
            existing.minBid = minUnitBid or minUnitBuyout
            existing.lastUpdated = now
            existing.count = totalQty
            existing.source = "PCF Sniff"
        else
            _G.PCF_DB.prices[itemId] = {
                minBuyout = minUnitBuyout,
                minBid = minUnitBid or minUnitBuyout,
                lastUpdated = now,
                count = totalQty,
                source = "PCF Sniff",
            }
        end

        if _G.PCF.MeshSync and _G.PCF.MeshSync.MarkDirty then
            _G.PCF.MeshSync.MarkDirty(itemId)
        end
        if _G.PCF.Tooltip and _G.PCF.Tooltip.RefreshVisibleTooltip then
            _G.PCF.Tooltip.RefreshVisibleTooltip()
        end

        return 1
    end
end

-- Ensure PCF.Tooltip (both embedded and standalone) never writes custom keys onto Blizzard's
-- GameTooltip (_pcfHooked / _pcfStackCount) and never calls tooltip:Show() inside modern
-- TooltipDataProcessor post-calls or combat (both of which taint GameTooltip / ContainerFrame).
if _G.PCF and type(_G.PCF.Tooltip) == "table" then
    local hookedTooltips = setmetatable({}, { __mode = "k" })
    local tooltipStackCounts = setmetatable({}, { __mode = "k" })

    local function IsSecretVal(val)
        if val == nil then return false end
        if _G.PF and _G.PF.IsSecret then
            return _G.PF.IsSecret(val)
        end
        if _G.issecretvalue then
            local ok, isSec = pcall(_G.issecretvalue, val)
            if ok and isSec then return true end
        end
        if _G.canaccessvalue then
            local ok, canAccess = pcall(_G.canaccessvalue, val)
            if ok and not canAccess then return true end
        end
        return false
    end

    local function IsForbiddenTooltip(tooltip)
        if not tooltip then return true end
        if tooltip.IsForbidden then
            local ok, forbidden = pcall(tooltip.IsForbidden, tooltip)
            if ok and forbidden then return true end
        end
        return false
    end

    local function IsSupportedItemTooltip(tooltip)
        if not tooltip or IsForbiddenTooltip(tooltip) then return false end
        return tooltip == _G.GameTooltip
            or tooltip == _G.ItemRefTooltip
            or tooltip == _G.ShoppingTooltip1
            or tooltip == _G.ShoppingTooltip2
    end

    local function SafeFind(str, pattern)
        if str == nil or IsSecretVal(str) then return nil end
        local ok, res = pcall(string.find, str, pattern)
        return ok and res or nil
    end

    local function SafeMatch(str, pattern)
        if str == nil or IsSecretVal(str) then return nil end
        local ok, res = pcall(string.match, str, pattern)
        return ok and res or nil
    end

    local function QueryContainerStackCount(bag, slot, expectedItemId)
        if type(bag) ~= "number" or type(slot) ~= "number" then return nil end
        if _G.C_Container and _G.C_Container.GetContainerItemInfo then
            local ok, info = pcall(_G.C_Container.GetContainerItemInfo, bag, slot)
            if ok and type(info) == "table" and info.stackCount and info.stackCount > 1 then
                if not expectedItemId or not info.itemID or info.itemID == expectedItemId then
                    return math.floor(info.stackCount)
                end
            end
        end
        if _G.GetContainerItemInfo then
            local ok, _, itemCount, _, _, _, _, link = pcall(_G.GetContainerItemInfo, bag, slot)
            if ok and type(itemCount) == "number" and itemCount > 1 then
                local matchStr = SafeMatch(link, "item:(%d+)")
                local slotItemId = matchStr and tonumber(matchStr) or nil
                if not expectedItemId or not slotItemId or slotItemId == expectedItemId then
                    return math.floor(itemCount)
                end
            end
        end
        return nil
    end

    local function ExtractItemFromTooltip(tooltip, tooltipData)
        local itemLink, itemId = nil, nil
        if tooltip and tooltip.GetItem then
            local ok, _, link = pcall(tooltip.GetItem, tooltip)
            if ok and link and not IsSecretVal(link) then
                itemLink = link
            end
        end
        if not itemLink and tooltipData and tooltipData.hyperlink and not IsSecretVal(tooltipData.hyperlink) then
            itemLink = tooltipData.hyperlink
        end
        if itemLink then
            local matchStr = SafeMatch(itemLink, "item:(%d+)")
            if matchStr then itemId = tonumber(matchStr) end
        end
        if not itemId and tooltipData and tooltipData.id and not IsSecretVal(tooltipData.id) then
            itemId = tonumber(tooltipData.id)
        end
        return itemLink, itemId
    end

    local function ExtractStackCount(tooltip, itemId)
        if not tooltip or IsForbiddenTooltip(tooltip) then return 1 end
        local trackedStack = tooltipStackCounts[tooltip] or rawget(tooltip, "_pcfStackCount")
        if type(trackedStack) == "number" and trackedStack > 1 then
            return math.floor(trackedStack)
        end

        local ok, owner = pcall(function()
            return tooltip.GetOwner and tooltip:GetOwner()
        end)
        if not ok or not owner then return 1 end

        local isActionOrProtected = (owner.action ~= nil)
            or (owner.buttonType ~= nil)
            or (owner.IsProtected and owner:IsProtected())
        if isActionOrProtected then
            return 1
        end

        if type(owner.count) == "number" and owner.count > 1 then
            return math.floor(owner.count)
        end
        if type(owner.stackCount) == "number" and owner.stackCount > 1 then
            return math.floor(owner.stackCount)
        end

        local countRegion = owner.Count or (owner.GetName and owner:GetName() and _G[owner:GetName() .. "Count"])
        if countRegion and countRegion.GetText and (not countRegion.IsShown or countRegion:IsShown()) then
            local okTxt, text = pcall(countRegion.GetText, countRegion)
            if okTxt and text ~= nil and not IsSecretVal(text) then
                local parsed = tonumber(SafeMatch(text, "^%s*(%d+)%s*$") or "")
                if parsed and parsed > 1 then
                    return math.floor(parsed)
                end
            end
        end

        local bag = (owner.GetBagID and owner:GetBagID())
            or owner.bagID
            or (owner.GetParent and owner:GetParent() and owner:GetParent().GetID and owner:GetParent():GetID())
        local slot = (owner.GetSlotIndex and owner:GetSlotIndex())
            or owner.slotID
            or (owner.GetID and owner:GetID())
        local containerCount = QueryContainerStackCount(bag, slot, itemId)
        if containerCount and containerCount > 1 then
            return containerCount
        end
        return 1
    end

    local function UpdateOrAddAHPriceLine(tooltip, lineText, allowShow)
        if not tooltip or IsForbiddenTooltip(tooltip) then return end
        local tooltipName = tooltip.GetName and tooltip:GetName()
        local numLines = tooltip.NumLines and tooltip:NumLines() or 0
        if tooltipName and numLines > 0 then
            for i = 1, numLines do
                local leftFontString = _G[tooltipName .. "TextLeft" .. i]
                if leftFontString and leftFontString.GetText then
                    local ok, existingText = pcall(leftFontString.GetText, leftFontString)
                    if ok and SafeFind(existingText, "^AH%s+Price:") then
                        if leftFontString.SetText then
                            pcall(leftFontString.SetText, leftFontString, lineText)
                        end
                        if allowShow and tooltip.Show then
                            pcall(tooltip.Show, tooltip)
                        end
                        return
                    end
                end
            end
        end
        if tooltip.AddLine then
            pcall(tooltip.AddLine, tooltip, lineText, 1, 1, 1)
        end
        if allowShow and tooltip.Show then
            pcall(tooltip.Show, tooltip)
        end
    end

    _G.PCF.Tooltip.OnTooltipSetItem = function(tooltip, tooltipData, allowShow)
        if not tooltip or IsForbiddenTooltip(tooltip) then return end
        local shouldShow = (allowShow == true)

        pcall(function()
            local itemLink, itemId = ExtractItemFromTooltip(tooltip, tooltipData)
            if not itemLink and not itemId then return end

            local ahPrice = _G.PCF.ProviderRegistry and _G.PCF.ProviderRegistry.ResolveAHPrice
                and _G.PCF.ProviderRegistry.ResolveAHPrice(itemLink, itemId)

            if _G.PCF_DB and _G.PCF_DB.settings and _G.PCF_DB.settings.showTooltip == false then
                return
            end

            local lineText
            if ahPrice and ahPrice > 0 then
                local stackCount = ExtractStackCount(tooltip, itemId)
                local unitFormatted = _G.PCF.Formatter.FormatTooltipMoney(ahPrice)
                if stackCount and stackCount > 1 then
                    local stackFormatted = _G.PCF.Formatter.FormatTooltipMoney(ahPrice * stackCount)
                    lineText = string.format("AH  Price: %s (%s)", stackFormatted, unitFormatted)
                else
                    lineText = string.format("AH  Price: %s", unitFormatted)
                end
            else
                lineText = "AH  Price: ??"
            end

            UpdateOrAddAHPriceLine(tooltip, lineText, shouldShow)
        end)
    end

    _G.PCF.Tooltip.RefreshVisibleTooltip = function()
        if _G.InCombatLockdown and _G.InCombatLockdown() then return end
        if _G.GameTooltip and not IsForbiddenTooltip(_G.GameTooltip) and (not _G.GameTooltip.IsShown or _G.GameTooltip:IsShown()) then
            _G.PCF.Tooltip.OnTooltipSetItem(_G.GameTooltip, nil, false)
        end
    end

    local function HookTooltipSafe(tooltip, hasTooltipDataProcessor)
        if not tooltip or hookedTooltips[tooltip] or IsForbiddenTooltip(tooltip) then return end
        hookedTooltips[tooltip] = true

        if tooltip.HookScript then
            if not hasTooltipDataProcessor then
                pcall(function()
                    tooltip:HookScript("OnTooltipSetItem", function(self)
                        _G.PCF.Tooltip.OnTooltipSetItem(self, nil, true)
                    end)
                end)
            end
            pcall(function()
                tooltip:HookScript("OnTooltipCleared", function(self)
                    tooltipStackCounts[self] = nil
                end)
            end)
            pcall(function()
                tooltip:HookScript("OnHide", function(self)
                    tooltipStackCounts[self] = nil
                end)
            end)
        end

        if _G.hooksecurefunc and type(tooltip.SetBagItem) == "function" then
            pcall(_G.hooksecurefunc, tooltip, "SetBagItem", function(self, bag, slot)
                tooltipStackCounts[self] = QueryContainerStackCount(bag, slot, nil)
            end)
        end
    end

    _G.PCF.Tooltip.Init = function()
        local hasTooltipDataProcessor = (_G.TooltipDataProcessor
            and _G.TooltipDataProcessor.AddTooltipPostCall
            and _G.Enum
            and _G.Enum.TooltipDataType
            and _G.Enum.TooltipDataType.Item) ~= nil

        HookTooltipSafe(_G.GameTooltip, hasTooltipDataProcessor)
        HookTooltipSafe(_G.ItemRefTooltip, hasTooltipDataProcessor)
        HookTooltipSafe(_G.ShoppingTooltip1, hasTooltipDataProcessor)
        HookTooltipSafe(_G.ShoppingTooltip2, hasTooltipDataProcessor)

        if hasTooltipDataProcessor and not _G.PCF.Tooltip._processorHooked then
            _G.TooltipDataProcessor.AddTooltipPostCall(_G.Enum.TooltipDataType.Item, function(tooltip, data)
                if IsSupportedItemTooltip(tooltip) then
                    _G.PCF.Tooltip.OnTooltipSetItem(tooltip, data, false)
                end
            end)
            _G.PCF.Tooltip._processorHooked = true
        end
    end
end
