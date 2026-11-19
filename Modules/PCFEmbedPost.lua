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
