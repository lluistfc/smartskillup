local M = {};

local TERPANDER_SONG = 'Victory March';
local TERPANDER_DUMMY_SONG = "Army's Paeon";
local TROUBADOUR_BUFF_ID = 348;
local DEFAULT_THIRD_SONGS = { 'Blade Madrigal', 'Mage\'s Ballad III', 'Sentinel\'s Scherzo' };

function M.choose_third_song(available, target_name, apururu_mp, shantotto_mp)
    target_name = (target_name or ''):lower();
    local ballad_needed = target_name == 'bozzetto jody'
        and ((apururu_mp ~= nil and apururu_mp <= 55)
            or (shantotto_mp ~= nil and shantotto_mp <= 35));
    if (ballad_needed and available["mage's ballad iii"] ~= nil) then
        local reason = apururu_mp ~= nil and apururu_mp <= 55
            and string.format('Apururu MP %d%%', apururu_mp)
            or string.format('Shantotto II MP %d%%', shantotto_mp or 0);
        return "Mage's Ballad III", reason;
    end
    for _, candidate in ipairs(DEFAULT_THIRD_SONGS) do
        if (available[candidate:lower()] ~= nil) then
            return candidate, target_name == 'bozzetto jody'
                and string.format('Jody offense; caster MP stable (Apururu %s, Shantotto %s)',
                    apururu_mp == nil and 'n/a' or (apururu_mp .. '%'),
                    shantotto_mp == nil and 'n/a' or (shantotto_mp .. '%'))
                or 'physical damage phase';
        end
    end
    return nil, 'no supported third song learned';
end

function M.repair_plan(setup, cursor, failed_action)
    if (failed_action == nil or not failed_action.is_song) then return nil; end
    local failed_name = (failed_action.name or ''):lower();
    local following = setup[cursor + 1];
    if (failed_name == TERPANDER_DUMMY_SONG:lower() and following ~= nil) then
        return { failed_action, following };
    end
    if (cursor == #setup) then return { failed_action }; end
    local result = {};
    for _, action in ipairs(setup) do result[#result + 1] = action; end
    return result;
end

function M.can_spend_tp(current_tp, ws_threshold, action_cost, reserve)
    local cost = action_cost or 0;
    local floor = reserve or 0;
    if (cost <= 0) then return true; end
    if (current_tp < cost) then return false; end
    if (current_tp >= ws_threshold) then return current_tp - cost >= ws_threshold; end
    return current_tp - cost >= floor;
end

function M.current_song_deadline(estimates, expected_names)
    local expected, earliest = {}, nil;
    for _, name in ipairs(expected_names or {}) do expected[(name or ''):lower()] = true; end
    for key, song in pairs(estimates or {}) do
        if expected[key] and song.expires_at ~= nil
            and (earliest == nil or song.expires_at < earliest) then
            earliest = song.expires_at;
        end
    end
    return earliest;
end

function M.new(ctx)
    local state = ctx.state;
    local trace = ctx.trace_event or function() end;

    local function trust_mp_percent(expected_name)
        local party = AshitaCore:GetMemoryManager():GetParty();
        if (party == nil) then return nil; end
        for index = 1, 5 do
            if (party:GetMemberIsActive(index) == 1) then
                local name = party:GetMemberName(index) or '';
                if (name:lower() == expected_name:lower()) then
                    return party:GetMemberMPPercent(index) or 0;
                end
            end
        end
        return nil;
    end

    local function choose_third_song(by_name)
        local apururu_mp = trust_mp_percent('Apururu');
        local shantotto_mp = trust_mp_percent('Shantotto II');
        return M.choose_third_song(by_name, state.combat_encounter_target_name,
            apururu_mp, shantotto_mp);
    end

    local function contains_action(actions, expected_name)
        for _, action in ipairs(actions) do
            if ((action.name or ''):lower() == expected_name:lower()) then return true; end
        end
        return false;
    end

    local function setup_actions()
        local regular, dummy, additional = {}, {}, {};
        for _, action in ipairs(ctx.role_actions('setup_buff')) do
            local name = (action.name or ''):lower();
            if (state.settings.ambuscade.terpander_three_song[1] and action.is_song) then
                -- The enabled Terpander policy owns the complete song list so
                -- unrelated selected songs cannot consume or overwrite slot 3.
            elseif (name == TERPANDER_SONG:lower()) then
                table.insert(additional, action);
            elseif (name == TERPANDER_DUMMY_SONG:lower()) then
                table.insert(dummy, action);
            else
                table.insert(regular, action);
            end
        end
        if (state.settings.ambuscade.terpander_three_song[1]) then
            local by_name = {};
            for _, action in ipairs(state.action_catalog.spells or {}) do
                by_name[(action.name or ''):lower()] = action;
            end
            local third_song, third_reason = choose_third_song(by_name);
            state.combat_selected_third_song = third_song;
            state.combat_selected_third_reason = third_reason;
            local rotation = state.combat_song_slots_established
                and { 'Advancing March', 'Valor Minuet V', third_song }
                or { 'Advancing March', 'Valor Minuet V', TERPANDER_DUMMY_SONG, third_song };
            for _, name in ipairs(rotation) do
                local action = name and by_name[name:lower()] or nil;
                if (action ~= nil) then table.insert(regular, action); end
            end
            return regular;
        end
        for _, action in ipairs(dummy) do table.insert(regular, action); end
        for _, action in ipairs(additional) do table.insert(regular, action); end
        return regular;
    end

    local function refresh_interval()
        local duration = state.settings.ambuscade.song_duration[1];
        local margin = state.settings.ambuscade.song_refresh_margin[1];
        return math.max(30.0, duration - margin);
    end

    local function party_value(getter)
        local party = AshitaCore:GetMemoryManager():GetParty();
        return party ~= nil and (getter(party) or 0) or 0;
    end

    local function has_incoming_heal(server_id, current_time)
        if server_id == nil or server_id == 0 then return false, nil; end
        local found, spell_name = false, nil;
        for key, heal in pairs(state.combat_incoming_heals or {}) do
            if current_time >= (heal.expires_at or 0) then
                state.combat_incoming_heals[key] = nil;
            elseif heal.target_server_id == server_id then
                found, spell_name = true, heal.spell_name;
            end
        end
        return found, spell_name;
    end

    local function lowest_party_hp(current_time)
        local party = AshitaCore:GetMemoryManager():GetParty();
        if (party == nil) then return 100, '<me>', 'player'; end
        local lowest_hp, lowest_target, lowest_name = 101, nil, nil;
        for index = 0, 5 do
            if (party:GetMemberIsActive(index) == 1) then
                local hp = party:GetMemberHPPercent(index) or 100;
                local server_id = party:GetMemberServerId(index) or 0;
                local incoming, spell_name = has_incoming_heal(server_id, current_time);
                if (hp > 0 and hp < lowest_hp and not incoming) then
                    lowest_hp = hp;
                    lowest_target = index == 0 and '<me>' or ('<p%d>'):fmt(index);
                    lowest_name = party:GetMemberName(index) or ('party member %d'):fmt(index);
                elseif (hp > 0 and incoming and hp <= state.settings.ambuscade.heal_below[1]) then
                    trace('emergency_heal_deferred', ('target=%q hp=%d incoming=%q server_id=%s'):fmt(
                        party:GetMemberName(index) or ('party member %d'):fmt(index), hp,
                        tostring(spell_name), tostring(server_id)));
                end
            end
        end
        if lowest_target == nil then return 100, '<me>', 'player'; end
        return lowest_hp, lowest_target, lowest_name;
    end

    local function player_tp()
        return party_value(function(party) return party:GetMemberTP(0); end);
    end

    local function active_song_count()
        local player = AshitaCore:GetMemoryManager():GetPlayer();
        local buffs = player and (player:GetBuffs() or {}) or {};
        local count = 0;
        for _, buff_id in pairs(buffs) do
            if (type(buff_id) == 'number' and buff_id >= 195 and buff_id <= 222) then count = count + 1; end
        end
        return count;
    end

    local function has_player_buff(expected_id)
        local player = AshitaCore:GetMemoryManager():GetPlayer();
        local buffs = player and (player:GetBuffs() or {}) or {};
        for _, buff_id in pairs(buffs) do
            if (buff_id == expected_id) then return true; end
        end
        return false;
    end

    local function finishing_moves()
        local player = AshitaCore:GetMemoryManager():GetPlayer();
        local buffs = player and (player:GetBuffs() or {}) or {};
        local counts = { [381] = 1, [382] = 2, [383] = 3, [384] = 4, [385] = 5, [588] = 6 };
        for _, buff_id in pairs(buffs) do
            if (counts[buff_id] ~= nil) then return counts[buff_id]; end
        end
        return 0;
    end

    local function is_step(action)
        return (action.name or ''):lower():find(' step', 1, true) ~= nil;
    end

    local function trust_tp(expected_name)
        local party = AshitaCore:GetMemoryManager():GetParty();
        if (party == nil) then return nil; end
        for index = 1, 5 do
            if (party:GetMemberIsActive(index) == 1) then
                local name = party:GetMemberName(index) or '';
                if (name:lower() == expected_name:lower()) then return party:GetMemberTP(index) or 0; end
            end
        end
        return nil;
    end

    local function trusts_ready_for_weapon_skill()
        local shantotto = trust_tp('Shantotto II');
        local qultada = trust_tp('Qultada');
        return (shantotto == nil or shantotto >= state.settings.ambuscade.shantotto_sync_tp[1])
            and (qultada == nil or qultada < 1000);
    end

    local function ready_role_action(role, effect)
        for _, action in ipairs(ctx.role_actions(role, effect)) do
            if (ctx.action_ready(action)) then return action; end
        end
        return nil;
    end

    local function reset()
        state.combat_song_slots_established = false;
        state.combat_confirmed_songs = {};
        state.combat_debuff_until = {};
        state.combat_step_state = {};
        state.combat_setup_pending_token = nil;
        state.combat_setup_pending_action = nil;
        state.combat_setup_attempts = {};
        state.combat_setup_degraded = false;
        state.combat_setup_cycle = nil;
        state.combat_setup_generation = 0;
        state.combat_song_repair_actions = nil;
        state.combat_song_repair_at = 0;
        state.combat_song_repair_third_song = nil;
        state.combat_encounter_target_name = '';
        state.combat_selected_third_song = nil;
        state.combat_selected_third_reason = '';
        state.combat_opening_troubadour_seen = false;
        state.combat_song_loss_seen_at = 0;
        state.combat_song_estimates = {};
        state.combat_target_key = nil;
        state.combat_pending_debuff = nil;
        state.combat_incoming_heals = {};
        state.ambuscade_phase = 'setup';
        state.ambuscade_cursor = 1;
        state.ambuscade_samba_at = 0;
        state.ambuscade_step_at = 0;
        state.ambuscade_song_at = 0;
        state.ambuscade_finale_at = 0;
        state.ambuscade_ws_wait_started = 0;
        state.ambuscade_reverse_at = 0;
        state.ambuscade_waltz_at = 0;
    end

    local function use_action(options, action, target, status, delay)
        options.queue_action(action.name, ctx.action_catalog.command(action, target));
        state.last_spell = action.name;
        state.status = (options.status_prefix or '') .. (status or action.name);
        return ctx.schedule_action(action, delay, target);
    end

    local function tick(options)
        local current_time = ctx.now();
        local allow_setup = options.allow_setup ~= false;
        if (options.target_name or '') ~= '' then
            state.combat_encounter_target_name = options.target_name;
        end
        if (state.combat_pending_debuff ~= nil) then
            local pending = state.combat_pending_debuff;
            local outcome = ctx.action_outcome(pending.token);
            if (outcome ~= nil) then
                if (outcome.status == 'completed') then
                    if (pending.is_step) then
                        local step = state.combat_step_state[pending.debuff_key] or { level = 0, expires = 0 };
                        step.level = math.min(5, step.level + 1);
                        step.estimated_level = step.level;
                        step.confidence = step.confirmed_level and 'battle_text' or 'matched_action_packet';
                        step.expires = step.level == 1 and (current_time + 60)
                            or math.min(current_time + 120, math.max(current_time, step.expires) + 30);
                        state.combat_step_state[pending.debuff_key] = step;
                        trace('step_estimate_advanced', ('key=%q estimated_level=%d expires=%.3f token=%s confidence=category_packet_only'):fmt(
                            pending.debuff_key, step.level, step.expires, tostring(outcome.token)));
                        state.combat_debuff_until[pending.debuff_key] = current_time
                            + (step.level < 5 and 6 or 75);
                    else
                        state.combat_debuff_until[pending.debuff_key] = current_time
                            + (pending.duration or state.settings.ambuscade.combat_debuff_duration[1]);
                    end
                else
                    local retry_delay = pending.is_step and 5.5 or 10.0;
                    state.combat_debuff_until[pending.debuff_key] = current_time + retry_delay;
                    trace('combat_debuff_backoff', ('key=%q status=%s retry_at=%.3f'):fmt(
                        pending.debuff_key, outcome.status, state.combat_debuff_until[pending.debuff_key]));
                end
                state.combat_pending_debuff = nil;
            end
        end
        if (allow_setup and state.ambuscade_phase == 'combat'
            and state.combat_song_slots_established and active_song_count() < 3) then
            if (state.combat_song_loss_seen_at or 0) == 0 then
                state.combat_song_loss_seen_at = current_time;
            elseif (current_time - state.combat_song_loss_seen_at) >= 2.0 then
                -- Song icons do not identify which March was lost. Defer a
                -- controlled repair instead of immediately blocking combat
                -- with a complete four-cast Terpander rebuild.
                state.combat_song_loss_seen_at = 0;
                trace('song_slot_warning', ('active_count=%d action=none confidence=generic_buff_count timers_authoritative=true'):fmt(
                    active_song_count()));
            end
        else
            state.combat_song_loss_seen_at = 0;
        end
        local heal = ready_role_action('heal');
        local lowest_hp, heal_target, heal_name = lowest_party_hp(current_time);
        if (heal and lowest_hp <= state.settings.ambuscade.heal_below[1]
            and current_time >= state.ambuscade_waltz_at) then
            use_action(options, heal, heal_target,
                ('Emergency heal: %s (%d%%)'):fmt(heal_name, lowest_hp), 3.0);
            state.ambuscade_waltz_at = current_time + 8.0;
            return true;
        end

        local setup = setup_actions();
        if (allow_setup and state.ambuscade_phase == 'setup') then
            if (state.combat_setup_cycle == nil) then
                local repair_due = state.combat_song_repair_actions ~= nil
                    and current_time >= (state.combat_song_repair_at or 0);
                if (repair_due) then setup = state.combat_song_repair_actions; end
                state.combat_setup_generation = (state.combat_setup_generation or 0) + 1;
                state.combat_setup_cycle = {
                    actions = setup,
                    generation = state.combat_setup_generation,
                    started_at = current_time,
                    kind = repair_due and 'repair'
                        or (state.combat_song_slots_established and 'refresh' or 'rebuild'),
                    third_song = repair_due and state.combat_song_repair_third_song
                        or state.combat_selected_third_song,
                    third_reason = state.combat_selected_third_reason,
                };
                trace('setup_cycle_started', ('generation=%d kind=%s action_count=%d'):fmt(
                    state.combat_setup_cycle.generation, state.combat_setup_cycle.kind, #setup));
                trace('song_strategy_selected', ('third_song=%q reason=%q encounter_target=%q'):fmt(
                    tostring(state.combat_setup_cycle.third_song),
                    tostring(state.combat_setup_cycle.third_reason),
                    tostring(state.combat_encounter_target_name)));
            end
            -- A cycle is immutable. Buff icons and settings may change while a
            -- song is casting, but they must not rewrite the remaining actions.
            setup = state.combat_setup_cycle.actions;
            local action = setup[state.ambuscade_cursor];
            if (action) then
                if (state.combat_setup_pending_token ~= nil) then
                    local pending_action = state.combat_setup_pending_action or action;
                    local outcome = ctx.action_outcome(state.combat_setup_pending_token);
                    if (outcome == nil) then
                        state.next_action = current_time + 0.1;
                        return true;
                    end
                    state.combat_setup_pending_token = nil;
                    state.combat_setup_pending_action = nil;
                    if (outcome.status == 'completed') then
                        state.combat_setup_attempts[pending_action.key] = nil;
                        if (pending_action.is_song) then
                            state.combat_confirmed_songs[(pending_action.name or ''):lower()] = true;
                            local troubadour = has_player_buff(TROUBADOUR_BUFF_ID);
                            local duration = refresh_interval() * (troubadour and 2 or 1);
                            state.combat_song_estimates[(pending_action.name or ''):lower()] = {
                                name = pending_action.name,
                                cast_at = current_time,
                                expires_at = current_time + duration,
                                troubadour = troubadour,
                                confidence = 'matched_action_packet',
                            };
                            trace('song_cast_estimated', ('name=%q token=%s troubadour_buff=%s confidence=category_packet_only'):fmt(
                                pending_action.name, tostring(outcome.token),
                                tostring(troubadour)));
                        end
                        state.ambuscade_cursor = state.ambuscade_cursor + 1;
                        action = setup[state.ambuscade_cursor];
                        if (action == nil) then
                            state.next_action = current_time;
                            return true;
                        end
                    else
                        local attempts = (state.combat_setup_attempts[pending_action.key] or 0) + 1;
                        state.combat_setup_attempts[pending_action.key] = attempts;
                        if (attempts < 2) then
                            state.status = (options.status_prefix or '') .. ('Retrying %s after %s'):fmt(
                                pending_action.name, outcome.status);
                            state.next_action = current_time + 1.0;
                            return true;
                        end
                        state.combat_setup_degraded = true;
                        trace('setup_action_degraded', ('name=%q key=%s status=%s attempts=%d'):fmt(
                            pending_action.name, tostring(pending_action.key), outcome.status, attempts));
                        state.status = (options.status_prefix or '') .. ('Degraded setup: skipping %s'):fmt(
                            pending_action.name);
                        if (state.combat_setup_cycle.kind == 'rebuild') then
                            -- Keep successful NiTro songs intact when possible.
                            -- In particular, a failed dummy repairs as Paeon plus
                            -- the final real song instead of replaying March/Minuet.
                            state.combat_song_repair_actions = M.repair_plan(
                                setup, state.ambuscade_cursor, pending_action);
                            if (state.combat_song_repair_actions ~= nil) then
                                state.combat_song_repair_third_song = state.combat_setup_cycle.third_song;
                                state.combat_song_repair_at = current_time + 5.0;
                                state.ambuscade_cursor = #setup + 1;
                                trace('setup_repair_deferred', ('failed=%q repair_count=%d repair_at=%.3f reason=control_vivian_first'):fmt(
                                    pending_action.name, #state.combat_song_repair_actions,
                                    state.combat_song_repair_at));
                                state.next_action = current_time;
                                return true;
                            end
                        end
                        state.ambuscade_cursor = state.ambuscade_cursor + 1;
                        action = setup[state.ambuscade_cursor];
                        if (action == nil) then state.next_action = current_time; return true; end
                    end
                end
                state.combat_setup_pending_token = use_action(
                    options, action, '<me>', ('Setup buff %d/%d'):fmt(state.ambuscade_cursor, #setup));
                state.combat_setup_pending_action = action;
                if (action.is_song and has_player_buff(TROUBADOUR_BUFF_ID)) then
                    state.combat_opening_troubadour_seen = true;
                end
                return true;
            end
            local interval = refresh_interval();
            local expected_real_songs = {};
            for _, song in ipairs(setup) do
                if song.is_song and song.name ~= TERPANDER_DUMMY_SONG then
                    expected_real_songs[#expected_real_songs + 1] = song.name;
                end
            end
            local earliest_expiry = M.current_song_deadline(
                state.combat_song_estimates, expected_real_songs);
            if state.combat_setup_cycle.kind ~= 'repair' then
                local retained = {};
                for _, name in ipairs(expected_real_songs) do
                    local key = name:lower();
                    if state.combat_song_estimates[key] ~= nil then
                        retained[key] = state.combat_song_estimates[key];
                    end
                end
                state.combat_song_estimates = retained;
            end
            state.combat_opening_troubadour_seen = false;
            if (state.combat_setup_cycle.kind ~= 'repair') then
                -- Degradation no longer causes a destructive full rebuild after
                -- 15 seconds. Preserve the estimated NiTro expiry; any missing
                -- Terpander slot is handled by the targeted repair plan.
                state.ambuscade_song_at = earliest_expiry or (current_time + interval);
            end
            trace('setup_cycle_complete', ('degraded=%s troubadour_doubled=%s next_song_at=%.3f confirmed_song_count=%d'):fmt(
                tostring(state.combat_setup_degraded), tostring(earliest_expiry ~= nil
                    and earliest_expiry > current_time + refresh_interval()),
                state.ambuscade_song_at, active_song_count()));
            if (state.settings.ambuscade.terpander_three_song[1]) then
                local complete = true;
                local expected = {};
                for _, action in ipairs(setup) do expected[#expected + 1] = action.name; end
                if (#expected ~= 4 and not state.combat_song_slots_established) then complete = false; end
                for _, name in ipairs(expected) do
                    if (not contains_action(setup, name)
                        or not state.combat_confirmed_songs[name:lower()]) then complete = false; break; end
                end
                if (state.combat_setup_cycle.kind == 'repair') then
                    local third_name = state.combat_setup_cycle.third_song;
                    complete = not state.combat_setup_degraded
                        and state.combat_confirmed_songs['advancing march']
                        and state.combat_confirmed_songs['valor minuet v']
                        and third_name ~= nil
                        and state.combat_confirmed_songs[third_name:lower()];
                end
                state.combat_song_slots_established = complete and not state.combat_setup_degraded;
            end
            if (state.combat_setup_cycle.kind == 'repair') then
                trace('setup_repair_complete', ('established=%s degraded=%s'):fmt(
                    tostring(state.combat_song_slots_established), tostring(state.combat_setup_degraded)));
                state.combat_song_repair_actions = nil;
                state.combat_song_repair_at = 0;
                state.combat_song_repair_third_song = nil;
            end
            state.ambuscade_phase = 'combat';
            state.combat_setup_cycle = nil;
        end

        if (not options.has_target) then return false; end

        local target_key = options.target_key;
        if (target_key ~= nil and target_key ~= '' and target_key ~= state.combat_target_key) then
            state.combat_target_key = target_key;
            state.ambuscade_ws_wait_started = 0;
        end

        local tp, threshold = player_tp(), state.settings.ambuscade.weapon_skill_tp[1];
        local function can_spend_tp(action)
            -- Preserve enough TP for an emergency Waltz while below the WS
            -- threshold, and never queue an action whose TP cost cannot be met.
            return M.can_spend_tp(tp, threshold, action.tp_cost, 350);
        end

        local dispel = ready_role_action('dispel');
        if (dispel and options.target_has_enhancements
            and current_time >= state.ambuscade_finale_at) then
            use_action(options, dispel, '<t>', 'Dispelling ' .. (options.target_name or 'target'), 3.0);
            state.ambuscade_finale_at = current_time + 15.0;
            return true;
        end

        local repair_due = state.combat_song_repair_actions ~= nil
            and current_time >= (state.combat_song_repair_at or 0);
        if (allow_setup and #setup > 0
            and (repair_due or current_time >= state.ambuscade_song_at)) then
            state.ambuscade_phase = 'setup';
            state.ambuscade_cursor = 1;
            state.combat_setup_cycle = nil;
            state.combat_setup_degraded = false;
            state.combat_setup_attempts = {};
            state.next_action = current_time;
            state.status = (options.status_prefix or '')
                .. (repair_due and 'Repairing missing song slot' or 'Refreshing setup buffs');
            return true;
        end

        local ws = ready_role_action('weapon_skill');
        if (ws and tp >= threshold) then
            if (state.ambuscade_ws_wait_started == 0) then state.ambuscade_ws_wait_started = current_time; end
            local waited = current_time - state.ambuscade_ws_wait_started;
            if (trusts_ready_for_weapon_skill()
                or waited >= state.settings.ambuscade.ws_sync_wait[1]) then
                use_action(options, ws, '<t>', ('Weaponskill: %s (%d TP)'):fmt(ws.name, tp));
                state.ambuscade_ws_wait_started = 0;
                return true;
            end
            state.status = (options.status_prefix or '') .. ('Holding WS for trusts (%.1f/%.1fs)'):fmt(
                waited, state.settings.ambuscade.ws_sync_wait[1]);
            state.next_action = current_time + 0.25;
            return true;
        end
        state.ambuscade_ws_wait_started = 0;

        local buff;
        for _, action in ipairs(ctx.role_actions('combat_buff')) do
            if ((action.name or ''):lower() == 'haste samba' and can_spend_tp(action)
                and ctx.action_ready(action)) then buff = action; break; end
        end
        if (buff and current_time >= state.ambuscade_samba_at) then
            use_action(options, buff, '<me>', 'Refreshing combat buff');
            state.ambuscade_samba_at = current_time + 80.0;
            return true;
        end

        local debuff, debuff_key, debuff_until;
        local debuff_actions, step_actions, seen_steps = {}, {}, {};
        for _, action in ipairs(ctx.role_actions('combat_debuff')) do
            if (is_step(action)) then
                step_actions[#step_actions + 1] = action;
                seen_steps[action.key] = true;
            else
                debuff_actions[#debuff_actions + 1] = action;
            end
        end
        for _, action in ipairs(ctx.role_actions('combat_buff')) do
            if (is_step(action) and not seen_steps[action.key]) then step_actions[#step_actions + 1] = action; end
        end
        table.sort(step_actions, function(first, second)
            local first_box = (first.name or ''):lower() == 'box step';
            local second_box = (second.name or ''):lower() == 'box step';
            if (first_box ~= second_box) then return first_box; end
            return (first.name or ''):lower() < (second.name or ''):lower();
        end);
        if (#step_actions > 0) then
            debuff_actions[#debuff_actions + 1] = step_actions[1];
        end
        for _, action in ipairs(debuff_actions) do
            local key = ('%s|%s'):fmt(
                tostring(options.target_key or options.target_name or 'target'), action.key);
            local expires = state.combat_debuff_until[key] or 0;
            if (current_time >= expires and can_spend_tp(action) and ctx.action_ready(action)) then
                debuff, debuff_key, debuff_until = action, key, expires;
                break;
            end
        end
        if (debuff and current_time >= debuff_until) then
            local token = use_action(options, debuff, '<t>', 'Applying combat debuff');
            state.combat_pending_debuff = {
                token = token,
                debuff_key = debuff_key,
                is_step = is_step(debuff),
                duration = state.settings.ambuscade.combat_debuff_duration[1],
            };
            return true;
        end

        local recovery = ready_role_action('tp_recovery');
        if (recovery and (recovery.name or ''):lower() == 'reverse flourish'
            and finishing_moves() < 5) then recovery = nil; end
        if (recovery and tp <= threshold - 500 and current_time >= state.ambuscade_reverse_at) then
            use_action(options, recovery, '<me>', 'Recovering TP');
            state.ambuscade_reverse_at = current_time + 10.0;
            return true;
        end

        return false;
    end

    return {
        reset = reset,
        tick = tick,
        setup_actions = setup_actions,
        player_tp = player_tp,
        shantotto_tp = function() return trust_tp('Shantotto II'); end,
        qultada_tp = function() return trust_tp('Qultada'); end,
        ready_role_action = ready_role_action,
        terpander_rotation_ready = function()
            local found = {};
            for _, action in ipairs(state.action_catalog.spells or {}) do found[(action.name or ''):lower()] = true; end
            for _, name in ipairs({ 'Advancing March', 'Valor Minuet V', TERPANDER_DUMMY_SONG }) do
                if (not found[name:lower()]) then return false, name; end
            end
            local third;
            for _, name in ipairs(DEFAULT_THIRD_SONGS) do
                if (found[name:lower()]) then third = name; break; end
            end
            if (third == nil) then return false, table.concat(DEFAULT_THIRD_SONGS, ' / '); end
            return true, nil;
        end,
    };
end

return M;
