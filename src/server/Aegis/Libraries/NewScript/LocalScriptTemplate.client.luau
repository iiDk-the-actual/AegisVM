-- _aegisRef points to the _aegis clone in ReplicatedStorage. Using an
-- ObjectValue instead of a direct child keeps _aegis out of
-- FindFirstChildWhichIsA("ModuleScript") searches on this script.
local _aegisRef = script:WaitForChild("_aegisRef")
local _aegis = require(_aegisRef.Value)
-- Destroy the local pointer. Don't attempt to nil-parent the RS clone:
-- clients cannot modify server-owned instances in ReplicatedStorage.
_aegisRef:Destroy()
_aegis.run(script:GetAttribute("Source"), script.Name, { globals = { script = script } })
