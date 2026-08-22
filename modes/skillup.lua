local M = {}
local ACTION_CATEGORIES = { 'spells', 'job_abilities', 'weapon_skills' }

function M.new(ctx)
    local state = ctx.state
    local function actions()
        local result = {}
        for _, category in ipairs(ACTION_CATEGORIES) do
            for _, action in ipairs(ctx.selected_actions(state.settings.actions.rotation, category)) do
                table.insert(result, action)
            end
        end
        return result
    end
    local function start()
        ctx.refresh_catalog()
        if #actions() == 0 then
            return false, 'Select at least one currently available action first.'
        end
        state.resting = false
        state.skill_cursor = 1
        return true, 'Skill-up session started.'
    end
    local function tick()
        local player = AshitaCore:GetMemoryManager():GetPlayer()
        ctx.refresh_catalog_if_needed(player)
        local party = AshitaCore:GetMemoryManager():GetParty()
        local mpp = party:GetMemberMPPercent(0) or 0
        if state.resting then
            if mpp >= state.settings.resume_above[1] then
                ctx.queue '/heal'
                state.resting = false
                state.status = 'Running'
                state.next_action = ctx.now() + 1
            else
                state.status = ('Resting (%d%% MP)'):fmt(mpp)
                state.next_action = ctx.now() + 1
            end
            return
        elseif state.settings.rest_below[1] > 0 and mpp <= state.settings.rest_below[1] then
            ctx.queue '/heal'
            state.resting = true
            state.status = ('Resting (%d%% MP)'):fmt(mpp)
            state.next_action = ctx.now() + 2
            return
        end
        local selected = actions()
        if #selected == 0 then
            ctx.stop 'Stopped: no actions selected.'
            return
        end
        local mp = party:GetMemberMP(0) or 0
        for offset = 0, #selected - 1 do
            local index = ((state.skill_cursor + offset - 1) % #selected) + 1
            local action = selected[index]
            local mana_cost = action.mana or 0
            local affordable = action.kind ~= 'spell'
                or (mana_cost <= mp and (state.settings.mp_limit[1] <= 0 or mana_cost <= state.settings.mp_limit[1]))
            if affordable and ctx.action_ready(action) then
                local target = action.kind == 'spell' and ctx.spell_target(action.id)
                    or (bit.band(action.targets or 0, 0x20) == 0 and '<me>' or '<t>')
                ctx.queue(ctx.action_command(action, target))
                state.last_spell = action.name
                state.status = ('Using %s (%s)'):fmt(action.name, action.category:gsub('_', ' '))
                state.skill_cursor = (index % #selected) + 1
                state.next_action = ctx.now() + math.max(action.kind == 'spell' and 2.5 or 1, state.settings.delay[1])
                return
            end
        end
        state.status = ctx.player_engaged() and 'Waiting for MP/recasts' or 'Waiting for MP/recasts/combat'
        state.next_action = ctx.now() + 1
    end
    return { start = start, tick = tick, actions = actions }
end

return M
