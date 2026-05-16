-- Constants.luau - Static compile-time values for AegisVM
--
-- All hard-coded strings and version identifiers live here so they
-- have a single source of truth and are easy to audit or update.

local Constants = {}

-- Interpreter version string exposed to guest code as _AEGIS_VERSION.
Constants.VERSION = "4"

-- Name shown in error messages and chunk names when no name is given.
Constants.INTERPRETER_NAME = "AegisVM"

-- Default chunk name used by loadstring / load when none is supplied.
Constants.DEFAULT_CHUNK_NAME = "loadstring"

-- Base URL for the rbxm conversion service used by WebRbxmParser.
-- Source for this service is available at https://github.com/iiDk-the-actual/convert.iidk.online
Constants.CONVERT_BASE_URL = "https://convert.iidk.online/rbxm?url="

return Constants
