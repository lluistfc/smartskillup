local profiles = {
    { id = 'plantoids_2026_08', label = 'August 2026: Plantoids', module = 'ambuscades.plantoids_2026_08' },
};
local M = {};
function M.list() return profiles; end
function M.find(id)
    for _, profile in ipairs(profiles) do if (profile.id == id) then return profile; end end
    return profiles[1];
end
return M;
