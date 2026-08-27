local packet_decoder = require 'packet_decoder';
local M = {};

local file = nil;
local path = '';

local function ensure_directory()
    local root = ('%s\\config\\addons\\smartskillup\\'):fmt(AshitaCore:GetInstallPath());
    local directory = root .. 'logs\\';
    if (not ashita.fs.exists(root)) then ashita.fs.create_dir(root); end
    if (not ashita.fs.exists(directory)) then ashita.fs.create_dir(directory); end
    return directory;
end

function M.open(metadata)
    M.close();
    path = ensure_directory() .. os.date('ambuscade_%Y%m%d_%H%M%S.log');
    file = io.open(path, 'a+');
    if (file ~= nil) then
        file:write(('# SmartSkillup Ambuscade diagnostic trace %s\n'):fmt(os.date('%Y-%m-%d %H:%M:%S')));
        file:write(('# %s\n'):fmt(metadata or ''));
        file:write('# Times use the addon monotonic clock; action packets are written as decoded fields.\n');
        file:flush();
    else
        path = '';
    end
    return path;
end

function M.close()
    if (file ~= nil) then file:flush(); file:close(); file = nil; end
end

function M.path() return path; end

function M.event(current_time, label, details)
    if (file == nil) then return; end
    file:write(('[%.3f] event=%s%s\n'):fmt(current_time or 0, tostring(label),
        details and (' ' .. tostring(details)) or ''));
    file:flush();
end

function M.packet(current_time, direction, e)
    if (file == nil or (e.id ~= 0x001A and e.id ~= 0x0028)) then return; end
    file:write(('[%.3f] packet=%s %s blocked=%s injected=%s modified=%s\n'):fmt(
        current_time or 0, direction, packet_decoder.describe(direction, e),
        tostring(e.blocked), tostring(e.injected), tostring(e.modified)));
    file:flush();
end

return M;
