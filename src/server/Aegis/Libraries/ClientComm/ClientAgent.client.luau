-- ClientAgent - AegisVM client-side communication agent
-- Runs inside the player's PlayerGui._AegisComm folder.
-- Forwards mouse position (every 0.1 s) and all input events to the server
-- so that AegisVM's CLIENT_COMMUNICATION emulation can serve them to guest
-- scripts running on the server.

local Players    = game:GetService("Players")
local UIS        = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local player = Players.LocalPlayer
local mouse  = player:GetMouse()

-- The RemoteEvents were created by ClientComm.setup() on the server before
-- this LocalScript was cloned here, so WaitForChild should return instantly.
local comms      = script.Parent
local mouseUp    = comms:WaitForChild("MouseUpdate", 10)
local inputEvent = comms:WaitForChild("InputEvent",  10)

if not mouseUp or not inputEvent then return end  -- safety: abort if setup failed

-- ─── Periodic mouse position (every 0.1 s via Heartbeat) ─────────────

local elapsed = 0
RunService.Heartbeat:Connect(function(dt)
    elapsed = elapsed + dt
    if elapsed < 0.1 then return end
    elapsed = elapsed - 0.1
    local ok, delta = pcall(function() return UIS:GetMouseDelta() end)
    mouseUp:FireServer({
        x      = mouse.X,
        y      = mouse.Y,
        hit    = mouse.Hit,
        target = mouse.Target,
        deltaX = ok and delta.X or 0,
        deltaY = ok and delta.Y or 0,
    })
end)

-- ─── Mouse button and wheel events (immediate) ───────────────────────

mouse.Button1Down:Connect(function()   inputEvent:FireServer("Button1Down",   {}) end)
mouse.Button1Up:Connect(function()     inputEvent:FireServer("Button1Up",     {}) end)
mouse.Button2Down:Connect(function()   inputEvent:FireServer("Button2Down",   {}) end)
mouse.Button2Up:Connect(function()     inputEvent:FireServer("Button2Up",     {}) end)
mouse.WheelForward:Connect(function()  inputEvent:FireServer("WheelForward",  {}) end)
mouse.WheelBackward:Connect(function() inputEvent:FireServer("WheelBackward", {}) end)

-- ─── UserInputService keyboard / gamepad events ──────────────────────

local function fwd(kind)
    return function(input, gameProcessed)
        if gameProcessed then return end
        inputEvent:FireServer(kind, {
            KeyCode       = input.KeyCode,
            UserInputType = input.UserInputType,
            Position      = input.Position,
            Delta         = input.Delta,
        })
    end
end

UIS.InputBegan:Connect(fwd("InputBegan"))
UIS.InputEnded:Connect(fwd("InputEnded"))
UIS.InputChanged:Connect(fwd("InputChanged"))

-- ─── TextBox focus events ────────────────────────────────────────────

UIS.TextBoxFocused:Connect(function(tb)
    inputEvent:FireServer("TextBoxFocused", tb)
end)

UIS.TextBoxFocusReleased:Connect(function(tb)
    inputEvent:FireServer("TextBoxFocusReleased", tb)
end)
