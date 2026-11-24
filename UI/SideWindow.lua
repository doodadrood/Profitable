local PF = _G.PF or {}
_G.PF = PF
_G.Profitable = PF

PF.SideWindow = {}

local sideFrame = nil
local onboardingFrame = nil
local settingsFrame = nil
local snoozedFrame = nil
local ahToggleButton = nil
local minimapButton = nil
local minimapUsesLibDBIcon = false
local eventFrame = CreateFrame("Frame")
local playButtons = {}
local hmButtons = {}
local filterTagButtons = {}
local settingsCheckRows = {}
local priceSourceButtons = {}
local snoozedRows = {}
local TOP_ROWS = 5
local HM_ROWS = 2
local MAX_SNOOZED_ROWS = 12

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
        key = "showSideWindow",
        frameName = "PF_SettingRow_AutoOpen",
        label = "Auto-Open Side Window at Auction House",
        desc = "Uncheck to keep Profitable hidden at the AH until you click the Profitable button or /pf.",
        defaultVal = true,
    },
    {
        key = "showMinimapButton",
        frameName = "PF_SettingRow_Minimap",
        label = "Show Minimap Button (OneForAll / LibDBIcon Compatible)",
        desc = "Show a circular minimap button that collapses cleanly into button-collector addons.",
        defaultVal = true,
    },
    {
        key = "autoSnoozeOnCraft",
        frameName = "PF_SettingRow_AutoSnoozeCraft",
        label = "Auto-Snooze Crafted Plays (12 Hours)",
        desc = "Automatically hide a crafting play for 12h after you craft it so Top 5 rotates fresh plays.",
        defaultVal = true,
    },
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

local PRICE_SOURCE_CHOICES = {
    { key = "AUTO",        label = "Auto (Freshest)", frameName = "PF_SettingSource_Auto" },
    { key = "PCF",         label = "PCF Scan",        frameName = "PF_SettingSource_PCF" },
    { key = "AUCTIONATOR", label = "Auctionator",     frameName = "PF_SettingSource_Auctionator" },
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

function PF.SideWindow.SnoozeOpportunity(opp, isPermanent)
    if type(opp) ~= "table" or not PF.SnoozePlay then
        return nil
    end
    local dur = isPermanent and 0 or nil
    local reason = isPermanent and "permanent" or "manual"
    local entry = PF.SnoozePlay(opp, dur, reason)
    if entry then
        local durSec = entry.durationSeconds or 86400
        local durLabel
        if isPermanent then
            durLabel = "permanently"
        elseif durSec == 86400 then
            durLabel = "for 24h"
        elseif durSec == 43200 then
            durLabel = "for 12h"
        else
            durLabel = "for " .. PF.FormatAgeShort(durSec)
        end
        local dispName = entry.itemLink or entry.itemName or entry.key
        print(string.format(
            "|cff00ff88[Profitable]|r Hidden %s %s. (Restore anytime in Options -> Snoozed Plays or /pf unhide)",
            dispName,
            durLabel
        ))
        PF.SideWindow.ApplySnoozeChange()
    end
    return entry
end

local function CreateOpportunityButton(parent, frameName, yOffset, bgR, bgG, bgB)
    local btn = CreateFrame("Button", frameName, parent)
    if btn.SetSize then btn:SetSize(336, 46) end
    if btn.SetPoint then
        btn:SetPoint("TOPLEFT", parent, "TOPLEFT", 12, yOffset)
    end
    if btn.RegisterForClicks then
        pcall(btn.RegisterForClicks, btn, "LeftButtonUp", "RightButtonUp")
    end
    SetBackdropSafe(btn, bgR or 0.11, bgG or 0.13, bgB or 0.16, 0.92)

    local mainText = btn.CreateFontString and btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    if mainText then
        if mainText.SetPoint then mainText:SetPoint("TOPLEFT", btn, "TOPLEFT", 8, -6) end
        if mainText.SetWidth then mainText:SetWidth(298) end
        if mainText.SetJustifyH then mainText:SetJustifyH("LEFT") end
        if mainText.SetWordWrap then pcall(mainText.SetWordWrap, mainText, false) end
    end

    local subText = btn.CreateFontString and btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    if subText then
        if subText.SetPoint then subText:SetPoint("TOPLEFT", mainText, "BOTTOMLEFT", 0, -4) end
        if subText.SetWidth then subText:SetWidth(318) end
        if subText.SetJustifyH then subText:SetJustifyH("LEFT") end
        if subText.SetWordWrap then pcall(subText.SetWordWrap, subText, false) end
    end

    local snoozeBtn = CreateFrame("Button", frameName .. "_Snooze", btn)
    if snoozeBtn.SetSize then snoozeBtn:SetSize(18, 18) end
    if snoozeBtn.SetPoint then snoozeBtn:SetPoint("TOPRIGHT", btn, "TOPRIGHT", -4, -4) end
    SetBackdropSafe(snoozeBtn, 0.22, 0.14, 0.16, 0.85)
    local snoozeText = snoozeBtn.CreateFontString and snoozeBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    if snoozeText then
        if snoozeText.SetPoint then snoozeText:SetPoint("CENTER", snoozeBtn, "CENTER", 0, 0) end
        if snoozeText.SetText then snoozeText:SetText("|cffff9999x|r") end
    end
    snoozeBtn:SetScript("OnClick", function()
        if btn._opportunity then
            local isPerm = (_G.IsShiftKeyDown and _G.IsShiftKeyDown()) == true
            PF.SideWindow.SnoozeOpportunity(btn._opportunity, isPerm)
        end
    end)
    snoozeBtn:SetScript("OnEnter", function(self)
        if not _G.GameTooltip then return end
        _G.GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        _G.GameTooltip:AddLine("Snooze / Hide Play", 0, 1, 0.5)
        _G.GameTooltip:AddLine("Click: Snooze this play for 24 hours.", 1, 1, 1, true)
        _G.GameTooltip:AddLine("Shift-Click: Hide permanently (restore in Options).", 0.7, 0.85, 1, true)
        _G.GameTooltip:Show()
    end)
    snoozeBtn:SetScript("OnLeave", function()
        if _G.GameTooltip then _G.GameTooltip:Hide() end
    end)
    snoozeBtn:Hide()

    btn:SetScript("OnClick", function(_, mouseButton)
        if mouseButton == "RightButton" and btn._opportunity then
            local isPerm = (_G.IsShiftKeyDown and _G.IsShiftKeyDown()) == true
            PF.SideWindow.SnoozeOpportunity(btn._opportunity, isPerm)
            return
        end
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
            _G.GameTooltip:AddLine("|cff00ff88Left-Click:|r Open Shopping List & Breakdown", 0.2, 1, 0.6)
            _G.GameTooltip:AddLine("|cffaaaaaaRight-Click (or 'x'): Snooze for 24h (Shift for permanent)|r", 0.75, 0.75, 0.75)
            _G.GameTooltip:Show()
        elseif btn._needsAHScan then
            _G.GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            _G.GameTooltip:AddLine("Auction House Scan Required", 1, 0.8, 0.2)
            _G.GameTooltip:AddLine("Profitable needs fresh Auction House price data (via PCF Scan or Auctionator) before it can calculate profitable plays.", 1, 1, 1, true)
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
    btn.snoozeBtn = snoozeBtn
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
    if onboardingFrame.SetSize then onboardingFrame:SetSize(440, 260) end
    if onboardingFrame.SetPoint then onboardingFrame:SetPoint("CENTER", _G.UIParent, "CENTER", 0, 60) end
    if onboardingFrame.SetFrameStrata then onboardingFrame:SetFrameStrata("DIALOG") end
    if onboardingFrame.SetToplevel then onboardingFrame:SetToplevel(true) end
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
                "|cffffcc00Profitable needs Auction House price data to calculate plays.|r\n\n"
                .. "|cff00ff881.|r Visit any Auctioneer and open the |cffffd100Auction House|r.\n"
                .. "|cff00ff882.|r Click |cff00ff88Scan AH Now|r (or |cff00ff88PCF Scan|r) — OR if you already use |cffffd100Auctionator|r, run an Auctionator Full Scan (no duplicate scan needed!).\n"
                .. "|cff00ff883.|r Open your profession windows once to scan recipes, then click |cff00ff88Find Top 5 Plays|r (or click the |cff00ff88Profitable|r AH / Minimap button)."
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
    local status, info = "NO_DATA", { itemCount = 0, ageText = "never" }
    if PF.GetAHDataStatus then
        status, info = PF.GetAHDataStatus()
    end
    if onboardingFrame.statusText then
        if status == "NO_DATA" then
            onboardingFrame.statusText:SetText("|cffff5555Current Status: No Auction House scan data found yet (0 items).|r")
        elseif status == "STALE" then
            onboardingFrame.statusText:SetText(string.format("|cffff9900Current Status: Auction House data is stale (%s old — please rescan at the AH).|r", info.ageText or "24h+"))
        else
            local srcLabel = (info.activeSource and info.activeSource ~= "None") and (" via " .. info.activeSource) or ""
            onboardingFrame.statusText:SetText(string.format("|cff00ff88Current Status: Auction House data ready (%d items%s, %s old).|r", info.itemCount or 0, srcLabel, info.ageText or "0m"))
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
    local mode = (PF.GetPriceSourceMode and PF.GetPriceSourceMode()) or "AUTO"
    local ahOpen = PF.AHVerifier and PF.AHVerifier.IsAuctionHouseOpen and PF.AHVerifier.IsAuctionHouseOpen()
    if mode == "AUCTIONATOR" then
        print("|cffffcc00[Profitable]|r Price Source is set to Auctionator. Run an Auctionator Full Scan at the Auction House (or switch Price Source to Auto/PCF in Options).")
        return false
    end
    if not ahOpen then
        PF.SideWindow.ShowOnboardingPopup(true)
        print("|cffffcc00[Profitable]|r You must open the Auction House at an Auctioneer first, then click 'Scan AH Now' (or run an Auctionator Full Scan).")
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
    if key == "showMinimapButton" then
        if s and type(s.minimap) == "table" and s.minimap.hide ~= nil then
            return s.minimap.hide ~= true
        end
        return defaultVal == true
    end
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

local function SyncPCFScanButtonForPriceSource()
    if not (_G.PCF_DB and type(_G.PCF_DB.settings) == "table") then
        return
    end
    if _G.PCF_DB.settings.userSetScanButton then
        return
    end
    local mode = (PF.GetPriceSourceMode and PF.GetPriceSourceMode()) or "AUTO"
    local desired = (mode ~= "AUCTIONATOR")
    if _G.PCF_DB.settings.showScanButton ~= desired then
        _G.PCF_DB.settings.showScanButton = desired
        if _G.PCF and _G.PCF.Scanner and type(_G.PCF.Scanner.UpdateVisibility) == "function" then
            _G.PCF.Scanner.UpdateVisibility()
        end
    end
    if PF.SideWindow and PF.SideWindow.UpdateAHToggleButtonAnchor then
        PF.SideWindow.UpdateAHToggleButtonAnchor()
    end
end

function PF.SideWindow.SetPriceSource(modeInput, quiet)
    if type(modeInput) ~= "string" then
        return false, PF.GetPriceSourceMode()
    end
    local normalized = modeInput:upper():match("^%s*(.-)%s*$") or ""
    if normalized == "ATR" or normalized == "AUCTIONATOR" then
        normalized = "AUCTIONATOR"
    elseif normalized == "PCF" or normalized == "SCAN" then
        normalized = "PCF"
    elseif normalized == "AUTO" or normalized == "BOTH" or normalized == "FRESHEST" then
        normalized = "AUTO"
    else
        if not quiet then
            print("|cffff5555[Profitable]|r Invalid price source. Use 'auto', 'pcf', or 'auctionator'.")
        end
        return false, PF.GetPriceSourceMode()
    end

    Profitable_DB = Profitable_DB or {}
    Profitable_DB.settings = Profitable_DB.settings or {}
    Profitable_DB.settings.priceSource = normalized
    SyncPCFScanButtonForPriceSource()
    PF.SideWindow.ApplyFilterChange()

    if not quiet then
        local labels = {
            AUTO = "Auto (Freshest of PCF / Auctionator / Feed)",
            PCF = "PCF Scan Only",
            AUCTIONATOR = "Auctionator Only",
        }
        print(string.format("|cff00ff88[Profitable]|r Price Data Source set to: %s.", labels[normalized] or normalized))
    end
    return true, normalized
end

function PF.SideWindow.SetMinimapButtonShown(shown)
    Profitable_DB = Profitable_DB or {}
    Profitable_DB.settings = Profitable_DB.settings or {}
    Profitable_DB.settings.minimap = (type(Profitable_DB.settings.minimap) == "table" and Profitable_DB.settings.minimap) or { hide = false, minimapPos = 220 }
    local shouldShow = (shown == true)
    Profitable_DB.settings.minimap.hide = not shouldShow

    if minimapUsesLibDBIcon and _G.LibStub then
        local ok, ldbIcon = pcall(_G.LibStub, "LibDBIcon-1.0", true)
        if ok and ldbIcon then
            if shouldShow and ldbIcon.Show then
                pcall(ldbIcon.Show, ldbIcon, "Profitable")
            elseif not shouldShow and ldbIcon.Hide then
                pcall(ldbIcon.Hide, ldbIcon, "Profitable")
            end
        end
    elseif minimapButton then
        if shouldShow then
            minimapButton:Show()
        else
            minimapButton:Hide()
        end
    end

    PF.SideWindow.RefreshFilterControls()
    return shouldShow
end

function PF.SideWindow.RefreshFilterControls()
    for _, tag in ipairs(FILTER_TAGS) do
        local btn = filterTagButtons[tag.key]
        if btn then
            local enabled = GetSettingBool(tag.key, tag.defaultVal)
            SetTagButtonVisual(btn, tag.label, enabled)
        end
    end

    if not settingsFrame then
        return
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

    local activeMode = (PF.GetPriceSourceMode and PF.GetPriceSourceMode()) or "AUTO"
    for _, choice in ipairs(PRICE_SOURCE_CHOICES) do
        local btn = priceSourceButtons[choice.key]
        if btn then
            local selected = (activeMode == choice.key)
            if btn._pfBg then
                local r, g, b = selected and 0.08 or 0.14, selected and 0.36 or 0.15, selected and 0.22 or 0.18
                if btn._pfBg.SetColorTexture then
                    btn._pfBg:SetColorTexture(r, g, b, 0.95)
                elseif btn._pfBg.SetTexture then
                    btn._pfBg:SetTexture(r, g, b, 0.95)
                end
            end
            local txt = selected
                and string.format("|cff00ff88[%s]|r", choice.label)
                or string.format("|cffaaaaaa%s|r", choice.label)
            if btn.SetText then btn:SetText(txt) end
            if btn.labelText and btn.labelText.SetText then
                btn.labelText:SetText(txt)
            end
        end
    end
    if settingsFrame and settingsFrame.sourceTitleText then
        local status, info = "NO_DATA", {}
        if PF.GetAHDataStatus then
            status, info = PF.GetAHDataStatus()
        end
        local atrLoaded = PF.AuctionatorSource and PF.AuctionatorSource.IsAvailable and PF.AuctionatorSource.IsAvailable()
        local activeNote
        if status == "FRESH" then
            activeNote = string.format("|cff00ff88Active: %s (%d items)|r", info.activeSource or "PCF", info.itemCount or 0)
        elseif status == "STALE" then
            activeNote = string.format("|cffff9900Stale: %s (%s old)|r", info.activeSource or "PCF", info.ageText or "24h+")
        else
            activeNote = atrLoaded and "|cffffcc00No scan data yet (run PCF or Auctionator scan)|r" or "|cffffcc00No scan data yet|r"
        end
        settingsFrame.sourceTitleText:SetText("Price Data Source:  " .. activeNote)
    end

    if settingsFrame and settingsFrame.budgetTitleText then
        local effectiveBudget, isCapped, playerGold, customCap = PF.GetEffectiveBudget()
        if isCapped then
            local extraNote = (playerGold < customCap)
                and string.format(" |cffffcc00(using %s — wallet limit)|r", PF.Formatter.FormatMoneyShort(effectiveBudget))
                or string.format(" |cffaaaaaa(Wallet: %s)|r", PF.Formatter.FormatMoneyShort(playerGold))
            settingsFrame.budgetTitleText:SetText(string.format(
                "Max Spending Budget: |cff00ff88%s Cap|r%s",
                PF.Formatter.FormatMoneyShort(customCap),
                extraNote
            ))
        else
            settingsFrame.budgetTitleText:SetText(string.format(
                "Max Spending Budget: |cffffd100All Gold (%s)|r",
                PF.Formatter.FormatMoneyShort(playerGold)
            ))
        end
        if settingsFrame.budgetInput and not (settingsFrame.budgetInput.HasFocus and settingsFrame.budgetInput:HasFocus()) then
            settingsFrame.budgetInput:SetText(isCapped and PF.Formatter.FormatMoneyShort(customCap) or "")
        end
    end

    if settingsFrame and settingsFrame.snoozedTitleText then
        local snoozed = (PF.GetActiveSnoozedPlays and PF.GetActiveSnoozedPlays()) or {}
        if #snoozed > 0 then
            settingsFrame.snoozedTitleText:SetText(string.format(
                "Snoozed / Hidden Plays: |cffffd100%d active|r |cffaaaaaa(Right-click or 'x' any row to snooze 24h)|r",
                #snoozed
            ))
        else
            settingsFrame.snoozedTitleText:SetText("Snoozed / Hidden Plays: |cffaaaaaaNone — right-click or click 'x' on any play to hide 24h|r")
        end
    end
end

function PF.SideWindow.SetCustomBudget(inputValue, quiet)
    local copper = PF.ParseGoldToCopper(inputValue)
    if copper == nil then
        if not quiet then
            print("|cffff5555[Profitable]|r Invalid budget. Enter gold like '10', '10g', '10g 50s', or 'auto' for all gold.")
        end
        return false, nil
    end

    Profitable_DB = Profitable_DB or {}
    Profitable_DB.settings = Profitable_DB.settings or {}
    Profitable_DB.settings.customBudgetCopper = copper
    PF.SideWindow.ApplyFilterChange()

    if not quiet then
        if copper > 0 then
            local eff, _, playerGold = PF.GetEffectiveBudget()
            if playerGold < copper then
                print(string.format(
                    "|cff00ff88[Profitable]|r Spending budget cap set to %s (effective: %s based on current wallet).",
                    PF.Formatter.FormatMoney(copper), PF.Formatter.FormatMoney(eff)
                ))
            else
                print(string.format(
                    "|cff00ff88[Profitable]|r Spending budget cap set to %s (Wallet: %s).",
                    PF.Formatter.FormatMoney(copper), PF.Formatter.FormatMoney(playerGold)
                ))
            end
        else
            print(string.format(
                "|cff00ff88[Profitable]|r Spending budget reset to All Gold (%s).",
                PF.Formatter.FormatMoney(PF.Formatter.GetPlayerGold())
            ))
        end
    end
    return true, copper
end

function PF.SideWindow.ApplySnoozeChange()
    local status = (PF.GetAHDataStatus and PF.GetAHDataStatus()) or "FRESH"
    if status == "FRESH" and not PF.AHVerifier.IsRunning() then
        if PF.AHVerifier.RefreshForSnoozeChange then
            PF.AHVerifier.RefreshForSnoozeChange()
        elseif PF.AHVerifier.RecalculateFromCache then
            PF.AHVerifier.RecalculateFromCache()
        end
    end
    if sideFrame and (not sideFrame.IsShown or sideFrame:IsShown()) then
        PF.SideWindow.RefreshRows()
        if not PF.AHVerifier.IsRunning() and sideFrame.statusText and status == "FRESH" then
            local count = (Profitable_DB and Profitable_DB.lastTopPlays and #Profitable_DB.lastTopPlays) or 0
            sideFrame.statusText:SetText(string.format("Top %d Ready", count))
        end
    end
    if settingsFrame and settingsFrame.snoozedTitleText then
        local snoozed = (PF.GetActiveSnoozedPlays and PF.GetActiveSnoozedPlays()) or {}
        if #snoozed > 0 then
            settingsFrame.snoozedTitleText:SetText(string.format(
                "Snoozed / Hidden Plays: |cffffd100%d active|r |cffaaaaaa(Right-click or 'x' any row to snooze 24h)|r",
                #snoozed
            ))
        else
            settingsFrame.snoozedTitleText:SetText("Snoozed / Hidden Plays: |cffaaaaaaNone — right-click or click 'x' on any play to hide 24h|r")
        end
    end
    if PF.DetailWindow and PF.DetailWindow.RefreshIfShown then
        PF.DetailWindow.RefreshIfShown()
    end
    if snoozedFrame and (not snoozedFrame.IsShown or snoozedFrame:IsShown()) and PF.SideWindow.RefreshSnoozedWindow then
        PF.SideWindow.RefreshSnoozedWindow()
    end
end

function PF.SideWindow.ApplyFilterChange()
    if PF.RecipeScanner and PF.RecipeScanner.InvalidateCache then
        PF.RecipeScanner.InvalidateCache()
    end
    if PF.AHVerifier and PF.AHVerifier.InvalidateEvaluatedPool then
        PF.AHVerifier.InvalidateEvaluatedPool()
    end
    if PF.InvalidateAHStatusCache then
        PF.InvalidateAHStatusCache()
    end
    local status = (PF.GetAHDataStatus and PF.GetAHDataStatus()) or "FRESH"
    if status == "FRESH" and not PF.AHVerifier.IsRunning() and PF.AHVerifier.RecalculateFromCache then
        PF.AHVerifier.RecalculateFromCache()
    end
    if sideFrame and (not sideFrame.IsShown or sideFrame:IsShown()) then
        PF.SideWindow.Refresh()
    else
        PF.SideWindow.RefreshFilterControls()
    end
    if PF.DetailWindow and PF.DetailWindow.RefreshIfShown then
        PF.DetailWindow.RefreshIfShown()
    end
    if snoozedFrame and (not snoozedFrame.IsShown or snoozedFrame:IsShown()) and PF.SideWindow.RefreshSnoozedWindow then
        PF.SideWindow.RefreshSnoozedWindow()
    end
end

function PF.SideWindow.ToggleSetting(key, defaultVal)
    Profitable_DB = Profitable_DB or {}
    Profitable_DB.settings = Profitable_DB.settings or {}
    if key == "showMinimapButton" then
        local cur = GetSettingBool("showMinimapButton", defaultVal)
        return PF.SideWindow.SetMinimapButtonShown(not cur)
    end
    local cur = GetSettingBool(key, defaultVal)
    Profitable_DB.settings[key] = not cur
    PF.SideWindow.ApplyFilterChange()
    return Profitable_DB.settings[key]
end

local function EnsureSnoozedWindow()
    if snoozedFrame then
        return snoozedFrame
    end

    snoozedFrame = CreateFrame("Frame", "PF_SnoozedPlaysWindow", _G.UIParent)
    if snoozedFrame.SetSize then snoozedFrame:SetSize(400, 380) end
    if snoozedFrame.SetPoint then snoozedFrame:SetPoint("CENTER", _G.UIParent, "CENTER", 140, 20) end
    if snoozedFrame.SetFrameStrata then snoozedFrame:SetFrameStrata("DIALOG") end
    if snoozedFrame.SetToplevel then snoozedFrame:SetToplevel(true) end
    if snoozedFrame.SetMovable then snoozedFrame:SetMovable(true) end
    if snoozedFrame.EnableMouse then snoozedFrame:EnableMouse(true) end
    if snoozedFrame.RegisterForDrag then snoozedFrame:RegisterForDrag("LeftButton") end
    snoozedFrame:SetScript("OnDragStart", function(self)
        if self.StartMoving then self:StartMoving() end
    end)
    snoozedFrame:SetScript("OnDragStop", function(self)
        if self.StopMovingOrSizing then self:StopMovingOrSizing() end
    end)
    SetBackdropSafe(snoozedFrame, 0.05, 0.06, 0.09, 0.97)

    local title = snoozedFrame.CreateFontString and snoozedFrame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    if title then
        if title.SetPoint then title:SetPoint("TOPLEFT", snoozedFrame, "TOPLEFT", 14, -12) end
        if title.SetText then title:SetText("|cff00ff88Profitable|r — Snoozed / Hidden Plays") end
    end

    local closeBtn = CreateFrame("Button", "PF_SnoozedCloseButton", snoozedFrame, "UIPanelCloseButton")
    if closeBtn.SetPoint then closeBtn:SetPoint("TOPRIGHT", snoozedFrame, "TOPRIGHT", -4, -4) end
    closeBtn:SetScript("OnClick", function()
        snoozedFrame:Hide()
    end)

    local emptyText = snoozedFrame.CreateFontString and snoozedFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    if emptyText then
        if emptyText.SetPoint then emptyText:SetPoint("TOPLEFT", snoozedFrame, "TOPLEFT", 16, -46) end
        if emptyText.SetWidth then emptyText:SetWidth(368) end
        if emptyText.SetJustifyH then emptyText:SetJustifyH("LEFT") end
        if emptyText.SetText then emptyText:SetText("|cffaaaaaaNo snoozed or hidden plays right now.|r") end
    end

    for i = 1, MAX_SNOOZED_ROWS do
        local yOff = -44 - ((i - 1) * 24)
        local row = CreateFrame("Frame", "PF_SnoozedRow" .. i, snoozedFrame)
        if row.SetSize then row:SetSize(372, 22) end
        if row.SetPoint then row:SetPoint("TOPLEFT", snoozedFrame, "TOPLEFT", 14, yOff) end
        SetBackdropSafe(row, 0.11, 0.13, 0.16, 0.92)

        local label = row.CreateFontString and row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        if label then
            if label.SetPoint then label:SetPoint("LEFT", row, "LEFT", 6, 0) end
            if label.SetWidth then label:SetWidth(292) end
            if label.SetJustifyH then label:SetJustifyH("LEFT") end
            if label.SetWordWrap then pcall(label.SetWordWrap, label, false) end
        end

        local unhideBtn = CreateFrame("Button", "PF_SnoozedUnhideBtn" .. i, row, "UIPanelButtonTemplate")
        if unhideBtn.SetSize then unhideBtn:SetSize(64, 18) end
        if unhideBtn.SetPoint then unhideBtn:SetPoint("RIGHT", row, "RIGHT", -4, 0) end
        if unhideBtn.SetText then unhideBtn:SetText("Unhide") end
        unhideBtn:SetScript("OnClick", function()
            if row._snoozeKey and PF.UnsnoozePlay then
                local removed, entry = PF.UnsnoozePlay(row._snoozeKey)
                if removed then
                    print(string.format("|cff00ff88[Profitable]|r Restored %s to your opportunity list.", (entry and (entry.itemLink or entry.itemName)) or row._snoozeKey))
                    PF.SideWindow.ApplySnoozeChange()
                end
            end
        end)

        row.label = label
        row.unhideBtn = unhideBtn
        row:Hide()
        snoozedRows[i] = row
    end

    local clearAllBtn = CreateFrame("Button", "PF_SnoozedClearAllButton", snoozedFrame, "UIPanelButtonTemplate")
    if clearAllBtn.SetSize then clearAllBtn:SetSize(140, 24) end
    if clearAllBtn.SetPoint then clearAllBtn:SetPoint("BOTTOMLEFT", snoozedFrame, "BOTTOMLEFT", 14, 12) end
    if clearAllBtn.SetText then clearAllBtn:SetText("Clear All Hidden") end
    clearAllBtn:SetScript("OnClick", function()
        local cleared = (PF.ClearAllSnoozedPlays and PF.ClearAllSnoozedPlays()) or 0
        if cleared > 0 then
            print(string.format("|cff00ff88[Profitable]|r Restored all %d snoozed/hidden plays.", cleared))
            PF.SideWindow.ApplySnoozeChange()
        end
    end)

    local closeFooterBtn = CreateFrame("Button", "PF_SnoozedDoneButton", snoozedFrame, "UIPanelButtonTemplate")
    if closeFooterBtn.SetSize then closeFooterBtn:SetSize(100, 24) end
    if closeFooterBtn.SetPoint then closeFooterBtn:SetPoint("BOTTOMRIGHT", snoozedFrame, "BOTTOMRIGHT", -14, 12) end
    if closeFooterBtn.SetText then closeFooterBtn:SetText("Close") end
    closeFooterBtn:SetScript("OnClick", function()
        snoozedFrame:Hide()
    end)

    snoozedFrame.emptyText = emptyText
    snoozedFrame.rows = snoozedRows
    snoozedFrame.clearAllBtn = clearAllBtn
    snoozedFrame:Hide()
    PF.SideWindow.snoozedFrame = snoozedFrame
    return snoozedFrame
end

function PF.SideWindow.RefreshSnoozedWindow()
    if not snoozedFrame then return end
    local list = (PF.GetActiveSnoozedPlays and PF.GetActiveSnoozedPlays()) or {}
    if snoozedFrame.emptyText then
        if #list == 0 then
            snoozedFrame.emptyText:Show()
        else
            snoozedFrame.emptyText:Hide()
        end
    end
    for i = 1, MAX_SNOOZED_ROWS do
        local row = snoozedRows[i]
        local entry = list[i]
        if entry then
            row._snoozeKey = entry.key
            local tag
            if entry.isPermanent then
                tag = "|cffff7777[Permanent]|r"
            elseif entry.reason == "crafted" then
                tag = string.format("|cff00ccff[Crafted: %s left]|r", entry.remainingText)
            else
                tag = string.format("|cffffd100[%s left]|r", entry.remainingText)
            end
            if row.label then
                row.label:SetText(string.format("%s  %s", entry.itemLink or entry.itemName or entry.key, tag))
            end
            row:Show()
        else
            row._snoozeKey = nil
            row:Hide()
        end
    end
end

function PF.SideWindow.ToggleSnoozedWindow()
    local frame = EnsureSnoozedWindow()
    if frame.IsShown and frame:IsShown() then
        frame:Hide()
    else
        PF.SideWindow.RefreshSnoozedWindow()
        frame:Show()
        if frame.Raise then frame:Raise() end
    end
end

local function EnsureSettingsWindow()
    if settingsFrame then
        return settingsFrame
    end

    local rowHeight = 31
    local rowPitch = 34
    local listStartY = -52
    local afterListY = listStartY - (#SETTINGS_OPTIONS * rowPitch) - 4
    local sourceCardHeight = 52
    local budgetCardHeight = 62
    local snoozedCardHeight = 50
    local totalHeight = math.abs(afterListY) + sourceCardHeight + 6 + budgetCardHeight + 6 + snoozedCardHeight + 46

    settingsFrame = CreateFrame("Frame", "PF_SettingsWindow", _G.UIParent)
    if settingsFrame.SetSize then settingsFrame:SetSize(430, totalHeight) end
    if settingsFrame.SetPoint then settingsFrame:SetPoint("CENTER", _G.UIParent, "CENTER", 0, 10) end
    if settingsFrame.SetFrameStrata then settingsFrame:SetFrameStrata("MEDIUM") end
    if settingsFrame.SetToplevel then settingsFrame:SetToplevel(true) end
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
        if subtitle.SetPoint then subtitle:SetPoint("TOPLEFT", settingsFrame, "TOPLEFT", 14, -33) end
        if subtitle.SetText then subtitle:SetText("Click any option below to toggle window behavior, filters, or auto-snooze:") end
    end

    for idx, opt in ipairs(SETTINGS_OPTIONS) do
        local yOff = listStartY - ((idx - 1) * rowPitch)
        local row = CreateFrame("Button", opt.frameName, settingsFrame)
        if row.SetSize then row:SetSize(402, rowHeight) end
        if row.SetPoint then row:SetPoint("TOPLEFT", settingsFrame, "TOPLEFT", 14, yOff) end
        SetBackdropSafe(row, 0.11, 0.13, 0.16, 0.92)

        local titleText = row.CreateFontString and row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        if titleText then
            if titleText.SetPoint then titleText:SetPoint("TOPLEFT", row, "TOPLEFT", 8, -3) end
            if titleText.SetWidth then titleText:SetWidth(386) end
            if titleText.SetJustifyH then titleText:SetJustifyH("LEFT") end
        end

        local descText = row.CreateFontString and row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        if descText then
            if descText.SetPoint then descText:SetPoint("TOPLEFT", titleText, "BOTTOMLEFT", 0, -1) end
            if descText.SetWidth then descText:SetWidth(386) end
            if descText.SetJustifyH then descText:SetJustifyH("LEFT") end
            if descText.SetWordWrap then pcall(descText.SetWordWrap, descText, false) end
            if descText.SetText then descText:SetText("|cffaaaaaa" .. opt.desc .. "|r") end
        end

        row:SetScript("OnClick", function()
            PF.SideWindow.ToggleSetting(opt.key, opt.defaultVal)
        end)

        row.titleText = titleText
        row.descText = descText
        settingsCheckRows[opt.key] = row
    end

    -- Price Data Source Card (Auto / PCF Scan / Auctionator)
    local sourceYOff = afterListY
    local sourceCard = CreateFrame("Frame", "PF_SettingsSourceCard", settingsFrame)
    if sourceCard.SetSize then sourceCard:SetSize(402, sourceCardHeight) end
    if sourceCard.SetPoint then sourceCard:SetPoint("TOPLEFT", settingsFrame, "TOPLEFT", 14, sourceYOff) end
    SetBackdropSafe(sourceCard, 0.10, 0.13, 0.18, 0.94)

    local sourceTitleText = sourceCard.CreateFontString and sourceCard:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    if sourceTitleText then
        if sourceTitleText.SetPoint then sourceTitleText:SetPoint("TOPLEFT", sourceCard, "TOPLEFT", 8, -6) end
        if sourceTitleText.SetWidth then sourceTitleText:SetWidth(386) end
        if sourceTitleText.SetJustifyH then sourceTitleText:SetJustifyH("LEFT") end
    end

    for idx, choice in ipairs(PRICE_SOURCE_CHOICES) do
        local btn = CreateFrame("Button", choice.frameName, sourceCard)
        if btn.SetSize then btn:SetSize(124, 22) end
        if btn.SetPoint then
            btn:SetPoint("BOTTOMLEFT", sourceCard, "BOTTOMLEFT", 8 + ((idx - 1) * 131), 6)
        end
        SetBackdropSafe(btn, 0.14, 0.15, 0.18, 0.95)
        local labelText = btn.CreateFontString and btn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        if labelText then
            if labelText.SetPoint then labelText:SetPoint("CENTER", btn, "CENTER", 0, 0) end
        end
        btn.labelText = labelText
        btn:SetScript("OnClick", function()
            PF.SideWindow.SetPriceSource(choice.key)
        end)
        priceSourceButtons[choice.key] = btn
    end

    settingsFrame.sourceCard = sourceCard
    settingsFrame.sourceTitleText = sourceTitleText
    settingsFrame.priceSourceButtons = priceSourceButtons

    -- Max Spending Budget Cap Section (Defaults to full character gold when blank/0)
    local budgetYOff = sourceYOff - sourceCardHeight - 6
    local budgetCard = CreateFrame("Frame", "PF_SettingsBudgetCard", settingsFrame)
    if budgetCard.SetSize then budgetCard:SetSize(402, budgetCardHeight) end
    if budgetCard.SetPoint then budgetCard:SetPoint("TOPLEFT", settingsFrame, "TOPLEFT", 14, budgetYOff) end
    SetBackdropSafe(budgetCard, 0.10, 0.13, 0.18, 0.94)

    local budgetTitleText = budgetCard.CreateFontString and budgetCard:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    if budgetTitleText then
        if budgetTitleText.SetPoint then budgetTitleText:SetPoint("TOPLEFT", budgetCard, "TOPLEFT", 8, -5) end
        if budgetTitleText.SetWidth then budgetTitleText:SetWidth(386) end
        if budgetTitleText.SetJustifyH then budgetTitleText:SetJustifyH("LEFT") end
    end

    local budgetDescText = budgetCard.CreateFontString and budgetCard:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    if budgetDescText then
        if budgetDescText.SetPoint then budgetDescText:SetPoint("TOPLEFT", budgetTitleText, "BOTTOMLEFT", 0, -2) end
        if budgetDescText.SetWidth then budgetDescText:SetWidth(386) end
        if budgetDescText.SetJustifyH then budgetDescText:SetJustifyH("LEFT") end
        if budgetDescText.SetText then
            budgetDescText:SetText("|cffaaaaaaLimit gold spent per play (e.g. 10, 10g 50s, or blank for All Gold):|r")
        end
    end

    local budgetInput = CreateFrame("EditBox", "PF_SettingsBudgetInput", budgetCard, "InputBoxTemplate")
    if budgetInput.SetSize then budgetInput:SetSize(136, 20) end
    if budgetInput.SetPoint then budgetInput:SetPoint("BOTTOMLEFT", budgetCard, "BOTTOMLEFT", 14, 6) end
    if budgetInput.SetAutoFocus then pcall(budgetInput.SetAutoFocus, budgetInput, false) end
    if budgetInput.SetMaxLetters then pcall(budgetInput.SetMaxLetters, budgetInput, 20) end

    local function CommitBudgetInput()
        local raw = (budgetInput.GetText and budgetInput:GetText()) or ""
        if budgetInput.ClearFocus then pcall(budgetInput.ClearFocus, budgetInput) end
        PF.SideWindow.SetCustomBudget(raw)
    end

    budgetInput:SetScript("OnEnterPressed", CommitBudgetInput)
    budgetInput:SetScript("OnEscapePressed", function(self)
        if self.ClearFocus then pcall(self.ClearFocus, self) end
        PF.SideWindow.RefreshFilterControls()
    end)

    local budgetApplyBtn = CreateFrame("Button", "PF_SettingsBudgetApplyButton", budgetCard, "UIPanelButtonTemplate")
    if budgetApplyBtn.SetSize then budgetApplyBtn:SetSize(74, 22) end
    if budgetApplyBtn.SetPoint then budgetApplyBtn:SetPoint("LEFT", budgetInput, "RIGHT", 10, 0) end
    if budgetApplyBtn.SetText then budgetApplyBtn:SetText("Apply") end
    budgetApplyBtn:SetScript("OnClick", CommitBudgetInput)

    local budgetAutoBtn = CreateFrame("Button", "PF_SettingsBudgetAutoButton", budgetCard, "UIPanelButtonTemplate")
    if budgetAutoBtn.SetSize then budgetAutoBtn:SetSize(112, 22) end
    if budgetAutoBtn.SetPoint then budgetAutoBtn:SetPoint("LEFT", budgetApplyBtn, "RIGHT", 8, 0) end
    if budgetAutoBtn.SetText then budgetAutoBtn:SetText("Use All Gold") end
    budgetAutoBtn:SetScript("OnClick", function()
        if budgetInput.ClearFocus then pcall(budgetInput.ClearFocus, budgetInput) end
        if budgetInput.SetText then budgetInput:SetText("") end
        PF.SideWindow.SetCustomBudget(0)
    end)

    settingsFrame.budgetCard = budgetCard
    settingsFrame.budgetTitleText = budgetTitleText
    settingsFrame.budgetInput = budgetInput
    settingsFrame.budgetApplyBtn = budgetApplyBtn
    settingsFrame.budgetAutoBtn = budgetAutoBtn

    -- Snoozed / Hidden Plays Management Card
    local snoozedYOff = budgetYOff - budgetCardHeight - 6
    local snoozedCard = CreateFrame("Frame", "PF_SettingsSnoozedCard", settingsFrame)
    if snoozedCard.SetSize then snoozedCard:SetSize(402, snoozedCardHeight) end
    if snoozedCard.SetPoint then snoozedCard:SetPoint("TOPLEFT", settingsFrame, "TOPLEFT", 14, snoozedYOff) end
    SetBackdropSafe(snoozedCard, 0.10, 0.13, 0.18, 0.94)

    local snoozedTitleText = snoozedCard.CreateFontString and snoozedCard:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    if snoozedTitleText then
        if snoozedTitleText.SetPoint then snoozedTitleText:SetPoint("TOPLEFT", snoozedCard, "TOPLEFT", 8, -5) end
        if snoozedTitleText.SetWidth then snoozedTitleText:SetWidth(386) end
        if snoozedTitleText.SetJustifyH then snoozedTitleText:SetJustifyH("LEFT") end
    end

    local manageSnoozedBtn = CreateFrame("Button", "PF_SettingsManageSnoozedButton", snoozedCard, "UIPanelButtonTemplate")
    if manageSnoozedBtn.SetSize then manageSnoozedBtn:SetSize(170, 22) end
    if manageSnoozedBtn.SetPoint then manageSnoozedBtn:SetPoint("BOTTOMLEFT", snoozedCard, "BOTTOMLEFT", 8, 6) end
    if manageSnoozedBtn.SetText then manageSnoozedBtn:SetText("Manage Snoozed Plays") end
    manageSnoozedBtn:SetScript("OnClick", function()
        PF.SideWindow.ToggleSnoozedWindow()
    end)

    local clearSnoozedBtn = CreateFrame("Button", "PF_SettingsClearSnoozedButton", snoozedCard, "UIPanelButtonTemplate")
    if clearSnoozedBtn.SetSize then clearSnoozedBtn:SetSize(130, 22) end
    if clearSnoozedBtn.SetPoint then clearSnoozedBtn:SetPoint("LEFT", manageSnoozedBtn, "RIGHT", 10, 0) end
    if clearSnoozedBtn.SetText then clearSnoozedBtn:SetText("Clear All Hidden") end
    clearSnoozedBtn:SetScript("OnClick", function()
        local cleared = (PF.ClearAllSnoozedPlays and PF.ClearAllSnoozedPlays()) or 0
        if cleared > 0 then
            print(string.format("|cff00ff88[Profitable]|r Restored all %d snoozed/hidden plays.", cleared))
            PF.SideWindow.ApplySnoozeChange()
        else
            print("|cff00ff88[Profitable]|r No snoozed/hidden plays to clear.")
        end
    end)

    settingsFrame.snoozedCard = snoozedCard
    settingsFrame.snoozedTitleText = snoozedTitleText
    settingsFrame.manageSnoozedBtn = manageSnoozedBtn
    settingsFrame.clearSnoozedBtn = clearSnoozedBtn

    local resetBtn = CreateFrame("Button", "PF_SettingsResetButton", settingsFrame, "UIPanelButtonTemplate")
    if resetBtn.SetSize then resetBtn:SetSize(160, 24) end
    if resetBtn.SetPoint then resetBtn:SetPoint("BOTTOMLEFT", settingsFrame, "BOTTOMLEFT", 14, 12) end
    if resetBtn.SetText then resetBtn:SetText("Reset Filter Defaults") end
    resetBtn:SetScript("OnClick", function()
        Profitable_DB = Profitable_DB or {}
        Profitable_DB.settings = Profitable_DB.settings or {}
        for _, opt in ipairs(SETTINGS_OPTIONS) do
            if opt.key == "showMinimapButton" then
                PF.SideWindow.SetMinimapButtonShown(opt.defaultVal)
            else
                Profitable_DB.settings[opt.key] = opt.defaultVal
            end
        end
        Profitable_DB.settings.priceSource = "AUTO"
        Profitable_DB.settings.customBudgetCopper = 0
        SyncPCFScanButtonForPriceSource()
        if budgetInput.ClearFocus then pcall(budgetInput.ClearFocus, budgetInput) end
        if budgetInput.SetText then budgetInput:SetText("") end
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
        if frame.Raise then frame:Raise() end
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
    -- Use MEDIUM strata + SetToplevel(true) so Blizzard panels (ProfessionsFrame, AuctionHouseFrame)
    -- and Profitable windows can freely swap focus when clicked.
    if sideFrame.SetFrameStrata then sideFrame:SetFrameStrata("MEDIUM") end
    if sideFrame.SetToplevel then sideFrame:SetToplevel(true) end
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
        if statusText.SetWidth then statusText:SetWidth(160) end
        if statusText.SetWordWrap then pcall(statusText.SetWordWrap, statusText, false) end
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
    if btn.snoozeBtn then
        btn.snoozeBtn:Show()
    end
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
        local tag = targetItem and targetItem.strategyTag
        if tag and tag ~= "" then
            sideFrame.statusText:SetText(string.format("%d/%d [%s]: %s", currentIdx or 0, totalCount or 0, tag, name))
        else
            sideFrame.statusText:SetText(string.format("Verifying %d/%d: %s", currentIdx or 0, totalCount or 0, name))
        end
    end
end

function PF.SideWindow.RefreshRows()
    if not sideFrame then return end

    local effectiveBudget, isCapped = PF.GetEffectiveBudget()
    local recipeCount = (PF.RecipeScanner.GetKnownRecipeCount and PF.RecipeScanner.GetKnownRecipeCount())
        or #PF.RecipeScanner.GetKnownRecipes()
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
        elseif dataInfo.activeSource == "Auctionator" then
            itemsLabel = string.format("|cff00ccff%d (Atr)|r", pcfItems)
        else
            itemsLabel = string.format("|cff00ccff%d|r", pcfItems)
        end
        local budgetLabel = isCapped
            and string.format("|cff00ff88%s (Cap)|r", PF.Formatter.FormatMoneyShort(effectiveBudget))
            or string.format("|cffffd100%s|r", PF.Formatter.FormatMoney(effectiveBudget))
        sideFrame.infoText:SetText(string.format(
            "Budget: %s  |  Recipes: |cff00ff88%d|r  |  Items: %s%s",
            budgetLabel, recipeCount, itemsLabel, feedNote
        ))
    end

    -- When AH data is missing or very stale (>24h), do NOT display old/stale plays;
    -- instead direct the user to run an AH scan first.
    if dataStatus == "NO_DATA" or dataStatus == "STALE" then
        local ahOpen = PF.AHVerifier and PF.AHVerifier.IsAuctionHouseOpen and PF.AHVerifier.IsAuctionHouseOpen()
        local pcfScanning = IsPCFScannerRunning()
        local sourceMode = (PF.GetPriceSourceMode and PF.GetPriceSourceMode()) or "AUTO"

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
            if btn1.snoozeBtn then btn1.snoozeBtn:Hide() end
            if pcfScanning then
                if btn1.mainText then
                    btn1.mainText:SetText("|cff00ccffAuction House Scan in Progress...|r")
                end
                if btn1.subText then
                    btn1.subText:SetText("Wait for PCF Scan to reach 100%, then click 'Find Top 5 Plays'.")
                end
            elseif sourceMode == "AUCTIONATOR" then
                if btn1.mainText then
                    if dataStatus == "NO_DATA" then
                        btn1.mainText:SetText("|cffffcc00Auctionator Data Required: No Scan Found!|r")
                    else
                        btn1.mainText:SetText(string.format("|cffff9900Auctionator Data is Stale (%s old)|r", dataInfo.ageText or "24h+"))
                    end
                end
                if btn1.subText then
                    btn1.subText:SetText("Run an Auctionator Full Scan at the AH (or switch Price Source in Options).")
                end
            elseif dataStatus == "NO_DATA" then
                if btn1.mainText then
                    btn1.mainText:SetText("|cffffcc00Scan Required: No Auction House Data Found!|r")
                end
                if btn1.subText then
                    if ahOpen then
                        btn1.subText:SetText("Click here or 'Scan AH Now' above (or run an Auctionator Full Scan).")
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
                        btn1.subText:SetText("Click here or 'Scan AH Now' above (or run an Auctionator scan) to refresh.")
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
                if playButtons[i].snoozeBtn then playButtons[i].snoozeBtn:Hide() end
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
                if hmButtons[i].snoozeBtn then hmButtons[i].snoozeBtn:Hide() end
                hmButtons[i]:Hide()
            end
        end
        return
    end

    if sideFrame.subBanner then
        sideFrame.subBanner:SetText("Top 5 Plays (click to expand; right-click or 'x' to snooze 24h):")
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
            if btn.snoozeBtn then btn.snoozeBtn:Hide() end
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
            if btn.snoozeBtn then btn.snoozeBtn:Hide() end
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
    if onboardingFrame and (not onboardingFrame.IsShown or onboardingFrame:IsShown()) then
        PF.SideWindow.RefreshOnboardingPopup()
    end
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
        if frame.Raise then frame:Raise() end
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

local function GetActiveAuctionHouseFrame()
    if _G.AuctionHouseFrame and (not _G.AuctionHouseFrame.IsShown or _G.AuctionHouseFrame:IsShown()) then
        return _G.AuctionHouseFrame
    end
    if _G.AuctionFrame and (not _G.AuctionFrame.IsShown or _G.AuctionFrame:IsShown()) then
        return _G.AuctionFrame
    end
    return _G.AuctionHouseFrame or _G.AuctionFrame
end

function PF.SideWindow.UpdateAHToggleButtonAnchor()
    if not ahToggleButton or not ahToggleButton.SetPoint then return end
    local parent = (ahToggleButton.GetParent and ahToggleButton:GetParent()) or GetActiveAuctionHouseFrame()
    if not parent then return end

    local pcfBtn = _G.PCF_AuctionScanButton or (_G.PCF and _G.PCF.Scanner and _G.PCF.Scanner.scanButton)
    local pcfVisibleOnSameParent = pcfBtn
        and (not pcfBtn.GetParent or pcfBtn:GetParent() == parent)
        and (not pcfBtn.IsShown or pcfBtn:IsShown())

    if ahToggleButton.ClearAllPoints then
        ahToggleButton:ClearAllPoints()
    end
    if pcfVisibleOnSameParent then
        ahToggleButton:SetPoint("RIGHT", pcfBtn, "LEFT", -4, 0)
    else
        local isLegacyFrame = (_G.AuctionFrame ~= nil and parent == _G.AuctionFrame)
        local offsetX = isLegacyFrame and -34 or -30
        local offsetY = isLegacyFrame and -13 or -3
        ahToggleButton:SetPoint("TOPRIGHT", parent, "TOPRIGHT", offsetX, offsetY)
    end
end

function PF.SideWindow.EnsureAHToggleButton()
    local parent = GetActiveAuctionHouseFrame()
    if not parent then return nil end

    if ahToggleButton then
        if ahToggleButton.GetParent and ahToggleButton:GetParent() ~= parent and ahToggleButton.SetParent then
            ahToggleButton:SetParent(parent)
        end
        PF.SideWindow.UpdateAHToggleButtonAnchor()
        ahToggleButton:Show()
        return ahToggleButton
    end

    ahToggleButton = CreateFrame("Button", "PF_AuctionToggleButton", parent, "UIPanelButtonTemplate")
    if ahToggleButton.SetSize then ahToggleButton:SetSize(78, 20) end
    if ahToggleButton.SetFrameStrata then ahToggleButton:SetFrameStrata("HIGH") end
    if ahToggleButton.SetText then ahToggleButton:SetText("Profitable") end
    if ahToggleButton.RegisterForClicks then
        pcall(ahToggleButton.RegisterForClicks, ahToggleButton, "LeftButtonUp", "RightButtonUp")
    end

    ahToggleButton:SetScript("OnClick", function(_, mouseButton)
        if mouseButton == "RightButton" then
            PF.SideWindow.ToggleSettingsWindow()
        else
            PF.SideWindow.Toggle()
        end
    end)
    ahToggleButton:SetScript("OnEnter", function(self)
        if not _G.GameTooltip then return end
        _G.GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
        _G.GameTooltip:AddLine("|cff00ff88Profitable (PF)|r", 1, 1, 1)
        _G.GameTooltip:AddLine("|cff00ff88Left-Click:|r Show / Hide the Top 5 Plays side window.", 1, 1, 1, true)
        _G.GameTooltip:AddLine("|cff88ccffRight-Click:|r Open Filter, Price Source & Snooze Options.", 0.8, 0.9, 1, true)
        _G.GameTooltip:Show()
    end)
    ahToggleButton:SetScript("OnLeave", function()
        if _G.GameTooltip then _G.GameTooltip:Hide() end
    end)

    PF.SideWindow.UpdateAHToggleButtonAnchor()
    ahToggleButton:Show()
    PF.SideWindow.ahToggleButton = ahToggleButton
    return ahToggleButton
end

local function PopulateMinimapTooltip(tooltip)
    if not tooltip or not tooltip.AddLine then return end
    tooltip:AddLine("|cff00ff88Profitable (PF)|r", 1, 1, 1)
    local status, info = "NO_DATA", {}
    if PF.GetAHDataStatus then
        status, info = PF.GetAHDataStatus()
    end
    if status == "FRESH" then
        tooltip:AddLine(string.format("Data: |cff00ff88%d items (%s, %s old)|r", info.itemCount or 0, info.activeSource or "PCF", info.ageText or "0m"), 0.85, 0.85, 0.85)
    elseif status == "STALE" then
        tooltip:AddLine(string.format("Data: |cffff9900Stale (%s old)|r", info.ageText or "24h+"), 1, 0.65, 0.2)
    else
        tooltip:AddLine("Data: |cffff5555No AH scan data yet|r", 1, 0.4, 0.4)
    end
    local snoozedCount = PF.GetActiveSnoozedPlays and #PF.GetActiveSnoozedPlays() or 0
    if snoozedCount > 0 then
        tooltip:AddLine(string.format("Snoozed Plays: |cffffd100%d|r", snoozedCount), 0.85, 0.85, 0.85)
    end
    tooltip:AddLine(" ")
    tooltip:AddLine("|cff00ff88Left-Click:|r Toggle Profitable Window", 0.9, 0.9, 0.9)
    tooltip:AddLine("|cff88ccffRight-Click:|r Open Options", 0.9, 0.9, 0.9)
    tooltip:AddLine("|cffffd100Shift-Left-Click:|r Find Top 5 Plays", 0.9, 0.9, 0.9)
    tooltip:AddLine("|cffaaaaaaDrag:|r Move around Minimap", 0.7, 0.7, 0.7)
end

local function OnMinimapButtonClick(_, mouseButton)
    if mouseButton == "RightButton" then
        PF.SideWindow.ToggleSettingsWindow()
    elseif _G.IsShiftKeyDown and _G.IsShiftKeyDown() then
        PF.SideWindow.RunSearch()
    else
        PF.SideWindow.Toggle()
    end
end

local function PositionMinimapButtonByAngle(btn, angleDeg)
    if not btn or not btn.SetPoint or not _G.Minimap then return end
    local rad = math.rad(tonumber(angleDeg) or 220)
    local radius = 80
    local x = math.cos(rad) * radius
    local y = math.sin(rad) * radius
    if btn.ClearAllPoints then btn:ClearAllPoints() end
    btn:SetPoint("CENTER", _G.Minimap, "CENTER", x, y)
end

function PF.SideWindow.InitMinimapButton()
    if minimapButton then
        return minimapButton
    end

    Profitable_DB = Profitable_DB or {}
    Profitable_DB.settings = Profitable_DB.settings or {}
    if type(Profitable_DB.settings.minimap) ~= "table" then
        Profitable_DB.settings.minimap = { hide = false, minimapPos = 220 }
    end
    local minimapDB = Profitable_DB.settings.minimap
    if minimapDB.minimapPos == nil then
        minimapDB.minimapPos = 220
    end

    local dataObject = {
        type = "launcher",
        label = "Profitable",
        text = "Profitable",
        icon = "Interface\\Icons\\INV_Misc_Coin_02",
        OnClick = OnMinimapButtonClick,
        OnTooltipShow = PopulateMinimapTooltip,
    }

    -- 1. If LibDataBroker-1.1 + LibDBIcon-1.0 are already loaded (e.g., via Auctionator/TSM/etc.),
    -- register natively so OneForAll / MBB / HidingBar / ElvUI manage it automatically.
    if _G.LibStub then
        local okLDB, ldb = pcall(_G.LibStub, "LibDataBroker-1.1", true)
        local okIcon, ldbIcon = pcall(_G.LibStub, "LibDBIcon-1.0", true)
        if okLDB and ldb and okIcon and ldbIcon and type(ldb.NewDataObject) == "function" and type(ldbIcon.Register) == "function" then
            local registeredObj = (ldb.GetDataObjectByName and ldb:GetDataObjectByName("Profitable"))
                or ldb:NewDataObject("Profitable", dataObject)
            if registeredObj then
                local alreadyReg = ldbIcon.IsRegistered and ldbIcon:IsRegistered("Profitable")
                if not alreadyReg then
                    pcall(ldbIcon.Register, ldbIcon, "Profitable", registeredObj, minimapDB)
                end
                minimapUsesLibDBIcon = true
                minimapButton = (ldbIcon.GetMinimapButton and ldbIcon:GetMinimapButton("Profitable"))
                    or _G["LibDBIcon10_Profitable"]
                if minimapDB.hide and ldbIcon.Hide then
                    pcall(ldbIcon.Hide, ldbIcon, "Profitable")
                elseif not minimapDB.hide and ldbIcon.Show then
                    pcall(ldbIcon.Show, ldbIcon, "Profitable")
                end
                PF.SideWindow.minimapButton = minimapButton
                return minimapButton
            end
        end
    end

    -- 2. Standalone LibDBIcon-1.0-compatible button ("LibDBIcon10_Profitable" parented to Minimap).
    -- Uses exact LibDBIcon frame naming, sizing, textures, and .dataObject layout, and only sets
    -- its point on creation/drag so minimap button collectors (OneForAll, MBB, HidingBar) can
    -- cleanly reparent and collapse it without fighting position updates.
    local parent = _G.Minimap or _G.UIParent
    local btn = CreateFrame("Button", "LibDBIcon10_Profitable", parent)
    if btn.SetSize then btn:SetSize(31, 31) end
    if btn.SetFrameStrata then btn:SetFrameStrata("MEDIUM") end
    if btn.SetFrameLevel then pcall(btn.SetFrameLevel, btn, 8) end
    if btn.SetMovable then btn:SetMovable(true) end
    if btn.EnableMouse then btn:EnableMouse(true) end
    if btn.RegisterForClicks then
        pcall(btn.RegisterForClicks, btn, "LeftButtonUp", "RightButtonUp")
    end
    if btn.RegisterForDrag then
        pcall(btn.RegisterForDrag, btn, "LeftButton")
    end
    if btn.SetHighlightTexture then
        pcall(btn.SetHighlightTexture, btn, "Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    end

    if btn.CreateTexture then
        local overlay = btn:CreateTexture(nil, "OVERLAY")
        if overlay then
            if overlay.SetSize then overlay:SetSize(53, 53) end
            if overlay.SetTexture then overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder") end
            if overlay.SetPoint then overlay:SetPoint("TOPLEFT", btn, "TOPLEFT", 0, 0) end
            btn.overlay = overlay
        end

        local background = btn:CreateTexture(nil, "BACKGROUND")
        if background then
            if background.SetSize then background:SetSize(20, 20) end
            if background.SetTexture then background:SetTexture("Interface\\Minimap\\UI-Minimap-Background") end
            if background.SetPoint then background:SetPoint("TOPLEFT", btn, "TOPLEFT", 7, -5) end
            btn.background = background
        end

        local icon = btn:CreateTexture(nil, "ARTWORK")
        if icon then
            if icon.SetSize then icon:SetSize(17, 17) end
            if icon.SetTexture then icon:SetTexture("Interface\\Icons\\INV_Misc_Coin_02") end
            if icon.SetPoint then icon:SetPoint("CENTER", btn, "CENTER", 0, 0) end
            if icon.SetTexCoord then pcall(icon.SetTexCoord, icon, 0.05, 0.95, 0.05, 0.95) end
            btn.icon = icon
        end
    end

    btn.dataObject = dataObject
    btn.db = minimapDB

    btn:SetScript("OnClick", OnMinimapButtonClick)
    btn:SetScript("OnEnter", function(self)
        if not _G.GameTooltip then return end
        _G.GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        PopulateMinimapTooltip(_G.GameTooltip)
        _G.GameTooltip:Show()
    end)
    btn:SetScript("OnLeave", function()
        if _G.GameTooltip then _G.GameTooltip:Hide() end
    end)
    btn:SetScript("OnDragStart", function(self)
        if self.GetParent and _G.Minimap and self:GetParent() ~= _G.Minimap then
            -- Managed inside a minimap collector frame (e.g. OneForAll); do not hijack its position.
            return
        end
        if self.SetScript then
            self:SetScript("OnUpdate", function(frame)
                if not _G.Minimap or not _G.GetCursorPosition or not _G.Minimap.GetCenter then
                    return
                end
                local mx, my = _G.Minimap:GetCenter()
                local cx, cy = _G.GetCursorPosition()
                local scale = (_G.Minimap.GetEffectiveScale and _G.Minimap:GetEffectiveScale()) or 1
                cx, cy = cx / scale, cy / scale
                if mx and my then
                    local angle = math.deg(math.atan2(cy - my, cx - mx))
                    minimapDB.minimapPos = angle
                    PositionMinimapButtonByAngle(frame, angle)
                end
            end)
        end
    end)
    btn:SetScript("OnDragStop", function(self)
        if self.SetScript then
            self:SetScript("OnUpdate", nil)
        end
    end)

    PositionMinimapButtonByAngle(btn, minimapDB.minimapPos)
    if minimapDB.hide then
        btn:Hide()
    else
        btn:Show()
    end

    minimapButton = btn
    PF.SideWindow.minimapButton = minimapButton
    return minimapButton
end

function PF.SideWindow.Init()
    if PF.SideWindow._initialized then return end
    PF.SideWindow._initialized = true

    PF.SideWindow.InitMinimapButton()

    if eventFrame.RegisterEvent then
        pcall(eventFrame.RegisterEvent, eventFrame, "AUCTION_HOUSE_SHOW")
        pcall(eventFrame.RegisterEvent, eventFrame, "AUCTION_HOUSE_CLOSED")
        pcall(eventFrame.RegisterEvent, eventFrame, "PLAYER_MONEY")
        eventFrame:SetScript("OnEvent", function(_, event)
            if event == "AUCTION_HOUSE_SHOW" then
                HookPCFScanButtonIfAvailable()
                PF.SideWindow.EnsureAHToggleButton()
                if _G.C_Timer and _G.C_Timer.After then
                    _G.C_Timer.After(0, function()
                        HookPCFScanButtonIfAvailable()
                        PF.SideWindow.UpdateAHToggleButtonAnchor()
                    end)
                end
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
                if settingsFrame and (not settingsFrame.IsShown or settingsFrame:IsShown()) then
                    PF.SideWindow.RefreshFilterControls()
                end
            end
        end)
    end
    PF.SideWindow.eventFrame = eventFrame
end
