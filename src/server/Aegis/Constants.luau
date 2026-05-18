-- Constants.luau - Static compile-time values for AegisVM
--
-- All hard-coded strings and version identifiers live here so they
-- have a single source of truth and are easy to audit or update.

local Constants = {}

-- Interpreter version string exposed to guest code as _AEGIS_VERSION.
Constants.VERSION = "5"

-- Verbosity levels for interpreter error output.
-- Controls how much detail appears in runtime error messages and
-- whether guest print/warn calls are forwarded to the output window.
--
--   SUPPRESS (0) - suppress ALL output: guest print/warn are swallowed,
--                  AegisVM emits no automatic warnings, error strings are
--                  bare messages.  Use when embedding AegisVM silently.
--   SILENT   (1) - no automatic AegisVM warns; error strings are bare
--                  messages; guest print/warn pass through.
--   BRIEF    (2) - automatic AegisVM warns fire; error strings are bare
--                  messages.
--   STANDARD (3) - automatic warns fire; error strings include
--                  [Category:line] prefix.
--   VERBOSE  (4) - automatic warns fire; error strings include a full
--                  call-stack trace.
--
-- Set Constants.VERBOSITY to one of these values to change globally.
Constants.VERBOSITY_SUPPRESS = 0
Constants.VERBOSITY_SILENT   = 1
Constants.VERBOSITY_BRIEF    = 2
Constants.VERBOSITY_STANDARD = 3
Constants.VERBOSITY_VERBOSE  = 4
Constants.VERBOSITY          = Constants.VERBOSITY_VERBOSE

-- Name shown in error messages and chunk names when no name is given.
Constants.INTERPRETER_NAME = "AegisVM"

-- Default chunk name used by loadstring / load when none is supplied.
Constants.DEFAULT_CHUNK_NAME = "loadstring"

-- Base URL for the rbxm conversion service used by WebRbxmParser.
-- Source for this service is available at https://github.com/AegisLua/API
Constants.CONVERT_BASE_URL = "https://api.aegislua.xyz/rbxm?url="

-- When true, require(numericId) inside the sandbox fetches the asset via
-- WebRbxmParser, finds the first child named "MainModule", and requires it.
-- When false, require(numericId) passes the number straight to native require.
Constants.REQUIRE_FETCH_NUMERIC = true

-- When true, AegisVM emulates client-side APIs (LocalPlayer, RenderStepped,
-- GetMouse, UserInputService, CoreGui, etc.) on the server by injecting a
-- LocalScript into the owner player's PlayerGui and communicating over
-- RemoteEvents.  The owner is resolved in order:
--   1. The "owner" global in the sandbox scope (if it is a Player)
--   2. The first Player found by walking the "script" global's parent chain
--   3. The first Player whose name matches a Model found in that chain
--   4. nil (a warning is emitted unless VERBOSITY is SUPPRESS)
Constants.CLIENT_COMMUNICATION = false

-- When true, any .Text or .PlaceholderText assignment on a Roblox Instance
-- is routed through Roblox's TextService filter before being applied.
-- Results are cached so repeated assignments of the same string only filter
-- once.  If the filtered result is more than 50% hashtag characters the
-- cache entry is not stored and the text will be re-filtered next time.
Constants.FILTER_TEXT = false

-- When true (and FILTER_TEXT is also true), the raw text is applied
-- immediately and the filtered replacement is applied asynchronously in a
-- spawned task.  When false the assignment yields until filtering finishes.
Constants.FILTER_ASYNC = true

return Constants
