local PF = _G.PF or {}
_G.PF = PF
_G.Profitable = PF

PF.DetailWindow = {}

local detailFrame = nil
local currentOpportunity = nil
local shoppingRows = {}
local scrollUpdatePending = false
local MAX_SHOPPING_ROWS = 20
local SCROLL_VIEWPORT_HEIGHT = 360
local SCROLL_STEP = 38
local CHECKMARK_ICON = "|TInterface\\RaidFrame\\ReadyCheck-Ready:14:14:0:0|t "

local function SetRowBackgroundColor(frame, bgR, bgG, bgB, bgA)
    if not frame or not frame._pfBg then return end
    if frame._pfBg.SetColorTexture then
        frame._pfBg:SetColorTexture(bgR, bgG, bgB, bgA)
    elseif frame._pfBg.SetTexture then
        frame._pfBg:SetTexture(bgR, bgG, bgB, bgA)
    end
end

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
    _G.GameTooltip:AddLine("|cff00ff88Click:|r Open in AH / View Item", 0.8, 0.8, 0.8)
    _G.GameTooltip:AddLine("|cff00ff88Shift-Click:|r Insert into AH Search / Chat", 0.8, 0.8, 0.8)
    _G.GameTooltip:Show()
end

local function ApplyScrollOffset(offset)
    if not detailFrame or not detailFrame.scrollFrame then return end
    local sf = detailFrame.scrollFrame
    local maxScroll = sf._maxScroll or 0
    local clamped = math.max(0, math.min(maxScroll, offset or 0))
    sf._currentScroll = clamped
    if sf.SetVerticalScroll then
        pcall(sf.SetVerticalScroll, sf, clamped)
    end
    if detailFrame.scrollBar and detailFrame.scrollBar.SetValue then
        detailFrame._updatingScrollBar = true
        pcall(detailFrame.scrollBar.SetValue, detailFrame.scrollBar, clamped)
        detailFrame._updatingScrollBar = false
    end
end

local function OnDetailMouseWheel(_, delta)
    if not detailFrame or not detailFrame.scrollFrame then return end
    local sf = detailFrame.scrollFrame
    local cur = sf._currentScroll or (sf.GetVerticalScroll and sf:GetVerticalScroll()) or 0
    local nextOffset = cur - ((delta or 0) * SCROLL_STEP)
    ApplyScrollOffset(nextOffset)
end

local function BindMouseWheelForwarding(frame)
    if not frame then return end
    if frame.EnableMouseWheel then
        pcall(frame.EnableMouseWheel, frame, true)
    end
    if frame.SetScript then
        pcall(frame.SetScript, frame, "OnMouseWheel", OnDetailMouseWheel)
    end
end

local function EstimateWrappedTextHeight(text, charsPerLine, lineHeight)
    if type(text) ~= "string" or text == "" then return 20 end
    charsPerLine = charsPerLine or 68
    lineHeight = lineHeight or 14
    local totalLines = 0
    for paragraph in (text .. "\n"):gmatch("(.-)\n") do
        local stripped = paragraph:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|H.-|h", ""):gsub("|h", "")
        local len = math.max(1, #stripped)
        totalLines = totalLines + math.max(1, math.ceil(len / charsPerLine))
    end
    return totalLines * lineHeight
end

local function UpdateScrollRange()
    if not detailFrame or not detailFrame.scrollFrame or not detailFrame.scrollChild then
        return
    end

    local descText = detailFrame.descText
    local rawText = (descText and descText.GetText and descText:GetText()) or ""
    local measuredHeight = (descText and descText.GetStringHeight and descText:GetStringHeight()) or 0
    local estimatedHeight = EstimateWrappedTextHeight(rawText, 66, 14)
    local descHeight = math.max(measuredHeight, estimatedHeight, 24)

    local rowsHeight = 0
    for i = 1, MAX_SHOPPING_ROWS do
        local row = shoppingRows[i]
        if row and (row._itemData or row._stepData) then
            rowsHeight = rowsHeight + (row._rowHeight or 60)
        end
    end

    local totalContentHeight = descHeight + 38 + rowsHeight + 14
    if detailFrame.scrollChild.SetHeight then
        detailFrame.scrollChild:SetHeight(math.max(SCROLL_VIEWPORT_HEIGHT, totalContentHeight))
    end

    local maxScroll = math.max(0, totalContentHeight - SCROLL_VIEWPORT_HEIGHT)
    detailFrame.scrollFrame._maxScroll = maxScroll

    if detailFrame.scrollBar then
        if detailFrame.scrollBar.SetMinMaxValues then
            detailFrame.scrollBar:SetMinMaxValues(0, maxScroll)
        end
        if maxScroll > 0 then
            if detailFrame.scrollBar.Show then detailFrame.scrollBar:Show() end
        else
            if detailFrame.scrollBar.Hide then detailFrame.scrollBar:Hide() end
        end
    end

    ApplyScrollOffset(math.min(detailFrame.scrollFrame._currentScroll or 0, maxScroll))
end

local function CreateShoppingRow(parent, index, anchorBelowFrame)
    local row = CreateFrame("Frame", "PF_DetailShoppingRow" .. index, parent)
    if row.SetSize then row:SetSize(432, 54) end
    if row.SetPoint then
        if index == 1 then
            row:SetPoint("TOPLEFT", anchorBelowFrame, "BOTTOMLEFT", 0, -8)
        else
            row:SetPoint("TOPLEFT", anchorBelowFrame, "BOTTOMLEFT", 0, -6)
        end
    end
    SetBackdropSafe(row, 0.12, 0.13, 0.16, 0.90)
    BindMouseWheelForwarding(row)

    -- Line 1: Clickable Item Link Button
    local itemBtn = CreateFrame("Button", "PF_DetailShoppingItemBtn" .. index, row)
    if itemBtn.SetSize then itemBtn:SetSize(268, 16) end
    if itemBtn.SetPoint then itemBtn:SetPoint("TOPLEFT", row, "TOPLEFT", 8, -5) end
    BindMouseWheelForwarding(itemBtn)

    local itemText = itemBtn.CreateFontString and itemBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    if itemText then
        if itemText.SetPoint then itemText:SetPoint("LEFT", itemBtn, "LEFT", 0, 0) end
        if itemText.SetWidth then itemText:SetWidth(268) end
        if itemText.SetJustifyH then itemText:SetJustifyH("LEFT") end
        if itemText.SetWordWrap then pcall(itemText.SetWordWrap, itemText, false) end
    end

    -- Line 2: Live Inventory / Mailbox Status (anchored below itemBtn so it never overlaps Line 1)
    local statusText = row.CreateFontString and row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    if statusText then
        if statusText.SetPoint then statusText:SetPoint("TOPLEFT", itemBtn, "BOTTOMLEFT", 0, -3) end
        if statusText.SetWidth then statusText:SetWidth(268) end
        if statusText.SetJustifyH then statusText:SetJustifyH("LEFT") end
        if statusText.SetWordWrap then pcall(statusText.SetWordWrap, statusText, false) end
    end

    -- Line 3: Unit & Total Price Info (anchored below statusText so it never wraps into Line 1 or Line 2)
    local priceText = row.CreateFontString and row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    if priceText then
        if priceText.SetPoint then priceText:SetPoint("TOPLEFT", statusText, "BOTTOMLEFT", 0, -2) end
        if priceText.SetWidth then priceText:SetWidth(268) end
        if priceText.SetJustifyH then priceText:SetJustifyH("LEFT") end
        if priceText.SetWordWrap then pcall(priceText.SetWordWrap, priceText, false) end
    end

    local searchBtn = CreateFrame("Button", "PF_DetailShoppingSearchBtn" .. index, row, "UIPanelButtonTemplate")
    if searchBtn.SetSize then searchBtn:SetSize(74, 22) end
    if searchBtn.SetPoint then searchBtn:SetPoint("RIGHT", row, "RIGHT", -80, 0) end
    if searchBtn.SetText then searchBtn:SetText("Open in AH") end
    BindMouseWheelForwarding(searchBtn)

    local buyBtn = CreateFrame("Button", "PF_DetailShoppingBuyBtn" .. index, row, "UIPanelButtonTemplate")
    if buyBtn.SetSize then buyBtn:SetSize(70, 22) end
    if buyBtn.SetPoint then buyBtn:SetPoint("RIGHT", row, "RIGHT", -6, 0) end
    if buyBtn.SetText then buyBtn:SetText("Buy Next") end
    BindMouseWheelForwarding(buyBtn)

    local craftBtn = CreateFrame("Button", "PF_DetailShoppingCraftBtn" .. index, row, "UIPanelButtonTemplate")
    if craftBtn.SetSize then craftBtn:SetSize(144, 22) end
    if craftBtn.SetPoint then craftBtn:SetPoint("RIGHT", row, "RIGHT", -6, 0) end
    if craftBtn.SetText then craftBtn:SetText("Open Crafting") end
    craftBtn:Hide()
    BindMouseWheelForwarding(craftBtn)

    local craftNowBtn = CreateFrame("Button", "PF_DetailShoppingCraftNowBtn" .. index, row, "UIPanelButtonTemplate")
    if craftNowBtn.SetSize then craftNowBtn:SetSize(68, 22) end
    if craftNowBtn.SetPoint then craftNowBtn:SetPoint("RIGHT", row, "RIGHT", -6, 0) end
    if craftNowBtn.SetText then craftNowBtn:SetText("Craft 1x") end
    craftNowBtn:Hide()
    BindMouseWheelForwarding(craftNowBtn)

    itemBtn:SetScript("OnClick", function()
        if row._itemData then
            local rem = math.max(1, row._itemData.remainingToBuy or row._itemData.totalQuantity or 1)
            HandleItemLinkClick(row._itemData.itemId, row._itemData.name, row._itemData.link, rem)
        elseif row._stepData then
            local rem = math.max(1, row._stepData.remainingToCraft or row._stepData.totalQuantity or 1)
            HandleItemLinkClick(row._stepData.outputItemId, row._stepData.outputName, row._stepData.outputLink, rem)
        end
    end)
    itemBtn:SetScript("OnEnter", function(self)
        if row._itemData then
            ShowItemTooltip(self, row._itemData.itemId, row._itemData.link)
        elseif row._stepData then
            ShowItemTooltip(self, row._stepData.outputItemId, row._stepData.outputLink)
        end
    end)
    itemBtn:SetScript("OnLeave", function()
        if _G.GameTooltip then _G.GameTooltip:Hide() end
    end)

    searchBtn:SetScript("OnClick", function()
        if row._itemData then
            local rem = math.max(1, (row._itemData.remainingToBuy and row._itemData.remainingToBuy > 0) and row._itemData.remainingToBuy or row._itemData.totalQuantity or 1)
            PF.AHVerifier.SearchItemOnAH(row._itemData.itemId, row._itemData.name, row._itemData.link, rem)
        end
    end)

    buyBtn:SetScript("OnClick", function()
        if row._itemData then
            if row._itemData.remainingToBuy == 0 then
                if (row._itemData.purchasedInMail or 0) > 0 then
                    print(string.format(
                        "|cff00ff88[Profitable]|r You already purchased all required [%s] (%d in mail — check your mailbox!).",
                        row._itemData.name or "Item",
                        row._itemData.purchasedInMail
                    ))
                else
                    print(string.format("|cff00ff88[Profitable]|r You already have all required [%s] (covered by bags / crafted materials).", row._itemData.name or "Item"))
                end
                return
            end
            local rem = math.max(1, row._itemData.remainingToBuy or row._itemData.totalQuantity or 1)
            local effectiveMax = row._itemData.effectiveMaxUnitPrice or row._itemData.maxUnitPrice
            PF.AHVerifier.BuyNextCheapListing(row._itemData.itemId, row._itemData.name, effectiveMax, rem)
        end
    end)

    local function BuildStepRecipe(stepData)
        return stepData.recipe or {
            recipeId = stepData.recipeId,
            name = stepData.recipeName or stepData.outputName,
            profession = stepData.profession,
            professionId = stepData.professionId,
            outputItemId = stepData.outputItemId,
        }
    end

    craftBtn:SetScript("OnClick", function()
        if row._stepData then
            PF.RecipeScanner.OpenRecipe(BuildStepRecipe(row._stepData))
        end
    end)
    craftBtn:SetScript("OnEnter", function(self)
        if not _G.GameTooltip or not row._stepData then return end
        local prof = row._stepData.profession or "Profession"
        _G.GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        _G.GameTooltip:AddLine("Open " .. prof, 0, 1, 0.5)
        _G.GameTooltip:AddLine(string.format(
            "Click to open your %s window directly to [%s].",
            prof,
            row._stepData.recipeName or row._stepData.outputName or "Recipe"
        ), 1, 1, 1, true)
        _G.GameTooltip:Show()
    end)
    craftBtn:SetScript("OnLeave", function()
        if _G.GameTooltip then _G.GameTooltip:Hide() end
    end)

    craftNowBtn:SetScript("OnClick", function()
        if row._stepData then
            local batches = math.max(1, row._stepData.craftableBatchesNow or row._stepData.remainingBatches or 1)
            PF.RecipeScanner.CraftRecipe(BuildStepRecipe(row._stepData), batches)
        end
    end)
    craftNowBtn:SetScript("OnEnter", function(self)
        if not _G.GameTooltip or not row._stepData then return end
        local prof = row._stepData.profession or "Profession"
        local batches = math.max(1, row._stepData.craftableBatchesNow or row._stepData.remainingBatches or 1)
        _G.GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        _G.GameTooltip:AddLine(string.format("Craft %dx [%s]", batches, row._stepData.recipeName or row._stepData.outputName or "Recipe"), 0, 1, 0.5)
        _G.GameTooltip:AddLine(string.format(
            "Click to craft %dx directly via %s (zero UI taint). If %s isn't open yet, the first click opens it to this recipe and the second click starts crafting.",
            batches, prof, prof
        ), 1, 1, 1, true)
        _G.GameTooltip:Show()
    end)
    craftNowBtn:SetScript("OnLeave", function()
        if _G.GameTooltip then _G.GameTooltip:Hide() end
    end)

    row.itemBtn = itemBtn
    row.itemText = itemText
    row.statusText = statusText
    row.priceText = priceText
    row.searchBtn = searchBtn
    row.buyBtn = buyBtn
    row.craftBtn = craftBtn
    row.craftNowBtn = craftNowBtn
    row._indentX = 0
    row._rowHeight = 60
    return row
end

local function EnsureDetailFrame()
    if detailFrame then return detailFrame end

    detailFrame = CreateFrame("Frame", "PF_OpportunityDetailWindow", _G.UIParent)
    if detailFrame.SetSize then detailFrame:SetSize(480, 520) end
    if detailFrame.SetPoint then detailFrame:SetPoint("CENTER", _G.UIParent, "CENTER", 220, 0) end
    -- Use MEDIUM strata + SetToplevel(true) matching Blizzard UI panels (ProfessionsFrame,
    -- AuctionHouseFrame, etc.) so clicking any window brings whichever one is in focus to the front.
    if detailFrame.SetFrameStrata then detailFrame:SetFrameStrata("MEDIUM") end
    if detailFrame.SetToplevel then detailFrame:SetToplevel(true) end
    if detailFrame.SetMovable then detailFrame:SetMovable(true) end
    if detailFrame.EnableMouse then detailFrame:EnableMouse(true) end
    if detailFrame.RegisterForDrag then detailFrame:RegisterForDrag("LeftButton") end
    detailFrame:SetScript("OnDragStart", function(self)
        if self.StartMoving then self:StartMoving() end
    end)
    detailFrame:SetScript("OnDragStop", function(self)
        if self.StopMovingOrSizing then self:StopMovingOrSizing() end
    end)
    BindMouseWheelForwarding(detailFrame)

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
    if titleBtn.SetSize then titleBtn:SetSize(446, 24) end
    if titleBtn.SetPoint then titleBtn:SetPoint("TOPLEFT", detailFrame, "TOPLEFT", 14, -36) end

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

    -- Financial Breakdown Summary Box (Pinned at Top)
    local metricsText = detailFrame.CreateFontString and detailFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    if metricsText then
        if metricsText.SetPoint then metricsText:SetPoint("TOPLEFT", detailFrame, "TOPLEFT", 14, -64) end
        if metricsText.SetWidth then metricsText:SetWidth(450) end
        if metricsText.SetJustifyH then metricsText:SetJustifyH("LEFT") end
    end

    -- Scrollable Body Viewport (holds explanation text + shopping list header + shopping rows)
    local scrollFrame = CreateFrame("ScrollFrame", "PF_DetailScrollFrame", detailFrame)
    if scrollFrame.SetSize then scrollFrame:SetSize(440, SCROLL_VIEWPORT_HEIGHT) end
    if scrollFrame.SetPoint then scrollFrame:SetPoint("TOPLEFT", detailFrame, "TOPLEFT", 14, -106) end
    if scrollFrame.SetClipsChildren then pcall(scrollFrame.SetClipsChildren, scrollFrame, true) end
    scrollFrame._currentScroll = 0
    scrollFrame._maxScroll = 0
    BindMouseWheelForwarding(scrollFrame)

    local scrollChild = CreateFrame("Frame", "PF_DetailScrollChild", scrollFrame)
    if scrollChild.SetSize then scrollChild:SetSize(436, SCROLL_VIEWPORT_HEIGHT) end
    if scrollFrame.SetScrollChild then
        pcall(scrollFrame.SetScrollChild, scrollFrame, scrollChild)
    end
    BindMouseWheelForwarding(scrollChild)

    -- Thin Vertical Scrollbar Slider on Right Edge
    local scrollBar = CreateFrame("Slider", "PF_DetailScrollBar", detailFrame)
    if scrollBar.SetSize then scrollBar:SetSize(10, SCROLL_VIEWPORT_HEIGHT) end
    if scrollBar.SetPoint then scrollBar:SetPoint("TOPLEFT", scrollFrame, "TOPRIGHT", 6, 0) end
    if scrollBar.SetOrientation then pcall(scrollBar.SetOrientation, scrollBar, "VERTICAL") end
    if scrollBar.SetMinMaxValues then scrollBar:SetMinMaxValues(0, 0) end
    if scrollBar.SetValueStep then pcall(scrollBar.SetValueStep, scrollBar, 10) end
    if scrollBar.SetValue then scrollBar:SetValue(0) end
    SetBackdropSafe(scrollBar, 0.14, 0.16, 0.20, 0.90)
    if scrollBar.CreateTexture and scrollBar.SetThumbTexture then
        local thumb = scrollBar:CreateTexture(nil, "OVERLAY")
        if thumb.SetSize then thumb:SetSize(10, 44) end
        if thumb.SetColorTexture then
            thumb:SetColorTexture(0.20, 0.85, 0.55, 0.90)
        elseif thumb.SetTexture then
            thumb:SetTexture(0.20, 0.85, 0.55, 0.90)
        end
        pcall(scrollBar.SetThumbTexture, scrollBar, thumb)
    end
    scrollBar:SetScript("OnValueChanged", function(_, value)
        if detailFrame._updatingScrollBar then return end
        ApplyScrollOffset(value)
    end)
    BindMouseWheelForwarding(scrollBar)

    -- Explanation / Why It's Valuable Box (Top of ScrollChild)
    local descText = scrollChild.CreateFontString and scrollChild:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    if descText then
        if descText.SetPoint then descText:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 2, -4) end
        if descText.SetWidth then descText:SetWidth(430) end
        if descText.SetJustifyH then descText:SetJustifyH("LEFT") end
        if descText.SetJustifyV then descText:SetJustifyV("TOP") end
    end

    -- Shopping List Section Header (Dynamically anchored below descText so it can NEVER overlap!)
    local shopHeader = scrollChild.CreateFontString and scrollChild:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    if shopHeader then
        if shopHeader.SetPoint then
            shopHeader:SetPoint("TOPLEFT", descText, "BOTTOMLEFT", 0, -14)
        end
        if shopHeader.SetText then
            shopHeader:SetText("|cffffd100Shopping List & Live Inventory / Mailbox Tracker:|r")
        end
    end

    for i = 1, MAX_SHOPPING_ROWS do
        local anchorTarget = (i == 1) and shopHeader or shoppingRows[i - 1]
        shoppingRows[i] = CreateShoppingRow(scrollChild, i, anchorTarget)
    end

    -- Footer Action Buttons (Pinned at Bottom of Window)
    local recipeBtn = CreateFrame("Button", "PF_DetailOpenRecipeButton", detailFrame, "UIPanelButtonTemplate")
    if recipeBtn.SetSize then recipeBtn:SetSize(145, 24) end
    if recipeBtn.SetPoint then recipeBtn:SetPoint("BOTTOMLEFT", detailFrame, "BOTTOMLEFT", 14, 14) end
    if recipeBtn.SetText then recipeBtn:SetText("Open Recipe") end
    recipeBtn:SetScript("OnClick", function()
        if currentOpportunity and currentOpportunity.recipe then
            PF.RecipeScanner.OpenRecipe(currentOpportunity.recipe)
        end
    end)
    recipeBtn:SetScript("OnEnter", function(self)
        if not _G.GameTooltip or not currentOpportunity or not currentOpportunity.recipe then return end
        local prof = currentOpportunity.recipe.profession or "Profession"
        _G.GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        _G.GameTooltip:AddLine("Open " .. prof, 0, 1, 0.5)
        _G.GameTooltip:AddLine(string.format("Click to open your %s crafting window to [%s].", prof, currentOpportunity.recipe.name or currentOpportunity.itemName or "Recipe"), 1, 1, 1, true)
        _G.GameTooltip:Show()
    end)
    recipeBtn:SetScript("OnLeave", function()
        if _G.GameTooltip then _G.GameTooltip:Hide() end
    end)

    local craftFinalBtn = CreateFrame("Button", "PF_DetailCraftFinalButton", detailFrame, "UIPanelButtonTemplate")
    if craftFinalBtn.SetSize then craftFinalBtn:SetSize(82, 24) end
    if craftFinalBtn.SetPoint then craftFinalBtn:SetPoint("LEFT", recipeBtn, "RIGHT", 6, 0) end
    if craftFinalBtn.SetText then craftFinalBtn:SetText("Craft 1x") end
    craftFinalBtn:Hide()
    craftFinalBtn:SetScript("OnClick", function()
        if currentOpportunity and currentOpportunity.recipe then
            local batches = math.max(1, currentOpportunity.finalCraftableBatches or 1)
            PF.RecipeScanner.CraftRecipe(currentOpportunity.recipe, batches)
        end
    end)
    craftFinalBtn:SetScript("OnEnter", function(self)
        if not _G.GameTooltip or not currentOpportunity or not currentOpportunity.recipe then return end
        local prof = currentOpportunity.recipe.profession or "Profession"
        local batches = math.max(1, currentOpportunity.finalCraftableBatches or 1)
        _G.GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        _G.GameTooltip:AddLine(string.format("Craft %dx [%s]", batches, currentOpportunity.recipe.name or currentOpportunity.itemName or "Recipe"), 0, 1, 0.5)
        _G.GameTooltip:AddLine(string.format(
            "Click to craft %dx directly via %s (zero UI taint). If %s isn't open yet, the first click opens it to this recipe and the second click starts crafting.",
            batches, prof, prof
        ), 1, 1, 1, true)
        _G.GameTooltip:Show()
    end)
    craftFinalBtn:SetScript("OnLeave", function()
        if _G.GameTooltip then _G.GameTooltip:Hide() end
    end)

    local searchTargetBtn = CreateFrame("Button", "PF_DetailSearchTargetButton", detailFrame, "UIPanelButtonTemplate")
    if searchTargetBtn.SetSize then searchTargetBtn:SetSize(140, 24) end
    if searchTargetBtn.SetPoint then searchTargetBtn:SetPoint("BOTTOM", detailFrame, "BOTTOM", 10, 14) end
    if searchTargetBtn.SetText then searchTargetBtn:SetText("Search Target AH") end
    searchTargetBtn:SetScript("OnClick", function()
        if currentOpportunity then
            PF.AHVerifier.SearchItemOnAH(currentOpportunity.itemId, currentOpportunity.itemName, currentOpportunity.itemLink)
        end
    end)

    local refreshBtn = CreateFrame("Button", "PF_DetailRefreshButton", detailFrame, "UIPanelButtonTemplate")
    if refreshBtn.SetSize then refreshBtn:SetSize(120, 24) end
    if refreshBtn.SetPoint then refreshBtn:SetPoint("BOTTOMRIGHT", detailFrame, "BOTTOMRIGHT", -14, 14) end
    if refreshBtn.SetText then refreshBtn:SetText("Refresh Bags") end
    refreshBtn:SetScript("OnClick", function()
        if _G.IsShiftKeyDown and _G.IsShiftKeyDown() and PF.AHVerifier and PF.AHVerifier.ClearPurchasedTracker then
            PF.AHVerifier.ClearPurchasedTracker()
            print("|cff00ff88[Profitable]|r Cleared 'Bought (In Mail)' purchase tracker.")
        end
        PF.DetailWindow.RefreshIfShown()
    end)
    refreshBtn:SetScript("OnEnter", function(self)
        if not _G.GameTooltip then return end
        _G.GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        _G.GameTooltip:AddLine("Refresh Inventory & Mail Tracker", 0, 1, 0.5)
        _G.GameTooltip:AddLine("Click: Refresh live bag/bank/mail counts.", 1, 1, 1, true)
        _G.GameTooltip:AddLine("Shift-Click: Reset 'Bought (In Mail)' purchase tracker.", 0.7, 0.85, 1, true)
        _G.GameTooltip:Show()
    end)
    refreshBtn:SetScript("OnLeave", function()
        if _G.GameTooltip then _G.GameTooltip:Hide() end
    end)

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
    detailFrame.scrollFrame = scrollFrame
    detailFrame.scrollChild = scrollChild
    detailFrame.scrollBar = scrollBar
    detailFrame.descText = descText
    detailFrame.shopHeader = shopHeader
    detailFrame.recipeBtn = recipeBtn
    detailFrame.craftFinalBtn = craftFinalBtn
    detailFrame.searchTargetBtn = searchTargetBtn
    detailFrame.refreshBtn = refreshBtn
    detailFrame.shoppingRows = shoppingRows

    detailFrame:Hide()
    PF.DetailWindow.frame = detailFrame
    return detailFrame
end

local function OpportunityReferencesItem(opp, itemId)
    if type(opp) ~= "table" or not itemId or itemId <= 0 then
        return false
    end
    if opp.itemId == itemId or opp.targetMatId == itemId then
        return true
    end
    if type(opp.shoppingList) == "table" then
        for _, shop in ipairs(opp.shoppingList) do
            if shop and shop.itemId == itemId then
                return true
            end
        end
    end
    if opp.deBreakdown and type(opp.deBreakdown.drops) == "table" then
        for _, d in ipairs(opp.deBreakdown.drops) do
            if d and (d.sellItemId == itemId or d.itemId == itemId) then
                return true
            end
        end
    end
    return false
end

function PF.DetailWindow.RevalidateActiveOpportunity(updatedItemId)
    if not detailFrame or (detailFrame.IsShown and not detailFrame:IsShown()) then
        return false
    end
    local opp = currentOpportunity or (Profitable_DB and Profitable_DB.activePlay)
    if not opp or not OpportunityReferencesItem(opp, updatedItemId) then
        return false
    end

    -- If the updated item is a shopping input that the player has ALREADY fully acquired
    -- (in bags or confirmed purchased in mail) and is NOT an AH exit item, do not shrink the
    -- play or falsely flag it [No Longer Profitable] just because the player bought out the cheap listings!
    if PF.OpportunityEngine and PF.OpportunityEngine.ComputeLiveInventoryState then
        PF.OpportunityEngine.ComputeLiveInventoryState(opp)
    end
    local isExitItem = (opp.actionType == "CRAFT_AH" and opp.itemId == updatedItemId)
        or ((opp.actionType == "BUY_DE" or opp.actionType == "CRAFT_DE") and opp.targetMatId == updatedItemId)

    -- Once the player has started purchasing inputs for this play, lock opp.quantity (never shrink
    -- e.g. 3x -> 2x mid-shopping because earlier purchases lowered GetPlayerGold() or depleted AH tiers)
    -- and dynamically adjust remaining unbought items' max unit prices in O(K) time!
    if not isExitItem and opp._hasActivePurchases then
        PF.DetailWindow.RefreshIfShown()
        return true
    end

    if not isExitItem and type(opp.shoppingList) == "table" then
        local matchedInput = false
        local allMatchingCovered = true
        for _, shop in ipairs(opp.shoppingList) do
            if shop and shop.itemId == updatedItemId then
                matchedInput = true
                if (shop.remainingToBuy or 0) > 0 then
                    allMatchingCovered = false
                    break
                end
            end
        end
        if matchedInput and allMatchingCovered then
            PF.DetailWindow.RefreshIfShown()
            return true
        end
    end

    -- Fast O(1) single-opportunity re-evaluation instead of re-scanning all 7,000+ AH items
    -- on every COMMODITY_SEARCH_RESULTS_UPDATED / ITEM_SEARCH_RESULTS_UPDATED click or purchase.
    if PF.OpportunityEngine and PF.OpportunityEngine.ReevaluateSingleOpportunity then
        local matched = PF.OpportunityEngine.ReevaluateSingleOpportunity(opp)
        if matched then
            matched.verified = opp.verified
            matched._liveUnprofitable = false
            currentOpportunity = matched
            if Profitable_DB then
                Profitable_DB.activePlay = matched
            end
        else
            opp._liveUnprofitable = true
            opp.verified = false
            if type(opp.shoppingList) == "table" then
                for _, shop in ipairs(opp.shoppingList) do
                    if shop and shop.source == "AH" then
                        local ob = Profitable_DB and Profitable_DB.orderBookCache and Profitable_DB.orderBookCache[shop.itemId]
                        if ob and (time() - (ob.timestamp or 0)) <= 600 then
                            if ob.unavailable or type(ob.listings) ~= "table" or #ob.listings == 0 then
                                shop._liveUnavailable = true
                                shop._liveMinUnitPrice = nil
                            else
                                shop._liveUnavailable = false
                                shop._liveMinUnitPrice = ob.listings[1] and ob.listings[1].unitPrice or nil
                            end
                        end
                    end
                end
            end
        end
    end

    PF.DetailWindow.RefreshIfShown()
    return true
end

function PF.DetailWindow.ShowOpportunity(opp)
    if not opp then return end
    if opp.recipe and PF.RecipeScanner and PF.RecipeScanner.NormalizeRecipeProfession then
        if PF.RecipeScanner.NormalizeRecipeProfession(opp.recipe) and PF.OpportunityEngine and PF.OpportunityEngine.BuildDetailedExplanation then
            opp.explanation = PF.OpportunityEngine.BuildDetailedExplanation(opp)
        end
    end
    currentOpportunity = opp
    if Profitable_DB then
        Profitable_DB.activePlay = opp
    end

    local frame = EnsureDetailFrame()
    frame:Show()
    if frame.Raise then frame:Raise() end
    ApplyScrollOffset(0)

    if PF.AHVerifier and PF.AHVerifier.OpenNextNeededItemInDefaultAH then
        PF.AHVerifier.OpenNextNeededItemInDefaultAH(opp)
    end

    PF.DetailWindow.RefreshIfShown()
end

function PF.DetailWindow.RefreshIfShown()
    if not detailFrame or (detailFrame.IsShown and not detailFrame:IsShown()) then
        return
    end
    local opp = currentOpportunity or (Profitable_DB and Profitable_DB.activePlay)
    if not opp then return end

    if opp.recipe and PF.RecipeScanner and PF.RecipeScanner.NormalizeRecipeProfession then
        if PF.RecipeScanner.NormalizeRecipeProfession(opp.recipe) and PF.OpportunityEngine and PF.OpportunityEngine.BuildDetailedExplanation then
            opp.explanation = PF.OpportunityEngine.BuildDetailedExplanation(opp)
        end
    end

    if PF.OpportunityEngine and PF.OpportunityEngine.ComputeLiveInventoryState then
        PF.OpportunityEngine.ComputeLiveInventoryState(opp)
    end

    local verBadge
    if opp._liveUnprofitable then
        verBadge = "|cffff4444[No Longer Profitable]|r"
    elseif opp.verified then
        verBadge = "|cff00ff00[Verified AH]|r"
    else
        verBadge = "|cffffcc00[Cached Scan]|r"
    end
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
            and string.format("   |cffffd100Est. Deposit:|r %s", PF.Formatter.FormatMoney(opp.totalDepositRisk))
            or ""
        local profStr = PF.Formatter.FormatMoney(opp.totalProfit)
        if opp._liveUnprofitable then
            detailFrame.metricsText:SetText(string.format(
                "|cffffd100Est. Cost:|r %s   |cffffd100Net Rev:|r %s   |cffffd100AH Cut:|r %s%s\n|cffff4444Live AH prices changed — this play is no longer profitable!|r",
                costStr, revStr, cutStr, depStr
            ))
        else
            detailFrame.metricsText:SetText(string.format(
                "|cffffd100Cost:|r %s   |cffffd100Net Rev:|r %s   |cffffd100AH Cut:|r %s%s\n|cff00ff00Total Profit:|r |cff00ff00%s|r (%d%% ROI)",
                costStr, revStr, cutStr, depStr, profStr, opp.roiPercent or 0
            ))
        end
    end

    if detailFrame.descText then
        local explanation = opp.explanation or PF.OpportunityEngine.BuildDetailedExplanation(opp)
        detailFrame.descText:SetText(explanation)
    end

    -- Build interleaved display rows: each raw shopping item followed immediately
    -- by any intermediate craft sub-step (e.g. Mithril Ore -> Mithril Bar) that it feeds.
    local shopList = type(opp.shoppingList) == "table" and opp.shoppingList or {}
    local steps = type(opp.intermediateSteps) == "table" and opp.intermediateSteps or {}
    local lastShopIdxByItemId = {}
    for idx, item in ipairs(shopList) do
        if item and item.itemId then
            lastShopIdxByItemId[item.itemId] = idx
        end
    end
    local stepsAfterShopIdx = {}
    local unattachedSteps = {}
    for _, step in ipairs(steps) do
        if type(step) == "table" and step.outputItemId then
            local attachIdx = 0
            if type(step.reagents) == "table" then
                for _, subR in ipairs(step.reagents) do
                    local sIdx = subR and subR.itemId and lastShopIdxByItemId[subR.itemId]
                    if sIdx and sIdx > attachIdx then
                        attachIdx = sIdx
                    end
                end
            end
            if attachIdx > 0 then
                stepsAfterShopIdx[attachIdx] = stepsAfterShopIdx[attachIdx] or {}
                table.insert(stepsAfterShopIdx[attachIdx], step)
            else
                table.insert(unattachedSteps, step)
            end
        end
    end

    local displayEntries = {}
    for idx, item in ipairs(shopList) do
        table.insert(displayEntries, { kind = "SHOP", item = item })
        if stepsAfterShopIdx[idx] then
            for _, step in ipairs(stepsAfterShopIdx[idx]) do
                table.insert(displayEntries, { kind = "CRAFT", step = step })
            end
        end
    end
    for _, step in ipairs(unattachedSteps) do
        table.insert(displayEntries, { kind = "CRAFT", step = step })
    end

    for i = 1, MAX_SHOPPING_ROWS do
        local row = shoppingRows[i]
        local entry = displayEntries[i]
        if entry and entry.kind == "SHOP" then
            local item = entry.item
            row._itemData = item
            row._stepData = nil
            row._rowKind = "SHOP"
            row:Show()

            local indentX = 0
            if row.SetSize then row:SetSize(432, 54) end
            if row.ClearAllPoints and row.SetPoint then
                row:ClearAllPoints()
                if i == 1 then
                    row:SetPoint("TOPLEFT", detailFrame.shopHeader, "BOTTOMLEFT", indentX, -8)
                else
                    local prevRow = shoppingRows[i - 1]
                    local prevIndent = (prevRow and prevRow._indentX) or 0
                    row:SetPoint("TOPLEFT", prevRow, "BOTTOMLEFT", indentX - prevIndent, -6)
                end
            end
            row._indentX = indentX
            row._rowHeight = 60

            if row.itemBtn and row.itemBtn.SetWidth then row.itemBtn:SetWidth(268) end
            if row.itemText and row.itemText.SetWidth then row.itemText:SetWidth(268) end
            if row.statusText and row.statusText.SetWidth then row.statusText:SetWidth(268) end
            if row.priceText and row.priceText.SetWidth then row.priceText:SetWidth(268) end

            local liveInBags = item.haveInBags or PF.Formatter.GetInventoryCount(item.itemId, false)
            local liveInBank = item.haveInBank or math.max(0, PF.Formatter.GetInventoryCount(item.itemId, true) - liveInBags)
            local inMail = item.purchasedInMail or 0
            local effectiveNeeded = item.effectiveQuantity or item.totalQuantity or 1
            local remToBuy = (item.remainingToBuy ~= nil) and item.remainingToBuy or math.max(0, effectiveNeeded - liveInBags - inMail)
            local isBought = (item.purchasedCovered == true)
            local isReady = (remToBuy <= 0 and not isBought)

            if isBought then
                SetRowBackgroundColor(row, 0.07, 0.22, 0.13, 0.94)
            elseif isReady then
                SetRowBackgroundColor(row, 0.07, 0.20, 0.12, 0.92)
            elseif inMail > 0 then
                SetRowBackgroundColor(row, 0.10, 0.16, 0.21, 0.92)
            else
                SetRowBackgroundColor(row, 0.12, 0.13, 0.16, 0.90)
            end

            local checkPrefix = (isBought or isReady) and CHECKMARK_ICON or ""
            local sourceTag = (item.source == "Vendor") and "|cff00ccff[Vendor]|r" or "|cffffaa00[AH]|r"
            if row.itemText then
                row.itemText:SetText(string.format("%s%s %dx %s", checkPrefix, sourceTag, item.totalQuantity, item.link))
            end

            local satNote = ""
            if type(item.satisfyingSteps) == "table" and #item.satisfyingSteps > 0 then
                local s0 = item.satisfyingSteps[1]
                satNote = string.format("%d / %d %s", s0.haveInBags, s0.totalQuantity, s0.outputName or "crafted")
            end

            local invStatus
            if item.fullySatisfiedByIntermediates then
                if satNote ~= "" then
                    invStatus = string.format("|cff00ff00Ready: Covered by %s|r", satNote)
                else
                    invStatus = "|cff00ff00Ready: Covered by crafted items in bags|r"
                end
            elseif isBought then
                if liveInBags > 0 then
                    invStatus = string.format("|cff00ff00Purchased: %d / %d (%d bags + %d mail)|r", liveInBags + inMail, effectiveNeeded, liveInBags, inMail)
                else
                    invStatus = string.format("|cff00ff00Purchased: %d / %d (Check Mail)|r", inMail, effectiveNeeded)
                end
            elseif remToBuy <= 0 then
                if item.satisfiedByIntermediates and satNote ~= "" then
                    invStatus = string.format("|cff00ff00Ready: %d / %d (%s)|r", liveInBags, effectiveNeeded, satNote)
                else
                    invStatus = string.format("|cff00ff00Ready: %d / %d|r", liveInBags, effectiveNeeded)
                end
            elseif inMail > 0 then
                local bankNote = (liveInBank > 0) and string.format(" (+%d bank)", liveInBank) or ""
                if liveInBags > 0 then
                    invStatus = string.format("|cff00e5ffHave: %d bags + %d mail / %d%s — Buy %d|r", liveInBags, inMail, effectiveNeeded, bankNote, remToBuy)
                else
                    invStatus = string.format("|cff00e5ffBought: %d / %d (in mail)%s — Buy %d|r", inMail, effectiveNeeded, bankNote, remToBuy)
                end
            else
                local bankNote = (liveInBank > 0) and string.format(" (+%d bank)", liveInBank) or ""
                if item.satisfiedByIntermediates and satNote ~= "" then
                    invStatus = string.format("|cffffcc00Have: %d / %d%s — Buy %d (%s)|r", liveInBags, effectiveNeeded, bankNote, remToBuy, satNote)
                else
                    invStatus = string.format("|cffffcc00Have: %d / %d%s — Buy %d|r", liveInBags, effectiveNeeded, bankNote, remToBuy)
                end
            end

            local effectiveMax = item.effectiveMaxUnitPrice or item.maxUnitPrice
            local priceInfo
            if item.source == "Vendor" then
                priceInfo = string.format("|cffccccccVendor: %s ea (Total: %s)|r", PF.Formatter.FormatMoney(item.avgUnitPrice), PF.Formatter.FormatMoney(item.totalCost))
            elseif item._liveUnavailable then
                priceInfo = "|cffff5555Live AH: Sold out / no buyout listings|r"
            elseif item._liveMinUnitPrice and effectiveMax and item._liveMinUnitPrice > effectiveMax then
                priceInfo = string.format("|cffff5555Live AH: %s ea (above max %s — unprofitable!)|r", PF.Formatter.FormatMoney(item._liveMinUnitPrice), PF.Formatter.FormatMoney(effectiveMax))
            elseif item._liveMinUnitPrice and item.maxUnitPrice and item._liveMinUnitPrice > item.maxUnitPrice and effectiveMax and item._liveMinUnitPrice <= effectiveMax then
                priceInfo = string.format("|cff88eeaaLive AH: %s ea (within dyn max %s)|r", PF.Formatter.FormatMoney(item._liveMinUnitPrice), PF.Formatter.FormatMoney(effectiveMax))
            elseif effectiveMax and item.maxUnitPrice and effectiveMax > item.maxUnitPrice and remToBuy > 0 then
                priceInfo = string.format("|cffccccccAH: %s ea (Dyn Max %s) | Total: %s|r", PF.Formatter.FormatMoney(item.avgUnitPrice), PF.Formatter.FormatMoney(effectiveMax), PF.Formatter.FormatMoney(item.totalCost))
            elseif item.minUnitPrice ~= item.maxUnitPrice then
                priceInfo = string.format("|cffccccccAvg %s (Max %s) | Total: %s|r", PF.Formatter.FormatMoney(item.avgUnitPrice), PF.Formatter.FormatMoney(item.maxUnitPrice), PF.Formatter.FormatMoney(item.totalCost))
            else
                priceInfo = string.format("|cffccccccAH: %s ea (Total: %s)|r", PF.Formatter.FormatMoney(item.avgUnitPrice), PF.Formatter.FormatMoney(item.totalCost))
            end

            if row.statusText then row.statusText:SetText(invStatus) end
            if row.priceText then row.priceText:SetText(priceInfo) end

            if row.craftBtn then row.craftBtn:Hide() end
            if row.craftNowBtn then row.craftNowBtn:Hide() end
            if row.searchBtn then
                if item.source == "Vendor" then
                    row.searchBtn:Hide()
                else
                    row.searchBtn:Show()
                    row.searchBtn:SetText("Open in AH")
                end
            end
            if row.buyBtn then
                row.buyBtn:Show()
                local label = (PF.AHVerifier and PF.AHVerifier.GetBuyButtonLabel and PF.AHVerifier.GetBuyButtonLabel(item)) or "Buy Next"
                row.buyBtn:SetText(label)
            end
        elseif entry and entry.kind == "CRAFT" then
            local step = entry.step
            row._itemData = nil
            row._stepData = step
            row._rowKind = "CRAFT"
            row:Show()

            local indentX = 14
            if row.SetSize then row:SetSize(418, 50) end
            if row.ClearAllPoints and row.SetPoint then
                row:ClearAllPoints()
                if i == 1 then
                    row:SetPoint("TOPLEFT", detailFrame.shopHeader, "BOTTOMLEFT", indentX, -8)
                else
                    local prevRow = shoppingRows[i - 1]
                    local prevIndent = (prevRow and prevRow._indentX) or 0
                    row:SetPoint("TOPLEFT", prevRow, "BOTTOMLEFT", indentX - prevIndent, -3)
                end
            end
            row._indentX = indentX
            row._rowHeight = 53

            local stepTotal = step.totalQuantity or ((step.countPerUnit or 1) * (opp.quantity or 1))
            local stepBags = step.haveInBags or 0
            local stepBank = step.haveInBank or 0
            local remCraft = step.remainingToCraft or math.max(0, stepTotal - stepBags)
            local craftBatchesNow = step.craftableBatchesNow or 0
            local showCraftNow = (remCraft > 0 and craftBatchesNow > 0)
            local outputDisplay = step.outputLink or step.outputName or step.recipeName or "Crafted Item"

            if remCraft <= 0 then
                SetRowBackgroundColor(row, 0.07, 0.21, 0.14, 0.92)
            elseif showCraftNow then
                SetRowBackgroundColor(row, 0.09, 0.15, 0.23, 0.94)
            else
                SetRowBackgroundColor(row, 0.09, 0.14, 0.20, 0.92)
            end

            local craftTextWidth = showCraftNow and 234 or 254
            if row.itemBtn and row.itemBtn.SetWidth then row.itemBtn:SetWidth(craftTextWidth) end
            if row.itemText and row.itemText.SetWidth then row.itemText:SetWidth(craftTextWidth) end
            if row.statusText and row.statusText.SetWidth then row.statusText:SetWidth(craftTextWidth) end
            if row.priceText and row.priceText.SetWidth then row.priceText:SetWidth(craftTextWidth) end

            local craftCheckPrefix = (remCraft <= 0) and CHECKMARK_ICON or ""
            if row.itemText then
                row.itemText:SetText(string.format("%s|cff00ccff-> [Craft]|r %dx %s", craftCheckPrefix, stepTotal, outputDisplay))
            end

            local craftStatus
            if remCraft <= 0 then
                craftStatus = string.format("|cff00ff00Ready: %d / %d|r", stepBags, stepTotal)
            elseif step.matsReadyInBags then
                craftStatus = string.format("|cff00e5ffHave: %d / %d — Craft %d (mats ready!)|r", stepBags, stepTotal, remCraft)
            elseif (step.craftableNow or 0) > 0 then
                craftStatus = string.format("|cffffcc00Have: %d / %d — Craft %d (%d ready now)|r", stepBags, stepTotal, remCraft, step.craftableNow)
            else
                local bankNote = (stepBank > 0) and string.format(" (+%d bank)", stepBank) or ""
                craftStatus = string.format("|cffffcc00Have: %d / %d%s — Craft %d|r", stepBags, stepTotal, bankNote, remCraft)
            end

            local reqParts = {}
            if type(step.reagents) == "table" then
                local batchesForInfo = (remCraft > 0) and (step.remainingBatches or 0) or math.ceil(stepTotal / math.max(1, step.avgMade or 1))
                for _, sr in ipairs(step.reagents) do
                    local qty = math.max(1, batchesForInfo * (sr.countPerBatch or sr.count or 1))
                    table.insert(reqParts, string.format("%dx %s", qty, sr.name or ("Item #" .. tostring(sr.itemId))))
                end
            end
            local profLabel = step.profession or "Crafting"
            local subDesc = (#reqParts > 0)
                and string.format("|cffaaaaaaUses: %s (%s)|r", table.concat(reqParts, ", "), profLabel)
                or string.format("|cffaaaaaaStep: %s (%s)|r", step.recipeName or outputDisplay, profLabel)

            if row.statusText then row.statusText:SetText(craftStatus) end
            if row.priceText then row.priceText:SetText(subDesc) end

            if row.searchBtn then row.searchBtn:Hide() end
            if row.buyBtn then row.buyBtn:Hide() end
            if row.craftBtn then
                row.craftBtn:Show()
                row.craftBtn:SetText(string.format("Open %s", profLabel))
                if showCraftNow then
                    if row.craftBtn.SetSize then row.craftBtn:SetSize(92, 22) end
                    if row.craftBtn.ClearAllPoints and row.craftBtn.SetPoint then
                        row.craftBtn:ClearAllPoints()
                        row.craftBtn:SetPoint("RIGHT", row, "RIGHT", -78, 0)
                    end
                else
                    if row.craftBtn.SetSize then row.craftBtn:SetSize(144, 22) end
                    if row.craftBtn.ClearAllPoints and row.craftBtn.SetPoint then
                        row.craftBtn:ClearAllPoints()
                        row.craftBtn:SetPoint("RIGHT", row, "RIGHT", -6, 0)
                    end
                end
            end
            if row.craftNowBtn then
                if showCraftNow then
                    row.craftNowBtn:Show()
                    row.craftNowBtn:SetText(string.format("Craft %dx", craftBatchesNow))
                else
                    row.craftNowBtn:Hide()
                end
            end
        else
            row._itemData = nil
            row._stepData = nil
            row._rowKind = nil
            row:Hide()
        end
    end

    local finalBatches = opp.finalCraftableBatches or 0
    local showFinalCraft = (opp.recipe ~= nil and finalBatches > 0)

    if detailFrame.recipeBtn then
        if opp.recipe then
            detailFrame.recipeBtn:Show()
            detailFrame.recipeBtn:SetText(string.format("Open %s", opp.recipe.profession or "Recipe"))
            if detailFrame.recipeBtn.SetSize then
                detailFrame.recipeBtn:SetSize(showFinalCraft and 116 or 145, 24)
            end
        else
            detailFrame.recipeBtn:Hide()
        end
    end

    if detailFrame.craftFinalBtn then
        if showFinalCraft then
            detailFrame.craftFinalBtn:Show()
            detailFrame.craftFinalBtn:SetText(string.format("Craft %dx", finalBatches))
            if detailFrame.craftFinalBtn.ClearAllPoints and detailFrame.craftFinalBtn.SetPoint and detailFrame.recipeBtn then
                detailFrame.craftFinalBtn:ClearAllPoints()
                detailFrame.craftFinalBtn:SetPoint("LEFT", detailFrame.recipeBtn, "RIGHT", 6, 0)
            end
        else
            detailFrame.craftFinalBtn:Hide()
        end
    end

    if detailFrame.searchTargetBtn then
        if detailFrame.searchTargetBtn.SetSize then
            detailFrame.searchTargetBtn:SetSize(showFinalCraft and 126 or 140, 24)
        end
        if detailFrame.searchTargetBtn.ClearAllPoints and detailFrame.searchTargetBtn.SetPoint then
            detailFrame.searchTargetBtn:ClearAllPoints()
            if showFinalCraft and detailFrame.craftFinalBtn then
                detailFrame.searchTargetBtn:SetPoint("LEFT", detailFrame.craftFinalBtn, "RIGHT", 6, 0)
            else
                detailFrame.searchTargetBtn:SetPoint("BOTTOM", detailFrame, "BOTTOM", 10, 14)
            end
        end
    end

    if detailFrame.refreshBtn and detailFrame.refreshBtn.SetSize then
        detailFrame.refreshBtn:SetSize(showFinalCraft and 110 or 120, 24)
    end

    UpdateScrollRange()
    if not scrollUpdatePending and _G.C_Timer and _G.C_Timer.After then
        scrollUpdatePending = true
        _G.C_Timer.After(0, function()
            scrollUpdatePending = false
            UpdateScrollRange()
        end)
    end
end
