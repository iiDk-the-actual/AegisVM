-- Constants.luau - Static compile-time values for AegisVM
--
-- All hard-coded strings and version identifiers live here so they
-- have a single source of truth and are easy to audit or update.

local Constants = {}

-- Interpreter version string exposed to guest code as _AEGIS_VERSION.
Constants.VERSION = "4"

-- Verbosity levels for interpreter error output.
-- Controls how much detail appears in runtime error messages and whether
-- the interpreter emits automatic warnings for errors in callbacks.
--
--   SILENT   (0) - no automatic warns; error strings contain the bare message only
--   BRIEF    (1) - automatic warns fire; error strings contain the bare message only
--   STANDARD (2) - automatic warns fire; error strings are "[Category:line] message"
--   VERBOSE  (3) - automatic warns fire; error strings include a full call-stack trace
--
-- Set Constants.VERBOSITY to one of these values to change behaviour globally.
Constants.VERBOSITY_SILENT   = 0
Constants.VERBOSITY_BRIEF    = 1
Constants.VERBOSITY_STANDARD = 2
Constants.VERBOSITY_VERBOSE  = 3
Constants.VERBOSITY          = Constants.VERBOSITY_VERBOSE

-- Name shown in error messages and chunk names when no name is given.
Constants.INTERPRETER_NAME = "AegisVM"

-- Default chunk name used by loadstring / load when none is supplied.
Constants.DEFAULT_CHUNK_NAME = "loadstring"

-- Base URL for the rbxm conversion service used by WebRbxmParser.
-- Source for this service is available at https://github.com/AegisLua/API
Constants.CONVERT_BASE_URL = "https://api.aegislua.xyz/rbxm?url="

return Constants
