-- TextFilter.luau - Roblox text-filter integration for AegisVM
--
-- When Constants.FILTER_TEXT is true, Runtime:tableSet calls TextFilter.apply
-- for every .Text / .PlaceholderText write on a Roblox Instance.
--
-- Cache behaviour:
--   Filtered results are stored in a module-level table keyed by the raw
--   string.  If the filtered result is more than 50% '#' characters the
--   entry is NOT cached (or is cleared if it was previously cached), so
--   the next write of that string will attempt a fresh filter pass.
--
-- Async vs sync (controlled by Constants.FILTER_ASYNC):
--   true  - raw text is written immediately; a task.spawn updates the
--           property once filtering completes.
--   false - the assignment yields until filtering finishes, then writes
--           the filtered text.

local Constants   = require(script.Parent.Constants)
local TextService = game:GetService("TextService")

local TextFilter = {}

-- Shared cache across all Runtime instances.
local cache = {}

-- Returns the fraction of characters in s that are '#'.
local function hashFraction(s)
    if #s == 0 then return 0 end
    local _, count = string.gsub(s, "#", "")
    return count / #s
end

-- Filter text through TextService, yielding until done.
-- Returns the filtered string, or the original if filtering fails.
local function filterSync(text, userId)
    if cache[text] then return cache[text] end

    local ok, result = pcall(function()
        return TextService:FilterStringAsync(text, userId)
    end)
    if not ok or result == nil then return text end

    local ok2, filtered = pcall(function()
        return result:GetNonChatStringForBroadcastAsync()
    end)
    if not ok2 or type(filtered) ~= "string" then return text end

    if hashFraction(filtered) > 0.5 then
        -- Heavily censored: clear any stale cache entry and skip caching.
        cache[text] = nil
        return filtered
    end

    cache[text] = filtered
    return filtered
end

-- Apply the text filter to a property on a Roblox Instance.
-- instance : Roblox Instance (userdata)
-- key      : "Text" or "PlaceholderText"
-- value    : the raw string the guest script tried to assign
-- userId   : fromUserId for TextService (defaults to 0)
function TextFilter.apply(instance, key, value, userId)
    userId = userId or 0

    if Constants.FILTER_ASYNC then
        -- Write raw text immediately so there is no visible blank period.
        pcall(function() instance[key] = value end)

        -- If already cached, apply right away without spawning.
        if cache[value] ~= nil then
            local cached = cache[value]
            pcall(function() instance[key] = cached end)
            return
        end

        task.spawn(function()
            local filtered = filterSync(value, userId)
            -- Guard: only overwrite if the property still holds the raw value
            -- (the guest may have changed it again between now and then).
            pcall(function()
                if instance[key] == value then
                    instance[key] = filtered
                end
            end)
        end)
    else
        -- Synchronous path: yield until filtering is done, then write once.
        local filtered = filterSync(value, userId)
        pcall(function() instance[key] = filtered end)
    end
end

return TextFilter
