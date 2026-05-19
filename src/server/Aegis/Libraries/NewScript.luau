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
    -- IMPORTANT: the clone must NOT be a direct child of obj. If it were,
    -- FindFirstChildWhichIsA("ModuleScript", true) calls inside the module source
    -- would find _aegis (which is itself a ModuleScript) before the real inner
    -- modules, breaking require(). Instead, park it in ReplicatedStorage and
    -- point to it via an ObjectValue child (_aegisRef). ObjectValue is not a
    -- ModuleScript, so child searches on obj never see it.
    local aegisClone = script.Parent.Parent:Clone()
    aegisClone.Name = "_aegis"

    local ref = Instance.new("ObjectValue")
    ref.Name = "_aegisRef"
    ref.Value = aegisClone
    ref.Parent = obj

    -- Parent the clone after the ObjectValue is set up so replication order is
    -- consistent: ref arrives with obj, clone arrives in RS simultaneously.
    aegisClone.Parent = game:GetService("ReplicatedStorage")

    obj.Parent = opts.parent
    return obj
end

return NewScript
