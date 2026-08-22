local registry = require 'ambuscades.registry';
local M = {};

function M.new(ctx)
    local controller = { available_profiles = registry.list };
    function controller.profile_label()
        return registry.find(ctx.state.settings.ambuscade.profile[1]).label;
    end
    local current;
    function controller.activate()
        local selected = ctx.state.settings.ambuscade.profile[1];
        local metadata = registry.find(selected);
        if (selected ~= metadata.id) then ctx.state.settings.ambuscade.profile[1] = metadata.id; end
        current = require(metadata.module).new(ctx);
        controller.id, controller.label, controller.targets = metadata.id, metadata.label, current.targets;
    end
    controller.activate();
    for _, method in ipairs({ 'reset', 'tick', 'next_action', 'on_text', 'timeline_prune',
        'timeline_add', 'player_tp', 'shantotto_tp', 'qultada_tp', 'finishing_moves',
        'role_count', 'buff_count', 'ui_stats' }) do
        local name = method;
        controller[name] = function(...) return current[name](...); end
    end
    return controller;
end

return M;
