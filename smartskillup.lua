addon.name      = 'smartskillup';
addon.author    = 'RolandJ; Ashita port by Codex';
addon.version   = '1.1.0';
addon.desc      = 'Automates skill-up casting, command rotations, and supported Ambuscade fights.';
addon.link      = '';

require 'common';

local chat     = require 'chat';
local imgui    = require 'imgui';
local settings = require 'settings';
local action_catalog = require 'action_catalog';
local ENTITY_STATUS_ENGAGED = 1;

local defaults = T{
    visible = T{ true },
    mode = T{ 1 }, -- 1 = skill-up, 2 = commands, 3 = Ambuscade, 4 = AFK
    delay = T{ 4.0 },
    mp_limit = T{ 0 },
    rest_below = T{ 15 },
    resume_above = T{ 85 },
    target_party = T{ -1 },
    commands = T{},
    actions = T{ rotation = T{} },
    ambuscade = T{
        profile = T{ 'plantoids_2026_08' },
        weapon_skill_tp = T{ 1000 },
        song_duration = T{ 150 },
        song_refresh_margin = T{ 15 },
        heal_below = T{ 55 },
        shantotto_sync_tp = T{ 900 },
        ws_sync_wait = T{ 4.0 },
        roles = T{
            setup_buff = T{}, sleep = T{}, heal = T{}, dispel = T{},
            combat_buff = T{}, combat_debuff = T{}, tp_recovery = T{}, weapon_skill = T{},
        },
    },
};
local state = {
    settings = settings.load(defaults),
    active = false,
    paused = false,
    resting = false,
    next_action = 0,
    skill_cursor = 1,
    command_cursor = 1,
    action_catalog = { spells = {}, job_abilities = {}, weapon_skills = {}, by_key = {} },
    action_catalog_job = -1,
    last_spell = '',
    status = 'Idle',
    ambuscade_phase = 'idle',
    ambuscade_cursor = 1,
    ambuscade_setup_verified = 0,
    ambuscade_song_attempts = 0,
    ambuscade_samba_at = 0,
    ambuscade_step_at = 0,
    ambuscade_lullaby_pending = false,
    ambuscade_lullaby_verify_at = 0,
    ambuscade_vivian_asleep = false,
    ambuscade_restore_target_index = 0,
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
if (state.settings.ambuscade.weapon_skill_tp[1] ~= 1000
    and state.settings.ambuscade.weapon_skill_tp[1] ~= 2000
    and state.settings.ambuscade.weapon_skill_tp[1] ~= 3000) then
    state.settings.ambuscade.weapon_skill_tp[1] = 1000;
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
    return player ~= nil and player:GetLoginStatus() == 2
        and (player:HasSpellData() or player:HasAbilityData());
end

local function current_job_key(player)
    return player:GetMainJob() * 100000 + player:GetMainJobLevel() * 1000
        + player:GetSubJob() * 100 + player:GetSubJobLevel();
end

local function rebuild_action_catalog()
    local player = AshitaCore:GetMemoryManager():GetPlayer();
    state.action_catalog = action_catalog.build(player, AshitaCore:GetResourceManager());
    state.action_catalog_job = player and current_job_key(player) or -1;
end

local function current_action_catalog()
    local player = AshitaCore:GetMemoryManager():GetPlayer();
    if (player and state.action_catalog_job ~= current_job_key(player)) then rebuild_action_catalog(); end
    return state.action_catalog;
end

local function setting_checked(container, key)
    return container[key] ~= nil and container[key][1] == true;
end

local function selected_actions(container, category, effect)
    local result = {};
    local catalog = current_action_catalog();
    for _, action in ipairs(catalog[category] or {}) do
        if (setting_checked(container, action.key) and (effect == nil or action_catalog.has_effect(action, effect))) then
            table.insert(result, action);
        end
    end
    return result;
end

local function role_actions(role, effect)
    local result = {};
    local selected = state.settings.ambuscade.roles[role] or {};
    for _, category in ipairs({ 'spells', 'job_abilities', 'weapon_skills' }) do
        for _, action in ipairs(selected_actions(selected, category, effect)) do table.insert(result, action); end
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

local function is_spell_ready(spell)
    local timer = AshitaCore:GetMemoryManager():GetRecast():GetSpellTimer(spell.Index);
    return timer == nil or timer <= 0;
end

local function is_player_engaged()
    if (type(GetPlayerEntity) ~= 'function') then return false; end
    local entity = GetPlayerEntity();
    return entity ~= nil and entity.Status == ENTITY_STATUS_ENGAGED;
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

local active_mode;
local function stop(reason)
    if (state.active and active_mode and active_mode.stop) then active_mode.stop(); end
    if (state.resting) then queue('/heal'); end
    state.active = false;
    state.paused = false;
    state.resting = false;
    state.status = reason or 'Stopped';
    log('notice', state.status);
end

local ambuscade;
local skillup;
local afk;
local function start()
    if (state.settings.mode[1] == 3) then
        local player = AshitaCore:GetMemoryManager():GetPlayer();
        if (not player_ready()) then
            log('error', 'The character is not ready.');
            return;
        end
        rebuild_action_catalog();
        ambuscade.activate(); ambuscade.reset(); active_mode = ambuscade;
    elseif (state.settings.mode[1] == 2) then
        active_mode = nil;
        if (#enabled_commands() == 0) then
            log('error', 'Add and enable at least one command first.');
            return;
        end
    elseif (state.settings.mode[1] == 4) then
        active_mode = afk;
        local ok, message = afk.start();
        if (not ok) then log('error', message); return; end
    else
        active_mode = skillup;
        local ok, message = skillup.start();
        if (not ok) then log('error', message); return; end
    end
    state.active = true;
    state.paused = false;
    state.resting = false;
    state.next_action = now();
    state.status = state.settings.mode[1] == 3 and 'Ambuscade: preparing buffs'
        or (state.settings.mode[1] == 4 and state.status
        or (state.settings.mode[1] == 2 and 'Running commands' or 'Running actions'));
    log('ok', state.settings.mode[1] == 3 and (ambuscade.label .. ' routine started.')
        or (state.settings.mode[1] == 4 and 'AFK retaliation armed.'
        or (state.settings.mode[1] == 2 and 'Command session started.' or 'Skill-up session started.')));
end

local function action_ready(action)
    if (action.kind == 'weaponskill') then
        local party = AshitaCore:GetMemoryManager():GetParty();
        return party ~= nil and (party:GetMemberTP(0) or 0) >= 1000;
    elseif (action.kind == 'spell') then
        local spell = AshitaCore:GetResourceManager():GetSpellById(action.id);
        return spell ~= nil and is_spell_ready(spell);
    elseif (action.kind == 'ability' and action.recast_id ~= nil) then
        local recast = AshitaCore:GetMemoryManager():GetRecast();
        for index = 0, 31 do
            if (recast:GetAbilityTimerId(index) == action.recast_id) then
                return (recast:GetAbilityTimer(index) or 0) <= 0;
            end
        end
    end
    return true;
end

local mode_context = {
    state = state,
    now = now,
    queue = queue,
    action_catalog = action_catalog,
    role_actions = role_actions,
    is_spell_ready = is_spell_ready,
    is_player_engaged = is_player_engaged,
    action_ready = action_ready,
    stop = stop,
    timeline_add = timeline_add,
    timeline_prune = timeline_prune,
    ambuscade_queue = ambuscade_queue,
    selected_actions = selected_actions,
    refresh_catalog = rebuild_action_catalog,
    refresh_catalog_if_needed = function(player)
        if (player and current_job_key(player) ~= state.action_catalog_job) then rebuild_action_catalog(); end
    end,
    spell_target = function(id)
        local spell = AshitaCore:GetResourceManager():GetSpellById(id);
        return spell and target_for(spell) or '<t>';
    end,
    action_command = action_catalog.command,
    player_engaged = is_player_engaged,
};
ambuscade = require('modes.ambuscade').new(mode_context);
skillup = require('modes.skillup').new(mode_context);
afk = require('modes.afk').new(mode_context);

local function tick()
    if (not state.active or state.paused or now() < state.next_action) then return; end
    if (state.settings.mode[1] ~= 4 and not player_ready()) then return; end

    if (state.settings.mode[1] == 3) then
        ambuscade.tick();
        return;
    elseif (state.settings.mode[1] == 4) then
        afk.tick();
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

    skillup.tick();
end

local function print_help()
    log('notice', 'Commands: /sms start | stop | pause | resume | show | hide | actions | help');
    log('notice', 'Use the configuration window to select actions and assign Ambuscade roles.');
end

ashita.events.register('command', 'smartskillup_command', function (e)
    local args = e.command:args();
    if (#args == 0 or not args[1]:any('/sms', '/smartskillup', '/skillup')) then return; end
    e.blocked = true;
    local command = (#args > 1 and args[2]:lower()) or 'help';
    if (command == '__restoretarget') then
        local index = state.ambuscade_restore_target_index;
        if (index > 0 and type(GetEntity) == 'function' and GetEntity(index) ~= nil) then
            AshitaCore:GetMemoryManager():GetTarget():SetTarget(index, true);
        end
        state.ambuscade_restore_target_index = 0;
    elseif (command:any('start', 'go', 'on')) then
        start();
    elseif (command:any('stop', 'off')) then
        stop('Skill-up session stopped.');
    elseif (command == 'pause') then
        state.paused = true; state.status = 'Paused'; log('notice', 'Session paused.');
    elseif (command:any('resume', 'unpause')) then
        state.paused = false; state.next_action = now(); state.status = 'Running'; log('ok', 'Session resumed.');
    elseif (command == 'show') then
        state.settings.visible[1] = true; settings.save();
    elseif (command == 'hide') then
        state.settings.visible[1] = false; settings.save();
    elseif (command:any('actions', 'spells', 'spellreport')) then
        rebuild_action_catalog();
        for _, category in ipairs({ 'spells', 'job_abilities', 'weapon_skills' }) do
            local names = {};
            for _, action in ipairs(state.action_catalog[category]) do table.insert(names, action.name); end
            log('notice', category:gsub('_', ' ') .. ': ' .. (#names > 0 and table.concat(names, ', ') or '(none)'));
        end
    elseif (command == 'help') then
        print_help();
    else
        print_help();
    end
end);

ashita.events.register('text_in', 'smartskillup_ambuscade_buffs', function (e)
    if (state.settings.mode[1] == 3) then ambuscade.on_text(e); end
end);

ashita.events.register('packet_in', 'smartskillup_afk_packet', function (e)
    if (state.active and state.settings.mode[1] == 4) then afk.on_packet(e); end
end);

local config_ui = require 'config_ui';
local ui_context = {
    state = state,
    ambuscade_targets = function () return ambuscade.targets; end,
    ambuscade_label = ambuscade.profile_label,
    ambuscade_profiles = ambuscade.available_profiles,
    afk_state = afk.state,
    now = now,
    save = settings.save,
    stop = stop,
    start = start,
    refresh = rebuild_action_catalog,
    catalog = current_action_catalog,
    has_effect = action_catalog.has_effect,
    party_target_label = party_target_label,
    timeline = ambuscade.timeline_add,
    prune_timeline = ambuscade.timeline_prune,
    wake = function () state.next_action = now(); end,
    next_action = ambuscade.next_action,
    ambuscade_stats = ambuscade.ui_stats,
};

ashita.events.register('d3d_present', 'smartskillup_present', function ()
    tick();
    config_ui.render(ui_context);
end);

ashita.events.register('unload', 'smartskillup_unload', function ()
    if (state.active and active_mode and active_mode.stop) then active_mode.stop(); end
    if (state.resting) then queue('/heal'); end
    settings.save();
end);
