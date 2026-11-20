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
    _G.PCF.Scanner.SniffItemSearchResults = function(itemKey)
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
