package.path = './?.lua;' .. package.path;

local rotation = require 'combat_rotation';

local march = { name = 'Advancing March', is_song = true };
local minuet = { name = 'Valor Minuet V', is_song = true };
local dummy = { name = "Army's Paeon", is_song = true };
local final = { name = 'Blade Madrigal', is_song = true };
local setup = { march, minuet, dummy, final };

local dummy_repair = rotation.repair_plan(setup, 3, dummy);
assert(#dummy_repair == 2 and dummy_repair[1] == dummy and dummy_repair[2] == final,
    'dummy failure must preserve March/Minuet and repair only dummy plus final song');

local final_repair = rotation.repair_plan(setup, 4, final);
assert(#final_repair == 1 and final_repair[1] == final,
    'final-song failure must retry only that song');

local core_repair = rotation.repair_plan(setup, 2, minuet);
assert(#core_repair == 4 and core_repair ~= setup,
    'a failed core song must snapshot a complete rebuild without aliasing the live list');

assert(rotation.repair_plan(setup, 2, { name = 'Troubadour', is_song = false }) == nil,
    'non-song failures must not create a song repair plan');

assert(not rotation.can_spend_tp(72, 1000, 100, 350),
    'a Step must not be queued without enough TP');
assert(not rotation.can_spend_tp(400, 1000, 100, 350),
    'low-priority TP actions must preserve the emergency Waltz reserve');
assert(rotation.can_spend_tp(500, 1000, 100, 350),
    'TP actions may spend above the emergency reserve');
assert(not rotation.can_spend_tp(1050, 1000, 100, 350),
    'TP actions must preserve a ready weaponskill');

local deadline = rotation.current_song_deadline({
    ['advancing march'] = { expires_at = 300 },
    ['valor minuet v'] = { expires_at = 305 },
    ["mage's ballad iii"] = { expires_at = 310 },
    ['blade madrigal'] = { expires_at = 100 },
}, { 'Advancing March', 'Valor Minuet V', "Mage's Ballad III" });
assert(deadline == 300,
    'a stale estimate for the previous third song must not reopen refresh early');

local learned = {
    ['blade madrigal'] = true,
    ["mage's ballad iii"] = true,
    ["sentinel's scherzo"] = true,
};
local julika_song = rotation.choose_third_song(learned, 'Bozzetto Julika', 20, 10);
assert(julika_song == 'Blade Madrigal',
    'the damage-race phases must retain Madrigal even when caster MP is low');
local stable_jody_song = rotation.choose_third_song(learned, 'Bozzetto Jody', 80, 70);
assert(stable_jody_song == 'Blade Madrigal',
    'Jody must retain Madrigal while caster MP is stable');
local low_mp_jody_song = rotation.choose_third_song(learned, 'Bozzetto Jody', 55, 70);
assert(low_mp_jody_song == "Mage's Ballad III",
    'Jody must select Ballad III when Apururu reaches the configured pressure threshold');
local fallback_song = rotation.choose_third_song({ ["sentinel's scherzo"] = true },
    'Bozzetto Julika', nil, nil);
assert(fallback_song == "Sentinel's Scherzo",
    'the strategy must select the safest learned fallback when offensive songs are unavailable');

print('combat rotation tests passed');
