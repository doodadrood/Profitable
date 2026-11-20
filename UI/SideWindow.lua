local PF = _G.PF or {}
_G.PF = PF
_G.Profitable = PF

PF.SideWindow = {}

local sideFrame = nil
local onboardingFrame = nil
local settingsFrame = nil
local eventFrame = CreateFrame("Frame")
local playButtons = {}
local hmButtons = {}
local filterTagButtons = {}
local settingsCheckRows = {}
local TOP_ROWS = 5
local HM_ROWS = 2

local FILTER_TAGS = {
    {
        key = "assumeCanDisenchant",
        frameName = "PF_FilterTag_Disenchant",
        label = "Disenchant",
        defaultVal = true,
        tooltipTitle = "Disenchant Plays ([Buy and DE] / [Craft and DE])",
        tooltipDesc = "Toggle showing plays that require disenchanting uncommon/rare/epic gear. Turn OFF on non-enchanter characters if you don't want to disenchant.",
    },
    {
        key = "showCraftPlays",
        frameName = "PF_FilterTag_Craft",
        label = "Craft",
        defaultVal = true,
        tooltipTitle = "Crafting Plays ([Craft and AH] / [Craft and Vendor])",
        tooltipDesc = "Toggle showing profession crafting plays.",
    },
    {
        key = "showVendorPlays",
        frameName = "PF_FilterTag_Vendor",
        label = "Vendor",
        defaultVal = true,
        tooltipTitle = "Direct Vendor Flips ([Vendor])",
        tooltipDesc = "Toggle showing items listed on the Auction House below their NPC vendor sell price.",
    },
    {
        key = "buyoutOnly",
        frameName = "PF_FilterTag_BuyoutOnly",
        label = "Buyout Only",
        defaultVal = true,
        tooltipTitle = "Buyout Only (Exclude Bid-Only Auctions)",
        tooltipDesc = "When ON, strictly excludes AH listings that only have a bid option and no instant buyout price.",
    },
}

local SETTINGS_OPTIONS = {
    {
        key = "buyoutOnly",
        frameName = "PF_SettingRow_BuyoutOnly",
        label = "Buyout Only (Exclude Bid-Only Auctions)",
        desc = "Ignore AH listings that only have a bid option and no buyout price.",
        defaultVal = true,
    },
    {
        key = "assumeCanDisenchant",
        frameName = "PF_SettingRow_Disenchant",
        label = "Include Disenchant Plays (Buy & DE / Craft & DE)",
        desc = "Uncheck on non-enchanter characters to hide all disenchant plays.",
        defaultVal = true,
    },
    {
        key = "showCraftPlays",
        frameName = "PF_SettingRow_Craft",
        label = "Include Crafting Plays (Craft & AH / Craft & Vendor)",
        desc = "Include profitable crafting plays from your professions.",
        defaultVal = true,
    },
    {
        key = "showVendorPlays",
        frameName = "PF_SettingRow_Vendor",
        label = "Include Direct Vendor Flips (Buy AH -> Sell to NPC)",
        desc = "Include items listed on the AH below their NPC vendor sell price.",
        defaultVal = true,
    },
    {
        key = "includeTrainerRecommendations",
        frameName = "PF_SettingRow_Trainer",
        label = "Include Trainer / Vendor Recipe Recommendations (+25 Skill)",
        desc = "Surface profitable recipes you can learn at a trainer or vendor.",
        defaultVal = true,
    },
    {
        key = "includeAllCharRecipes",
        frameName = "PF_SettingRow_Alts",
        label = "Include All Characters' Known Recipes (Alts)",
        desc = "Use crafting recipes scanned across all characters on your account.",
        defaultVal = false,
    },
    {
        key = "useHistoricalSpikeGuard",
        frameName = "PF_SettingRow_SpikeGuard",
        label = "Historical Spike Protection (14-Day Median Cap)",
        desc = "Cap spiked exit prices when MarketFeed 14-day history is present.",
        defaultVal = true,
    },
}

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

local function IsPCFScannerRunning()
    local btn = _G.PCF and _G.PCF.Scanner and _G.PCF.Scanner.scanButton
    if btn and btn.GetText and btn:GetText() == "Stop Scan" then
        return true
    end
    return false
end

local hookedPCFScanButtons = setmetatable({}, { __mode = "k" })

local function HookPCFScanButtonIfAvailable()
    local btn = _G.PCF and _G.PCF.Scanner and _G.PCF.Scanner.scanButton
    if not btn or hookedPCFScanButtons[btn] or type(btn.SetText) ~= "function" then
        return
    end
    hookedPCFScanButtons[btn] = true
    local function onSetText()
        if sideFrame and (not sideFrame.IsShown or sideFrame:IsShown()) then
            PF.SideWindow.Refresh()
        elseif onboardingFrame and (not onboardingFrame.IsShown or onboardingFrame:IsShown()) then
            PF.SideWindow.RefreshOnboardingPopup()
        end
    end
    if _G.hooksecurefunc then
        pcall(_G.hooksecurefunc, btn, "SetText", onSetText)
    else
        local origSetText = btn.SetText
        btn.SetText = function(self, text, ...)
            local res = origSetText(self, text, ...)
            onSetText()
            return res
        end
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
        if mainText.SetPoint then mainText:SetPoint("TOPLEFT", btn, "TOPLEFT", 8, -6) end
        if mainText.SetWidth then mainText:SetWidth(320) end
        if mainText.SetJustifyH then mainText:SetJustifyH("LEFT") end
        if mainText.SetWordWrap then pcall(mainText.SetWordWrap, mainText, false) end
    end

    local subText = btn.CreateFontString and btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    if subText then
        if subText.SetPoint then subText:SetPoint("TOPLEFT", mainText, "BOTTOMLEFT", 0, -4) end
        if subText.SetWidth then subText:SetWidth(320) end
        if subText.SetJustifyH then subText:SetJustifyH("LEFT") end
        if subText.SetWordWrap then pcall(subText.SetWordWrap, subText, false) end
    end

    btn:SetScript("OnClick", function()
        if btn._opportunity then
            PF.DetailWindow.ShowOpportunity(btn._opportunity)
        elseif btn._needsAHScan then
            PF.SideWindow.TriggerAHScan()
        end
    end)

    btn:SetScript("OnEnter", function(self)
        if not _G.GameTooltip then return end
        if btn._opportunity then
            local opp = btn._opportunity
            _G.GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            _G.GameTooltip:AddLine(opp.summaryLine or opp.itemName, 0, 1, 0.5)
            if opp.explanation then
                _G.GameTooltip:AddLine(opp.explanation, 1, 1, 1, true)
            end
            _G.GameTooltip:AddLine(" ")
            _G.GameTooltip:AddLine("|cff00ff88Click to open Shopping List & Breakdown|r", 0.2, 1, 0.6)
            _G.GameTooltip:Show()
        elseif btn._needsAHScan then
            _G.GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            _G.GameTooltip:AddLine("Auction House Scan Required", 1, 0.8, 0.2)
            _G.GameTooltip:AddLine("Profitable needs fresh Auction House price data before it can calculate profitable plays.", 1, 1, 1, true)
            _G.GameTooltip:AddLine(" ")
            if PF.AHVerifier and PF.AHVerifier.IsAuctionHouseOpen and PF.AHVerifier.IsAuctionHouseOpen() then
                _G.GameTooltip:AddLine("|cff00ff88Click to start an Auction House scan now|r", 0.2, 1, 0.6)
            else
                _G.GameTooltip:AddLine("|cffffcc00Open the Auction House at any Auctioneer to scan|r", 1, 0.8, 0.2)
            end
            _G.GameTooltip:Show()
        end
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

local function EnsureOnboardingPopup()
    if onboardingFrame then
        return onboardingFrame
    end

    onboardingFrame = CreateFrame("Frame", "PF_OnboardingPopup", _G.UIParent)
    if onboardingFrame.SetSize then onboardingFrame:SetSize(440, 250) end
    if onboardingFrame.SetPoint then onboardingFrame:SetPoint("CENTER", _G.UIParent, "CENTER", 0, 60) end
    if onboardingFrame.SetFrameStrata then onboardingFrame:SetFrameStrata("DIALOG") end
    if onboardingFrame.SetMovable then onboardingFrame:SetMovable(true) end
    if onboardingFrame.EnableMouse then onboardingFrame:EnableMouse(true) end
    if onboardingFrame.RegisterForDrag then onboardingFrame:RegisterForDrag("LeftButton") end
    onboardingFrame:SetScript("OnDragStart", function(self)
        if self.StartMoving then self:StartMoving() end
    end)
    onboardingFrame:SetScript("OnDragStop", function(self)
        if self.StopMovingOrSizing then self:StopMovingOrSizing() end
    end)

    SetBackdropSafe(onboardingFrame, 0.05, 0.06, 0.09, 0.97)

    local title = onboardingFrame.CreateFontString and onboardingFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    if title then
        if title.SetPoint then title:SetPoint("TOPLEFT", onboardingFrame, "TOPLEFT", 16, -14) end
        if title.SetText then title:SetText("|cff00ff88Welcome to Profitable!|r — AH Scan Required") end
    end

    local closeBtn = CreateFrame("Button", "PF_OnboardingCloseButton", onboardingFrame, "UIPanelCloseButton")
    if closeBtn.SetPoint then closeBtn:SetPoint("TOPRIGHT", onboardingFrame, "TOPRIGHT", -4, -4) end
    closeBtn:SetScript("OnClick", function()
        onboardingFrame:Hide()
    end)

    local bodyText = onboardingFrame.CreateFontString and onboardingFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    if bodyText then
        if bodyText.SetPoint then bodyText:SetPoint("TOPLEFT", onboardingFrame, "TOPLEFT", 16, -44) end
        if bodyText.SetWidth then bodyText:SetWidth(408) end
        if bodyText.SetJustifyH then bodyText:SetJustifyH("LEFT") end
        if bodyText.SetJustifyV then bodyText:SetJustifyV("TOP") end
        if bodyText.SetText then
            bodyText:SetText(
                "|cffffcc00Profitable will not function until it has Auction House price data.|r\n\n"
                .. "|cff00ff881.|r Visit any Auctioneer and open the |cffffd100Auction House|r.\n"
                .. "|cff00ff882.|r Click |cff00ff88Scan AH Now|r in Profitable (or |cff00ff88PCF Scan|r in the top-right of the AH) and let the scan reach 100%.\n"
                .. "|cff00ff883.|r Open your profession windows once to scan recipes, then click |cff00ff88Find Top 5 Plays|r (or type |cff00ff88/pf|r)."
            )
        end
    end

    local statusText = onboardingFrame.CreateFontString and onboardingFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    if statusText then
        if statusText.SetPoint then statusText:SetPoint("BOTTOMLEFT", onboardingFrame, "BOTTOMLEFT", 16, 48) end
        if statusText.SetWidth then statusText:SetWidth(408) end
        if statusText.SetJustifyH then statusText:SetJustifyH("LEFT") end
    end

    local acceptBtn = CreateFrame("Button", "PF_OnboardingAcceptButton", onboardingFrame, "UIPanelButtonTemplate")
    if acceptBtn.SetSize then acceptBtn:SetSize(210, 26) end
    if acceptBtn.SetPoint then acceptBtn:SetPoint("BOTTOM", onboardingFrame, "BOTTOM", 0, 14) end
    if acceptBtn.SetText then acceptBtn:SetText("OK, Got It! (Don't Show Again)") end
    acceptBtn:SetScript("OnClick", function()
        PF.SideWindow.DismissOnboardingPopup()
    end)

    onboardingFrame.title = title
    onboardingFrame.bodyText = bodyText
    onboardingFrame.statusText = statusText
    onboardingFrame.acceptBtn = acceptBtn
    onboardingFrame.closeBtn = closeBtn

    onboardingFrame:Hide()
    PF.SideWindow.onboardingFrame = onboardingFrame
    return onboardingFrame
end

function PF.SideWindow.RefreshOnboardingPopup()
    if not onboardingFrame then return end
    local status, info = PF.GetAHDataStatus and PF.GetAHDataStatus() or "NO_DATA", { itemCount = 0, ageText = "never" }
    if PF.GetAHDataStatus then
        status, info = PF.GetAHDataStatus()
    end
    if onboardingFrame.statusText then
        if status == "NO_DATA" then
            onboardingFrame.statusText:SetText("|cffff5555Current Status: No Auction House scan data found yet (0 items).|r")
        elseif status == "STALE" then
            onboardingFrame.statusText:SetText(string.format("|cffff9900Current Status: Auction House data is stale (%s old — please rescan at the AH).|r", info.ageText or "24h+"))
        else
            onboardingFrame.statusText:SetText(string.format("|cff00ff88Current Status: Auction House data ready (%d items, %s old).|r", info.itemCount or 0, info.ageText or "0m"))
        end
    end
end

function PF.SideWindow.ShowOnboardingPopup(forceShow)
    if not forceShow and Profitable_DB and Profitable_DB.settings and Profitable_DB.settings.onboardingDismissed == true then
        return false
    end
    local popup = EnsureOnboardingPopup()
    PF.SideWindow.RefreshOnboardingPopup()
    popup:Show()
    return true
end

function PF.SideWindow.DismissOnboardingPopup()
    if Profitable_DB and Profitable_DB.settings then
        Profitable_DB.settings.onboardingDismissed = true
    end
    if onboardingFrame then
        onboardingFrame:Hide()
    end
end

function PF.SideWindow.TriggerAHScan()
    local ahOpen = PF.AHVerifier and PF.AHVerifier.IsAuctionHouseOpen and PF.AHVerifier.IsAuctionHouseOpen()
    if not ahOpen then
        PF.SideWindow.ShowOnboardingPopup(true)
        print("|cffffcc00[Profitable]|r You must open the Auction House at an Auctioneer first, then click 'Scan AH Now' (or 'PCF Scan').")
        return false
    end

    if _G.PCF_DB and type(_G.PCF_DB.settings) == "table" then
        _G.PCF_DB.settings.showScanButton = true
    end

    if _G.PCF and _G.PCF.Scanner and type(_G.PCF.Scanner.StartScan) == "function" then
        _G.PCF.Scanner.StartScan()
        HookPCFScanButtonIfAvailable()
        PF.SideWindow.Refresh()
        return true
    end

    print("|cffff5555[Profitable]|r PriceCheckerForever scanner is not ready. Try /reload.")
    return false
end

local function GetSettingBool(key, defaultVal)
    local s = Profitable_DB and Profitable_DB.settings
    if not s or s[key] == nil then
        return defaultVal == true
    end
    return s[key] == true
end

local function SetTagButtonVisual(btn, label, isEnabled)
    if not btn then return end
    if btn._pfBg then
        if isEnabled then
            if btn._pfBg.SetColorTexture then
                btn._pfBg:SetColorTexture(0.08, 0.34, 0.22, 0.95)
            elseif btn._pfBg.SetTexture then
                btn._pfBg:SetTexture(0.08, 0.34, 0.22, 0.95)
            end
        else
            if btn._pfBg.SetColorTexture then
                btn._pfBg:SetColorTexture(0.14, 0.14, 0.16, 0.85)
            elseif btn._pfBg.SetTexture then
                btn._pfBg:SetTexture(0.14, 0.14, 0.16, 0.85)
            end
        end
    end
    local formatted = isEnabled
        and string.format("|cff00ff88[%s]|r", label)
        or string.format("|cff777777[%s]|r", label)
    if btn.SetText then
        btn:SetText(formatted)
    end
    if btn.labelText and btn.labelText.SetText then
        btn.labelText:SetText(formatted)
    end
end

function PF.SideWindow.RefreshFilterControls()
    for _, tag in ipairs(FILTER_TAGS) do
        local btn = filterTagButtons[tag.key]
        if btn then
            local enabled = GetSettingBool(tag.key, tag.defaultVal)
            SetTagButtonVisual(btn, tag.label, enabled)
        end
    end
    for _, opt in ipairs(SETTINGS_OPTIONS) do
        local row = settingsCheckRows[opt.key]
        if row then
            local enabled = GetSettingBool(opt.key, opt.defaultVal)
            local box = enabled and "|cff00ff88[ON]|r" or "|cff777777[OFF]|r"
            local text = string.format("%s  %s", box, opt.label)
            if row.SetText then row:SetText(text) end
            if row.titleText and row.titleText.SetText then
                row.titleText:SetText(text)
            end
            if row._pfBg then
                local r, g, b = enabled and 0.10 or 0.12, enabled and 0.22 or 0.13, enabled and 0.16 or 0.15
                if row._pfBg.SetColorTexture then
                    row._pfBg:SetColorTexture(r, g, b, 0.92)
                elseif row._pfBg.SetTexture then
                    row._pfBg:SetTexture(r, g, b, 0.92)
                end
            end
        end
    end
end

function PF.SideWindow.ApplyFilterChange()
    PF.SideWindow.RefreshFilterControls()
    local status = (PF.GetAHDataStatus and PF.GetAHDataStatus()) or "FRESH"
    if status == "FRESH" and not PF.AHVerifier.IsRunning() and PF.AHVerifier.RecalculateFromCache then
        PF.AHVerifier.RecalculateFromCache()
    end
    if sideFrame and (not sideFrame.IsShown or sideFrame:IsShown()) then
        PF.SideWindow.Refresh()
    end
    if PF.DetailWindow and PF.DetailWindow.RefreshIfShown then
        PF.DetailWindow.RefreshIfShown()
    end
end

function PF.SideWindow.ToggleSetting(key, defaultVal)
    Profitable_DB = Profitable_DB or {}
    Profitable_DB.settings = Profitable_DB.settings or {}
    local cur = GetSettingBool(key, defaultVal)
    Profitable_DB.settings[key] = not cur
    PF.SideWindow.ApplyFilterChange()
    return Profitable_DB.settings[key]
end

local function EnsureSettingsWindow()
    if settingsFrame then
        return settingsFrame
    end

    settingsFrame = CreateFrame("Frame", "PF_SettingsWindow", _G.UIParent)
    if settingsFrame.SetSize then settingsFrame:SetSize(410, 385) end
    if settingsFrame.SetPoint then settingsFrame:SetPoint("CENTER", _G.UIParent, "CENTER", 0, 20) end
    if settingsFrame.SetFrameStrata then settingsFrame:SetFrameStrata("DIALOG") end
    if settingsFrame.SetMovable then settingsFrame:SetMovable(true) end
    if settingsFrame.EnableMouse then settingsFrame:EnableMouse(true) end
    if settingsFrame.RegisterForDrag then settingsFrame:RegisterForDrag("LeftButton") end
    settingsFrame:SetScript("OnDragStart", function(self)
        if self.StartMoving then self:StartMoving() end
    end)
    settingsFrame:SetScript("OnDragStop", function(self)
        if self.StopMovingOrSizing then self:StopMovingOrSizing() end
    end)

    SetBackdropSafe(settingsFrame, 0.05, 0.06, 0.09, 0.97)

    local title = settingsFrame.CreateFontString and settingsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    if title then
        if title.SetPoint then title:SetPoint("TOPLEFT", settingsFrame, "TOPLEFT", 14, -12) end
        if title.SetText then title:SetText("|cff00ff88Profitable|r — Filter & Play Options") end
    end

    local closeBtn = CreateFrame("Button", "PF_SettingsCloseButton", settingsFrame, "UIPanelCloseButton")
    if closeBtn.SetPoint then closeBtn:SetPoint("TOPRIGHT", settingsFrame, "TOPRIGHT", -4, -4) end
    closeBtn:SetScript("OnClick", function()
        settingsFrame:Hide()
    end)

    local subtitle = settingsFrame.CreateFontString and settingsFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    if subtitle then
        if subtitle.SetPoint then subtitle:SetPoint("TOPLEFT", settingsFrame, "TOPLEFT", 14, -34) end
        if subtitle.SetText then subtitle:SetText("Click any option below (or the tag bubbles on the Side Window) to filter plays:") end
    end

    for idx, opt in ipairs(SETTINGS_OPTIONS) do
        local yOff = -56 - ((idx - 1) * 40)
        local row = CreateFrame("Button", opt.frameName, settingsFrame)
        if row.SetSize then row:SetSize(382, 36) end
        if row.SetPoint then row:SetPoint("TOPLEFT", settingsFrame, "TOPLEFT", 14, yOff) end
        SetBackdropSafe(row, 0.11, 0.13, 0.16, 0.92)

        local titleText = row.CreateFontString and row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        if titleText then
            if titleText.SetPoint then titleText:SetPoint("TOPLEFT", row, "TOPLEFT", 8, -4) end
            if titleText.SetWidth then titleText:SetWidth(366) end
            if titleText.SetJustifyH then titleText:SetJustifyH("LEFT") end
        end

        local descText = row.CreateFontString and row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        if descText then
            if descText.SetPoint then descText:SetPoint("TOPLEFT", titleText, "BOTTOMLEFT", 0, -2) end
            if descText.SetWidth then descText:SetWidth(366) end
            if descText.SetJustifyH then descText:SetJustifyH("LEFT") end
            if descText.SetText then descText:SetText("|cffaaaaaa" .. opt.desc .. "|r") end
        end

        row:SetScript("OnClick", function()
            PF.SideWindow.ToggleSetting(opt.key, opt.defaultVal)
        end)

        row.titleText = titleText
        row.descText = descText
        settingsCheckRows[opt.key] = row
    end

    local resetBtn = CreateFrame("Button", "PF_SettingsResetButton", settingsFrame, "UIPanelButtonTemplate")
    if resetBtn.SetSize then resetBtn:SetSize(160, 24) end
    if resetBtn.SetPoint then resetBtn:SetPoint("BOTTOMLEFT", settingsFrame, "BOTTOMLEFT", 14, 12) end
    if resetBtn.SetText then resetBtn:SetText("Reset Filter Defaults") end
    resetBtn:SetScript("OnClick", function()
        Profitable_DB = Profitable_DB or {}
        Profitable_DB.settings = Profitable_DB.settings or {}
        for _, opt in ipairs(SETTINGS_OPTIONS) do
            Profitable_DB.settings[opt.key] = opt.defaultVal
        end
        PF.SideWindow.ApplyFilterChange()
    end)

    local doneBtn = CreateFrame("Button", "PF_SettingsDoneButton", settingsFrame, "UIPanelButtonTemplate")
    if doneBtn.SetSize then doneBtn:SetSize(110, 24) end
    if doneBtn.SetPoint then doneBtn:SetPoint("BOTTOMRIGHT", settingsFrame, "BOTTOMRIGHT", -14, 12) end
    if doneBtn.SetText then doneBtn:SetText("Done") end
    doneBtn:SetScript("OnClick", function()
        settingsFrame:Hide()
    end)

    settingsFrame:Hide()
    PF.SideWindow.settingsFrame = settingsFrame
    PF.SideWindow.RefreshFilterControls()
    return settingsFrame
end

function PF.SideWindow.ToggleSettingsWindow()
    local frame = EnsureSettingsWindow()
    if frame.IsShown and frame:IsShown() then
        frame:Hide()
    else
        PF.SideWindow.RefreshFilterControls()
        frame:Show()
    end
end

local function EnsureSideWindow()
    if sideFrame then
        AnchorToAuctionHouse()
        return sideFrame
    end

    sideFrame = CreateFrame("Frame", "PF_AuctionSideWindow", _G.UIParent)
    if sideFrame.SetSize then sideFrame:SetSize(360, 530) end
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

    local settingsBtn = CreateFrame("Button", "PF_SideWindowSettingsButton", sideFrame, "UIPanelButtonTemplate")
    if settingsBtn.SetSize then settingsBtn:SetSize(64, 20) end
    if settingsBtn.SetPoint then settingsBtn:SetPoint("TOPRIGHT", sideFrame, "TOPRIGHT", -30, -7) end
    if settingsBtn.SetText then settingsBtn:SetText("Options") end
    settingsBtn:SetScript("OnClick", function()
        PF.SideWindow.ToggleSettingsWindow()
    end)
    settingsBtn:SetScript("OnEnter", function(self)
        if not _G.GameTooltip then return end
        _G.GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        _G.GameTooltip:AddLine("Profitable Filter & Play Options", 0, 1, 0.5)
        _G.GameTooltip:AddLine("Open the settings panel to configure Buyout-Only filtering, Disenchant/Craft/Vendor play toggles, and Trainer/Alt recipe options.", 1, 1, 1, true)
        _G.GameTooltip:Show()
    end)
    settingsBtn:SetScript("OnLeave", function()
        if _G.GameTooltip then _G.GameTooltip:Hide() end
    end)

    -- Gold & Known Recipes info line
    local infoText = sideFrame.CreateFontString and sideFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    if infoText then
        if infoText.SetPoint then infoText:SetPoint("TOPLEFT", sideFrame, "TOPLEFT", 12, -32) end
    end

    -- Primary Run / Stop / Scan Button
    local findBtn = CreateFrame("Button", "PF_FindOpportunitiesButton", sideFrame, "UIPanelButtonTemplate")
    if findBtn.SetSize then findBtn:SetSize(165, 24) end
    if findBtn.SetPoint then findBtn:SetPoint("TOPLEFT", sideFrame, "TOPLEFT", 12, -52) end
    if findBtn.SetText then findBtn:SetText("Find Top 5 Plays") end
    findBtn:SetScript("OnClick", function()
        if PF.AHVerifier.IsRunning() then
            PF.AHVerifier.Stop("USER_ACCEPTED_TOP5")
            return
        end
        local forceLive = (_G.IsShiftKeyDown and _G.IsShiftKeyDown()) == true
        local status = (PF.GetAHDataStatus and PF.GetAHDataStatus()) or "FRESH"
        if status == "NO_DATA" or (status == "STALE" and not forceLive) then
            PF.SideWindow.TriggerAHScan()
            return
        end
        PF.SideWindow.RunSearch(forceLive)
    end)
    findBtn:SetScript("OnEnter", function(self)
        if not _G.GameTooltip then return end
        local status, info = "FRESH", nil
        if PF.GetAHDataStatus then
            status, info = PF.GetAHDataStatus()
        end
        _G.GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if status == "NO_DATA" then
            _G.GameTooltip:AddLine("Auction House Scan Required", 1, 0.8, 0.2)
            _G.GameTooltip:AddLine("No Auction House price data is cached yet. Click to start an AH scan while at the Auction House.", 1, 1, 1, true)
        elseif status == "STALE" then
            _G.GameTooltip:AddLine(string.format("Auction House Data Stale (%s old)", (info and info.ageText) or "24h+"), 1, 0.6, 0.2)
            _G.GameTooltip:AddLine("Click: Start a fresh Auction House scan so plays use current prices.", 1, 1, 1, true)
            _G.GameTooltip:AddLine("Shift-Click: Force live AH verification using existing candidates.", 0.7, 0.85, 1, true)
        else
            _G.GameTooltip:AddLine("Find Top 5 Plays", 0, 1, 0.5)
            _G.GameTooltip:AddLine("Click: Calculate and verify the Top 5 plays on the live Auction House.", 1, 1, 1, true)
            _G.GameTooltip:AddLine("Shift-Click: Force live AH verification queries for all candidates.", 0.7, 0.85, 1, true)
        end
        _G.GameTooltip:Show()
    end)
    findBtn:SetScript("OnLeave", function()
        if _G.GameTooltip then _G.GameTooltip:Hide() end
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

    -- Quick-Toggle Filter Tag Bubbles Bar ([Disenchant] [Craft] [Vendor] [Buyout Only])
    for idx, tag in ipairs(FILTER_TAGS) do
        local xOff = 12 + ((idx - 1) * 85)
        local pill = CreateFrame("Button", tag.frameName, sideFrame)
        if pill.SetSize then pill:SetSize(81, 20) end
        if pill.SetPoint then pill:SetPoint("TOPLEFT", sideFrame, "TOPLEFT", xOff, -80) end
        SetBackdropSafe(pill, 0.08, 0.34, 0.22, 0.95)

        local labelText = pill.CreateFontString and pill:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        if labelText then
            if labelText.SetPoint then labelText:SetPoint("CENTER", pill, "CENTER", 0, 0) end
        end
        pill.labelText = labelText

        pill:SetScript("OnClick", function()
            PF.SideWindow.ToggleSetting(tag.key, tag.defaultVal)
        end)
        pill:SetScript("OnEnter", function(self)
            if not _G.GameTooltip then return end
            local enabled = GetSettingBool(tag.key, tag.defaultVal)
            _G.GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            _G.GameTooltip:AddLine(tag.tooltipTitle, 0, 1, 0.5)
            _G.GameTooltip:AddLine(tag.tooltipDesc, 1, 1, 1, true)
            _G.GameTooltip:AddLine(" ")
            _G.GameTooltip:AddLine(string.format("Current: %s — |cff00ff88Click to toggle|r", enabled and "|cff00ff00ON|r" or "|cffff5555OFF|r"), 0.8, 0.8, 0.8)
            _G.GameTooltip:Show()
        end)
        pill:SetScript("OnLeave", function()
            if _G.GameTooltip then _G.GameTooltip:Hide() end
        end)

        filterTagButtons[tag.key] = pill
    end

    local subBanner = sideFrame.CreateFontString and sideFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    if subBanner then
        if subBanner.SetPoint then subBanner:SetPoint("TOPLEFT", sideFrame, "TOPLEFT", 12, -106) end
        if subBanner.SetText then subBanner:SetText("Top 5 Plays (1 per end-result market — click to expand):") end
    end

    for i = 1, TOP_ROWS do
        local yOff = -126 - ((i - 1) * 50)
        playButtons[i] = CreateOpportunityButton(sideFrame, "PF_SideWindowPlayButton" .. i, yOff, 0.11, 0.13, 0.16)
    end

    -- Honorable Mentions Section Header
    local hmHeader = sideFrame.CreateFontString and sideFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    if hmHeader then
        if hmHeader.SetPoint then hmHeader:SetPoint("TOPLEFT", sideFrame, "TOPLEFT", 12, -384) end
        if hmHeader.SetText then
            hmHeader:SetText("|cffffd100Honorable Mentions (Best Craft & Vendor Plays):|r")
        end
    end

    for i = 1, HM_ROWS do
        local yOff = -404 - ((i - 1) * 50)
        hmButtons[i] = CreateOpportunityButton(sideFrame, "PF_SideWindowHMButton" .. i, yOff, 0.13, 0.11, 0.15)
    end

    sideFrame.infoText = infoText
    sideFrame.findBtn = findBtn
    sideFrame.settingsBtn = settingsBtn
    sideFrame.statusBar = statusBar
    sideFrame.statusText = statusText
    sideFrame.subBanner = subBanner
    sideFrame.playButtons = playButtons
    sideFrame.hmHeader = hmHeader
    sideFrame.hmButtons = hmButtons
    sideFrame.filterTagButtons = filterTagButtons

    PF.SideWindow.RefreshFilterControls()
    AnchorToAuctionHouse()
    PF.SideWindow.frame = sideFrame
    return sideFrame
end

local function PopulateRowButton(btn, opp, rankOrPrefix)
    btn._opportunity = opp
    btn._needsAHScan = false
    btn:Show()
    local line1
    if type(rankOrPrefix) == "number" then
        line1 = PF.OpportunityEngine.FormatOpportunityLine(rankOrPrefix, opp)
    else
        line1 = PF.OpportunityEngine.FormatOpportunityLine(nil, opp, rankOrPrefix)
    end
    local verTag = opp.verified and "|cff00ff00[Verified]|r" or "|cffffcc00[Cached]|r"
    local spikeTag = opp.spikeInfo and " |cffff6600[Spike Cap]|r" or ""
    local recTag = (opp.recipe and opp.recipe.isTrainerRecommendation)
        and string.format(" |cff00ccff[%s]|r", opp.recipe.sourceHint or "Trainer")
        or ""
    local line2 = string.format(
        "   Qty: %dx  |  ROI: %d%%  |  %s%s%s  —  |cff88ccffClick to expand|r",
        opp.quantity or 1, opp.roiPercent or 0, verTag, spikeTag, recTag
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
    local dataStatus, dataInfo = "FRESH", { itemCount = 0, pcfItems = 0, ageText = "0m" }
    if PF.GetAHDataStatus then
        dataStatus, dataInfo = PF.GetAHDataStatus()
    end
    local pcfItems = dataInfo.itemCount or 0

    if sideFrame.infoText then
        local feedAgeSec = PF.MarketFeed and PF.MarketFeed.GetFeedAgeSeconds and PF.MarketFeed.GetFeedAgeSeconds()
        local feedNote = ""
        if type(feedAgeSec) == "number" then
            local mins = math.floor(feedAgeSec / 60)
            local ageLabel = (mins >= 60) and string.format("%dh", math.floor(mins / 60)) or string.format("%dm", mins)
            feedNote = string.format("  |  |cff00ff88Feed: %s|r", ageLabel)
        end
        local itemsLabel
        if dataStatus == "NO_DATA" then
            itemsLabel = "|cffff55550 (No Scan)|r"
        elseif dataStatus == "STALE" then
            itemsLabel = string.format("|cffff9900%d (Stale: %s)|r", pcfItems, dataInfo.ageText or "24h+")
        else
            itemsLabel = string.format("|cff00ccff%d|r", pcfItems)
        end
        sideFrame.infoText:SetText(string.format(
            "Budget: |cffffd100%s|r  |  Recipes: |cff00ff88%d|r  |  Items: %s%s",
            PF.Formatter.FormatMoney(gold), #recipes, itemsLabel, feedNote
        ))
    end

    -- When AH data is missing or very stale (>24h), do NOT display old/stale plays;
    -- instead direct the user to run an AH scan first.
    if dataStatus == "NO_DATA" or dataStatus == "STALE" then
        local ahOpen = PF.AHVerifier and PF.AHVerifier.IsAuctionHouseOpen and PF.AHVerifier.IsAuctionHouseOpen()
        local pcfScanning = IsPCFScannerRunning()

        if sideFrame.subBanner then
            if dataStatus == "NO_DATA" then
                sideFrame.subBanner:SetText("|cffffcc00Auction House Scan Required Before Calculating Plays:|r")
            else
                sideFrame.subBanner:SetText(string.format("|cffff9900Auction House Data Is Stale (%s old) — Rescan Required:|r", dataInfo.ageText or "24h+"))
            end
        end

        local btn1 = playButtons[1]
        if btn1 then
            btn1._opportunity = nil
            btn1._needsAHScan = true
            btn1:Show()
            if pcfScanning then
                if btn1.mainText then
                    btn1.mainText:SetText("|cff00ccffAuction House Scan in Progress...|r")
                end
                if btn1.subText then
                    btn1.subText:SetText("Wait for PCF Scan to reach 100%, then click 'Find Top 5 Plays'.")
                end
            elseif dataStatus == "NO_DATA" then
                if btn1.mainText then
                    btn1.mainText:SetText("|cffffcc00Scan Required: No Auction House Data Found!|r")
                end
                if btn1.subText then
                    if ahOpen then
                        btn1.subText:SetText("Click here or 'Scan AH Now' above (or 'PCF Scan' on the AH) to scan.")
                    else
                        btn1.subText:SetText("Open the Auction House at an Auctioneer and click 'Scan AH Now'.")
                    end
                end
            else
                if btn1.mainText then
                    btn1.mainText:SetText(string.format("|cffff9900AH Data is Stale (%s old) — Old Plays Hidden|r", dataInfo.ageText or "24h+"))
                end
                if btn1.subText then
                    if ahOpen then
                        btn1.subText:SetText("Click here or 'Scan AH Now' above (or 'PCF Scan') to refresh prices.")
                    else
                        btn1.subText:SetText("Open the Auction House at an Auctioneer and run a fresh scan.")
                    end
                end
            end
        end

        for i = 2, TOP_ROWS do
            if playButtons[i] then
                playButtons[i]._opportunity = nil
                playButtons[i]._needsAHScan = false
                playButtons[i]:Hide()
            end
        end

        if sideFrame.hmHeader and sideFrame.hmHeader.Hide then
            sideFrame.hmHeader:Hide()
        end
        for i = 1, HM_ROWS do
            if hmButtons[i] then
                hmButtons[i]._opportunity = nil
                hmButtons[i]._needsAHScan = false
                hmButtons[i]:Hide()
            end
        end
        return
    end

    if sideFrame.subBanner then
        sideFrame.subBanner:SetText("Top 5 Plays (1 per end-result market — click to expand):")
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
            btn._needsAHScan = false
            if i == 1 and #plays == 0 then
                btn:Show()
                if btn.mainText then
                    btn.mainText:SetText("|cffaaaaaaNo profitable plays calculated yet.|r")
                end
                if btn.subText then
                    btn.subText:SetText("Click 'Find Top 5 Plays' above to calculate your best plays.")
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
            btn._needsAHScan = false
            btn:Hide()
        end
    end
end

function PF.SideWindow.Refresh()
    local frame = EnsureSideWindow()
    HookPCFScanButtonIfAvailable()
    PF.SideWindow.RefreshFilterControls()

    if PF.AHVerifier.IsRunning() then
        if frame.findBtn then frame.findBtn:SetText("Accept Top 5 / Stop") end
    else
        local dataStatus, dataInfo = "FRESH", { ageText = "0m" }
        if PF.GetAHDataStatus then
            dataStatus, dataInfo = PF.GetAHDataStatus()
        end
        local ahOpen = PF.AHVerifier and PF.AHVerifier.IsAuctionHouseOpen and PF.AHVerifier.IsAuctionHouseOpen()
        local pcfScanning = IsPCFScannerRunning()

        if pcfScanning then
            if frame.findBtn then frame.findBtn:SetText("Scanning AH...") end
            if frame.statusBar then
                frame.statusBar:SetMinMaxValues(0, 1)
                frame.statusBar:SetValue(0)
            end
            if frame.statusText then
                frame.statusText:SetText("PCF Scan Running")
            end
        elseif dataStatus == "NO_DATA" then
            if frame.findBtn then
                frame.findBtn:SetText(ahOpen and "Scan AH Now" or "AH Scan Needed")
            end
            if frame.statusBar then
                frame.statusBar:SetMinMaxValues(0, 1)
                frame.statusBar:SetValue(0)
            end
            if frame.statusText then
                frame.statusText:SetText("No AH Data")
            end
        elseif dataStatus == "STALE" then
            if frame.findBtn then
                frame.findBtn:SetText(ahOpen and "Scan AH Now" or "AH Data Stale")
            end
            if frame.statusBar then
                frame.statusBar:SetMinMaxValues(0, 1)
                frame.statusBar:SetValue(0)
            end
            if frame.statusText then
                frame.statusText:SetText("Stale (" .. (dataInfo.ageText or "24h+") .. ")")
            end
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
    end
    PF.SideWindow.RefreshRows()
    PF.SideWindow.RefreshOnboardingPopup()
end

function PF.SideWindow.RunSearch(forceLiveVerify)
    EnsureSideWindow()
    sideFrame:Show()

    local dataStatus, dataInfo = "FRESH", { ageText = "0m" }
    if PF.GetAHDataStatus then
        dataStatus, dataInfo = PF.GetAHDataStatus()
    end

    if dataStatus == "NO_DATA" then
        if Profitable_DB then
            Profitable_DB.lastTopPlays = {}
            Profitable_DB.lastHonorableMentions = {}
        end
        PF.SideWindow.Refresh()
        PF.SideWindow.ShowOnboardingPopup(false)
        print("|cffffcc00[Profitable]|r Cannot calculate plays yet: No Auction House price data found! Visit an Auctioneer, open the AH, and click 'Scan AH Now' (or 'PCF Scan') first.")
        return {}
    elseif dataStatus == "STALE" and not forceLiveVerify then
        if Profitable_DB then
            Profitable_DB.lastTopPlays = {}
            Profitable_DB.lastHonorableMentions = {}
        end
        PF.SideWindow.Refresh()
        print(string.format("|cffff9900[Profitable]|r Auction House data is stale (%s old). Open the Auction House and click 'Scan AH Now' (or 'PCF Scan') to refresh prices first.", dataInfo.ageText or "24h+"))
        return {}
    end

    if sideFrame.findBtn then sideFrame.findBtn:SetText("Accept Top 5 / Stop") end
    if sideFrame.statusText then sideFrame.statusText:SetText("Calculating plays...") end

    local plays = PF.AHVerifier.StartDiscoveryAndVerification({
        forceLiveVerify = (forceLiveVerify == true),
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
        local dataStatus, dataInfo = "FRESH", nil
        if PF.GetAHDataStatus then
            dataStatus, dataInfo = PF.GetAHDataStatus()
        end
        if dataStatus == "NO_DATA" then
            print("|cffffcc00[Profitable]|r No Auction House price data found yet. Visit an Auctioneer, open the AH, and click 'Scan AH Now' (or 'PCF Scan') to get started.")
        elseif dataStatus == "STALE" then
            print(string.format("|cffff9900[Profitable]|r Your Auction House scan data is stale (%s old). Visit the Auction House and click 'Scan AH Now' for fresh plays.", (dataInfo and dataInfo.ageText) or "24h+"))
        end
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
                HookPCFScanButtonIfAvailable()
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
