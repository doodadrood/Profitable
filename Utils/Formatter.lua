local PF = _G.PF or {}
_G.PF = PF
_G.Profitable = PF

PF.Formatter = {}

local GOLD_ICON = "|TInterface\\MoneyFrame\\UI-GoldIcon:0:0:2:0|t"
local SILVER_ICON = "|TInterface\\MoneyFrame\\UI-SilverIcon:0:0:2:0|t"
local COPPER_ICON = "|TInterface\\MoneyFrame\\UI-CopperIcon:0:0:2:0|t"

local QUALITY_HEX = {
    [0] = "cff9d9d9d", -- Poor
    [1] = "cffffffff", -- Common
    [2] = "cff1eff00", -- Uncommon
    [3] = "cff0070dd", -- Rare
    [4] = "cffa335ee", -- Epic
    [5] = "cffff8000", -- Legendary
}

local function IsFiniteNumber(val)
    return type(val) == "number" and val == val and val > -math.huge and val < math.huge
end

function PF.Formatter.FormatMoney(copper, compact)
    if not IsFiniteNumber(copper) or copper <= 0 then
        return "0c"
    end
    copper = math.floor(copper + 0.5)
    local g = math.floor(copper / 10000) + 0
    local s = math.floor((copper % 10000) / 100) + 0
    local c = (copper % 100) + 0

    if compact then
        -- Compact summary format for Side Window: e.g. "22g", "2g45s", "85s", "45c"
        local parts = {}
        if g > 0 then
            table.insert(parts, string.format("%.0fg", g))
            if s > 0 then
                table.insert(parts, string.format("%ds", s))
            end
        elseif s > 0 then
            table.insert(parts, string.format("%ds", s))
            if c > 0 then
                table.insert(parts, string.format("%dc", c))
            end
        else
            table.insert(parts, string.format("%dc", c))
        end
        return table.concat(parts, "")
    end

    local parts = {}
    if g > 0 then table.insert(parts, string.format("%.0fg", g)) end
    if s > 0 then table.insert(parts, string.format("%ds", s)) end
    if c > 0 or #parts == 0 then table.insert(parts, string.format("%dc", c)) end
    return table.concat(parts, " ")
end

function PF.Formatter.FormatMoneyShort(copper)
    return PF.Formatter.FormatMoney(copper, true)
end

function PF.Formatter.FormatTooltipMoney(copper)
    if not IsFiniteNumber(copper) or copper <= 0 then
        return "0c"
    end
    copper = math.floor(copper + 0.5)
    if _G.GetCoinTextureString then
        local ok, formatted = pcall(_G.GetCoinTextureString, copper)
        if ok and type(formatted) == "string" and formatted ~= "" then
            return formatted
        end
    end
    local g = math.floor(copper / 10000) + 0
    local s = math.floor((copper % 10000) / 100) + 0
    local c = (copper % 100) + 0
    local parts = {}
    if g > 0 then table.insert(parts, string.format("%.0f%s", g, GOLD_ICON)) end
    if s > 0 then table.insert(parts, string.format("%d%s", s, SILVER_ICON)) end
    if c > 0 or #parts == 0 then table.insert(parts, string.format("%d%s", c, COPPER_ICON)) end
    return table.concat(parts, " ")
end

function PF.Formatter.GetPlayerGold()
    if _G.GetMoney then
        local ok, money = pcall(_G.GetMoney)
        if ok and type(money) == "number" and money >= 0 then
            return math.floor(money)
        end
    end
    return 0
end

function PF.Formatter.GetInventoryCount(itemId, includeBank)
    if not itemId or itemId <= 0 then return 0 end
    if _G.C_Item and _G.C_Item.GetItemCount then
        local ok, count = pcall(_G.C_Item.GetItemCount, itemId, includeBank == true, false, false)
        if ok and type(count) == "number" then
            return math.floor(count)
        end
    end
    if _G.GetItemCount then
        local ok, count = pcall(_G.GetItemCount, itemId, includeBank == true)
        if ok and type(count) == "number" then
            return math.floor(count)
        end
    end
    return 0
end

function PF.Formatter.BuildItemLink(itemId, itemName, quality, existingLink)
    if type(existingLink) == "string" and existingLink:find("|Hitem:") then
        return existingLink
    end
    if not itemId then
        return string.format("[%s]", tostring(itemName or "Unknown Item"))
    end
    local info = PF.VendorDatabase and PF.VendorDatabase.GetItemMetadata and PF.VendorDatabase.GetItemMetadata(itemId)
    if info and type(info.link) == "string" and info.link:find("|Hitem:") then
        return info.link
    end
    local resolvedName = itemName or (info and info.name) or string.format("Item #%d", itemId)
    local resolvedQuality = quality or (info and info.quality) or 1
    local hex = QUALITY_HEX[resolvedQuality] or QUALITY_HEX[1]
    return string.format("|%s|Hitem:%d:0:0:0:0:0:0:0|h[%s]|h|r", hex, itemId, resolvedName)
end
