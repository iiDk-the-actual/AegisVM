-- Constants.luau - Static compile-time values for AegisVM
--
-- All hard-coded strings and version identifiers live here so they
-- have a single source of truth and are easy to audit or update.

local Constants = {}

-- Interpreter version string exposed to guest code as _AEGIS_VERSION.
Constants.VERSION = "2"

-- Name shown in error messages and chunk names when no name is given.
Constants.INTERPRETER_NAME = "AegisVM"

-- Default chunk name used by loadstring / load when none is supplied.
Constants.DEFAULT_CHUNK_NAME = "loadstring"

return Constants
