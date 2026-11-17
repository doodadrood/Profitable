local _, PF = ...
PF = type(PF) == "table" and PF or _G.PF or {}
_G.PF = PF

PF.SideWindow = {}

local sideFrame = nil
local eventFrame = CreateFrame("Frame")
local playButtons = {}
local hmButtons = {}
local TOP_ROWS = 5
local HM_ROWS = 2

local function SetBackdropSafe(frame, bgR, bgG, bgB, bgA)
    if not frame then return end
    if frame.CreateTexture and not frame._pfBg then
        local bg = frame:CreateTexture(nil, "BACKGROUND")
        if bg.SetAllPoints then bg:SetAllPoints(frame) end
        if bg.SetColorTexture then
            bg:SetColorTexture(bgR or 0.05, bgG or 0.06, bgB or 0.08, bgA or 0.94)
        elseif bg.SetTexture then
            bg:SetTexture(bgR or 0.05, bgG or 0.06, bgB or 0.08, bgA or 0.94)
        end
        frame._pfBg = bg
    end
end

local function CreateOpportunityButton(parent, frameName, yOffset, bgR, bgG, bgB)
    local btn = CreateFrame("Button", frameName, parent)
    if btn.SetSize then btn:SetSize(336, 46) end
    if btn.SetPoint then
        btn:SetPoint("TOPLEFT", parent, "TOPLEFT", 12, yOffset)
    end
    SetBackdropSafe(btn, bgR or 0.11, bgG or 0.13, bgB or 0.16, 0.92)

    local mainText = btn.CreateFontString and btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    if mainText then
        if mainText.SetPoint then mainText.SetPoint(mainText, "TOPLEFT", btn, "TOPLEFT", 8, -6) end
        if mainText.SetWidth then mainText:SetWidth(320) end
        if mainText.SetJustifyH then mainText:SetJustifyH("LEFT") end
    end

    local subText = btn.CreateFontString and btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    if subText then
        if subText.SetPoint then subText:SetPoint("BOTTOMLEFT", btn, "BOTTOMLEFT", 8, 5) end
        if subText.SetWidth then subText:SetWidth(320) end
        if subText.SetJustifyH then subText:SetJustifyH("LEFT") end
    end

    btn:SetScript("OnClick", function()
        if btn._opportunity then
            PF.DetailWindow.ShowOpportunity(btn._opportunity)
        end
    end)

    btn:SetScript("OnEnter", function(self)
        if not _G.GameTooltip or not btn._opportunity then return end
        local opp = btn._opportunity
        _G.GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        _G.GameTooltip:AddLine(opp.summaryLine or opp.itemName, 0, 1, 0.5)
        if opp.explanation then
            _G.GameTooltip:AddLine(opp.explanation, 1, 1, 1, true)
        end
        _G.GameTooltip:AddLine(" ")
        _G.GameTooltip:AddLine("|cff00ff88Click to open Shopping List & Breakdown|r", 0.2, 1, 0.6)
        _G.GameTooltip:Show()
    end)

    btn:SetScript("OnLeave", function()
        if _G.GameTooltip then _G.GameTooltip:Hide() end
    end)

    btn.mainText = mainText
    btn.subText = subText
    return btn
end

local function AnchorToAuctionHouse()
    if not sideFrame or not sideFrame.SetPoint then return end
    local ahParent = _G.AuctionHouseFrame or _G.AuctionFrame
    if ahParent and (not ahParent.IsShown or ahParent:IsShown()) then
        if sideFrame.ClearAllPoints then sideFrame:ClearAllPoints() end
        sideFrame:SetPoint("TOPLEFT", ahParent, "TOPRIGHT", 6, 0)
    end
end

local function EnsureSideWindow()
    if sideFrame then
        AnchorToAuctionHouse()
        return sideFrame
    end

    sideFrame = CreateFrame("Frame", "PF_AuctionSideWindow", _G.UIParent)
    if sideFrame.SetSize then sideFrame:SetSize(360, 505) end
    if sideFrame.SetPoint then sideFrame:SetPoint("TOPLEFT", _G.UIParent, "TOPLEFT", 850, -100) end
    if sideFrame.SetFrameStrata then sideFrame:SetFrameStrata("HIGH") end
    if sideFrame.SetMovable then sideFrame:SetMovable(true) end
    if sideFrame.EnableMouse then sideFrame:EnableMouse(true) end
    if sideFrame.RegisterForDrag then sideFrame:RegisterForDrag("LeftButton") end
    sideFrame:SetScript("OnDragStart", function(self)
        if self.StartMoving then self:StartMoving() end
    end)
    sideFrame:SetScript("OnDragStop", function(self)
        if self.StopMovingOrSizing then self:StopMovingOrSizing() end
    end)

    SetBackdropSafe(sideFrame, 0.05, 0.06, 0.08, 0.95)

    -- Header Title
    local title = sideFrame.CreateFontString and sideFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    if title then
        if title.SetPoint then title:SetPoint("TOPLEFT", sideFrame, "TOPLEFT", 12, -10) end
        if title.SetText then title:SetText("|cff00ff88Profitable|r — Top 5 AH Plays") end
    end

    local closeBtn = CreateFrame("Button", "PF_SideWindowCloseButton", sideFrame, "UIPanelCloseButton")
    if closeBtn.SetPoint then closeBtn:SetPoint("TOPRIGHT", sideFrame, "TOPRIGHT", -2, -2) end
    closeBtn:SetScript("OnClick", function()
        sideFrame:Hide()
    end)

    -- Gold & Known Recipes info line
    local infoText = sideFrame.CreateFontString and sideFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    if infoText then
        if infoText.SetPoint then infoText:SetPoint("TOPLEFT", sideFrame, "TOPLEFT", 12, -32) end
    end

    -- Primary Run / Stop Button
    local findBtn = CreateFrame("Button", "PF_FindOpportunitiesButton", sideFrame, "UIPanelButtonTemplate")
    if findBtn.SetSize then findBtn:SetSize(165, 24) end
    if findBtn.SetPoint then findBtn:SetPoint("TOPLEFT", sideFrame, "TOPLEFT", 12, -52) end
    if findBtn.SetText then findBtn:SetText("Find Top 5 Plays") end
    findBtn:SetScript("OnClick", function()
        if PF.AHVerifier.IsRunning() then
            PF.AHVerifier.Stop("USER_ACCEPTED_TOP5")
        else
            PF.SideWindow.RunSearch()
        end
    end)

    -- Status / Progress Bar
    local statusBar = CreateFrame("StatusBar", "PF_SideWindowProgressBar", sideFrame)
    if statusBar.SetSize then statusBar:SetSize(165, 20) end
    if statusBar.SetPoint then statusBar:SetPoint("LEFT", findBtn, "RIGHT", 6, 0) end
    if statusBar.SetStatusBarTexture then
        statusBar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    end
    if statusBar.SetMinMaxValues then
        statusBar:SetMinMaxValues(0, 1)
        statusBar:SetValue(0)
    end
    if statusBar.SetStatusBarColor then
        statusBar:SetStatusBarColor(0.12, 0.65, 0.40, 0.90)
    end

    local statusText = statusBar.CreateFontString and statusBar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    if statusText then
        if statusText.SetPoint then statusText:SetPoint("CENTER", statusBar, "CENTER", 0, 0) end
        if statusText.SetText then statusText:SetText("Ready") end
    end

    local subBanner = sideFrame.CreateFontString and sideFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    if subBanner then
        if subBanner.SetPoint then subBanner:SetPoint("TOPLEFT", sideFrame, "TOPLEFT", 12, -82) end
        if subBanner.SetText then subBanner:SetText("Top 5 Plays (1 per end-result market — click to expand):") end
    end

    for i = 1, TOP_ROWS do
        local yOff = -102 - ((i - 1) * 50)
        playButtons[i] = CreateOpportunityButton(sideFrame, "PF_SideWindowPlayButton" .. i, yOff, 0.11, 0.13, 0.16)
    end

    -- Honorable Mentions Section Header
    local hmHeader = sideFrame.CreateFontString and sideFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    if hmHeader then
        if hmHeader.SetPoint then hmHeader:SetPoint("TOPLEFT", sideFrame, "TOPLEFT", 12, -360) end
        if hmHeader.SetText then
            hmHeader:SetText("|cffffd100Honorable Mentions (Best Craft & Vendor Plays):|r")
        end
    end

    for i = 1, HM_ROWS do
        local yOff = -380 - ((i - 1) * 50)
        hmButtons[i] = CreateOpportunityButton(sideFrame, "PF_SideWindowHMButton" .. i, yOff, 0.13, 0.11, 0.15)
    end

    sideFrame.infoText = infoText
    sideFrame.findBtn = findBtn
    sideFrame.statusBar = statusBar
    sideFrame.statusText = statusText
    sideFrame.playButtons = playButtons
    sideFrame.hmHeader = hmHeader
    sideFrame.hmButtons = hmButtons

    AnchorToAuctionHouse()
    PF.SideWindow.frame = sideFrame
    return sideFrame
end

local function PopulateRowButton(btn, opp, rankOrPrefix)
    btn._opportunity = opp
    btn:Show()
    local line1
    if type(rankOrPrefix) == "number" then
        line1 = PF.OpportunityEngine.FormatOpportunityLine(rankOrPrefix, opp)
    else
        line1 = PF.OpportunityEngine.FormatOpportunityLine(nil, opp, rankOrPrefix)
    end
    local verTag = opp.verified and "|cff00ff00[Verified]|r" or "|cffffcc00[Cached]|r"
    local recTag = (opp.recipe and opp.recipe.isTrainerRecommendation)
        and string.format(" |cff00ccff[%s]|r", opp.recipe.sourceHint or "Trainer")
        or ""
    local line2 = string.format(
        "   Qty: %dx  |  ROI: %d%%  |  %s%s  —  |cff88ccffClick to expand|r",
        opp.quantity or 1, opp.roiPercent or 0, verTag, recTag
    )
    if btn.mainText then btn.mainText:SetText(line1) end
    if btn.subText then btn.subText:SetText(line2) end
end

function PF.SideWindow.UpdateProgress(currentIdx, totalCount, targetItem)
    if not sideFrame then return end
    if sideFrame.findBtn then
        sideFrame.findBtn:SetText("Accept Top 5 / Stop")
    end
    if sideFrame.statusBar and totalCount and totalCount > 0 then
        sideFrame.statusBar:SetMinMaxValues(0, totalCount)
        sideFrame.statusBar:SetValue(currentIdx)
    end
    if sideFrame.statusText then
        local name = (targetItem and targetItem.name) or "AH"
        sideFrame.statusText:SetText(string.format("Verifying %d/%d: %s", currentIdx or 0, totalCount or 0, name))
    end
    PF.SideWindow.RefreshRows()
end

function PF.SideWindow.RefreshRows()
    if not sideFrame then return end

    local gold = PF.Formatter.GetPlayerGold()
    local recipes = PF.RecipeScanner.GetKnownRecipes()
    local pcfItems = 0
    if _G.PCF_DB and type(_G.PCF_DB.prices) == "table" then
        for _ in pairs(_G.PCF_DB.prices) do pcfItems = pcfItems + 1 end
    end

    if sideFrame.infoText then
        sideFrame.infoText:SetText(string.format(
            "Budget: |cffffd100%s|r  |  Recipes: |cff00ff88%d|r  |  PCF Items: |cff00ccff%d|r",
            PF.Formatter.FormatMoney(gold), #recipes, pcfItems
        ))
    end

    local plays = (Profitable_DB and Profitable_DB.lastTopPlays) or {}
    local hms = (Profitable_DB and Profitable_DB.lastHonorableMentions) or {}

    for i = 1, TOP_ROWS do
        local btn = playButtons[i]
        local opp = plays[i]
        if opp then
            PopulateRowButton(btn, opp, i)
        else
            btn._opportunity = nil
            if i == 1 and #plays == 0 then
                btn:Show()
                if btn.mainText then
                    btn.mainText:SetText("|cffaaaaaaNo profitable plays calculated yet.|r")
                end
                if btn.subText then
                    btn.subText:SetText("Click 'Find Top 5 Plays' (run PCF Scan first if cache is empty).")
                end
            else
                btn:Hide()
            end
        end
    end

    if sideFrame.hmHeader then
        if #hms > 0 then
            if sideFrame.hmHeader.Show then sideFrame.hmHeader:Show() end
        else
            if sideFrame.hmHeader.Hide then sideFrame.hmHeader:Hide() end
        end
    end

    for i = 1, HM_ROWS do
        local btn = hmButtons[i]
        local opp = hms[i]
        if opp then
            local prefix = (opp.hmCategory == "Top Craft") and "|cff00ccff[Craft]|r" or "|cffffd100[Vendor]|r"
            PopulateRowButton(btn, opp, prefix)
        else
            btn._opportunity = nil
            btn:Hide()
        end
    end
end

function PF.SideWindow.Refresh()
    local frame = EnsureSideWindow()
    if PF.AHVerifier.IsRunning() then
        if frame.findBtn then frame.findBtn:SetText("Accept Top 5 / Stop") end
    else
        if frame.findBtn then frame.findBtn:SetText("Find Top 5 Plays") end
        if frame.statusBar then
            frame.statusBar:SetMinMaxValues(0, 1)
            frame.statusBar:SetValue(1)
        end
        if frame.statusText then
            local count = (Profitable_DB and Profitable_DB.lastTopPlays and #Profitable_DB.lastTopPlays) or 0
            frame.statusText:SetText(string.format("Top %d Ready", count))
        end
    end
    PF.SideWindow.RefreshRows()
end

function PF.SideWindow.RunSearch()
    EnsureSideWindow()
    sideFrame:Show()
    if sideFrame.findBtn then sideFrame.findBtn:SetText("Accept Top 5 / Stop") end
    if sideFrame.statusText then sideFrame.statusText:SetText("Calculating plays...") end

    local plays = PF.AHVerifier.StartDiscoveryAndVerification({
        onUpdate = function(idx, total, target)
            PF.SideWindow.UpdateProgress(idx, total, target)
        end,
        onFinish = function()
            PF.SideWindow.Refresh()
        end,
    })
    PF.SideWindow.Refresh()
    return plays
end

function PF.SideWindow.Toggle()
    local frame = EnsureSideWindow()
    if frame.IsShown and frame:IsShown() then
        frame:Hide()
    else
        AnchorToAuctionHouse()
        frame:Show()
        PF.SideWindow.Refresh()
    end
end

function PF.SideWindow.Init()
    if PF.SideWindow._initialized then return end
    PF.SideWindow._initialized = true

    if eventFrame.RegisterEvent then
        pcall(eventFrame.RegisterEvent, eventFrame, "AUCTION_HOUSE_SHOW")
        pcall(eventFrame.RegisterEvent, eventFrame, "AUCTION_HOUSE_CLOSED")
        pcall(eventFrame.RegisterEvent, eventFrame, "PLAYER_MONEY")
        eventFrame:SetScript("OnEvent", function(_, event)
            if event == "AUCTION_HOUSE_SHOW" then
                if not Profitable_DB or not Profitable_DB.settings or Profitable_DB.settings.showSideWindow ~= false then
                    local frame = EnsureSideWindow()
                    AnchorToAuctionHouse()
                    frame:Show()
                    PF.SideWindow.Refresh()
                end
            elseif event == "AUCTION_HOUSE_CLOSED" then
                if PF.AHVerifier.IsRunning() then
                    PF.AHVerifier.Stop("AH_CLOSED")
                end
                if sideFrame then
                    sideFrame:Hide()
                end
            elseif event == "PLAYER_MONEY" then
                if sideFrame and (not sideFrame.IsShown or sideFrame:IsShown()) then
                    PF.SideWindow.RefreshRows()
                end
            end
        end)
    end
    PF.SideWindow.eventFrame = eventFrame
end
