local _, PF = ...
PF = type(PF) == "table" and PF or _G.PF or {}
_G.PF = PF

PF.RecipeDatabase = {}

-- Curated Classic / WoW: Forever baseline recipe database across professions.
-- Used both to evaluate recipes based on character profession skill rank (even before
-- opening each profession window) and to recommend high-profit trainer/unlearned recipes.
local BASELINE_RECIPES = {
    -- ==========================================
    -- MINING (Smelting)
    -- ==========================================
    {
        name = "Smelt Copper",
        profession = "Mining",
        skillReq = 1,
        source = "Trainer",
        outputItemId = 2840,
        avgMade = 1,
        reagents = { { itemId = 2770, name = "Copper Ore", count = 1 } },
    },
    {
        name = "Smelt Tin",
        profession = "Mining",
        skillReq = 65,
        source = "Trainer",
        outputItemId = 3576,
        avgMade = 1,
        reagents = { { itemId = 2771, name = "Tin Ore", count = 1 } },
    },
    {
        name = "Smelt Bronze",
        profession = "Mining",
        skillReq = 65,
        source = "Trainer",
        outputItemId = 2841,
        avgMade = 2,
        reagents = {
            { itemId = 2840, name = "Copper Bar", count = 1 },
            { itemId = 3576, name = "Tin Bar", count = 1 },
        },
    },
    {
        name = "Smelt Silver",
        profession = "Mining",
        skillReq = 75,
        source = "Trainer",
        outputItemId = 2842,
        avgMade = 1,
        reagents = { { itemId = 2775, name = "Silver Ore", count = 1 } },
    },
    {
        name = "Smelt Iron",
        profession = "Mining",
        skillReq = 125,
        source = "Trainer",
        outputItemId = 3575,
        avgMade = 1,
        reagents = { { itemId = 2772, name = "Iron Ore", count = 1 } },
    },
    {
        name = "Smelt Gold",
        profession = "Mining",
        skillReq = 155,
        source = "Trainer",
        outputItemId = 3577,
        avgMade = 1,
        reagents = { { itemId = 2776, name = "Gold Ore", count = 1 } },
    },
    {
        name = "Smelt Steel",
        profession = "Mining",
        skillReq = 165,
        source = "Trainer",
        outputItemId = 3859,
        avgMade = 1,
        reagents = {
            { itemId = 3575, name = "Iron Bar", count = 1 },
            { itemId = 3857, name = "Coal", count = 1 },
        },
    },
    {
        name = "Smelt Mithril",
        profession = "Mining",
        skillReq = 175,
        source = "Trainer",
        outputItemId = 3860,
        avgMade = 1,
        reagents = { { itemId = 3858, name = "Mithril Ore", count = 1 } },
    },
    {
        name = "Smelt Truesilver",
        profession = "Mining",
        skillReq = 230,
        source = "Trainer",
        outputItemId = 6037,
        avgMade = 1,
        reagents = { { itemId = 7911, name = "Truesilver Ore", count = 1 } },
    },
    {
        name = "Smelt Thorium",
        profession = "Mining",
        skillReq = 250,
        source = "Trainer",
        outputItemId = 12359,
        avgMade = 1,
        reagents = { { itemId = 10620, name = "Thorium Ore", count = 1 } },
    },

    -- ==========================================
    -- BLACKSMITHING
    -- ==========================================
    {
        name = "Rough Grinding Stone",
        profession = "Blacksmithing",
        skillReq = 25,
        source = "Trainer",
        outputItemId = 3470,
        avgMade = 1,
        reagents = { { itemId = 2835, name = "Rough Stone", count = 2 } },
    },
    {
        name = "Copper Chain Pants",
        profession = "Blacksmithing",
        skillReq = 35,
        source = "Trainer",
        outputItemId = 2846,
        avgMade = 1,
        reagents = { { itemId = 2840, name = "Copper Bar", count = 4 } },
    },
    {
        name = "Coarse Grinding Stone",
        profession = "Blacksmithing",
        skillReq = 75,
        source = "Trainer",
        outputItemId = 3478,
        avgMade = 1,
        reagents = { { itemId = 2836, name = "Coarse Stone", count = 2 } },
    },
    {
        name = "Heavy Grinding Stone",
        profession = "Blacksmithing",
        skillReq = 125,
        source = "Trainer",
        outputItemId = 3486,
        avgMade = 1,
        reagents = { { itemId = 2838, name = "Heavy Stone", count = 3 } },
    },
    {
        name = "Iridescent Hammer",
        profession = "Blacksmithing",
        skillReq = 140,
        source = "Trainer",
        outputItemId = 5540,
        avgMade = 1,
        reagents = {
            { itemId = 2841, name = "Bronze Bar", count = 10 },
            { itemId = 5500, name = "Iridescent Pearl", count = 1 },
            { itemId = 2880, name = "Weak Flux", count = 2 },
        },
    },
    {
        name = "Solid Grinding Stone",
        profession = "Blacksmithing",
        skillReq = 200,
        source = "Trainer",
        outputItemId = 7966,
        avgMade = 1,
        reagents = { { itemId = 7912, name = "Solid Stone", count = 4 } },
    },
    {
        name = "Heavy Mithril Shoulder",
        profession = "Blacksmithing",
        skillReq = 205,
        source = "Trainer",
        outputItemId = 7919,
        avgMade = 1,
        reagents = {
            { itemId = 3860, name = "Mithril Bar", count = 8 },
            { itemId = 4234, name = "Heavy Leather", count = 6 },
        },
    },
    {
        name = "Heavy Mithril Gauntlets",
        profession = "Blacksmithing",
        skillReq = 205,
        source = "Trainer",
        outputItemId = 7920,
        avgMade = 1,
        reagents = {
            { itemId = 3860, name = "Mithril Bar", count = 6 },
            { itemId = 4339, name = "Bolt of Mageweave", count = 4 },
        },
    },
    {
        name = "Heavy Mithril Pants",
        profession = "Blacksmithing",
        skillReq = 210,
        source = "Vendor/Drop Plan",
        outputItemId = 7941,
        avgMade = 1,
        reagents = {
            { itemId = 3860, name = "Mithril Bar", count = 10 },
            { itemId = 1705, name = "Lesser Moonstone", count = 2 },
            { itemId = 3466, name = "Strong Flux", count = 1 },
        },
    },
    {
        name = "Mithril Shield Spike",
        profession = "Blacksmithing",
        skillReq = 215,
        source = "Drop Plan",
        outputItemId = 7967,
        avgMade = 1,
        reagents = {
            { itemId = 3860, name = "Mithril Bar", count = 4 },
            { itemId = 6037, name = "Truesilver Bar", count = 2 },
            { itemId = 7966, name = "Solid Grinding Stone", count = 4 },
        },
    },
    {
        name = "Big Black Mace",
        profession = "Blacksmithing",
        skillReq = 230,
        source = "Trainer",
        outputItemId = 7945,
        avgMade = 1,
        reagents = {
            { itemId = 3860, name = "Mithril Bar", count = 16 },
            { itemId = 7971, name = "Black Pearl", count = 1 },
            { itemId = 1210, name = "Shadowgem", count = 4 },
            { itemId = 4304, name = "Thick Leather", count = 2 },
            { itemId = 7966, name = "Solid Grinding Stone", count = 1 },
        },
    },
    {
        name = "Dense Grinding Stone",
        profession = "Blacksmithing",
        skillReq = 250,
        source = "Trainer",
        outputItemId = 12644,
        avgMade = 1,
        reagents = { { itemId = 12365, name = "Dense Stone", count = 4 } },
    },

    -- ==========================================
    -- TAILORING
    -- ==========================================
    {
        name = "Bolt of Linen Cloth",
        profession = "Tailoring",
        skillReq = 1,
        source = "Trainer",
        outputItemId = 2996,
        avgMade = 1,
        reagents = { { itemId = 2589, name = "Linen Cloth", count = 2 } },
    },
    {
        name = "Brown Linen Robe",
        profession = "Tailoring",
        skillReq = 30,
        source = "Trainer",
        outputItemId = 6238,
        avgMade = 1,
        reagents = {
            { itemId = 2996, name = "Bolt of Linen Cloth", count = 3 },
            { itemId = 2320, name = "Coarse Thread", count = 1 },
        },
    },
    {
        name = "White Linen Robe",
        profession = "Tailoring",
        skillReq = 30,
        source = "Trainer",
        outputItemId = 6241,
        avgMade = 1,
        reagents = {
            { itemId = 2996, name = "Bolt of Linen Cloth", count = 3 },
            { itemId = 2324, name = "Bleach", count = 1 },
            { itemId = 2320, name = "Coarse Thread", count = 1 },
        },
    },
    {
        name = "Bolt of Woolen Cloth",
        profession = "Tailoring",
        skillReq = 75,
        source = "Trainer",
        outputItemId = 2997,
        avgMade = 1,
        reagents = { { itemId = 2592, name = "Wool Cloth", count = 3 } },
    },
    {
        name = "Soft-soled Linen Boots",
        profession = "Tailoring",
        skillReq = 80,
        source = "Trainer",
        outputItemId = 4312,
        avgMade = 1,
        reagents = {
            { itemId = 2996, name = "Bolt of Linen Cloth", count = 5 },
            { itemId = 2318, name = "Light Leather", count = 2 },
            { itemId = 2321, name = "Fine Thread", count = 1 },
        },
    },
    {
        name = "Bolt of Silk Cloth",
        profession = "Tailoring",
        skillReq = 125,
        source = "Trainer",
        outputItemId = 4305,
        avgMade = 1,
        reagents = { { itemId = 4306, name = "Silk Cloth", count = 4 } },
    },
    {
        name = "Azure Silk Vest",
        profession = "Tailoring",
        skillReq = 150,
        source = "Trainer",
        outputItemId = 4324,
        avgMade = 1,
        reagents = {
            { itemId = 4305, name = "Bolt of Silk Cloth", count = 5 },
            { itemId = 6260, name = "Blue Dye", count = 2 },
            { itemId = 2321, name = "Fine Thread", count = 1 },
        },
    },
    {
        name = "Bolt of Mageweave",
        profession = "Tailoring",
        skillReq = 175,
        source = "Trainer",
        outputItemId = 4339,
        avgMade = 1,
        reagents = { { itemId = 4338, name = "Mageweave Cloth", count = 5 } },
    },
    {
        name = "Crimson Silk Shoulders",
        profession = "Tailoring",
        skillReq = 190,
        source = "Trainer",
        outputItemId = 7058,
        avgMade = 1,
        reagents = {
            { itemId = 4305, name = "Bolt of Silk Cloth", count = 5 },
            { itemId = 2604, name = "Red Dye", count = 2 },
            { itemId = 4291, name = "Silken Thread", count = 2 },
        },
    },
    {
        name = "White Bandit Mask",
        profession = "Tailoring",
        skillReq = 215,
        source = "Drop Pattern",
        outputItemId = 10008,
        avgMade = 1,
        reagents = {
            { itemId = 4339, name = "Bolt of Mageweave", count = 1 },
            { itemId = 2324, name = "Bleach", count = 1 },
            { itemId = 8343, name = "Heavy Silken Thread", count = 1 },
        },
    },
    {
        name = "Bolt of Runecloth",
        profession = "Tailoring",
        skillReq = 250,
        source = "Trainer",
        outputItemId = 14048,
        avgMade = 1,
        reagents = { { itemId = 14047, name = "Runecloth", count = 5 } },
    },
    {
        name = "Runecloth Belt",
        profession = "Tailoring",
        skillReq = 255,
        source = "Trainer",
        outputItemId = 13856,
        avgMade = 1,
        reagents = {
            { itemId = 14048, name = "Bolt of Runecloth", count = 2 },
            { itemId = 14341, name = "Rune Thread", count = 1 },
        },
    },
    {
        name = "Runecloth Boots",
        profession = "Tailoring",
        skillReq = 280,
        source = "Trainer",
        outputItemId = 13864,
        avgMade = 1,
        reagents = {
            { itemId = 14048, name = "Bolt of Runecloth", count = 4 },
            { itemId = 3575, name = "Iron Bar", count = 4 },
            { itemId = 4304, name = "Thick Leather", count = 2 },
            { itemId = 14341, name = "Rune Thread", count = 1 },
        },
    },
    {
        name = "Runecloth Headband",
        profession = "Tailoring",
        skillReq = 295,
        source = "Trainer",
        outputItemId = 13866,
        avgMade = 1,
        reagents = {
            { itemId = 14048, name = "Bolt of Runecloth", count = 4 },
            { itemId = 3575, name = "Iron Bar", count = 2 },
            { itemId = 14341, name = "Rune Thread", count = 1 },
        },
    },

    -- ==========================================
    -- LEATHERWORKING
    -- ==========================================
    {
        name = "Green Leather Armor",
        profession = "Leatherworking",
        skillReq = 155,
        source = "Vendor Pattern",
        outputItemId = 4255,
        avgMade = 1,
        reagents = {
            { itemId = 2319, name = "Medium Leather", count = 9 },
            { itemId = 2605, name = "Green Dye", count = 2 },
            { itemId = 2321, name = "Fine Thread", count = 4 },
        },
    },
    {
        name = "Dark Leather Shoulders",
        profession = "Leatherworking",
        skillReq = 140,
        source = "Vendor/Drop Pattern",
        outputItemId = 4252,
        avgMade = 1,
        reagents = {
            { itemId = 2319, name = "Medium Leather", count = 12 },
            { itemId = 4340, name = "Gray Dye", count = 1 },
            { itemId = 2321, name = "Fine Thread", count = 2 },
        },
    },
    {
        name = "Dusky Belt",
        profession = "Leatherworking",
        skillReq = 195,
        source = "Trainer",
        outputItemId = 7387,
        avgMade = 1,
        reagents = {
            { itemId = 4234, name = "Heavy Leather", count = 10 },
            { itemId = 4305, name = "Bolt of Silk Cloth", count = 2 },
            { itemId = 2325, name = "Black Dye", count = 2 },
            { itemId = 3575, name = "Iron Bar", count = 1 },
        },
    },
    {
        name = "Nightscape Tunic",
        profession = "Leatherworking",
        skillReq = 205,
        source = "Trainer",
        outputItemId = 8189,
        avgMade = 1,
        reagents = {
            { itemId = 4304, name = "Thick Leather", count = 7 },
            { itemId = 4291, name = "Silken Thread", count = 2 },
        },
    },
    {
        name = "Nightscape Headband",
        profession = "Leatherworking",
        skillReq = 205,
        source = "Trainer",
        outputItemId = 8191,
        avgMade = 1,
        reagents = {
            { itemId = 4304, name = "Thick Leather", count = 5 },
            { itemId = 4291, name = "Silken Thread", count = 2 },
        },
    },
    {
        name = "Wicked Leather Bracers",
        profession = "Leatherworking",
        skillReq = 265,
        source = "Vendor Pattern",
        outputItemId = 15084,
        avgMade = 1,
        reagents = {
            { itemId = 8170, name = "Rugged Leather", count = 8 },
            { itemId = 2325, name = "Black Dye", count = 1 },
            { itemId = 14341, name = "Rune Thread", count = 1 },
        },
    },
    {
        name = "Wicked Leather Headband",
        profession = "Leatherworking",
        skillReq = 280,
        source = "Vendor Pattern",
        outputItemId = 15086,
        avgMade = 1,
        reagents = {
            { itemId = 8170, name = "Rugged Leather", count = 12 },
            { itemId = 2325, name = "Black Dye", count = 1 },
            { itemId = 14341, name = "Rune Thread", count = 1 },
        },
    },

    -- ==========================================
    -- ENCHANTING (Wands)
    -- ==========================================
    {
        name = "Lesser Magic Wand",
        profession = "Enchanting",
        skillReq = 10,
        source = "Trainer",
        outputItemId = 11287,
        avgMade = 1,
        reagents = {
            { itemId = 4470, name = "Simple Wood", count = 1 },
            { itemId = 10938, name = "Lesser Magic Essence", count = 1 },
        },
    },
    {
        name = "Greater Magic Wand",
        profession = "Enchanting",
        skillReq = 70,
        source = "Trainer",
        outputItemId = 11288,
        avgMade = 1,
        reagents = {
            { itemId = 4470, name = "Simple Wood", count = 1 },
            { itemId = 10939, name = "Greater Magic Essence", count = 1 },
        },
    },
    {
        name = "Lesser Mystic Wand",
        profession = "Enchanting",
        skillReq = 155,
        source = "Trainer",
        outputItemId = 11289,
        avgMade = 1,
        reagents = {
            { itemId = 11291, name = "Star Wood", count = 1 },
            { itemId = 11134, name = "Lesser Mystic Essence", count = 1 },
            { itemId = 11083, name = "Soul Dust", count = 1 },
        },
    },
    {
        name = "Greater Mystic Wand",
        profession = "Enchanting",
        skillReq = 175,
        source = "Trainer",
        outputItemId = 11290,
        avgMade = 1,
        reagents = {
            { itemId = 11291, name = "Star Wood", count = 1 },
            { itemId = 11135, name = "Greater Mystic Essence", count = 1 },
            { itemId = 11137, name = "Vision Dust", count = 1 },
        },
    },
}

function PF.RecipeDatabase.GetAllBaselineRecipes()
    return BASELINE_RECIPES
end

function PF.RecipeDatabase.GetCharacterSkillRanks()
    local skills = {}
    if _G.GetNumSkillLines and _G.GetSkillLineInfo then
        local okNum, numLines = pcall(_G.GetNumSkillLines)
        if okNum and type(numLines) == "number" and numLines > 0 then
            for i = 1, numLines do
                local okLine, skillName, isHeader, _, skillRank, _, _, skillMaxRank = pcall(_G.GetSkillLineInfo, i)
                if okLine and not isHeader and type(skillName) == "string" and type(skillRank) == "number" and skillRank > 0 then
                    skills[skillName] = {
                        rank = skillRank,
                        maxRank = skillMaxRank or 300,
                    }
                end
            end
        end
    end
    return skills
end
