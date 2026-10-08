------------------------------------------------------------
-- Edge MRU Tab Switcher
-- Window-scoped MRU + cached previews + wake recovery
------------------------------------------------------------

hs.dockicon.hide()

------------------------------------------------------------
-- Config
------------------------------------------------------------

local MAX_TABS = 9
local MIN_TABS = 2
local HISTORY_LIMIT = 100
local PREVIEW_CACHE_LIMIT = 50
local FAVICON_CACHE_LIMIT = 100
local TAB_SCOPE = "current" -- "current" or "all"
local OVERLAY_WINDOW_WIDTH = 0.88
local OVERLAY_WINDOW_HEIGHT = 0.80

local BRIDGE_PORT = 27123
local BRIDGE_TOKEN = "__EDGE_MRU_LOCAL_TOKEN__"
local BRIDGE_HEALTH_SECONDS = 12

------------------------------------------------------------
-- State
------------------------------------------------------------

local recentTabs = {}
local previewImages = {}
local previewLastUsed = {}
local previewUseSerial = 0
local activeEdgeWindowID = nil
local faviconImages = {}
local fallbackIcon = hs.image.imageFromAppBundle("com.microsoft.edgemac")

local switching = false
local switchChoices = {}
local selectedIndex = 1

local overlay = nil
local overlayCardElements = {}
local overlayItemCount = 0
local overlayHostWindow = nil
local overlayResizeTimer = nil
local navigationTap = nil
local swallowedKeys = {}

local optionReleaseTimer = nil
local optionTabHotkey = nil
local optionShiftTabHotkey = nil
local appWatcher = nil
local wakeWatcher = nil
local wakeRecoveryTimer = nil

local bridgeServer = nil
local bridgeSocketLastSeen = 0
local pendingSwitch = nil
local pendingSwitchTimer = nil
local requestCounter = 0
local restoredMruSnapshot = false
local seedTask = nil

local US = string.char(31)
local RS = string.char(30)

------------------------------------------------------------
-- Helpers
------------------------------------------------------------

local function cleanText(s)
    s = tostring(s or "")
    s = s:gsub("\r", " ")
    s = s:gsub("\n", " ")
    return s
end

local function splitPlain(str, sep)
    local out = {}
    local start = 1
    while true do
        local i, j = string.find(str, sep, start, true)
        if not i then
            table.insert(out, string.sub(str, start))
            break
        end
        table.insert(out, string.sub(str, start, i - 1))
        start = j + 1
    end
    return out
end

local function edgeIsFrontmost()
    local app = hs.application.frontmostApplication()
    if not app then return false end
    return app:bundleID() == "com.microsoft.edgemac"
        or app:name() == "Microsoft Edge"
end

local function nowSeconds()
    return hs.timer.secondsSinceEpoch()
end

local function makeKey(tab)
    if tab.edgeTabID and tostring(tab.edgeTabID) ~= "" then
        return "edge:" .. tostring(tab.edgeTabID)
    end
    return tostring(tab.url or "") .. "\n" .. tostring(tab.text or "")
end

local function normalizeTab(tab)
    if not tab then return nil end
    tab.edgeTabID = tab.edgeTabID and tostring(tab.edgeTabID) or nil
    tab.edgeWindowID = tab.edgeWindowID and tostring(tab.edgeWindowID) or nil
    tab.edgeIndex = tonumber(tab.edgeIndex)
    tab.text = cleanText(tab.text)
    tab.subText = cleanText(tab.subText)
    tab.url = cleanText(tab.url)
    tab.key = makeKey(tab)
    return tab
end

------------------------------------------------------------
-- MRU
--
-- A single chronological list is retained, but each entry carries the
-- Chromium windowId. Filtering by window preserves each window's own MRU
-- order while also supporting an optional all-windows mode.
------------------------------------------------------------

local function bumpRecent(tab)
    tab = normalizeTab(tab)
    if not tab then return end

    local newList = { tab }

    for _, oldTab in ipairs(recentTabs) do
        local sameTab = oldTab.key == tab.key

        if not sameTab
            and tab.edgeTabID
            and not oldTab.edgeTabID
            and oldTab.url == tab.url
            and oldTab.text == tab.text
        then
            sameTab = true
        end

        if not sameTab then
            table.insert(newList, oldTab)
            if #newList >= HISTORY_LIMIT then break end
        end
    end

    recentTabs = newList
end

local function removeEdgeTab(edgeTabID)
    edgeTabID = tostring(edgeTabID or "")
    if edgeTabID == "" then return end

    local newList = {}
    for _, tab in ipairs(recentTabs) do
        if tostring(tab.edgeTabID or "") ~= edgeTabID then
            table.insert(newList, tab)
        end
    end
    recentTabs = newList
    previewImages[edgeTabID] = nil
    previewLastUsed[edgeTabID] = nil
    faviconImages[edgeTabID] = nil
end

local function applyMruSnapshot(items)
    if type(items) ~= "table" then return end

    local restored = {}
    for _, item in ipairs(items) do
        if type(item) == "table" then
            local tab = normalizeTab({
                edgeTabID = item.tabId,
                edgeWindowID = item.windowId,
                edgeIndex = item.index,
                text = item.title ~= "" and item.title or item.url,
                subText = item.url,
                url = item.url,
            })
            if tab and tab.edgeTabID and tab.url ~= "" then
                table.insert(restored, tab)
                if #restored >= HISTORY_LIMIT then break end
            end
        end
    end

    if #restored > 0 then
        recentTabs = restored
        restoredMruSnapshot = true

        local keep = {}
        for _, tab in ipairs(restored) do
            if tab.edgeTabID then keep[tab.edgeTabID] = true end
        end
        for tabId, _ in pairs(previewImages) do
            if not keep[tabId] then
                previewImages[tabId] = nil
                previewLastUsed[tabId] = nil
            end
        end
        for tabId, _ in pairs(faviconImages) do
            if not keep[tabId] then faviconImages[tabId] = nil end
        end
    end
end

local function choicesForCurrentScope()
    local out = {}

    for _, tab in ipairs(recentTabs) do
        local include = true

        if TAB_SCOPE == "current" and activeEdgeWindowID then
            include = tostring(tab.edgeWindowID or "") == tostring(activeEdgeWindowID)
        end

        if include then
            table.insert(out, tab)
            if #out >= MAX_TABS then break end
        end
    end

    -- During the brief startup window before the extension has restored
    -- Chromium windowIds, legacy AppleScript seed rows cannot be mapped to a
    -- Chrome window. Fall back to global MRU rather than making the hotkey dead.
    if #out == 0 and TAB_SCOPE == "current" and #recentTabs > 0 then
        for i = 1, math.min(#recentTabs, MAX_TABS) do
            table.insert(out, recentTabs[i])
        end
    end

    return out
end

------------------------------------------------------------
-- Preview cache
--
-- Keep a hard LRU bound in Hammerspoon as well as in the Edge extension.
-- This prevents decoded hs.image objects from accumulating indefinitely
-- during very long browser sessions with many distinct Chromium tabIds.
------------------------------------------------------------

local function touchPreview(edgeTabID)
    edgeTabID = tostring(edgeTabID or "")
    if edgeTabID == "" or not previewImages[edgeTabID] then return end

    previewUseSerial = previewUseSerial + 1
    previewLastUsed[edgeTabID] = previewUseSerial
end

local function trimPreviewCache()
    local count = 0
    for _ in pairs(previewImages) do count = count + 1 end

    while count > PREVIEW_CACHE_LIMIT do
        local oldestTabID = nil
        local oldestUse = math.huge

        for tabId, _ in pairs(previewImages) do
            local used = previewLastUsed[tabId] or 0
            if used < oldestUse then
                oldestUse = used
                oldestTabID = tabId
            end
        end

        if not oldestTabID then break end

        previewImages[oldestTabID] = nil
        previewLastUsed[oldestTabID] = nil
        count = count - 1
    end
end

local function getPreviewImage(edgeTabID)
    edgeTabID = tostring(edgeTabID or "")
    if edgeTabID == "" then return nil end

    local image = previewImages[edgeTabID]
    if image then touchPreview(edgeTabID) end
    return image
end

local function applyThumbnail(edgeTabID, dataUrl)
    edgeTabID = tostring(edgeTabID or "")
    dataUrl = tostring(dataUrl or "")
    if edgeTabID == "" or dataUrl == "" then return end

    local ok, image = pcall(hs.image.imageFromURL, dataUrl)
    if not ok or not image then return end

    previewImages[edgeTabID] = image
    touchPreview(edgeTabID)
    trimPreviewCache()

    if overlay and switching then
        for i, tab in ipairs(switchChoices) do
            if tostring(tab.edgeTabID or "") == edgeTabID then
                local refs = overlayCardElements[i]
                if refs and refs.preview then
                    overlay:elementAttribute(refs.preview, "image", image)
                    overlay:elementAttribute(refs.preview, "imageAlpha", 1.0)
                    if refs.placeholder then
                        overlay:elementAttribute(refs.placeholder, "text", "")
                    end
                end
                break
            end
        end
    end
end

------------------------------------------------------------
-- Site icon cache
------------------------------------------------------------

local function applyFavicon(edgeTabID, dataUrl)
    edgeTabID = tostring(edgeTabID or "")
    if edgeTabID == "" or type(dataUrl) ~= "string"
        or not dataUrl:match("^data:image/png;base64,") or #dataUrl > 90000
    then return end

    local known = false
    for _, tab in ipairs(recentTabs) do
        if tostring(tab.edgeTabID or "") == edgeTabID then known = true; break end
    end
    if not known then return end
    local cached = faviconImages[edgeTabID]
    if cached and cached.dataUrl == dataUrl then return end
    local ok, image = pcall(hs.image.imageFromURL, dataUrl)
    if not ok or not image then return end
    faviconImages[edgeTabID] = { image = image, dataUrl = dataUrl }

    local count = 0
    for _ in pairs(faviconImages) do count = count + 1 end
    if count > FAVICON_CACHE_LIMIT then
        for id, _ in pairs(faviconImages) do
            if id ~= edgeTabID then faviconImages[id] = nil; break end
        end
    end
    if overlay and switching then
        for i, tab in ipairs(switchChoices) do
            if tostring(tab.edgeTabID or "") == edgeTabID then
                local refs = overlayCardElements[i]
                if refs and refs.icon then
                    overlay:elementAttribute(refs.icon, "image", image)
                    overlay:elementAttribute(refs.icon, "imageAlpha", 1.0)
                end
                break
            end
        end
    end
end

------------------------------------------------------------
-- AppleScript fallback
------------------------------------------------------------

local function appleScriptString(s)
    s = tostring(s or "")
    s = s:gsub("\\", "\\\\")
    s = s:gsub('"', '\\"')
    s = s:gsub("\r", " ")
    s = s:gsub("\n", " ")
    return '"' .. s .. '"'
end

local function activateEdgeTabFallback(choice)
    if not choice then return end

    local targetURL = appleScriptString(choice.url)
    local targetTitle = appleScriptString(choice.text)

    local script = string.format([[
tell application "Microsoft Edge"
    set targetURL to %s
    set targetTitle to %s

    repeat with w in windows
        repeat with i from 1 to count of tabs of w
            set t to tab i of w
            if (URL of t as text) = targetURL then
                if (title of t as text) = targetTitle then
                    set active tab index of w to i
                    set index of w to 1
                    activate
                    return true
                end if
            end if
        end repeat
    end repeat

    repeat with w in windows
        repeat with i from 1 to count of tabs of w
            set t to tab i of w
            if (URL of t as text) = targetURL then
                set active tab index of w to i
                set index of w to 1
                activate
                return true
            end if
        end repeat
    end repeat

    return false
end tell
]], targetURL, targetTitle)

    local ok, _, err = hs.osascript.applescript(script)
    if not ok then
        print("Edge MRU fallback switch failed: " .. hs.inspect(err))
    end
end

------------------------------------------------------------
-- Bridge
------------------------------------------------------------

local function bridgeHeaders()
    return {
        ["Content-Type"] = "text/plain; charset=utf-8",
        ["Access-Control-Allow-Origin"] = "*",
        ["Access-Control-Allow-Methods"] = "GET, POST, OPTIONS",
        ["Access-Control-Allow-Headers"] = "Content-Type",
        ["Access-Control-Allow-Private-Network"] = "true",
    }
end

local function clearPendingSwitch()
    if pendingSwitchTimer then
        pendingSwitchTimer:stop()
        pendingSwitchTimer = nil
    end
    pendingSwitch = nil
end

local function bridgeSocketIsReady()
    return bridgeSocketLastSeen > 0
        and (nowSeconds() - bridgeSocketLastSeen) <= BRIDGE_HEALTH_SECONDS
        and bridgeServer ~= nil
end

local function sendSocket(payload)
    if not bridgeServer then return false end
    local ok, encoded = pcall(hs.json.encode, payload)
    if not ok then return false end
    local sent = pcall(function() bridgeServer:send(encoded) end)
    return sent
end

local function activateEdgeTab(choice)
    if not choice then return end
    bumpRecent(choice)

    if choice.edgeWindowID then
        activeEdgeWindowID = tostring(choice.edgeWindowID)
    end

    if choice.edgeTabID and bridgeSocketIsReady() then
        requestCounter = requestCounter + 1
        local requestId = tostring(requestCounter) .. "-" .. tostring(math.floor(nowSeconds() * 1000))

        clearPendingSwitch()
        pendingSwitch = {
            requestId = requestId,
            choice = choice,
        }

        local ok = sendSocket({
            type = "switchTab",
            token = BRIDGE_TOKEN,
            requestId = requestId,
            tabId = tonumber(choice.edgeTabID),
            windowId = tonumber(choice.edgeWindowID),
        })

        if ok then
            pendingSwitchTimer = hs.timer.doAfter(0.25, function()
                if pendingSwitch and pendingSwitch.requestId == requestId then
                    local fallbackChoice = pendingSwitch.choice
                    clearPendingSwitch()
                    activateEdgeTabFallback(fallbackChoice)
                end
            end)
            return
        end
    end

    activateEdgeTabFallback(choice)
end

local function applySettings(payload)
    local maxTabs = tonumber(payload.maxTabs)
    if maxTabs then
        maxTabs = math.floor(maxTabs)
        if maxTabs < MIN_TABS then maxTabs = MIN_TABS end
        if maxTabs > 25 then maxTabs = 25 end
        MAX_TABS = maxTabs
    end

    local scope = tostring(payload.tabScope or "")
    if scope == "current" or scope == "all" then
        TAB_SCOPE = scope
    end
end

local function handleBridgePayload(payload)
    if type(payload) ~= "table" then return end

    if payload.type == "heartbeat" then
        bridgeSocketLastSeen = nowSeconds()
        return
    end

    if payload.type == "focusedWindow" then
        bridgeSocketLastSeen = nowSeconds()
        local id = tostring(payload.windowId or "")
        if id ~= "" and id ~= "-1" then activeEdgeWindowID = id end
        return
    end

    if payload.type == "settings" then
        bridgeSocketLastSeen = nowSeconds()
        applySettings(payload)
        return
    end

    if payload.type == "mruSnapshot" then
        bridgeSocketLastSeen = nowSeconds()
        applyMruSnapshot(payload.tabs)
        return
    end

    if payload.type == "thumbnail" then
        bridgeSocketLastSeen = nowSeconds()
        applyThumbnail(payload.tabId, payload.dataUrl)
        return
    end

    if payload.type == "favicon" then
        bridgeSocketLastSeen = nowSeconds()
        applyFavicon(payload.tabId, payload.dataUrl)
        return
    end

    if payload.type == "switchResult" then
        bridgeSocketLastSeen = nowSeconds()
        if pendingSwitch
            and tostring(payload.requestId or "") == tostring(pendingSwitch.requestId or "")
        then
            local choice = pendingSwitch.choice
            local success = payload.ok == true
            clearPendingSwitch()
            if not success then activateEdgeTabFallback(choice) end
        end
        return
    end
end

local function startBridge()
    if bridgeServer then
        bridgeServer:stop()
        bridgeServer = nil
    end

    bridgeSocketLastSeen = 0

    bridgeServer = hs.httpserver.new(false, false)
    bridgeServer:maxBodySize(10 * 1024 * 1024)
    bridgeServer:setInterface("127.0.0.1")
    bridgeServer:setPort(BRIDGE_PORT)

    bridgeServer:setCallback(function(method, path, headers, body)
        if method == "OPTIONS" then
            return "", 204, bridgeHeaders()
        end

        if method == "GET" and path == "/health" then
            return "edge-mru-ok", 200, bridgeHeaders()
        end

        if method ~= "POST" or path ~= "/edge-mru" then
            return "not found", 404, bridgeHeaders()
        end

        local ok, payload = pcall(hs.json.decode, body or "")
        if not ok or type(payload) ~= "table" then
            return "bad json", 400, bridgeHeaders()
        end

        if payload.token ~= BRIDGE_TOKEN then
            return "forbidden", 403, bridgeHeaders()
        end

        if payload.type == "removed" then
            removeEdgeTab(payload.tabId)
            return "ok", 200, bridgeHeaders()
        end

        if payload.type == "focusedWindow" then
            local id = tostring(payload.windowId or "")
            if id ~= "" and id ~= "-1" then activeEdgeWindowID = id end
            return "ok", 200, bridgeHeaders()
        end

        if payload.type == "activated"
            or payload.type == "updated"
            or payload.type == "focusChanged"
        then
            local url = cleanText(payload.url)
            local title = cleanText(payload.title)
            if url == "" then return "ignored", 200, bridgeHeaders() end

            local tab = {
                edgeTabID = tostring(payload.tabId or ""),
                edgeWindowID = tostring(payload.windowId or ""),
                edgeIndex = tonumber(payload.index),
                text = title ~= "" and title or url,
                subText = url,
                url = url,
            }
            bumpRecent(tab)

            if payload.windowFocused == true or payload.type == "focusChanged" then
                activeEdgeWindowID = tab.edgeWindowID
            end

            return "ok", 200, bridgeHeaders()
        end

        return "ignored", 200, bridgeHeaders()
    end)

    bridgeServer:websocket("/ws", function(message)
        bridgeSocketLastSeen = nowSeconds()
        local ok, payload = pcall(hs.json.decode, message or "")
        if ok and type(payload) == "table" then
            if not payload.token or payload.token == BRIDGE_TOKEN then
                handleBridgePayload(payload)
            end
        end
        return ""
    end)

    bridgeServer:start()
end

------------------------------------------------------------
-- AppleScript seed fallback
------------------------------------------------------------

local seedScript = [[
tell application "Microsoft Edge"
    set unitSep to ASCII character 31
    set recordSep to ASCII character 30
    set outputText to ""

    if (count of windows) is 0 then return outputText

    set maxTabs to 25
    set addedCount to 0

    repeat with w in windows
        if addedCount >= maxTabs then exit repeat
        set windowID to id of w
        set tabCount to count of tabs of w

        repeat with ti from 1 to tabCount
            if addedCount >= maxTabs then exit repeat
            set t to tab ti of w
            set outputText to outputText ¬
                & (windowID as text) & unitSep ¬
                & (ti as text) & unitSep ¬
                & (title of t as text) & unitSep ¬
                & (URL of t as text) & recordSep
            set addedCount to addedCount + 1
        end repeat
    end repeat

    return outputText
end tell
]]

local function seedRecentTabs()
    if restoredMruSnapshot then return end
    if seedTask and seedTask:isRunning() then return end

    seedTask = hs.task.new("/usr/bin/osascript", function(exitCode, stdout, stderr)
        seedTask = nil
        if restoredMruSnapshot or exitCode ~= 0 then return end

        local found = {}
        for _, record in ipairs(splitPlain(stdout or "", RS)) do
            local fields = splitPlain(record, US)
            if #fields >= 4 and cleanText(fields[4]) ~= "" then
                table.insert(found, normalizeTab({
                    windowID = tonumber(fields[1]),
                    tabIndex = tonumber(fields[2]),
                    text = cleanText(fields[3]),
                    subText = cleanText(fields[4]),
                    url = cleanText(fields[4]),
                }))
            end
        end

        if #found > 0 and not restoredMruSnapshot then
            recentTabs = found
        end
    end, { "-e", seedScript })

    if seedTask then seedTask:start() end
end

------------------------------------------------------------
-- UI helpers
------------------------------------------------------------

local function hideOverlay()
    if overlay then overlay:hide() end
end

local function deleteOverlay()
    if overlay then
        overlay:hide()
        overlay:delete()
        overlay = nil
    end
    overlayCardElements = {}
    overlayItemCount = 0
end

local function domainFromURL(url)
    url = tostring(url or "")
    local domain = url:match("^https?://([^/]+)")
    if domain then return domain:gsub("^www%.", "") end
    if url:match("^file://") then return "Local file" end
    if url:match("^edge://") then return "Microsoft Edge" end
    return url
end

local function cardFillColor(selected)
    if selected then return { white = 1.0, alpha = 0.26 } end
    return { white = 1.0, alpha = 0.0 }
end

local function cardStrokeColor(selected)
    return { white = 1.0, alpha = selected and 1.0 or 0.35 }
end

local function cardStrokeWidth(selected)
    return selected and 3.0 or 1.0
end

local function setCardSelected(index, selected)
    if not overlay then return end
    local refs = overlayCardElements[index]
    if not refs then return end

    overlay:elementAttribute(refs.rect, "fillColor", cardFillColor(selected))
    overlay:elementAttribute(refs.rect, "strokeColor", cardStrokeColor(selected))
    overlay:elementAttribute(refs.rect, "strokeWidth", cardStrokeWidth(selected))
end

local function updateOverlaySelection(oldIndex, newIndex)
    if oldIndex == newIndex then return end
    if oldIndex and oldIndex >= 1 and oldIndex <= overlayItemCount then
        setCardSelected(oldIndex, false)
    end
    if newIndex and newIndex >= 1 and newIndex <= overlayItemCount then
        setCardSelected(newIndex, true)
    end
end

local function overlayFrameForWindow()
    local win = overlayHostWindow or hs.window.focusedWindow()
    local screen = win and win:screen() or hs.screen.mainScreen()
    screen = screen or hs.screen.mainScreen()
    local sf = screen:frame()
    local wf = win and win:frame() or sf
    -- Keep the panel inside the visible part of a window spanning monitors.
    local left = math.max(wf.x, sf.x)
    local top = math.max(wf.y, sf.y)
    local right = math.min(wf.x + wf.w, sf.x + sf.w)
    local bottom = math.min(wf.y + wf.h, sf.y + sf.h)
    if right <= left or bottom <= top then
        left, top, right, bottom = sf.x, sf.y, sf.x + sf.w, sf.y + sf.h
    end
    local width = (right - left) * OVERLAY_WINDOW_WIDTH
    local height = (bottom - top) * OVERLAY_WINDOW_HEIGHT
    return { x = left + (right - left - width) / 2,
        y = top + (bottom - top - height) / 2, w = width, h = height }
end

local function showOverlay()
    if #switchChoices == 0 then return end

    local frame = overlayFrameForWindow()
    local width, height = frame.w, frame.h

    local itemCount = math.min(#switchChoices, MAX_TABS)
    local outerPad = math.min(14, width * 0.03, height * 0.04)
    local headerH = math.min(30, height * 0.08)
    local footerH = math.min(22, height * 0.06)
    local gap = math.min(8, width * 0.015, height * 0.015)

    if not overlay then overlay = hs.canvas.new(frame) else overlay:frame(frame) end

    local cardsTop = outerPad + headerH
    local usableW = width - outerPad * 2
    local usableH = height - cardsTop - outerPad - footerH
    -- Choose the grid that fits the window's aspect ratio with readable cards.
    local cols = 1
    local bestScore = math.huge
    for candidate = 1, itemCount do
        local candidateRows = math.ceil(itemCount / candidate)
        local cw = (usableW - gap * (candidate - 1)) / candidate
        local ch = (usableH - gap * (candidateRows - 1)) / candidateRows
        if cw > 0 and ch > 0 then
            local score = math.abs(math.log((cw / ch) / 1.65))
                + math.max(0, 150 - cw) / 50 + math.max(0, 100 - ch) / 40
                + (candidate * candidateRows - itemCount) * 0.04
            if score < bestScore then cols, bestScore = candidate, score end
        end
    end
    local rows = math.ceil(itemCount / cols)
    local cardW = (usableW - gap * (cols - 1)) / cols
    local cardH = (usableH - gap * (rows - 1)) / rows

    local elements = {}
    overlayCardElements = {}
    overlayItemCount = itemCount

    -- Mostly opaque backing keeps the overlay readable over page content.
    table.insert(elements, {
        type = "rectangle",
        action = "fill",
        frame = { x = 0, y = 0, w = width, h = height },
        roundedRectRadii = { xRadius = 14, yRadius = 14 },
        fillColor = { white = 0.0, alpha = 0.90 },
        withShadow = false,
    })

    local scopeLabel = TAB_SCOPE == "current" and "Current Edge window" or "All Edge windows"
    table.insert(elements, {
        type = "text",
        frame = { x = outerPad + 2, y = outerPad / 2, w = width - outerPad * 2 - 4, h = headerH },
        text = "Edge tabs  ·  " .. scopeLabel .. "  ·  " .. tostring(itemCount),
        textSize = math.max(9, math.min(13, headerH * 0.55)),
        textColor = { white = 1.0, alpha = 1.0 },
        textLineBreak = "truncateTail",
    })

    for i = 1, itemCount do
        local tab = switchChoices[i]
        local row = math.floor((i - 1) / cols)
        local col = (i - 1) % cols

        local remaining = itemCount - row * cols
        local itemsInRow = math.min(cols, remaining)
        local rowWidth = itemsInRow * cardW + math.max(0, itemsInRow - 1) * gap
        local rowStartX = outerPad + (usableW - rowWidth) / 2

        local cx = rowStartX + col * (cardW + gap)
        local cy = cardsTop + row * (cardH + gap)
        local selected = i == selectedIndex

        local rectIndex = #elements + 1
        table.insert(elements, {
            type = "rectangle",
            action = "strokeAndFill",
            frame = { x = cx, y = cy, w = cardW, h = cardH },
            roundedRectRadii = { xRadius = 9, yRadius = 9 },
            fillColor = cardFillColor(selected),
            strokeColor = cardStrokeColor(selected),
            strokeWidth = cardStrokeWidth(selected),
        })

        local previewInset = math.min(4, cardW * 0.03, cardH * 0.03)
        local metaHeight = math.min(56, cardH * 0.38)
        local previewH = math.max(1, cardH - metaHeight - previewInset * 2)
        local previewFrame = {
            x = cx + previewInset,
            y = cy + previewInset,
            w = math.max(1, cardW - previewInset * 2),
            h = previewH,
        }

        table.insert(elements, {
            type = "rectangle",
            action = "fill",
            frame = previewFrame,
            roundedRectRadii = { xRadius = 7, yRadius = 7 },
            -- Translucent black backing for the preview area. This remains
            -- visible around letterboxed images and when no preview exists.
            fillColor = { white = 0.0, alpha = 0.22 },
        })

        local edgeTabID = tostring(tab.edgeTabID or "")
        local previewImage = getPreviewImage(edgeTabID)

        local previewIndex = #elements + 1
        table.insert(elements, {
            type = "image",
            frame = previewFrame,
            image = previewImage,
            imageScaling = "scaleProportionally",
            imageAlignment = "center",
            imageAlpha = previewImage and 1.0 or 0.0,
        })

        local placeholderIndex = #elements + 1
        table.insert(elements, {
            type = "text",
            frame = previewFrame,
            text = previewImage and "" or "Preview unavailable",
            textSize = math.max(9, math.min(12, cardH * 0.065)),
            textAlignment = "center",
            textColor = { white = 1.0, alpha = 1.0 },
        })

        local titleY = cy + previewInset + previewH + 3
        local domainH = math.min(14, metaHeight * 0.30)
        local domainY = cy + cardH - domainH - 4
        local titleH = math.max(1, domainY - titleY - 2)
        local iconSize = math.max(1, math.min(18, titleH, cardW * 0.12))
        local favicon = faviconImages[tostring(tab.edgeTabID or "")]
        local icon = favicon and favicon.image or fallbackIcon
        local iconIndex = #elements + 1
        table.insert(elements, {
            type = "image",
            frame = { x = cx + 8, y = titleY, w = iconSize, h = iconSize },
            image = icon,
            imageAlpha = icon and 1.0 or 0.0,
            imageScaling = "scaleProportionally",
            imageAlignment = "center",
        })

        local titleIndex = #elements + 1
        table.insert(elements, {
            type = "text",
            frame = { x = cx + 8 + iconSize + 5, y = titleY,
                w = math.max(1, cardW - iconSize - 21), h = titleH },
            text = tab.text,
            textSize = math.max(9, math.min(13, titleH * 0.65)),
            textColor = { white = 1.0, alpha = 1.0 },
            textLineBreak = "wordWrap",
        })

        table.insert(elements, {
            type = "text",
            frame = { x = cx + 9, y = domainY, w = math.max(1, cardW - 18), h = domainH },
            text = domainFromURL(tab.url),
            textSize = math.max(7, math.min(9, domainH * 0.65)),
            textColor = { white = 1.0, alpha = 1.0 },
            textLineBreak = "truncateMiddle",
        })

        table.insert(elements, {
            type = "rectangle",
            action = "strokeAndFill",
            frame = { x = cx + 9, y = cy + 9, w = 23, h = 18 },
            roundedRectRadii = { xRadius = 6, yRadius = 6 },
            fillColor = { white = 1.0, alpha = 0.72 },
            strokeColor = { white = 0.0, alpha = 1.0 },
            strokeWidth = 1,
        })

        table.insert(elements, {
            type = "text",
            frame = { x = cx + 9, y = cy + 9, w = 23, h = 17 },
            text = tostring(i),
            textSize = 9,
            textAlignment = "center",
            textColor = { white = 0.0, alpha = 1.0 },
        })

        overlayCardElements[i] = {
            rect = rectIndex,
            preview = previewIndex,
            placeholder = placeholderIndex,
            title = titleIndex,
            icon = iconIndex,
            row = row,
            centerX = cx + cardW / 2,
        }
    end

    table.insert(elements, {
        type = "text",
        frame = { x = outerPad, y = height - outerPad - footerH + 3,
            w = width - outerPad * 2, h = footerH },
        text = "Hold ⌥ · Tab / arrows · 1–9 select · Esc cancel",
        textSize = math.max(8, math.min(11, width / 48)),
        textAlignment = "center",
        textLineBreak = "truncateTail",
        textColor = { white = 1.0, alpha = 0.70 },
    })

    overlay:replaceElements(elements)
    overlay:show()
    overlay:bringToFront(true)
end

local function watchOverlayResize()
    if overlayResizeTimer then return end
    overlayResizeTimer = hs.timer.doEvery(0.10, function()
        if not switching or not overlay then return end
        local frame = overlayFrameForWindow()
        local current = overlay:frame()
        if math.abs(frame.x - current.x) > 1 or math.abs(frame.y - current.y) > 1
            or math.abs(frame.w - current.w) > 1 or math.abs(frame.h - current.h) > 1
        then showOverlay() end
    end)
end

------------------------------------------------------------
-- Switching
------------------------------------------------------------

local function beginOrCycle(direction)
    if not switching then
        switchChoices = choicesForCurrentScope()

        if #switchChoices == 0 then
            hs.alert.show(TAB_SCOPE == "current"
                and "No recent tabs for this Edge window"
                or "No recent Edge tabs")
            return
        end

        switching = true
        overlayHostWindow = hs.window.focusedWindow()

        if direction > 0 then
            selectedIndex = #switchChoices > 1 and 2 or 1
        else
            selectedIndex = #switchChoices
        end

        showOverlay()
        watchOverlayResize()
        return
    end

    local oldIndex = selectedIndex
    selectedIndex = selectedIndex + direction
    if selectedIndex > #switchChoices then selectedIndex = 1 end
    if selectedIndex < 1 then selectedIndex = #switchChoices end
    updateOverlaySelection(oldIndex, selectedIndex)
end

local function finishSwitch(cancelled)
    if not switching then return end

    local choice = selectedIndex and switchChoices[selectedIndex] or nil
    switching = false

    if optionReleaseTimer then
        optionReleaseTimer:stop()
        optionReleaseTimer = nil
    end
    if overlayResizeTimer then
        overlayResizeTimer:stop()
        overlayResizeTimer = nil
    end

    hideOverlay()
    switchChoices = {}
    overlayHostWindow = nil

    if choice and not cancelled then activateEdgeTab(choice) end
end

local function selectOverlayIndex(index)
    if not switching or index < 1 or index > overlayItemCount then return end
    local oldIndex = selectedIndex
    selectedIndex = index
    updateOverlaySelection(oldIndex, selectedIndex)
end

local function moveOverlaySelection(key)
    if key == "left" or key == "right" then
        local step = key == "right" and 1 or -1
        selectOverlayIndex((selectedIndex - 1 + step) % overlayItemCount + 1)
        return
    end
    local current = overlayCardElements[selectedIndex]
    if not current then return end
    local targetRow = current.row + (key == "down" and 1 or -1)
    local bestIndex, bestDistance = nil, math.huge
    for i, refs in ipairs(overlayCardElements) do
        if refs.row == targetRow then
            local distance = math.abs(refs.centerX - current.centerX)
            if distance < bestDistance then bestIndex, bestDistance = i, distance end
        end
    end
    if bestIndex then selectOverlayIndex(bestIndex) end
end

local numberKeys = {}
for i = 1, 9 do
    numberKeys[hs.keycodes.map[tostring(i)]] = i
end

navigationTap = hs.eventtap.new({ hs.eventtap.event.types.keyDown, hs.eventtap.event.types.keyUp }, function(event)
    local code = event:getKeyCode()
    if event:getType() == hs.eventtap.event.types.keyUp then
        if swallowedKeys[code] then swallowedKeys[code] = nil; return true end
        return false
    end
    -- Consume held-key repeats after cancellation until the physical key is up.
    if not switching then return swallowedKeys[code] == true end
    local key = hs.keycodes.map[code]
    if key == "escape" then
        swallowedKeys[code] = true
        finishSwitch(true)
        return true
    end
    local flags = event:getFlags()
    if not flags.alt or flags.cmd or flags.ctrl then return false end
    if key == "left" or key == "right" or key == "up" or key == "down" then
        swallowedKeys[code] = true
        moveOverlaySelection(key)
        return true
    end
    local number = numberKeys[code]
    if number then
        swallowedKeys[code] = true
        selectOverlayIndex(number)
        return true
    end
    return false
end)
navigationTap:start()

local function watchOptionRelease()
    if optionReleaseTimer then return end
    optionReleaseTimer = hs.timer.doEvery(0.02, function()
        local modifiers = hs.eventtap.checkKeyboardModifiers()
        if not modifiers.alt then finishSwitch() end
    end)
end

local function handleOptionTab(direction)
    beginOrCycle(direction)
    if switching then watchOptionRelease() end
end

------------------------------------------------------------
-- Hotkeys / focus
------------------------------------------------------------

optionTabHotkey = hs.hotkey.new({"alt"}, "tab", function()
    handleOptionTab(1)
end)

optionShiftTabHotkey = hs.hotkey.new({"alt", "shift"}, "tab", function()
    handleOptionTab(-1)
end)

local function updateOptionTabHotkeys()
    if edgeIsFrontmost() then
        optionTabHotkey:enable()
        optionShiftTabHotkey:enable()
    elseif not switching then
        optionTabHotkey:disable()
        optionShiftTabHotkey:disable()
    end
end

appWatcher = hs.application.watcher.new(function(appName, eventType, app)
    if eventType == hs.application.watcher.activated then
        if switching and not edgeIsFrontmost() then finishSwitch(true) end
        updateOptionTabHotkeys()
    end
end)
appWatcher:start()

------------------------------------------------------------
-- Sleep / wake recovery
------------------------------------------------------------

local function scheduleWakeRecovery()
    if wakeRecoveryTimer then
        wakeRecoveryTimer:stop()
        wakeRecoveryTimer = nil
    end

    wakeRecoveryTimer = hs.timer.doAfter(0.75, function()
        wakeRecoveryTimer = nil
        switching = false
        switchChoices = {}
        overlayHostWindow = nil
        swallowedKeys = {}

        if overlayResizeTimer then
            overlayResizeTimer:stop()
            overlayResizeTimer = nil
        end

        if optionReleaseTimer then
            optionReleaseTimer:stop()
            optionReleaseTimer = nil
        end

        hideOverlay()
        clearPendingSwitch()
        bridgeSocketLastSeen = 0
        updateOptionTabHotkeys()
        navigationTap:start()
        startBridge()

        hs.timer.doAfter(0.75, updateOptionTabHotkeys)
    end)
end

wakeWatcher = hs.caffeinate.watcher.new(function(event)
    if event == hs.caffeinate.watcher.systemDidWake
        or event == hs.caffeinate.watcher.screensDidWake
        or event == hs.caffeinate.watcher.screensDidUnlock
    then
        scheduleWakeRecovery()
    end
end)
wakeWatcher:start()

------------------------------------------------------------
-- Reload shortcut
------------------------------------------------------------

hs.hotkey.bind({"cmd", "ctrl", "alt"}, "r", function()
    hs.reload()
end)

------------------------------------------------------------
-- Start
------------------------------------------------------------

updateOptionTabHotkeys()
startBridge()

-- Give the extension time to reconnect and restore the authoritative snapshot.
hs.timer.doAfter(1.5, function()
    if not restoredMruSnapshot then seedRecentTabs() end
end)

hs.alert.show("Edge MRU window scope loaded")
