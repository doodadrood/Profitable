local _, PF = ...
PF = type(PF) == "table" and PF or _G.PF or {}
_G.PF = PF

PF.DetailWindow = {}

local detailFrame = nil
local currentOpportunity = nil
local shoppingRows = {}
local MAX_SHOPPING_ROWS = 8

local function SetBackdropSafe(frame, bgR, bgG, bgB, bgA)
    if not frame then return end
    if frame.CreateTexture and not frame._pfBg then
        local bg = frame:CreateTexture(nil, "BACKGROUND")
        if bg.SetAllPoints then bg:SetAllPoints(frame) end
        if bg.SetColorTexture then
            bg:SetColorTexture(bgR or 0.06, bgG or 0.07, bgB or 0.09, bgA or 0.94)
        elseif bg.SetTexture then
            bg:SetTexture(bgR or 0.06, bgG or 0.07, bgB or 0.09, bgA or 0.94)
        end
        frame._pfBg = bg
    end
end

local function HandleItemLinkClick(itemId, itemName, itemLink, desiredQuantity)
    if _G.IsModifiedClick and _G.IsModifiedClick("CHATLINK") then
        if _G.ChatEdit_InsertLink and itemLink then
            local inserted = _G.ChatEdit_InsertLink(itemLink)
            if inserted then return end
        end
        if _G.BrowseName and _G.BrowseName.IsVisible and _G.BrowseName:IsVisible() then
            local cleanName = itemName or (itemLink and itemLink:match("%[(.-)%]")) or ""
            _G.BrowseName:SetText(cleanName)
            return
        end
        if _G.AuctionHouseFrame and _G.AuctionHouseFrame.SearchBar and _G.AuctionHouseFrame.SearchBar.SearchBox then
            local cleanName = itemName or (itemLink and itemLink:match("%[(.-)%]")) or ""
            _G.AuctionHouseFrame.SearchBar.SearchBox:SetText(cleanName)
            return
        end
    end

    if PF.AHVerifier and PF.AHVerifier.IsAuctionHouseOpen and PF.AHVerifier.IsAuctionHouseOpen() then
        PF.AHVerifier.SearchItemOnAH(itemId, itemName, itemLink, desiredQuantity)
    elseif _G.SetItemRef and itemLink then
        pcall(_G.SetItemRef, "item:" .. tostring(itemId), itemLink, "LeftButton")
    end
end

local function ShowItemTooltip(owner, itemId, itemLink)
    if not _G.GameTooltip then return end
    _G.GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    if itemLink and _G.GameTooltip.SetHyperlink then
        pcall(_G.GameTooltip.SetHyperlink, _G.GameTooltip, itemLink)
    elseif itemId and _G.GameTooltip.SetHyperlink then
        pcall(_G.GameTooltip.SetHyperlink, _G.GameTooltip, "item:" .. tostring(itemId))
    end
    _G.GameTooltip:AddLine(" ")
    _G.GameTooltip:AddLine("|cff00ff88Click:|r Search on AH / View Item", 0.8, 0.8, 0.8)
    _G.GameTooltip:AddLine("|cff00ff88Shift-Click:|r Insert into AH Search / Chat", 0.8, 0.8, 0.8)
    _G.GameTooltip:Show()
end

local function CreateShoppingRow(parent, index)
    local row = CreateFrame("Frame", "PF_DetailShoppingRow" .. index, parent)
    if row.SetSize then row:SetSize(416, 36) end
    if row.SetPoint then
        row:SetPoint("TOPLEFT", parent, "TOPLEFT", 12, -230 - ((index - 1) * 40))
    end
    SetBackdropSafe(row, 0.12, 0.13, 0.16, 0.90)

    -- Clickable Item Link Button
    local itemBtn = CreateFrame("Button", "PF_DetailShoppingItemBtn" .. index, row)
    if itemBtn.SetSize then itemBtn:SetSize(220, 18) end
    if itemBtn.SetPoint then itemBtn:SetPoint("TOPLEFT", row, "TOPLEFT", 6, -3) end

    local itemText = itemBtn.CreateFontString and itemBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    if itemText then
        if itemText.SetPoint then itemText:SetPoint("LEFT", itemBtn, "LEFT", 0, 0) end
        if itemText.SetJustifyH then itemText:SetJustifyH("LEFT") end
    end

    local statusText = row.CreateFontString and row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    if statusText then
        if statusText.SetPoint then statusText:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 6, 4) end
        if statusText.SetJustifyH then statusText:SetJustifyH("LEFT") end
    end

    local searchBtn = CreateFrame("Button", "PF_DetailShoppingSearchBtn" .. index, row, "UIPanelButtonTemplate")
    if searchBtn.SetSize then searchBtn:SetSize(74, 22) end
    if searchBtn.SetPoint then searchBtn:SetPoint("RIGHT", row, "RIGHT", -80, 0) end
    if searchBtn.SetText then searchBtn:SetText("Search AH") end

    local buyBtn = CreateFrame("Button", "PF_DetailShoppingBuyBtn" .. index, row, "UIPanelButtonTemplate")
    if buyBtn.SetSize then buyBtn:SetSize(70, 22) end
    if buyBtn.SetPoint then buyBtn:SetPoint("RIGHT", row, "RIGHT", -6, 0) end
    if buyBtn.SetText then buyBtn:SetText("Buy Next") end

    itemBtn:SetScript("OnClick", function()
        if row._itemData then
            local rem = math.max(1, row._itemData.remainingToBuy or row._itemData.totalQuantity or 1)
            HandleItemLinkClick(row._itemData.itemId, row._itemData.name, row._itemData.link, rem)
        end
    end)
    itemBtn:SetScript("OnEnter", function(self)
        if row._itemData then
            ShowItemTooltip(self, row._itemData.itemId, row._itemData.link)
        end
    end)
    itemBtn:SetScript("OnLeave", function()
        if _G.GameTooltip then _G.GameTooltip:Hide() end
    end)

    searchBtn:SetScript("OnClick", function()
        if row._itemData then
            local rem = math.max(1, row._itemData.remainingToBuy or row._itemData.totalQuantity or 1)
            PF.AHVerifier.SearchItemOnAH(row._itemData.itemId, row._itemData.name, row._itemData.link, rem)
        end
    end)

    buyBtn:SetScript("OnClick", function()
        if row._itemData then
            local rem = math.max(1, row._itemData.remainingToBuy or row._itemData.totalQuantity or 1)
            PF.AHVerifier.BuyNextCheapListing(row._itemData.itemId, row._itemData.name, row._itemData.maxUnitPrice, rem)
        end
    end)

    row.itemBtn = itemBtn
    row.itemText = itemText
    row.statusText = statusText
    row.searchBtn = searchBtn
    row.buyBtn = buyBtn
    return row
end

local function EnsureDetailFrame()
    if detailFrame then return detailFrame end

    detailFrame = CreateFrame("Frame", "PF_OpportunityDetailWindow", _G.UIParent)
    if detailFrame.SetSize then detailFrame:SetSize(440, 520) end
    if detailFrame.SetPoint then detailFrame:SetPoint("CENTER", _G.UIParent, "CENTER", 220, 0) end
    if detailFrame.SetFrameStrata then detailFrame:SetFrameStrata("DIALOG") end
    if detailFrame.SetMovable then detailFrame:SetMovable(true) end
    if detailFrame.EnableMouse then detailFrame:EnableMouse(true) end
    if detailFrame.RegisterForDrag then detailFrame:RegisterForDrag("LeftButton") end
    detailFrame:SetScript("OnDragStart", function(self)
        if self.StartMoving then self:StartMoving() end
    end)
    detailFrame:SetScript("OnDragStop", function(self)
        if self.StopMovingOrSizing then self:StopMovingOrSizing() end
    end)

    SetBackdropSafe(detailFrame, 0.05, 0.06, 0.08, 0.96)

    -- Header Bar
    local headerText = detailFrame.CreateFontString and detailFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    if headerText then
        if headerText.SetPoint then headerText:SetPoint("TOPLEFT", detailFrame, "TOPLEFT", 14, -12) end
        if headerText.SetText then headerText:SetText("|cff00ff88Profitable|r — Opportunity Breakdown") end
    end

    local closeBtn = CreateFrame("Button", "PF_DetailCloseButton", detailFrame, "UIPanelCloseButton")
    if closeBtn.SetPoint then closeBtn:SetPoint("TOPRIGHT", detailFrame, "TOPRIGHT", -4, -4) end
    closeBtn:SetScript("OnClick", function()
        detailFrame:Hide()
    end)

    -- Target Item Clickable Title Button
    local titleBtn = CreateFrame("Button", "PF_DetailTargetItemButton", detailFrame)
    if titleBtn.SetSize then titleBtn:SetSize(410, 24) end
    if titleBtn.SetPoint then titleBtn:SetPoint("TOPLEFT", detailFrame, "TOPLEFT", 14, -38) end

    local titleText = titleBtn.CreateFontString and titleBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    if titleText then
        if titleText.SetPoint then titleText:SetPoint("LEFT", titleBtn, "LEFT", 0, 0) end
    end
    titleBtn:SetScript("OnClick", function()
        if currentOpportunity then
            HandleItemLinkClick(currentOpportunity.itemId, currentOpportunity.itemName, currentOpportunity.itemLink)
        end
    end)
    titleBtn:SetScript("OnEnter", function(self)
        if currentOpportunity then
            ShowItemTooltip(self, currentOpportunity.itemId, currentOpportunity.itemLink)
        end
    end)
    titleBtn:SetScript("OnLeave", function()
        if _G.GameTooltip then _G.GameTooltip:Hide() end
    end)

    -- Financial Breakdown Summary Box
    local metricsText = detailFrame.CreateFontString and detailFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    if metricsText then
        if metricsText.SetPoint then metricsText:SetPoint("TOPLEFT", detailFrame, "TOPLEFT", 14, -68) end
        if metricsText.SetWidth then metricsText:SetWidth(412) end
        if metricsText.SetJustifyH then metricsText:SetJustifyH("LEFT") end
    end

    -- Explanation / Why It's Valuable Box
    local descText = detailFrame.CreateFontString and detailFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    if descText then
        if descText.SetPoint then descText:SetPoint("TOPLEFT", detailFrame, "TOPLEFT", 14, -112) end
        if descText.SetWidth then descText:SetWidth(412) end
        if descText.SetJustifyH then descText:SetJustifyH("LEFT") end
        if descText.SetJustifyV then descText:SetJustifyV("TOP") end
    end

    -- Shopping List Section Header
    local shopHeader = detailFrame.CreateFontString and detailFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    if shopHeader then
        if shopHeader.SetPoint then shopHeader:SetPoint("TOPLEFT", detailFrame, "TOPLEFT", 14, -210) end
        if shopHeader.SetText then
            shopHeader:SetText("|cffffd100Shopping List & Live Inventory / Mailbox Tracker:|r")
        end
    end

    for i = 1, MAX_SHOPPING_ROWS do
        shoppingRows[i] = CreateShoppingRow(detailFrame, i)
    end

    -- Footer Action Buttons
    local recipeBtn = CreateFrame("Button", "PF_DetailOpenRecipeButton", detailFrame, "UIPanelButtonTemplate")
    if recipeBtn.SetSize then recipeBtn:SetSize(140, 24) end
    if recipeBtn.SetPoint then recipeBtn:SetPoint("BOTTOMLEFT", detailFrame, "BOTTOMLEFT", 14, 14) end
    if recipeBtn.SetText then recipeBtn:SetText("Open Recipe") end
    recipeBtn:SetScript("OnClick", function()
        if currentOpportunity and currentOpportunity.recipe then
            PF.RecipeScanner.CraftRecipe(currentOpportunity.recipe, currentOpportunity.quantity)
        end
    end)

    local searchTargetBtn = CreateFrame("Button", "PF_DetailSearchTargetButton", detailFrame, "UIPanelButtonTemplate")
    if searchTargetBtn.SetSize then searchTargetBtn:SetSize(130, 24) end
    if searchTargetBtn.SetPoint then searchTargetBtn:SetPoint("BOTTOM", detailFrame, "BOTTOM", 8, 14) end
    if searchTargetBtn.SetText then searchTargetBtn:SetText("Search Target AH") end
    searchTargetBtn:SetScript("OnClick", function()
        if currentOpportunity then
            PF.AHVerifier.SearchItemOnAH(currentOpportunity.itemId, currentOpportunity.itemName, currentOpportunity.itemLink)
        end
    end)

    local refreshBtn = CreateFrame("Button", "PF_DetailRefreshButton", detailFrame, "UIPanelButtonTemplate")
    if refreshBtn.SetSize then refreshBtn:SetSize(110, 24) end
    if refreshBtn.SetPoint then refreshBtn:SetPoint("BOTTOMRIGHT", detailFrame, "BOTTOMRIGHT", -14, 14) end
    if refreshBtn.SetText then refreshBtn:SetText("Refresh Bags") end
    refreshBtn:SetScript("OnClick", function()
        PF.DetailWindow.RefreshIfShown()
    end)

    -- Live Inventory / Mailbox Event Listener so players see bag counts update as they loot mail
    if detailFrame.RegisterEvent then
        pcall(detailFrame.RegisterEvent, detailFrame, "BAG_UPDATE")
        pcall(detailFrame.RegisterEvent, detailFrame, "BAG_UPDATE_DELAYED")
        pcall(detailFrame.RegisterEvent, detailFrame, "MAIL_INBOX_UPDATE")
        pcall(detailFrame.RegisterEvent, detailFrame, "PLAYER_MONEY")
        detailFrame:SetScript("OnEvent", function()
            PF.DetailWindow.RefreshIfShown()
        end)
    end

    detailFrame.titleText = titleText
    detailFrame.metricsText = metricsText
    detailFrame.descText = descText
    detailFrame.recipeBtn = recipeBtn
    detailFrame.searchTargetBtn = searchTargetBtn
    detailFrame.refreshBtn = refreshBtn
    detailFrame.shoppingRows = shoppingRows

    detailFrame:Hide()
    PF.DetailWindow.frame = detailFrame
    return detailFrame
end

function PF.DetailWindow.ShowOpportunity(opp)
    if not opp then return end
    currentOpportunity = opp
    if Profitable_DB then
        Profitable_DB.activePlay = opp
    end

    local frame = EnsureDetailFrame()
    frame:Show()
    PF.DetailWindow.RefreshIfShown()
end

function PF.DetailWindow.RefreshIfShown()
    if not detailFrame or (detailFrame.IsShown and not detailFrame:IsShown()) then
        return
    end
    local opp = currentOpportunity or (Profitable_DB and Profitable_DB.activePlay)
    if not opp then return end

    local verBadge = opp.verified and "|cff00ff00[Verified AH]|r" or "|cffffcc00[Cached Scan]|r"
    if detailFrame.titleText then
        detailFrame.titleText:SetText(string.format("%s %s (x%d) %s", opp.actionLabel, opp.itemLink, opp.quantity, verBadge))
    end

    if detailFrame.metricsText then
        local costStr = PF.Formatter.FormatMoney(opp.totalCost)
        local revStr = PF.Formatter.FormatMoney(opp.totalNetRevenue)
        local cutPct = math.floor(((opp.ahCutRate or 0.05) * 100) + 0.5)
        local cutStr = (opp.totalAHCut and opp.totalAHCut > 0)
            and string.format("%s (%d%%)", PF.Formatter.FormatMoney(opp.totalAHCut), cutPct)
            or "0c (Vendor)"
        local depStr = (opp.totalDepositRisk and opp.totalDepositRisk > 0)
            and string.format("  |cffffd100Est. Deposit:|r %s", PF.Formatter.FormatMoney(opp.totalDepositRisk))
            or ""
        local profStr = PF.Formatter.FormatMoney(opp.totalProfit)
        detailFrame.metricsText:SetText(string.format(
            "|cffffd100Cost:|r %s   |cffffd100Net Rev:|r %s   |cffffd100AH Cut:|r %s%s\n|cff00ff00Total Profit:|r |cff00ff00%s|r (%d%% ROI)",
            costStr, revStr, cutStr, depStr, profStr, opp.roiPercent or 0
        ))
    end

    if detailFrame.descText then
        local explanation = opp.explanation or PF.OpportunityEngine.BuildDetailedExplanation(opp)
        detailFrame.descText:SetText(explanation)
    end

    local shopList = opp.shoppingList or {}
    for i = 1, MAX_SHOPPING_ROWS do
        local row = shoppingRows[i]
        local item = shopList[i]
        if item then
            row._itemData = item
            row:Show()

            local liveInBags = PF.Formatter.GetInventoryCount(item.itemId, false)
            local liveInBank = math.max(0, PF.Formatter.GetInventoryCount(item.itemId, true) - liveInBags)
            item.haveInBags = liveInBags
            item.haveInBank = liveInBank
            item.remainingToBuy = math.max(0, item.totalQuantity - liveInBags)

            local sourceTag = (item.source == "Vendor") and "|cff00ccff[Vendor]|r" or "|cffffaa00[AH]|r"
            if row.itemText then
                row.itemText:SetText(string.format("%s %dx %s", sourceTag, item.totalQuantity, item.link))
            end

            local invStatus
            if liveInBags >= item.totalQuantity then
                invStatus = string.format("|cff00ff00Ready in Bags: %d / %d|r", liveInBags, item.totalQuantity)
            else
                local bankNote = (liveInBank > 0) and string.format(" (+%d bank)", liveInBank) or ""
                invStatus = string.format("|cffffcc00Have: %d / %d%s — Buy %d more|r", liveInBags, item.totalQuantity, bankNote, item.remainingToBuy)
            end

            local priceInfo
            if item.source == "Vendor" then
                priceInfo = string.format("Vendor: %s ea (Total %s)", PF.Formatter.FormatMoney(item.avgUnitPrice), PF.Formatter.FormatMoney(item.totalCost))
            elseif item.minUnitPrice ~= item.maxUnitPrice then
                priceInfo = string.format("Avg %s (Max %s) | Total %s", PF.Formatter.FormatMoney(item.avgUnitPrice), PF.Formatter.FormatMoney(item.maxUnitPrice), PF.Formatter.FormatMoney(item.totalCost))
            else
                priceInfo = string.format("AH: %s ea (Total %s)", PF.Formatter.FormatMoney(item.avgUnitPrice), PF.Formatter.FormatMoney(item.totalCost))
            end

            if row.statusText then
                row.statusText:SetText(invStatus .. "  |  " .. priceInfo)
            end

            if row.searchBtn then
                if item.source == "Vendor" then
                    row.searchBtn:Hide()
                else
                    row.searchBtn:Show()
                    row.searchBtn:SetText("Open in AH")
                end
            end

            if row.buyBtn then
                local label = (PF.AHVerifier and PF.AHVerifier.GetBuyButtonLabel and PF.AHVerifier.GetBuyButtonLabel(item)) or "Buy Next"
                row.buyBtn:SetText(label)
            end
        else
            row._itemData = nil
            row:Hide()
        end
    end

    if detailFrame.recipeBtn then
        if opp.recipe then
            detailFrame.recipeBtn:Show()
            detailFrame.recipeBtn:SetText(string.format("Open %s", opp.recipe.profession or "Recipe"))
        else
            detailFrame.recipeBtn:Hide()
        end
    end
end
