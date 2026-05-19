-- NewScript.luau - Script instance factory for AegisVM sandboxed scripts
--
-- Clones a template Script/LocalScript/ModuleScript, stores the original
-- source as a "Source" attribute, and injects a private _aegis module clone
-- so the sandboxed script can run without sharing interpreter state.
--
-- Public API:
--
--     NewScript.new(opts)
--         opts.type    -- "Script" | "LocalScript" | "ModuleScript"
--         opts.source  -- Luau source string
--         opts.parent  -- Instance to parent the new script to
--         returns the new script Instance

local RS = game:GetService("ReplicatedStorage")

-- All NewScript modules in this session share one _aegis clone in RS.
-- The GUID suffix makes the name unique across sessions and games so it
-- does not collide with anything a developer or guest script might create.
local aegisName = "_aegis_" .. game:GetService("HttpService"):GenerateGUID(false)
local sharedAegis = RS:FindFirstChild(aegisName)
if not sharedAegis then
    sharedAegis = script.Parent.Parent:Clone()
    sharedAegis.Name = aegisName
    sharedAegis.Parent = RS
end

local NewScript = {}

function NewScript.new(opts)
    local obj

    if opts.type == "ModuleScript" then
        obj = script:WaitForChild("ModuleScriptTemplate"):Clone()
    elseif opts.type == "LocalScript" then
        obj = script:WaitForChild("LocalScriptTemplate"):Clone()
    else
        obj = script:WaitForChild("ScriptTemplate"):Clone()
    end

    obj:SetAttribute("Source", opts.source or "")

    -- When an owner UserId is provided (e.g. from REPLICATE_SCRIPTS mode),
    -- store it as an attribute so ScriptTemplate can resolve the Player and
    -- inject it as the sandbox "owner" global.
    if opts.ownerUserId then
        obj:SetAttribute("_AegisOwnerId", opts.ownerUserId)
    end

    -- Point to the shared _aegis clone via a string attribute. Attributes are
    -- invisible to FindFirstChild/FindFirstChildWhichIsA searches, so guest
    -- code inside the module source cannot accidentally find _aegis.
    obj:SetAttribute("_aegisRef", aegisName)

    obj.Parent = opts.parent
    return obj
end

return NewScript
