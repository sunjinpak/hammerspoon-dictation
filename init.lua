-- Hammerspoon Config
-- Dictation: Ctrl+D to record -> macOS 26 Speech (offline) -> auto paste
--   Ctrl+D again = stop and paste. ESC while recording = cancel.

require("hs.ipc")
require("sd-backup")  -- DJI Pocket 3 SD card auto-backup

local dictateTask = nil
local state = "idle"  -- idle / recording / processing
local liveCanvas = nil
local liveTimer = nil
local startTime = 0
local sourceWindow = nil  -- remember where Ctrl+D was pressed
local dictateScript = os.getenv("HOME") .. "/.hammerspoon/dictate.sh"
local dictatePidFile = "/tmp/hs_dictate.pid"

-- Hotkey-level events go to the same log dictate.sh writes. Without this, a
-- press that never reaches dictate.sh (ignored during processing, recorder not
-- yet spawned) leaves no trace, and "dictation sometimes does nothing" cannot
-- be diagnosed after the fact.
local hsLogFile = os.getenv("HOME") .. "/.claude-local/hammerspoon/dictate.log"
local function hslog(msg)
    local f = io.open(hsLogFile, "a")
    if f then
        f:write(os.date("%Y-%m-%d %H:%M:%S") .. " hs: " .. msg .. "\n")
        f:close()
    end
end
local dictateWatchdog = nil
local dictateCancelled = false

-- Stop `rec` by the PID it wrote, not by pkill pattern: a fast double-tap can
-- fire before `rec` exists, and a pattern-matched signal is then lost forever.
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
    -- PID file not written yet: fall back to the pattern, then retry shortly.
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

-- Paste without destroying the clipboard: dictation should not cost the user
-- whatever they had copied.
--
-- Two dictations in quick succession must not chain: without this guard the
-- second paste would "save" the first one's dictated text as the original and
-- restore that instead of the user's real clipboard.
local clipSaved = nil
local clipRestoreTimer = nil

local function pasteText(text)
    if clipRestoreTimer then
        -- A restore is still pending, so the clipboard currently holds the
        -- previous dictation, not the user's content. Keep the original.
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

-- Wait for focus to actually land before pasting. A fixed 0.2s delay races with
-- slow or cross-Space activation and can drop the text into the wrong window.
local function focusThenPaste(win, text, attempt)
    attempt = attempt or 1
    local target = hs.window.focusedWindow()
    if win and (not target or target:id() ~= win:id()) then
        if attempt > 10 then  -- ~1s; window likely closed during recording
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

-- v6: what the user was looking at when they started talking, for the corrector.
--
-- The corrector sees one sentence and has to guess whether "프로덕션" is
-- "production" or "prediction". The window in front of the user usually settles
-- it: a Terminal showing a Claude conversation about a paper's introduction, a
-- Word document titled with the manuscript's name. Captured at recording *start*
-- (what prompted the utterance) and written to a file, since the text can be a
-- few KB and this must not add latency to the paste.
--
-- Terminal.app is the only app whose visible text is read; other apps
-- contribute just their name and window title. Owner-only file: screen text is
-- as sensitive as the transcript.
local ctxFile = "/tmp/hs_dictate.ctx"
local function captureContext(win)
    local ok, err = pcall(function()
        local app = win and win:application()
        local appName = app and app:name() or ""
        local title = win and win:title() or ""
        local lines = { "app: " .. appName, "window: " .. title }
        if appName == "Terminal" then
            local ok2, text = hs.osascript.applescript(
                [[tell application "Terminal" to get contents of selected tab of front window]])
            if ok2 and type(text) == "string" then
                text = text:gsub("%s+\n", "\n")  -- drop trailing pad on each row
                if #text > 1500 then text = text:sub(-1500) end
                table.insert(lines, "screen:\n" .. text)
            end
        end
        local f = io.open(ctxFile, "w")
        if f then
            f:write(table.concat(lines, "\n"))
            f:close()
            os.execute("chmod 600 " .. ctxFile)
        end
    end)
    if not ok then os.remove(ctxFile) end
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
        -- Cannot start a new one yet. Say so: a silently dropped press is
        -- indistinguishable from a broken hotkey.
        hslog("hotkey ignored: still processing")
        hs.alert.show("Still processing previous dictation", 1)
        return
    end

    if state == "recording" then
        -- Stop recording
        state = "processing"
        showProcessing()
        if not stopRecording() then
            -- PID file not there yet: `rec` has not spawned (opening a
            -- Bluetooth input can take over a second). A single retry at
            -- 0.35s used to be the only attempt; if it also missed, the
            -- recorder ran on for up to 300s with the overlay stuck on
            -- "Processing...". Retry until it appears, up to ~3s.
            hslog("stop: recorder not spawned yet, retrying")
            local tries = 0
            local retry
            retry = hs.timer.doEvery(0.25, function()
                tries = tries + 1
                if stopRecording() or state ~= "processing" or tries >= 12 then
                    retry:stop()
                    if tries >= 12 then hslog("stop: gave up after 3s, watchdog will reset") end
                end
            end)
        end
        return
    end

    -- Start recording - remember current window
    hslog("start")
    state = "recording"
    dictateCancelled = false
    sourceWindow = hs.window.focusedWindow()
    createOverlay()
    captureContext(sourceWindow)

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
            hslog("error: " .. msg)
            hs.alert.show("Dictation error: " .. msg, 4)
            return
        end

        if exitCode == 2 or text == "" then
            hslog("no speech (exit " .. tostring(exitCode) .. ")")
            hs.alert.show("No speech detected", 2)
            return
        end

        -- Always wrap in <...>: the inline-comment convention applies everywhere,
        -- not just terminals.
        text = "<" .. text .. ">"

        focusThenPaste(sourceWindow, text)
    -- DICTATE_DEBUG=1 logs each run (timing, silence-gate decisions, and the
    -- Gemini correction's before/after) to dictate.log. Set here rather than in a
    -- shell rc because Hammerspoon's non-interactive zsh reads neither ~/.zshrc
    -- nor ~/.zprofile -- the same trap that left v2's correction step silently
    -- dead for months.
    end, {"-c", "DICTATE_DEBUG=1 " .. dictateScript})

    if not dictateTask:start() then
        resetDictation()
        hs.alert.show("Dictation failed to start", 3)
        return
    end

    -- Watchdog: without this a hung transcription leaves state = "processing"
    -- and Ctrl+D dead until a manual Hammerspoon reload.
    dictateWatchdog = hs.timer.doAfter(330, function()
        if state == "idle" then return end
        hslog("watchdog reset from state=" .. state)
        stopRecording()
        if dictateTask then dictateTask:terminate() end
        resetDictation()
        hs.alert.show("Dictation timed out - reset", 3)
    end)
end)

-- Reload config
hs.hotkey.bind({"cmd", "alt", "ctrl"}, "r", function()
    os.execute("pkill -f 'rec -q /tmp/hs_dictate.wav' 2>/dev/null")
    hs.reload()
end)

-- ESC handler: when a Claude-enlarged Terminal window exists, ESC restores it.
-- Otherwise ESC passes through normally (vi mode, autocomplete dismissal, etc).
-- Globals so we can inspect them via `hs -c`.
claudeWindowStateDir = os.getenv("HOME") .. "/.claude/state/window_bounds"

function anyClaudeEnlargedWindowExists()
    local handle = io.popen("ls -A " .. claudeWindowStateDir .. " 2>/dev/null | head -1")
    if not handle then return false end
    local result = handle:read("*a") or ""
    handle:close()
    return result:len() > 0
end

claudeEscWatcher = hs.eventtap.new({hs.eventtap.event.types.keyDown}, function(event)
    if event:getKeyCode() ~= 53 then return false end  -- 53 = ESC
    local flags = event:getFlags()
    if flags.cmd or flags.alt or flags.ctrl then
        return false  -- modifier+ESC passes through
    end

    -- ESC while recording = throw the recording away, in any app.
    if cancelDictation() then
        return true
    end

    local frontApp = hs.application.frontmostApplication()
    if not frontApp or frontApp:bundleID() ~= "com.apple.Terminal" then
        return false
    end

    if not anyClaudeEnlargedWindowExists() then
        return false
    end

    hs.alert.show("Claude window restoring...", 0.5)
    os.execute(os.getenv("HOME") .. "/.claude/hooks/terminal_window_restore_all.sh &")
    return true  -- consume ESC
end)
claudeEscWatcher:start()

-- Claude Code 완료 알림 토글 메뉴바 (코드는 settings repo에서 로드, 모든 Mac 공통).
pcall(dofile, os.getenv("HOME") .. "/.claude-local/hammerspoon/claude_notify_menubar.lua")  -- claude-notify-menubar

hs.alert.show("Hammerspoon loaded")
