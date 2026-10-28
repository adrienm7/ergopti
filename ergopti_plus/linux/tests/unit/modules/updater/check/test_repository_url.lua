--- tests/unit/modules/updater/check/test_repository_url.lua

--- ==============================================================================
--- MODULE: Repository URL Policy (Linux)
--- DESCRIPTION:
--- Replays the shared contract: the Versions and update-check windows open
--- release-note links only on this repository's github.com surface.
--- ==============================================================================

local helpers = require("tests.helpers")

require("test.repository_url_contract")(helpers)
