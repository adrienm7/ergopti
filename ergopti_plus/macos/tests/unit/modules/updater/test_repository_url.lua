--- tests/unit/modules/updater/test_repository_url.lua

--- ==============================================================================
--- MODULE: Repository URL Policy (macOS)
--- DESCRIPTION:
--- Replays the shared contract: the update-check window's release-note links
--- open only on this repository's github.com surface.
--- ==============================================================================

local helpers = require("tests.helpers")

require("test.repository_url_contract")(helpers)
