package.path = package.path .. ";./?.lua"

local nav = require("nav_logic")

local function equal(actual, expected, label)
    assert(actual == expected, ("%s: expected %s, got %s"):format(label, tostring(expected), tostring(actual)))
end

local swapped = nav.convert({ x = 1, y = 2, z = 3 }, "swapped")
equal(swapped.x, 1, "swapped x")
equal(swapped.y, 3, "swapped y")
equal(swapped.z, 2, "swapped z")
local restored = nav.convert(swapped, "swapped")
equal(restored.y, 2, "restored y")
equal(restored.z, 3, "restored z")

local mode, custom = nav.select_calibration({
    ["ffxi:false"] = { mode = "ffxi", custom_mesh = false, player_valid = true, target_valid = true },
    ["swapped:false"] = { mode = "swapped", custom_mesh = false, player_valid = true, target_valid = true },
})
equal(mode, "ffxi", "preferred calibration mode")
equal(custom, false, "preferred calibration custom flag")

mode, custom = nav.select_calibration({
    ["ffxi:false"] = { mode = "ffxi", custom_mesh = false, player_valid = false },
    ["swapped:false"] = { mode = "swapped", custom_mesh = false, player_valid = true },
})
equal(mode, "swapped", "fallback calibration mode")
equal(custom, false, "fallback calibration custom flag")

local points, err, endpoint = nav.normalize({
    { x = 0, y = 0, z = 0 },
    { x = 0.01, y = 0.01, z = 0 },
    { x = 2, y = 0, z = 0 },
    { x = 4, y = 0, z = 0 },
}, { x = 0, y = 0, z = 0 }, { x = 5, y = 0, z = 0 })
equal(err, nil, "normalized error")
equal(#points, 2, "normalized point count")
equal(endpoint, 1, "endpoint distance")
equal(nav.waypoint_reached(1.49), true, "waypoint within tolerance")
equal(nav.waypoint_reached(1.51), false, "waypoint outside tolerance")

local shortened = nav.stop_short({ { x = 10, y = 0, z = 2 } },
    { x = 0, y = 0, z = 0 }, { x = 10, y = 0, z = 2 }, 2.5)
equal(shortened[1].x, 7.5, "path stops before target")
equal(shortened[1].y, 0, "shortened path y")

local left = nav.lateral_detour({ x = 0, y = 0, z = 1 }, { x = 5, y = 0, z = 1 }, 3, 1)
equal(left.x, 0, "left detour x")
equal(left.y, 3, "left detour y")
local right = nav.lateral_detour({ x = 0, y = 0, z = 1 }, { x = 5, y = 0, z = 1 }, 3, -1)
equal(right.y, -3, "right detour y")

points, err = nav.normalize({ { x = 0 / 0, y = 0, z = 0 } }, { x = 0, y = 0, z = 0 }, { x = 1, y = 0, z = 0 })
equal(points, nil, "invalid waypoint result")
equal(err, "waypoint_data_invalid", "invalid waypoint error")

points, err = nav.normalize(
    { { x = 1, y = 1, z = 0 }, { x = 150, y = 1, z = 0 } },
    { x = 0, y = 0, z = 0 },
    { x = 150, y = 1, z = 0 }
)
equal(points, nil, "invalid jump result")
equal(err, "waypoint_jump_invalid", "invalid jump error")

print("nav_logic tests passed")
