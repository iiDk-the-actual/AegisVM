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
local comms         = script.Parent
local mouseUp       = comms:WaitForChild("MouseUpdate",       10)
local inputEvent    = comms:WaitForChild("InputEvent",        10)
local notifEvent    = comms:WaitForChild("NotificationEvent", 10)
local coreGuiEvent  = comms:WaitForChild("CoreGuiAction",     10)
local cameraUpdate  = comms:WaitForChild("CameraUpdate",      10)
local cameraCommand = comms:WaitForChild("CameraCommand",     10)

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

    if cameraUpdate then
        local cam = workspace.CurrentCamera
        if cam then
            local camTypeOk, camTypeName = pcall(function() return cam.CameraType.Name end)
            cameraUpdate:FireServer({
                FieldOfView  = cam.FieldOfView,
                CFrame       = cam.CFrame,
                Focus        = cam.Focus,
                CameraType   = camTypeOk and camTypeName or "Custom",
                ViewportSize = cam.ViewportSize,
                HeadLocked   = cam.HeadLocked,
            })
        end
    end
end)

-- ─── Mouse button and wheel events (immediate) ───────────────────────
-- Also send current mouse data on click/release so the server has an
-- up-to-date position at the moment the event fires (issue #22).

local function sendMouseNow()
    local ok, delta = pcall(function() return UIS:GetMouseDelta() end)
    mouseUp:FireServer({
        x      = mouse.X,
        y      = mouse.Y,
        hit    = mouse.Hit,
        target = mouse.Target,
        deltaX = ok and delta.X or 0,
        deltaY = ok and delta.Y or 0,
    })
end

mouse.Button1Down:Connect(function()   sendMouseNow() inputEvent:FireServer("Button1Down",   {}) end)
mouse.Button1Up:Connect(function()     sendMouseNow() inputEvent:FireServer("Button1Up",     {}) end)
mouse.Button2Down:Connect(function()   sendMouseNow() inputEvent:FireServer("Button2Down",   {}) end)
mouse.Button2Up:Connect(function()     sendMouseNow() inputEvent:FireServer("Button2Up",     {}) end)
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

-- ─── CoreGui action handler ──────────────────────────────────────────────────

local StarterGui = game:GetService("StarterGui")

local function showNotification(title, text, icon, duration)
    pcall(function()
        StarterGui:SetCore("SendNotification", {
            Title    = tostring(title or ""),
            Text     = tostring(text  or ""),
            Icon     = (type(icon) == "string") and icon or nil,
            Duration = tonumber(duration) or 5,
        })
    end)
end

local function handleCoreGuiAction(action, a1, a2)
    if action == "ToggleCoreGui" then
        -- Emulate CoreGui:ToggleCoreGui(coreGuiType, enabled) on the client
        -- by delegating to StarterGui:SetCoreGuiEnabled.
        pcall(function()
            StarterGui:SetCoreGuiEnabled(a1, a2)
        end)
    elseif action == "SetCore" then
        -- Forward generic SetCore calls (e.g. TopbarEnabled) to the client.
        pcall(function()
            StarterGui:SetCore(a1, a2)
        end)
    end
end

-- ─── Wire up CoreGui remote events ──────────────────────────────────────────

if notifEvent then
    notifEvent.OnClientEvent:Connect(function(title, text, icon, duration)
        showNotification(title, text, icon, duration)
    end)
end

if coreGuiEvent then
    coreGuiEvent.OnClientEvent:Connect(function(action, a1, a2)
        handleCoreGuiAction(action, a1, a2)
    end)
end

-- ─── Camera command handler ──────────────────────────────────────────────────
-- Server pushes property writes (e.g. FieldOfView, CFrame, CameraType) to the
-- client's workspace.CurrentCamera. CameraType arrives as a string name and is
-- converted back to the Enum item before assignment.

if cameraCommand then
    cameraCommand.OnClientEvent:Connect(function(prop, value)
        local cam = workspace.CurrentCamera
        if not cam then return end
        if prop == "CameraType" then
            local ok, enumVal = pcall(function() return Enum.CameraType[value] end)
            pcall(function() cam.CameraType = ok and enumVal or value end)
        else
            pcall(function() cam[prop] = value end)
        end
    end)
end
