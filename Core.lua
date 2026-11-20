local addonName = ...
local PF = _G.PF or {}
_G.PF = PF
_G.Profitable = PF

PF_API = _G.PF_API or {}
_G.PF_API = PF_API
_G.Profitable_API = PF_API

function PF_API.FindTopOpportunities(budgetOverride, customOrderBooks, limitOverride)
    return PF.OpportunityEngine.FindTopOpportunities(budgetOverride, customOrderBooks, limitOverride)
end

function PF_API.RunSearch()
    return PF.SideWindow.RunSearch()
end

function PF_API.ShowOpportunity(indexOrOpp)
    if type(indexOrOpp) == "number" then
        local plays = Profitable_DB and Profitable_DB.lastTopPlays
        local opp = plays and plays[indexOrOpp]
        if opp then
            PF.DetailWindow.ShowOpportunity(opp)
            return true
        end
        return false
    elseif type(indexOrOpp) == "table" then
        PF.DetailWindow.ShowOpportunity(indexOrOpp)
        return true
    end
    return false
end

function PF_API.EvaluateDisenchant(itemId, itemLink)
    return PF.DisenchantDatabase.EvaluateDisenchant(itemId, itemLink, PF.OpportunityEngine.ResolveAHPrice)
end

function PF_API.IsReady()
    return _G.PF_INITIALIZED == true
        and type(Profitable_DB) == "table"
        and type(PF.OpportunityEngine) == "table"
end

local function RegisterSlashCommands()
    SLASH_PROFITABLE1 = "/pf"
    SLASH_PROFITABLE2 = "/profitable"
    SlashCmdList["PROFITABLE"] = function(msg)
        local cmd, arg = (msg or ""):lower():match("^%s*(%S*)%s*(.-)%s*$")
        if cmd == "" or cmd == "toggle" or cmd == "show" then
            if not (Profitable_DB and Profitable_DB.settings and Profitable_DB.settings.onboardingDismissed == true) then
                PF.SideWindow.ShowOnboardingPopup(false)
            end
            PF.SideWindow.Toggle()
        elseif cmd == "scan" then
            local status = (PF.GetAHDataStatus and PF.GetAHDataStatus()) or "FRESH"
            local ahOpen = PF.AHVerifier and PF.AHVerifier.IsAuctionHouseOpen and PF.AHVerifier.IsAuctionHouseOpen()
            if (status == "NO_DATA" or status == "STALE") and ahOpen then
                PF.SideWindow.TriggerAHScan()
            else
                local plays = PF.SideWindow.RunSearch()
                if status == "FRESH" then
                    print(string.format("|cff00ff88[Profitable]|r Found %d profitable plays:", #(plays or {})))
                    for i, opp in ipairs(plays or {}) do
                        print("  " .. (opp.summaryLine or PF.OpportunityEngine.FormatOpportunityLine(i, opp)))
                    end
                end
            end
        elseif cmd == "run" or cmd == "find" then
            local status = (PF.GetAHDataStatus and PF.GetAHDataStatus()) or "FRESH"
            local plays = PF.SideWindow.RunSearch()
            if status == "FRESH" then
                print(string.format("|cff00ff88[Profitable]|r Found %d profitable plays:", #(plays or {})))
                for i, opp in ipairs(plays or {}) do
                    print("  " .. (opp.summaryLine or PF.OpportunityEngine.FormatOpportunityLine(i, opp)))
                end
            end
        elseif cmd == "welcome" or cmd == "guide" or cmd == "onboarding" then
            PF.SideWindow.ShowOnboardingPopup(true)
        elseif cmd == "detail" or tonumber(cmd) then
            local idx = tonumber(cmd) or tonumber(arg) or 1
            local status = (PF.GetAHDataStatus and PF.GetAHDataStatus()) or "FRESH"
            if status == "NO_DATA" then
                PF.SideWindow.ShowOnboardingPopup(false)
                print("|cffffcc00[Profitable]|r No Auction House scan data found yet. Open the Auction House and click 'Scan AH Now' (or 'PCF Scan') first.")
            elseif not PF_API.ShowOpportunity(idx) then
                print(string.format("|cffff5555[Profitable]|r Opportunity #%d not found. Run /pf run first.", idx))
            end
        elseif cmd == "de" then
            Profitable_DB.settings.assumeCanDisenchant = not Profitable_DB.settings.assumeCanDisenchant
            if PF.SideWindow and PF.SideWindow.ApplyFilterChange then
                PF.SideWindow.ApplyFilterChange()
            end
            print(string.format("|cff00ff88[Profitable]|r Disenchant Plays: %s", Profitable_DB.settings.assumeCanDisenchant and "ON" or "OFF"))
        elseif cmd == "alts" then
            Profitable_DB.settings.includeAllCharRecipes = not Profitable_DB.settings.includeAllCharRecipes
            if PF.SideWindow and PF.SideWindow.ApplyFilterChange then
                PF.SideWindow.ApplyFilterChange()
            end
            print(string.format("|cff00ff88[Profitable]|r Include All Characters' Recipes: %s", Profitable_DB.settings.includeAllCharRecipes and "ON" or "OFF"))
        elseif cmd == "buyout" or cmd == "buyoutonly" then
            Profitable_DB.settings.buyoutOnly = not (Profitable_DB.settings.buyoutOnly ~= false)
            if PF.SideWindow and PF.SideWindow.ApplyFilterChange then
                PF.SideWindow.ApplyFilterChange()
            end
            print(string.format("|cff00ff88[Profitable]|r Buyout Only (Exclude Bid-Only Auctions): %s", Profitable_DB.settings.buyoutOnly and "ON" or "OFF"))
        elseif cmd == "options" or cmd == "settings" or cmd == "config" then
            if PF.SideWindow and PF.SideWindow.ToggleSettingsWindow then
                PF.SideWindow.ToggleSettingsWindow()
            end
        elseif cmd == "budget" then
            if arg == nil or arg == "" then
                local eff, isCapped, playerGold, customCap = PF.GetEffectiveBudget()
                if isCapped then
                    print(string.format(
                        "|cff00ff88[Profitable]|r Budget Cap: %s (Effective: %s, Wallet: %s). Use '/pf budget <amount>' or '/pf budget auto'.",
                        PF.Formatter.FormatMoney(customCap), PF.Formatter.FormatMoney(eff), PF.Formatter.FormatMoney(playerGold)
                    ))
                else
                    print(string.format(
                        "|cff00ff88[Profitable]|r Budget: All Gold (%s). Use '/pf budget 10g' to cap or '/pf budget auto' to reset.",
                        PF.Formatter.FormatMoney(playerGold)
                    ))
                end
            elseif PF.SideWindow and PF.SideWindow.SetCustomBudget then
                PF.SideWindow.SetCustomBudget(arg)
            end
        else
            print("|cff00ff88Profitable Commands:|r")
            print("  /pf          - Toggle the Profitable AH side window")
            print("  /pf run      - Calculate and verify the Top 5 profitable plays")
            print("  /pf scan     - Start an AH price scan (when at the AH) or calculate plays")
            print("  /pf detail N - Open the breakdown & shopping tracker for play #1-#5")
            print("  /pf options  - Open the Profitable Filter & Play Options window")
            print("  /pf budget X - Set max spending budget (e.g. '/pf budget 10g' or '/pf budget auto')")
            print("  /pf buyout   - Toggle Buyout-Only mode (excludes bid-only auctions; Default: ON)")
            print("  /pf de       - Toggle Disenchant plays on or off (Default: ON)")
            print("  /pf alts     - Toggle using known recipes across all alts vs current character")
            print("  /pf welcome  - Re-open the Getting Started / AH Scan guide popup")
        end
    end
end

local function IsStandalonePCFLoaded()
    if PF._standalonePCFActive == true then
        return true
    end
    local isLoadedFn = (_G.C_AddOns and _G.C_AddOns.IsAddOnLoaded) or _G.IsAddOnLoaded
    if type(isLoadedFn) == "function" then
        local ok, loaded = pcall(isLoadedFn, "PriceCheckerForever")
        if ok and loaded then
            return true
        end
    end
    return false
end

local function ConfigureEmbeddedPCF()
    if PF._embeddedPCFActive and not IsStandalonePCFLoaded() then
        if not _G.PCF_INITIALIZED and _G.PCF and type(_G.PCF.Initialize) == "function" then
            _G.PCF.Initialize()
        end
        Profitable_DB.embeddedPCF = (type(Profitable_DB.embeddedPCF) == "table" and Profitable_DB.embeddedPCF) or {}
        if _G.PCF_API and type(_G.PCF_API.SetSavedVariables) == "function" then
            _G.PCF_API.SetSavedVariables(Profitable_DB.embeddedPCF)
        elseif _G.PCF and type(_G.PCF.LoadConfig) == "function" then
            _G.PCF.LoadConfig(Profitable_DB.embeddedPCF)
        end
    end

    -- Ensure PCF's AH scan button is active out of the box when Profitable is enabled
    -- (unless the user explicitly toggled it off via /pcf button), even alongside TSM/Auctionator.
    if _G.PCF_DB and type(_G.PCF_DB.settings) == "table" and not _G.PCF_DB.settings.userSetScanButton then
        if _G.PCF_DB.settings.showScanButton ~= true then
            _G.PCF_DB.settings.showScanButton = true
            if _G.PCF and _G.PCF.Scanner and type(_G.PCF.Scanner.UpdateVisibility) == "function" then
                _G.PCF.Scanner.UpdateVisibility()
            end
        end
    end
end

function PF.Initialize()
    if _G.PF_INITIALIZED then
        return false
    end
    _G.PF_INITIALIZED = true

    PF.LoadConfig()
    ConfigureEmbeddedPCF()
    if PF.VendorDatabase and PF.VendorDatabase.Init then
        PF.VendorDatabase.Init()
    end
    if PF.RecipeScanner and PF.RecipeScanner.Init then
        PF.RecipeScanner.Init()
    end
    if PF.MarketFeed and PF.MarketFeed.OnFeedLoaded then
        PF.MarketFeed.OnFeedLoaded()
    end
    if PF.AHVerifier and PF.AHVerifier.Init then
        PF.AHVerifier.Init()
    end
    if PF.SideWindow and PF.SideWindow.Init then
        PF.SideWindow.Init()
    end

    RegisterSlashCommands()

    local dataStatus, dataInfo = "FRESH", nil
    if PF.GetAHDataStatus then
        dataStatus, dataInfo = PF.GetAHDataStatus()
    end

    if not (Profitable_DB and Profitable_DB.settings and Profitable_DB.settings.onboardingDismissed == true) then
        if PF.SideWindow and PF.SideWindow.ShowOnboardingPopup then
            PF.SideWindow.ShowOnboardingPopup(false)
        end
        print("|cffffcc00[Profitable]|r Welcome! Profitable will not function until it has Auction House price data. Visit an Auctioneer, open the AH, and click 'Scan AH Now' (or 'PCF Scan').")
    elseif dataStatus == "NO_DATA" then
        print("|cffffcc00[Profitable]|r Loaded (no Auction House scan data found yet — open the AH and click 'Scan AH Now' or 'PCF Scan' before calculating plays).")
    elseif dataStatus == "STALE" then
        print(string.format("|cffff9900[Profitable]|r Loaded (Auction House data is %s old — open the AH and run a fresh scan for accurate plays).", (dataInfo and dataInfo.ageText) or "24h+"))
    else
        print("|cff00ff88Profitable loaded.|r Open the Auction House or type /pf to find the top 5 plays.")
    end
    return true
end

if _G.PF_INITIALIZED then
    return
end

local coreFrame = CreateFrame("Frame")
coreFrame:RegisterEvent("ADDON_LOADED")
if coreFrame.RegisterEvent then
    pcall(coreFrame.RegisterEvent, coreFrame, "PLAYER_LOGIN")
end

coreFrame:SetScript("OnEvent", function(self, event, loadedAddon)
    if event == "ADDON_LOADED" and loadedAddon ~= addonName and loadedAddon ~= "Profitable" then
        return
    end
    if _G.PF_INITIALIZED then
        self:UnregisterEvent("ADDON_LOADED")
        pcall(self.UnregisterEvent, self, "PLAYER_LOGIN")
        return
    end
    PF.Initialize()
    self:UnregisterEvent("ADDON_LOADED")
    pcall(self.UnregisterEvent, self, "PLAYER_LOGIN")
end)

PF.coreFrame = coreFrame
