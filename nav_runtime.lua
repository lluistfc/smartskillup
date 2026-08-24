local ffi = require("ffi")
local logic = require("nav_logic")

ffi.cdef([[
typedef struct ssu_nav_position_t {
    float x;
    float y;
    float z;
} ssu_nav_position_t;

void* __cdecl CreateFFXINavClass(void);
void __cdecl DisposeFFXINavClass(void* instance);
uint8_t __cdecl LoadMesh(void* instance, const uint16_t* path);
void __cdecl FindPath(void* instance, ssu_nav_position_t start, ssu_nav_position_t finish, uint8_t custom_mesh);
void __cdecl FindClosestPath(void* instance, ssu_nav_position_t start, ssu_nav_position_t finish, uint8_t custom_mesh);
int __cdecl Get_WayPoints(void* instance, ssu_nav_position_t** points);
int __cdecl Pathpoints(void* instance);
uint8_t __cdecl IsValidPosition(void* instance, ssu_nav_position_t position, uint8_t custom_mesh);
uint8_t __cdecl CanSeeDestination(void* instance, ssu_nav_position_t start, ssu_nav_position_t finish);
uint8_t __cdecl EnableNearestPoly(void* instance, ssu_nav_position_t position, uint8_t enable, uint8_t custom_mesh);
uint8_t __cdecl isNavMeshEnabled(void* instance);
uint8_t __cdecl unload(void* instance);
]])

local M = {
    available = false,
    error = "",
    zone = 0,
    diagnostics = {},
}

local library
local instance

local function native_position(position, mode)
    local converted = logic.convert(position, mode)
    return ffi.new("ssu_nav_position_t", converted.x, converted.y, converted.z)
end

local function valid_position(position, mode, custom_mesh)
    return library.IsValidPosition(instance, native_position(position, mode), custom_mesh and 1 or 0) ~= 0
end

local function set_diagnostic(values)
    for key, value in pairs(values) do
        M.diagnostics[key] = value
    end
end

local function utf16(value)
    local buffer = ffi.new("uint16_t[?]", #value + 1)
    for index = 1, #value do
        buffer[index - 1] = value:byte(index)
    end
    return buffer
end

local function initialize()
    if library and instance then
        return true
    end
    local dll_path = addon.path .. "\\nav\\runtime\\FFXINAV.dll"
    local ok, result = pcall(ffi.load, dll_path)
    if not ok then
        M.error = "Could not load FFXINAV.dll: " .. tostring(result)
        return false
    end
    library = result
    instance = library.CreateFFXINavClass()
    if instance == nil or instance == ffi.NULL then
        M.error = "FFXINAV failed to create its navigation object."
        instance = nil
        return false
    end
    return true
end

function M.load(zone)
    zone = tonumber(zone) or 0
    if zone <= 0 then
        M.error = "Current zone is unavailable."
        return false
    end
    if M.available and M.zone == zone then
        return true
    end
    if not initialize() then
        return false
    end
    if M.available then
        library.unload(instance)
        M.available = false
    end
    local mesh_path = addon.path .. ("\\nav\\runtime\\%d.nav"):fmt(zone)
    if not ashita.fs.exists(mesh_path) then
        M.error = ("No navmesh is installed for zone %d."):fmt(zone)
        return false
    end
    local ok, loaded = pcall(function()
        return library.LoadMesh(instance, utf16(mesh_path))
    end)
    if not ok or loaded == 0 then
        M.error = ("Failed to load navmesh for zone %d%s"):fmt(zone, ok and "." or (": " .. tostring(loaded)))
        return false
    end
    M.zone = zone
    M.available = library.isNavMeshEnabled(instance) ~= 0
    M.diagnostics = { zone = zone, mesh_path = mesh_path, loaded = M.available }
    M.error = M.available and "" or ("Navmesh for zone %d did not become active."):fmt(zone)
    return M.available
end

local function calibrate(start_position, end_position)
    local probes = {}
    for _, mode in ipairs({ "ffxi", "swapped" }) do
        for _, custom_mesh in ipairs({ false, true }) do
            local key = mode .. ":" .. tostring(custom_mesh)
            probes[key] = {
                mode = mode,
                custom_mesh = custom_mesh,
                player_valid = valid_position(start_position, mode, custom_mesh),
                target_valid = end_position and valid_position(end_position, mode, custom_mesh) or nil,
            }
        end
    end
    local mode, custom_mesh = logic.select_calibration(probes)
    set_diagnostic({ probes = probes, mode = mode or "unresolved", custom_mesh = custom_mesh })
    return mode, custom_mesh
end

local function read_waypoints(mode)
    local pointer = ffi.new("ssu_nav_position_t*[1]")
    local count = library.Get_WayPoints(instance, pointer)
    local reported = library.Pathpoints(instance)
    if count <= 0 or pointer[0] == nil or pointer[0] == ffi.NULL then
        return nil, count, reported, "waypoint_pointer_invalid"
    end
    local result = {}
    local native_result = {}
    for index = 0, math.min(count, 256) - 1 do
        local point = pointer[0][index]
        local native_point = {
            x = tonumber(point.x),
            y = tonumber(point.y),
            z = tonumber(point.z),
        }
        native_result[#native_result + 1] = native_point
        result[#result + 1] = logic.convert(native_point, mode)
    end
    return result, count, reported, nil, native_result
end

function M.find_path(start_position, end_position, endpoint_tolerance)
    if not M.available or not instance then
        return nil, M.error ~= "" and M.error or "Navmesh is not loaded."
    end
    local mode = M.diagnostics.mode ~= "unresolved" and M.diagnostics.mode or nil
    local custom_mesh = M.diagnostics.custom_mesh
    if not mode then
        mode, custom_mesh = calibrate(start_position, end_position)
    end
    if not mode then
        return nil, "coordinate_mode_unresolved", M.diagnostics
    end
    local start_valid = valid_position(start_position, mode, custom_mesh)
    local target_valid = valid_position(end_position, mode, custom_mesh)
    local start, finish = native_position(start_position, mode), native_position(end_position, mode)
    local ok, result, count, reported, read_error, query, native_points = pcall(function()
        local points, direct_count, direct_reported, direct_error, raw_points
        local query_type = "direct"
        if target_valid then
            library.FindPath(instance, start, finish, custom_mesh and 1 or 0)
            points, direct_count, direct_reported, direct_error, raw_points = read_waypoints(mode)
        end
        if not points then
            library.FindClosestPath(instance, start, finish, custom_mesh and 1 or 0)
            points, direct_count, direct_reported, direct_error, raw_points = read_waypoints(mode)
            query_type = "closest"
        end
        return points, direct_count, direct_reported, direct_error, query_type, raw_points
    end)
    if not ok then
        return nil, "native_query_error:" .. tostring(result), M.diagnostics
    end
    if not result then
        set_diagnostic({
            start_valid = start_valid,
            target_valid = target_valid,
            waypoint_count = count,
            reported_points = reported,
            query = query or "closest",
            native_error = read_error,
            result = start_valid and "path_empty" or "start_off_mesh",
        })
        if not start_valid then
            return nil, "start_off_mesh", M.diagnostics
        end
        return nil, target_valid and "path_disconnected" or "destination_off_mesh", M.diagnostics
    end
    local normalized, normalize_error, endpoint_distance = logic.normalize(result, start_position, end_position, 256)
    local tolerance = endpoint_tolerance or 5.0
    if normalized and endpoint_distance > tolerance then
        normalized, normalize_error =
            nil, query == "closest" and "closest_endpoint_too_far" or "direct_endpoint_too_far"
    end
    set_diagnostic({
        start_valid = start_valid,
        target_valid = target_valid,
        waypoint_count = count,
        reported_points = reported,
        query = query,
        endpoint_distance = endpoint_distance,
        result = normalized and "accepted" or normalize_error,
        native_waypoints = native_points,
        waypoints = normalized,
    })
    return normalized, normalize_error, M.diagnostics
end

function M.can_see(start_position, end_position)
    if not M.available or not instance or not M.diagnostics.mode then
        return nil
    end
    local ok, visible = pcall(function()
        return library.CanSeeDestination(
            instance,
            native_position(start_position, M.diagnostics.mode),
            native_position(end_position, M.diagnostics.mode)
        ) ~= 0
    end)
    return ok and visible or nil
end

function M.status()
    return M.diagnostics
end

function M.shutdown()
    if library and instance then
        pcall(function()
            if M.available then
                library.unload(instance)
            end
            library.DisposeFFXINavClass(instance)
        end)
    end
    instance = nil
    library = nil
    M.available = false
    M.zone = 0
    M.diagnostics = {}
end

return M
