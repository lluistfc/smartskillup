local M = {};

function M.new(ctx)
    local moving = false;
    local target_index = 0;
    local last_distance = nil;
    local last_progress_at = 0;

    local function stop()
        local manager = AshitaCore:GetMemoryManager();
        local follow = manager and manager:GetAutoFollow() or nil;
        if (follow ~= nil and moving) then follow:SetIsAutoRunning(0); end
        moving = false;
        target_index = 0;
        last_distance = nil;
        last_progress_at = 0;
    end

    local function player_index()
        local party = AshitaCore:GetMemoryManager():GetParty();
        return party ~= nil and (party:GetMemberTargetIndex(0) or 0) or 0;
    end

    local function distance(index)
        local entities = AshitaCore:GetMemoryManager():GetEntity();
        local player = player_index();
        if (entities == nil or player <= 0 or index == nil or index <= 0) then return nil; end
        local player_x = entities:GetLocalPositionX(player);
        local player_y = entities:GetLocalPositionY(player);
        local target_x = entities:GetLocalPositionX(index);
        local target_y = entities:GetLocalPositionY(index);
        if (type(player_x) ~= 'number' or type(player_y) ~= 'number'
            or type(target_x) ~= 'number' or type(target_y) ~= 'number') then return nil; end
        local delta_x, delta_y = target_x - player_x, target_y - player_y;
        return math.sqrt((delta_x * delta_x) + (delta_y * delta_y));
    end

    local function approach(index, stop_distance)
        local current_distance = distance(index);
        if (current_distance == nil or current_distance <= stop_distance) then
            stop();
            return false, current_distance;
        end

        local manager = AshitaCore:GetMemoryManager();
        local follow = manager and manager:GetAutoFollow() or nil;
        local entities = manager and manager:GetEntity() or nil;
        local server_id = entities and (entities:GetServerId(index) or 0) or 0;
        if (follow == nil or server_id <= 0) then
            stop();
            return false, current_distance;
        end

        if (not moving or target_index ~= index) then
            stop();
            follow:SetTargetIndex(index);
            follow:SetTargetServerId(server_id);
            follow:SetFollowTargetIndex(index);
            follow:SetFollowTargetServerId(server_id);
            follow:SetIsAutoRunning(1);
            moving = true;
            target_index = index;
            last_distance = current_distance;
            last_progress_at = ctx.now();
        elseif (last_distance == nil or current_distance < last_distance - 0.15) then
            last_distance = current_distance;
            last_progress_at = ctx.now();
        elseif (ctx.now() - last_progress_at >= 1.0) then
            stop();
            return false, current_distance, true;
        end
        return true, current_distance;
    end

    return {
        approach = approach,
        distance = distance,
        stop = stop,
        is_moving = function() return moving; end,
    };
end

return M;
