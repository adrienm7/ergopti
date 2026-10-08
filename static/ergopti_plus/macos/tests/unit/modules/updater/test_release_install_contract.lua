--- macos/tests/unit/modules/updater/test_release_install_contract.lua

--- ==============================================================================
--- MODULE: Release Install and Configuration Backup Contracts (macOS)
--- DESCRIPTION:
--- Runs the shared one-click release install and configuration backup
--- contracts with the real shared updater defaults, decoded by the shared
--- decoder. The Linux suite runs the same contracts.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")

local handle = assert(io.open(helpers.shared("modules/updater/defaults.json"), "rb"))
local defaults = assert(Json.decode(handle:read("*a")), "defaults.json must decode")
handle:close()

require("test.config_backup_contract").register(helpers, { defaults = defaults })
require("test.release_install_contract").register(helpers)

local policy_handle = assert(io.open(helpers.shared("modules/network/managed_network.json"), "rb"))
local policy = assert(Json.decode(policy_handle:read("*a")), "managed network policy must decode")
policy_handle:close()
require("test.release_install_network_contract").register(helpers, policy)
