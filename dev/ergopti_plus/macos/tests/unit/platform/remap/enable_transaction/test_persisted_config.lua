--- tests/unit/platform/remap/enable_transaction/test_persisted_config.lua

--- ==============================================================================
--- MODULE: Remap Transaction Regression
--- DESCRIPTION:
--- Preserves exact lifecycle and persistence guarantees inside one fixture scope.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_fixture = require("tests.support.remap_transaction_fixture")

helpers.describe("HS-019 malformed TOML keeps the real Clear All command inert", function()
	helpers.it("joins the real parser, remap owner, manifest route, and menu terminal", function()
		with_fixture(function(fixture)
			local corrupt_path = os.tmpname()
			local corrupt_toml = "[karabiner\nenabled = true\n[tap_holds\nconfig = broken ]]\n"
			local file = assert(io.open(corrupt_path, "w"), "cannot create malformed TOML fixture")
			assert(file:write(corrupt_toml))
			assert(file:close())

			local remap, calls = fixture.load_enabled_remap({ real_user_config_path = corrupt_path })
			helpers.assert_eq(calls.init_result, false,
				"the genuine TOML decoder must refuse the malformed file")
			helpers.assert_eq(remap.get_enabled(), false,
				"failed initialization must expose only the fail-closed facade state")

			local observations = { errors = 0, successes = 0, refreshes = 0 }
			local logger = {}
			for _, level in ipairs({ "debug", "done", "info", "start", "trace", "warn" }) do
				logger[level] = function() end
			end
			logger.error = function() observations.errors = observations.errors + 1 end
			logger.success = function() observations.successes = observations.successes + 1 end
			local saved_logger = package.loaded["infra.logger"]
			package.loaded["infra.logger"] = logger
			local MenuRemap = helpers.load_with_stubs("ui.menu.menu_remap", {})
			package.loaded["infra.logger"] = saved_logger

			local built = MenuRemap.build({
				karabiner = remap,
				updateMenu = function()
					observations.refreshes = observations.refreshes + 1
				end,
			})
			local function children(row)
				if type(row) ~= "table" then return {} end
				return row.items or row.menu or {}
			end
			local function find_row(row, label)
				if type(row) ~= "table" then return nil end
				if row.label == label or row.title == label then return row end
				for _, child in ipairs(children(row)) do
					local found = find_row(child, label)
					if found then return found end
				end
				return nil
			end
			local row = find_row(built, "menu.karabiner.clear_all")
			helpers.assert_not_nil(row,
				"the real manifest must expose the Clear All command")
			local action = row and (row.action or row.fn)
			helpers.assert_type(action, "function")
			helpers.assert_eq(action(), false,
				"the real command must propagate the uninitialized owner refusal")

			local after = assert(io.open(corrupt_path, "r"))
			local after_bytes = after:read("*a")
			after:close()
			os.remove(corrupt_path .. ".tmp")
			os.remove(corrupt_path)

			helpers.assert_eq(after_bytes, corrupt_toml,
				"Clear All must leave the rejected TOML byte-identical")
			helpers.assert_eq(remap.get_enabled(), false,
				"Clear All must not synthesize enabled state after failed initialization")
			helpers.assert_eq(observations.successes, 0,
				"the menu must publish no false success")
			helpers.assert_true(observations.errors >= 1,
				"the composed refusal must remain visible")
		end)
	end)
end)

helpers.describe("karabiner init fails closed on unsafe persisted config", function()
	helpers.it("HS-019 returns literal booleans for every early refusal class", function()
		with_fixture(function(fixture)
			local uninitialized = fixture.load_enabled_remap({ skip_init = true })
			helpers.assert_eq(uninitialized.init(nil), false,
				"an invalid adapter must return literal false, never nil")

			local missing_data, missing_calls = fixture.load_enabled_remap({ empty_data = true })
			helpers.assert_type(missing_data.init, "function")
			helpers.assert_eq(missing_calls.init_result, false,
				"required-data refusal must return literal false, never nil")

			local initialized = fixture.load_enabled_remap()
			helpers.assert_eq(initialized.init({ expand_path = function(path) return path end }), false,
				"duplicate initialization is a refusal and must return literal false")
		end)
	end)

	helpers.it("arms no state, lease, watcher, or regeneration surface", function()
		with_fixture(function(fixture)
			local remap, calls = fixture.load_enabled_remap({ config_error = true })
			helpers.assert_eq(calls.init_result, false)
			helpers.assert_eq(calls.lease_init, 0,
				"an unreadable config may contain enabled=false, so no lease generation may be prepared")
			helpers.assert_eq(calls.input_source_watchers, 0)
			helpers.assert_eq(calls.build, 0)
			helpers.assert_eq(calls.deploy, 0)
			helpers.assert_eq(remap.get_enabled(), false,
				"require_state must prove that no default state was published")
		end)
	end)
end)
