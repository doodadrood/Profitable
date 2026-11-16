-- Mock WoW Lua Environment for Profitable CLI validation
local Mock = {
    currentTime = 1700000000.0,
    playerMoney = 220000, -- 22g default
    bagCounts = {},
    bankCounts = {},
    tradeSkills = {},
    tradeSkillLine = "Blacksmithing",
    auctionListingsByQuery = {},
    currentAuctionResults = {},
    lastAuctionQuery = nil,
    timers = {},
    castSpells = {},
    selectedTradeSkill = nil,
    craftedTradeSkill = nil,
    placedBids = {},
    skillLines = {},
    merchantItems = {},
    depositRate = 5,
}

_G.SlashCmdList = _G.SlashCmdList or {}

_G.GetTime = function() return Mock.currentTime end
_G.time = function() return math.floor(Mock.currentTime) end
_G.UnitName = function(unit) return unit == "player" and "ProfitTester" or "Target" end
_G.GetRealmName = function() return "Forever" end
_G.GetMoney = function() return Mock.playerMoney end

_G.GetItemCount = function(itemId, includeBank)
    local bags = Mock.bagCounts[itemId] or 0
    if includeBank then
        return bags + (Mock.bankCounts[itemId] or 0)
    end
    return bags
end

_G.C_Timer = {
    After = function(delay, callback)
        table.insert(Mock.timers, { delay = delay, callback = callback })
    end
}

function Mock.FlushTimers(maxSteps)
    local steps = 0
    local limit = maxSteps or 100
    while #Mock.timers > 0 and steps < limit do
        local t = table.remove(Mock.timers, 1)
        steps = steps + 1
        if t and t.callback then
            t.callback()
        end
    end
end

_G.CreateFrame = function(frameType, name, parent, template)
    local frame = {
        frameType = frameType,
        name = name,
        parent = parent,
        template = template,
        events = {},
        scripts = {},
        lines = {},
        text = "",
        shown = true,
        minVal = 0,
        maxVal = 1,
        val = 0,
    }
    if name then _G[name] = frame end
    function frame:GetName() return self.name end
    function frame:GetParent() return self.parent end
    function frame:RegisterEvent(event) self.events[event] = true end
    function frame:UnregisterEvent(event) self.events[event] = nil end
    function frame:SetScript(name, func) self.scripts[name] = func end
    function frame:HookScript(name, func)
        local prev = self.scripts[name]
        self.scripts[name] = function(...) if prev then prev(...) end; func(...) end
    end
    function frame:Trigger(event, ...)
        if self.events[event] and self.scripts["OnEvent"] then
            self.scripts["OnEvent"](self, event, ...)
        end
    end
    function frame:Click()
        if self.scripts["OnClick"] then
            self.scripts["OnClick"](self)
        end
    end
    function frame:SetOwner(owner) self.owner = owner end
    function frame:GetOwner() return self.owner end
    function frame:ClearLines() self.lines = {} end
    function frame:AddLine(text) table.insert(self.lines, text) end
    function frame:SetHyperlink(link) self.hyperlink = link end
    function frame:SetSize(w, h) self.width = w; self.height = h end
    function frame:SetWidth(w) self.width = w end
    function frame:SetHeight(h) self.height = h end
    function frame:SetPoint(...) end
    function frame:ClearAllPoints() end
    function frame:SetAllPoints(...) end
    function frame:SetFrameStrata(...) end
    function frame:SetMovable(...) end
    function frame:EnableMouse(...) end
    function frame:RegisterForDrag(...) end
    function frame:StartMoving() end
    function frame:StopMovingOrSizing() end
    function frame:SetText(t) self.text = t end
    function frame:GetText() return self.text end
    function frame:Show() self.shown = true end
    function frame:Hide() self.shown = false end
    function frame:IsShown() return self.shown end
    function frame:IsVisible() return self.shown end
    function frame:SetMinMaxValues(minV, maxV) self.minVal = minV; self.maxVal = maxV end
    function frame:SetValue(v) self.val = v end
    function frame:GetValue() return self.val end
    function frame:SetStatusBarTexture(...) end
    function frame:SetStatusBarColor(...) end
    function frame:CreateTexture(...)
        return {
            SetAllPoints = function() end,
            SetColorTexture = function() end,
            SetTexture = function() end,
        }
    end
    function frame:CreateFontString(...)
        local fs = { text = "" }
        function fs:SetPoint(...) end
        function fs:SetWidth(...) end
        function fs:SetJustifyH(...) end
        function fs:SetJustifyV(...) end
        function fs:SetText(t) self.text = t end
        function fs:GetText() return self.text end
        return fs
    end
    return frame
end

_G.UIParent = _G.CreateFrame("Frame", "UIParent")
_G.GameTooltip = _G.CreateFrame("GameTooltip", "GameTooltip")
_G.AuctionFrame = _G.CreateFrame("Frame", "AuctionFrame", _G.UIParent)
_G.BrowseName = _G.CreateFrame("EditBox", "BrowseName", _G.AuctionFrame)

-- Legacy TradeSkill Mock API
_G.GetTradeSkillLine = function() return Mock.tradeSkillLine, 250, 300 end
_G.GetNumTradeSkills = function() return #Mock.tradeSkills end
_G.GetTradeSkillInfo = function(index)
    local ts = Mock.tradeSkills[index]
    if not ts then return nil end
    return ts.name, ts.skillType or "optimal", 1, true
end
_G.GetTradeSkillItemLink = function(index)
    local ts = Mock.tradeSkills[index]
    if not ts then return nil end
    return ts.outputLink or string.format("|cffffffff|Hitem:%d:0:0:0|h[%s]|h|r", ts.outputItemId, ts.name)
end
_G.GetTradeSkillNumMade = function(index)
    local ts = Mock.tradeSkills[index]
    if not ts then return 1, 1 end
    return ts.minMade or 1, ts.maxMade or ts.minMade or 1
end
_G.GetTradeSkillNumReagents = function(index)
    local ts = Mock.tradeSkills[index]
    return (ts and ts.reagents and #ts.reagents) or 0
end
_G.GetTradeSkillReagentInfo = function(index, rIndex)
    local ts = Mock.tradeSkills[index]
    local r = ts and ts.reagents and ts.reagents[rIndex]
    if not r then return nil end
    return r.name, nil, r.count, Mock.bagCounts[r.itemId] or 0
end
_G.GetTradeSkillReagentItemLink = function(index, rIndex)
    local ts = Mock.tradeSkills[index]
    local r = ts and ts.reagents and ts.reagents[rIndex]
    if not r then return nil end
    return r.link or string.format("|cffffffff|Hitem:%d:0:0:0|h[%s]|h|r", r.itemId, r.name or "Reagent")
end
_G.SelectTradeSkill = function(index)
    Mock.selectedTradeSkill = index
end
_G.DoTradeSkill = function(index, qty)
    Mock.craftedTradeSkill = { index = index, quantity = qty }
end
_G.CastSpellByName = function(spellName)
    table.insert(Mock.castSpells, spellName)
end

-- Legacy Auction House Mock API
_G.CanSendAuctionQuery = function() return true end
_G.QueryAuctionItems = function(name)
    Mock.lastAuctionQuery = name
    Mock.currentAuctionResults = Mock.auctionListingsByQuery[name] or {}
    if _G.PF and _G.PF.AHVerifier and _G.PF.AHVerifier.frame then
        _G.PF.AHVerifier.frame:Trigger("AUCTION_ITEM_LIST_UPDATE")
    end
end
_G.GetNumAuctionItems = function(listType)
    return #Mock.currentAuctionResults, #Mock.currentAuctionResults
end
_G.GetAuctionItemInfo = function(listType, index)
    local row = Mock.currentAuctionResults[index]
    if not row then return nil end
    return row.name, nil, row.count or 1, 1, nil, 1, nil, row.minBid or row.buyoutPrice, 0, row.buyoutPrice, 0, nil, 0, "Seller", nil, 0, row.itemId
end
_G.SetSelectedAuctionItem = function(listType, index)
    Mock.selectedAuctionIndex = index
end
_G.PlaceAuctionBid = function(listType, index, amount)
    table.insert(Mock.placedBids, { listType = listType, index = index, amount = amount })
end
_G.GetAuctionHouseDepositRate = function()
    return Mock.depositRate
end
_G.GetNumSkillLines = function()
    return #Mock.skillLines
end
_G.GetSkillLineInfo = function(index)
    local s = Mock.skillLines[index]
    if not s then return nil end
    return s.name, s.isHeader or false, true, s.rank or 1, 0, 0, s.maxRank or 300
end
_G.GetMerchantNumItems = function()
    return #Mock.merchantItems
end
_G.GetMerchantItemInfo = function(index)
    local m = Mock.merchantItems[index]
    if not m then return nil end
    return m.name, nil, m.price, m.quantity or 1, m.numAvailable or -1
end
_G.GetMerchantItemLink = function(index)
    local m = Mock.merchantItems[index]
    if not m then return nil end
    return m.link or string.format("|cffffffff|Hitem:%d:0:0:0|h[%s]|h|r", m.itemId, m.name or "Item")
end

return Mock
