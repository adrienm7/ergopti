--- tests/unit/infra/test_features_manifest_projection.lua

--- ==============================================================================
--- MODULE: Features Manifest Projection (Linux)
--- DESCRIPTION:
--- The shared manifest both Lua drivers load, projected for this driver.
--- ==============================================================================

local helpers = require("tests.helpers")
require("test.features_manifest_contract").run(helpers, "linux", require("infra.manifest_reader"))
