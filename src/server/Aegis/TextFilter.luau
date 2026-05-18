-- TextFilter.luau - Roblox text-filter integration for AegisVM
--
-- When Constants.FILTER_TEXT is true, Runtime:tableSet calls TextFilter.apply
-- for every .Text / .PlaceholderText write on a Roblox Instance.
--
-- Two-stage pipeline applied to every string before it is written:
--   1. Name redaction - replaces team names, humanoid display names, and
--      names of models that contain a Humanoid with '#' runs of equal length.
--      The name list is rebuilt at most every NAME_TTL seconds.
--   2. TextService filter - routes the redacted string through
--      TextService:FilterStringAsync for Roblox's standard chat filter.
--
-- Cache behaviour:
--   Final results (after both stages) are stored keyed by the original raw
--   string.  If the result is more than 50% '#' characters the entry is not
--   cached, so the next write of that string retries from scratch.
--
-- Async vs sync (controlled by Constants.FILTER_ASYNC):
--   true  - raw text is written immediately; a task.spawn applies the
--           fully-filtered result once both pipeline stages complete.
--   false - the assignment yields until both stages finish, then writes once.

local Constants   = require(script.Parent.Constants)
local TextService = game:GetService("TextService")
local Teams       = game:GetService("Teams")
local Workspace   = game:GetService("Workspace")

local TextFilter = {}

-- ─── Result cache ────────────────────────────────────────────────────────────

-- Shared across all Runtime instances: raw string -> fully filtered string.
local cache = {}

local function hashFraction(s)
    if #s == 0 then return 0 end
    local _, count = string.gsub(s, "#", "")
    return count / #s
end

-- ─── Sensitive name list ─────────────────────────────────────────────────────

-- How often (seconds) to rebuild the name list.
local NAME_TTL      = 5
local namePatterns  = {}   -- list of compiled Lua patterns
local namesCachedAt = 0

-- Build a case-insensitive Lua pattern for a literal string.
-- Each letter becomes [Xx], Lua special chars are escaped.
local function buildPattern(name)
    local escaped = name:gsub("([%(%)%.%%%+%-%*%?%[%^%$])", "%%%1")
    return (escaped:gsub("%a", function(c)
        return "[" .. c:upper() .. c:lower() .. "]"
    end))
end

-- Collect team names, humanoid display names, and names of models that
-- contain a Humanoid. Names shorter than 3 characters are skipped to
-- reduce false positives. Rebuilds at most every NAME_TTL seconds.
local function buildNamePatterns()
    if tick() - namesCachedAt < NAME_TTL then return end
    namesCachedAt = tick()

    local seen     = {}
    local patterns = {}

    local function add(name)
        if type(name) ~= "string" or #name < 3 then return end
        local lower = name:lower()
        if seen[lower] then return end
        seen[lower] = true
        patterns[#patterns + 1] = buildPattern(name)
    end

    -- Team names
    local ok1, teams = pcall(function() return Teams:GetTeams() end)
    if ok1 then
        for _, team in ipairs(teams) do
            pcall(function() add(team.Name) end)
        end
    end

    -- Humanoid display names and their parent model names
    local ok2, descs = pcall(function() return Workspace:GetDescendants() end)
    if ok2 then
        for _, desc in ipairs(descs) do
            local ok3, cn = pcall(function() return desc.ClassName end)
            if ok3 and cn == "Humanoid" then
                pcall(function() add(desc.DisplayName) end)
                pcall(function()
                    local parent = desc.Parent
                    if parent then add(parent.Name) end
                end)
            end
        end
    end

    namePatterns = patterns
end

-- Replace every occurrence of each sensitive name in text with '#' runs
-- of matching length. Operates on the already-built namePatterns list.
local function redactNames(text)
    buildNamePatterns()
    for _, pattern in ipairs(namePatterns) do
        text = text:gsub(pattern, function(m)
            return string.rep("#", #m)
        end)
    end
    return text
end

-- ─── TextService stage ───────────────────────────────────────────────────────

-- Run text through both pipeline stages, yielding until done.
-- Returns the fully filtered string, or the best available fallback.
local function filterSync(text, userId)
    if cache[text] then return cache[text] end

    -- Stage 1: name redaction (fast, no yield)
    local redacted = redactNames(text)

    -- Stage 2: TextService (yields)
    local ok, result = pcall(function()
        return TextService:FilterStringAsync(redacted, userId)
    end)
    local filtered
    if ok and result ~= nil then
        local ok2, s = pcall(function()
            return result:GetNonChatStringForBroadcastAsync()
        end)
        filtered = (ok2 and type(s) == "string") and s or redacted
    else
        filtered = redacted
    end

    if hashFraction(filtered) > 0.5 then
        cache[text] = nil
        return filtered
    end

    cache[text] = filtered
    return filtered
end

-- ─── Public API ──────────────────────────────────────────────────────────────

-- Apply the full filter pipeline to a property on a Roblox Instance.
--   instance : Roblox Instance (userdata)
--   key      : "Text" or "PlaceholderText"
--   value    : the raw string the guest script tried to assign
--   userId   : fromUserId for TextService (defaults to 0)
function TextFilter.apply(instance, key, value, userId)
    userId = userId or 0

    if Constants.FILTER_ASYNC then
        -- Write raw text immediately so there is no visible blank period.
        pcall(function() instance[key] = value end)

        -- Already cached - apply synchronously without spawning.
        if cache[value] ~= nil then
            local cached = cache[value]
            pcall(function() instance[key] = cached end)
            return
        end

        task.spawn(function()
            local filtered = filterSync(value, userId)
            pcall(function()
                -- Only overwrite if the property still holds the raw value;
                -- the guest may have assigned something else in the meantime.
                if instance[key] == value then
                    instance[key] = filtered
                end
            end)
        end)
    else
        local filtered = filterSync(value, userId)
        pcall(function() instance[key] = filtered end)
    end
end

return TextFilter
