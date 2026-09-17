local combat_rotation = require 'combat_rotation'
local logic = require 'tangaroa_logic'

local M = {}
local DOOM_BUFF_ID = 15

function M.new(ctx)
    local state = ctx.state
    local combat = combat_rotation.new(ctx)

    local function target_name()
        local target = AshitaCore:GetMemoryManager():GetTarget()
        local index = target and (target:GetTargetIndex(0) or 0) or 0
        local entity = index > 0 and type(GetEntity) == 'function' and GetEntity(index) or nil
        return entity and (entity.Name or entity.name or '') or ''
    end

    local function target_key()
        local target = AshitaCore:GetMemoryManager():GetTarget()
        local index = target and (target:GetTargetIndex(0) or 0) or 0
        local entities = AshitaCore:GetMemoryManager():GetEntity()
        local server_id = index > 0 and (entities:GetServerId(index) or 0) or 0
        return server_id ~= 0 and tostring(server_id) or ('index:%d'):fmt(index)
    end

    local function has_doom()
        local player = AshitaCore:GetMemoryManager():GetPlayer()
        local buffs = player and (player:GetBuffs() or {}) or {}
        for _, buff in pairs(buffs) do
            if buff == DOOM_BUFF_ID then return true end
        end
        return false
    end

    local function equip(weapon, phase)
        if weapon == '' or state.tangaroa_equipped_phase == phase then return false end
        if not state.tangaroa_lac_main_disabled then
            ctx.queue('/lac disable main')
            state.tangaroa_lac_main_disabled = true
            state.status = 'Tangaroa: releasing main slot from LuaShitacast'
            state.next_action = ctx.now() + 0.5
            return true
        end
        ctx.queue(('/equip main "%s"'):fmt(weapon:gsub('"', '')))
        state.tangaroa_equipped_phase = phase
        state.status = ('Tangaroa: equipping %s weapon'):fmt(phase)
        state.next_action = ctx.now() + 1.0
        return true
    end

    local function start()
        ctx.refresh_catalog()
        state.tangaroa_phase = 'exposed'
        state.tangaroa_equipped_phase = nil
        state.tangaroa_holy_water_at = 0
        state.tangaroa_lac_main_disabled = false
        state.ambuscade_phase = 'setup'
        combat.reset()
        return true, 'Tangaroa routine started.'
    end

    local function stop()
        combat.reset()
        if state.tangaroa_lac_main_disabled then ctx.queue('/lac enable main') end
        state.tangaroa_equipped_phase = nil
        state.tangaroa_lac_main_disabled = false
    end

    local function tick()
        local current_time = ctx.now()
        if has_doom() and current_time >= (state.tangaroa_holy_water_at or 0) then
            ctx.queue('/item "Holy Water" <me>')
            state.tangaroa_holy_water_at = current_time + state.settings.tangaroa.holy_water_interval[1]
            state.status = 'Tangaroa: using Holy Water for Doom'
            state.next_action = current_time + 1.0
            return
        end

        if not logic.is_tangaroa(target_name()) then
            state.status = 'Tangaroa: target Tangaroa to begin'
            state.next_action = current_time + 0.5
            return
        end

        if state.tangaroa_phase == 'shell' then
            if equip(state.settings.tangaroa.club[1], 'shell') then return end
            local party = AshitaCore:GetMemoryManager():GetParty()
            local tp = party and (party:GetMemberTP(0) or 0) or 0
            if tp >= state.settings.ambuscade.weapon_skill_tp[1] then
                local ws = state.settings.tangaroa.shell_weapon_skill[1]:gsub('"', '')
                if ws ~= '' then
                    ctx.queue(('/ws "%s" <t>'):fmt(ws))
                    state.status = 'Tangaroa: shell phase — using ' .. ws
                    state.next_action = current_time + 2.0
                    return
                end
            end
            state.status = 'Tangaroa: shell phase — building TP with club'
            state.next_action = current_time + 0.5
            return
        end

        if equip(state.settings.tangaroa.dagger[1], 'exposed') then return end
        if combat.tick({
            has_target = true,
            target_name = 'Tangaroa',
            target_key = target_key(),
            target_has_enhancements = false,
            status_prefix = 'Tangaroa: ',
            queue_action = function(_, command) ctx.queue(command) end,
        }) then return end
        state.status = 'Tangaroa: exposed — normal combat rotation'
        state.next_action = current_time + 0.5
    end

    local function on_text(e)
        local message = (e.message_modified or ''):strip_colors():gsub('[\30\31\127]', ''):gsub('%c', ' ')
        local phase = logic.phase_from_message(message)
        if phase ~= nil then
            state.tangaroa_phase = phase
            state.tangaroa_equipped_phase = nil
            state.next_action = ctx.now()
            state.status = phase == 'shell' and 'Tangaroa: Venom Shell detected' or 'Tangaroa: stagger detected'
        end
    end

    local function set_phase(phase)
        state.tangaroa_phase = phase
        state.tangaroa_equipped_phase = nil
        state.next_action = ctx.now()
    end

    return {
        start = start,
        stop = stop,
        pause = stop,
        tick = tick,
        on_text = on_text,
        set_phase = set_phase,
    }
end

return M
