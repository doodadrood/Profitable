local _, PF = ...
PF = type(PF) == "table" and PF or _G.PF or {}
_G.PF = PF

PF.VendorDatabase = {}

-- Unit buy prices in copper from standard NPC trade/profession vendors (before faction discount;
-- using base price is conservative and safe, while MERCHANT_SHOW updates exact discounted price).
local STATIC_VENDOR_BUY_PRICES = {
    -- Threads & Curing (Tailoring / Leatherworking)
    [2320]  = { price = 10,     name = "Coarse Thread" },
    [2321]  = { price = 100,    name = "Fine Thread" },
    [4291]  = { price = 500,    name = "Silken Thread" },
    [8343]  = { price = 2000,   name = "Heavy Silken Thread" },
    [14341] = { price = 5000,   name = "Rune Thread" },
    [4289]  = { price = 50,     name = "Salt" },

    -- Dyes & Bleach
    [2324]  = { price = 25,     name = "Bleach" },
    [2604]  = { price = 50,     name = "Red Dye" },
    [6260]  = { price = 50,     name = "Blue Dye" },
    [2605]  = { price = 100,    name = "Green Dye" },
    [4340]  = { price = 350,    name = "Gray Dye" },
    [4341]  = { price = 500,    name = "Yellow Dye" },
    [6261]  = { price = 1000,   name = "Orange Dye" },
    [2325]  = { price = 1000,   name = "Black Dye" },
    [4342]  = { price = 2500,   name = "Purple Dye" },
    [10290] = { price = 2500,   name = "Pink Dye" },

    -- Flux, Coal, Wood, Stocks (Blacksmithing / Engineering / Enchanting)
    [2880]  = { price = 100,    name = "Weak Flux" },
    [3466]  = { price = 2000,   name = "Strong Flux" },
    [18567] = { price = 150000, name = "Elemental Flux" },
    [3857]  = { price = 500,    name = "Coal" },
    [4470]  = { price = 38,     name = "Simple Wood" },
    [11291] = { price = 4500,   name = "Star Wood" },
    [4399]  = { price = 2000,   name = "Wooden Stock" },
    [4400]  = { price = 2000,   name = "Heavy Stock" },
    [6217]  = { price = 124,    name = "Copper Rod" },
    [10647] = { price = 2000,   name = "Engineer's Ink" },
    [10648] = { price = 15,     name = "Common Parchment" },

    -- Vials (Alchemy - unit price per 1 vial)
    [3371]  = { price = 4,      name = "Empty Vial" },
    [3372]  = { price = 40,     name = "Leaded Vial" },
    [8925]  = { price = 500,    name = "Crystal Vial" },
    [18256] = { price = 3000,   name = "Imbued Vial" },

    -- Cooking Spices & Vendor Beverages
    [2678]  = { price = 10,     name = "Mild Spices" },
    [2692]  = { price = 40,     name = "Hot Spices" },
    [3713]  = { price = 160,    name = "Soothing Spices" },
    [159]   = { price = 5,      name = "Refreshing Spring Water" },
    [1179]  = { price = 25,     name = "Ice Cold Milk" },
    [2894]  = { price = 50,     name = "Rhapsody Malt" },
    [2596]  = { price = 120,    name = "Skin of Dwarven Stout" },
    [2593]  = { price = 150,    name = "Flask of Stormwind Tawny" },
    [2594]  = { price = 1500,   name = "Flagon of Dwarven Honeymead" },
}

-- Seed metadata for common Classic / Forever materials, enchanting mats, and crafted items
-- Used when the local WoW client cache hasn't loaded GetItemInfo(itemId) yet.
-- classID: 2 = Weapon, 4 = Armor, 7 = Trade Goods
local SEED_ITEM_METADATA = {
    -- Herbs
    [2447]  = { name = "Peacebloom",               quality = 1, itemLevel = 1,  classID = 7, vendorSell = 10 },
    [765]   = { name = "Silverleaf",               quality = 1, itemLevel = 1,  classID = 7, vendorSell = 10 },
    [2449]  = { name = "Earthroot",                quality = 1, itemLevel = 5,  classID = 7, vendorSell = 20 },
    [785]   = { name = "Mageroyal",                quality = 1, itemLevel = 10, classID = 7, vendorSell = 20 },
    [2450]  = { name = "Briarthorn",               quality = 1, itemLevel = 15, classID = 7, vendorSell = 25 },
    [2452]  = { name = "Swiftthistle",             quality = 1, itemLevel = 15, classID = 7, vendorSell = 15 },
    [2453]  = { name = "Bruiseweed",               quality = 1, itemLevel = 20, classID = 7, vendorSell = 25 },
    [3356]  = { name = "Kingsblood",               quality = 1, itemLevel = 25, classID = 7, vendorSell = 30 },
    [3357]  = { name = "Liferoot",                 quality = 1, itemLevel = 30, classID = 7, vendorSell = 75 },
    [3818]  = { name = "Fadeleaf",                 quality = 1, itemLevel = 32, classID = 7, vendorSell = 125 },
    [3821]  = { name = "Goldthorn",                quality = 1, itemLevel = 34, classID = 7, vendorSell = 150 },
    [3358]  = { name = "Khadgar's Whisker",        quality = 1, itemLevel = 36, classID = 7, vendorSell = 175 },
    [8838]  = { name = "Sungrass",                 quality = 1, itemLevel = 46, classID = 7, vendorSell = 300 },
    [8839]  = { name = "Blindweed",                quality = 1, itemLevel = 47, classID = 7, vendorSell = 325 },
    [8845]  = { name = "Ghost Mushroom",           quality = 1, itemLevel = 49, classID = 7, vendorSell = 375 },
    [8846]  = { name = "Gromsblood",               quality = 1, itemLevel = 50, classID = 7, vendorSell = 375 },
    [13463] = { name = "Dreamfoil",                quality = 1, itemLevel = 54, classID = 7, vendorSell = 500 },
    [13464] = { name = "Golden Sansam",            quality = 1, itemLevel = 52, classID = 7, vendorSell = 400 },
    [13465] = { name = "Mountain Silversage",      quality = 1, itemLevel = 56, classID = 7, vendorSell = 600 },
    [13466] = { name = "Plaguebloom",              quality = 1, itemLevel = 57, classID = 7, vendorSell = 600 },
    [13467] = { name = "Icecap",                   quality = 1, itemLevel = 58, classID = 7, vendorSell = 625 },
    [13468] = { name = "Black Lotus",              quality = 2, itemLevel = 60, classID = 7, vendorSell = 1000 },

    -- Ores, Stones, and Bars
    [2770]  = { name = "Copper Ore",               quality = 1, itemLevel = 5,  classID = 7, vendorSell = 5 },
    [2840]  = { name = "Copper Bar",               quality = 1, itemLevel = 5,  classID = 7, vendorSell = 10 },
    [2771]  = { name = "Tin Ore",                  quality = 1, itemLevel = 15, classID = 7, vendorSell = 25 },
    [3576]  = { name = "Tin Bar",                  quality = 1, itemLevel = 15, classID = 7, vendorSell = 30 },
    [2841]  = { name = "Bronze Bar",               quality = 1, itemLevel = 15, classID = 7, vendorSell = 50 },
    [2775]  = { name = "Silver Ore",               quality = 2, itemLevel = 15, classID = 7, vendorSell = 50 },
    [2842]  = { name = "Silver Bar",               quality = 2, itemLevel = 15, classID = 7, vendorSell = 100 },
    [2772]  = { name = "Iron Ore",                 quality = 1, itemLevel = 25, classID = 7, vendorSell = 75 },
    [3575]  = { name = "Iron Bar",                 quality = 1, itemLevel = 25, classID = 7, vendorSell = 200 },
    [3859]  = { name = "Steel Bar",                quality = 1, itemLevel = 30, classID = 7, vendorSell = 250 },
    [2776]  = { name = "Gold Ore",                 quality = 2, itemLevel = 31, classID = 7, vendorSell = 400 },
    [3577]  = { name = "Gold Bar",                 quality = 2, itemLevel = 31, classID = 7, vendorSell = 600 },
    [3858]  = { name = "Mithril Ore",              quality = 1, itemLevel = 35, classID = 7, vendorSell = 250 },
    [3860]  = { name = "Mithril Bar",              quality = 1, itemLevel = 35, classID = 7, vendorSell = 400 },
    [7911]  = { name = "Truesilver Ore",           quality = 2, itemLevel = 45, classID = 7, vendorSell = 500 },
    [6037]  = { name = "Truesilver Bar",           quality = 2, itemLevel = 45, classID = 7, vendorSell = 500 },
    [10620] = { name = "Thorium Ore",              quality = 1, itemLevel = 45, classID = 7, vendorSell = 500 },
    [12359] = { name = "Thorium Bar",              quality = 1, itemLevel = 45, classID = 7, vendorSell = 600 },
    [12655] = { name = "Enchanted Thorium Bar",    quality = 1, itemLevel = 50, classID = 7, vendorSell = 1000 },
    [12360] = { name = "Arcanite Bar",             quality = 2, itemLevel = 55, classID = 7, vendorSell = 5000 },
    [2835]  = { name = "Rough Stone",              quality = 1, itemLevel = 5,  classID = 7, vendorSell = 2 },
    [2836]  = { name = "Coarse Stone",             quality = 1, itemLevel = 15, classID = 7, vendorSell = 15 },
    [2838]  = { name = "Heavy Stone",              quality = 1, itemLevel = 25, classID = 7, vendorSell = 60 },
    [7912]  = { name = "Solid Stone",              quality = 1, itemLevel = 35, classID = 7, vendorSell = 100 },
    [12365] = { name = "Dense Stone",              quality = 1, itemLevel = 45, classID = 7, vendorSell = 250 },
    [3470]  = { name = "Rough Grinding Stone",     quality = 1, itemLevel = 5,  classID = 7, vendorSell = 5 },
    [3478]  = { name = "Coarse Grinding Stone",    quality = 1, itemLevel = 15, classID = 7, vendorSell = 10 },
    [3486]  = { name = "Heavy Grinding Stone",     quality = 1, itemLevel = 25, classID = 7, vendorSell = 100 },
    [7966]  = { name = "Solid Grinding Stone",     quality = 1, itemLevel = 35, classID = 7, vendorSell = 200 },
    [12644] = { name = "Dense Grinding Stone",     quality = 1, itemLevel = 50, classID = 7, vendorSell = 500 },

    -- Cloth & Bolts
    [2589]  = { name = "Linen Cloth",              quality = 1, itemLevel = 5,  classID = 7, vendorSell = 13 },
    [2996]  = { name = "Bolt of Linen Cloth",      quality = 1, itemLevel = 5,  classID = 7, vendorSell = 30 },
    [2592]  = { name = "Wool Cloth",               quality = 1, itemLevel = 15, classID = 7, vendorSell = 33 },
    [2997]  = { name = "Bolt of Woolen Cloth",     quality = 1, itemLevel = 15, classID = 7, vendorSell = 100 },
    [4306]  = { name = "Silk Cloth",               quality = 1, itemLevel = 30, classID = 7, vendorSell = 150 },
    [4305]  = { name = "Bolt of Silk Cloth",       quality = 1, itemLevel = 30, classID = 7, vendorSell = 600 },
    [4338]  = { name = "Mageweave Cloth",          quality = 1, itemLevel = 40, classID = 7, vendorSell = 250 },
    [4339]  = { name = "Bolt of Mageweave",        quality = 1, itemLevel = 40, classID = 7, vendorSell = 1000 },
    [14047] = { name = "Runecloth",                quality = 1, itemLevel = 50, classID = 7, vendorSell = 400 },
    [14048] = { name = "Bolt of Runecloth",        quality = 1, itemLevel = 50, classID = 7, vendorSell = 1600 },
    [14256] = { name = "Felcloth",                 quality = 1, itemLevel = 54, classID = 7, vendorSell = 1000 },
    [14342] = { name = "Mooncloth",                quality = 1, itemLevel = 55, classID = 7, vendorSell = 2000 },

    -- Leather & Hides
    [2934]  = { name = "Ruined Leather Scraps",    quality = 1, itemLevel = 1,  classID = 7, vendorSell = 7 },
    [2318]  = { name = "Light Leather",            quality = 1, itemLevel = 10, classID = 7, vendorSell = 15 },
    [783]   = { name = "Light Hide",               quality = 1, itemLevel = 10, classID = 7, vendorSell = 50 },
    [4231]  = { name = "Cured Light Hide",         quality = 1, itemLevel = 15, classID = 7, vendorSell = 90 },
    [2319]  = { name = "Medium Leather",           quality = 1, itemLevel = 20, classID = 7, vendorSell = 50 },
    [4232]  = { name = "Medium Hide",              quality = 1, itemLevel = 20, classID = 7, vendorSell = 120 },
    [4233]  = { name = "Cured Medium Hide",        quality = 1, itemLevel = 25, classID = 7, vendorSell = 230 },
    [4234]  = { name = "Heavy Leather",            quality = 1, itemLevel = 30, classID = 7, vendorSell = 150 },
    [4235]  = { name = "Heavy Hide",               quality = 1, itemLevel = 30, classID = 7, vendorSell = 200 },
    [4236]  = { name = "Cured Heavy Hide",         quality = 1, itemLevel = 35, classID = 7, vendorSell = 500 },
    [4304]  = { name = "Thick Leather",            quality = 1, itemLevel = 40, classID = 7, vendorSell = 300 },
    [8169]  = { name = "Thick Hide",               quality = 1, itemLevel = 40, classID = 7, vendorSell = 500 },
    [8172]  = { name = "Cured Thick Hide",         quality = 1, itemLevel = 45, classID = 7, vendorSell = 700 },
    [8170]  = { name = "Rugged Leather",           quality = 1, itemLevel = 50, classID = 7, vendorSell = 500 },
    [8171]  = { name = "Rugged Hide",              quality = 1, itemLevel = 50, classID = 7, vendorSell = 500 },
    [15407] = { name = "Cured Rugged Hide",        quality = 1, itemLevel = 55, classID = 7, vendorSell = 3000 },

    -- Gems
    [774]   = { name = "Malachite",                quality = 2, itemLevel = 10, classID = 7, vendorSell = 15 },
    [818]   = { name = "Tigerseye",                quality = 2, itemLevel = 15, classID = 7, vendorSell = 100 },
    [1210]  = { name = "Shadowgem",                quality = 2, itemLevel = 20, classID = 7, vendorSell = 250 },
    [1705]  = { name = "Lesser Moonstone",         quality = 2, itemLevel = 25, classID = 7, vendorSell = 300 },
    [1206]  = { name = "Moss Agate",               quality = 2, itemLevel = 25, classID = 7, vendorSell = 400 },
    [3864]  = { name = "Citrine",                  quality = 2, itemLevel = 35, classID = 7, vendorSell = 800 },
    [1529]  = { name = "Jade",                     quality = 2, itemLevel = 30, classID = 7, vendorSell = 700 },
    [7909]  = { name = "Aquamarine",               quality = 2, itemLevel = 40, classID = 7, vendorSell = 1000 },
    [7910]  = { name = "Star Ruby",                quality = 2, itemLevel = 45, classID = 7, vendorSell = 1250 },
    [12361] = { name = "Blue Sapphire",            quality = 2, itemLevel = 55, classID = 7, vendorSell = 2000 },
    [12364] = { name = "Huge Emerald",             quality = 2, itemLevel = 55, classID = 7, vendorSell = 2500 },
    [12799] = { name = "Large Opal",               quality = 2, itemLevel = 55, classID = 7, vendorSell = 2000 },
    [12800] = { name = "Azerothian Diamond",       quality = 2, itemLevel = 55, classID = 7, vendorSell = 2500 },
    [5498]  = { name = "Small Lustrous Pearl",     quality = 2, itemLevel = 15, classID = 7, vendorSell = 100 },
    [5500]  = { name = "Iridescent Pearl",         quality = 2, itemLevel = 25, classID = 7, vendorSell = 250 },
    [7971]  = { name = "Black Pearl",              quality = 2, itemLevel = 35, classID = 7, vendorSell = 1000 },
    [13926] = { name = "Golden Pearl",             quality = 2, itemLevel = 45, classID = 7, vendorSell = 4000 },

    -- Enchanting Materials
    [10940] = { name = "Strange Dust",             quality = 1, itemLevel = 5,  classID = 7, vendorSell = 0 },
    [11083] = { name = "Soul Dust",                quality = 1, itemLevel = 20, classID = 7, vendorSell = 0 },
    [11137] = { name = "Vision Dust",              quality = 1, itemLevel = 30, classID = 7, vendorSell = 0 },
    [11176] = { name = "Dream Dust",               quality = 1, itemLevel = 40, classID = 7, vendorSell = 0 },
    [16204] = { name = "Illusion Dust",            quality = 1, itemLevel = 50, classID = 7, vendorSell = 0 },
    [10938] = { name = "Lesser Magic Essence",     quality = 2, itemLevel = 10, classID = 7, vendorSell = 0 },
    [10939] = { name = "Greater Magic Essence",    quality = 2, itemLevel = 15, classID = 7, vendorSell = 0 },
    [10998] = { name = "Lesser Astral Essence",    quality = 2, itemLevel = 20, classID = 7, vendorSell = 0 },
    [11082] = { name = "Greater Astral Essence",   quality = 2, itemLevel = 25, classID = 7, vendorSell = 0 },
    [11134] = { name = "Lesser Mystic Essence",    quality = 2, itemLevel = 30, classID = 7, vendorSell = 0 },
    [11135] = { name = "Greater Mystic Essence",   quality = 2, itemLevel = 35, classID = 7, vendorSell = 0 },
    [11174] = { name = "Lesser Nether Essence",    quality = 2, itemLevel = 40, classID = 7, vendorSell = 0 },
    [11175] = { name = "Greater Nether Essence",   quality = 2, itemLevel = 45, classID = 7, vendorSell = 0 },
    [16202] = { name = "Lesser Eternal Essence",   quality = 2, itemLevel = 50, classID = 7, vendorSell = 0 },
    [16203] = { name = "Greater Eternal Essence",  quality = 2, itemLevel = 55, classID = 7, vendorSell = 0 },
    [10978] = { name = "Small Glimmering Shard",   quality = 3, itemLevel = 20, classID = 7, vendorSell = 0 },
    [11084] = { name = "Large Glimmering Shard",   quality = 3, itemLevel = 25, classID = 7, vendorSell = 0 },
    [11138] = { name = "Small Glowing Shard",      quality = 3, itemLevel = 30, classID = 7, vendorSell = 0 },
    [11139] = { name = "Large Glowing Shard",      quality = 3, itemLevel = 35, classID = 7, vendorSell = 0 },
    [11177] = { name = "Small Radiant Shard",      quality = 3, itemLevel = 40, classID = 7, vendorSell = 0 },
    [11178] = { name = "Large Radiant Shard",      quality = 3, itemLevel = 45, classID = 7, vendorSell = 0 },
    [14343] = { name = "Small Brilliant Shard",    quality = 3, itemLevel = 50, classID = 7, vendorSell = 0 },
    [14344] = { name = "Large Brilliant Shard",    quality = 3, itemLevel = 55, classID = 7, vendorSell = 0 },
    [20725] = { name = "Nexus Crystal",            quality = 4, itemLevel = 60, classID = 7, vendorSell = 0 },

    -- Common Crafted Items (Examples & Classics)
    [2846]  = { name = "Copper Chain Pants",       quality = 1, itemLevel = 9,  classID = 4, invType = "INVTYPE_LEGS",     vendorSell = 107 },
    [5540]  = { name = "Iridescent Hammer",        quality = 2, itemLevel = 26, classID = 2, invType = "INVTYPE_WEAPON",   vendorSell = 3194 },
    [7967]  = { name = "Mithril Shield Spike",     quality = 2, itemLevel = 43, classID = 7, invType = "",                 vendorSell = 1500 },
    [6238]  = { name = "Brown Linen Robe",         quality = 2, itemLevel = 10, classID = 4, invType = "INVTYPE_ROBE",     vendorSell = 64 },
    [6241]  = { name = "White Linen Robe",         quality = 2, itemLevel = 10, classID = 4, invType = "INVTYPE_ROBE",     vendorSell = 66 },
    [4312]  = { name = "Soft-soled Linen Boots",   quality = 2, itemLevel = 16, classID = 4, invType = "INVTYPE_FEET",     vendorSell = 200 },
    [4324]  = { name = "Azure Silk Vest",          quality = 2, itemLevel = 35, classID = 4, invType = "INVTYPE_CHEST",    vendorSell = 1647 },
    [7058]  = { name = "Crimson Silk Shoulders",   quality = 2, itemLevel = 38, classID = 4, invType = "INVTYPE_SHOULDER", vendorSell = 2166 },
    [10008] = { name = "White Bandit Mask",        quality = 2, itemLevel = 43, classID = 4, invType = "INVTYPE_HEAD",     vendorSell = 2472 },
    [13856] = { name = "Runecloth Belt",           quality = 2, itemLevel = 51, classID = 4, invType = "INVTYPE_WAIST",    vendorSell = 4247 },
    [13864] = { name = "Runecloth Boots",          quality = 2, itemLevel = 54, classID = 4, invType = "INVTYPE_FEET",     vendorSell = 10035 },
    [13866] = { name = "Runecloth Headband",       quality = 2, itemLevel = 57, classID = 4, invType = "INVTYPE_HEAD",     vendorSell = 9188 },
    [15086] = { name = "Wicked Leather Headband",  quality = 2, itemLevel = 56, classID = 4, invType = "INVTYPE_HEAD",     vendorSell = 9821 },
    [15084] = { name = "Wicked Leather Bracers",   quality = 2, itemLevel = 53, classID = 4, invType = "INVTYPE_WRIST",    vendorSell = 4831 },
    [4255]  = { name = "Green Leather Armor",      quality = 2, itemLevel = 26, classID = 4, invType = "INVTYPE_CHEST",    vendorSell = 1140 },
    [4252]  = { name = "Dark Leather Shoulders",   quality = 2, itemLevel = 30, classID = 4, invType = "INVTYPE_SHOULDER", vendorSell = 1480 },
    [7387]  = { name = "Dusky Belt",               quality = 2, itemLevel = 37, classID = 4, invType = "INVTYPE_WAIST",    vendorSell = 1423 },
    [8189]  = { name = "Nightscape Tunic",         quality = 2, itemLevel = 42, classID = 4, invType = "INVTYPE_CHEST",    vendorSell = 3893 },
    [8191]  = { name = "Nightscape Headband",      quality = 2, itemLevel = 43, classID = 4, invType = "INVTYPE_HEAD",     vendorSell = 3370 },
    [11287] = { name = "Lesser Magic Wand",        quality = 2, itemLevel = 13, classID = 2, invType = "INVTYPE_RANGED",   vendorSell = 519 },
    [11288] = { name = "Greater Magic Wand",       quality = 2, itemLevel = 18, classID = 2, invType = "INVTYPE_RANGED",   vendorSell = 1546 },
    [11289] = { name = "Lesser Mystic Wand",       quality = 2, itemLevel = 30, classID = 2, invType = "INVTYPE_RANGED",   vendorSell = 4159 },
    [11290] = { name = "Greater Mystic Wand",      quality = 2, itemLevel = 35, classID = 2, invType = "INVTYPE_RANGED",   vendorSell = 8656 },
    [3853]  = { name = "Moonsteel Broadsword",     quality = 3, itemLevel = 36, classID = 2, invType = "INVTYPE_2HWEAPON", vendorSell = 12450 },
    [7941]  = { name = "Heavy Mithril Pants",      quality = 2, itemLevel = 42, classID = 4, invType = "INVTYPE_LEGS",     vendorSell = 4560 },
    [7920]  = { name = "Heavy Mithril Gauntlets",  quality = 2, itemLevel = 40, classID = 4, invType = "INVTYPE_HAND",     vendorSell = 2490 },
    [7919]  = { name = "Heavy Mithril Shoulder",   quality = 2, itemLevel = 40, classID = 4, invType = "INVTYPE_SHOULDER", vendorSell = 2780 },
    [7945]  = { name = "Big Black Mace",           quality = 2, itemLevel = 45, classID = 2, invType = "INVTYPE_2HWEAPON", vendorSell = 7105 },
}

for id, entry in pairs(STATIC_VENDOR_BUY_PRICES) do
    if not SEED_ITEM_METADATA[id] then
        SEED_ITEM_METADATA[id] = {
            name = entry.name,
            quality = 1,
            itemLevel = 1,
            classID = 7,
            vendorSell = math.floor(entry.price / 4),
        }
    end
end

function PF.VendorDatabase.GetVendorBuyPrice(itemId)
    if not itemId or itemId <= 0 then return nil end
    if Profitable_DB and Profitable_DB.vendorBuyPrices and Profitable_DB.vendorBuyPrices[itemId] then
        local dynamicPrice = Profitable_DB.vendorBuyPrices[itemId]
        if type(dynamicPrice) == "number" and dynamicPrice > 0 then
            return dynamicPrice
        end
    end
    local staticEntry = STATIC_VENDOR_BUY_PRICES[itemId]
    if staticEntry and staticEntry.price and staticEntry.price > 0 then
        return staticEntry.price
    end
    return nil
end

function PF.VendorDatabase.IsVendorReagent(itemId)
    return PF.VendorDatabase.GetVendorBuyPrice(itemId) ~= nil
end

local function QueryGameItemInfo(target)
    if not target then return nil end
    local getInfo = (_G.C_Item and _G.C_Item.GetItemInfo) or _G.GetItemInfo
    if type(getInfo) ~= "function" then
        return nil
    end

    local ok, itemName, itemLink, itemQuality, itemLevel, itemMinLevel, itemType, itemSubType,
        itemStackCount, itemEquipLoc, itemTexture, sellPrice, classID, subclassID = pcall(getInfo, target)
    if not ok or not itemName then
        if type(target) == "number" and _G.C_Item and type(_G.C_Item.RequestLoadItemDataByID) == "function" then
            pcall(_G.C_Item.RequestLoadItemDataByID, target)
        end
        return nil
    end

    if not classID then
        if itemType == "Weapon" or itemType == _G.AUCTION_CATEGORY_WEAPONS then
            classID = 2
        elseif itemType == "Armor" or itemType == _G.AUCTION_CATEGORY_ARMOR then
            classID = 4
        elseif itemType == "Trade Goods" then
            classID = 7
        end
    end

    return {
        name = itemName,
        link = itemLink,
        quality = itemQuality or 1,
        itemLevel = itemLevel or 1,
        minLevel = itemMinLevel or 1,
        itemType = itemType,
        itemSubType = itemSubType,
        stackCount = itemStackCount or 1,
        invType = itemEquipLoc or "",
        texture = itemTexture,
        vendorSell = sellPrice or 0,
        classID = classID,
        subClassID = subclassID,
    }
end

function PF.VendorDatabase.GetItemMetadata(itemId, itemLink)
    if not itemId and type(itemLink) == "string" then
        itemId = tonumber(itemLink:match("item:(%d+)"))
    end
    if not itemId or itemId <= 0 then
        return nil
    end

    local live = QueryGameItemInfo(itemLink or itemId)
    if live then
        if Profitable_DB and Profitable_DB.itemCache then
            Profitable_DB.itemCache[itemId] = live
        end
        return live
    end

    if Profitable_DB and Profitable_DB.itemCache and Profitable_DB.itemCache[itemId] then
        return Profitable_DB.itemCache[itemId]
    end

    local seed = SEED_ITEM_METADATA[itemId]
    if seed then
        return seed
    end

    return nil
end

function PF.VendorDatabase.GetVendorSellPrice(itemId, itemLink)
    local meta = PF.VendorDatabase.GetItemMetadata(itemId, itemLink)
    if meta and type(meta.vendorSell) == "number" and meta.vendorSell > 0 then
        return meta.vendorSell
    end
    if _G.PCF and _G.PCF.ProviderRegistry and _G.PCF.ProviderRegistry.GetVendorPrice then
        local ok, vp = pcall(_G.PCF.ProviderRegistry.GetVendorPrice, itemLink, itemId)
        if ok and type(vp) == "number" and vp > 0 then
            return vp
        end
    end
    return nil
end

function PF.VendorDatabase.ScanOpenMerchant()
    if not _G.GetMerchantNumItems or not _G.GetMerchantItemInfo then
        return 0
    end
    local okNum, numItems = pcall(_G.GetMerchantNumItems)
    if not okNum or type(numItems) ~= "number" or numItems <= 0 then
        return 0
    end

    Profitable_DB = Profitable_DB or {}
    Profitable_DB.vendorBuyPrices = Profitable_DB.vendorBuyPrices or {}
    Profitable_DB.vendorAlerts = {}

    local ahCut = (PF.GetEffectiveAHCutRate and PF.GetEffectiveAHCutRate()) or 0.05
    local alertsEnabled = not (Profitable_DB.settings and Profitable_DB.settings.enableVendorArbitrageAlerts == false)

    local learned = 0
    for i = 1, numItems do
        local okInfo, name, texture, price, quantity, numAvailable = pcall(_G.GetMerchantItemInfo, i)
        if okInfo and price and price > 0 then
            local link = _G.GetMerchantItemLink and _G.GetMerchantItemLink(i)
            local itemId = link and tonumber(link:match("item:(%d+)"))
            if itemId and itemId > 0 then
                local qty = (quantity and quantity > 0) and quantity or 1
                local unitPrice = math.max(1, math.floor((price / qty) + 0.5))
                PF.VendorDatabase.GetItemMetadata(itemId, link)

                -- Unlimited stock (numAvailable == -1) is recorded as a reliable vendor reagent price
                if numAvailable == nil or numAvailable == -1 then
                    Profitable_DB.vendorBuyPrices[itemId] = unitPrice
                    learned = learned + 1
                end

                -- Check Limited-Supply (or underpriced) Vendor -> AH Arbitrage (after 5% AH cut!)
                if alertsEnabled and numAvailable and numAvailable > 0 and PF.OpportunityEngine and PF.OpportunityEngine.ResolveAHPrice then
                    local ahUnit = PF.OpportunityEngine.ResolveAHPrice(itemId, link)
                    if ahUnit and ahUnit > 0 then
                        local netAHUnit = math.floor(ahUnit * (1 - ahCut))
                        local unitProfit = netAHUnit - unitPrice
                        if unitProfit >= 1000 and netAHUnit >= (unitPrice * 1.5) then
                            local displayLink = PF.Formatter.BuildItemLink(itemId, name, nil, link)
                            local totalProfit = unitProfit * numAvailable
                            table.insert(Profitable_DB.vendorAlerts, {
                                merchantIndex = i,
                                itemId = itemId,
                                name = name or ("Item #" .. itemId),
                                link = displayLink,
                                stock = numAvailable,
                                unitBuyPrice = unitPrice,
                                unitAHGross = ahUnit,
                                unitAHNet = netAHUnit,
                                unitProfit = unitProfit,
                                totalProfit = totalProfit,
                            })
                            print(string.format(
                                "|cff00ff88[Profitable Vendor Alert]|r %s (x%d in stock) costs %s ea, sells on AH for %s (%s net after %d%% cut) -> |cff00ff00+%s profit!|r",
                                displayLink,
                                numAvailable,
                                PF.Formatter.FormatMoney(unitPrice),
                                PF.Formatter.FormatMoney(ahUnit),
                                PF.Formatter.FormatMoney(netAHUnit),
                                math.floor(ahCut * 100 + 0.5),
                                PF.Formatter.FormatMoney(totalProfit)
                            ))
                        end
                    end
                end
            end
        end
    end
    return learned
end

function PF.VendorDatabase.Init()
    if PF.VendorDatabase._initialized then return end
    PF.VendorDatabase._initialized = true

    local frame = CreateFrame("Frame")
    if frame and frame.RegisterEvent then
        pcall(frame.RegisterEvent, frame, "MERCHANT_SHOW")
        pcall(frame.RegisterEvent, frame, "MERCHANT_UPDATE")
        frame:SetScript("OnEvent", function()
            PF.VendorDatabase.ScanOpenMerchant()
        end)
    end
    PF.VendorDatabase.frame = frame
end
