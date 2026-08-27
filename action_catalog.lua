local M = {}
local ACTION_CATEGORIES = { 'spells', 'job_abilities', 'weapon_skills' }
local TRUST_SPELL_MIN_ID, TRUST_SPELL_MAX_ID = 896, 1019
local JOB_ABILITY_MIN_ID, JOB_ABILITY_MAX_ID = 0x200, 0x3FF
local COMMAND_PREFIXES = {
    spell = '/ma',
    ability = '/ja',
    weaponskill = '/ws',
}
local SONG_BUFFS = {
    { 'paeon', 195 }, { 'ballad', 196 }, { 'minne', 197 }, { 'minuet', 198 },
    { 'madrigal', 199 }, { 'prelude', 200 }, { 'mambo', 201 }, { 'aubade', 202 },
    { 'pastoral', 203 }, { 'humming', 204 }, { 'fantasia', 205 }, { 'operetta', 206 },
    { 'capriccio', 207 }, { 'serenade', 208 }, { 'round', 209 }, { 'gavotte', 210 },
    { 'fugue', 211 }, { 'rhapsody', 212 }, { 'aria', 213 }, { 'march', 214 },
    { 'etude', 215 }, { 'carol', 216 }, { 'hymnus', 218 }, { 'mazurka', 219 },
    { 'sirvente', 220 }, { 'dirge', 221 }, { 'scherzo', 222 },
}

local function text(value)
    if type(value) == 'string' then
        return value
    end
    if value ~= nil then
        local ok, result = pcall(function()
            return value[1] or value[0] or value[2] or value[3] or value[4]
        end)
        if ok and type(result) == 'string' then
            return result
        end
    end
    return ''
end

local function enabled(value)
    return value == true or value == 1
end

local function song_buff_id(name, targets)
    if bit.band(targets or 0, 0x20) ~= 0 then
        return nil
    end
    local lower = name:lower()
    for _, entry in ipairs(SONG_BUFFS) do
        if lower:find(entry[1], 1, true) then
            return entry[2]
        end
    end
    return nil
end

local function usable_spell(player, spell)
    local main_job, sub_job = player:GetMainJob(), player:GetSubJob()
    local main_req = spell.LevelRequired and spell.LevelRequired[main_job + 1] or 0
    local sub_req = spell.LevelRequired and spell.LevelRequired[sub_job + 1] or 0
    return (main_req and main_req > 0 and main_req <= player:GetMainJobLevel())
        or (sub_req and sub_req > 0 and sub_req <= player:GetSubJobLevel())
end

local function add(result, seen, action)
    if action.name == '' or seen[action.key] then
        return
    end
    seen[action.key] = true
    table.insert(result[action.category], action)
    result.by_key[action.key] = action
end

function M.build(player, resources)
    local result = { spells = {}, job_abilities = {}, weapon_skills = {}, by_key = {} }
    local seen = {}
    if player == nil then
        return result
    end

    if enabled(player:HasSpellData()) then
        for id = 0, 1023 do
            local spell = resources:GetSpellById(id)
            local is_trust = id >= TRUST_SPELL_MIN_ID and id <= TRUST_SPELL_MAX_ID
            if not is_trust and spell and enabled(player:HasSpell(id)) and usable_spell(player, spell) then
                local name = text(spell.Name)
                add(result, seen, {
                    key = 'spell:' .. id,
                    id = id,
                    packet_id = spell.Index or id,
                    category = 'spells',
                    kind = 'spell',
                    name = name,
                    description = text(spell.Description):lower(),
                    targets = spell.Targets or 0,
                    mana = spell.ManaCost or 0,
                    cast_time = (spell.CastTime or 0) / 4,
                    skill = spell.Skill,
                    status_id = song_buff_id(name, spell.Targets),
                    is_song = spell.Skill == 40,
                    recast_id = spell.Index or id,
                })
            end
        end
    end

    if enabled(player:HasAbilityData()) then
        -- Resource ids below 0x200 contain weapon skills and menu-category
        -- headers such as "Sambas", "Jigs", and "Steps". HasAbility can
        -- report those indices as available, so only scan the job-ability
        -- resource range here; weapon skills are collected separately below.
        for id = JOB_ABILITY_MIN_ID, JOB_ABILITY_MAX_ID do
            local ok, known = pcall(player.HasAbility, player, id)
            if ok and enabled(known) then
                local ability = resources:GetAbilityById(id)
                if ability then
                    add(result, seen, {
                        key = 'ability:' .. id,
                        id = id,
                        -- Outgoing/incoming action packets use the job ability
                        -- list index (resource id minus the 0x200 JA offset).
                        packet_id = id - JOB_ABILITY_MIN_ID,
                        category = 'job_abilities',
                        kind = 'ability',
                        name = text(ability.Name),
                        description = text(ability.Description):lower(),
                        targets = ability.Targets or 0,
                        tp_cost = ability.TPCost or 0,
                        recast_id = ability.RecastTimerId,
                    })
                end
            end
        end
        for id = 1, 255 do
            if enabled(player:HasWeaponSkill(id)) then
                local ability = resources:GetAbilityById(id)
                if ability then
                    add(result, seen, {
                        key = 'weaponskill:' .. id,
                        id = id,
                        packet_id = ability.Index or id,
                        category = 'weapon_skills',
                        kind = 'weaponskill',
                        name = text(ability.Name),
                        description = text(ability.Description):lower(),
                        targets = ability.Targets or 0,
                    })
                end
            end
        end
    end

    for _, category in ipairs(ACTION_CATEGORIES) do
        table.sort(result[category], function(a, b)
            return a.name:lower() < b.name:lower()
        end)
    end
    return result
end

function M.command(action, target)
    local prefix = COMMAND_PREFIXES[action.kind] or COMMAND_PREFIXES.weaponskill
    return ('%s "%s" %s'):fmt(prefix, action.name, target or '<t>')
end

function M.has_effect(action, effect)
    local description = action and action.description or ''
    if effect == 'sleep' then
        return description:find('sleep', 1, true) ~= nil or description:find('asleep', 1, true) ~= nil
    end
    return true
end

return M
