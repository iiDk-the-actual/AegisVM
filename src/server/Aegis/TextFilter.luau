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
local RunService  = game:GetService("RunService")

local isServer = RunService:IsServer()

-- Client-only: lazy reference to the FilterRequest RemoteFunction in _AegisComm.
-- Resolved on first filter call so we don't block module load.
local filterRemote = nil

local function getFilterRemote()
    if filterRemote then return filterRemote end
    local ok, rf = pcall(function()
        local player = game:GetService("Players").LocalPlayer
        local gui    = player.PlayerGui:WaitForChild("_AegisComm", 10)
        if not gui then return nil end
        return gui:WaitForChild("FilterRequest", 10)
    end)
    if ok and rf then filterRemote = rf end
    return filterRemote
end

local TextFilter = {}

-- ─── Result cache ────────────────────────────────────────────────────────────

-- Shared across all Runtime instances: raw string -> fully filtered string.
local cache = {}

-- Per-instance archive of the raw text last assigned by guest code.
-- Keyed by Instance (weak) so GC'd instances do not accumulate.
-- Structure: rawTexts[instance][key] = rawString
local rawTexts = {}
setmetatable(rawTexts, { __mode = "k" })

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
-- Returns the fully filtered string, or the name-redacted fallback on any
-- service error.  Results are only cached when filtering fully succeeded -
-- failures (rate limit, timeout, service down) are never cached so the next
-- call retries rather than permanently treating the text as clean.
local function filterSync(text, userId)
    if cache[text] then return cache[text] end

    -- Stage 1: name redaction (fast, no yield)
    local redacted = redactNames(text)

    -- On the client, FilterStringAsync is unavailable. Route through the
    -- FilterRequest RemoteFunction so the server runs the full pipeline.
    if not isServer then
        local rf = getFilterRemote()
        if not rf then return redacted end
        local ok, filtered = pcall(function()
            return rf:InvokeServer(text)
        end)
        if not ok or type(filtered) ~= "string" then return redacted end
        if hashFraction(filtered) <= 0.5 then
            cache[text] = filtered
        end
        return filtered
    end

    -- Stage 2: TextService (yields, may be rate-limited or unavailable)
    local ok, result = pcall(function()
        return TextService:FilterStringAsync(redacted, userId)
    end)

    if not ok or result == nil then
        -- FilterStringAsync failed (rate limit, timeout, service down).
        -- Return name-redacted text WITHOUT caching so the next call retries.
        return redacted
    end

    -- Extract the filtered string using the configured strictness level.
    local ok2, filtered = pcall(function()
        if Constants.FILTER_STRICT then
            -- Chat-level filter: stricter, scoped to the player's settings.
            return result:GetChatForUserAsync(userId)
        else
            -- Broadcast filter: lenient, safe for all-player UI text.
            return result:GetNonChatStringForBroadcastAsync()
        end
    end)

    if not ok2 or type(filtered) ~= "string" then
        -- GetChatForUserAsync / GetNonChatStringForBroadcastAsync failed.
        -- Again, do not cache - let the next call retry.
        return redacted
    end

    -- Cache only when filtering fully succeeded and the result is not mostly
    -- hashes (a mostly-hashed result suggests the filter is unreliable for
    -- this input; retrying may produce a better result).
    if hashFraction(filtered) <= 0.5 then
        cache[text] = filtered
    end

    return filtered
end

-- ─── Public API ──────────────────────────────────────────────────────────────

-- Return the raw text that guest code last assigned to instance[key].
-- Returns nil if no assignment has been archived for this instance/key.
function TextFilter.getRaw(instance, key)
    local t = rawTexts[instance]
    return t and t[key]
end

-- Apply the full filter pipeline to a property on a Roblox Instance.
--   instance : Roblox Instance (userdata)
--   key      : "Text" or "PlaceholderText"
--   value    : the raw string the guest script tried to assign
--   userId   : fromUserId for TextService (defaults to 0)
--
-- The raw value is NEVER written to the instance.  It is stored in rawTexts
-- so that VM reads of the property return the guest-visible value.  Only the
-- filtered result is written to the actual Roblox property.
function TextFilter.apply(instance, key, value, userId)
    userId = userId or 0

    -- Archive the raw text so VM tableGet can return it on read.
    if not rawTexts[instance] then rawTexts[instance] = {} end
    rawTexts[instance][key] = value

    if Constants.FILTER_ASYNC then
        -- Already cached - apply the filtered result synchronously.
        if cache[value] ~= nil then
            local cached = cache[value]
            pcall(function() instance[key] = cached end)
            return
        end

        -- Not cached - filter in the background and write when done.
        task.spawn(function()
            local filtered = filterSync(value, userId)
            pcall(function() instance[key] = filtered end)
        end)
    else
        local filtered = filterSync(value, userId)
        pcall(function() instance[key] = filtered end)
    end
end

-- Filter a plain string through the full pipeline and return the result.
-- Yields until filtering is complete.  Use for print/warn or notification text.
function TextFilter.filterString(text, userId)
    userId = userId or 0
    return filterSync(text, userId)
end

return TextFilter
