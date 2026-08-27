local M = {}

local function finite(value)
    return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

function M.convert(position, mode)
    if not position then
        return nil
    end
    if mode == "swapped" then
        return { x = position.x, y = position.z, z = position.y }
    end
    return { x = position.x, y = position.y, z = position.z }
end

function M.select_calibration(probes)
    local preference = { "ffxi:false", "swapped:false", "ffxi:true", "swapped:true" }
    for _, key in ipairs(preference) do
        local probe = probes[key]
        if probe and probe.player_valid and (probe.target_valid == nil or probe.target_valid) then
            return probe.mode, probe.custom_mesh
        end
    end
    for _, key in ipairs(preference) do
        local probe = probes[key]
        if probe and probe.player_valid then
            return probe.mode, probe.custom_mesh
        end
    end
    return nil, nil
end

function M.horizontal_distance(first, second)
    local dx, dy = first.x - second.x, first.y - second.y
    return math.sqrt(dx * dx + dy * dy)
end

function M.waypoint_reached(distance, tolerance)
    return type(distance) == "number" and distance <= (tolerance or 1.5)
end

function M.stop_short(path, start_position, target_position, stop_distance)
    if not path or #path == 0 or not start_position or not target_position then return path end
    local distance = math.max(0, tonumber(stop_distance) or 0)
    if distance == 0 then return path end
    local previous = #path > 1 and path[#path - 1] or start_position
    local dx, dy = previous.x - target_position.x, previous.y - target_position.y
    local length = math.sqrt((dx * dx) + (dy * dy))
    if length <= 0.001 then return path end
    local result = {}
    for index = 1, #path - 1 do result[index] = path[index] end
    result[#path] = {
        x = target_position.x + (dx / length) * distance,
        y = target_position.y + (dy / length) * distance,
        z = path[#path].z,
    }
    return result
end

function M.lateral_detour(start_position, destination, distance, side)
    if not start_position or not destination then return nil end
    local dx, dy = destination.x - start_position.x, destination.y - start_position.y
    local length = math.sqrt((dx * dx) + (dy * dy))
    if length <= 0.001 then return nil end
    local offset = math.max(0.5, tonumber(distance) or 3.0) * ((side or 1) < 0 and -1 or 1)
    return {
        x = start_position.x - (dy / length) * offset,
        y = start_position.y + (dx / length) * offset,
        z = start_position.z,
    }
end

function M.normalize(points, start_position, target_position, maximum_points)
    local result = {}
    local limit = math.min(#points, maximum_points or 256)
    for index = 1, limit do
        local point = points[index]
        if
            not point
            or not finite(point.x)
            or not finite(point.y)
            or not finite(point.z)
            or math.abs(point.x) > 100000
            or math.abs(point.y) > 100000
            or math.abs(point.z) > 100000
        then
            return nil, "waypoint_data_invalid"
        end
        local previous = result[#result]
        if previous and M.horizontal_distance(previous, point) > 100 then
            return nil, "waypoint_jump_invalid"
        end
        if not previous or M.horizontal_distance(previous, point) > 0.05 or math.abs(previous.z - point.z) > 0.05 then
            result[#result + 1] = point
        end
    end
    while #result > 0 and M.horizontal_distance(start_position, result[1]) <= 0.8 do
        table.remove(result, 1)
    end
    if #result == 0 then
        return nil, "path_empty_after_normalization"
    end
    local endpoint_distance = M.horizontal_distance(result[#result], target_position)
    return result, nil, endpoint_distance
end

return M
