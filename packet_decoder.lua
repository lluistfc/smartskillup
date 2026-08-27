local ffi = require 'ffi';
local M = {};

local CATEGORY_NAMES = {
    [1] = 'melee', [2] = 'ranged_finish', [3] = 'weaponskill', [4] = 'spell',
    [5] = 'item', [6] = 'job_ability', [7] = 'weaponskill_start',
    [8] = 'spell_start', [9] = 'item_start', [11] = 'mob_ability', [12] = 'ranged_start',
    [14] = 'job_ability_effect',
};
local OUTGOING_CATEGORY_NAMES = {
    [0] = 'disengage', [1] = 'engage_or_attack', [2] = 'ranged_attack', [3] = 'spell',
    [4] = 'item', [5] = 'job_ability', [7] = 'weaponskill', [9] = 'job_ability',
    [12] = 'assist', [13] = 'raise_response',
};

local function resource_name(category, param, outgoing)
    if (AshitaCore == nil or AshitaCore:GetResourceManager() == nil) then return ''; end
    local resources = AshitaCore:GetResourceManager();
    local ok, resource = pcall(function()
        if ((outgoing and category == 3) or (not outgoing and (category == 4 or category == 8))) then
            return resources:GetSpellById(param);
        elseif (outgoing and (category == 5 or category == 9)) then
            return resources:GetAbilityById(param + 0x200);
        elseif ((outgoing and category == 7)
            or (not outgoing and (category == 3 or category == 6 or category == 7))) then
            return resources:GetAbilityById((not outgoing and category == 6) and (param + 0x200) or param);
        end
        return nil;
    end);
    if (not ok or resource == nil) then return ''; end
    local name = resource.Name;
    if (type(name) ~= 'string') then
        local name_ok, localized = pcall(function()
            return name and (name[1] or name[0] or name[2]) or nil;
        end);
        name = name_ok and localized or nil;
    end
    return type(name) == 'string' and name or '';
end

local function ids(values)
    local result = {};
    for index, value in ipairs(values or {}) do result[index] = tostring(value); end
    return table.concat(result, ',');
end

local function decode_incoming_action(e)
    local data, offset, maximum = e.data_raw, 40, (e.size or 0) * 8;
    local function bits(length)
        if (offset + length > maximum) then error('packet_too_short'); end
        local value = ashita.bits.unpack_be(data, 0, offset, length);
        offset = offset + length;
        return value;
    end
    local function skip_action()
        bits(5); bits(12); bits(7); bits(3); bits(17); bits(10); bits(31);
        if (bits(1) == 1) then bits(10); bits(17); bits(10); end
        if (bits(1) == 1) then bits(10); bits(14); bits(10); end
    end
    local actor, count = bits(32), bits(6);
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
        local action_count = bits(4);
        for _ = 1, action_count do skip_action(); end
    end
    return ('type=incoming_action actor_server_id=%s category=%d(%s) action_param=%s action_name=%q target_count=%d target_server_ids=[%s]'):fmt(
        tostring(actor), category, CATEGORY_NAMES[category] or 'unknown', tostring(param),
        resource_name(category, param, false), count, ids(targets));
end

local function byte_reader(e)
    local data = type(e.data) == 'string' and e.data or e.data_raw;
    local size = e.size or (type(data) == 'string' and #data or 0);
    local pointer;
    if (type(data) ~= 'string' and data ~= nil) then pointer = ffi.cast('const uint8_t*', data); end
    local function byte(offset)
        if (offset < 0 or offset >= size) then error('packet_too_short'); end
        return type(data) == 'string' and data:byte(offset + 1) or pointer[offset];
    end
    local function u16(offset) return byte(offset) + byte(offset + 1) * 0x100; end
    local function u32(offset) return u16(offset) + u16(offset + 2) * 0x10000; end
    return u16, u32;
end

local function decode_outgoing_action(e)
    local u16, u32 = byte_reader(e);
    local target_id = u32(4);
    local target_index = u16(8);
    local category = u16(10);
    local param = u16(12);
    return ('type=outgoing_action target_server_id=%s target_index=%d category=%d(%s) action_param=%d action_name=%q'):fmt(
        tostring(target_id), target_index, category, OUTGOING_CATEGORY_NAMES[category] or 'unknown', param,
        resource_name(category, param, true));
end

function M.describe(direction, e)
    if (e.id == 0x0028 and direction == 'in') then
        local ok, value = pcall(decode_incoming_action, e);
        return ok and value or ('type=incoming_action decode_error=%q'):fmt(tostring(value));
    elseif (e.id == 0x001A and direction == 'out') then
        local ok, value = pcall(decode_outgoing_action, e);
        return ok and value or ('type=outgoing_action decode_error=%q'):fmt(tostring(value));
    elseif (e.id == 0x000A) then
        return 'type=zone_transition';
    elseif (e.id == 0x000B) then
        return 'type=logout';
    end
    return ('type=packet id=0x%04X size=%s'):fmt(e.id or 0, tostring(e.size or 0));
end

return M;
