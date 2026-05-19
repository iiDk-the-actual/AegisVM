local _aegisChild = script:FindFirstChild("_aegis")
local _aegis = require(_aegisChild)
-- Detach _aegis immediately so FindFirstChildWhichIsA/FindFirstChild calls inside
-- the script source cannot find it and mistake it for the script's own children.
_aegisChild.Parent = nil
_aegis.run(script:GetAttribute("Source"), script.Name, { globals = { script = script } })
