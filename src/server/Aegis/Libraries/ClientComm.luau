-- ClientComm.luau - Server-side client communication for AegisVM
--
-- When Constants.CLIENT_COMMUNICATION is true this module:
--   1. Injects a LocalScript (ClientAgent) into the owner player's PlayerGui.
--   2. Creates two RemoteEvents inside a _AegisComm folder in that PlayerGui:
--        MouseUpdate  - client fires server with periodic mouse position data
--        InputEvent   - client fires server with keyboard/mouse button/UIS events
--   3. Returns per-player emulated Mouse and UserInputService objects that
--      buildRoblox uses to replace the client-only APIs inside the sandbox.
--
-- All setup is lazy and idempotent: call setup(player) any time; it is safe
-- to call multiple times for the same player.

local ClientComm = {}

local ClientAgent  = script:WaitForChild("ClientAgent")
local TextFilter   = require(script.Parent.Parent.TextFilter)

-- Cache: real Player -> state table
local playerState = {}

-- ─── Per-player setup ────────────────────────────────────────────────

local function ensureSetup(player)
    if playerState[player] then return playerState[player] end

    -- Create the _AegisComm folder in the player's PlayerGui.
    local playerGui = player:FindFirstChildOfClass("PlayerGui")
        or player:WaitForChild("PlayerGui", 15)
    if not playerGui then return nil end

    local comms = playerGui:FindFirstChild("_AegisComm")
    if not comms then
        comms = Instance.new("Folder")
        comms.Name = "_AegisComm"
        comms.Parent = playerGui
    end

    -- RemoteEvent: client sends mouse position every ~0.1 s
    local mouseUpdate = comms:FindFirstChild("MouseUpdate")
    if not mouseUpdate then
        mouseUpdate = Instance.new("RemoteEvent")
        mouseUpdate.Name = "MouseUpdate"
        mouseUpdate.Parent = comms
    end

    -- RemoteEvent: client sends all input events immediately
    local inputEvent = comms:FindFirstChild("InputEvent")
    if not inputEvent then
        inputEvent = Instance.new("RemoteEvent")
        inputEvent.Name = "InputEvent"
        inputEvent.Parent = comms
    end

    -- Clone the LocalScript template into the comms folder so it runs on
    -- the client automatically (PlayerGui replicates to the client).
    if not comms:FindFirstChild("ClientAgent") then
        local agent = ClientAgent:Clone()
        agent.Parent = comms
        agent.Disabled = false
    end

    -- RemoteEvent: server fires to show a notification toast on the client
    local notifEvent = comms:FindFirstChild("NotificationEvent")
    if not notifEvent then
        notifEvent = Instance.new("RemoteEvent")
        notifEvent.Name = "NotificationEvent"
        notifEvent.Parent = comms
    end

    -- RemoteEvent: server fires to apply SetCore or ToggleCoreGui on the client
    local coreGuiAction = comms:FindFirstChild("CoreGuiAction")
    if not coreGuiAction then
        coreGuiAction = Instance.new("RemoteEvent")
        coreGuiAction.Name = "CoreGuiAction"
        coreGuiAction.Parent = comms
    end

    -- RemoteEvent: client sends camera state every ~0.1 s
    local cameraUpdate = comms:FindFirstChild("CameraUpdate")
    if not cameraUpdate then
        cameraUpdate = Instance.new("RemoteEvent")
        cameraUpdate.Name = "CameraUpdate"
        cameraUpdate.Parent = comms
    end

    -- RemoteEvent: server fires to push camera property changes to the client
    local cameraCommand = comms:FindFirstChild("CameraCommand")
    if not cameraCommand then
        cameraCommand = Instance.new("RemoteEvent")
        cameraCommand.Name = "CameraCommand"
        cameraCommand.Parent = comms
    end

    -- RemoteFunction: client invokes to filter text server-side.
    -- TextService:FilterStringAsync is server-only; LocalScripts route through
    -- this function so the full filter pipeline runs on the server.
    local filterRequest = comms:FindFirstChild("FilterRequest")
    if not filterRequest then
        filterRequest = Instance.new("RemoteFunction")
        filterRequest.Name = "FilterRequest"
        filterRequest.Parent = comms
    end
    filterRequest.OnServerInvoke = function(requestingPlayer, text)
        if not rawequal(requestingPlayer, player) then return text end
        if type(text) ~= "string" then return "" end
        return TextFilter.filterString(text, requestingPlayer.UserId)
    end

    -- Hidden RobloxGui ScreenGui in PlayerGui. Exists so that instance-hierarchy
    -- searches (FindFirstChild / WaitForChild on PlayerGui) can find a child
    -- named "RobloxGui". Actual emulated behaviour comes from the CoreGui proxy
    -- built in StdLib (sendNotifProxy etc.).
    if not playerGui:FindFirstChild("RobloxGui") then
        local robloxGui = Instance.new("ScreenGui")
        robloxGui.Name         = "RobloxGui"
        robloxGui.Enabled      = false
        robloxGui.ResetOnSpawn = false
        robloxGui.Parent       = playerGui
    end

    -- ── Mouse state ──────────────────────────────────────────────────

    local ms = {
        X = 0, Y = 0,
        prevX = 0, prevY = 0,
        Hit = CFrame.new(),
        Target = nil,
        Icon = "",
        lastTime = 0,
    }

    -- BindableEvents for Mouse signals
    local moveBE    = Instance.new("BindableEvent")
    local b1DnBE    = Instance.new("BindableEvent")
    local b1UpBE    = Instance.new("BindableEvent")
    local b2DnBE    = Instance.new("BindableEvent")
    local b2UpBE    = Instance.new("BindableEvent")
    local wfBE      = Instance.new("BindableEvent")
    local wbBE      = Instance.new("BindableEvent")
    -- Legacy Mouse.KeyDown / Mouse.KeyUp (deprecated but widely used)
    local keyDnBE   = Instance.new("BindableEvent")
    local keyUpBE   = Instance.new("BindableEvent")

    -- ── UIS state ────────────────────────────────────────────────────

    local keyState = {}  -- [Enum.KeyCode] = true

    -- BindableEvents for UserInputService signals
    local ibBE   = Instance.new("BindableEvent")  -- InputBegan
    local ieBE   = Instance.new("BindableEvent")  -- InputEnded
    local icBE   = Instance.new("BindableEvent")  -- InputChanged
    local tbfBE  = Instance.new("BindableEvent")  -- TextBoxFocused
    local tbrBE  = Instance.new("BindableEvent")  -- TextBoxFocusReleased

    -- ── Wire up RemoteEvent listeners ────────────────────────────────

    mouseUpdate.OnServerEvent:Connect(function(sender, data)
        if not rawequal(sender, player) then return end
        if type(data) ~= "table" then return end
        ms.prevX = ms.X
        ms.prevY = ms.Y
        ms.X        = tonumber(data.x) or 0
        ms.Y        = tonumber(data.y) or 0
        ms.Hit      = typeof(data.hit)    == "CFrame"    and data.hit    or CFrame.new()
        ms.Target   = typeof(data.target) == "Instance"  and data.target or nil
        ms.lastTime = tick()
        moveBE:Fire()
    end)

    inputEvent.OnServerEvent:Connect(function(sender, kind, data)
        if not rawequal(sender, player) then return end
        if type(data) ~= "table" then data = {} end

        if     kind == "Button1Down"   then b1DnBE:Fire()
        elseif kind == "Button1Up"     then b1UpBE:Fire()
        elseif kind == "Button2Down"   then b2DnBE:Fire()
        elseif kind == "Button2Up"     then b2UpBE:Fire()
        elseif kind == "WheelForward"  then wfBE:Fire()
        elseif kind == "WheelBackward" then wbBE:Fire()
        elseif kind == "InputBegan" then
            if data.KeyCode then keyState[data.KeyCode] = true end
            ibBE:Fire(data)
            -- Replicate legacy Mouse.KeyDown for keyboard input (issue #23).
            if data.UserInputType == Enum.UserInputType.Keyboard and data.KeyCode then
                local ok, name = pcall(function() return data.KeyCode.Name:lower() end)
                keyDnBE:Fire(ok and name or "")
            end
        elseif kind == "InputEnded" then
            if data.KeyCode then keyState[data.KeyCode] = nil end
            ieBE:Fire(data)
            -- Replicate legacy Mouse.KeyUp for keyboard input (issue #23).
            if data.UserInputType == Enum.UserInputType.Keyboard and data.KeyCode then
                local ok, name = pcall(function() return data.KeyCode.Name:lower() end)
                keyUpBE:Fire(ok and name or "")
            end
        elseif kind == "InputChanged" then
            icBE:Fire(data)
        elseif kind == "TextBoxFocused" then
            tbfBE:Fire(data)
        elseif kind == "TextBoxFocusReleased" then
            tbrBE:Fire(data)
        end
    end)

    -- ── Camera state ─────────────────────────────────────────────────

    local cs = {
        FieldOfView  = 70,
        CFrame       = CFrame.new(),
        Focus        = CFrame.new(),
        CameraType   = "Custom",
        ViewportSize = Vector2.new(0, 0),
        HeadLocked   = true,
    }

    cameraUpdate.OnServerEvent:Connect(function(sender, data)
        if not rawequal(sender, player) then return end
        if type(data) ~= "table" then return end
        if type(data.FieldOfView)    == "number"  then cs.FieldOfView  = data.FieldOfView  end
        if typeof(data.CFrame)       == "CFrame"  then cs.CFrame       = data.CFrame       end
        if typeof(data.Focus)        == "CFrame"  then cs.Focus        = data.Focus        end
        if type(data.CameraType)     == "string"  then cs.CameraType   = data.CameraType   end
        if typeof(data.ViewportSize) == "Vector2" then cs.ViewportSize = data.ViewportSize end
        if type(data.HeadLocked)     == "boolean" then cs.HeadLocked   = data.HeadLocked   end
    end)

    -- Emulated Camera object. Read-only: reflects what the client last sent.
    -- CameraType is returned as an Enum item when possible, matching Roblox's API.
    local camera = setmetatable({}, {
        __index = function(_, k)
            if k == "FieldOfView"  then return cs.FieldOfView
            elseif k == "CFrame"        then return cs.CFrame
            elseif k == "Focus"         then return cs.Focus
            elseif k == "ViewportSize"  then return cs.ViewportSize
            elseif k == "HeadLocked"    then return cs.HeadLocked
            elseif k == "ClassName"     then return "Camera"
            elseif k == "CameraType" then
                local ok, enumVal = pcall(function() return Enum.CameraType[cs.CameraType] end)
                return ok and enumVal or cs.CameraType
            end
        end,
        __newindex = function(_, k, v)
            -- Update local cs state immediately (optimistic), then push to client.
            -- CameraType is normalised to a string name for both storage and wire.
            if k == "FieldOfView" and type(v) == "number" then
                cs.FieldOfView = v
                cameraCommand:FireClient(player, k, v)
            elseif k == "CFrame" and typeof(v) == "CFrame" then
                cs.CFrame = v
                cameraCommand:FireClient(player, k, v)
            elseif k == "Focus" and typeof(v) == "CFrame" then
                cs.Focus = v
                cameraCommand:FireClient(player, k, v)
            elseif k == "HeadLocked" and type(v) == "boolean" then
                cs.HeadLocked = v
                cameraCommand:FireClient(player, k, v)
            elseif k == "CameraType" then
                local name
                if type(v) == "string" then
                    name = v
                else
                    local ok, n = pcall(function() return v.Name end)
                    if ok and type(n) == "string" then name = n end
                end
                if name then
                    cs.CameraType = name
                    cameraCommand:FireClient(player, k, name)
                end
            elseif k == "CameraSubject" and typeof(v) == "Instance" then
                cameraCommand:FireClient(player, k, v)
            end
        end,
        __tostring = function() return "Camera" end,
    })

    -- ── Emulated Mouse ───────────────────────────────────────────────
    -- X and Y are lerped between the two most recent received positions
    -- based on elapsed time since the last update (0.1 s update interval).

    local mouse = setmetatable({}, {
        __index = function(_, k)
            local elapsed = tick() - ms.lastTime
            local alpha   = math.clamp(elapsed / 0.1, 0, 1)
            if k == "X" then
                return ms.prevX + (ms.X - ms.prevX) * alpha
            elseif k == "Y" then
                return ms.prevY + (ms.Y - ms.prevY) * alpha
            elseif k == "Hit"    then return ms.Hit
            elseif k == "Target" then return ms.Target
            elseif k == "Icon"   then return ms.Icon
            elseif k == "Move"         then return moveBE.Event
            elseif k == "Button1Down"  then return b1DnBE.Event
            elseif k == "Button1Up"    then return b1UpBE.Event
            elseif k == "Button2Down"  then return b2DnBE.Event
            elseif k == "Button2Up"    then return b2UpBE.Event
            elseif k == "WheelForward"  then return wfBE.Event
            elseif k == "WheelBackward" then return wbBE.Event
            elseif k == "KeyDown"      then return keyDnBE.Event
            elseif k == "KeyUp"        then return keyUpBE.Event
            end
        end,
        __newindex = function(_, k, v)
            if k == "Icon" then ms.Icon = v end
        end,
    })

    -- ── Emulated UserInputService ────────────────────────────────────

    local uis = {
        KeyboardEnabled = true,
        MouseEnabled    = true,
        TouchEnabled    = false,
        GamepadEnabled  = false,

        InputBegan            = ibBE.Event,
        InputEnded            = ieBE.Event,
        InputChanged          = icBE.Event,
        TextBoxFocused        = tbfBE.Event,
        TextBoxFocusReleased  = tbrBE.Event,

        IsKeyDown = function(_, keyCode)
            return keyState[keyCode] == true
        end,
        GetMouseLocation = function()
            return Vector2.new(ms.X, ms.Y)
        end,
        GetMouseDelta = function()
            return Vector2.new(0, 0)
        end,
        GetKeysPressed = function()
            local out = {}
            for k in pairs(keyState) do
                out[#out + 1] = { KeyCode = k }
            end
            return out
        end,
        GetSupportedGamepadKeyCodes = function() return {} end,
    }

    -- ── Finalise ─────────────────────────────────────────────────────

    local state = { comms = comms, mouse = mouse, uis = uis, camera = camera, notifEvent = notifEvent, coreGuiAction = coreGuiAction }
    playerState[player] = state

    -- Remove state when the player leaves the game
    game:GetService("Players").PlayerRemoving:Connect(function(leaving)
        if rawequal(leaving, player) then
            playerState[player] = nil
        end
    end)

    return state
end

-- ─── Public API ──────────────────────────────────────────────────────

-- Set up communication for a player and return the state table.
-- Safe to call multiple times; subsequent calls return the cached state.
function ClientComm.setup(player)
    if not player then return nil end
    return ensureSetup(player)
end

-- Return the emulated Mouse object for a player (sets up comm if needed).
function ClientComm.getMouse(player)
    local state = ensureSetup(player)
    return state and state.mouse
end

-- Return the emulated Camera for a player (reflects workspace.CurrentCamera data
-- sent by the client). Sets up comm if needed.
function ClientComm.getCamera(player)
    local state = ensureSetup(player)
    return state and state.camera
end

-- Return the emulated UserInputService for a player.
function ClientComm.getUserInputService(player)
    local state = ensureSetup(player)
    return state and state.uis
end

-- Fire a notification toast to the player's client. Silently ignored if
-- _AegisComm is not yet set up for this player.
function ClientComm.sendNotification(player, title, text, icon, duration)
    local state = playerState[player]
    if not state then return end
    state.notifEvent:FireClient(player, title, text, icon, duration)
end

-- Send a CoreGui action (SetCore or ToggleCoreGui) to the player's client
-- so that StarterGui can apply the change locally.
function ClientComm.sendCoreGuiAction(player, action, a1, a2)
    local state = playerState[player]
    if not state then return end
    state.coreGuiAction:FireClient(player, action, a1, a2)
end

return ClientComm
