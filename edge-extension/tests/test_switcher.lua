-- Run with a Lua 5.4 interpreter: lua tests/test_switcher.lua ../init.lua
local configPath = arg and arg[1] or "../init.lua"
local screenFrame = { x = 0, y = 0, w = 1600, h = 1000 }
local windowFrame = { x = 100, y = 100, w = 1000, h = 700 }
local modifiers = { alt = true }
local clock = 100
local timers, sent, hotkeys = {}, {}, {}
local frontmostEdge = true
local windowOwnerEdge = true
local focusedWindowAvailable = true
local edgeApplication = { bundleID = function() return "com.microsoft.edgemac" end,
    name = function() return "Microsoft Edge" end }
local otherApplication = { bundleID = function() return "other" end,
    name = function() return "Other" end }
local screen = { frame = function() return screenFrame end }
local window = { screen = function() return screen end, frame = function() return windowFrame end,
    application = function() return windowOwnerEdge and edgeApplication or otherApplication end }
local navigationCallback, applicationCallback
local function object()
    return setmetatable({}, { __index = function(_, key)
        return function(self, value)
            if key == "send" then table.insert(sent, value) end
            return self
        end
    end })
end
local function timer(interval, callback)
    local t = { interval = interval, callback = callback, stopped = false }
    function t:stop() self.stopped = true end
    table.insert(timers, t)
    return t
end
local keys = { escape = 53, left = 123, right = 124, up = 126, down = 125, tab = 48, a = 0 }
for i = 1, 9 do keys[tostring(i)] = i + 60 end
local keyNames = {}
for key, code in pairs(keys) do keyNames[code] = key end
for code, key in pairs(keyNames) do keys[code] = key end
hs = {
    dockicon = { hide = function() end },
    image = { imageFromAppBundle = function() return "edge-icon" end,
        imageFromURL = function(url) return "decoded:" .. url end },
    application = { frontmostApplication = function()
        return frontmostEdge and edgeApplication or otherApplication
    end, watcher = { activated = 1, deactivated = 2, new = function(callback)
        applicationCallback = callback; return object()
    end } },
    timer = { secondsSinceEpoch = function() return clock end, doEvery = timer, doAfter = timer },
    window = { focusedWindow = function() if focusedWindowAvailable then return window end end },
    screen = { mainScreen = function() return screen end },
    canvas = { new = function(frame)
        local c = { bounds = frame }
        function c:frame(f) if f then self.bounds = f; return self end; return self.bounds end
        function c:replaceElements(elements) self.elements = elements end
        function c:elementAttribute(index, name, value) self.elements[index][name] = value end
        function c:show() self.visible = true end
        function c:hide() self.visible = false end
        function c:bringToFront() end
        return c
    end },
    eventtap = { checkKeyboardModifiers = function() return modifiers end,
        event = { types = { keyDown = 1, keyUp = 2, flagsChanged = 3 },
            properties = { keyboardEventAutorepeat = 1 } },
        new = function(_, callback) navigationCallback = callback; return object() end },
    keycodes = { map = keys },
    hotkey = { new = function(mods, key, callback)
        local hotkey = { mods = mods, key = key, callback = callback, enabled = false }
        function hotkey:enable() self.enabled = true; return self end
        function hotkey:disable() self.enabled = false; return self end
        table.insert(hotkeys, hotkey)
        return hotkey
    end,
        bind = function() end },
    httpserver = { new = object },
    json = { encode = function(payload) return payload end },
    caffeinate = { watcher = { new = object } },
    alert = { show = function() end },
    osascript = { applescript = function() error("Unexpected AppleScript fallback") end },
}
local file = assert(io.open(configPath))
local source = file:read("*a"); file:close()
local testExports = [[
return {
    begin = handleOptionTab, finish = finishSwitch, payload = handleBridgePayload,
    state = function() return switching, selectedIndex, overlay, overlayCardElements,
        overlayResizeTimer, optionReleaseTimer, recentTabs, faviconImages end,
}
]]
local tool = assert(load(source .. testExports, "@" .. configPath))()
local function fixture(count)
    tool.finish(true)
    local tabs = {}
    for i = 1, count do
        tabs[i] = { tabId = i, windowId = 1, index = i - 1,
            title = "Tab " .. i, url = "https://example.com/" .. i }
    end
    tool.payload({ type = "settings", maxTabs = count, tabScope = "current" })
    tool.payload({ type = "mruSnapshot", tabs = tabs })
    tool.payload({ type = "focusedWindow", windowId = 1 })
    modifiers.alt = true
    tool.begin(1)
end
local function event(key, eventType, flags, repeatKey)
    return navigationCallback({ getKeyCode = function() return keys[key] end,
        getType = function() return eventType or 1 end,
        getFlags = function() return flags or modifiers end,
        getProperty = function() return repeatKey and 1 or 0 end })
end
local function press(key, flags)
    local consumed = event(key, 1, flags)
    local consumedUp = event(key, 2, flags)
    return consumed, consumedUp
end
local function near(a, b) assert(math.abs(a - b) < 0.001, tostring(a) .. " != " .. tostring(b)) end
fixture(9)
local switching, selected, overlay, refs, resizeTimer, releaseTimer = tool.state()
assert(switching and selected == 2 and overlay.visible)
local consumed, consumedUp = press("9")
assert(consumed and consumedUp)
local _, index = tool.state(); assert(index == 9)
modifiers.alt = false; releaseTimer.callback()
assert(#sent == 1 and sent[1].tabId == 9)
assert(resizeTimer.stopped and releaseTimer.stopped and not overlay.visible)
fixture(9)
local before = #sent
local _, _, _, _, cancelledResize, cancelledRelease, mru = tool.state()
assert(press("escape"))
assert(not tool.state() and #sent == before and mru[1].edgeTabID == "1")
assert(cancelledResize.stopped and cancelledRelease.stopped)
modifiers.alt = false; cancelledRelease.callback(); assert(#sent == before)
assert(not press("right"), "Arrow leaked into overlay when it is closed")

fixture(9)
assert(not press("a"))
assert(not press("right", { alt = true, cmd = true }))
press("1"); press("left"); local _, last = tool.state(); assert(last == 9, "Left from first selected " .. tostring(last))
press("right"); local _, first = tool.state(); assert(first == 1)
press("up"); local _, top = tool.state(); assert(top == 1)
press("down"); local _, lower, _, grid = tool.state(); assert(grid[lower].row == grid[1].row + 1)

-- The panel responds to a resized window while preserving the chosen tab.
local _, oldIndex, panel, _, liveResize = tool.state()
windowFrame = { x = 300, y = 200, w = 600, h = 450 }
liveResize.callback()
local _, newIndex = tool.state(); assert(newIndex == oldIndex)
near(panel.bounds.w, 600 * 0.88); near(panel.bounds.h, 450 * 0.80)
near(panel.bounds.x, 300 + 600 * 0.06); near(panel.bounds.y, 200 + 450 * 0.10)

-- Exercise every supported tab count over small, wide, tall and full-size windows.
for _, size in ipairs({ {480, 320}, {700, 950}, {1300, 400}, {1600, 1000} }) do
    windowFrame = { x = 0, y = 0, w = size[1], h = size[2] }
    for count = 2, 25 do
        fixture(count)
        local _, _, canvas, cards = tool.state()
        assert(#cards == count)
        for _, element in ipairs(canvas.elements) do
            assert(element.frame.w > 0 and element.frame.h > 0)
            assert(element.frame.x >= 0 and element.frame.y >= 0)
            assert(element.frame.x + element.frame.w <= canvas.bounds.w + 0.001)
            assert(element.frame.y + element.frame.h <= canvas.bounds.h + 0.001)
        end
        for index, card in ipairs(cards) do
            press(tostring(1))
            -- Select via the real navigation path, including cards beyond 9.
            for _ = 2, index do press("right") end
            press("down")
            local _, target = tool.state()
            local best = math.huge
            for _, candidate in ipairs(cards) do
                if candidate.row == card.row + 1 then
                    best = math.min(best, math.abs(candidate.centerX - card.centerX))
                end
            end
            if best == math.huge then assert(target == index)
            else near(math.abs(cards[target].centerX - card.centerX), best) end
        end
    end
end
windowFrame = { x = -100, y = 0, w = 600, h = 500 }
fixture(5)
local _, _, clipped = tool.state()
assert(clipped.bounds.x >= 0 and clipped.bounds.x + clipped.bounds.w <= 500)

-- An asynchronously delivered favicon updates its card and ignores unknown tabs.
local _, _, iconPanel, iconRefs = tool.state()
local iconData = "data:image/png;base64,aWNvbg=="
tool.payload({ type = "favicon", tabId = 2, dataUrl = iconData })
assert(iconPanel.elements[iconRefs[2].icon].image == "decoded:" .. iconData)
tool.payload({ type = "favicon", tabId = 999, dataUrl = iconData })
local _, _, _, _, _, _, _, icons = tool.state(); assert(icons[999] == nil)
tool.payload({ type = "mruSnapshot", tabs = { { tabId = 1, windowId = 1, title = "one", url = "https://one" } } })
assert(icons[2] == nil)

frontmostEdge = false
applicationCallback("Other", 1)
assert(not tool.state() and not iconPanel.visible)

-- The restored version uses the original Hammerspoon Option+Tab hotkeys,
-- enabled by frontmost-app notifications rather than per-key window checks.
assert(#hotkeys == 2)
assert(hotkeys[1].key == "tab" and hotkeys[1].mods[1] == "alt")
assert(hotkeys[2].key == "tab" and hotkeys[2].mods[2] == "shift")
assert(not hotkeys[1].enabled and not hotkeys[2].enabled)
frontmostEdge = true
applicationCallback("Microsoft Edge", 1, edgeApplication)
assert(hotkeys[1].enabled and hotkeys[2].enabled)
fixture(9); tool.finish(true)
hotkeys[1].callback()
local open, forward = tool.state()
assert(open and forward == 2)
hotkeys[2].callback()
local _, reverse = tool.state(); assert(reverse == 1)
assert(not press("tab", { ctrl = true }), "Control+Tab should remain native")

-- Losing a focused-window accessibility result does not cancel an open
-- switcher in this version as long as Option remains held.
local _, _, panel, _, _, release = tool.state()
focusedWindowAvailable = false
release.callback()
assert(tool.state() and panel.visible)
focusedWindowAvailable = true
modifiers.alt = false
release.callback()
assert(not tool.state() and not panel.visible)

frontmostEdge = false
applicationCallback("Other", 1, otherApplication)
assert(not hotkeys[1].enabled and not hotkeys[2].enabled)
print("Lua behavior checks passed: original Option+Tab hotkeys, release, cancellation, navigation, resize, and icons")
