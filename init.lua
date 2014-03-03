--- Cycle through recently focused clients (Alt-Tab and more).
--
-- Author: http://daniel.hahler.de
-- Github: https://github.com/blueyed/awesome-cyclefocus

local awful        = require('awful')
-- local setmetatable = setmetatable
local naughty      = require("naughty")
local table        = table
local tostring     = tostring
local gears        = require('gears')
local capi         = {
--     tag            = tag,
    client         = client,
    keygrabber     = keygrabber,
--     mousegrabber   = mousegrabber,
--     mouse          = mouse,
    screen         = screen
}


-- Configuration. This can be overridden.
local cyclefocus
cyclefocus = {
    -- Should clients be raised during cycling? (overrides focus_clients)
    raise_clients = false,
    -- Should clients be focused during cycling? (overridden by raise_clients)
    focus_clients = true,

    -- Preset to be used for the notification.
    naughty_preset = {
        position = 'top_left',
        timeout = 0,
        font = "sans 14",
        icon_size = 48,
    },

    naughty_preset_for_offset = {
        -- Default callback, which will be applied for all offsets.
        default = function (preset, args)
            preset.icon = gears.surface.load(args.client.icon) -- using gears prevents memory leaking
            preset.screen = 1

            local s = preset.screen
            local wa = capi.screen[s].workarea
            preset.width = wa.width * 0.618
        end,

        ["-1"] = function (preset, args)
            preset.text = cyclefocus.get_object_name(args.client)
            preset.font = 'sans 10'
            -- preset.icon_size = 32
        end,
        ["0"] = function (preset, args)
            -- Use get_object_name to handle .name=nil.
            preset.text = cyclefocus.get_object_name(args.client)
                    .. " [screen " .. args.client.screen .. "]"
                    .. " [" .. args.idx .. "/" .. args.total .. "] "
            -- XXX: Makes awesome crash:
            -- preset.text = '<span gravity="auto">' .. preset.text .. '</span>'
            preset.text = '<b>' .. preset.text .. '</b>'
        end,
        ["1"] = function (preset, args)
            preset.text = cyclefocus.get_object_name(args.client)
            preset.font = 'sans 10'
            -- preset.icon_size = 32
        end
    },

    cycle_filters = {},

    -- The filter to ignore clients altogether (get not added to the history stack).
    -- This is different from the cycle_filters.
    filter_focus_history = awful.client.focus.filter,

    debug_level = 0,  -- 1: normal debugging, 2: verbose, 3: very verbose.
}

-- A set of default filters, which can be used for cyclefocus.cycle_filters.
cyclefocus.filters = {
    -- Filter clients on the same screen.
    same_screen = function (c, source_c) return c.screen == source_c.screen end,

    common_tag  = function (c, source_c)
        for _, t in pairs(c:tags()) do
            for _, t2 in pairs(source_c:tags()) do
                if t == t2 then
                    cyclefocus.debug("Filter: client shares tag '"
                        .. cyclefocus.get_object_name(t)
                        .. " with " .. cyclefocus.get_object_name(c))
                    return true
                end
            end
        end
        return false
    end
}

local ignore_focus_signal = false  -- Flag to ignore the focus signal internally.


-- Debug function. Set focusstyle.debug to activate it. {{{
local debug = function(s, level)
    local level = level or 1
    if not cyclefocus.debug_level or cyclefocus.debug_level < level then
        return
    end
    naughty.notify({
        text = s,
        timeout = 10,
        font = "monospace 10",
    })
end
cyclefocus.debug = debug  -- Used as reference in the filters above.

local get_object_name = function (o)
    if not o then
        return '<no object>'
    elseif not o.name then
        return '<no object name>'
    else
        return o.name
    end
end
cyclefocus.get_object_name = get_object_name
-- }}}


-- Internal functions to handle the focus history. {{{
-- Based upon awful.client.focus.history.
local history = {
    stack = {}
}
function history.delete(c)
    for k, v in ipairs(history.stack) do
        if v == c then
            table.remove(history.stack, k)
            break
        end
    end
end
function history.add(c)
    -- NOTE: c.name could be nil!
    debug("history.add: " .. get_object_name(c), 2)
    if cyclefocus.filter_focus_history then
        if not cyclefocus.filter_focus_history(c) then
            debug("Filtered! " .. get_object_name(c), 2)
            return true
        end
    end
    -- Remove the client if its in the stack
    history.delete(c)
    -- Record the client has latest focused
    table.insert(history.stack, 1, c)
end
-- }}}

-- Connect to signals. {{{
-- Add clients that got focused to the history stack,
-- but not when we are cycling through the clients ourselves.
client.connect_signal("focus", function (c)
    if ignore_focus_signal then
        debug("Ignoring focus signal: " .. get_object_name(c), 3)
        return false
    end
    history.add(c)
end)

-- Only manage clients during startup to fill the stack
-- initially. Later clients are handled via the "focus" signal.
client.connect_signal("manage", function (c, startup)
    if startup then
        history.add(c)
    end
end)
client.connect_signal("unmanage", function (c)
    history.delete(c)
end)
-- }}}

-- Main function.
cyclefocus.cycle = function(startdirection, args)
    local args = args or {}
    local modifier = args.modifier or 'Alt_L'
    local keys = args.keys or {'Tab', 'ISO_Left_Tab'}
    local shift = args.shift or 'Shift'
    -- cycle_filters: different from filter_focus_history!
    local cycle_filters = args.cycle_filters or cyclefocus.cycle_filters

    -- Support single filter.
    if args.cycle_filter then
        cycle_filters = awful.util.table.clone(cycle_filters)
        table.insert(cycle_filters, args.cycle_filter)
    end

    -- Set flag to ignore any focus events while cycling through clients.
    ignore_focus_signal = true

    -- Internal state.
    local orig_client = capi.client.focus  -- Will be jumped to via Escape (abort).
    local idx = 1                          -- Currently focused client in the stack.

    local notifications = {}

    --- Helper function to get the next client.
    -- @param direction 1 (forward) or -1 (backward).
    -- @return client or nil
    local get_next_client = function(direction, idx)
        local startidx = idx
        local nextc
        while true do
            debug('find loop: #' .. idx, 3)
            idx = awful.util.cycle(#history.stack, idx + direction)
            nextc = idx and history.stack[idx]

            if nextc then
                -- Filtering.
                if cycle_filters then
                    for _k, filter in pairs(cycle_filters) do
                        if not filter(nextc, args.initiating_client) then
                            debug("Filtering/skipping client: " .. get_object_name(nextc), 3)
                            nextc = nil
                            break
                        end
                    end
                end
                if nextc then
                    -- Found client to switch to.
                    break
                end
            end

            -- Abort after having looped through all clients once
            if not idx or startidx == idx then
                debug("No (other) client found!", 1)
                return nil
            end
        end
        debug("get_next_client returns: " .. get_object_name(nextc), 3)
        return nextc, idx
    end

    local first_run = true
    local nextc
    capi.keygrabber.run(function(mod, key, event)
        -- Helper function to exit out of the keygrabber.
        -- If a client is given, it will be jumped to.
        local exit_grabber = function (c)
            debug("exit_grabber: " .. get_object_name(c), 2)
            if c then
                awful.client.jumpto(c)
                history.add(c)
            end
            if notifications then
                for _, v in pairs(notifications) do
                    naughty.destroy(v)
                end
            end
            ignore_focus_signal = false
            capi.keygrabber.stop()
            return true
        end

        debug("grabber: mod: " .. table.concat(mod, ',')
            .. ", key: " .. key
            .. ", event: " .. event
            .. ", modifier: " .. modifier, 3)

        -- Abort on Escape.
        if key == 'Escape' then
            return exit_grabber(orig_client)
        end

        -- Direction (forward/backward) is determined by status of shift.
        local direction = awful.util.table.hasitem(mod, shift) and -1 or 1

        if event == "release" and key == modifier then
            -- Focus selected client when releasing modifier.
            -- When coming here on first run, the trigger was pressed quick and we need to fetch the next client while exiting.
            if first_run then
                nextc, idx = get_next_client(direction, idx)
            end
            return exit_grabber(nextc)
        end

        -- Ignore any "release" events and unexpected keys, except for the first run.
        if not first_run then
            if not awful.util.table.hasitem(keys, key) then
                debug("Ignoring unexpected key: " .. tostring(key), 2)
                return true
            end
            if event == "release" then
                return true
            end
        end
        first_run = false

        nextc, idx = get_next_client(direction, idx)
        if not nextc then
            return exit_grabber()
        end

        -- Create notification with index, name and screen.
        -- local tags = {}
        -- for _, tag in pairs(nextc:tags()) do
        --     table.insert(tags, tag.name)
        -- end
        -- IDEA: use a template for the text, and then create three notification, also for prev/next.

        local do_notification_for_idx_offset = function(offset, client)
            -- TODO: make this configurable using placeholders.
            local args = {}
            -- .. ", [tags " .. table.concat(tags, ", ") .. "]"

            -- Get naughty preset from naughty_preset, and callbacks.
            args.preset = awful.util.table.clone(cyclefocus.naughty_preset)

            -- Callback for offset.
            local args_for_cb = { client=client, offset=offset, idx=idx, total=#history.stack }

            local preset_for_offset = cyclefocus.naughty_preset_for_offset
            local preset_cb = preset_for_offset[tostring(offset)]
            if preset_cb then
                preset_cb(args.preset, args_for_cb)
            end
            -- Callback for all.
            if preset_for_offset.default then
                preset_for_offset.default(args.preset, args_for_cb)
            end

            -- Replace previous notification, if any.
            if notifications[tostring(offset)] then
                args.replaces_id = notifications[tostring(offset)].id
            end

            notifications[tostring(offset)] = naughty.notify({
                text=args.preset.text,
                preset=args.preset
            })
        end

        -- Delete existing notifications, replaces_id does not appear to work. Must be sequential maybe?!
        if notifications then
            for _, v in pairs(notifications) do
                naughty.destroy(v)
            end
        end
        local had_client = {}  -- Remember displayed clients, to display them only once.
        for i=-1, 1 do
            local _client
            if i == 0 then
                _client = nextc
            else
                _client = get_next_client(i, idx)
                if _client == nextc then
                    _client = false
                end
            end
            if _client and not awful.util.table.hasitem(had_client, _client) then
                do_notification_for_idx_offset(i, _client)
                table.insert(had_client, _client)
            end
        end

        -- Raise or focus next client.
        if cyclefocus.raise_clients then
            awful.client.jumpto(nextc)
        elseif cyclefocus.focus_clients then
            client.focus = nextc
        end

        -- return false  -- bubble up?!
        return true
    end)
end


-- A helper method to wrap awful.key.
function cyclefocus.key(mods, key, startdirection, _args)
    local mods = mods or {modkey} or {"Mod4"}
    local key = key or "Tab"
    local startdirection = startdirection or 1
    local args = _args or {}
    args.keys = args.keys or {key}
    args.mods = args.mods or mods

    return awful.key(mods, key, function(c)
        args.initiating_client = c  -- only for clientkeys, might be nil!
        cyclefocus.cycle(startdirection, args)
    end)
end

return cyclefocus
