local M = {};

local function text(value)
    if (type(value) == 'string') then return value; end
    if (type(value) == 'table') then return value[1] or value[0] or ''; end
    return '';
end

local function usable_spell(player, spell)
    local main_job, sub_job = player:GetMainJob(), player:GetSubJob();
    local main_req = spell.LevelRequired and spell.LevelRequired[main_job + 1] or 0;
    local sub_req = spell.LevelRequired and spell.LevelRequired[sub_job + 1] or 0;
    return (main_req and main_req > 0 and main_req <= player:GetMainJobLevel())
        or (sub_req and sub_req > 0 and sub_req <= player:GetSubJobLevel());
end

local function add(result, seen, action)
    if (action.name == '' or seen[action.key]) then return; end
    seen[action.key] = true;
    table.insert(result[action.category], action);
    result.by_key[action.key] = action;
end

function M.build(player, resources)
    local result = { spells = {}, job_abilities = {}, weapon_skills = {}, by_key = {} };
    local seen = {};
    if (player == nil) then return result; end

    if (player:HasSpellData()) then
        for id = 0, 1023 do
            local spell = resources:GetSpellById(id);
            if (spell and player:HasSpell(id) and usable_spell(player, spell)) then
                add(result, seen, {
                    key = 'spell:' .. id, id = id, category = 'spells', kind = 'spell',
                    name = text(spell.Name), description = text(spell.Description):lower(),
                    targets = spell.Targets or 0, mana = spell.ManaCost or 0,
                    skill = spell.Skill, recast_id = spell.Index or id,
                });
            end
        end
    end

    if (player:HasAbilityData()) then
        for id = 0, 1023 do
            local ok, known = pcall(player.HasAbility, player, id);
            if (ok and known) then
                local ability = resources:GetAbilityById(id);
                if (ability) then
                    add(result, seen, {
                        key = 'ability:' .. id, id = id, category = 'job_abilities', kind = 'ability',
                        name = text(ability.Name), description = text(ability.Description):lower(),
                        targets = ability.Targets or 0, recast_id = ability.RecastTimerId,
                    });
                end
            end
        end
        for id = 1, 255 do
            if (player:HasWeaponSkill(id)) then
                local ability = resources:GetAbilityById(id);
                if (ability) then
                    add(result, seen, {
                        key = 'weaponskill:' .. id, id = id, category = 'weapon_skills', kind = 'weaponskill',
                        name = text(ability.Name), description = text(ability.Description):lower(),
                        targets = ability.Targets or 0,
                    });
                end
            end
        end
    end

    for _, category in ipairs({ 'spells', 'job_abilities', 'weapon_skills' }) do
        table.sort(result[category], function(a, b) return a.name:lower() < b.name:lower(); end);
    end
    return result;
end

function M.command(action, target)
    local prefix = action.kind == 'spell' and '/ma'
        or (action.kind == 'ability' and '/ja' or '/ws');
    return ('%s "%s" %s'):fmt(prefix, action.name, target or '<t>');
end

function M.has_effect(action, effect)
    local description = action and action.description or '';
    if (effect == 'sleep') then
        return description:find('sleep', 1, true) ~= nil or description:find('asleep', 1, true) ~= nil;
    end
    return true;
end

return M;
