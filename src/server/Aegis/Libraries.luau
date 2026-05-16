-- Libraries.luau - Optional library modules bundled with AegisVM
--
-- Each entry is a fully-initialised module ready to use.
-- Accessible from outside via Aegis.Libraries.<Name>.

local Libraries = {}

Libraries.NewScript      = require(script.NewScript)
Libraries.WebRbxmParser = require(script.WebRbxmParser)

return Libraries
