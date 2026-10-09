--- tests/unit/infra/test_extension_binding_vectors.lua

--- ==============================================================================
--- MODULE: Extension Historical Binding Vectors (shared, replayed on macOS)
--- DESCRIPTION:
--- A layout extension may attach its geometry files to the runtime category,
--- feature section and source tier those rules had before they moved into it.
--- The macOS driver reads bindings through the shared scanner, so it replays the
--- vectors the Linux suite and the Windows scanner replay
--- (_shared/tests/corpus/layouts/extension_binding_vectors.json), and the
--- physical magic key a layout extension declares
--- (_shared/tests/corpus/layouts/extension_magic_key_vectors.json).
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")
local Extensions = require("hotstrings.extensions")

local handle = assert(io.open(helpers.shared("tests/corpus/layouts/extension_binding_vectors.json"), "rb"))
local vectors = Json.decode(handle:read("*a"))
handle:close()

require("test.extension_binding_contract")(helpers, Extensions, vectors)

local magic_handle = assert(io.open(helpers.shared("tests/corpus/layouts/extension_magic_key_vectors.json"), "rb"))
local magic_vectors = Json.decode(magic_handle:read("*a"))
magic_handle:close()

require("test.extension_magic_key_contract")(helpers, Extensions, magic_vectors)
