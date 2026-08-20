addon.name      = 'smartskillup';
addon.author    = 'RolandJ; Ashita port by Codex';
addon.version   = '1.1.0';
addon.desc      = 'Automates skill-up casting, command rotations, and supported Ambuscade fights.';
addon.link      = '';

require 'common';

local chat     = require 'chat';
local imgui    = require 'imgui';
local settings = require 'settings';
local ENTITY_STATUS_ENGAGED = 1;

local skill_names = {
    [32] = 'Divine Magic', [33] = 'Healing Magic', [34] = 'Enhancing Magic',
    [35] = 'Enfeebling Magic', [36] = 'Elemental Magic', [37] = 'Dark Magic',
    [38] = 'Summoning Magic', [39] = 'Ninjutsu', [40] = 'Singing',
    [41] = 'Stringed Instrument', [42] = 'Wind Instrument', [43] = 'Blue Magic',
    [44] = 'Geomancy', [45] = 'Handbell',
};

local skill_order = { 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45 };
local defaults = T{
    visible = T{ true },
    mode = T{ 1 }, -- 1 = spell rotation, 2 = command rotation, 3 = Ambuscade
    delay = T{ 4.0 },
    mp_limit = T{ 0 },
    rest_below = T{ 15 },
    resume_above = T{ 85 },
    target_party = T{ -1 },
    commands = T{},
    selected = T{},
    ambuscade = T{
        weapon_skill = T{ 'Viper Bite' },
        heal_below = T{ 55 },
        shantotto_sync_tp = T{ 900 },
        ws_sync_wait = T{ 4.0 },
        skills = T{
            advancing_march = T{ true },
            valor_minuet_v = T{ true },
            foe_lullaby_ii = T{ true },
            magic_finale = T{ true },
            haste_samba = T{ true },
            box_step = T{ true },
            reverse_flourish = T{ true },
            curing_waltz_iii = T{ true },
            weapon_skill = T{ true },
        },
    },
};
for _, id in ipairs(skill_order) do defaults.selected[tostring(id)] = T{ false }; end

local state = {
    settings = settings.load(defaults),
    active = false,
    paused = false,
    resting = false,
    next_action = 0,
    skill_cursor = 1,
    spell_cursor = {},
    command_cursor = 1,
    spell_cache = {},
    cache_job = -1,
    last_spell = '',
    status = 'Idle',
    ambuscade_phase = 'idle',
    ambuscade_cursor = 1,
    ambuscade_setup_verified = 0,
    ambuscade_song_attempts = 0,
    ambuscade_samba_at = 0,
    ambuscade_step_at = 0,
    ambuscade_lullaby_at = 0,
    ambuscade_song_at = 0,
    ambuscade_finale_at = 0,
    ambuscade_ws_wait_started = 0,
    ambuscade_reverse_at = 0,
    ambuscade_waltz_at = 0,
    ambuscade_engaged = false,
    ambuscade_timeline = {},
    ambuscade_mobs = {
        ['Bozzetto Julika'] = T{ true },
        ['Bozzetto Vivian'] = T{ true },
        ['Bozzetto Jody'] = T{ true },
    },
    ambuscade_buffs = {
        ['Bozzetto Julika'] = {},
        ['Bozzetto Vivian'] = {},
        ['Bozzetto Jody'] = {},
    },
};
-- Migrate earlier fight profiles. Evisceration requires its unlock quest, and
-- Dancing Edge is restricted to main-job THF/DNC. Viper Bite is confirmed in
-- Bettyboom's weaponskill list and is single-target, so it will not wake Vivian.
if (state.settings.ambuscade.weapon_skill[1] == 'Evisceration'
    or state.settings.ambuscade.weapon_skill[1] == 'Dancing Edge'
    or state.settings.ambuscade.weapon_skill[1] == 'Gust Slash') then
    state.settings.ambuscade.weapon_skill[1] = 'Viper Bite';
    settings.save();
end
local qpf = ashita.time.qpf();

settings.register('settings', 'settings_update', function (s)
    if (s ~= nil) then state.settings = s; end
    settings.save();
end);

local function now()
    local value = ashita.time.qpc();
    return value.q / qpf.q;
end

local function log(kind, message)
    if (kind == 'error') then
        print(chat.header(addon.name):append(chat.error(message)));
    elseif (kind == 'ok') then
        print(chat.header(addon.name):append(chat.success(message)));
    elseif (kind == 'notice') then
        print(chat.header(addon.name):append(chat.color1(6, message)));
    else
        print(chat.header(addon.name):append(chat.message(message)));
    end
end

local function queue(command)
    AshitaCore:GetChatManager():QueueCommand(1, command);
end

local function timeline_add(label)
    table.insert(state.ambuscade_timeline, 1, { time = now(), label = label });
    while (#state.ambuscade_timeline > 5) do table.remove(state.ambuscade_timeline); end
end

local function timeline_prune()
    local current_time = now();
    for index = #state.ambuscade_timeline, 1, -1 do
        if (current_time - state.ambuscade_timeline[index].time > 30.0) then
            table.remove(state.ambuscade_timeline, index);
        end
    end
end

local function ambuscade_queue(label, command)
    queue(command);
    timeline_add('Queued: ' .. label);
end

local function player_ready()
    local player = AshitaCore:GetMemoryManager():GetPlayer();
    return player ~= nil and player:GetLoginStatus() == 2 and player:HasSpellData();
end

local function spell_name(spell)
    return spell and spell.Name and (spell.Name[1] or spell.Name[0]) or nil;
end

local function rebuild_spells()
    state.spell_cache = {};
    for _, id in ipairs(skill_order) do state.spell_cache[id] = {}; end
    if (not player_ready()) then return; end

    local player = AshitaCore:GetMemoryManager():GetPlayer();
    local resources = AshitaCore:GetResourceManager();
    local main_job = player:GetMainJob();
    local sub_job = player:GetSubJob();
    local main_level = player:GetMainJobLevel();
    local sub_level = player:GetSubJobLevel();

    for id = 0, 1023 do
        local spell = resources:GetSpellById(id);
        if (spell ~= nil and state.spell_cache[spell.Skill] ~= nil and player:HasSpell(id)) then
            local main_req = spell.LevelRequired and spell.LevelRequired[main_job + 1] or 0;
            local sub_req = spell.LevelRequired and spell.LevelRequired[sub_job + 1] or 0;
            local usable = (main_req ~= nil and main_req > 0 and main_req <= main_level)
                or (sub_req ~= nil and sub_req > 0 and sub_req <= sub_level);
            local name = spell_name(spell);
            if (usable and name ~= nil and name ~= '' and spell.ManaCost >= 0) then
                table.insert(state.spell_cache[spell.Skill], spell);
            end
        end
    end

    for _, spells in pairs(state.spell_cache) do
        table.sort(spells, function (a, b)
            if (a.ManaCost == b.ManaCost) then return a.Index < b.Index; end
            return a.ManaCost < b.ManaCost;
        end);
    end
    state.cache_job = main_job * 100000 + main_level * 1000 + sub_job * 100 + sub_level;
end

local function selected_skills()
    local result = {};
    for _, id in ipairs(skill_order) do
        if (state.settings.selected[tostring(id)][1]) then table.insert(result, id); end
    end
    return result;
end

local function enabled_commands()
    local result = {};
    for _, entry in ipairs(state.settings.commands) do
        if (entry.enabled[1] and entry.text[1]:match('%S')) then
            table.insert(result, entry.text[1]);
        end
    end
    return result;
end

local function current_mp_percent(player)
    local party = AshitaCore:GetMemoryManager():GetParty();
    return party:GetMemberMPPercent(0) or 0;
end

local function is_spell_ready(spell)
    local timer = AshitaCore:GetMemoryManager():GetRecast():GetSpellTimer(spell.Index);
    return timer == nil or timer <= 0;
end

local function is_player_engaged()
    if (type(GetPlayerEntity) ~= 'function') then return false; end
    local entity = GetPlayerEntity();
    return entity ~= nil and entity.Status == ENTITY_STATUS_ENGAGED;
end

local ambuscade_setup = {
    '/ma "Advancing March" <me>',
    '/ma "Valor Minuet V" <me>',
};

local ambuscade_targets = {
    'Bozzetto Julika',
    'Bozzetto Jody',
    'Bozzetto Vivian',
};

local ambuscade_skill_options = {
    { key = 'advancing_march', label = 'Advancing March' },
    { key = 'valor_minuet_v', label = 'Valor Minuet V' },
    { key = 'foe_lullaby_ii', label = 'Foe Lullaby II' },
    { key = 'magic_finale', label = 'Magic Finale' },
    { key = 'haste_samba', label = 'Haste Samba' },
    { key = 'box_step', label = 'Box Step' },
    { key = 'reverse_flourish', label = 'Reverse Flourish' },
    { key = 'curing_waltz_iii', label = 'Curing Waltz III' },
    { key = 'weapon_skill', label = 'Configured weaponskill' },
};

local function ambuscade_skill_enabled(key)
    local option = state.settings.ambuscade.skills[key];
    return option ~= nil and option[1];
end

local function setup_song_key(index)
    return index == 1 and 'advancing_march' or 'valor_minuet_v';
end

local function current_target()
    local target = AshitaCore:GetMemoryManager():GetTarget();
    if (target == nil) then return nil; end
    local index = target:GetTargetIndex(0);
    if (index == nil or index == 0 or type(GetEntity) ~= 'function') then return nil; end
    return GetEntity(index);
end

local function target_name(entity)
    return entity ~= nil and (entity.Name or entity.name) or '';
end

local function target_hp_percent(entity)
    if (entity == nil) then return 100; end
    return entity.HPPercent or entity.HealthPercent or 100;
end

local function find_entity_named(expected)
    for index = 1, 0x8FF do
        local entity = GetEntity(index);
        if (entity ~= nil and target_name(entity):lower() == expected:lower()
            and target_hp_percent(entity) > 0) then
            return entity, index;
        end
    end
    return nil, nil;
end

local function ambuscade_mob_checked(name)
    local value = state.ambuscade_mobs[name];
    return value ~= nil and value[1];
end

local function ambuscade_buff_count(name)
    local buffs = state.ambuscade_buffs[name] or {};
    local count = 0;
    for _ in pairs(buffs) do count = count + 1; end
    return count;
end

local function target_has_enhancements(target)
    return ambuscade_buff_count(target_name(target)) > 0;
end

local function vivian_sleep_needed()
    if (not ambuscade_skill_enabled('foe_lullaby_ii')) then return false; end
    local vivian_alive = ambuscade_mob_checked('Bozzetto Vivian')
        and find_entity_named('Bozzetto Vivian') ~= nil;
    local julika_alive = ambuscade_mob_checked('Bozzetto Julika')
        and find_entity_named('Bozzetto Julika') ~= nil;
    local jody_alive = ambuscade_mob_checked('Bozzetto Jody')
        and find_entity_named('Bozzetto Jody') ~= nil;
    return vivian_alive and (julika_alive or jody_alive);
end

local function find_ambuscade_target()
    local current = current_target();
    local target_manager = AshitaCore:GetMemoryManager():GetTarget();
    for _, expected in ipairs(ambuscade_targets) do
        local entity, index = find_entity_named(expected);
        if (ambuscade_mob_checked(expected) and entity ~= nil) then
            if (target_name(current):lower() == expected:lower()
                and target_hp_percent(current) > 0) then
                return current, false;
            end
            target_manager:SetTarget(index, true);
            return entity, true;
        end
    end
    return nil, false;
end

local function player_hp_percent()
    local party = AshitaCore:GetMemoryManager():GetParty();
    return party ~= nil and (party:GetMemberHPPercent(0) or 0) or 0;
end

local function player_tp()
    local party = AshitaCore:GetMemoryManager():GetParty();
    return party ~= nil and (party:GetMemberTP(0) or 0) or 0;
end

local function trust_tp(expected_name)
    local party = AshitaCore:GetMemoryManager():GetParty();
    if (party == nil) then return nil; end
    for index = 1, 5 do
        if (party:GetMemberIsActive(index) == 1) then
            local name = party:GetMemberName(index) or '';
            if (name:lower() == expected_name:lower()) then
                return party:GetMemberTP(index) or 0;
            end
        end
    end
    return nil;
end

local function shantotto_tp()
    return trust_tp('Shantotto II');
end

local function qultada_tp()
    return trust_tp('Qultada');
end

local function shantotto_ready_for_ws()
    local tp = shantotto_tp();
    return tp == nil or tp >= state.settings.ambuscade.shantotto_sync_tp[1];
end

local function qultada_ready_for_ws()
    local tp = qultada_tp();
    return tp == nil or tp < 1000;
end

local function finishing_moves()
    local player = AshitaCore:GetMemoryManager():GetPlayer();
    if (player == nil) then return 0; end
    local buffs = player:GetBuffs() or {};
    local move_count = {
        [381] = 1, [382] = 2, [383] = 3,
        [384] = 4, [385] = 5, [588] = 6,
    };
    for index = 1, 32 do
        local count = move_count[buffs[index]];
        if (count ~= nil) then return count; end
    end
    return 0;
end

local function has_player_buff(buff_id)
    local player = AshitaCore:GetMemoryManager():GetPlayer();
    if (player == nil) then return false; end
    local buffs = player:GetBuffs() or {};
    for index = 1, 32 do
        if (buffs[index] == buff_id) then return true; end
    end
    return false;
end

local function setup_song_info(index)
    if (index == 1) then return 'Advancing March', 214; end
    if (index == 2) then return 'Valor Minuet V', 198; end
    return nil, nil;
end

local function reset_ambuscade()
    state.ambuscade_phase = 'setup';
    state.ambuscade_cursor = 1;
    state.ambuscade_setup_verified = 0;
    state.ambuscade_song_attempts = 0;
    state.ambuscade_samba_at = 0;
    state.ambuscade_step_at = 0;
    state.ambuscade_lullaby_at = 0;
    state.ambuscade_song_at = 0;
    state.ambuscade_finale_at = 0;
    state.ambuscade_ws_wait_started = 0;
    state.ambuscade_reverse_at = 0;
    state.ambuscade_waltz_at = 0;
    state.ambuscade_engaged = false;
    state.ambuscade_timeline = {};
    for _, name in ipairs(ambuscade_targets) do
        state.ambuscade_mobs[name][1] = true;
        state.ambuscade_buffs[name] = {};
    end
end

local function targets_enemy(spell)
    -- FFXI spell target flags: 0x20 means the spell can target an enemy.
    return bit.band(spell.Targets or 0, 0x20) ~= 0;
end

local function party_target_label(index)
    if (index == nil or index < 0) then return 'None (current target)'; end
    local party = AshitaCore:GetMemoryManager():GetParty();
    if (party == nil or party:GetMemberIsActive(index) ~= 1) then
        return ('Party slot %d (unavailable)'):fmt(index);
    end
    local name = party:GetMemberName(index);
    return (index == 0 and '%s (self)' or '%s (p%d)'):fmt(name, index);
end

local function choose_spell(skill_id, player)
    local spells = state.spell_cache[skill_id] or {};
    if (#spells == 0) then return nil; end
    local mp = AshitaCore:GetMemoryManager():GetParty():GetMemberMP(0) or 0;
    local engaged = is_player_engaged();
    local start = state.spell_cursor[skill_id] or 1;
    for offset = 0, #spells - 1 do
        local index = ((start + offset - 1) % #spells) + 1;
        local spell = spells[index];
        local within_limit = state.settings.mp_limit[1] <= 0
            or spell.ManaCost <= state.settings.mp_limit[1];
        local combat_allowed = not targets_enemy(spell) or engaged;
        if (within_limit and combat_allowed and spell.ManaCost <= mp and is_spell_ready(spell)) then
            state.spell_cursor[skill_id] = (index % #spells) + 1;
            return spell;
        end
    end
    return nil;
end

local function target_for(spell)
    -- Enemy actions must always use the current combat target.
    if (targets_enemy(spell)) then return '<t>'; end

    local selected = state.settings.target_party[1];
    local friendly_targets = bit.band(spell.Targets or 0, 0x0F) ~= 0;
    if (selected ~= nil and selected >= 0 and friendly_targets) then
        return selected == 0 and '<me>' or ('<p%d>'):fmt(selected);
    end

    -- With no explicit selection, retain current-target behavior. Spells which
    -- are strictly self-only still need <me> to remain castable.
    local flags = spell.Targets or 0;
    if (bit.band(flags, 0x01) ~= 0 and bit.band(flags, 0x0E) == 0) then return '<me>'; end
    return '<t>';
end

local function stop(reason)
    if (state.resting) then queue('/heal'); end
    state.active = false;
    state.paused = false;
    state.resting = false;
    state.status = reason or 'Stopped';
    log('notice', state.status);
end

local function start()
    if (state.settings.mode[1] == 3) then
        local player = AshitaCore:GetMemoryManager():GetPlayer();
        if (not player_ready()) then
            log('error', 'The character is not ready.');
            return;
        end
        if (player:GetMainJob() ~= 10 or player:GetSubJob() ~= 19) then
            log('error', 'This Ambuscade profile requires BRD/DNC.');
            return;
        end
        reset_ambuscade();
    elseif (state.settings.mode[1] == 2) then
        if (#enabled_commands() == 0) then
            log('error', 'Add and enable at least one command first.');
            return;
        end
    else
        if (#selected_skills() == 0) then
            log('error', 'Select at least one magic skill first.');
            return;
        end
        rebuild_spells();
        local available = false;
        for _, id in ipairs(selected_skills()) do
            if (#(state.spell_cache[id] or {}) > 0) then available = true; break; end
        end
        if (not available) then
            log('error', 'No currently usable spells were found for the selected skills.');
            return;
        end
    end
    state.active = true;
    state.paused = false;
    state.resting = false;
    state.next_action = now();
    state.status = state.settings.mode[1] == 3 and 'Ambuscade: preparing songs'
        or (state.settings.mode[1] == 2 and 'Running commands' or 'Running spells');
    log('ok', state.settings.mode[1] == 3 and 'Plantoid Ambuscade routine started.'
        or (state.settings.mode[1] == 2 and 'Command session started.' or 'Skill-up session started.'));
end

local function tick_ambuscade()
    local tick_time = now();
    local tick_tp = player_tp();
    if (ambuscade_skill_enabled('curing_waltz_iii')
        and player_hp_percent() <= state.settings.ambuscade.heal_below[1]
        and tick_tp >= 500 and tick_time >= state.ambuscade_waltz_at) then
        ambuscade_queue('Curing Waltz III', '/ja "Curing Waltz III" <me>');
        state.last_spell = 'Curing Waltz III';
        state.status = 'Emergency self-heal';
        state.ambuscade_waltz_at = tick_time + 8.0;
        state.next_action = tick_time + 3.0;
        return;
    end

    if (state.ambuscade_phase == 'setup') then
        while (state.ambuscade_cursor <= #ambuscade_setup
            and not ambuscade_skill_enabled(setup_song_key(state.ambuscade_cursor))) do
            timeline_add('Skipped (disabled): ' .. (setup_song_info(state.ambuscade_cursor)));
            state.ambuscade_setup_verified = state.ambuscade_cursor;
            state.ambuscade_cursor = state.ambuscade_cursor + 1;
        end
        local previous = state.ambuscade_cursor - 1;
        if (previous > state.ambuscade_setup_verified) then
            local previous_name, previous_buff = setup_song_info(previous);
            if (not ambuscade_skill_enabled(setup_song_key(previous))) then
                timeline_add('Skipped (disabled): ' .. previous_name);
                state.ambuscade_setup_verified = previous;
                state.ambuscade_song_attempts = 0;
            elseif (has_player_buff(previous_buff)) then
                timeline_add('Confirmed: ' .. previous_name);
                state.ambuscade_setup_verified = previous;
                state.ambuscade_song_attempts = 0;
            elseif (state.ambuscade_song_attempts < 3) then
                state.ambuscade_song_attempts = state.ambuscade_song_attempts + 1;
                ambuscade_queue('Retry ' .. previous_name, ambuscade_setup[previous]);
                state.status = 'Retrying ' .. previous_name .. ' (effect not detected)';
                state.next_action = now() + 10.0;
                return;
            else
                timeline_add('Failed to confirm: ' .. previous_name);
                state.ambuscade_setup_verified = previous;
                state.ambuscade_song_attempts = 0;
            end
        end
        if (state.ambuscade_cursor <= #ambuscade_setup) then
            local command = ambuscade_setup[state.ambuscade_cursor];
            ambuscade_queue(command:match('"([^"]+)"') or command, command);
            state.last_spell = command;
            state.status = ('Ambuscade setup %d/%d'):fmt(state.ambuscade_cursor, #ambuscade_setup);
            state.ambuscade_cursor = state.ambuscade_cursor + 1;
            state.ambuscade_song_attempts = 1;
            -- BRD songs have a long base cast time. Leave enough room for the
            -- cast to finish before queuing the next song.
            state.next_action = now() + 10.0;
            return;
        end
        state.ambuscade_song_at = now() + 110.0;
        state.ambuscade_phase = 'sleep_vivian';
    end

    if (state.ambuscade_phase == 'sleep_vivian') then
        local vivian, index = find_entity_named('Bozzetto Vivian');
        if (vivian ~= nil and vivian_sleep_needed()) then
            AshitaCore:GetMemoryManager():GetTarget():SetTarget(index, true);
            state.ambuscade_phase = 'cast_lullaby';
            state.status = 'Targeting Vivian for Lullaby';
            state.next_action = now() + 0.5;
            return;
        end
        state.ambuscade_phase = 'combat';
    elseif (state.ambuscade_phase == 'cast_lullaby') then
        if (not ambuscade_skill_enabled('foe_lullaby_ii') or not vivian_sleep_needed()) then
            state.ambuscade_phase = 'combat';
            state.status = 'Skipping Lullaby: Vivian no longer needs sleep';
            state.next_action = now();
            return;
        end
        ambuscade_queue('Foe Lullaby II', '/ma "Foe Lullaby II" <t>');
        state.last_spell = 'Foe Lullaby II';
        state.ambuscade_lullaby_at = now() + 50.0;
        state.ambuscade_phase = 'combat';
        state.status = 'Sleeping Bozzetto Vivian';
        state.next_action = now() + 4.0;
        return;
    end

    if (vivian_sleep_needed() and now() >= state.ambuscade_lullaby_at) then
        state.ambuscade_phase = 'sleep_vivian';
        state.status = 'Preparing to refresh Lullaby on Vivian';
        state.next_action = now() + 0.1;
        return;
    end

    local target, target_changed = find_ambuscade_target();
    if (target == nil) then
        if (state.ambuscade_engaged) then
            stop('Ambuscade routine complete: all Plantoids defeated.');
            return;
        end
        state.status = 'Waiting for Ambuscade Plantoids';
        state.next_action = now() + 0.5;
        return;
    end

    local current_time = now();
    local target_hp = target_hp_percent(target);
    if (target_changed) then
        state.status = 'Switching target to ' .. target_name(target);
        state.next_action = current_time + 0.5;
        return;
    end
    local tp = player_tp();
    if (target_hp <= 0) then
        state.status = 'Selecting next Plantoid';
        state.next_action = current_time + 0.25;
        return;
    end
    if (not is_player_engaged()) then
        ambuscade_queue('Engage ' .. target_name(target), '/attack <t>');
        state.ambuscade_engaged = true;
        state.status = 'Engaging ' .. target_name(target);
        state.next_action = current_time + 1.0;
        return;
    end
    if (ambuscade_skill_enabled('reverse_flourish') and tp < 1000
        and finishing_moves() == 5 and current_time >= state.ambuscade_reverse_at) then
        ambuscade_queue('Reverse Flourish', '/ja "Reverse Flourish" <me>');
        state.last_spell = 'Reverse Flourish';
        state.status = ('Converting 5 Finishing Moves (%d TP)'):fmt(tp);
        state.ambuscade_reverse_at = current_time + 30.0;
        state.next_action = current_time + 2.0;
        return;
    end
    if (tp < 1000) then
        state.ambuscade_ws_wait_started = 0;
    elseif (ambuscade_skill_enabled('weapon_skill')) then
        local trusts_ready = shantotto_ready_for_ws() and qultada_ready_for_ws();
        if (state.ambuscade_ws_wait_started == 0) then
            state.ambuscade_ws_wait_started = current_time;
        end
        local waited = current_time - state.ambuscade_ws_wait_started;
        if (trusts_ready or waited >= state.settings.ambuscade.ws_sync_wait[1]) then
            local ws = state.settings.ambuscade.weapon_skill[1];
            ambuscade_queue(ws, ('/ws "%s" <t>'):fmt(ws));
            state.last_spell = ws;
            state.status = ('Weaponskill: %s (%d TP, waited %.1fs)'):fmt(ws, tp, waited);
            state.ambuscade_ws_wait_started = 0;
            state.next_action = current_time + 2.0;
            return;
        end
        state.status = ('Holding WS for trusts (%.1f/%.1fs)'):fmt(
            waited, state.settings.ambuscade.ws_sync_wait[1]);
        state.next_action = current_time + 0.25;
        return;
    else
        state.ambuscade_ws_wait_started = 0;
    end
    if (ambuscade_skill_enabled('magic_finale')
        and current_time >= state.ambuscade_finale_at and target_has_enhancements(target)) then
        ambuscade_queue('Magic Finale on ' .. target_name(target), '/ma "Magic Finale" <t>');
        state.last_spell = 'Magic Finale';
        state.ambuscade_finale_at = current_time + 30.0;
        state.status = 'Dispelling ' .. target_name(target);
        state.next_action = current_time + 3.0;
        return;
    end
    if (ambuscade_skill_enabled('haste_samba') and current_time >= state.ambuscade_samba_at) then
        ambuscade_queue('Haste Samba', '/ja "Haste Samba" <me>');
        state.last_spell = 'Haste Samba';
        state.ambuscade_samba_at = current_time + 85.0;
        state.status = 'Refreshing Haste Samba';
        state.next_action = current_time + 2.0;
        return;
    end
    if (ambuscade_skill_enabled('box_step') and current_time >= state.ambuscade_step_at
        and finishing_moves() < 5) then
        ambuscade_queue('Box Step', '/ja "Box Step" <t>');
        state.last_spell = 'Box Step';
        state.ambuscade_step_at = current_time + 20.0;
        state.status = 'Applying Box Step';
        state.next_action = current_time + 2.0;
        return;
    end
    if (state.ambuscade_phase == 'verify_march') then
        if (not ambuscade_skill_enabled('advancing_march')) then
            state.ambuscade_phase = ambuscade_skill_enabled('valor_minuet_v')
                and 'refresh_minuet' or 'combat';
            state.ambuscade_song_attempts = 0;
            state.next_action = current_time;
        elseif (has_player_buff(214)) then
            timeline_add('Confirmed: Advancing March');
            state.ambuscade_phase = 'refresh_minuet';
            state.ambuscade_song_attempts = 0;
            state.next_action = current_time;
        elseif (state.ambuscade_song_attempts < 3) then
            state.ambuscade_song_attempts = state.ambuscade_song_attempts + 1;
            ambuscade_queue('Retry Advancing March', '/ma "Advancing March" <me>');
            state.status = 'Retrying Advancing March';
            state.next_action = current_time + 8.5;
        else
            timeline_add('Failed to confirm: Advancing March');
            state.ambuscade_phase = 'refresh_minuet';
            state.ambuscade_song_attempts = 0;
            state.next_action = current_time;
        end
        return;
    elseif (state.ambuscade_phase == 'refresh_minuet') then
        if (not ambuscade_skill_enabled('valor_minuet_v')) then
            state.ambuscade_phase = 'combat';
            state.ambuscade_song_at = current_time + 110.0;
            state.next_action = current_time;
            return;
        end
        ambuscade_queue('Valor Minuet V', '/ma "Valor Minuet V" <me>');
        state.last_spell = 'Valor Minuet V';
        state.ambuscade_phase = 'verify_minuet';
        state.ambuscade_song_attempts = 1;
        state.status = 'Queued Valor Minuet V; verifying effect';
        state.next_action = current_time + 8.5;
        return;
    elseif (state.ambuscade_phase == 'verify_minuet') then
        if (not ambuscade_skill_enabled('valor_minuet_v')) then
            state.ambuscade_phase = 'combat';
            state.ambuscade_song_attempts = 0;
            state.ambuscade_song_at = current_time + 110.0;
        elseif (has_player_buff(198)) then
            timeline_add('Confirmed: Valor Minuet V');
            state.ambuscade_phase = 'combat';
            state.ambuscade_song_attempts = 0;
            state.ambuscade_song_at = current_time + 110.0;
        elseif (state.ambuscade_song_attempts < 3) then
            state.ambuscade_song_attempts = state.ambuscade_song_attempts + 1;
            ambuscade_queue('Retry Valor Minuet V', '/ma "Valor Minuet V" <me>');
            state.status = 'Retrying Valor Minuet V';
            state.next_action = current_time + 8.5;
            return;
        else
            timeline_add('Failed to confirm: Valor Minuet V');
            state.ambuscade_phase = 'combat';
            state.ambuscade_song_attempts = 0;
            state.ambuscade_song_at = current_time + 30.0;
        end
    elseif (current_time >= state.ambuscade_song_at) then
        if (ambuscade_skill_enabled('advancing_march')) then
            ambuscade_queue('Advancing March', '/ma "Advancing March" <me>');
            state.last_spell = 'Advancing March';
            state.ambuscade_phase = 'verify_march';
            state.ambuscade_song_attempts = 1;
            state.status = 'Queued Advancing March; verifying effect';
            state.next_action = current_time + 8.5;
            return;
        elseif (ambuscade_skill_enabled('valor_minuet_v')) then
            state.ambuscade_phase = 'refresh_minuet';
            state.next_action = current_time;
            return;
        else
            state.ambuscade_song_at = current_time + 110.0;
        end
    end
    state.status = ('Fighting %s (%d%%)'):fmt(target_name(target), target_hp);
    state.next_action = current_time + 0.5;
end

local function ambuscade_next_action_label()
    if (not state.active) then return 'Press Start'; end
    if (state.paused) then return 'Paused'; end
    if (ambuscade_skill_enabled('curing_waltz_iii')
        and player_hp_percent() <= state.settings.ambuscade.heal_below[1]
        and player_tp() >= 500 and now() >= state.ambuscade_waltz_at) then
        return 'Curing Waltz III';
    end
    if (state.ambuscade_phase == 'setup') then
        local command = ambuscade_setup[state.ambuscade_cursor];
        return command ~= nil and (command:match('"([^"]+)"') or command) or 'Target Vivian';
    elseif (state.ambuscade_phase == 'sleep_vivian') then
        return 'Target Bozzetto Vivian';
    elseif (state.ambuscade_phase == 'cast_lullaby') then
        return 'Foe Lullaby II';
    elseif (state.ambuscade_phase == 'verify_march') then
        return has_player_buff(214) and 'March confirmed; queue Minuet' or 'Verify/retry Advancing March';
    elseif (state.ambuscade_phase == 'refresh_minuet') then
        return 'Valor Minuet V';
    elseif (state.ambuscade_phase == 'verify_minuet') then
        return has_player_buff(198) and 'Valor Minuet V confirmed' or 'Verify/retry Valor Minuet V';
    end

    local current_time = now();
    if (vivian_sleep_needed() and current_time >= state.ambuscade_lullaby_at) then
        return 'Refresh Foe Lullaby II';
    end
    if (ambuscade_skill_enabled('reverse_flourish') and player_tp() < 1000 and finishing_moves() == 5
        and current_time >= state.ambuscade_reverse_at) then return 'Reverse Flourish'; end
    if (ambuscade_skill_enabled('weapon_skill') and player_tp() >= 1000) then
        local waited = state.ambuscade_ws_wait_started > 0
            and (current_time - state.ambuscade_ws_wait_started) or 0;
        if (waited >= state.settings.ambuscade.ws_sync_wait[1]) then
            return state.settings.ambuscade.weapon_skill[1] .. ' (sync timeout)';
        end
        local cor_tp = qultada_tp();
        if (cor_tp ~= nil and cor_tp >= 1000) then
            return ('Hold WS for Qultada to spend TP (%d TP)'):fmt(cor_tp);
        end
        local trust_tp = shantotto_tp();
        if (trust_tp ~= nil and trust_tp < state.settings.ambuscade.shantotto_sync_tp[1]) then
            return ('Hold WS for Shantotto II (%d TP)'):fmt(trust_tp);
        end
        return state.settings.ambuscade.weapon_skill[1];
    end
    local target = current_target();
    if (ambuscade_skill_enabled('magic_finale')
        and current_time >= state.ambuscade_finale_at and target_has_enhancements(target)) then
        return 'Magic Finale on current target';
    end
    if (ambuscade_skill_enabled('haste_samba')
        and current_time >= state.ambuscade_samba_at) then return 'Haste Samba'; end
    if (ambuscade_skill_enabled('box_step') and current_time >= state.ambuscade_step_at
        and finishing_moves() < 5) then return 'Box Step'; end
    if (current_time >= state.ambuscade_song_at) then
        if (ambuscade_skill_enabled('advancing_march')) then return 'Refresh Advancing March'; end
        if (ambuscade_skill_enabled('valor_minuet_v')) then return 'Refresh Valor Minuet V'; end
    end
    return 'Build TP / monitor timers';
end

local function tick()
    if (not state.active or state.paused or now() < state.next_action or not player_ready()) then return; end

    if (state.settings.mode[1] == 3) then
        tick_ambuscade();
        return;
    elseif (state.settings.mode[1] == 2) then
        local commands = enabled_commands();
        if (#commands == 0) then stop('Stopped: no enabled commands.'); return; end
        if (state.command_cursor > #commands) then state.command_cursor = 1; end
        local command = commands[state.command_cursor];
        queue(command);
        state.last_spell = command;
        state.status = ('Command %d/%d'):fmt(state.command_cursor, #commands);
        state.command_cursor = (state.command_cursor % #commands) + 1;
        state.next_action = now() + math.max(0.1, state.settings.delay[1]);
        return;
    end

    local player = AshitaCore:GetMemoryManager():GetPlayer();
    local job_key = player:GetMainJob() * 100000 + player:GetMainJobLevel() * 1000
        + player:GetSubJob() * 100 + player:GetSubJobLevel();
    if (job_key ~= state.cache_job) then rebuild_spells(); end

    local mpp = current_mp_percent(player);
    if (state.resting) then
        if (mpp >= state.settings.resume_above[1]) then
            queue('/heal');
            state.resting = false;
            state.status = 'Running';
            state.next_action = now() + 1.0;
        else
            state.status = ('Resting (%d%% MP)'):fmt(mpp);
            state.next_action = now() + 1.0;
        end
        return;
    elseif (state.settings.rest_below[1] > 0 and mpp <= state.settings.rest_below[1]) then
        queue('/heal');
        state.resting = true;
        state.status = ('Resting (%d%% MP)'):fmt(mpp);
        state.next_action = now() + 2.0;
        return;
    end

    local skills = selected_skills();
    if (#skills == 0) then stop('Stopped: no skills selected.'); return; end
    for offset = 0, #skills - 1 do
        local index = ((state.skill_cursor + offset - 1) % #skills) + 1;
        local skill_id = skills[index];
        local spell = choose_spell(skill_id, player);
        if (spell ~= nil) then
            local name = spell_name(spell);
            queue(('/ma "%s" %s'):fmt(name, target_for(spell)));
            state.last_spell = name;
            state.status = ('Casting %s (%s)'):fmt(name, skill_names[skill_id]);
            state.skill_cursor = (index % #skills) + 1;
            state.next_action = now() + math.max(2.5, state.settings.delay[1]);
            return;
        end
    end
    state.status = is_player_engaged() and 'Waiting for MP/recasts' or 'Waiting for MP/recasts/combat';
    state.next_action = now() + 1.0;
end

local function print_help()
    log('notice', 'Commands: /sms start | stop | pause | resume | toggle <skill> | show | hide | spells | help');
    log('notice', 'Example: /sms toggle enhancing');
    log('notice', 'Use the window to switch between Spell Rotation and Command Rotation modes.');
end

local function find_skill(text)
    text = (text or ''):lower():gsub('[%s%p]', '');
    local found = nil;
    for id, name in pairs(skill_names) do
        local normalized = name:lower():gsub('[%s%p]', '');
        if (normalized:sub(1, #text) == text) then
            if (found ~= nil) then return nil, 'Multiple skills match.'; end
            found = id;
        end
    end
    return found, found == nil and 'No skill matches.' or nil;
end

ashita.events.register('command', 'smartskillup_command', function (e)
    local args = e.command:args();
    if (#args == 0 or not args[1]:any('/sms', '/smartskillup', '/skillup')) then return; end
    e.blocked = true;
    local command = (#args > 1 and args[2]:lower()) or 'help';
    if (command:any('start', 'go', 'on')) then
        start();
    elseif (command:any('stop', 'off')) then
        stop('Skill-up session stopped.');
    elseif (command == 'pause') then
        state.paused = true; state.status = 'Paused'; log('notice', 'Session paused.');
    elseif (command:any('resume', 'unpause')) then
        state.paused = false; state.next_action = now(); state.status = 'Running'; log('ok', 'Session resumed.');
    elseif (command:any('toggle', 'togskill', 'addskill', 'delskill')) then
        local id, err = find_skill(table.concat(args, ' ', 3));
        if (id == nil) then log('error', err); return; end
        local value = command == 'addskill' or (command ~= 'delskill' and not state.settings.selected[tostring(id)][1]);
        state.settings.selected[tostring(id)][1] = value;
        settings.save();
        log('ok', ('%s %s.'):fmt(value and 'Selected' or 'Deselected', skill_names[id]));
    elseif (command == 'show') then
        state.settings.visible[1] = true; settings.save();
    elseif (command == 'hide') then
        state.settings.visible[1] = false; settings.save();
    elseif (command:any('spells', 'spellreport')) then
        rebuild_spells();
        for _, id in ipairs(selected_skills()) do
            local names = {};
            for _, spell in ipairs(state.spell_cache[id] or {}) do
                table.insert(names, ('%s[%d]'):fmt(spell_name(spell), spell.ManaCost));
            end
            log('notice', skill_names[id] .. ': ' .. (#names > 0 and table.concat(names, ', ') or '(none)'));
        end
    elseif (command == 'help') then
        print_help();
    else
        print_help();
    end
end);

ashita.events.register('text_in', 'smartskillup_ambuscade_buffs', function (e)
    if (state.settings.mode[1] ~= 3) then return; end
    local message = (e.message_modified or ''):strip_colors():gsub('[\30\31\127]', ''):gsub('%c', ' ');
    local lower = message:lower();
    for _, name in ipairs(ambuscade_targets) do
        local name_lower = name:lower();
        if (lower:find(name_lower, 1, true)) then
            local effect = message:match('[Gg]ains the effect of ([^%.]+)')
                or message:match('[Gg]ains effect of ([^%.]+)');
            if (effect ~= nil) then
                state.ambuscade_buffs[name][effect:lower()] = true;
            else
                effect = message:match("'s ([^%.]+) effect wears off")
                    or message:match("'s ([^%.]+) effect disappears");
                if (effect ~= nil) then
                    state.ambuscade_buffs[name][effect:lower()] = nil;
                end
            end
        end
    end
end);

ashita.events.register('d3d_present', 'smartskillup_present', function ()
    tick();
    if (not state.settings.visible[1]) then return; end

    imgui.SetNextWindowSize({ 390, 0 }, ImGuiCond_FirstUseEver);
    local flags = bit.bor(ImGuiWindowFlags_AlwaysAutoResize, ImGuiWindowFlags_NoCollapse);
    if (imgui.Begin('SmartSkillup', state.settings.visible, flags)) then
        imgui.TextColored(state.active and { 0.3, 1.0, 0.4, 1.0 } or { 0.8, 0.8, 0.8, 1.0 }, state.status);
        if (state.last_spell ~= '') then imgui.Text('Last: ' .. state.last_spell); end
        imgui.Separator();

        local mode_label = state.settings.mode[1] == 3 and 'Ambuscade: Plantoids (BRD/DNC)'
            or (state.settings.mode[1] == 2 and 'Command Rotation' or 'Spell Rotation');
        if (imgui.BeginCombo('Mode', mode_label)) then
            if (imgui.Selectable('Spell Rotation', state.settings.mode[1] == 1)) then
                if (state.active) then stop('Stopped: execution mode changed.'); end
                state.settings.mode[1] = 1;
                settings.save();
            end
            if (imgui.Selectable('Command Rotation', state.settings.mode[1] == 2)) then
                if (state.active) then stop('Stopped: execution mode changed.'); end
                state.settings.mode[1] = 2;
                settings.save();
            end
            if (imgui.Selectable('Ambuscade: Plantoids (BRD/DNC)', state.settings.mode[1] == 3)) then
                if (state.active) then stop('Stopped: execution mode changed.'); end
                state.settings.mode[1] = 3;
                settings.save();
            end
            imgui.EndCombo();
        end

        if (state.settings.mode[1] == 1) then
            for _, id in ipairs(skill_order) do
                if (imgui.Checkbox(skill_names[id], state.settings.selected[tostring(id)])) then
                    settings.save();
                end
                if (id % 2 == 0) then imgui.SameLine(205); end
            end
        elseif (state.settings.mode[1] == 2) then
            imgui.Text('Commands are executed from top to bottom and then repeated.');
            local remove_index = nil;
            for index, entry in ipairs(state.settings.commands) do
                if (imgui.Checkbox(('##enabled_%d'):fmt(index), entry.enabled)) then settings.save(); end
                imgui.SameLine();
                imgui.PushItemWidth(285);
                if (imgui.InputText(('##command_%d'):fmt(index), entry.text, 256)) then settings.save(); end
                imgui.PopItemWidth();
                imgui.SameLine();
                if (imgui.SmallButton(('X##remove_%d'):fmt(index))) then remove_index = index; end
            end
            if (remove_index ~= nil) then
                table.remove(state.settings.commands, remove_index);
                state.command_cursor = 1;
                settings.save();
            end
            if (imgui.Button('Add Command', { 120, 0 })) then
                table.insert(state.settings.commands, T{ enabled = T{ true }, text = T{ '' } });
                settings.save();
            end
        else
            imgui.TextWrapped('August 2026 Vol. Two: Plantoids (Morbols).');
            imgui.TextWrapped('Summon trusts manually, enter the battlefield, and press Start. The addon targets Julika, Jody, then Vivian and automates songs, Finale, combat, steps, healing, and weaponskills.');
            imgui.Separator();
            imgui.Text('Trust summoning is manual.');
            imgui.Text('Active mobs (uncheck when defeated)');
            for _, name in ipairs(ambuscade_targets) do
                if (imgui.Checkbox(name, state.ambuscade_mobs[name])) then
                    timeline_add(('%s: %s'):fmt(name, state.ambuscade_mobs[name][1]
                        and 'enabled' or 'skipped'));
                    state.next_action = now();
                end
            end
            imgui.Separator();
            imgui.Text('Skill permissions');
            for index, option in ipairs(ambuscade_skill_options) do
                if (imgui.Checkbox(option.label, state.settings.ambuscade.skills[option.key])) then
                    settings.save();
                    timeline_add(('%s: %s'):fmt(option.label,
                        state.settings.ambuscade.skills[option.key][1] and 'enabled' or 'disabled'));
                    state.next_action = now();
                end
                if (index % 2 == 1 and index < #ambuscade_skill_options) then imgui.SameLine(205); end
            end
            imgui.PushItemWidth(180);
            if (imgui.InputText('Weaponskill', state.settings.ambuscade.weapon_skill, 64)) then settings.save(); end
            if (imgui.SliderInt('Heal below HP%', state.settings.ambuscade.heal_below, 20, 80)) then settings.save(); end
            if (imgui.SliderInt('Shantotto II sync TP', state.settings.ambuscade.shantotto_sync_tp, 750, 1000)) then settings.save(); end
            if (imgui.SliderFloat('Maximum WS sync wait', state.settings.ambuscade.ws_sync_wait, 0.0, 10.0, '%.1f sec')) then settings.save(); end
            imgui.PopItemWidth();
            local trust_tp = shantotto_tp();
            local cor_tp = qultada_tp();
            imgui.Text(('Bettyboom TP: %d    Shantotto II: %s    Qultada: %s')
                :fmt(player_tp(), trust_tp ~= nil and tostring(trust_tp) or 'N/A',
                    cor_tp ~= nil and tostring(cor_tp) or 'N/A'));
            imgui.Text(('Finishing Moves: %d'):fmt(finishing_moves()));
            imgui.Text(('Own songs — March: %s  Minuet: %s'):fmt(
                has_player_buff(214) and 'active' or 'missing',
                has_player_buff(198) and 'active' or 'missing'));
            imgui.Text(('Known enemy buffs — Julika: %d  Vivian: %d  Jody: %d'):fmt(
                ambuscade_buff_count('Bozzetto Julika'),
                ambuscade_buff_count('Bozzetto Vivian'),
                ambuscade_buff_count('Bozzetto Jody')));
            imgui.Separator();
            imgui.TextColored({ 0.4, 0.8, 1.0, 1.0 }, 'Next: ' .. ambuscade_next_action_label());
            imgui.Text('Timeline (commands queued)');
            timeline_prune();
            if (#state.ambuscade_timeline == 0) then
                imgui.TextDisabled('No actions queued yet.');
            else
                local current_time = now();
                for _, entry in ipairs(state.ambuscade_timeline) do
                    imgui.Text(('%5.1fs ago  %s'):fmt(current_time - entry.time, entry.label));
                end
            end
        end
        imgui.Separator();

        if (not state.active) then
            if (imgui.Button('Start', { 90, 0 })) then start(); end
        else
            if (imgui.Button('Stop', { 90, 0 })) then stop('Skill-up session stopped.'); end
            imgui.SameLine();
            if (imgui.Button(state.paused and 'Resume' or 'Pause', { 90, 0 })) then
                state.paused = not state.paused;
                state.status = state.paused and 'Paused' or 'Running';
                state.next_action = now();
            end
        end
        if (state.settings.mode[1] == 1) then
            imgui.SameLine();
            if (imgui.Button('Refresh Spells', { 120, 0 })) then rebuild_spells(); end
        end

        if (state.settings.mode[1] ~= 3) then
            imgui.PushItemWidth(130);
            local minimum_delay = state.settings.mode[1] == 2 and 0.1 or 2.5;
            local delay_label = state.settings.mode[1] == 2 and 'Command interval (sec)' or 'Cast delay (sec)';
            if (imgui.SliderFloat(delay_label, state.settings.delay, minimum_delay, 30.0, '%.1f')) then settings.save(); end
        end
        if (state.settings.mode[1] == 1) then
            if (imgui.SliderInt('MP cost limit (0=off)', state.settings.mp_limit, 0, 100)) then settings.save(); end
            if (imgui.SliderInt('Rest below MP% (0=off)', state.settings.rest_below, 0, 50)) then settings.save(); end
            if (imgui.SliderInt('Resume above MP%', state.settings.resume_above, 25, 100)) then settings.save(); end
        end
        if (state.settings.mode[1] ~= 3) then imgui.PopItemWidth(); end

        if (state.settings.mode[1] == 1) then
            local target_label = party_target_label(state.settings.target_party[1]);
            if (imgui.BeginCombo('Friendly target', target_label)) then
                if (imgui.Selectable('None (current target)', state.settings.target_party[1] == -1)) then
                    state.settings.target_party[1] = -1;
                    settings.save();
                end

                local party = AshitaCore:GetMemoryManager():GetParty();
                if (party ~= nil) then
                    for index = 0, 5 do
                        if (party:GetMemberIsActive(index) == 1) then
                            local label = party_target_label(index);
                            if (imgui.Selectable(label, state.settings.target_party[1] == index)) then
                                state.settings.target_party[1] = index;
                                settings.save();
                            end
                        end
                    end
                end
                imgui.EndCombo();
            end
        end
    end
    imgui.End();
end);

ashita.events.register('unload', 'smartskillup_unload', function ()
    if (state.resting) then queue('/heal'); end
    settings.save();
end);
