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

-- ─── Notification UI ────────────────────────────────────────────────────────

local TweenService = game:GetService("TweenService")
local StarterGui   = game:GetService("StarterGui")

local function showNotification(title, text, icon, duration)
    duration = tonumber(duration) or 5
    title    = tostring(title or "")
    text     = tostring(text  or "")
    icon     = (type(icon) == "string") and icon or ""

    local playerGui = player.PlayerGui

    -- Shared container ScreenGui for all notifications from AegisVM
    local container = playerGui:FindFirstChild("_AegisNotifs")
    if not container then
        container = Instance.new("ScreenGui")
        container.Name           = "_AegisNotifs"
        container.ResetOnSpawn   = false
        container.DisplayOrder   = 10000
        container.IgnoreGuiInset = true
        container.Parent         = playerGui
    end

    local frameH = 72
    local gap    = 8
    local margin = 12
    local frameW = 280

    -- Stack above already-visible notifications
    local stackCount = 0
    for _, c in ipairs(container:GetChildren()) do
        if c:IsA("Frame") then stackCount = stackCount + 1 end
    end

    -- yBase: distance from bottom edge (negative = up from bottom-right anchor)
    local yBase = -(margin + frameH + stackCount * (frameH + gap))
    -- xHide: X offset that places the frame fully off the right edge
    local xHide = frameW + margin + 20

    local frame = Instance.new("Frame")
    frame.Name             = "Notification"
    frame.Size             = UDim2.new(0, frameW, 0, frameH)
    frame.AnchorPoint      = Vector2.new(1, 1)
    frame.Position         = UDim2.new(1, xHide, 1, yBase)
    frame.BackgroundColor3 = Color3.fromRGB(28, 28, 28)
    frame.BorderSizePixel  = 0
    frame.ZIndex           = 10
    frame.Parent           = container

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 8)
    corner.Parent = frame

    -- Left accent stripe
    local stripe = Instance.new("Frame")
    stripe.Name             = "Stripe"
    stripe.Size             = UDim2.new(0, 4, 1, 0)
    stripe.BackgroundColor3 = Color3.fromRGB(0, 162, 255)
    stripe.BorderSizePixel  = 0
    stripe.ZIndex           = 11
    stripe.Parent           = frame
    local sc = Instance.new("UICorner")
    sc.CornerRadius = UDim.new(0, 8)
    sc.Parent = stripe

    -- Optional icon on the left
    local contentX = 14
    if icon ~= "" then
        local img = Instance.new("ImageLabel")
        img.Name                   = "Icon"
        img.Size                   = UDim2.new(0, 44, 0, 44)
        img.Position               = UDim2.new(0, 14, 0.5, 0)
        img.AnchorPoint            = Vector2.new(0, 0.5)
        img.BackgroundTransparency = 1
        img.Image                  = icon
        img.ZIndex                 = 11
        img.Parent                 = frame
        contentX = 66
    end

    local titleLabel = Instance.new("TextLabel")
    titleLabel.Name                   = "Title"
    titleLabel.Size                   = UDim2.new(1, -(contentX + margin), 0, 22)
    titleLabel.Position               = UDim2.new(0, contentX, 0, 12)
    titleLabel.BackgroundTransparency = 1
    titleLabel.TextColor3             = Color3.fromRGB(255, 255, 255)
    titleLabel.TextSize               = 14
    titleLabel.Font                   = Enum.Font.GothamBold
    titleLabel.Text                   = title
    titleLabel.TextXAlignment         = Enum.TextXAlignment.Left
    titleLabel.TextTruncate           = Enum.TextTruncate.AtEnd
    titleLabel.ZIndex                 = 11
    titleLabel.Parent                 = frame

    local textLabel = Instance.new("TextLabel")
    textLabel.Name                    = "Body"
    textLabel.Size                    = UDim2.new(1, -(contentX + margin), 0, 28)
    textLabel.Position                = UDim2.new(0, contentX, 0, 36)
    textLabel.BackgroundTransparency  = 1
    textLabel.TextColor3              = Color3.fromRGB(180, 180, 180)
    textLabel.TextSize                = 12
    textLabel.Font                    = Enum.Font.Gotham
    textLabel.Text                    = text
    textLabel.TextXAlignment          = Enum.TextXAlignment.Left
    textLabel.TextWrapped             = true
    textLabel.TextTruncate            = Enum.TextTruncate.AtEnd
    textLabel.ZIndex                  = 11
    textLabel.Parent                  = frame

    -- Slide in from the right
    local targetPos = UDim2.new(1, -margin, 1, yBase)
    local tweenIn   = TweenService:Create(
        frame,
        TweenInfo.new(0.25, Enum.EasingStyle.Quart, Enum.EasingDirection.Out),
        { Position = targetPos }
    )
    tweenIn:Play()

    -- Auto-dismiss after duration seconds
    task.delay(duration, function()
        if not frame or not frame.Parent then return end
        local tweenOut = TweenService:Create(
            frame,
            TweenInfo.new(0.2, Enum.EasingStyle.Quart, Enum.EasingDirection.In),
            { Position = UDim2.new(1, xHide, 1, yBase) }
        )
        tweenOut:Play()
        tweenOut.Completed:Wait()
        if frame and frame.Parent then frame:Destroy() end
    end)
end

-- ─── CoreGui action handler ──────────────────────────────────────────────────

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
