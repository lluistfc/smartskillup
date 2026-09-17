package.path = './?.lua;' .. package.path

local logic = require 'tangaroa_logic'

assert(logic.phase_from_message('Tangaroa uses Venom Shell.') == 'shell')
assert(logic.phase_from_message('Tangaroa readies Venom Shell.') == 'shell')
assert(logic.phase_from_message('Tangaroa is staggered!') == 'exposed')
assert(logic.phase_from_message("Tangaroa's weakness has changed.") == nil)
assert(logic.phase_from_message('Koura uses Bubble Curtain.') == nil)
assert(logic.is_tangaroa('Tangaroa'))
assert(not logic.is_tangaroa('Koura'))

print('Tangaroa logic tests passed')
