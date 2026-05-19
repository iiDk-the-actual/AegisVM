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

local NewScript = {}

-- Monotonic counter used to give each _aegis clone a unique name in RS so
-- multiple NewScript modules never interfere with each other's lookup.
local nextId = 0

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

    -- Clone the entire Aegis module tree so each sandboxed script has its
    -- own self-contained interpreter with no shared state.
    -- script.Parent is Libraries; script.Parent.Parent is Aegis itself.
    --
    -- The clone lives in ReplicatedStorage rather than as a direct child of obj.
    -- If it were a child, FindFirstChildWhichIsA("ModuleScript", true) calls
    -- inside the module source would find _aegis before real inner modules.
    -- Templates locate the clone via the "_aegisRef" attribute (a plain string
    -- holding the unique name in RS). Attributes are invisible to child searches,
    -- so guest code cannot accidentally stumble on the reference.
    nextId = nextId + 1
    local aegisName = "_aegis_" .. nextId

    local aegisClone = script.Parent.Parent:Clone()
    aegisClone.Name = aegisName
    aegisClone.Parent = game:GetService("ReplicatedStorage")

    obj:SetAttribute("_aegisRef", aegisName)

    obj.Parent = opts.parent
    return obj
end

return NewScript
