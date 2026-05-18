local _aegis = require(script:FindFirstChild("_aegis"))
-- _aegis.run returns (true, value) on success or (false, err) on failure.
-- Roblox's native require expects exactly one return value from a ModuleScript,
-- so we unpack and return only the module result (index 2), re-raising errors.
local ok, value = _aegis.run(script:GetAttribute("Source"), script.Name, { globals = { script = script } })
if not ok then error(value, 2) end
return value
