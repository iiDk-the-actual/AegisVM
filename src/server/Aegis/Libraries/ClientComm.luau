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

local ClientAgent = script:WaitForChild("ClientAgent")

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
        elseif kind == "InputEnded" then
            if data.KeyCode then keyState[data.KeyCode] = nil end
            ieBE:Fire(data)
        elseif kind == "InputChanged" then
            icBE:Fire(data)
        elseif kind == "TextBoxFocused" then
            tbfBE:Fire(data)
        elseif kind == "TextBoxFocusReleased" then
            tbrBE:Fire(data)
        end
    end)

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

    local state = { comms = comms, mouse = mouse, uis = uis }
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

-- Return the emulated UserInputService for a player.
function ClientComm.getUserInputService(player)
    local state = ensureSetup(player)
    return state and state.uis
end

return ClientComm
