--- tests/unit/infra/manifest/test_features_manifest_projection.lua

--- ==============================================================================
--- MODULE: Features Manifest Projection (macOS)
--- DESCRIPTION:
--- The shared manifest both Lua drivers load, projected for this driver.
--- ==============================================================================

local helpers = require("tests.helpers")

-- manifest_reader logs through infra.logger; load the stub first.
package.loaded["infra.logger"] = nil
local _ = helpers.load_with_stubs("infra.logger")

require("test.features_manifest_contract").run(helpers, "hs", require("infra.manifest_reader"))
