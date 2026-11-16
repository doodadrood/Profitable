local addonName, PF = ...
PF = (_G.PF_INITIALIZED and _G.PF) or (type(PF) == "table" and PF) or _G.PF or {}
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
            PF.SideWindow.Toggle()
        elseif cmd == "run" or cmd == "scan" or cmd == "find" then
            local plays = PF.SideWindow.RunSearch()
            print(string.format("|cff00ff88[Profitable]|r Found %d profitable plays:", #(plays or {})))
            for i, opp in ipairs(plays or {}) do
                print("  " .. (opp.summaryLine or PF.OpportunityEngine.FormatOpportunityLine(i, opp)))
            end
        elseif cmd == "detail" or tonumber(cmd) then
            local idx = tonumber(cmd) or tonumber(arg) or 1
            if not PF_API.ShowOpportunity(idx) then
                print(string.format("|cffff5555[Profitable]|r Opportunity #%d not found. Run /pf scan first.", idx))
            end
        elseif cmd == "de" then
            Profitable_DB.settings.assumeCanDisenchant = not Profitable_DB.settings.assumeCanDisenchant
            print(string.format("|cff00ff88[Profitable]|r Assume Can Disenchant: %s", Profitable_DB.settings.assumeCanDisenchant and "ON" or "OFF"))
        elseif cmd == "alts" then
            Profitable_DB.settings.includeAllCharRecipes = not Profitable_DB.settings.includeAllCharRecipes
            print(string.format("|cff00ff88[Profitable]|r Include All Characters' Recipes: %s", Profitable_DB.settings.includeAllCharRecipes and "ON" or "OFF"))
        else
            print("|cff00ff88Profitable Commands:|r")
            print("  /pf          - Toggle the Profitable AH side window")
            print("  /pf run      - Calculate and verify the Top 5 profitable plays")
            print("  /pf detail N - Open the breakdown & shopping tracker for play #1-#5")
            print("  /pf de       - Toggle Disenchant plays on or off (Default: ON)")
            print("  /pf alts     - Toggle using known recipes across all alts vs current character")
        end
    end
end

function PF.Initialize()
    if _G.PF_INITIALIZED then
        return false
    end
    _G.PF_INITIALIZED = true

    PF.LoadConfig()
    if PF.VendorDatabase and PF.VendorDatabase.Init then
        PF.VendorDatabase.Init()
    end
    if PF.RecipeScanner and PF.RecipeScanner.Init then
        PF.RecipeScanner.Init()
    end
    if PF.AHVerifier and PF.AHVerifier.Init then
        PF.AHVerifier.Init()
    end
    if PF.SideWindow and PF.SideWindow.Init then
        PF.SideWindow.Init()
    end

    RegisterSlashCommands()
    print("|cff00ff88Profitable loaded.|r Open the Auction House or type /pf to find the top 5 plays.")
    return true
end

if _G.PF_INITIALIZED then
    return
end

local coreFrame = CreateFrame("Frame")
coreFrame:RegisterEvent("ADDON_LOADED")

coreFrame:SetScript("OnEvent", function(self, event, loadedAddon)
    if loadedAddon ~= addonName and loadedAddon ~= "Profitable" then
        return
    end
    if _G.PF_INITIALIZED then
        self:UnregisterEvent("ADDON_LOADED")
        return
    end
    PF.Initialize()
    self:UnregisterEvent("ADDON_LOADED")
end)

PF.coreFrame = coreFrame
