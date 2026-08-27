local M = {};
local combat_rotation = require 'combat_rotation';
local movement_controller = require 'movement_controller';

function M.new(ctx)
local state = ctx.state;
local now = ctx.now;
local queue = ctx.queue;
local action_catalog = ctx.action_catalog;
local role_actions = ctx.role_actions;
local is_spell_ready = ctx.is_spell_ready;
local is_player_engaged = ctx.is_player_engaged;
local action_ready = ctx.action_ready;
local stop = ctx.stop;
local timeline_add = ctx.timeline_add;
local trace = ctx.trace_event or function() end;
local ambuscade_queue = ctx.ambuscade_queue;

local ambuscade_targets = {
    'Bozzetto Julika',
    'Bozzetto Vivian',
    'Bozzetto Jody',
};

local ambuscade_bonus_target = 'Bozzetto Golden Bomb';
local opening_song_abilities = { 'Nightingale', 'Troubadour' };

local function find_job_ability(name)
    for _, action in ipairs(state.action_catalog.job_abilities or {}) do
        if ((action.name or ''):lower() == name:lower()) then return action; end
    end
    return nil;
end

local function try_opening_song_ability()
    local current_time = now();
    if (state.ambuscade_opening_started_at == 0) then
        state.ambuscade_opening_started_at = current_time;
        state.ambuscade_opening_deadline = current_time + 25;
    elseif (current_time >= state.ambuscade_opening_deadline) then
        trace('opening_degraded', 'reason=ability_deadline');
        state.ambuscade_opening_ability_cursor = #opening_song_abilities + 1;
        state.ambuscade_opening_pending_token = nil;
        state.status = 'Opening abilities degraded: opener deadline reached';
        return false;
    end
    if (state.ambuscade_opening_pending_token ~= nil) then
        local outcome = ctx.action_outcome(state.ambuscade_opening_pending_token);
        if (outcome == nil) then return true; end
        state.ambuscade_opening_pending_token = nil;
        if (outcome.status == 'completed') then
            trace('opening_ability_result', ('name=%q token=%s status=completed'):fmt(
                tostring(state.ambuscade_opening_pending_name), tostring(outcome.token)));
            state.ambuscade_opening_ability_cursor = state.ambuscade_opening_ability_cursor + 1;
        else
            local key = state.ambuscade_opening_pending_name or 'unknown';
            local attempts = (state.ambuscade_opening_attempts[key] or 0) + 1;
            state.ambuscade_opening_attempts[key] = attempts;
            if (attempts >= 2) then
                trace('opening_ability_result', ('name=%q token=%s status=%s attempts=%d degraded=true'):fmt(
                    key, tostring(outcome.token), tostring(outcome.status), attempts));
                state.ambuscade_opening_ability_cursor = state.ambuscade_opening_ability_cursor + 1;
                state.status = 'Opening ability degraded: ' .. key;
            end
        end
        state.ambuscade_opening_pending_name = nil;
    end
    while (state.ambuscade_opening_ability_cursor <= #opening_song_abilities) do
        local name = opening_song_abilities[state.ambuscade_opening_ability_cursor];
        local action = find_job_ability(name);
        if (action ~= nil and action_ready(action)) then
            ambuscade_queue(action.name, action_catalog.command(action, '<me>'));
            state.last_spell = action.name;
            state.status = 'Opening song ability: ' .. action.name;
            state.ambuscade_opening_pending_token = ctx.schedule_action(action, nil, '<me>');
            trace('opening_ability_queued', ('name=%q token=%s'):fmt(
                action.name, tostring(state.ambuscade_opening_pending_token)));
            state.ambuscade_opening_pending_name = action.name;
            return true;
        end
        state.ambuscade_opening_ability_cursor = state.ambuscade_opening_ability_cursor + 1;
    end
    return false;
end
local combat = combat_rotation.new(ctx);
local movement = movement_controller.new(ctx);

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

local function vivian_should_be_slept()
    if (#role_actions('sleep', 'sleep') == 0) then return false; end
    local vivian = ambuscade_mob_checked('Bozzetto Vivian')
        and find_entity_named('Bozzetto Vivian') ~= nil;
    -- Current target cannot determine intent here because the Lullaby FSM
    -- temporarily selects Vivian. Under the encounter kill order, Vivian is
    -- controlled only while Julika is still the live priority target.
    local julika = ambuscade_mob_checked('Bozzetto Julika')
        and find_entity_named('Bozzetto Julika') ~= nil;
    return vivian and julika;
end

local function find_ambuscade_target()
    local current = current_target();
    local target_manager = AshitaCore:GetMemoryManager():GetTarget();

    -- The Golden Bomb is a temporary bonus target worth extra hallmarks. It is
    -- deliberately independent of the normal mob checkboxes and always takes
    -- priority while alive.
    local bonus, bonus_index = find_entity_named(ambuscade_bonus_target);
    if (bonus ~= nil) then
        if (target_name(current):lower() == ambuscade_bonus_target:lower()
            and target_hp_percent(current) > 0) then
            return current, false, target_manager:GetTargetIndex(0);
        end
        target_manager:SetTarget(bonus_index, true);
        return bonus, true, bonus_index;
    end

    for _, expected in ipairs(ambuscade_targets) do
        local entity, index = find_entity_named(expected);
        if (ambuscade_mob_checked(expected) and entity ~= nil) then
            if (target_name(current):lower() == expected:lower()
                and target_hp_percent(current) > 0) then
                return current, false, target_manager:GetTargetIndex(0);
            end
            target_manager:SetTarget(index, true);
            return entity, true, index;
        end
    end
    return nil, false;
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

local function reset_ambuscade()
    movement.stop();
    combat.reset();
    state.ambuscade_opening_ability_cursor = 1;
    state.ambuscade_opening_pending_token = nil;
    state.ambuscade_opening_pending_name = nil;
    state.ambuscade_opening_attempts = {};
    state.ambuscade_opening_started_at = 0;
    state.ambuscade_opening_deadline = 0;
    state.ambuscade_lullaby_marcato_attempted = false;
    state.combat_opening_troubadour_seen = false;
    state.ambuscade_setup_verified = 0;
    state.ambuscade_initial_setup_complete = false;
    state.ambuscade_song_attempts = 0;
    state.ambuscade_lullaby_pending = false;
    state.ambuscade_lullaby_pending_token = nil;
    state.ambuscade_lullaby_restore_queued = false;
    state.ambuscade_lullaby_verify_at = 0;
    state.ambuscade_lullaby_attempts = 0;
    state.ambuscade_lullaby_retry_at = 0;
    state.ambuscade_lullaby_targeting = false;
    state.ambuscade_vivian_asleep = false;
    state.ambuscade_restore_target_index = 0;
    state.ambuscade_restore_target_server_id = 0;
    state.ambuscade_engaged = false;
    state.ambuscade_target_transition_server_id = 0;
    state.ambuscade_target_transition_until = 0;
    state.ambuscade_target_transition_retry_at = 0;
    state.ambuscade_target_transition_attempts = 0;
    state.ambuscade_bonus_engage_at = 0;
    state.ambuscade_bonus_engage_attempts = 0;
    state.ambuscade_bonus_server_id = 0;
    state.ambuscade_bonus_ws_pending_token = nil;
    state.ambuscade_bonus_ws_opened = false;
    state.ambuscade_bonus_ws_dispatched = false;
    state.ambuscade_bonus_spawn_at = 0;
    state.ambuscade_bonus_spawn_tp = 0;
    state.ambuscade_timeline = {};
    for _, name in ipairs(ambuscade_targets) do
        state.ambuscade_mobs[name][1] = true;
        state.ambuscade_buffs[name] = {};
    end
end

local function urgent_tick()
    local bonus, bonus_index = find_entity_named(ambuscade_bonus_target);
    if (bonus == nil or bonus_index == nil) then
        state.ambuscade_bonus_engage_at = 0;
        state.ambuscade_bonus_engage_attempts = 0;
        state.ambuscade_bonus_server_id = 0;
        state.ambuscade_bonus_ws_pending_token = nil;
        state.ambuscade_bonus_ws_opened = false;
        state.ambuscade_bonus_ws_dispatched = false;
        state.ambuscade_bonus_spawn_at = 0;
        state.ambuscade_bonus_spawn_tp = 0;
        return false;
    end

    local current_time = now();
    local entities = AshitaCore:GetMemoryManager():GetEntity();
    local bonus_server_id = entities:GetServerId(bonus_index) or 0;
    if (bonus_server_id == 0) then
        state.status = 'Priority interrupt: waiting for Golden Bomb identity';
        state.next_action = current_time + 0.05;
        return true;
    end
    if (state.ambuscade_bonus_server_id ~= bonus_server_id) then
        state.ambuscade_bonus_server_id = bonus_server_id;
        state.ambuscade_bonus_engage_attempts = 0;
        state.ambuscade_bonus_ws_pending_token = nil;
        state.ambuscade_bonus_ws_opened = false;
        state.ambuscade_bonus_ws_dispatched = false;
        state.ambuscade_bonus_spawn_at = current_time;
        state.ambuscade_bonus_spawn_tp = combat.player_tp();
        trace('golden_detected', ('server_id=%s index=%d spawn_tp=%d configured_ws=%q'):fmt(
            tostring(bonus_server_id), bonus_index, state.ambuscade_bonus_spawn_tp,
            tostring((role_actions('weapon_skill')[1] or {}).name)));
    end
    local current = current_target();
    local needs_target = target_name(current):lower() ~= ambuscade_bonus_target:lower();
    if (needs_target) then state.ambuscade_bonus_engage_attempts = 0; end

    movement.stop();
    AshitaCore:GetMemoryManager():GetTarget():SetTarget(bonus_index, true);

    local selected = current_target();
    local selected_index = AshitaCore:GetMemoryManager():GetTarget():GetTargetIndex(0) or 0;
    local selected_server_id = selected_index > 0 and (entities:GetServerId(selected_index) or 0) or 0;
    if (selected_server_id ~= bonus_server_id or target_name(selected):lower() ~= ambuscade_bonus_target:lower()) then
        trace('golden_target_wait', ('expected_server_id=%s selected_server_id=%s selected_name=%q'):fmt(
            tostring(bonus_server_id), tostring(selected_server_id), target_name(selected)));
        state.status = 'Priority interrupt: acquiring Golden Bomb target';
        state.next_action = current_time + 0.05;
        return true;
    end

    local party = AshitaCore:GetMemoryManager():GetParty();
    local hp_percent = party and (party:GetMemberHPPercent(0) or 100) or 100;
    local emergency_heal = combat.ready_role_action('heal');
    if (hp_percent <= 20 and emergency_heal ~= nil and state.pending_action == nil) then
        ambuscade_queue('Critical heal before Golden Bomb',
            action_catalog.command(emergency_heal, '<me>'));
        state.last_spell = emergency_heal.name;
        state.status = 'Critical survival action before Golden Bomb opener';
        ctx.schedule_action(emergency_heal, nil, '<me>');
        return true;
    end

    if (state.settings.ambuscade.approach_targets[1]) then
        local approaching, distance = movement.approach(
            bonus_index, state.settings.ambuscade.approach_stop_distance[1]);
        if (approaching) then
            state.status = ('Priority interrupt: approaching Golden Bomb (%.1f yalms)'):fmt(distance);
            state.next_action = current_time + 0.05;
            return true;
        end
    end

    if (state.ambuscade_bonus_ws_pending_token ~= nil) then
        local outcome = ctx.action_outcome(state.ambuscade_bonus_ws_pending_token);
        if (outcome == nil) then
            if (state.ambuscade_bonus_ws_dispatched
                and state.ambuscade_bonus_engage_attempts == 0) then
                ambuscade_queue('Switch trusts to ' .. ambuscade_bonus_target, '/attack <t>');
                state.ambuscade_bonus_engage_attempts = 1;
                state.ambuscade_bonus_engage_at = current_time + 0.5;
                trace('golden_trust_switch', 'reason=ws_outgoing_accepted');
            end
            state.status = 'Priority interrupt: opening Golden Bomb with weaponskill';
            state.next_action = current_time + 0.1;
            return true;
        end
        state.ambuscade_bonus_ws_pending_token = nil;
        trace('golden_ws_result', ('token=%s status=%s reason=%q'):fmt(
            tostring(outcome.token), tostring(outcome.status), tostring(outcome.reason)));
        if (outcome.status == 'completed') then
            state.ambuscade_bonus_ws_opened = true;
        end
    end

    local opening_ws = role_actions('weapon_skill')[1];
    local strict_ws = state.ambuscade_bonus_spawn_tp >= 1000 and opening_ws ~= nil;
    if (strict_ws and not state.ambuscade_bonus_ws_opened and combat.player_tp() >= 1000) then
        if (state.pending_action ~= nil) then
            trace('golden_strict_wait', ('reason=pending_action spawn_tp=%d live_tp=%d pending_token=%s'):fmt(
                state.ambuscade_bonus_spawn_tp, combat.player_tp(), tostring(state.pending_action.token)));
            state.status = 'Priority interrupt: holding first Golden Bomb offense for weaponskill';
            state.next_action = current_time + 0.1;
            return true;
        elseif (not action_ready(opening_ws)) then
            trace('golden_strict_wait', ('reason=ws_not_ready spawn_tp=%d live_tp=%d ws=%q'):fmt(
                state.ambuscade_bonus_spawn_tp, combat.player_tp(), opening_ws.name));
            state.status = 'Priority interrupt: waiting for strict Golden Bomb weaponskill';
            state.next_action = current_time + 0.1;
            return true;
        else
            ambuscade_queue('Golden Bomb opener: ' .. opening_ws.name,
                action_catalog.command(opening_ws, '<t>'));
            state.last_spell = opening_ws.name;
            state.status = 'Priority interrupt: weaponskill on ' .. ambuscade_bonus_target;
            state.ambuscade_bonus_ws_pending_token = ctx.schedule_action(opening_ws, nil, '<t>');
            trace('golden_ws_queued', ('token=%s ws=%q spawn_tp=%d live_tp=%d'):fmt(
                tostring(state.ambuscade_bonus_ws_pending_token), opening_ws.name,
                state.ambuscade_bonus_spawn_tp, combat.player_tp()));
            return true;
        end
    end

    local needs_attack_retry = state.ambuscade_bonus_engage_attempts < 4
        and current_time >= (state.ambuscade_bonus_engage_at or 0);
    if (not needs_target and not needs_attack_retry) then
        state.status = 'Priority interrupt: waiting for Golden Bomb resolution';
        state.next_action = current_time + 0.1;
        return true;
    end

    ambuscade_queue('Emergency engage ' .. ambuscade_bonus_target, '/attack <t>');
    trace('golden_attack_fallback', ('spawn_tp=%d live_tp=%d engaged=%s ws_opened=%s attempts=%d'):fmt(
        state.ambuscade_bonus_spawn_tp, combat.player_tp(), tostring(is_player_engaged()),
        tostring(state.ambuscade_bonus_ws_opened), state.ambuscade_bonus_engage_attempts + 1));
    state.ambuscade_engaged = true;
    state.ambuscade_bonus_engage_attempts = state.ambuscade_bonus_engage_attempts + 1;
    state.ambuscade_bonus_engage_at = current_time + 0.5;
    state.status = 'Priority interrupt: engaging ' .. ambuscade_bonus_target;
    state.next_action = current_time + 0.25;
    return true;
end

local function try_priority_lullaby()
    -- Preserve the full Troubadour/Nightingale window for the initial song
    -- rotation. Once that opener has completed, Lullaby remains a priority
    -- even while recurring buffs are later being refreshed.
    if (not state.ambuscade_initial_setup_complete) then return false; end
    if (not vivian_should_be_slept() or state.ambuscade_vivian_asleep) then
        state.ambuscade_lullaby_targeting = false;
        return false;
    end

    local current_time = now();
    if (current_time < (state.ambuscade_lullaby_retry_at or 0)) then return false; end
    if (state.ambuscade_lullaby_pending) then
        if (current_time < state.ambuscade_lullaby_verify_at) then return false; end
        state.ambuscade_lullaby_pending = false;
        state.ambuscade_lullaby_pending_token = nil;
        state.ambuscade_lullaby_attempts = (state.ambuscade_lullaby_attempts or 0) + 1;
        local retry_delays = { 1, 2, 5 };
        local delay = retry_delays[math.min(#retry_delays, state.ambuscade_lullaby_attempts)];
        state.ambuscade_lullaby_retry_at = current_time + delay;
        timeline_add(('Sleep not confirmed; retrying in %ds'):fmt(delay));
        trace('lullaby_retry', ('reason=verification_timeout attempts=%d delay=%d'):fmt(
            state.ambuscade_lullaby_attempts, delay));
        return false;
    end
    local sleep_actions = role_actions('sleep', 'sleep');
    local sleep_action;
    for _, expected in ipairs({ 'Foe Lullaby II', 'Foe Lullaby', 'Horde Lullaby II', 'Horde Lullaby' }) do
        for _, action in ipairs(sleep_actions) do
            if ((action.name or ''):lower() == expected:lower()) then sleep_action = action; break; end
        end
        if (sleep_action ~= nil) then break; end
    end
    sleep_action = sleep_action or sleep_actions[1];
    if (sleep_action == nil) then return false; end
    if (sleep_action.kind == 'spell') then
        local spell = AshitaCore:GetResourceManager():GetSpellById(sleep_action.id);
        if (spell == nil or not is_spell_ready(spell)) then return false; end
    end
    if (find_entity_named(ambuscade_bonus_target) ~= nil) then return false; end

    if (not state.ambuscade_lullaby_marcato_attempted) then
        state.ambuscade_lullaby_marcato_attempted = true;
        local marcato = find_job_ability('Marcato');
        if (marcato ~= nil and action_ready(marcato)) then
            ambuscade_queue('Marcato for Vivian Lullaby', action_catalog.command(marcato, '<me>'));
            state.last_spell = marcato.name;
            state.status = 'Preparing high-accuracy Lullaby for Vivian';
            ctx.schedule_action(marcato, nil, '<me>');
            trace('lullaby_marcato_queued', ('vivian_pending=false name=%q'):fmt(marcato.name));
            return true;
        end
    end

    local vivian, vivian_index = find_entity_named('Bozzetto Vivian');
    if (vivian == nil) then return false; end

    local target_manager = AshitaCore:GetMemoryManager():GetTarget();
    local restore_index = target_manager:GetTargetIndex(0) or 0;
    local restore_entity = restore_index > 0 and GetEntity(restore_index) or nil;
    if (restore_index == 0 or target_name(restore_entity):lower() == 'bozzetto vivian') then
        local _, julika_index = find_entity_named('Bozzetto Julika');
        restore_index = julika_index or 0;
    end
    if (restore_index == 0) then return false; end

    state.ambuscade_restore_target_index = restore_index;
    local entities = AshitaCore:GetMemoryManager():GetEntity();
    state.ambuscade_restore_target_server_id = entities:GetServerId(restore_index) or 0;
    local current_index = target_manager:GetTargetIndex(0) or 0;
    local current_server_id = current_index > 0 and (entities:GetServerId(current_index) or 0) or 0;
    local vivian_server_id = entities:GetServerId(vivian_index) or 0;
    if (current_server_id ~= vivian_server_id) then
        state.ambuscade_lullaby_targeting = true;
        trace('lullaby_target_request', ('vivian_index=%d vivian_server_id=%s restore_index=%d restore_server_id=%s current_server_id=%s'):fmt(
            vivian_index, tostring(vivian_server_id), restore_index,
            tostring(state.ambuscade_restore_target_server_id), tostring(current_server_id)));
        target_manager:SetTarget(vivian_index, true);
        state.status = 'Acquiring Vivian for priority Lullaby';
        state.next_action = current_time + 0.05;
        return true;
    end
    state.ambuscade_lullaby_targeting = false;
    ambuscade_queue(sleep_action.name .. ' on Bozzetto Vivian', action_catalog.command(sleep_action, '<t>'));
    state.last_spell = sleep_action.name;
    state.ambuscade_lullaby_pending = true;
    state.ambuscade_lullaby_verify_at = current_time + 5.0;
    state.status = 'Applying Sleep to Vivian; restoring combat target';
    local sleep_token = ctx.schedule_action(sleep_action, nil, '<t>');
    state.ambuscade_lullaby_pending_token = sleep_token;
    state.ambuscade_lullaby_restore_queued = false;
    trace('lullaby_queued', ('token=%s spell=%q vivian_index=%d vivian_server_id=%s restore_index=%d restore_server_id=%s'):fmt(
        tostring(sleep_token), sleep_action.name, vivian_index, tostring(vivian_server_id),
        restore_index, tostring(state.ambuscade_restore_target_server_id)));
    return true;
end

local function tick_ambuscade()
    local current_time = now();
    -- A target change made for Lullaby spans frames. Let that operation verify
    -- and dispatch before the normal kill-target selector restores Julika.
    if (state.ambuscade_lullaby_targeting and try_priority_lullaby()) then return; end
    local target, changed, target_index = find_ambuscade_target();
    if (target == nil) then
        movement.stop();
        if (state.ambuscade_engaged) then stop('Ambuscade routine complete: all targets defeated.'); return; end
        if (state.ambuscade_phase == 'setup' and state.ambuscade_song_at == 0
            and try_opening_song_ability()) then return; end
        if (combat.tick({
            has_target = false,
            target_name = target_name(target),
            target_has_enhancements = false,
            queue_action = ambuscade_queue,
        })) then return; end
        state.status = 'Waiting for Ambuscade targets'; state.next_action = current_time + 0.5; return;
    end
    if (changed) then
        movement.stop();
        if (state.pending_action ~= nil and state.pending_action.target_server_id ~= 0) then
            local new_server_id = AshitaCore:GetMemoryManager():GetEntity():GetServerId(target_index) or 0;
            local player_id = AshitaCore:GetMemoryManager():GetParty():GetMemberServerId(0) or 0;
            if (new_server_id ~= 0 and state.pending_action.target_server_id ~= new_server_id
                and state.pending_action.target_server_id ~= player_id) then
                ctx.cancel_action('target_changed');
            end
        end
        ambuscade_queue('Engage ' .. target_name(target), '/attack <t>');
        trace('normal_target_changed', ('desired_index=%s desired_name=%q attack_queued=true'):fmt(
            tostring(target_index), target_name(target)));
        state.ambuscade_engaged = true;
        local server_id = AshitaCore:GetMemoryManager():GetEntity():GetServerId(target_index) or 0;
        state.ambuscade_target_transition_server_id = server_id;
        state.ambuscade_target_transition_until = current_time + 1.0;
        state.ambuscade_target_transition_retry_at = current_time + 0.35;
        state.ambuscade_target_transition_attempts = 1;
        state.status = 'Engaging new target ' .. target_name(target);
        state.next_action = current_time + 0.15;
        return;
    end
    local transition_id = state.ambuscade_target_transition_server_id or 0;
    if (transition_id ~= 0) then
        local selected_id = AshitaCore:GetMemoryManager():GetEntity():GetServerId(target_index) or 0;
        if (selected_id ~= transition_id) then
            state.ambuscade_target_transition_server_id = 0;
        elseif (current_time < state.ambuscade_target_transition_until) then
            if (current_time >= state.ambuscade_target_transition_retry_at
                and state.ambuscade_target_transition_attempts < 3) then
                ambuscade_queue('Confirm engage ' .. target_name(target), '/attack <t>');
                state.ambuscade_target_transition_attempts = state.ambuscade_target_transition_attempts + 1;
                state.ambuscade_target_transition_retry_at = current_time + 0.35;
                trace('normal_target_engage_retry', ('server_id=%s attempt=%d'):fmt(
                    tostring(transition_id), state.ambuscade_target_transition_attempts));
            end
            state.status = 'Confirming party target ' .. target_name(target);
            state.next_action = current_time + 0.1;
            return;
        else
            trace('normal_target_transition_settled', ('server_id=%s attempts=%d'):fmt(
                tostring(transition_id), state.ambuscade_target_transition_attempts));
            state.ambuscade_target_transition_server_id = 0;
        end
    end
    if (not is_player_engaged()) then
        ambuscade_queue('Engage ' .. target_name(target), '/attack <t>');
        state.ambuscade_engaged = true; state.status = 'Engaging ' .. target_name(target);
        state.next_action = current_time + 0.15; return;
    end

    -- Once a target exists, establish combat before spending time on any job
    -- ability or song so trusts begin attacking immediately after transitions.
    if (state.ambuscade_phase == 'setup' and state.ambuscade_song_at == 0
        and try_opening_song_ability()) then return; end
    if (state.ambuscade_phase == 'combat') then
        state.ambuscade_initial_setup_complete = true;
    end
    if (try_priority_lullaby()) then return; end

    if (state.ambuscade_phase == 'setup') then
        if (combat.tick({
            has_target = false,
            target_has_enhancements = false,
            queue_action = ambuscade_queue,
        })) then return; end
    end

    local approaching, distance = false, movement.distance(target_index);
    local target_server_id = AshitaCore:GetMemoryManager():GetEntity():GetServerId(target_index) or 0;
    local melee_confirmed = target_server_id ~= 0
        and state.combat_melee_target_server_id == target_server_id
        and current_time - (state.combat_melee_confirmed_at or 0) <= 3.5;
    if (state.settings.ambuscade.approach_targets[1] and not melee_confirmed) then
        approaching, distance = movement.approach(
            target_index, state.settings.ambuscade.approach_stop_distance[1]);
    else
        movement.stop();
    end
    if (approaching) then
        state.status = ('Approaching %s (%.1f yalms)'):fmt(target_name(target), distance);
        state.next_action = current_time + 0.1;
        return;
    elseif (melee_confirmed and distance ~= nil
        and distance > state.settings.ambuscade.approach_stop_distance[1]) then
        trace('approach_suppressed', ('reason=recent_melee distance=%.2f server_id=%s'):fmt(
            distance, tostring(target_server_id)));
    end

    local combat_target_server_id = AshitaCore:GetMemoryManager():GetEntity():GetServerId(target_index) or 0;
    local combat_target_key = combat_target_server_id ~= 0
        and tostring(combat_target_server_id) or ('index:%d'):fmt(target_index);
    if (combat.tick({
        has_target = true,
        target_key = combat_target_key,
        target_name = target_name(target),
        target_has_enhancements = target_has_enhancements(target),
        queue_action = ambuscade_queue,
    })) then return; end

    state.status = ('Fighting %s (%d%%)'):fmt(target_name(target), target_hp_percent(target));
    state.next_action = current_time + 0.5;
end

local function ambuscade_next_action_label()
    if (not state.active) then return 'Press Start'; end
    if (state.paused) then return 'Paused'; end
    if (state.ambuscade_phase == 'setup') then
        local action = combat.setup_actions()[state.ambuscade_cursor];
        return action and action.name or 'Begin combat';
    end
    if (vivian_should_be_slept() and not state.ambuscade_vivian_asleep) then
        local action = combat.ready_role_action('sleep', 'sleep');
        if (action) then return action.name .. ' on Vivian'; end
    end
    return 'Selected actions / combat';
end

local function on_text(e)
    if (state.settings.mode[1] ~= 3) then return; end
    local message = (e.message_modified or ''):strip_colors():gsub('[\30\31\127]', ''):gsub('%c', ' ');
    local lower = message:lower();

    if (lower:find('bozzetto vivian', 1, true)) then
        local applied = lower:find('falls asleep', 1, true)
            or lower:find('is put to sleep', 1, true)
            or lower:find('is asleep', 1, true)
            or lower:find('afflicted with sleep', 1, true);
        local removed = lower:find('is no longer asleep', 1, true)
            or lower:find('wakes up', 1, true)
            or lower:find('awakens', 1, true)
            or lower:find('sleep effect wears off', 1, true)
            or lower:find('sleep effect disappears', 1, true);
        local attempted = (state.last_spell or ''):lower();
        local mentions_sleep_action = lower:find('sleep', 1, true)
            or (attempted ~= '' and lower:find(attempted, 1, true));
        local failed = (lower:find('resist', 1, true) and mentions_sleep_action)
            or (lower:find('no effect', 1, true) and mentions_sleep_action);

        if (applied) then
            state.ambuscade_vivian_asleep = true;
            state.ambuscade_lullaby_pending = false;
            state.ambuscade_lullaby_attempts = 0;
            state.ambuscade_lullaby_retry_at = 0;
            state.ambuscade_lullaby_pending_token = nil;
            timeline_add('Confirmed: Sleep on Bozzetto Vivian');
            trace('lullaby_text_result', ('status=applied message=%q'):fmt(message));
        elseif (removed or failed) then
            state.ambuscade_vivian_asleep = false;
            state.ambuscade_lullaby_pending = false;
            state.ambuscade_lullaby_pending_token = nil;
            state.ambuscade_lullaby_attempts = (state.ambuscade_lullaby_attempts or 0) + 1;
            local retry_delays = { 1, 2, 5 };
            state.ambuscade_lullaby_retry_at = now()
                + retry_delays[math.min(#retry_delays, state.ambuscade_lullaby_attempts)];
            timeline_add(removed and 'Sleep ended on Bozzetto Vivian'
                or 'Selected Sleep action failed on Bozzetto Vivian');
            trace('lullaby_text_result', ('status=%s attempts=%d retry_at=%.3f message=%q'):fmt(
                removed and 'removed' or 'failed', state.ambuscade_lullaby_attempts,
                state.ambuscade_lullaby_retry_at, message));
            state.next_action = state.ambuscade_lullaby_retry_at;
        end
    end

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


    if (lower:find('magic finale', 1, true) and lower:find('no effect', 1, true)) then
        for _, name in ipairs(ambuscade_targets) do
            if (lower:find(name:lower(), 1, true)) then
                state.ambuscade_buffs[name] = {};
                state.ambuscade_finale_at = now() + 30.0;
                trace('finale_text_result', ('target=%q status=no_effect buffs_cleared=true'):fmt(name));
            end
        end
    end

    local step_level = lower:match('sluggish daze %(lv%.(%d+)%)');
    if (step_level ~= nil and lower:find('box step', 1, true)) then
        for _, name in ipairs(ambuscade_targets) do
            if (lower:find(name:lower(), 1, true)) then
                local _, index = find_entity_named(name);
                local server_id = index and (AshitaCore:GetMemoryManager():GetEntity():GetServerId(index) or 0) or 0;
                if (server_id ~= 0) then
                    local key = ('%s|ability:714'):fmt(tostring(server_id));
                    local level = tonumber(step_level) or 0;
                    state.combat_step_state[key] = {
                        level = level,
                        confirmed_level = level,
                        expires = now() + 60,
                        confidence = 'battle_text',
                    };
                    state.combat_debuff_until[key] = now() + (level >= 5 and 45 or 6);
                    trace('step_text_confirmed', ('target=%q key=%q level=%d'):fmt(name, key, level));
                end
            end
        end
    end
end

local function on_packet_out()
    local golden_token = state.ambuscade_bonus_ws_pending_token;
    if (golden_token ~= nil and state.pending_action ~= nil
        and state.pending_action.token == golden_token and state.pending_action.sent_at ~= nil
        and not state.ambuscade_bonus_ws_dispatched) then
        state.ambuscade_bonus_ws_dispatched = true;
        trace('golden_ws_dispatched', ('token=%s target_server_id=%s'):fmt(
            tostring(golden_token), tostring(state.pending_action.outgoing_target_server_id)));
    end
    local token = state.ambuscade_lullaby_pending_token;
    local pending = state.pending_action;
    if (token == nil or state.ambuscade_lullaby_restore_queued
        or pending == nil or pending.token ~= token or pending.sent_at == nil) then return; end
    state.ambuscade_lullaby_restore_queued = true;
    trace('lullaby_outgoing_accepted', ('token=%s outgoing_target_server_id=%s restore_queued=true'):fmt(
        tostring(token), tostring(pending.outgoing_target_server_id)));
    queue('/sms __restoretarget');
end

return {
    targets = ambuscade_targets,
    reset = reset_ambuscade,
    stop = movement.stop,
    pause = movement.stop,
    urgent_tick = urgent_tick,
    tick = tick_ambuscade,
    next_action = ambuscade_next_action_label,
    on_text = on_text,
    on_packet_out = on_packet_out,
    timeline_prune = ctx.timeline_prune,
    timeline_add = timeline_add,
    player_tp = combat.player_tp,
    shantotto_tp = combat.shantotto_tp,
    qultada_tp = combat.qultada_tp,
    finishing_moves = finishing_moves,
    validate = function()
        if (not state.settings.ambuscade.terpander_three_song[1]) then return true, nil; end
        local ok, missing = combat.terpander_rotation_ready();
        return ok, ok and nil or ('Terpander rotation is missing: ' .. tostring(missing));
    end,
    role_count = function(role) return #role_actions(role); end,
    buff_count = ambuscade_buff_count,
    ui_stats = function()
        return {
            ('Player TP: %d  Shantotto II: %s  Qultada: %s'):fmt(combat.player_tp(),
                combat.shantotto_tp() or 'N/A', combat.qultada_tp() or 'N/A'),
            ('Finishing Moves: %d  Setup buffs: %d'):fmt(finishing_moves(), #combat.setup_actions()),
            'Vivian Sleep: ' .. (state.ambuscade_lullaby_pending and 'verifying'
                or (state.ambuscade_vivian_asleep and 'active' or 'missing')),
            ('Known enemy buffs — Julika: %d  Vivian: %d  Jody: %d'):fmt(
                ambuscade_buff_count('Bozzetto Julika'), ambuscade_buff_count('Bozzetto Vivian'),
                ambuscade_buff_count('Bozzetto Jody')),
        };
    end,
};
end

return M;
