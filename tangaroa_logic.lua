local M = {}

function M.phase_from_message(message)
    local lower = (message or ''):lower()
    if lower:find('tangaroa uses venom shell', 1, true)
        or lower:find('tangaroa readies venom shell', 1, true) then
        return 'shell'
    end
    if lower:find('tangaroa is staggered', 1, true) then
        return 'exposed'
    end
    return nil
end

function M.is_tangaroa(name)
    return (name or ''):lower() == 'tangaroa'
end

return M
