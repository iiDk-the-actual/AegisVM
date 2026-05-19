-- Locate the private _aegis clone via the "_aegisRef" attribute (a string
-- holding its unique name in ReplicatedStorage). Using an attribute instead of
-- a child means FindFirstChildWhichIsA("ModuleScript") searches on this script
-- never see _aegis, and the reference survives multiple require() calls because
-- attributes are not destroyed by cleanup logic.
local _aegis = require(game:GetService("ReplicatedStorage"):WaitForChild(
    script:GetAttribute("_aegisRef")
))
-- _aegis.run returns (true, value) on success or (false, err) on failure.
-- Roblox's native require expects exactly one return value from a ModuleScript,
-- so we unpack and return only the module result (index 2), re-raising errors.
local ok, value = _aegis.run(script:GetAttribute("Source"), script.Name, { globals = { script = script } })
if not ok then error(value, 2) end
return value
