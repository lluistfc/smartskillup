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
local action_timing = require 'action_timing';
local combat_trace = require 'combat_trace';
local ENTITY_STATUS_ENGAGED = 1;

local defaults = T{
    visible = T{ true },
    mode = T{ 1 }, -- 1 = skill-up, 2 = commands, 3 = Ambuscade, 4 = AFK, 5 = Tangaroa
    delay = T{ 4.0 },
    mp_limit = T{ 0 },
    rest_below = T{ 15 },
    resume_above = T{ 85 },
    target_party = T{ -1 },
    commands = T{},
    actions = T{ rotation = T{} },
    afk_packet_log = T{ enabled = T{ false } },
    afk_recovery = T{
        enabled = T{ false },
        use_pathfinding = T{ true },
        use_pull_spell = T{ true },
        stop_distance = T{ 5.0 },
        max_time = T{ 8.0 },
        adopt_party_claims = T{ true },
        party_claim_range = T{ 30 },
    },
    afk_pull = T{
        enabled = T{ false },
        mob_name = T{ '' },
        spell_key = T{ '' },
        range = T{ 20 },
    },
    tangaroa = T{
        dagger = T{ 'Kaja Knife' },
        club = T{ '' },
        shell_weapon_skill = T{ 'True Strike' },
        holy_water_interval = T{ 1.2 },
    },
    ambuscade = T{
        profile = T{ 'plantoids_2026_08' },
        weapon_skill_tp = T{ 1000 },
        song_duration = T{ 150 },
        song_refresh_margin = T{ 15 },
        terpander_three_song = T{ true },
        approach_targets = T{ true },
        approach_stop_distance = T{ 5.0 },
        heal_below = T{ 55 },
        combat_debuff_duration = T{ 60 },
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
    action_catalog_retry_at = 0,
    last_spell = '',
    status = 'Idle',
    ambuscade_phase = 'idle',
    ambuscade_cursor = 1,
    ambuscade_opening_ability_cursor = 1,
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
    ambuscade_bonus_engage_at = 0,
    ambuscade_bonus_engage_attempts = 0,
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
    ambuscade_last_command_at = 0,
    ambuscade_last_heartbeat_at = 0,
    ambuscade_last_watchdog_at = 0,
    tangaroa_phase = 'exposed',
    tangaroa_equipped_phase = nil,
    tangaroa_holy_water_at = 0,
    tangaroa_lac_main_disabled = false,
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

local function target_trace_details(extra)
    local target = AshitaCore:GetMemoryManager():GetTarget();
    local entities = AshitaCore:GetMemoryManager():GetEntity();
    local index = target and (target:GetTargetIndex(0) or 0) or 0;
    local entity = index > 0 and type(GetEntity) == 'function' and GetEntity(index) or nil;
    local name = entity and (entity.Name or entity.name or '') or '';
    local server_id = index > 0 and (entities:GetServerId(index) or 0) or 0;
    local player_entity = type(GetPlayerEntity) == 'function' and GetPlayerEntity() or nil;
    local engaged = player_entity ~= nil and player_entity.Status == ENTITY_STATUS_ENGAGED;
    local party = AshitaCore:GetMemoryManager():GetParty();
    local tp = party and (party:GetMemberTP(0) or 0) or 0;
    return ('target_index=%d target_server_id=%s target_name=%q engaged=%s tp=%d pending=%s%s'):fmt(
        index, tostring(server_id), name, tostring(engaged), tp,
        tostring(state.pending_action and state.pending_action.token or 'none'), extra and (' ' .. extra) or '');
end

local function trace_event(label, details)
    combat_trace.event(now(), label, target_trace_details(details));
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
    state.ambuscade_last_command_at = now();
    trace_event('command_queue', ('label=%q command=%q'):fmt(label, command));
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
    local has_spells = player ~= nil and (player:HasSpellData() == true or player:HasSpellData() == 1);
    local has_abilities = player ~= nil and (player:HasAbilityData() == true or player:HasAbilityData() == 1);
    local action_count = #state.action_catalog.spells
        + #state.action_catalog.job_abilities
        + #state.action_catalog.weapon_skills;
    state.action_catalog_job = (has_spells or has_abilities) and action_count > 0
        and current_job_key(player) or -1;
    state.action_catalog_retry_at = now() + 1.0;
end

local function current_action_catalog()
    local player = AshitaCore:GetMemoryManager():GetPlayer();
    if (player and state.action_catalog_job ~= current_job_key(player)
        and now() >= state.action_catalog_retry_at) then
        rebuild_action_catalog();
    end
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
    state.pending_action = nil;
    state.last_action_outcome = nil;
    state.action_outcomes = {};
    state.action_outcome_order = {};
    state.status = reason or 'Stopped';
    if (state.settings.mode[1] == 3) then trace_event('session_stop', ('reason=%q'):fmt(state.status)); end
    combat_trace.close();
    log('notice', state.status);
end

local ambuscade;
local skillup;
local afk;
local tangaroa;
local function set_paused(value)
    state.paused = value;
    if (value and active_mode and active_mode.pause) then active_mode.pause(); end
    state.next_action = now();
    state.status = value and 'Paused' or 'Running';
    if (state.active and state.settings.mode[1] == 3) then
        trace_event('pause_changed', ('paused=%s source=user_command_or_panel'):fmt(tostring(value)));
    end
end
local function start()
    if (state.settings.mode[1] == 3) then
        local player = AshitaCore:GetMemoryManager():GetPlayer();
        if (not player_ready()) then
            log('error', 'The character is not ready.');
            return;
        end
        rebuild_action_catalog();
        local roles = state.settings.ambuscade.roles;
        local metadata = ('profile=%s ws_tp=%s song_duration=%s refresh_margin=%s terpander=%s roles_setup=%d roles_sleep=%d roles_ws=%d'):fmt(
            tostring(state.settings.ambuscade.profile[1]), tostring(state.settings.ambuscade.weapon_skill_tp[1]),
            tostring(state.settings.ambuscade.song_duration[1]), tostring(state.settings.ambuscade.song_refresh_margin[1]),
            tostring(state.settings.ambuscade.terpander_three_song[1]),
            #role_actions('setup_buff'), #role_actions('sleep'), #role_actions('weapon_skill'));
        local trace_path = combat_trace.open(metadata);
        if (trace_path ~= '') then log('notice', 'Ambuscade diagnostic log: ' .. trace_path); end
        state.combat_trace = function(time, label, details)
            combat_trace.event(time, label, target_trace_details(details));
        end;
        ambuscade.activate(); ambuscade.reset(); active_mode = ambuscade;
        state.ambuscade_last_command_at = now();
        state.ambuscade_last_heartbeat_at = 0;
        state.ambuscade_last_watchdog_at = 0;
        local valid, validation_message = ambuscade.validate();
        if (not valid) then
            combat_trace.close();
            log('error', validation_message);
            return;
        end
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
    elseif (state.settings.mode[1] == 5) then
        active_mode = tangaroa;
        local ok, message = tangaroa.start();
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
        or (state.settings.mode[1] == 5 and 'Tangaroa: ready'
        or (state.settings.mode[1] == 2 and 'Running commands' or 'Running actions')));
    log('ok', state.settings.mode[1] == 3 and (ambuscade.label .. ' routine started.')
        or (state.settings.mode[1] == 4 and 'AFK retaliation armed.'
        or (state.settings.mode[1] == 5 and 'Tangaroa routine started.'
        or (state.settings.mode[1] == 2 and 'Command session started.' or 'Skill-up session started.'))));
end

local function action_ready(action)
    if (action.kind == 'weaponskill') then
        local party = AshitaCore:GetMemoryManager():GetParty();
        return party ~= nil and (party:GetMemberTP(0) or 0) >= 1000;
    elseif (action.kind == 'spell') then
        local spell = AshitaCore:GetResourceManager():GetSpellById(action.id);
        return spell ~= nil and is_spell_ready(spell);
    elseif (action.kind == 'ability' and action.recast_id ~= nil) then
        local party = AshitaCore:GetMemoryManager():GetParty();
        if (party ~= nil and (party:GetMemberTP(0) or 0) < (action.tp_cost or 0)) then return false; end
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
    trace_event = trace_event,
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
    schedule_action = function(action, minimum_delay, target)
        local party = AshitaCore:GetMemoryManager():GetParty();
        local target_id = 0;
        if (target == '<me>') then
            target_id = party and (party:GetMemberServerId(0) or 0) or 0;
        elseif (target == '<t>') then
            local target_manager = AshitaCore:GetMemoryManager():GetTarget();
            local index = target_manager and (target_manager:GetTargetIndex(0) or 0) or 0;
            target_id = index > 0 and (AshitaCore:GetMemoryManager():GetEntity():GetServerId(index) or 0) or 0;
        else
            local party_index = type(target) == 'string' and tonumber(target:match('^<p(%d)>$')) or nil;
            if (party_index ~= nil and party_index >= 1 and party_index <= 5) then
                target_id = party and (party:GetMemberServerId(party_index) or 0) or 0;
            end
        end
        return action_timing.schedule(state, now(), action, minimum_delay, target_id);
    end,
    action_outcome = function(key) return action_timing.consume_outcome(state, key); end,
    cancel_action = function(reason) return action_timing.cancel(state, now(), reason); end,
    player_engaged = is_player_engaged,
};
ambuscade = require('modes.ambuscade').new(mode_context);
skillup = require('modes.skillup').new(mode_context);
afk = require('modes.afk').new(mode_context);
tangaroa = require('modes.tangaroa').new(mode_context);

local function tick()
    if (not state.active or state.paused) then return; end
    local current_time = now();
    if (state.settings.mode[1] == 3
        and current_time - (state.ambuscade_last_heartbeat_at or 0) >= 5.0) then
        state.ambuscade_last_heartbeat_at = current_time;
        trace_event('tick_heartbeat', ('active=%s paused=%s player_ready=%s phase=%s cursor=%s next_action=%.3f due=%s status=%q'):fmt(
            tostring(state.active), tostring(state.paused), tostring(player_ready()),
            tostring(state.ambuscade_phase), tostring(state.ambuscade_cursor),
            tonumber(state.next_action) or -1, tostring(current_time >= (tonumber(state.next_action) or 0)),
            tostring(state.status)));
        local player = type(GetPlayerEntity) == 'function' and GetPlayerEntity() or nil;
        local engaged = player ~= nil and player.Status == ENTITY_STATUS_ENGAGED;
        if (engaged and state.pending_action == nil
            and current_time - (state.ambuscade_last_command_at or current_time) >= 5.0
            and current_time - (state.ambuscade_last_watchdog_at or 0) >= 5.0) then
            state.ambuscade_last_watchdog_at = current_time;
            trace_event('rotation_watchdog', ('idle_for=%.2f phase=%s cursor=%s next_action=%.3f due=%s player_ready=%s status=%q'):fmt(
                current_time - state.ambuscade_last_command_at, tostring(state.ambuscade_phase),
                tostring(state.ambuscade_cursor), tonumber(state.next_action) or -1,
                tostring(current_time >= (tonumber(state.next_action) or 0)),
                tostring(player_ready()), tostring(state.status)));
        end
    end
    action_timing.poll(state, current_time);
    if (state.settings.mode[1] == 3 and ambuscade.urgent_tick()) then return; end
    if (state.pending_action ~= nil) then
        state.next_action = math.min(state.pending_action.timeout_at, current_time + 0.1);
        return;
    end
    if (current_time < state.next_action) then return; end
    if (state.settings.mode[1] ~= 4 and not player_ready()) then return; end

    if (state.settings.mode[1] == 3) then
        ambuscade.tick();
        return;
    elseif (state.settings.mode[1] == 4) then
        afk.tick();
        return;
    elseif (state.settings.mode[1] == 5) then
        tangaroa.tick();
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
        local expected_server_id = state.ambuscade_restore_target_server_id or 0;
        local entity_manager = AshitaCore:GetMemoryManager():GetEntity();
        local current_target = AshitaCore:GetMemoryManager():GetTarget();
        local current_index = current_target:GetTargetIndex(0) or 0;
        local current_entity = current_index > 0 and type(GetEntity) == 'function' and GetEntity(current_index) or nil;
        local current_name = current_entity and (current_entity.Name or current_entity.name or '') or '';
        local actual_server_id = index > 0 and (entity_manager:GetServerId(index) or 0) or 0;
        local allowed = current_name:lower() ~= 'bozzetto golden bomb'
            and index > 0 and expected_server_id ~= 0 and actual_server_id == expected_server_id
            and type(GetEntity) == 'function' and GetEntity(index) ~= nil;
        trace_event('lullaby_restore_command', ('allowed=%s restore_index=%d expected_server_id=%s actual_server_id=%s current_name=%q'):fmt(
            tostring(allowed), index, tostring(expected_server_id), tostring(actual_server_id), current_name));
        if (allowed) then
            current_target:SetTarget(index, true);
        end
        state.ambuscade_restore_target_index = 0;
        state.ambuscade_restore_target_server_id = 0;
    elseif (command:any('start', 'go', 'on')) then
        start();
    elseif (command:any('stop', 'off')) then
        stop('Skill-up session stopped.');
    elseif (command == 'pause') then
        set_paused(true); log('notice', 'Session paused.');
    elseif (command:any('resume', 'unpause')) then
        set_paused(false); log('ok', 'Session resumed.');
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
    if (state.active and state.settings.mode[1] == 3) then
        local message = (e.message_modified or ''):strip_colors():gsub('[\30\31\127]', ''):gsub('%c', ' ');
        trace_event('text_in', ('message=%q'):fmt(message));
    end
    if (state.active and state.pending_action ~= nil) then
        local message = (e.message_modified or ''):strip_colors():gsub('[\30\31\127]', ''):gsub('%c', ' '):lower();
        local party = AshitaCore:GetMemoryManager():GetParty();
        local player_name = party and (party:GetMemberName(0) or ''):lower() or '';
        local player_interrupted = player_name ~= ''
            and message:find(player_name .. "'s casting is interrupted", 1, true) ~= nil;
        if (message:find('unable to cast', 1, true)
            or player_interrupted
            or message:find('cannot use', 1, true)
            or message:find('not enough mp', 1, true)
            or message:find('recast time', 1, true)
            or message:find('unable to use', 1, true)) then
            action_timing.cancel(state, now(), message);
        end
    end
    if (state.settings.mode[1] == 3) then ambuscade.on_text(e); end
    if (state.active and state.settings.mode[1] == 5) then tangaroa.on_text(e); end
end);

ashita.events.register('packet_in', 'smartskillup_afk_packet', function (e)
    if (state.active and state.settings.mode[1] == 3) then combat_trace.packet(now(), 'in', e); end
    if (state.active) then action_timing.on_packet(state, e, now()); end
    if (state.active and state.settings.mode[1] == 4) then afk.on_packet(e); end
end);

ashita.events.register('packet_out', 'smartskillup_afk_packet_out', function (e)
    if (state.active and state.settings.mode[1] == 3) then combat_trace.packet(now(), 'out', e); end
    if (state.active) then action_timing.on_packet_out(state, e, now()); end
    if (state.active and state.settings.mode[1] == 3) then ambuscade.on_packet_out(e); end
    if (state.active and state.settings.mode[1] == 4) then afk.on_packet_out(e); end
end);

local config_ui = require 'config_ui';
local ui_context = {
    state = state,
    ambuscade_targets = function () return ambuscade.targets; end,
    ambuscade_label = ambuscade.profile_label,
    ambuscade_profiles = ambuscade.available_profiles,
    afk_state = afk.state,
    afk_scan_nearby = afk.scan_nearby,
    afk_nearby_mobs = afk.nearby_mobs,
    afk_pull_spells = afk.pull_spells,
    afk_packet_log_path = afk.packet_log_path,
    afk_sync_packet_log = afk.sync_packet_log,
    afk_navigation_status = afk.navigation_status,
    afk_test_navigation_path = afk.test_navigation_path,
    now = now,
    save = settings.save,
    stop = stop,
    pause = set_paused,
    start = start,
    refresh = rebuild_action_catalog,
    catalog = current_action_catalog,
    catalog_status = function()
        local player = AshitaCore:GetMemoryManager():GetPlayer();
        if (player == nil) then return 'Character data unavailable.'; end
        return ('Spell data: %s; ability data: %s.'):fmt(
            tostring(player:HasSpellData()), tostring(player:HasAbilityData()));
    end,
    has_effect = action_catalog.has_effect,
    party_target_label = party_target_label,
    timeline = ambuscade.timeline_add,
    prune_timeline = ambuscade.timeline_prune,
    wake = function () state.next_action = now(); end,
    next_action = ambuscade.next_action,
    ambuscade_stats = ambuscade.ui_stats,
    tangaroa_set_phase = tangaroa.set_phase,
};

ashita.events.register('d3d_present', 'smartskillup_present', function ()
    local ok, failure = xpcall(tick, debug.traceback);
    if (not ok) then
        trace_event('tick_exception', ('error=%q'):fmt(tostring(failure)));
        state.paused = true;
        state.status = 'Paused after combat tick error; see diagnostic log';
        log('error', state.status);
    end
    config_ui.render(ui_context);
end);

ashita.events.register('unload', 'smartskillup_unload', function ()
    combat_trace.close();
    if (state.active and active_mode and active_mode.stop) then active_mode.stop(); end
    if (afk and afk.shutdown_navigation) then afk.shutdown_navigation(); end
    if (state.resting) then queue('/heal'); end
    settings.save();
end);
