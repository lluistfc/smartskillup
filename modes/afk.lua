local M = {}
local nav = require 'nav_runtime'
local nav_logic = require 'nav_logic'
local combat_rotation = require 'combat_rotation'
local packet_decoder = require 'packet_decoder'
local HOSTILE_FLAG, MEMORY_SECONDS, RETRY_SECONDS = 0x10, 10, 3
local ENGAGE_GRACE_SECONDS, RECOVERY_CAST_WAIT, STUCK_SECONDS = 1.5, 3.0, 2.0
local SPELL_READY_GRACE, APPROACH_RETRY_SECONDS, MAX_APPROACH_ATTEMPTS = 3.0, 2.0, 3
local FACING_PULSE_SECONDS = 0.35
local MELEE_CONFIRMATION_GRACE = 1.5
local WAYPOINT_REACHED_DISTANCE = 1.5
local CLAIM_GRACE_SECONDS = 5.0
local APPROACH_HYSTERESIS, STALE_ENGAGEMENT_GRACE = 0.50, 2.0
local LOCKON_TRACE_INTERVAL = 5.0
local ATTACKER_MEMORY_SECONDS, TARGET_SWITCH_COOLDOWN = 8.0, 1.5
local TARGET_SWITCH_MARGIN, FAILED_TARGET_COOLDOWN = 1.0, 12.0
local CONFIRMED_TARGET_SWITCH_MARGIN, ACTIVE_THREAT_SECONDS = 2.0, 4.0
local NAV_REPLAN_DISTANCE, NAV_REPLAN_SECONDS = 4.0, 3.0
local NAV_DETOUR_DISTANCE, MAX_NAV_DETOURS = 3.0, 2
local PULL_SEARCH_RETRY_SECONDS = 1.0
local ZONE_PACKET, LOGOUT_PACKET, ACTION_PACKET = 0x000A, 0x000B, 0x0028

function M.new(ctx)
    local state = ctx.state
    state.afk = state.afk or {
        aggressor_index = 0,
        seen_at = 0,
        next_attack_at = 0,
        last_target = 'None',
        lockon_issued = false,
        attack_issued = false,
        following = false,
    }
    local afk = state.afk
    local combat = combat_rotation.new(ctx)
    afk.lockon_issued = afk.lockon_issued or false
    afk.attack_issued = afk.attack_issued or false
    afk.nearby_mobs = afk.nearby_mobs or {}
    afk.attackers = afk.attackers or {}
    afk.failed_targets = afk.failed_targets or {}
    afk.packet_log_path = afk.packet_log_path or ''
    afk.pull_search_name = afk.pull_search_name or ''
    afk.pull_primary_name = afk.pull_primary_name or ''
    afk.pull_search_misses = afk.pull_search_misses or 0
    afk.pull_search_position = afk.pull_search_position or 1
    afk.next_pull_search_at = afk.next_pull_search_at or 0
    local packet_log_file = nil
    local function close_packet_log()
        if packet_log_file then
            packet_log_file:flush()
            packet_log_file:close()
            packet_log_file = nil
        end
    end
    local function open_packet_log()
        if packet_log_file then
            return packet_log_file
        end
        local root = ('%s\\config\\addons\\smartskillup\\'):fmt(AshitaCore:GetInstallPath())
        local directory = root .. 'logs\\'
        if not ashita.fs.exists(root) then ashita.fs.create_dir(root) end
        if not ashita.fs.exists(directory) then ashita.fs.create_dir(directory) end
        afk.packet_log_path = directory .. os.date('packets_%Y%m%d_%H%M%S.log')
        packet_log_file = io.open(afk.packet_log_path, 'a+')
        if packet_log_file then
            packet_log_file:write(('# SmartSkillup combat packet log started %s\n'):fmt(os.date('%Y-%m-%d %H:%M:%S')))
            local recovery = state.settings.afk_recovery
            packet_log_file:write(('# recovery enabled=%s stop_distance=%s max_time=%s adopt_party_claims=%s claim_range=%s\n'):fmt(
                tostring(recovery.enabled[1]), tostring(recovery.stop_distance[1]), tostring(recovery.max_time[1]),
                tostring(recovery.adopt_party_claims[1]), tostring(recovery.party_claim_range[1])))
            packet_log_file:flush()
        else
            afk.packet_log_path = ''
        end
        return packet_log_file
    end
    local function fighting()
        return ctx.player_engaged() or (afk.aggressor_index or 0) > 0
    end
    local function record_packet(direction, e, force)
        if not state.settings.afk_packet_log.enabled[1] or (not force and not fighting()) then
            return false
        end
        -- Position/entity update packets arrive many times per second and the
        -- AFK state events already summarize the useful result. Keep only
        -- action and session-boundary packets in the human-readable log.
        if e.id ~= ACTION_PACKET and e.id ~= 0x001A
            and e.id ~= ZONE_PACKET and e.id ~= LOGOUT_PACKET then
            return false
        end
        local file = open_packet_log()
        if not file then
            return false
        end
        file:write(('[%s] direction=%s %s blocked=%s injected=%s modified=%s\n'):fmt(
            os.date('%Y-%m-%d %H:%M:%S'), direction, packet_decoder.describe(direction, e),
            tostring(e.blocked), tostring(e.injected), tostring(e.modified)))
        file:flush()
        return true
    end
    local function trace_event(label, details)
        if not state.settings.afk_packet_log.enabled[1] then
            return
        end
        local file = open_packet_log()
        if not file then
            return
        end
        file:write(('[%s] state=%s%s\n'):fmt(os.date('%Y-%m-%d %H:%M:%S'), label,
            details and (' ' .. details) or ''))
        file:flush()
    end
    local function sync_packet_log()
        if not state.settings.afk_packet_log.enabled[1] then close_packet_log() end
    end
    local function packet_log_path()
        return afk.packet_log_path or ''
    end
    local function camera_is_locked_on()
        local manager = AshitaCore:GetMemoryManager()
        local follow = manager and manager:GetAutoFollow() or nil
        if not follow then
            return nil
        end
        local ok, locked = pcall(function() return follow:GetIsCameraLockedOn() end)
        if not ok then
            return nil
        end
        return locked == true or locked == 1
    end
    local function ensure_lockon()
        local locked = camera_is_locked_on()
        local current = ctx.now()
        if (locked == false and (not afk.lockon_issued or current >= (afk.next_lockon_at or 0)))
            or (locked == nil and not afk.lockon_issued) then
            ctx.queue '/lockon'
            afk.lockon_issued = true
            afk.next_lockon_at = current + 1.0
            trace_event('lockon_queued', ('previous_state=%s'):fmt(tostring(locked)))
            return
        end
        if locked then
            afk.lockon_issued = true
        end
        if locked ~= afk.last_lock_state or current >= (afk.next_lock_trace_at or 0) then
            trace_event('lockon_preserved', ('state=%s'):fmt(tostring(locked)))
            afk.last_lock_state = locked
            afk.next_lock_trace_at = current + LOCKON_TRACE_INTERVAL
        end
    end
    local function ensure_lockoff(reason)
        local manager = AshitaCore:GetMemoryManager()
        local follow = manager and manager:GetAutoFollow() or nil
        local locked = camera_is_locked_on()
        local current = ctx.now()
        if follow and locked and current >= (afk.next_lockoff_at or 0) then
            local cleared = pcall(function()
                follow:SetIsCameraLockedOn(0)
                follow:SetIsCameraLocked(0)
            end)
            afk.next_lockoff_at = current + 1.0
            afk.lockon_issued = false
            local remaining = camera_is_locked_on()
            if remaining then ctx.queue '/lockoff' end
            trace_event('lockoff_applied', ('reason=%s direct=%s previous_state=%s remaining=%s fallback=%s'):fmt(
                reason or 'navigation', tostring(cleared), tostring(locked), tostring(remaining),
                tostring(remaining == true)))
        end
    end
    local function begin_melee_grace(reason)
        local current = ctx.now()
        if current < (afk.melee_grace_until or 0) then return end
        local until_time = current + MELEE_CONFIRMATION_GRACE
        if until_time > (afk.melee_grace_until or 0) then afk.melee_grace_until = until_time end
        trace_event('melee_grace_started', ('reason=%s until=%.2f'):fmt(
            reason or 'near_target', afk.melee_grace_until))
    end
    local function stop_following(reason)
        local manager = AshitaCore:GetMemoryManager()
        local follow = manager and manager:GetAutoFollow() or nil
        if follow and afk.following then
            trace_event('follow_stop', ('reason=%s autorun_before=%s'):fmt(
                reason or 'unspecified', tostring(follow:GetIsAutoRunning())))
            follow:SetIsAutoRunning(0)
        end
        afk.following = false
        afk.follow_reason = nil
    end
    local function start_following(index, reason)
        local manager = AshitaCore:GetMemoryManager()
        local follow = manager and manager:GetAutoFollow() or nil
        local entities = manager and manager:GetEntity() or nil
        local server_id = entities and (entities:GetServerId(index) or 0) or 0
        if not follow or index <= 0 or server_id <= 0 then
            trace_event('follow_start_failed', ('reason=%s index=%s server_id=%s'):fmt(
                reason or 'unspecified', tostring(index), tostring(server_id)))
            return false
        end
        follow:SetTargetIndex(index)
        follow:SetTargetServerId(server_id)
        follow:SetFollowTargetIndex(index)
        follow:SetFollowTargetServerId(server_id)
        follow:SetIsAutoRunning(1)
        afk.following = true
        afk.follow_reason = reason or 'unspecified'
        trace_event('follow_started', ('reason=%s index=%d server_id=0x%08X autorun=%s'):fmt(
            reason or 'unspecified', index, server_id, tostring(follow:GetIsAutoRunning())))
        return true
    end
    local function reset_recovery()
        stop_following('recovery_reset')
        afk.engage_started_at = 0
        afk.recovery_wait_until = 0
        afk.recovery_spell_attempted = false
        afk.next_recovery_spell_at = 0
        afk.recovery_spell_deadline = 0
        afk.approach_started_at = 0
        afk.last_distance = nil
        afk.last_progress_at = 0
        afk.approach_attempts = 0
        afk.next_approach_at = 0
        afk.facing_until = 0
        afk.facing_pulse_done = false
        afk.nav_path = nil
        afk.nav_cursor = 1
        afk.nav_attempted = false
        afk.nav_target_position = nil
        afk.nav_planned_at = 0
        afk.nav_waypoint_cursor = 0
        afk.last_waypoint_distance = nil
        afk.waypoint_progress_at = 0
        afk.next_nav_replan_at = 0
        afk.nav_detour_attempts = 0
        afk.next_lockoff_at = 0
        afk.melee_grace_until = 0
        afk.ws_wait_started = 0
        afk.melee_confirmed = false
        afk.melee_confirmed_server_id = 0
        afk.melee_pull = false
        afk.failure_recorded = false
        afk.invalid_since = 0
        afk.stale_clear_issued = false
    end
    local function hostile(index)
        if not index or index <= 0 or type(GetEntity) ~= 'function' then
            return false
        end
        local entity = GetEntity(index)
        if not entity then
            return false
        end
        return (entity.HPPercent or entity.HealthPercent or 0) > 0
            and bit.band(entity.SpawnFlags or 0, HOSTILE_FLAG) == HOSTILE_FLAG
    end
    local function party_claimed(index)
        if not hostile(index) then
            return false
        end
        local manager = AshitaCore:GetMemoryManager()
        local entities = manager and manager:GetEntity() or nil
        local party = manager and manager:GetParty() or nil
        if not entities or not party then
            return false
        end
        local claim_id = bit.band(entities:GetClaimStatus(index) or 0, 0xFFFF)
        if claim_id == 0 then
            return false
        end
        for member = 0, 17 do
            if party:GetMemberIsActive(member) == 1 then
                local server_id = party:GetMemberServerId(member) or 0
                if bit.band(server_id, 0xFFFF) == claim_id then
                    return true
                end
            end
        end
        return false
    end
    local function aggressor_is_valid()
        if not hostile(afk.aggressor_index) or not afk.aggressor_server_id
            or afk.aggressor_server_id <= 0 then
            return false
        end
        local entities = AshitaCore:GetMemoryManager():GetEntity()
        if entities == nil or entities:GetServerId(afk.aggressor_index) ~= afk.aggressor_server_id then
            return false
        end
        if not afk.adopted_party_claim then return true end
        if party_claimed(afk.aggressor_index) then
            afk.claim_seen_at = ctx.now()
            return true
        end
        return ctx.now() - (afk.claim_seen_at or 0) <= CLAIM_GRACE_SECONDS
    end
    local function distance_squared(entity)
        local distance = entity and entity.Distance or math.huge
        return type(distance) == 'number' and distance or math.huge
    end
    local function horizontal_distance(index)
        if not hostile(index) then
            return nil
        end
        local manager = AshitaCore:GetMemoryManager()
        local entities = manager and manager:GetEntity() or nil
        local party = manager and manager:GetParty() or nil
        local player_index = party and (party:GetMemberTargetIndex(0) or 0) or 0
        if not entities or player_index <= 0 then
            return nil
        end
        local player_x = entities:GetLocalPositionX(player_index)
        local player_y = entities:GetLocalPositionY(player_index)
        local target_x = entities:GetLocalPositionX(index)
        local target_y = entities:GetLocalPositionY(index)
        if type(player_x) ~= 'number' or type(player_y) ~= 'number'
            or type(target_x) ~= 'number' or type(target_y) ~= 'number' then
            return nil
        end
        local delta_x, delta_y = target_x - player_x, target_y - player_y
        return math.sqrt((delta_x * delta_x) + (delta_y * delta_y))
    end
    local function target_on_cooldown(server_id, current)
        local expires = afk.failed_targets[server_id]
        if not expires then return false end
        if current >= expires then
            afk.failed_targets[server_id] = nil
            return false
        end
        return true
    end
    local function remember_attacker(server_id, index, current)
        local entry = afk.attackers[server_id] or {}
        entry.server_id = server_id
        entry.index = index
        entry.name = (GetEntity(index) and GetEntity(index).Name) or entry.name or 'Unknown'
        entry.last_seen = current
        entry.distance = horizontal_distance(index)
        entry.direct = true
        afk.attackers[server_id] = entry
        if entry.distance and entry.distance <= state.settings.afk_recovery.stop_distance[1] + APPROACH_HYSTERESIS then
            afk.failed_targets[server_id] = nil
        end
        return entry
    end
    local function prune_attackers(current)
        for server_id, entry in pairs(afk.attackers) do
            if current - (entry.last_seen or 0) > ATTACKER_MEMORY_SECONDS
                or not hostile(entry.index)
                or AshitaCore:GetMemoryManager():GetEntity():GetServerId(entry.index) ~= server_id then
                afk.attackers[server_id] = nil
            else
                entry.distance = horizontal_distance(entry.index)
            end
        end
    end
    local function switch_aggressor(entry, reason, current)
        stop_following('target_switch')
        reset_recovery()
        afk.aggressor_index = entry.index
        afk.aggressor_server_id = entry.server_id
        afk.adopted_party_claim = false
        afk.target_source = 'direct'
        afk.seen_at = current
        afk.next_attack_at = current
        afk.last_target = entry.name or 'Unknown'
        afk.lockon_issued = false
        afk.attack_issued = false
        afk.next_target_switch_at = current + TARGET_SWITCH_COOLDOWN
        AshitaCore:GetMemoryManager():GetTarget():SetTarget(entry.index, true)
        state.status = 'AFK: switching to direct attacker ' .. afk.last_target
        trace_event('target_switched', ('reason=%s index=%d server_id=0x%08X name=%s distance=%s'):fmt(
            reason, entry.index, entry.server_id, afk.last_target, tostring(entry.distance)))
    end
    local function consider_attacker(entry, current)
        local current_valid = aggressor_is_valid()
        local current_distance = current_valid and horizontal_distance(afk.aggressor_index) or nil
        local reason, keep_reason
        local candidate_age = current - (entry.last_seen or 0)
        local current_confirmed = afk.melee_confirmed_server_id == afk.aggressor_server_id
        local switch_margin = current_confirmed and CONFIRMED_TARGET_SWITCH_MARGIN or TARGET_SWITCH_MARGIN
        local near_distance = state.settings.afk_recovery.stop_distance[1] + APPROACH_HYSTERESIS
        if entry.server_id == afk.aggressor_server_id then
            afk.seen_at = current
            return false
        elseif candidate_age > ACTIVE_THREAT_SECONDS then
            keep_reason = 'candidate_attack_is_stale'
        elseif not current_valid then
            reason = 'no_valid_current_target'
        elseif target_on_cooldown(afk.aggressor_server_id, current) then
            reason = 'current_target_failed'
        elseif entry.distance and current_distance
            and entry.distance <= near_distance
            and current_distance > entry.distance + switch_margin then
            reason = 'near_attacker_preemption'
        elseif current >= (afk.next_target_switch_at or 0) and entry.distance and current_distance
            and entry.distance + switch_margin < current_distance then
            reason = 'closer_direct_attacker'
        elseif current_distance and current_distance <= near_distance then
            keep_reason = current_confirmed and 'confirmed_target_in_melee_range'
                or 'current_target_in_melee_range'
        elseif entry.distance and current_distance and entry.distance >= current_distance then
            keep_reason = 'candidate_is_farther'
        else
            keep_reason = 'switch_margin_or_cooldown'
        end
        local decision = reason and 'switch' or 'keep'
        if current >= (entry.next_log_at or 0) then
            trace_event('attacker_candidate', ('decision=%s reason=%s current_id=0x%08X current_distance=%s current_confirmed=%s candidate_id=0x%08X candidate_distance=%s candidate_age=%.2f source=%s'):fmt(
                decision, tostring(reason or keep_reason), afk.aggressor_server_id or 0,
                tostring(current_distance), tostring(current_confirmed), entry.server_id,
                tostring(entry.distance), candidate_age, tostring(afk.target_source)))
            entry.next_log_at = current + 1.0
        end
        if reason then switch_aggressor(entry, reason, current); return true end
        return false
    end
    local function best_direct_attacker(current, excluded_server_id)
        local best, best_distance
        for server_id, entry in pairs(afk.attackers) do
            local distance = entry.distance or horizontal_distance(entry.index)
            if server_id ~= excluded_server_id and distance
                and current - (entry.last_seen or 0) <= ACTIVE_THREAT_SECONDS
                and not target_on_cooldown(server_id, current)
                and (not best_distance or distance < best_distance) then
                best, best_distance = entry, distance
            end
        end
        return best
    end
    local function entity_position(index)
        local manager = AshitaCore:GetMemoryManager()
        local entities = manager and manager:GetEntity() or nil
        if not entities or index <= 0 then return nil end
        local x = entities:GetLocalPositionX(index)
        local y = entities:GetLocalPositionY(index)
        local z = entities:GetLocalPositionZ(index)
        if type(x) ~= 'number' or type(y) ~= 'number' or type(z) ~= 'number' then return nil end
        return { x = x, y = y, z = z }
    end
    local function player_index()
        local party = AshitaCore:GetMemoryManager():GetParty()
        return party and (party:GetMemberTargetIndex(0) or 0) or 0
    end
    local function waypoint_distance(point)
        local position = entity_position(player_index())
        if not position or not point then return nil end
        local delta_x, delta_y = point.x - position.x, point.y - position.y
        return math.sqrt((delta_x * delta_x) + (delta_y * delta_y))
    end
    local function nav_details(diagnostics)
        diagnostics = diagnostics or nav.status() or {}
        return ('mode=%s custom=%s start_valid=%s target_valid=%s query=%s points=%s reported=%s endpoint=%s result=%s'):fmt(
            tostring(diagnostics.mode), tostring(diagnostics.custom_mesh), tostring(diagnostics.start_valid),
            tostring(diagnostics.target_valid), tostring(diagnostics.query), tostring(diagnostics.waypoint_count),
            tostring(diagnostics.reported_points), tostring(diagnostics.endpoint_distance), tostring(diagnostics.result))
    end
    local function plan_nav_path(index)
        local party = AshitaCore:GetMemoryManager():GetParty()
        local zone = party and (party:GetMemberZone(0) or 0) or 0
        local start_position = entity_position(player_index())
        local end_position = entity_position(index)
        afk.nav_attempted = true
        if not start_position or not end_position or not nav.load(zone) then
            trace_event('nav_path_failed', ('zone=%d mesh_zone=%s available=%s start=%s target=%s error=%s'):fmt(
                zone, tostring(nav.zone), tostring(nav.available),
                start_position and ('%.3f,%.3f,%.3f'):fmt(start_position.x, start_position.y, start_position.z) or 'nil',
                end_position and ('%.3f,%.3f,%.3f'):fmt(end_position.x, end_position.y, end_position.z) or 'nil',
                tostring(nav.error)))
            return false
        end
        local path, path_error, diagnostics = nav.find_path(
            start_position, end_position, state.settings.afk_recovery.stop_distance[1] + 2.0)
        if not path or #path == 0 then
            trace_event('nav_path_failed', ('zone=%d mesh_zone=%s available=%s start=%.3f,%.3f,%.3f target=%.3f,%.3f,%.3f error=%s %s'):fmt(
                zone, tostring(nav.zone), tostring(nav.available),
                start_position.x, start_position.y, start_position.z,
                end_position.x, end_position.y, end_position.z, tostring(path_error), nav_details(diagnostics)))
            return false
        end
        path = nav_logic.stop_short(path, start_position, end_position,
            state.settings.afk_recovery.stop_distance[1])
        afk.nav_path = path
        afk.nav_cursor = 1
        afk.nav_target_position = end_position
        afk.nav_planned_at = ctx.now()
        afk.nav_waypoint_cursor = 0
        afk.last_waypoint_distance = nil
        afk.waypoint_progress_at = afk.nav_planned_at
        while afk.nav_cursor <= #path
            and nav_logic.waypoint_reached(waypoint_distance(path[afk.nav_cursor]), WAYPOINT_REACHED_DISTANCE) do
            afk.nav_cursor = afk.nav_cursor + 1
        end
        trace_event('nav_path_ready', ('zone=%d points=%d cursor=%d %s'):fmt(
            zone, #path, afk.nav_cursor, nav_details(diagnostics)))
        for cursor, point in ipairs(path) do
            trace_event('nav_waypoint_planned', ('cursor=%d converted=%.3f,%.3f,%.3f'):fmt(
                cursor, point.x, point.y, point.z))
        end
        for cursor, point in ipairs(diagnostics and diagnostics.native_waypoints or {}) do
            trace_event('nav_waypoint_native', ('cursor=%d native=%.3f,%.3f,%.3f'):fmt(
                cursor, point.x, point.y, point.z))
        end
        return afk.nav_cursor <= #path
    end
    local function navigation_target_moved(index, current)
        if not afk.nav_path or not afk.nav_target_position then return false end
        local target = entity_position(index)
        if not target then return false end
        return current >= (afk.nav_planned_at or 0) + NAV_REPLAN_SECONDS
            and math.sqrt((target.x - afk.nav_target_position.x) ^ 2
                + (target.y - afk.nav_target_position.y) ^ 2) >= NAV_REPLAN_DISTANCE
    end
    local function test_navigation_path()
        local manager = AshitaCore:GetMemoryManager()
        local target_manager = manager and manager:GetTarget() or nil
        local party = manager and manager:GetParty() or nil
        local index = target_manager and (target_manager:GetTargetIndex(0) or 0) or 0
        local start_position, end_position = entity_position(player_index()), entity_position(index)
        local zone = party and (party:GetMemberZone(0) or 0) or 0
        if index <= 0 or not start_position or not end_position or not nav.load(zone) then
            return false, nav.error ~= '' and nav.error or 'Select a valid target first.'
        end
        local path, path_error, diagnostics = nav.find_path(
            start_position, end_position, state.settings.afk_recovery.stop_distance[1] + 2.0)
        trace_event(path and 'nav_test_ready' or 'nav_test_failed', ('zone=%d target_index=%d error=%s %s'):fmt(
            zone, index, tostring(path_error), nav_details(diagnostics)))
        return path ~= nil, path and ('Path ready: %d waypoints.'):fmt(#path) or tostring(path_error)
    end
    local function current_nav_waypoint()
        local path = afk.nav_path
        while path and afk.nav_cursor <= #path do
            local point = path[afk.nav_cursor]
            local distance = waypoint_distance(point)
            if not nav_logic.waypoint_reached(distance, WAYPOINT_REACHED_DISTANCE) then return point end
            afk.nav_cursor = afk.nav_cursor + 1
            afk.nav_waypoint_cursor = 0
            afk.last_waypoint_distance = nil
            afk.waypoint_progress_at = ctx.now()
            trace_event('nav_waypoint_reached', ('cursor=%d remaining=%d'):fmt(
                afk.nav_cursor, math.max(0, #path - afk.nav_cursor + 1)))
        end
        return nil
    end
    local function steer_to_waypoint(point)
        local manager = AshitaCore:GetMemoryManager()
        local follow = manager and manager:GetAutoFollow() or nil
        local position = entity_position(player_index())
        if not follow or not position or not point then return false end
        ensure_lockoff('nav_waypoint')
        follow:SetTargetIndex(0)
        follow:SetTargetServerId(0)
        follow:SetFollowTargetIndex(0)
        follow:SetFollowTargetServerId(0)
        follow:SetFollowDeltaX(point.x - position.x)
        follow:SetFollowDeltaZ(point.z - position.z)
        follow:SetFollowDeltaY(point.y - position.y)
        follow:SetFollowDeltaW(1)
        follow:SetIsAutoRunning(1)
        afk.following = true
        afk.follow_reason = 'nav_approach'
        return true
    end
    local function insert_lateral_detour(waypoint)
        local position = entity_position(player_index())
        if not position or not waypoint or not afk.nav_path
            or afk.nav_detour_attempts >= MAX_NAV_DETOURS then return nil end
        local attempt = afk.nav_detour_attempts + 1
        local side = attempt % 2 == 1 and 1 or -1
        local detour = nav_logic.lateral_detour(position, waypoint, NAV_DETOUR_DISTANCE, side)
        afk.nav_detour_attempts = attempt
        if not detour or nav.can_see(position, detour) == false then
            trace_event('nav_detour_rejected', ('attempt=%d side=%s reason=not_visible'):fmt(
                attempt, side > 0 and 'left' or 'right'))
            return nil
        end
        table.insert(afk.nav_path, afk.nav_cursor, detour)
        afk.nav_waypoint_cursor = 0
        afk.last_waypoint_distance = nil
        afk.waypoint_progress_at = ctx.now()
        trace_event('nav_detour_inserted', ('attempt=%d side=%s cursor=%d point=%.3f,%.3f,%.3f blocked_waypoint=%.3f,%.3f,%.3f'):fmt(
            attempt, side > 0 and 'left' or 'right', afk.nav_cursor,
            detour.x, detour.y, detour.z, waypoint.x, waypoint.y, waypoint.z))
        return detour
    end
    local function nearest_party_claimed_target()
        local manager = AshitaCore:GetMemoryManager()
        local target_manager = manager and manager:GetTarget() or nil
        local entities = manager and manager:GetEntity() or nil
        local current_target = target_manager and (target_manager:GetTargetIndex(0) or 0) or 0
        local maximum = state.settings.afk_recovery.party_claim_range[1]
        local current = ctx.now()
        local current_id = entities and (entities:GetServerId(current_target) or 0) or 0
        if party_claimed(current_target) and not target_on_cooldown(current_id, current) then
            local distance = horizontal_distance(current_target)
            if distance and distance <= maximum then
                return current_target
            end
        end
        local best_index, best_distance = 0, math.huge
        for index = 1, 0x8FF do
            if party_claimed(index) then
                local distance = horizontal_distance(index)
                local server_id = entities and (entities:GetServerId(index) or 0) or 0
                if distance and distance <= maximum and distance < best_distance
                    and not target_on_cooldown(server_id, current) then
                    best_index, best_distance = index, distance
                end
            end
        end
        return best_index
    end
    local function scan_nearby()
        local names = {}
        local seen = {}
        local maximum = state.settings.afk_pull.range[1] * state.settings.afk_pull.range[1]
        for index = 1, 0x8FF do
            if hostile(index) then
                local entity = GetEntity(index)
                local name = entity and entity.Name or ''
                if name ~= '' and distance_squared(entity) <= maximum and not seen[name] then
                    seen[name] = true
                    table.insert(names, name)
                end
            end
        end
        table.sort(names, function(a, b) return a:lower() < b:lower() end)
        afk.nearby_mobs = names
        afk.pull_search_name = state.settings.afk_pull.mob_name[1]
        afk.pull_primary_name = state.settings.afk_pull.mob_name[1]
        afk.pull_search_misses = 0
        afk.pull_search_position = 1
        afk.next_pull_search_at = 0
        return names
    end
    local function nearby_mobs()
        return afk.nearby_mobs
    end
    local function pull_spells()
        local result = {}
        for _, action in ipairs(ctx.state.action_catalog.spells or {}) do
            if bit.band(action.targets or 0, 0x20) ~= 0 then
                table.insert(result, action)
            end
        end
        return result
    end
    local function nearest_pull_target(name)
        local best_index, best_distance = 0, math.huge
        local maximum = state.settings.afk_pull.range[1] * state.settings.afk_pull.range[1]
        local current = ctx.now()
        for index = 1, 0x8FF do
            if hostile(index) then
                local entity = GetEntity(index)
                local distance = distance_squared(entity)
                local server_id = AshitaCore:GetMemoryManager():GetEntity():GetServerId(index) or 0
                if entity and entity.Name == name and distance <= maximum and distance < best_distance
                    and not target_on_cooldown(server_id, current) then
                    best_index, best_distance = index, distance
                end
            end
        end
        return best_index
    end
    local function pull_search_names(primary)
        local result = { primary }
        for _, name in ipairs(afk.nearby_mobs) do
            if name ~= primary then result[#result + 1] = name end
        end
        return result
    end
    local function pull_search_budget(position)
        if position == 1 then return 3 end
        if position == 2 then return 2 end
        return 1
    end
    local function entity_index(server_id)
        local entities = AshitaCore:GetMemoryManager():GetEntity()
        if not entities then
            return 0
        end
        local probable = bit.band(server_id, 0xFFF)
        if probable >= 0x900 then
            probable = probable - 0x100
        end
        if probable > 0 and probable < 0x900 and entities:GetServerId(probable) == server_id then
            return probable
        end
        for index = 1, 0x8FF do
            if entities:GetServerId(index) == server_id then
                return index
            end
        end
        return 0
    end
    local function actor_and_targets(e)
        local data, offset, maximum = e.data_raw, 40, e.size * 8
        local function bits(length)
            if offset + length >= maximum then
                return 0
            end
            local value = ashita.bits.unpack_be(data, 0, offset, length)
            offset = offset + length
            return value
        end
        local function skip_action()
            bits(5)
            bits(12)
            bits(7)
            bits(3)
            bits(17)
            bits(10)
            bits(31)
            if bits(1) == 1 then
                bits(10)
                bits(17)
                bits(10)
            end
            if bits(1) == 1 then
                bits(10)
                bits(14)
                bits(10)
            end
        end
        local actor, count = bits(32), bits(6)
        offset = offset + 4
        local category = bits(4)
        if category == 8 or category == 9 then
            bits(16)
            bits(16)
        else
            bits(32)
        end
        bits(32)
        local targets = {}
        for _ = 1, count do
            table.insert(targets, bits(32))
            local actions = bits(4)
            for _ = 1, actions do
                skip_action()
            end
        end
        return actor, targets, category
    end
    local function reset()
        reset_recovery()
        afk.aggressor_index, afk.seen_at, afk.next_attack_at = 0, 0, 0
        afk.aggressor_server_id = 0
        afk.adopted_party_claim = false
        afk.target_source = nil
        afk.claim_seen_at = 0
        afk.last_target = 'None'
        afk.lockon_issued = false
        afk.attack_issued = false
        afk.melee_confirmed = false
        afk.melee_confirmed_server_id = 0
        afk.invalid_since = 0
        afk.stale_clear_issued = false
        afk.last_lock_state = nil
        afk.next_lock_trace_at = 0
        afk.pull_search_name = state.settings.afk_pull.mob_name[1]
        afk.pull_primary_name = state.settings.afk_pull.mob_name[1]
        afk.pull_search_misses = 0
        afk.pull_search_position = 1
        afk.next_pull_search_at = 0
    end
    local function start()
        ctx.refresh_catalog()
        local role_count = #combat.setup_actions()
        for _, role in ipairs({ 'heal', 'combat_buff',
            'combat_debuff', 'tp_recovery', 'weapon_skill' }) do
            role_count = role_count + #ctx.role_actions(role)
        end
        if role_count == 0 then
            return false, 'Select at least one shared combat-role action first.'
        end
        reset()
        combat.reset()
        afk.attackers = {}
        afk.failed_targets = {}
        afk.next_target_switch_at = 0
        scan_nearby()
        ctx.queue '/autotarget on'
        state.status = 'AFK: waiting for an attacker'
        return true, 'AFK retaliation armed; auto-target is on.'
    end
    local function stop()
        ctx.queue '/autotarget off'
        close_packet_log()
        reset()
    end
    local function pause()
        reset_recovery()
        afk.attack_issued = false
        afk.lockon_issued = false
    end
    local function tick()
        local current = ctx.now()
        local player = type(GetPlayerEntity) == 'function' and GetPlayerEntity() or nil
        if not player or (player.HPPercent or player.HealthPercent or 0) <= 0 then
            stop_following()
            state.status = 'AFK: waiting for character recovery'
            state.next_action = current + 0.5
            return
        end
        if not ctx.player_engaged() then
            if combat.tick({
                has_target = false,
                target_has_enhancements = false,
                allow_setup = true,
                status_prefix = 'AFK: ',
                queue_action = function(_, command) ctx.queue(command) end,
            }) then return end
        end
        prune_attackers(current)
        local preferred_attacker = best_direct_attacker(current, afk.aggressor_server_id)
        if preferred_attacker and consider_attacker(preferred_attacker, current) then
            state.next_action = current + 0.1
            return
        end
        if afk.aggressor_index > 0
            and (not aggressor_is_valid()
                or (not ctx.player_engaged() and not afk.adopted_party_claim
                    and current - afk.seen_at > MEMORY_SECONDS)) then
            reset()
            state.status = 'AFK: previous attacker is no longer valid'
        end
        if not ctx.player_engaged() and not aggressor_is_valid()
            and state.settings.afk_recovery.adopt_party_claims[1] then
            local adopted_index = nearest_party_claimed_target()
            if adopted_index > 0 then
                local entities = AshitaCore:GetMemoryManager():GetEntity()
                reset_recovery()
                afk.aggressor_index = adopted_index
                afk.aggressor_server_id = entities:GetServerId(adopted_index)
                afk.adopted_party_claim = true
                afk.target_source = 'party'
                afk.claim_seen_at = current
                afk.seen_at = current
                afk.next_attack_at = current
                afk.last_target = GetEntity(adopted_index).Name or 'Unknown'
                afk.lockon_issued = false
                afk.attack_issued = false
                state.status = 'AFK: adopting party-claimed mob ' .. afk.last_target
                trace_event('party_claim_adopted', ('index=%d server_id=0x%08X name=%s distance=%s claim=0x%08X'):fmt(
                    adopted_index, afk.aggressor_server_id, afk.last_target,
                    tostring(horizontal_distance(adopted_index)), entities:GetClaimStatus(adopted_index) or 0))
            end
        end
        if aggressor_is_valid() and not ctx.player_engaged() then
            local target_manager = AshitaCore:GetMemoryManager():GetTarget()
            local current_target = target_manager and (target_manager:GetTargetIndex(0) or 0) or 0
            if target_manager and current_target ~= afk.aggressor_index then
                reset_recovery()
                target_manager:SetTarget(afk.aggressor_index, true)
                afk.attack_issued = false
                state.status = 'AFK: switching to attacker ' .. (GetEntity(afk.aggressor_index).Name or 'Unknown')
                state.next_action = current + 0.25
                return
            end
        end
        if aggressor_is_valid() and not afk.attack_issued then
            local entity = GetEntity(afk.aggressor_index)
            AshitaCore:GetMemoryManager():GetTarget():SetTarget(afk.aggressor_index, true)
            ensure_lockon()
            if not afk.facing_pulse_done then
                if not afk.following then
                    if not start_following(afk.aggressor_index, 'initial_facing') then
                        afk.facing_pulse_done = true
                    else
                        afk.facing_until = current + FACING_PULSE_SECONDS
                    end
                end
                if afk.following and current < afk.facing_until then
                    state.status = 'AFK: turning to face ' .. (entity.Name or 'attacker')
                    state.next_action = current + 0.05
                    return
                end
                stop_following('initial_facing_complete')
                afk.facing_pulse_done = true
            end
            if afk.following then
                state.status = 'AFK: turning to face ' .. (entity.Name or 'attacker')
                state.next_action = current + 0.05
                return
            end
            ctx.queue '/attack <t>'
            afk.attack_issued = true
            afk.engage_started_at = current
            afk.recovery_spell_deadline = current + ENGAGE_GRACE_SECONDS + SPELL_READY_GRACE
            afk.next_attack_at = current + RETRY_SECONDS
            state.status = 'AFK: engaging attacker ' .. (entity.Name or 'Unknown')
            trace_event('attack_queued', ('index=%d server_id=0x%08X distance=%s adopted=%s'):fmt(
                afk.aggressor_index, afk.aggressor_server_id, tostring(horizontal_distance(afk.aggressor_index)),
                tostring(afk.adopted_party_claim)))
            state.next_action = current + 1.0
            return
        end
        local engaged = ctx.player_engaged()
        local valid_aggressor = aggressor_is_valid()
        local aggressor_distance = valid_aggressor and horizontal_distance(afk.aggressor_index) or nil
        local recovery = state.settings.afk_recovery
        local recovery_active = recovery.enabled[1] or afk.melee_pull
        if engaged and not valid_aggressor then
            local target_manager = AshitaCore:GetMemoryManager():GetTarget()
            local selected_index = target_manager and (target_manager:GetTargetIndex(0) or 0) or 0
            if hostile(selected_index) then
                local entities = AshitaCore:GetMemoryManager():GetEntity()
                reset_recovery()
                afk.aggressor_index = selected_index
                afk.aggressor_server_id = entities:GetServerId(selected_index) or 0
                afk.adopted_party_claim = party_claimed(selected_index)
                afk.target_source = afk.adopted_party_claim and 'party' or 'selected'
                afk.claim_seen_at = afk.adopted_party_claim and current or 0
                afk.seen_at = current
                afk.attack_issued = true
                afk.engage_started_at = current
                afk.last_target = GetEntity(selected_index).Name or 'Unknown'
                trace_event('engaged_target_recovered', ('index=%d server_id=0x%08X name=%s distance=%s claimed=%s'):fmt(
                    selected_index, afk.aggressor_server_id, afk.last_target,
                    tostring(horizontal_distance(selected_index)), tostring(afk.adopted_party_claim)))
                state.status = 'AFK: recovered live engaged target ' .. afk.last_target
                state.next_action = current + 0.1
                return
            end
            if (afk.invalid_since or 0) == 0 then afk.invalid_since = current end
            local invalid_for = current - afk.invalid_since
            if invalid_for >= STALE_ENGAGEMENT_GRACE and not afk.stale_clear_issued then
                ctx.queue '/attack off'
                afk.stale_clear_issued = true
                trace_event('stale_engagement_cleared', ('invalid_for=%.2f selected_index=%d player_status=%s previous_index=%d previous_id=0x%08X'):fmt(
                    invalid_for, selected_index, tostring(player.Status), afk.aggressor_index or 0,
                    afk.aggressor_server_id or 0))
            end
            state.status = invalid_for < STALE_ENGAGEMENT_GRACE
                and 'AFK: waiting for battle-target data before clearing engagement'
                or 'AFK: clearing stale engagement before selecting an attacker'
            state.next_action = current + 0.25
            return
        end
        afk.invalid_since = 0
        afk.stale_clear_issued = false
        local stop_distance = recovery.stop_distance[1]
        local approach_threshold = afk.following and stop_distance
            or (stop_distance + APPROACH_HYSTERESIS)
        local needs_approach = engaged
            and afk.attack_issued
            and recovery_active
            and afk.melee_confirmed_server_id ~= afk.aggressor_server_id
            and current >= (afk.melee_grace_until or 0)
            and aggressor_distance ~= nil
            and aggressor_distance > approach_threshold
        if engaged and not needs_approach
            and afk.melee_confirmed_server_id ~= afk.aggressor_server_id then
            local entity = GetEntity(afk.aggressor_index)
            AshitaCore:GetMemoryManager():GetTarget():SetTarget(afk.aggressor_index, true)
            ensure_lockon()
            if afk.following and afk.follow_reason ~= 'melee_confirmation_retry' then
                stop_following('stop_distance_waiting_melee')
                begin_melee_grace('stop_distance_waiting_melee')
            end
            if current >= afk.next_attack_at then
                if not afk.following and start_following(afk.aggressor_index, 'melee_confirmation_retry') then
                    afk.facing_until = current + FACING_PULSE_SECONDS
                    begin_melee_grace('melee_confirmation_retry')
                end
                ctx.queue '/attack <t>'
                afk.next_attack_at = current + RETRY_SECONDS
                trace_event('melee_confirmation_retry', ('index=%d server_id=0x%08X distance=%s'):fmt(
                    afk.aggressor_index, afk.aggressor_server_id, tostring(aggressor_distance)))
            end
            if afk.following and afk.follow_reason == 'melee_confirmation_retry'
                and current >= (afk.facing_until or 0) then
                stop_following('melee_confirmation_retry_complete')
            end
            state.status = 'AFK: waiting for confirmed melee on ' .. (entity and entity.Name or 'attacker')
            state.next_action = current + 0.1
            return
        end
        if engaged and not needs_approach then
            stop_following('engagement_confirmed')
            ensure_lockon()
            local entity = GetEntity(afk.aggressor_index)
            if combat.tick({
                has_target = true,
                -- AFK establishes and refreshes its Terpander song slots only
                -- while idle. The rest of the shared combat rotation remains
                -- active after engagement.
                allow_setup = false,
                target_key = tostring(afk.aggressor_server_id or afk.aggressor_index),
                target_name = entity and entity.Name or 'target',
                -- AFK has no battle-message enhancement tracker, so automatic
                -- dispel remains dormant outside fight profiles that provide it.
                target_has_enhancements = false,
                status_prefix = 'AFK: ',
                queue_action = function(_, command) ctx.queue(command) end,
            }) then return end
            state.status = 'AFK: engaged; shared combat rotation waiting'
            state.next_action = ctx.now() + 1
            return
        end
        if afk.attack_issued and aggressor_is_valid() then
            local distance = aggressor_distance or horizontal_distance(afk.aggressor_index)
            local distance_label = distance and ('%.1f yalms'):fmt(distance) or 'unknown distance'
            if not recovery_active and afk.following then
                reset_recovery()
                afk.engage_started_at = current
                state.status = 'AFK: distant-attacker recovery disabled; movement stopped'
            end
            if recovery_active and current >= afk.engage_started_at + ENGAGE_GRACE_SECONDS then
                if not engaged and not afk.melee_pull
                    and recovery.use_pull_spell[1] and not afk.recovery_spell_attempted then
                    local spell = ctx.state.action_catalog.by_key[state.settings.afk_pull.spell_key[1]]
                    if not spell then
                        afk.recovery_spell_attempted = true
                    elseif current <= afk.recovery_spell_deadline then
                        if current >= afk.next_recovery_spell_at then
                            local party = AshitaCore:GetMemoryManager():GetParty()
                            local mp = party and (party:GetMemberMP(0) or 0) or 0
                            if (spell.mana or 0) <= mp and ctx.action_ready(spell) then
                                ctx.queue(ctx.action_command(spell, '<t>'))
                                state.last_spell = spell.name
                                afk.recovery_spell_attempted = true
                                afk.recovery_wait_until = current
                                    + math.max(RECOVERY_CAST_WAIT, (spell.cast_time or 0) + 1.5)
                                state.status = ('AFK: trying %s on attacker at %s'):fmt(spell.name, distance_label)
                                state.next_action = current + 0.25
                                return
                            end
                            afk.next_recovery_spell_at = current + 0.5
                        end
                        state.status = ('AFK: waiting briefly for %s'):fmt(spell.name)
                        state.next_action = current + 0.25
                        return
                    else
                        afk.recovery_spell_attempted = true
                    end
                end
                if current < (afk.recovery_wait_until or 0) then
                    state.status = 'AFK: waiting for ranged engagement'
                    state.next_action = current + 0.25
                    return
                end
                    local recovery_threshold = afk.following and stop_distance
                        or (stop_distance + APPROACH_HYSTERESIS)
                    if distance and distance > recovery_threshold
                        and current >= (afk.melee_grace_until or 0)
                        and afk.approach_attempts < MAX_APPROACH_ATTEMPTS then
                    if recovery.use_pathfinding[1] and not afk.nav_attempted then
                        plan_nav_path(afk.aggressor_index)
                    end
                    local waypoint = recovery.use_pathfinding[1] and current_nav_waypoint() or nil
                    if recovery.use_pathfinding[1] and afk.nav_path and not waypoint
                        and current >= (afk.next_nav_replan_at or 0) then
                        trace_event('nav_replan_requested', ('reason=path_exhausted distance=%.2f'):fmt(distance))
                        afk.next_nav_replan_at = current + NAV_REPLAN_SECONDS
                        plan_nav_path(afk.aggressor_index)
                        waypoint = current_nav_waypoint()
                    elseif recovery.use_pathfinding[1] and waypoint
                        and afk.nav_cursor >= #afk.nav_path
                        and navigation_target_moved(afk.aggressor_index, current) then
                        trace_event('nav_replan_requested', ('reason=target_moved_on_final_leg distance=%.2f'):fmt(distance))
                        if plan_nav_path(afk.aggressor_index) then waypoint = current_nav_waypoint() end
                    end
                    local waypoint_distance_now = waypoint and waypoint_distance(waypoint) or nil
                    if waypoint and afk.nav_waypoint_cursor ~= afk.nav_cursor then
                        afk.nav_waypoint_cursor = afk.nav_cursor
                        afk.last_waypoint_distance = waypoint_distance_now
                        afk.waypoint_progress_at = current
                        local position = entity_position(player_index())
                        trace_event('nav_waypoint_active', ('cursor=%d player=%s waypoint=%.3f,%.3f,%.3f distance=%s visible=%s'):fmt(
                            afk.nav_cursor, position and ('%.3f,%.3f,%.3f'):fmt(
                                position.x, position.y, position.z) or 'nil', waypoint.x, waypoint.y, waypoint.z,
                            tostring(waypoint_distance_now), tostring(position and nav.can_see(position, waypoint))))
                    elseif waypoint_distance_now
                        and waypoint_distance_now < (afk.last_waypoint_distance or waypoint_distance_now) - 0.15 then
                        afk.last_waypoint_distance = waypoint_distance_now
                        afk.waypoint_progress_at = current
                    end
                    if not afk.following and current >= afk.next_approach_at then
                        local started = waypoint and steer_to_waypoint(waypoint)
                            or start_following(afk.aggressor_index, 'distant_approach')
                        if started then
                            afk.approach_started_at = current
                            afk.last_distance = distance
                            afk.last_progress_at = current
                            afk.next_follow_trace_at = current
                            trace_event('follow_queued', ('distance=%.2f attempt=%d target_index=%d target_id=0x%08X nav=%s cursor=%d'):fmt(
                                distance, afk.approach_attempts + 1, afk.aggressor_index, afk.aggressor_server_id,
                                tostring(waypoint ~= nil), afk.nav_cursor or 0))
                        else
                            afk.approach_attempts = afk.approach_attempts + 1
                            afk.next_approach_at = current + APPROACH_RETRY_SECONDS
                        end
                    end
                    if afk.following and waypoint then
                        steer_to_waypoint(waypoint)
                    end
                    if afk.following then
                        local follow = AshitaCore:GetMemoryManager():GetAutoFollow()
                        local autorun = follow and follow:GetIsAutoRunning() or 0
                        if follow and autorun ~= 1 and autorun ~= true then
                            local resumed = waypoint and steer_to_waypoint(waypoint)
                                or start_following(afk.aggressor_index, 'knockback_resume')
                            if resumed then
                                afk.last_progress_at = current
                                trace_event('follow_resumed', ('distance=%.2f nav=%s'):fmt(
                                    distance, tostring(waypoint ~= nil)))
                            end
                        end
                    end
                    if not waypoint and distance < (afk.last_distance or distance) - 0.2 then
                        afk.last_distance = distance
                        afk.last_progress_at = current
                    end
                    local timed_out = current >= afk.approach_started_at + recovery.max_time[1]
                    local progress_at = waypoint and afk.waypoint_progress_at or afk.last_progress_at
                    local stuck = current >= (progress_at or current) + STUCK_SECONDS
                    if afk.following and current >= (afk.next_follow_trace_at or 0) then
                        local follow = AshitaCore:GetMemoryManager():GetAutoFollow()
                        trace_event('follow_progress', ('distance=%.2f last_distance=%.2f waypoint_distance=%s waypoint_last=%s cursor=%d autorun=%s follow_index=%s follow_id=%s'):fmt(
                            distance, afk.last_distance or distance, tostring(waypoint_distance_now),
                            tostring(afk.last_waypoint_distance), afk.nav_cursor or 0,
                            tostring(follow and follow:GetIsAutoRunning()),
                            tostring(follow and follow:GetFollowTargetIndex()),
                            tostring(follow and follow:GetFollowTargetServerId())))
                        afk.next_follow_trace_at = current + 0.5
                    end
                    if afk.following and stuck and waypoint and current >= (afk.next_nav_replan_at or 0) then
                        trace_event('nav_replan_requested', ('reason=waypoint_stalled cursor=%d waypoint_distance=%s target_distance=%.2f'):fmt(
                            afk.nav_cursor, tostring(waypoint_distance_now), distance))
                        afk.next_nav_replan_at = current + NAV_REPLAN_SECONDS
                        local detour = insert_lateral_detour(waypoint)
                        if detour then
                            waypoint = detour
                            steer_to_waypoint(waypoint)
                            afk.last_waypoint_distance = waypoint_distance(waypoint)
                            afk.waypoint_progress_at = current
                            stuck = false
                        elseif plan_nav_path(afk.aggressor_index) then
                            waypoint = current_nav_waypoint()
                            if waypoint then
                                steer_to_waypoint(waypoint)
                                afk.last_waypoint_distance = waypoint_distance(waypoint)
                                afk.waypoint_progress_at = current
                                stuck = false
                                trace_event('nav_replan_applied', ('reason=waypoint_stalled cursor=%d'):fmt(afk.nav_cursor))
                            end
                        end
                    end
                    if afk.following and (timed_out or stuck) then
                        stop_following(timed_out and 'timeout' or 'stalled')
                        afk.approach_attempts = afk.approach_attempts + 1
                        afk.next_approach_at = current + APPROACH_RETRY_SECONDS
                        afk.nav_path = nil
                        afk.nav_attempted = false
                        state.status = timed_out and 'AFK: approach timed out; retry scheduled'
                            or 'AFK: approach stalled; retry scheduled'
                    elseif afk.following then
                        state.status = ('AFK: approaching attacker at %.1f yalms'):fmt(distance)
                    else
                        state.status = ('AFK: waiting to retry approach (%d/%d)'):fmt(
                            afk.approach_attempts, MAX_APPROACH_ATTEMPTS)
                    end
                    state.next_action = current + 0.25
                    return
                end
                if afk.following then
                    stop_following('stop_distance_reached')
                    begin_melee_grace('stop_distance_reached')
                    afk.next_attack_at = current
                end
            end
            if current >= afk.next_attack_at then
                AshitaCore:GetMemoryManager():GetTarget():SetTarget(afk.aggressor_index, true)
                ensure_lockon()
                ctx.queue '/attack <t>'
                trace_event('attack_retried', ('index=%d server_id=0x%08X distance=%s'):fmt(
                    afk.aggressor_index, afk.aggressor_server_id, tostring(distance)))
                afk.next_attack_at = current + RETRY_SECONDS
            end
            if afk.approach_attempts >= MAX_APPROACH_ATTEMPTS
                and afk.melee_confirmed_server_id ~= afk.aggressor_server_id
                and not afk.failure_recorded then
                afk.failure_recorded = true
                afk.failed_targets[afk.aggressor_server_id] = current + FAILED_TARGET_COOLDOWN
                trace_event('target_approach_failed', ('index=%d server_id=0x%08X distance=%s cooldown=%.1f'):fmt(
                    afk.aggressor_index, afk.aggressor_server_id, tostring(distance), FAILED_TARGET_COOLDOWN))
                local alternative = best_direct_attacker(current, afk.aggressor_server_id)
                if alternative then
                    switch_aggressor(alternative, 'current_target_failed', current)
                    state.next_action = current + 0.1
                    return
                end
                if not engaged and afk.target_source == 'pull' then
                    reset()
                    state.status = 'AFK: failed pull target cooling down; selecting another'
                    state.next_action = current + 0.1
                    return
                end
            end
            if afk.approach_attempts < MAX_APPROACH_ATTEMPTS then
                state.status = 'AFK: waiting for melee engagement at ' .. distance_label
            else
                state.status = 'AFK: approach failed after maximum retries; still attempting /attack'
            end
            state.next_action = current + 0.25
            return
        end
        local pull = state.settings.afk_pull
        if pull.enabled[1] and pull.mob_name[1] ~= '' then
            if afk.pull_search_name == '' or afk.pull_primary_name ~= pull.mob_name[1] then
                afk.pull_primary_name = pull.mob_name[1]
                afk.pull_search_name = pull.mob_name[1]
                afk.pull_search_misses = 0
                afk.pull_search_position = 1
                afk.next_pull_search_at = 0
            end
            local search_names = pull_search_names(pull.mob_name[1])
            if afk.pull_search_position > #search_names then afk.pull_search_position = 1 end
            local search_name = search_names[afk.pull_search_position]
            afk.pull_search_name = search_name
            local search_budget = pull_search_budget(afk.pull_search_position)
            local target_index = 0
            if current >= (afk.next_pull_search_at or 0) then
                target_index = nearest_pull_target(search_name)
                if target_index == 0 then
                    afk.pull_search_misses = (afk.pull_search_misses or 0) + 1
                    afk.next_pull_search_at = current + PULL_SEARCH_RETRY_SECONDS
                    trace_event('pull_search_miss', ('name=%s position=%d/%d attempt=%d/%d scanned=%d'):fmt(
                        search_name, afk.pull_search_position, #search_names, afk.pull_search_misses,
                        search_budget, #afk.nearby_mobs))
                    if afk.pull_search_misses >= search_budget then
                        local previous = search_name
                        afk.pull_search_position = (afk.pull_search_position % #search_names) + 1
                        afk.pull_search_misses = 0
                        afk.next_pull_search_at = current
                        search_name = search_names[afk.pull_search_position]
                        afk.pull_search_name = search_name
                        trace_event('pull_search_advanced', ('previous=%s next=%s position=%d/%d next_budget=%d'):fmt(
                            previous, search_name, afk.pull_search_position, #search_names,
                            pull_search_budget(afk.pull_search_position)))
                    end
                end
            end
            local target_distance = target_index > 0 and horizontal_distance(target_index) or nil
            if target_index > 0 and target_distance then
                local entities = AshitaCore:GetMemoryManager():GetEntity()
                reset_recovery()
                afk.aggressor_index = target_index
                afk.aggressor_server_id = entities:GetServerId(target_index) or 0
                afk.adopted_party_claim = false
                afk.target_source = 'pull'
                afk.melee_pull = true
                afk.seen_at = current
                afk.next_attack_at = current
                afk.last_target = GetEntity(target_index).Name or search_name
                afk.lockon_issued = false
                afk.attack_issued = false
                AshitaCore:GetMemoryManager():GetTarget():SetTarget(target_index, true)
                state.status = ('AFK: approaching pull target %s at %.1f yalms'):fmt(
                    afk.last_target, target_distance)
                trace_event('melee_pull_adopted', ('index=%d server_id=0x%08X name=%s distance=%.2f'):fmt(
                    target_index, afk.aggressor_server_id, afk.last_target, target_distance))
                afk.pull_search_name = pull.mob_name[1]
                afk.pull_primary_name = pull.mob_name[1]
                afk.pull_search_misses = 0
                afk.pull_search_position = 1
                afk.next_pull_search_at = 0
                state.next_action = current + 0.1
                return
            end
            if target_index == 0 then
                state.status = ('AFK: searching for %s (%d/%d)'):fmt(
                    search_name, afk.pull_search_misses, pull_search_budget(afk.pull_search_position))
            end
        end
        if current - afk.seen_at > MEMORY_SECONDS or not aggressor_is_valid() then
            reset_recovery()
            afk.aggressor_index = 0
            afk.aggressor_server_id = 0
            afk.adopted_party_claim = false
            afk.target_source = nil
            afk.claim_seen_at = 0
            afk.lockon_issued = false
            afk.attack_issued = false
            state.status = 'AFK: waiting for an attacker'
            state.next_action = current + 0.25
            return
        end
        state.next_action = current + 0.25
    end
    local function on_packet(e)
        local recorded = record_packet('in', e, false)
        if e.id == ZONE_PACKET or e.id == LOGOUT_PACKET then
            close_packet_log()
            reset()
            return
        end
        if e.id ~= ACTION_PACKET then
            return
        end
        local ok, actor, targets, category = pcall(actor_and_targets, e)
        if not ok or not actor or not targets then
            return
        end
        local party = AshitaCore:GetMemoryManager():GetParty()
        local player_id = party and party:GetMemberServerId(0) or 0
        if player_id == 0 then
            return
        end
        if actor == player_id then
            if category == 1 and afk.aggressor_server_id > 0 then
                for _, target in ipairs(targets) do
                    if target == afk.aggressor_server_id then
                        afk.melee_confirmed = true
                        afk.melee_confirmed_server_id = target
                        if afk.following then stop_following('melee_confirmed') end
                        afk.failure_recorded = false
                        trace_event('melee_confirmed', ('target_id=0x%08X index=%d'):fmt(
                            target, afk.aggressor_index))
                        break
                    end
                end
            end
            return
        end
        for _, target in ipairs(targets) do
            if target == player_id then
                local index = entity_index(actor)
                if hostile(index) then
                    local current = ctx.now()
                    local entry = remember_attacker(actor, index, current)
                    if afk.aggressor_server_id == actor then
                        afk.seen_at = current
                    end
                    if afk.adopted_party_claim and afk.aggressor_server_id == actor then
                        afk.adopted_party_claim = false
                        afk.target_source = 'direct'
                        afk.claim_seen_at = 0
                        afk.seen_at = current
                        state.status = 'AFK: adopted target is now attacking directly'
                        trace_event('party_claim_promoted', ('index=%d server_id=0x%08X distance=%s'):fmt(
                            index, actor, tostring(horizontal_distance(index))))
                    elseif afk.aggressor_server_id == actor then
                        afk.target_source = 'direct'
                    else
                        consider_attacker(entry, current)
                    end
                    if not recorded then record_packet('in', e, true) end
                end
                return
            end
        end
    end
    local function on_packet_out(e)
        record_packet('out', e, false)
    end
    return {
        start = start,
        stop = stop,
        pause = pause,
        tick = tick,
        on_packet = on_packet,
        on_packet_out = on_packet_out,
        state = afk,
        actions = actions,
        scan_nearby = scan_nearby,
        nearby_mobs = nearby_mobs,
        pull_spells = pull_spells,
        packet_log_path = packet_log_path,
        sync_packet_log = sync_packet_log,
        shutdown_navigation = nav.shutdown,
        navigation_status = nav.status,
        test_navigation_path = test_navigation_path,
    }
end

return M
