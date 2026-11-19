-- Isolates standalone PriceCheckerForever state before Profitable loads Libs/PriceCheckerForever/Embed.xml
local PF = _G.PF or {}
_G.PF = PF
_G.Profitable = PF

if _G.PCF_INITIALIZED and type(_G.PCF) == "table" then
    PF._standalonePCFActive = true
    PF._savedStandalonePCF = _G.PCF
    PF._savedStandalonePCFDB = _G.PCF_DB
    PF._savedStandalonePCFAPI = _G.PCF_API

    -- Redirect embedded script file-load writes away from standalone PCF globals
    _G.PCF = {}
    _G.GPC = _G.PCF
    _G.PCF_API = {}
else
    PF._standalonePCFActive = false
    PF._savedStandalonePCF = nil
    PF._savedStandalonePCFDB = nil
    PF._savedStandalonePCFAPI = nil
end
