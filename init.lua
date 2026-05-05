-- Hammerspoon Dictation
-- Press Ctrl+D to start recording, Ctrl+D again to stop
-- Whisper transcribes locally, Gemini corrects, auto-pastes into original window

require("hs.ipc")

local dictateTask = nil
local state = "idle"  -- idle / recording / processing
local liveCanvas = nil
local liveTimer = nil
local startTime = 0
local sourceWindow = nil  -- remember where Ctrl+D was pressed
local dictateScript = os.getenv("HOME") .. "/.hammerspoon/dictate.sh"

local function createOverlay()
    local screen = hs.screen.mainScreen():frame()
    local w, h = 300, 60
    local x = (screen.w - w) / 2
    local y = 60

    liveCanvas = hs.canvas.new({x = x, y = y, w = w, h = h})
    liveCanvas:appendElements(
        {type = "rectangle", fillColor = {red = 0.8, green = 0.1, blue = 0.1, alpha = 0.9},
         roundedRectRadii = {xRadius = 12, yRadius = 12}},
        {type = "text", text = "Recording... 0s",
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
            liveCanvas[2].text = "Recording... " .. elapsed .. "s"
        end
    end)
end

local function showProcessing()
    if liveTimer then liveTimer:stop(); liveTimer = nil end
    if liveCanvas then
        liveCanvas[1].fillColor = {red = 0.2, green = 0.2, blue = 0.8, alpha = 0.9}
        liveCanvas[2].text = "Processing..."
    end
end

local function destroyOverlay()
    if liveTimer then liveTimer:stop(); liveTimer = nil end
    if liveCanvas then liveCanvas:delete(); liveCanvas = nil end
end

hs.hotkey.bind({"ctrl"}, "d", function()
    if state == "processing" then
        return
    end

    if state == "recording" then
        -- Stop recording
        state = "processing"
        showProcessing()
        os.execute("pkill -INT -f 'rec /tmp/hs_dictate.wav' 2>/dev/null")
        return
    end

    -- Start recording - remember current window
    state = "recording"
    sourceWindow = hs.window.focusedWindow()
    createOverlay()

    dictateTask = hs.task.new("/bin/zsh", function(exitCode, stdout, stderr)
        local corrected = ""
        if stdout then
            corrected = stdout:gsub("^%s+", ""):gsub("%s+$", "")
        end

        destroyOverlay()
        state = "idle"

        if corrected == "" then
            hs.alert.show("No speech detected", 2)
            return
        end

        -- Focus back to original window, then paste
        if sourceWindow then
            sourceWindow:focus()
        end
        hs.timer.doAfter(0.2, function()
            hs.pasteboard.setContents(corrected)
            hs.eventtap.keyStroke({"cmd"}, "v")
        end)
    end, {"-c", dictateScript})

    dictateTask:start()
end)

-- Reload config: Cmd+Alt+Ctrl+R
hs.hotkey.bind({"cmd", "alt", "ctrl"}, "r", function()
    os.execute("pkill -f 'rec /tmp/hs_dictate.wav' 2>/dev/null")
    hs.reload()
end)

hs.alert.show("Hammerspoon loaded")
