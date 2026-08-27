package.path = './?.lua;' .. package.path;

local timing = require 'action_timing';

assert(timing.is_healing_spell_name('Cure IV'), 'Cure must be recognized as an incoming heal');
assert(timing.is_healing_spell_name('Curaga VI'), 'Curaga must be recognized as an incoming heal');
assert(timing.is_healing_spell_name('Cura III'), 'Cura must be recognized as an incoming heal');
assert(timing.is_healing_spell_name('Full Cure'), 'Full Cure must be recognized as an incoming heal');
assert(not timing.is_healing_spell_name('Cursna'), 'status removal must not suppress emergency healing');

-- The delay calculation only touches Ashita for songs, so ability actions keep
-- this bookkeeping test runnable in plain Lua 5.1.
local action = {
    key = 'ability:1',
    id = 1,
    name = 'Test Ability',
    kind = 'ability',
    packet_id = 163,
};
local state = { next_action = 0 };

local first = timing.schedule(state, 0, action);
assert(type(first) == 'number', 'schedule must return an invocation token');
assert(timing.cancel(state, 0.1, 'first failed'));

local second = timing.schedule(state, 1, action);
assert(second ~= first, 'repeated actions must have distinct invocation tokens');
local old = timing.consume_outcome(state, first);
assert(old ~= nil and old.reason == 'first failed', 'the first result must remain token-bound');
assert(timing.consume_outcome(state, second) == nil, 'an old result must not satisfy the retry');

assert(timing.cancel(state, 1.1, 'second failed'));
local newer = timing.consume_outcome(state, second);
assert(newer ~= nil and newer.reason == 'second failed', 'the retry must consume only its own result');
assert(timing.consume_outcome(state, second) == nil, 'outcomes must be single-consumption');

local function le16(value)
    return string.char(value % 256, math.floor(value / 256) % 256);
end
local function le32(value)
    return le16(value % 65536) .. le16(math.floor(value / 65536));
end
local target_id = 0x01120959;
local outgoing = string.char(0, 0, 0, 0) .. le32(target_id) .. le16(114) .. le16(9) .. le16(163);
local sent = timing.schedule(state, 2, action, nil, target_id);
assert(timing.on_packet_out(state, { id = 0x001A, data = outgoing, size = #outgoing }, 2.1),
    'matching outgoing action must bind the pending invocation');
assert(state.pending_action.sent_at == 2.1, 'outgoing match must record dispatch time');
assert(not timing.matches_result(state.pending_action, 99, 99, 6, 164, { target_id }),
    'a delayed different ability must not complete the pending action');
assert(not timing.matches_result(state.pending_action, 99, 99, 6, 163, { target_id + 1 }),
    'a result for another target must not complete the pending action');
assert(timing.matches_result(state.pending_action, 99, 99, 6, 163, { target_id }),
    'matching action and target must complete the pending action');
timing.cancel(state, 2.2, 'fixture complete');
timing.consume_outcome(state, sent);

local step = {
    key = 'ability:714', id = 714, packet_id = 202, name = 'Box Step', kind = 'ability',
};
local step_token = timing.schedule(state, 3, step, nil, target_id);
state.pending_action.sent_at = 3.1;
assert(timing.matches_result(state.pending_action, 99, 99, 14, 202, { target_id }),
    'Box Step must accept the observed category-14 effect result');
assert(not timing.matches_result(state.pending_action, 99, 99, 14, 202, { target_id + 1 }),
    'category-14 Step result must remain target-bound');
timing.cancel(state, 3.2, 'step fixture complete');
timing.consume_outcome(state, step_token);

state.pending_action = {
    token = 999,
    key = 'spell:419',
    kind = 'spell',
    is_song = true,
};
timing.cancel(state, 10, 'song recovery fixture');
assert(state.next_action == 12.1,
    'song completion must retain enough recovery for the client animation lock');
timing.consume_outcome(state, 999);

for index = 1, 40 do
    timing.schedule(state, index + 2, action);
    timing.cancel(state, index + 2.1, 'prune test');
end
assert(#state.action_outcome_order <= 32, 'outcome history must remain bounded');

print('action_timing tests passed');
