--[[
    Scope.luau - Lexical scope chain and environment manager

    Implements Luau's scoping rules:

    - Every block (do/end, loop body, function body, if branch ...) opens a
      new child scope.
    - Scopes form a singly-linked chain up to the global scope (parent = nil).
    - Variable look-up walks the chain outward; the first scope that *declares*
      the name wins.
    - `local x` creates a new binding in the current (innermost) scope,
      shadowing any outer binding with the same name.
    - Assigning to an undeclared name (no `local`) walks the chain; if the
      name is found in any ancestor the assignment updates it there;
      otherwise the assignment goes to the global scope.
    - Closures capture the scope in which they are defined.  Because all
      variables live inside Lua table cells (scope.variables[name]), sharing
      between sibling closures is automatic - they both reference the same
      parent scope table.

    Implementation note on nil values
    ----------------------------------
    Lua tables cannot store nil at a key (the key disappears).  We use a
    separate `declared` boolean table to track which names have been defined
    in a scope.  The actual value is in `variables[name]` and may be nil.

    Const variables
    ---------------
    Variables declared with `local x <const> = value` are tracked in a
    separate `consts` boolean table.  Any attempt to assign to a const
    variable raises a RuntimeError.

    To-be-closed variables
    ----------------------
    Variables declared with `local x <close> = value` are tracked in a
    `closeList` array (in declaration order).  When the owning block
    exits (normal, break, continue, return, or error), the Runtime
    iterates `closeList` in reverse and calls `__close(value, err)` on
    each value whose metatable provides a `__close` metamethod.
]]

local Error = require(script.Parent.Error)

local Scope = {}
Scope.__index = Scope

-- --- Constructor --------------------------------------------------------

-- Create a new scope.
-- parent : enclosing Scope (nil => this is the global scope)
-- name   : optional string label used in error messages / debug output
function Scope.new(parent, name)
    return setmetatable({
        parent    = parent,
        name      = name or "block",
        variables = {},   -- [varName] = value  (value may be nil)
        declared  = {},   -- [varName] = true   (existence flag)
        consts    = {},   -- [varName] = true   (const flag)
        closeList = {},   -- ordered list of names declared with <close>
    }, Scope)
end

-- Convenience: create the top-level global scope
function Scope.global(name)
    return Scope.new(nil, name or "global")
end

-- Spawn a child scope (inherits from self)
function Scope:child(name)
    return Scope.new(self, name)
end

-- --- Declaration --------------------------------------------------------

-- Declare a new local variable in THIS scope only.
-- Shadows any same-named variable in ancestor scopes.
-- isConst: if true, the variable cannot be reassigned after declaration.
-- isClose: if true, the variable is to-be-closed; appended to closeList.
function Scope:declareLocal(name, value, isConst, isClose)
    self.declared[name]  = true
    self.variables[name] = value
    if isConst then
        self.consts[name] = true
    end
    if isClose then
        self.closeList[#self.closeList + 1] = name
    end
end

-- Declare multiple locals at once (pairs of name/value).
-- Extra values are discarded; missing values default to nil.
function Scope:declareLocals(names, values)
    for i, name in ipairs(names) do
        self:declareLocal(name, values and values[i])
    end
end

-- --- Look-up ------------------------------------------------------------

-- Find the innermost scope that declares `name`, or nil if not found.
function Scope:findOwner(name)
    local s = self
    while s do
        if s.declared[name] then return s end
        s = s.parent
    end
    return nil
end

-- Read a variable.  Returns nil if not declared anywhere.
function Scope:get(name)
    local owner = self:findOwner(name)
    if owner then
        return owner.variables[name]
    end
    return nil
end

-- Test whether a variable is declared anywhere in the chain.
function Scope:has(name)
    return self:findOwner(name) ~= nil
end

-- --- Assignment ---------------------------------------------------------

-- Assign to an existing variable in the chain.
-- Returns true if the variable was found and updated.
-- Returns false if the variable is not declared anywhere.
-- Raises a RuntimeError if the variable is declared but marked const.
function Scope:set(name, value)
    local owner = self:findOwner(name)
    if owner then
        if owner.consts[name] then
            error(Error.runtime(
                "attempt to assign to const variable '" .. name .. "'"
            ), 0)
        end
        owner.variables[name] = value
        return true
    end
    return false
end

-- Assign per Luau semantics:
-- - If the name is declared anywhere in the chain, update it there.
-- - Otherwise, create it at the global (root) scope.
function Scope:assign(name, value)
    if not self:set(name, value) then
        self:getGlobalScope():declareLocal(name, value)
    end
end

-- --- Global scope helpers -----------------------------------------------

-- Walk to the root (global) scope.
function Scope:getGlobalScope()
    local s = self
    while s.parent do
        s = s.parent
    end
    return s
end

-- Declare a variable directly in the global scope.
function Scope:defineGlobal(name, value)
    self:getGlobalScope():declareLocal(name, value)
end

-- --- Debug --------------------------------------------------------------

-- Return a string listing all variables visible from this scope.
function Scope:dump(indent)
    indent = indent or 0
    local pad = string.rep("  ", indent)
    local lines = { string.format("%s[Scope: %s]", pad, self.name) }
    for name, _ in pairs(self.declared) do
        lines[#lines + 1] = string.format(
            "%s  %s = %s%s", pad, name,
            tostring(self.variables[name]),
            self.consts[name] and " <const>" or ""
        )
    end
    if self.parent then
        lines[#lines + 1] = self.parent:dump(indent + 1)
    end
    return table.concat(lines, "\n")
end

return Scope
