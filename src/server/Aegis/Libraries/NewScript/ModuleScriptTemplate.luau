-- _aegis is not a direct child of this script; it lives in ReplicatedStorage
-- and is pointed to by the _aegisRef ObjectValue child. This keeps _aegis out
-- of FindFirstChildWhichIsA("ModuleScript") searches on this instance.
local _aegisRef = script:WaitForChild("_aegisRef")
local _aegisModule = _aegisRef.Value
local _aegis = require(_aegisModule)
-- Clean up: destroy the pointer and remove the clone from RS. require() has
-- already cached the result so _aegis stays alive without occupying RS.
_aegisRef:Destroy()
pcall(function() _aegisModule.Parent = nil end)
-- _aegis.run returns (true, value) on success or (false, err) on failure.
-- Roblox's native require expects exactly one return value from a ModuleScript,
-- so we unpack and return only the module result (index 2), re-raising errors.
local ok, value = _aegis.run(script:GetAttribute("Source"), script.Name, { globals = { script = script } })
if not ok then error(value, 2) end
return value
