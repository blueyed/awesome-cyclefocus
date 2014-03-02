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
--     screen         = screen
}


-- Configuration. This can be overridden.
local cyclefocus = {
    -- Should clients be raised during cycling? (overrides focus_clients)
    raise_clients = true,
    -- Should clients be focused during cycling? (overridden by raise_clients)
    focus_clients = true,

    -- Preset to be used for the notification.
    naughty_preset = {
        position = 'bottom_left',
        timeout = 0,
        font = "Ubuntu Regular 14",
        icon_size = 32,
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
                    cyclefocus.debug("Filter: client shares tag '" .. t.name .. " with " .. c.name)
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
    debug("history.add: " .. c.name, 2)
    if cyclefocus.filter_focus_history then
        if not cyclefocus.filter_focus_history(c) then
            debug("Filtered!" .. c.name, 2)
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
        debug("Ignoring focus signal: " .. c.name, 3)
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
    -- NOTE: making a copy here to break the reference, otherwise the default
    -- would be changed via args.cycle_filter below.
    local cycle_filters = args.cycle_filters or awful.util.table.join(cyclefocus.cycle_filters)

    -- Support single filter
    if args.cycle_filter then
        table.insert(cycle_filters, args.cycle_filter)
    end

    -- Set flag to ignore any focus events while cycling through clients.
    ignore_focus_signal = true

    -- Internal state.
    local orig_client = capi.client.focus  -- Will be jumped to via Escape (abort).
    local idx = 1                          -- Currently focused client in the stack.
    local next_notification                -- The notification to be displayed.

    --- Helper function to get the next client.
    -- @param direction 1 (forward) or -1 (backward).
    -- @return client or nil
    local get_next_client = function(direction)
        local startidx = idx
        local nextc
        while true do
            debug('find loop: #' .. idx, 3)
            idx = idx + direction
            if idx < 1 then
                idx = #history.stack
            elseif idx > #history.stack then
                idx = 1
            end
            nextc = history.stack[idx]

            if nextc then
                -- Filtering.
                if cycle_filters then
                    for _k, filter in pairs(cycle_filters) do
                        if not filter(nextc, args.initiating_client) then
                            debug("Filtering/skipping client: " .. nextc.name, 3)
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
            if startidx == idx then
                debug("No (other) client found!", 1)
                return nil
            end
            -- debug("Invalid next client: " .. tostring(nextc), 3)
        end
        debug("get_next_client returns: " .. tostring(nextc), 3)
        return nextc
    end

    local first_run = true
    local nextc
    capi.keygrabber.run(function(mod, key, event)
        -- Helper function to exit out of the keygrabber.
        -- If a client is given, it will be jumped to.
        local exit_grabber = function (c)
            debug("exit_grabber: " .. tostring(c), 2)
            if c then
                awful.client.jumpto(c)
                history.add(c)
            end
            if next_notification then
                naughty.destroy(next_notification)
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
            return exit_grabber(first_run and get_next_client(direction) or nextc)
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

        nextc = get_next_client(direction)
        if not nextc then
            return exit_grabber()
        end

        -- Create notification with index, name and screen.
        -- local tags = {}
        -- for _, tag in pairs(nextc:tags()) do
        --     table.insert(tags, tag.name)
        -- end
        local notification_args = {
            -- TODO: make this configurable using placeholders.
            text = "[" .. idx .. "/" .. #history.stack .. "] "
                .. nextc.name .. " [screen " .. nextc.screen .. "]"
                -- .. ", [tags " .. table.concat(tags, ", ") .. "]"
                ,
            preset = awful.util.table.join({
                icon = gears.surface.load(nextc.icon), -- prevents memory leaking
            }, cyclefocus.naughty_preset)
        }
        -- Replace previous notification, if any.
        if next_notification then
            notification_args.replaces_id = next_notification.id
        end
        next_notification = naughty.notify(notification_args)

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
