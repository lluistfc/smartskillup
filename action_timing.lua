local M = {};

local ACTION_PACKET = 0x0028;
local NIGHTINGALE_BUFF = 347;
local RESULT_CATEGORIES = {
    spell = 4,
    ability = 6,
    weaponskill = 3,
};

function M.is_healing_spell_name(name)
    local lower = (name or ''):lower();
    return lower == 'cure' or lower:match('^cure %a+$') ~= nil
        or lower == 'curaga' or lower:match('^curaga %a+$') ~= nil
        or lower == 'cura' or lower:match('^cura %a+$') ~= nil
        or lower == 'full cure';
end

local function spell_name(param)
    local resources = AshitaCore:GetResourceManager();
    local spell = resources and resources:GetSpellById(param) or nil;
    if spell == nil then return ''; end
    local name = spell.Name;
    if type(name) == 'string' then return name; end
    if name ~= nil then
        local ok, value = pcall(function() return name[1] or name[0]; end);
        if ok and type(value) == 'string' then return value; end
    end
    return '';
end

local function track_incoming_heal(state, actor, category, param, targets, current_time)
    if category ~= 8 and category ~= 4 then return; end
    local name = spell_name(param);
    if not M.is_healing_spell_name(name) then return; end
    state.combat_incoming_heals = state.combat_incoming_heals or {};
    for _, target_id in ipairs(targets or {}) do
        local key = tostring(target_id) .. '|' .. tostring(actor) .. '|' .. tostring(param);
        if category == 8 then
            state.combat_incoming_heals[key] = {
                target_server_id = target_id,
                actor_server_id = actor,
                spell_id = param,
                spell_name = name,
                expires_at = current_time + 8.0,
            };
            if state.combat_trace ~= nil then
                state.combat_trace(current_time, 'incoming_heal_started', ('spell=%q actor_server_id=%s target_server_id=%s expires_at=%.3f'):fmt(
                    name, tostring(actor), tostring(target_id), current_time + 8.0));
            end
        else
            state.combat_incoming_heals[key] = nil;
            if state.combat_trace ~= nil then
                state.combat_trace(current_time, 'incoming_heal_resolved', ('spell=%q actor_server_id=%s target_server_id=%s'):fmt(
                    name, tostring(actor), tostring(target_id)));
            end
        end
    end
end

local function result_category_matches(pending, category)
    if (pending.kind == 'ability' and pending.is_step and category == 14) then return true; end
    return category == RESULT_CATEGORIES[pending.kind];
end

local function has_player_buff(buff_id)
    local player = AshitaCore:GetMemoryManager():GetPlayer();
    local buffs = player and (player:GetBuffs() or {}) or {};
    for _, active in pairs(buffs) do
        if (active == buff_id) then return true; end
    end
    return false;
end

function M.delay(action)
    if (action.kind == 'spell') then
        if (action.is_song and has_player_buff(NIGHTINGALE_BUFF)) then return 1.50; end
        return math.max(1.0, math.min(12.0, (action.cast_time or 0) + 0.75));
    elseif (action.kind == 'weaponskill') then
        return 1.75;
    elseif (action.kind == 'ability') then
        return 1.25;
    end
    return 1.0;
end

function M.schedule(state, current_time, action, minimum_delay, target_server_id)
    local delay = math.max(minimum_delay or 0, M.delay(action));
    state.action_sequence = (state.action_sequence or 0) + 1;
    local token = state.action_sequence;
    state.pending_action = {
        token = token,
        key = action.key,
        id = action.id,
        packet_id = action.packet_id or action.id,
        name = action.name,
        kind = action.kind,
        is_song = action.is_song,
        is_step = (action.name or ''):lower():find('step', 1, true) ~= nil,
        cast_time = action.cast_time,
        delay = delay,
        started_at = current_time,
        target_server_id = target_server_id or 0,
        sent_at = nil,
        deadline = current_time + delay,
        timeout_at = current_time + math.max(8.0, delay + 5.0),
    };
    state.next_action = current_time + delay;
    if (state.combat_trace ~= nil) then
        state.combat_trace(current_time, 'action_schedule', ('token=%d key=%s id=%s kind=%s name=%q delay=%.2f'):fmt(
            token, tostring(action.key), tostring(action.id), tostring(action.kind), tostring(action.name), delay));
    end
    return token;
end

local function store_outcome(state, outcome)
    state.action_outcomes = state.action_outcomes or {};
    state.action_outcome_order = state.action_outcome_order or {};
    state.action_outcomes[outcome.token] = outcome;
    table.insert(state.action_outcome_order, outcome.token);
    while (#state.action_outcome_order > 32) do
        local expired = table.remove(state.action_outcome_order, 1);
        state.action_outcomes[expired] = nil;
    end
    state.last_action_outcome = outcome;
end

local function finish(state, status, current_time, reason)
    local pending = state.pending_action;
    if (pending == nil) then return false; end
    state.pending_action = nil;
    store_outcome(state, {
        token = pending.token,
        key = pending.key,
        name = pending.name,
        kind = pending.kind,
        status = status,
        reason = reason,
        time = current_time,
    });
    if (state.combat_trace ~= nil) then
        state.combat_trace(current_time, 'action_finish', ('token=%d key=%s kind=%s status=%s reason=%q'):fmt(
            pending.token, tostring(pending.key), tostring(pending.kind), status, tostring(reason)));
    end
    -- Completion packets arrive before the client is always ready to accept
    -- the next command. Preserve a short recovery window; the old 0.15s
    -- acceleration caused the live NiTro opener to spam "unable to cast".
    -- A song's result packet is visible well before the client releases the
    -- song animation lock. Live NiTro traces showed that a 0.75s recovery
    -- queued the next song while the previous one was still completing.
    local recovery = pending.is_song and 2.10
        or (pending.kind == 'weaponskill' and 0.50 or 0.75);
    state.next_action = current_time + recovery;
    return true;
end

local function packet_action(e)
    if (e.id ~= ACTION_PACKET or e.data_raw == nil or (e.size or 0) <= 0) then return nil, nil; end
    local offset, maximum = 40, e.size * 8;
    local function bits(length)
        if (offset + length >= maximum) then return 0; end
        local value = ashita.bits.unpack_be(e.data_raw, 0, offset, length);
        offset = offset + length;
        return value;
    end
    local actor = bits(32);
    local count = bits(6);
    offset = offset + 4;
    local category = bits(4);
    local param;
    if (category == 8 or category == 9) then
        param = bits(16); bits(16);
    else
        param = bits(32);
    end
    bits(32);
    local targets = {};
    for _ = 1, count do
        targets[#targets + 1] = bits(32);
        local actions = bits(4);
        for _ = 1, actions do
            bits(5); bits(12); bits(7); bits(3); bits(17); bits(10); bits(31);
            if (bits(1) == 1) then bits(10); bits(17); bits(10); end
            if (bits(1) == 1) then bits(10); bits(14); bits(10); end
        end
    end
    return actor, category, param, targets;
end

local OUTGOING_CATEGORIES = { spell = 3, ability = 9, weaponskill = 7 };

local function outgoing_action(e)
    if (e.id ~= 0x001A) then return nil; end
    local data = type(e.data) == 'string' and e.data or nil;
    local size = e.size or (data and #data or 0);
    if (data == nil or size < 14) then return nil; end
    local function byte(offset)
        return data:byte(offset + 1);
    end
    local function u16(offset) return byte(offset) + byte(offset + 1) * 0x100; end
    local function u32(offset) return u16(offset) + u16(offset + 2) * 0x10000; end
    return u32(4), u16(10), u16(12);
end

function M.on_packet_out(state, e, current_time)
    local pending = state.pending_action;
    if (pending == nil or pending.sent_at ~= nil) then return false; end
    local ok, target_id, category, param = pcall(outgoing_action, e);
    if (not ok or target_id == nil or category ~= OUTGOING_CATEGORIES[pending.kind]
        or param ~= pending.packet_id) then return false; end
    if (pending.target_server_id ~= 0 and target_id ~= pending.target_server_id) then return false; end
    pending.sent_at = current_time;
    pending.outgoing_target_server_id = target_id;
    pending.timeout_at = current_time + pending.delay + 2.0;
    if (state.combat_trace ~= nil) then
        state.combat_trace(current_time, 'action_outgoing_matched', ('token=%d packet_id=%s target_server_id=%s'):fmt(
            pending.token, tostring(param), tostring(target_id)));
    end
    return true;
end

function M.matches_result(pending, actor, player_id, category, param, targets)
    if (pending == nil or pending.sent_at == nil or actor ~= player_id
        or not result_category_matches(pending, category) or param ~= pending.packet_id) then return false; end
    if (pending.target_server_id == 0) then return true; end
    for _, target_id in ipairs(targets or {}) do
        if (target_id == pending.target_server_id) then return true; end
    end
    return false;
end

function M.on_packet(state, e, current_time)
    local actor, category, param, targets = packet_action(e);
    if actor ~= nil then track_incoming_heal(state, actor, category, param, targets, current_time); end
    local party = AshitaCore:GetMemoryManager():GetParty();
    local player_id = party and (party:GetMemberServerId(0) or 0) or 0;
    if (actor == player_id and category == 1) then
        for _, target_id in ipairs(targets or {}) do
            state.combat_melee_target_server_id = target_id;
            state.combat_melee_confirmed_at = current_time;
        end
    end
    local pending = state.pending_action;
    if (pending == nil) then return false; end
    local target_matches = pending.target_server_id == 0;
    for _, target_id in ipairs(targets or {}) do
        if (target_id == pending.target_server_id) then target_matches = true; break; end
    end
    if (not M.matches_result(pending, actor, player_id, category, param, targets)) then
        if (state.combat_trace ~= nil and actor == player_id) then
            state.combat_trace(current_time, 'action_packet_rejected', ('pending_token=%d sent=%s actor=%s category=%s expected_category=%s param=%s expected_param=%s target_match=%s'):fmt(
                pending.token, tostring(pending.sent_at ~= nil), tostring(actor), tostring(category),
                tostring(pending.is_step and '6|14' or RESULT_CATEGORIES[pending.kind]), tostring(param), tostring(pending.packet_id),
                tostring(target_matches)));
        end
        return false;
    end
    if (state.combat_trace ~= nil) then
        state.combat_trace(current_time, 'action_packet_matched_exact', ('pending_token=%d actor=%s category=%s param=%s target_server_id=%s'):fmt(
            pending.token, tostring(actor), tostring(category), tostring(param), tostring(pending.target_server_id)));
    end
    return finish(state, 'completed', current_time, 'action_packet');
end

function M.cancel(state, current_time, reason)
    return finish(state, 'failed', current_time, reason or 'failure_message');
end

function M.poll(state, current_time)
    local pending = state.pending_action;
    if (pending ~= nil and current_time >= pending.timeout_at) then
        return finish(state, 'timed_out', current_time, 'completion_packet_timeout');
    end
    return false;
end

function M.consume_outcome(state, token)
    if (type(token) ~= 'number' or state.action_outcomes == nil) then return nil; end
    local outcome = state.action_outcomes[token];
    if (outcome == nil) then return nil; end
    state.action_outcomes[token] = nil;
    return outcome;
end

return M;
