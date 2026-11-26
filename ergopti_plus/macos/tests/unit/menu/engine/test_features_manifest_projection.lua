--- tests/unit/menu/engine/test_features_manifest_projection.lua

--- ==============================================================================
--- MODULE: Features Manifest Projection (macOS)
--- DESCRIPTION:
--- The shared manifest both Lua drivers load, projected for this driver.
--- ==============================================================================

local helpers = require("tests.helpers")

-- manifest_reader logs through infra.logger; load the stub first.
package.loaded["core.logger.engine.logger"] = nil
local _ = helpers.load_with_stubs("core.logger.engine.logger")

require("tests.lua.features_manifest_contract").run(helpers, "hs", require("menu.engine.manifest_reader"))
