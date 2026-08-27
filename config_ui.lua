local imgui = require 'imgui';
local M = {};

local categories = {
    { key = 'spells', label = 'Spells' },
    { key = 'job_abilities', label = 'Job abilities' },
    { key = 'weapon_skills', label = 'Weapon skills' },
};
local roles = {
    { key = 'setup_buff', label = 'Setup / recurring buffs' },
    { key = 'sleep', label = 'Sleep Vivian', effect = 'sleep' },
    { key = 'heal', label = 'Emergency healing' },
    { key = 'dispel', label = 'Dispel enemy enhancements' },
    { key = 'combat_buff', label = 'Combat buffs' },
    { key = 'combat_debuff', label = 'Combat debuffs' },
    { key = 'tp_recovery', label = 'TP recovery' },
    { key = 'weapon_skill', label = 'Weapon skills', category = 'weapon_skills' },
};

local function checklist(ctx, container, suffix, effect, only_category, open_by_default)
    local catalog, shown = ctx.catalog(), 0;
    for _, category in ipairs(categories) do
        if (only_category == nil or only_category == category.key) then
            local eligible = {};
            for _, action in ipairs(catalog[category.key]) do
                if (effect == nil or ctx.has_effect(action, effect)) then table.insert(eligible, action); end
            end
            shown = shown + #eligible;
            if (#eligible > 0 and open_by_default) then
                imgui.SetNextItemOpen(true, ImGuiCond_FirstUseEver);
            end
            if (#eligible > 0 and imgui.TreeNode(category.label .. '##' .. suffix)) then
                for _, action in ipairs(eligible) do
                    if (container[action.key] == nil) then container[action.key] = T{ false }; end
                    if (imgui.Checkbox(action.name .. '##' .. suffix .. action.key, container[action.key])) then
                        ctx.save(); ctx.wake();
                    end
                    if (action.description ~= '' and imgui.IsItemHovered()) then imgui.SetTooltip(action.description); end
                end
                imgui.TreePop();
            end
        end
    end
    if (shown == 0) then
        imgui.TextDisabled('No currently available matching actions.');
        if (suffix == 'rotation' or suffix == 'afk') then imgui.TextDisabled(ctx.catalog_status()); end
    end
end

local function mode_selector(ctx, state)
    local labels = { 'Skill-up Rotation', 'Command Rotation', 'Ambuscade', 'AFK Retaliation' };
    if (imgui.BeginCombo('Mode', labels[state.settings.mode[1]]) ) then
        for mode, label in ipairs(labels) do
            if (imgui.Selectable(label, state.settings.mode[1] == mode)) then
                if (state.active) then ctx.stop('Stopped: execution mode changed.'); end
                state.settings.mode[1] = mode; ctx.save();
            end
        end
        imgui.EndCombo();
    end
end

local function rotation_panel(ctx, state)
    imgui.TextWrapped('Choose individual actions available to the current character.');
    checklist(ctx, state.settings.actions.rotation, 'rotation');
    if (imgui.BeginCombo('Friendly target', ctx.party_target_label(state.settings.target_party[1]))) then
        if (imgui.Selectable('None (current target)', state.settings.target_party[1] == -1)) then
            state.settings.target_party[1] = -1; ctx.save();
        end
        local party = AshitaCore:GetMemoryManager():GetParty();
        if (party) then
            for index = 0, 5 do
                if (party:GetMemberIsActive(index) == 1
                    and imgui.Selectable(ctx.party_target_label(index), state.settings.target_party[1] == index)) then
                    state.settings.target_party[1] = index; ctx.save();
                end
            end
        end
        imgui.EndCombo();
    end
end

local function command_panel(ctx, state)
    imgui.Text('Commands are executed from top to bottom and then repeated.');
    local remove;
    for index, entry in ipairs(state.settings.commands) do
        if (imgui.Checkbox(('##enabled_%d'):fmt(index), entry.enabled)) then ctx.save(); end
        imgui.SameLine(); imgui.PushItemWidth(285);
        if (imgui.InputText(('##command_%d'):fmt(index), entry.text, 256)) then ctx.save(); end
        imgui.PopItemWidth(); imgui.SameLine();
        if (imgui.SmallButton(('X##remove_%d'):fmt(index))) then remove = index; end
    end
    if (remove) then table.remove(state.settings.commands, remove); state.command_cursor = 1; ctx.save(); end
    if (imgui.Button('Add Command', { 120, 0 })) then
        table.insert(state.settings.commands, T{ enabled = T{ true }, text = T{ '' } }); ctx.save();
    end
end

local function ambuscade_panel(ctx, state)
    imgui.TextWrapped('Configure action roles, enter the battlefield, then press Start.');
    if (imgui.BeginCombo('Fight profile', ctx.ambuscade_label())) then
        for _, profile in ipairs(ctx.ambuscade_profiles()) do
            if (imgui.Selectable(profile.label, state.settings.ambuscade.profile[1] == profile.id)) then
                state.settings.ambuscade.profile[1] = profile.id; ctx.save();
            end
        end
        imgui.EndCombo();
    end
    imgui.Text('Active mobs (uncheck when defeated)');
    for _, name in ipairs(ctx.ambuscade_targets()) do
        if (imgui.Checkbox(name, state.ambuscade_mobs[name])) then ctx.timeline(name .. ': updated'); ctx.wake(); end
    end
    imgui.Separator(); imgui.Text('Configured action roles');
    for _, role in ipairs(roles) do
        if (imgui.TreeNode(role.label .. '##role_' .. role.key)) then
            checklist(ctx, state.settings.ambuscade.roles[role.key], 'role_' .. role.key, role.effect, role.category);
            imgui.TreePop();
        end
    end
    if (imgui.Button('Refresh available actions', { 180, 0 })) then ctx.refresh(); end
    imgui.PushItemWidth(180);
    if (imgui.Checkbox('Use Terpander three-song rotation', state.settings.ambuscade.terpander_three_song)) then
        state.ambuscade_phase = 'setup'; state.ambuscade_cursor = 1; ctx.save(); ctx.wake();
    end
    if (imgui.BeginCombo('Weaponskill TP', ('%d TP'):fmt(state.settings.ambuscade.weapon_skill_tp[1]))) then
        for _, value in ipairs({ 1000, 2000, 3000 }) do
            if (imgui.Selectable(('%d TP'):fmt(value), state.settings.ambuscade.weapon_skill_tp[1] == value)) then
                state.settings.ambuscade.weapon_skill_tp[1] = value; state.ambuscade_ws_wait_started = 0; ctx.wake(); ctx.save();
            end
        end
        imgui.EndCombo();
    end
    if (imgui.SliderInt('Recurring buff duration (sec)', state.settings.ambuscade.song_duration, 60, 300)) then ctx.save(); end
    if (imgui.SliderInt('Refresh buffs early (sec)', state.settings.ambuscade.song_refresh_margin, 5, 45)) then ctx.save(); end
    if (imgui.SliderInt('Heal below HP%', state.settings.ambuscade.heal_below, 20, 80)) then ctx.save(); end
    if (imgui.SliderInt('Combat debuff duration (sec)', state.settings.ambuscade.combat_debuff_duration,
        15, 180)) then ctx.save(); end
    if (imgui.Checkbox('Approach selected targets', state.settings.ambuscade.approach_targets)) then
        ctx.save(); ctx.wake();
    end
    if (imgui.SliderFloat('Approach stop distance', state.settings.ambuscade.approach_stop_distance,
        2.41, 10, '%.2f yalms')) then ctx.save(); end
    if (imgui.SliderInt('Shantotto II sync TP', state.settings.ambuscade.shantotto_sync_tp, 750, 1000)) then ctx.save(); end
    if (imgui.SliderFloat('Maximum WS sync wait', state.settings.ambuscade.ws_sync_wait, 0, 10, '%.1f sec')) then ctx.save(); end
    imgui.PopItemWidth();
    for _, line in ipairs(ctx.ambuscade_stats()) do imgui.Text(line); end
    imgui.Separator(); imgui.TextColored({ .4, .8, 1, 1 }, 'Next: ' .. ctx.next_action());
    ctx.prune_timeline(); imgui.Text('Timeline (commands queued)');
    for _, entry in ipairs(state.ambuscade_timeline) do imgui.Text(('%5.1fs ago  %s'):fmt(ctx.now() - entry.time, entry.label)); end
end

local function afk_panel(ctx, state)
    imgui.TextWrapped('Retaliates only after a live hostile actor targets your character with an incoming action.');
    imgui.Text('Last attacker: ' .. (ctx.afk_state.last_target or 'None'));
    imgui.TextDisabled('Enables FFXI auto-target while this mode is running.');
    imgui.Separator();
    imgui.TextWrapped('Uses the same role-based combat rotation as Ambuscade; movement and target acquisition remain AFK-specific.');
    for _, role in ipairs(roles) do
        if (role.key ~= 'sleep' and role.key ~= 'dispel') then
            if (imgui.TreeNode(role.label .. '##afk_role_' .. role.key)) then
                checklist(ctx, state.settings.ambuscade.roles[role.key], 'afk_role_' .. role.key,
                    role.effect, role.category);
                imgui.TreePop();
            end
        end
    end
    if (imgui.Button('Refresh available actions', { 180, 0 })) then ctx.refresh(); end
    imgui.PushItemWidth(130);
    if (imgui.Checkbox('Use Terpander three-song rotation', state.settings.ambuscade.terpander_three_song)) then
        state.ambuscade_phase = 'setup'; state.ambuscade_cursor = 1; ctx.save(); ctx.wake();
    end
    if (imgui.SliderInt('Recurring buff duration (sec)', state.settings.ambuscade.song_duration, 60, 300)) then ctx.save(); end
    if (imgui.SliderInt('Refresh buffs early (sec)', state.settings.ambuscade.song_refresh_margin, 5, 45)) then ctx.save(); end
    if (imgui.SliderInt('Heal below HP%', state.settings.ambuscade.heal_below, 20, 80)) then ctx.save(); end
    if (imgui.SliderInt('Combat debuff duration (sec)', state.settings.ambuscade.combat_debuff_duration,
        15, 180)) then ctx.save(); end
    if (imgui.BeginCombo('Weaponskill TP', ('%d TP'):fmt(state.settings.ambuscade.weapon_skill_tp[1]))) then
        for _, value in ipairs({ 1000, 2000, 3000 }) do
            if (imgui.Selectable(('%d TP'):fmt(value), state.settings.ambuscade.weapon_skill_tp[1] == value)) then
                state.settings.ambuscade.weapon_skill_tp[1] = value;
                ctx.save(); ctx.wake();
            end
        end
        imgui.EndCombo();
    end
    if (imgui.SliderInt('Shantotto II sync TP', state.settings.ambuscade.shantotto_sync_tp, 750, 1000)) then
        ctx.save();
    end
    if (imgui.SliderFloat('Maximum WS sync wait', state.settings.ambuscade.ws_sync_wait, 0, 10, '%.1f sec')) then
        ctx.save();
    end
    imgui.PopItemWidth();
    imgui.TextWrapped('Weapon skills use the Ambuscade policy: Qultada acts first, then Shantotto II synchronization, bounded by the maximum wait.');
    imgui.Separator();
    imgui.Text('Distant attacker recovery');
    if (imgui.Checkbox('Approach distant attackers', state.settings.afk_recovery.enabled)) then
        ctx.save(); ctx.wake();
    end
    if (imgui.Checkbox('Use navmesh pathfinding', state.settings.afk_recovery.use_pathfinding)) then
        ctx.save(); ctx.wake();
    end
    if (imgui.Checkbox('Try pull spell before approaching', state.settings.afk_recovery.use_pull_spell)) then
        ctx.save(); ctx.wake();
    end
    imgui.PushItemWidth(130);
    if (imgui.SliderFloat('Approach stop distance', state.settings.afk_recovery.stop_distance, 2.41, 10, '%.2f yalms')) then
        ctx.save();
    end
    if (imgui.SliderFloat('Maximum approach time', state.settings.afk_recovery.max_time, 3, 20, '%.1f sec')) then
        ctx.save();
    end
    if (imgui.SliderInt('Party-claimed scan range', state.settings.afk_recovery.party_claim_range, 5, 50)) then
        ctx.save();
    end
    imgui.PopItemWidth();
    if (imgui.Checkbox('Adopt mobs claimed by party or trusts', state.settings.afk_recovery.adopt_party_claims)) then
        ctx.save(); ctx.wake();
    end
    local nav_status = ctx.afk_navigation_status();
    imgui.TextWrapped(('Navmesh: %s | mode: %s | last query: %s | waypoints: %s'):fmt(
        nav_status.loaded and 'loaded' or 'not loaded', tostring(nav_status.mode or 'unresolved'),
        tostring(nav_status.result or 'none'), tostring(nav_status.waypoint_count or 0)));
    if (imgui.Button('Test path to current target', { 210, 0 })) then
        local _, message = ctx.afk_test_navigation_path();
        state.status = 'AFK navigation: ' .. message;
    end
    imgui.TextWrapped('Navmesh movement is used when a mesh exists; direct follow is the fallback. Movement stops if distance is not decreasing.');
    imgui.Separator();
    imgui.Text('Combat diagnostics');
    if (imgui.Checkbox('Record all combat packets', state.settings.afk_packet_log.enabled)) then
        ctx.save(); ctx.afk_sync_packet_log();
    end
    imgui.TextWrapped('Records incoming and outgoing packet metadata and full raw hex. Logs can grow quickly.');
    local packet_path = ctx.afk_packet_log_path();
    imgui.TextWrapped(packet_path ~= '' and ('Log: ' .. packet_path) or 'Log starts when combat is detected.');
    imgui.Separator();
    imgui.Text('Automatic pull while out of combat');
    if (imgui.Checkbox('Enable automatic pull', state.settings.afk_pull.enabled)) then ctx.save(); ctx.wake(); end
    if (imgui.Button('Scan nearby mobs', { 150, 0 })) then ctx.afk_scan_nearby(); end
    local selected_mob = state.settings.afk_pull.mob_name[1];
    if (imgui.BeginCombo('Mob name', selected_mob ~= '' and selected_mob or 'Select a nearby mob')) then
        for _, name in ipairs(ctx.afk_nearby_mobs()) do
            if (imgui.Selectable(name, selected_mob == name)) then
                state.settings.afk_pull.mob_name[1] = name; ctx.save(); ctx.wake();
            end
        end
        imgui.EndCombo();
    end
    imgui.TextWrapped('Pull search cycles through the scanned names: the selected primary gets three tries, the second name gets two, and every remaining name gets one before returning to the primary.');
    imgui.PushItemWidth(130);
    if (imgui.SliderInt('Scan range (yalms)', state.settings.afk_pull.range, 5, 50)) then ctx.save(); end
    imgui.PopItemWidth();
end

function M.render(ctx)
    local state = ctx.state;
    if (not state.settings.visible[1]) then return; end
    imgui.SetNextWindowSize({ 390, 0 }, ImGuiCond_FirstUseEver);
    if (imgui.Begin('SmartSkillup', state.settings.visible,
        bit.bor(ImGuiWindowFlags_AlwaysAutoResize, ImGuiWindowFlags_NoCollapse))) then
        imgui.TextColored(state.active and { .3, 1, .4, 1 } or { .8, .8, .8, 1 }, state.status);
        if (state.last_spell ~= '') then imgui.Text('Last: ' .. state.last_spell); end
        if (state.pending_action ~= nil) then
            imgui.TextDisabled(('Action in flight: %s'):fmt(state.pending_action.name or state.pending_action.key));
        elseif (state.last_action_outcome ~= nil) then
            imgui.TextDisabled(('Action result: %s (%s)'):fmt(
                state.last_action_outcome.name or state.last_action_outcome.key,
                state.last_action_outcome.status));
        end
        imgui.Separator(); mode_selector(ctx, state);
        if (state.settings.mode[1] == 1) then rotation_panel(ctx, state);
        elseif (state.settings.mode[1] == 2) then command_panel(ctx, state);
        elseif (state.settings.mode[1] == 3) then ambuscade_panel(ctx, state);
        else
            imgui.BeginChild('##afk_settings', { 0, 460 }, ImGuiChildFlags_Borders);
            afk_panel(ctx, state);
            imgui.EndChild();
        end
        imgui.Separator();
        if (not state.active) then
            if (imgui.Button('Start', { 90, 0 })) then ctx.start(); end
        else
            if (imgui.Button('Stop', { 90, 0 })) then ctx.stop('Skill-up session stopped.'); end
            imgui.SameLine();
            if (imgui.Button(state.paused and 'Resume' or 'Pause', { 90, 0 })) then
                ctx.pause(not state.paused);
            end
        end
        if (state.settings.mode[1] == 1) then imgui.SameLine(); if (imgui.Button('Refresh Actions', { 120, 0 })) then ctx.refresh(); end end
        if (state.settings.mode[1] == 1 or state.settings.mode[1] == 2) then
            imgui.PushItemWidth(130);
            local minimum = state.settings.mode[1] == 2 and .1 or 2.5;
            if (imgui.SliderFloat(state.settings.mode[1] == 2 and 'Command interval (sec)' or 'Action delay (sec)',
                state.settings.delay, minimum, 30, '%.1f')) then ctx.save(); end
            if (state.settings.mode[1] == 1) then
                if (imgui.SliderInt('MP cost limit (0=off)', state.settings.mp_limit, 0, 100)) then ctx.save(); end
                if (imgui.SliderInt('Rest below MP% (0=off)', state.settings.rest_below, 0, 50)) then ctx.save(); end
                if (imgui.SliderInt('Resume above MP%', state.settings.resume_above, 25, 100)) then ctx.save(); end
            end
            imgui.PopItemWidth();
        end
    end
    imgui.End();
end

return M;
