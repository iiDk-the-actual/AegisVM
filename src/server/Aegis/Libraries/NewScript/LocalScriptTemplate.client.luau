-- Locate the private _aegis clone in ReplicatedStorage via the "_aegisRef"
-- attribute. WaitForChild handles replication delay on the client.
local _aegis = require(game:GetService("ReplicatedStorage"):WaitForChild(
    script:GetAttribute("_aegisRef")
))
_aegis.run(script:GetAttribute("Source"), script.Name, { globals = { script = script } })
