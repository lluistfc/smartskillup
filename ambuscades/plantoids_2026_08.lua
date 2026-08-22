local M = {};

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
local ambuscade_queue = ctx.ambuscade_queue;

local ambuscade_targets = {
    'Bozzetto Julika',
    'Bozzetto Jody',
    'Bozzetto Vivian',
};

local ambuscade_bonus_target = 'Bozzetto Golden Bomb';

local function ambuscade_song_refresh_interval()
    local duration = state.settings.ambuscade.song_duration[1];
    local margin = state.settings.ambuscade.song_refresh_margin[1];
    return math.max(30.0, duration - margin);
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

local function vivian_should_be_slept()
    if (#role_actions('sleep', 'sleep') == 0) then return false; end
    local vivian = ambuscade_mob_checked('Bozzetto Vivian')
        and find_entity_named('Bozzetto Vivian') ~= nil;
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
            return current, false;
        end
        target_manager:SetTarget(bonus_index, true);
        return bonus, true;
    end

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

local function reset_ambuscade()
    state.ambuscade_phase = 'setup';
    state.ambuscade_cursor = 1;
    state.ambuscade_setup_verified = 0;
    state.ambuscade_song_attempts = 0;
    state.ambuscade_samba_at = 0;
    state.ambuscade_step_at = 0;
    state.ambuscade_lullaby_pending = false;
    state.ambuscade_lullaby_verify_at = 0;
    state.ambuscade_vivian_asleep = false;
    state.ambuscade_restore_target_index = 0;
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

local function try_priority_lullaby()
    if (not vivian_should_be_slept() or state.ambuscade_vivian_asleep) then return false; end

    local current_time = now();
    if (state.ambuscade_lullaby_pending) then
        if (current_time < state.ambuscade_lullaby_verify_at) then return false; end
        state.ambuscade_lullaby_pending = false;
        timeline_add('Sleep not confirmed; will retry when ready');
    end
    local sleep_action = role_actions('sleep', 'sleep')[1];
    if (sleep_action == nil) then return false; end
    if (sleep_action.kind == 'spell') then
        local spell = AshitaCore:GetResourceManager():GetSpellById(sleep_action.id);
        if (spell == nil or not is_spell_ready(spell)) then return false; end
    end
    if (find_entity_named(ambuscade_bonus_target) ~= nil) then return false; end

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
    target_manager:SetTarget(vivian_index, true);
    ambuscade_queue(sleep_action.name .. ' on Bozzetto Vivian', action_catalog.command(sleep_action, '<t>'));
    -- This private command is processed immediately after the spell command,
    -- once FFXI has locked the cast target, restoring the combat target without
    -- disengaging or changing the party's battle target.
    queue('/sms __restoretarget');
    state.last_spell = sleep_action.name;
    state.ambuscade_lullaby_pending = true;
    state.ambuscade_lullaby_verify_at = current_time + 5.0;
    state.status = 'Applying Sleep to Vivian; restoring combat target';
    state.next_action = current_time + 4.0;
    return true;
end

local function ready_role_action(role, effect)
    for _, action in ipairs(role_actions(role, effect)) do
        if (action_ready(action)) then return action; end
    end
    return nil;
end

local function use_ambuscade_action(action, target, status, delay)
    ambuscade_queue(action.name, action_catalog.command(action, target));
    state.last_spell = action.name;
    state.status = status or action.name;
    state.next_action = now() + (delay or (action.kind == 'spell' and 4.0 or 2.0));
end

local function tick_ambuscade()
    local current_time = now();
    local heal = ready_role_action('heal');
    if (heal and player_hp_percent() <= state.settings.ambuscade.heal_below[1]
        and current_time >= state.ambuscade_waltz_at) then
        use_ambuscade_action(heal, '<me>', 'Emergency self-heal', 3.0);
        state.ambuscade_waltz_at = current_time + 8.0;
        return;
    end
    if (try_priority_lullaby()) then return; end

    local setup = role_actions('setup_buff');
    if (state.ambuscade_phase == 'setup') then
        local action = setup[state.ambuscade_cursor];
        if (action) then
            use_ambuscade_action(action, '<me>', ('Setup buff %d/%d'):fmt(state.ambuscade_cursor, #setup),
                action.kind == 'spell' and 10.0 or 2.0);
            state.ambuscade_cursor = state.ambuscade_cursor + 1;
            return;
        end
        state.ambuscade_song_at = current_time + ambuscade_song_refresh_interval();
        state.ambuscade_phase = 'combat';
    end

    local target, changed = find_ambuscade_target();
    if (target == nil) then
        if (state.ambuscade_engaged) then stop('Ambuscade routine complete: all targets defeated.'); return; end
        state.status = 'Waiting for Ambuscade targets'; state.next_action = current_time + 0.5; return;
    end
    if (changed) then state.status = 'Switching target to ' .. target_name(target); state.next_action = current_time + 0.5; return; end
    if (not is_player_engaged()) then
        ambuscade_queue('Engage ' .. target_name(target), '/attack <t>');
        state.ambuscade_engaged = true; state.status = 'Engaging ' .. target_name(target);
        state.next_action = current_time + 1.0; return;
    end

    local tp, threshold = player_tp(), state.settings.ambuscade.weapon_skill_tp[1];
    local recovery = ready_role_action('tp_recovery');
    if (recovery and tp < threshold and current_time >= state.ambuscade_reverse_at) then
        use_ambuscade_action(recovery, '<me>', 'Recovering TP');
        state.ambuscade_reverse_at = current_time + 10.0; return;
    end
    local ws = ready_role_action('weapon_skill');
    if (ws and tp >= threshold) then
        local trusts_ready = shantotto_ready_for_ws() and qultada_ready_for_ws();
        if (state.ambuscade_ws_wait_started == 0) then state.ambuscade_ws_wait_started = current_time; end
        local waited = current_time - state.ambuscade_ws_wait_started;
        if (trusts_ready or waited >= state.settings.ambuscade.ws_sync_wait[1]) then
            use_ambuscade_action(ws, '<t>', ('Weaponskill: %s (%d TP)'):fmt(ws.name, tp));
            state.ambuscade_ws_wait_started = 0; return;
        end
        state.status = ('Holding WS for trusts (%.1f/%.1fs)'):fmt(waited, state.settings.ambuscade.ws_sync_wait[1]);
        state.next_action = current_time + 0.25; return;
    else
        state.ambuscade_ws_wait_started = 0;
    end

    local dispel = ready_role_action('dispel');
    if (dispel and target_has_enhancements(target) and current_time >= state.ambuscade_finale_at) then
        use_ambuscade_action(dispel, '<t>', 'Dispelling ' .. target_name(target), 3.0);
        state.ambuscade_finale_at = current_time + 15.0; return;
    end
    local buff = ready_role_action('combat_buff');
    if (buff and current_time >= state.ambuscade_samba_at) then
        use_ambuscade_action(buff, '<me>', 'Refreshing combat buff');
        state.ambuscade_samba_at = current_time + 60.0; return;
    end
    local debuff = ready_role_action('combat_debuff');
    if (debuff and current_time >= state.ambuscade_step_at) then
        use_ambuscade_action(debuff, '<t>', 'Applying combat debuff');
        state.ambuscade_step_at = current_time + 20.0; return;
    end
    if (#setup > 0 and current_time >= state.ambuscade_song_at) then
        state.ambuscade_phase = 'setup'; state.ambuscade_cursor = 1;
        state.next_action = current_time; state.status = 'Refreshing setup buffs'; return;
    end
    state.status = ('Fighting %s (%d%%)'):fmt(target_name(target), target_hp_percent(target));
    state.next_action = current_time + 0.5;
end

local function ambuscade_next_action_label()
    if (not state.active) then return 'Press Start'; end
    if (state.paused) then return 'Paused'; end
    if (state.ambuscade_phase == 'setup') then
        local action = role_actions('setup_buff')[state.ambuscade_cursor];
        return action and action.name or 'Begin combat';
    end
    if (vivian_should_be_slept() and not state.ambuscade_vivian_asleep) then
        local action = ready_role_action('sleep', 'sleep');
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
            timeline_add('Confirmed: Sleep on Bozzetto Vivian');
        elseif (removed or failed) then
            state.ambuscade_vivian_asleep = false;
            state.ambuscade_lullaby_pending = false;
            timeline_add(removed and 'Sleep ended on Bozzetto Vivian'
                or 'Selected Sleep action failed on Bozzetto Vivian');
            state.next_action = now();
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
end

return {
    targets = ambuscade_targets,
    reset = reset_ambuscade,
    tick = tick_ambuscade,
    next_action = ambuscade_next_action_label,
    on_text = on_text,
    timeline_prune = ctx.timeline_prune,
    timeline_add = timeline_add,
    player_tp = player_tp,
    shantotto_tp = shantotto_tp,
    qultada_tp = qultada_tp,
    finishing_moves = finishing_moves,
    role_count = function(role) return #role_actions(role); end,
    buff_count = ambuscade_buff_count,
    ui_stats = function()
        return {
            ('Player TP: %d  Shantotto II: %s  Qultada: %s'):fmt(player_tp(),
                shantotto_tp() or 'N/A', qultada_tp() or 'N/A'),
            ('Finishing Moves: %d  Setup buffs: %d'):fmt(finishing_moves(), #role_actions('setup_buff')),
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


