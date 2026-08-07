-- Hammerspoon Dictation v3
-- Ctrl+D to record, Ctrl+D again to stop and paste, ESC to cancel.
-- Transcription runs on the macOS 26 Speech framework: offline, no API key.

local dictateTask = nil
local state = "idle"  -- idle / recording / processing
local liveCanvas = nil
local liveTimer = nil
local startTime = 0
local sourceWindow = nil
local dictateScript = os.getenv("HOME") .. "/.hammerspoon/dictate.sh"
local dictatePidFile = "/tmp/hs_dictate.pid"
local dictateWatchdog = nil
local dictateCancelled = false

-- Dictated text is pasted as <...> in every app. The wrapper marks the text as
-- spoken input, which CLI agents read as an inline comment and which stays easy
-- to spot (and delete) anywhere else. Set to false to paste plain text.
local wrapInBrackets = true

-- Stop `rec` by the PID it wrote rather than by pkill pattern: a fast double-tap
-- can fire before `rec` exists, and a pattern-matched signal is then lost.
local function stopRecording()
    local f = io.open(dictatePidFile, "r")
    if f then
        local pid = (f:read("*a") or ""):match("%d+")
        f:close()
        if pid then
            os.execute("kill -INT " .. pid .. " 2>/dev/null")
            return true
        end
    end
    os.execute("pkill -INT -f 'rec -q /tmp/hs_dictate.wav' 2>/dev/null")
    return false
end

local function createOverlay()
    local screen = hs.screen.mainScreen():frame()
    local w, h = 300, 60
    local x = (screen.w - w) / 2
    local y = 60

    liveCanvas = hs.canvas.new({x = x, y = y, w = w, h = h})
    liveCanvas:appendElements(
        {type = "rectangle", fillColor = {red = 0.8, green = 0.1, blue = 0.1, alpha = 0.9},
         roundedRectRadii = {xRadius = 12, yRadius = 12}},
        {type = "text", text = "🎤 Recording... 0s",
         textColor = {red = 1, green = 1, blue = 1, alpha = 1},
         textSize = 18, textAlignment = "center",
         frame = {x = "0%", y = "15%", w = "100%", h = "70%"}}
    )
    liveCanvas:level(hs.canvas.windowLevels.overlay)
    liveCanvas:show()

    startTime = hs.timer.secondsSinceEpoch()
    liveTimer = hs.timer.doEvery(1, function()
        local elapsed = math.floor(hs.timer.secondsSinceEpoch() - startTime)
        if liveCanvas and state == "recording" then
            liveCanvas[2].text = "🎤 Recording... " .. elapsed .. "s"
        end
    end)
end

local function showProcessing()
    if liveTimer then liveTimer:stop(); liveTimer = nil end
    if liveCanvas then
        liveCanvas[1].fillColor = {red = 0.2, green = 0.2, blue = 0.8, alpha = 0.9}
        liveCanvas[2].text = "⏳ Processing..."
    end
end

local function destroyOverlay()
    if liveTimer then liveTimer:stop(); liveTimer = nil end
    if liveCanvas then liveCanvas:delete(); liveCanvas = nil end
end

local function resetDictation()
    if dictateWatchdog then dictateWatchdog:stop(); dictateWatchdog = nil end
    destroyOverlay()
    state = "idle"
    dictateTask = nil
end

-- Paste without destroying the clipboard. Two dictations in quick succession
-- must not chain: without the timer guard the second paste would "save" the
-- first one's text as the original and restore that instead.
local clipSaved = nil
local clipRestoreTimer = nil

local function pasteText(text)
    if clipRestoreTimer then
        clipRestoreTimer:stop()
        clipRestoreTimer = nil
    else
        clipSaved = hs.pasteboard.getContents()
    end

    local original = clipSaved
    hs.pasteboard.setContents(text)
    hs.eventtap.keyStroke({"cmd"}, "v")

    clipRestoreTimer = hs.timer.doAfter(0.4, function()
        clipRestoreTimer = nil
        clipSaved = nil
        if original then
            hs.pasteboard.setContents(original)
        end
    end)
end

-- Wait for focus to actually land before pasting. A fixed delay races with slow
-- or cross-Space activation and can drop the text into the wrong window.
local function focusThenPaste(win, text, attempt)
    attempt = attempt or 1
    local target = hs.window.focusedWindow()
    if win and (not target or target:id() ~= win:id()) then
        if attempt > 10 then  -- ~1s; the window probably closed while recording
            hs.pasteboard.setContents(text)
            hs.alert.show("Dictation copied to clipboard (target window gone)", 3)
            return
        end
        win:focus()
        hs.timer.doAfter(0.1, function() focusThenPaste(win, text, attempt + 1) end)
        return
    end
    pasteText(text)
end

local function cancelDictation()
    if state ~= "recording" then return false end
    dictateCancelled = true
    stopRecording()
    if dictateTask then dictateTask:terminate() end
    resetDictation()
    hs.alert.show("Dictation cancelled", 1)
    return true
end

hs.hotkey.bind({"ctrl"}, "d", function()
    if state == "processing" then
        return
    end

    if state == "recording" then
        state = "processing"
        showProcessing()
        if not stopRecording() then
            -- PID file not written yet; retry once the recorder has spawned.
            hs.timer.doAfter(0.35, stopRecording)
        end
        return
    end

    state = "recording"
    dictateCancelled = false
    sourceWindow = hs.window.focusedWindow()
    createOverlay()

    dictateTask = hs.task.new("/bin/zsh", function(exitCode, stdout, stderr)
        if dictateCancelled then return end

        local text = ""
        if stdout then
            text = stdout:gsub("^%s+", ""):gsub("%s+$", "")
        end

        resetDictation()

        -- Distinguish a real error from genuine silence: reporting a broken
        -- setup as "no speech" sends the user hunting for a mic problem.
        if exitCode ~= 0 and exitCode ~= 2 then
            local msg = (stderr or ""):gsub("%s+$", "")
            if msg == "" then msg = "exit " .. tostring(exitCode) end
            hs.alert.show("Dictation error: " .. msg, 4)
            return
        end

        if exitCode == 2 or text == "" then
            hs.alert.show("No speech detected", 2)
            return
        end

        if wrapInBrackets then
            text = "<" .. text .. ">"
        end

        focusThenPaste(sourceWindow, text)
    end, {"-c", dictateScript})

    if not dictateTask:start() then
        resetDictation()
        hs.alert.show("Dictation failed to start", 3)
        return
    end

    -- Without this, a hung transcription leaves state = "processing" and Ctrl+D
    -- dead until a manual reload. 330s = the 300s recording cap plus headroom.
    dictateWatchdog = hs.timer.doAfter(330, function()
        if state == "idle" then return end
        stopRecording()
        if dictateTask then dictateTask:terminate() end
        resetDictation()
        hs.alert.show("Dictation timed out - reset", 3)
    end)
end)

-- ESC cancels an in-progress recording; otherwise it passes through untouched.
dictateEscWatcher = hs.eventtap.new({hs.eventtap.event.types.keyDown}, function(event)
    if event:getKeyCode() ~= 53 then return false end  -- 53 = ESC
    local flags = event:getFlags()
    if flags.cmd or flags.alt or flags.ctrl then
        return false
    end
    return cancelDictation()
end)
dictateEscWatcher:start()

-- Reload config
hs.hotkey.bind({"cmd", "alt", "ctrl"}, "r", function()
    os.execute("pkill -f 'rec -q /tmp/hs_dictate.wav' 2>/dev/null")
    hs.reload()
end)

hs.alert.show("Hammerspoon dictation loaded")
