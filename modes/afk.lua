local M = {};
local HOSTILE_FLAG, MEMORY_SECONDS, RETRY_SECONDS = 0x10, 10, 3;

function M.new(ctx)
    local state = ctx.state;
    state.afk = state.afk or { aggressor_index = 0, seen_at = 0, next_attack_at = 0, last_target = 'None' };
    local afk = state.afk;
    local function hostile(index)
        if (not index or index <= 0 or type(GetEntity) ~= 'function') then return false; end
        local entity = GetEntity(index);
        if (not entity) then return false; end
        return (entity.HPPercent or entity.HealthPercent or 0) > 0
            and bit.band(entity.SpawnFlags or 0, HOSTILE_FLAG) == HOSTILE_FLAG;
    end
    local function entity_index(server_id)
        local entities = AshitaCore:GetMemoryManager():GetEntity();
        if (not entities) then return 0; end
        local probable = bit.band(server_id, 0xFFF);
        if (probable >= 0x900) then probable = probable - 0x100; end
        if (probable > 0 and probable < 0x900 and entities:GetServerId(probable) == server_id) then return probable; end
        for index = 1, 0x8FF do if (entities:GetServerId(index) == server_id) then return index; end end
        return 0;
    end
    local function actor_and_targets(e)
        local data, offset, maximum = e.data_raw, 40, e.size * 8;
        local function bits(length)
            if (offset + length >= maximum) then return 0; end
            local value = ashita.bits.unpack_be(data, 0, offset, length); offset = offset + length; return value;
        end
        local actor, count = bits(32), bits(6); offset = offset + 4;
        local category = bits(4); if (category == 8 or category == 9) then bits(16); bits(16); else bits(32); end
        bits(32);
        local targets = {};
        for _ = 1, count do
            table.insert(targets, bits(32));
            local actions = bits(4);
            for _ = 1, actions do
                bits(5); bits(12); bits(7); bits(3); bits(17); bits(10); bits(31);
                if (bits(1) == 1) then bits(10); bits(17); bits(10); end
                if (bits(1) == 1) then bits(10); bits(14); bits(10); end
            end
        end
        return actor, targets;
    end
    local function reset()
        afk.aggressor_index, afk.seen_at, afk.next_attack_at = 0, 0, 0;
        afk.last_target = 'None';
    end
    local function start()
        reset(); ctx.queue('/autotarget on'); state.status = 'AFK: waiting for an attacker';
        return true, 'AFK retaliation armed; auto-target is on.';
    end
    local function stop()
        ctx.queue('/autotarget off'); reset();
    end
    local function tick()
        if (ctx.player_engaged()) then state.status = 'AFK: engaged; auto-target will chain attackers'; return; end
        local current = ctx.now();
        if (current - afk.seen_at > MEMORY_SECONDS or not hostile(afk.aggressor_index)) then
            afk.aggressor_index = 0; state.status = 'AFK: waiting for an attacker'; state.next_action = current + .25; return;
        end
        if (current < afk.next_attack_at) then return; end
        local entity = GetEntity(afk.aggressor_index);
        AshitaCore:GetMemoryManager():GetTarget():SetTarget(afk.aggressor_index, true);
        ctx.queue('/attack <t>'); afk.last_target = entity.Name or 'Unknown';
        state.status = 'AFK: engaging attacker ' .. afk.last_target;
        afk.next_attack_at = current + RETRY_SECONDS; state.next_action = current + .25;
    end
    local function on_packet(e)
        if (e.id == 0x000A or e.id == 0x000B) then reset(); return; end
        if (e.id ~= 0x0028) then return; end
        local ok, actor, targets = pcall(actor_and_targets, e);
        if (not ok or not actor or not targets) then return; end
        local party = AshitaCore:GetMemoryManager():GetParty();
        local player_id = party and party:GetMemberServerId(0) or 0;
        if (player_id == 0 or actor == player_id) then return; end
        for _, target in ipairs(targets) do
            if (target == player_id) then
                local index = entity_index(actor);
                if (hostile(index)) then
                    afk.aggressor_index, afk.seen_at, afk.next_attack_at = index, ctx.now(), ctx.now();
                    afk.last_target = GetEntity(index).Name or 'Unknown'; state.status = 'AFK: attacker detected ' .. afk.last_target;
                end
                return;
            end
        end
    end
    return { start = start, stop = stop, tick = tick, on_packet = on_packet, state = afk };
end

return M;
