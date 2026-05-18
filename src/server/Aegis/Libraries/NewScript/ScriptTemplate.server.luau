local _aegis = require(script:FindFirstChild("_aegis"))
local globals = { script = script }

-- If an owner UserId was stored by NewScript (REPLICATE_SCRIPTS mode), resolve
-- the Player and inject owner + CLIENT_COMMUNICATION into the sandbox.
local ownerUserId = script:GetAttribute("_AegisOwnerId")
if ownerUserId then
    local ok, owner = pcall(function()
        return game:GetService("Players"):GetPlayerByUserId(ownerUserId)
    end)
    if ok and owner then
        globals.owner = owner
        globals.CLIENT_COMMUNICATION = true
    end
end

_aegis.run(script:GetAttribute("Source"), script.Name, { globals = globals })
