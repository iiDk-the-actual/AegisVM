local _aegisChild = script:FindFirstChild("_aegis")
local _aegis = require(_aegisChild)
-- Detach _aegis immediately so FindFirstChildWhichIsA/FindFirstChild calls inside
-- the module source cannot find it and mistake it for the module's own children.
_aegisChild.Parent = nil
-- _aegis.run returns (true, value) on success or (false, err) on failure.
-- Roblox's native require expects exactly one return value from a ModuleScript,
-- so we unpack and return only the module result (index 2), re-raising errors.
local ok, value = _aegis.run(script:GetAttribute("Source"), script.Name, { globals = { script = script } })
if not ok then error(value, 2) end
return value
