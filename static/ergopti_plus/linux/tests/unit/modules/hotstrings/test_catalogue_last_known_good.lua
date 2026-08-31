--- tests/unit/modules/hotstrings/test_catalogue_last_known_good.lua

--- ==============================================================================
--- MODULE: Catalogue Last-Known-Good Transactions
--- DESCRIPTION:
--- Proves that uncommitted TOML reads retain their source snapshot and that an
--- aggregate with an unrecoverable source never replaces the active engine.
--- ==============================================================================

local helpers = require("tests.helpers")

local function parsed(trigger, replacement)
	return {
		meta = {},
		sections_order = { "probe" },
		sections = {
			probe = {
				entries = { {
					trigger = trigger,
					output = replacement,
					auto_expand = true,
				} },
			},
		},
	}
end

local function mapping_by_trigger(mappings, trigger)
	for _, mapping in ipairs(mappings or {}) do
		if mapping.trigger == trigger then return mapping end
	end
	return nil
end

helpers.describe("hotstring catalogue: last-known-good sources", function()

	helpers.it("retains each failed source and reports every uncommitted parse", function()
		local previous_reader = package.loaded["toml_codec.reader"]
		local previous_loader = package.loaded["modules.hotstrings.loader"]
		local states = {}
		package.loaded["toml_codec.reader"] = {
			parse = function(path)
				local state = states[path]
				if state.raise then error(state.raise) end
				return state.data, state.committed
			end,
		}
		package.loaded["modules.hotstrings.loader"] = nil

		local ok, err = pcall(function()
			local Loader = require("modules.hotstrings.loader")
			states["one.toml"] = { data = parsed("one", "one-old"), committed = true }
			states["two.toml"] = { data = parsed("two", "two-old"), committed = true }
			local catalogue = Loader.load_catalogue({ "one.toml", "two.toml" })
			helpers.assert_true(catalogue.committed)
			helpers.assert_eq(catalogue.errors, 0)

			for _, failure in ipairs({ "read", "semantic", "close" }) do
				states["one.toml"] = { data = parsed("partial", failure), committed = false }
				states["two.toml"] = { data = parsed("two", "two-" .. failure), committed = true }
				catalogue = Loader.load_catalogue({ "one.toml", "two.toml" })
				helpers.assert_true(catalogue.committed,
					failure .. " failure must be recoverable from the healthy snapshot")
				helpers.assert_eq(catalogue.errors, 1, failure .. " failure must be counted exactly")
				helpers.assert_eq(mapping_by_trigger(catalogue.mappings, "one").replacement, "one-old",
					failure .. " failure must retain the source's last committed mapping")
				helpers.assert_eq(mapping_by_trigger(catalogue.mappings, "two").replacement,
					"two-" .. failure, "a healthy sibling source must still advance")
			end

			states["one.toml"] = { data = {}, committed = false }
			states["two.toml"] = { data = {}, committed = false }
			catalogue = Loader.load_catalogue({ "one.toml", "two.toml" })
			helpers.assert_true(catalogue.committed, "both sources have healthy snapshots")
			helpers.assert_eq(catalogue.errors, 2, "two failed sources must report two errors")

			states["new.toml"] = { data = {}, committed = false }
			catalogue = Loader.load_catalogue({ "one.toml", "new.toml" })
			helpers.assert_eq(catalogue.committed, false,
				"a never-committed source must make the aggregate non-committable")
			helpers.assert_eq(catalogue.errors, 2)
		end)

		package.loaded["modules.hotstrings.loader"] = previous_loader
		package.loaded["toml_codec.reader"] = previous_reader
		if not ok then error(err, 0) end
	end)

	helpers.it("keeps the active engine untouched when no complete aggregate exists", function()
		local previous_loader = package.loaded["modules.hotstrings.loader"]
		local current = nil
		package.loaded["modules.hotstrings.loader"] = {
			find_toml_files = function() return {} end,
			list_subdirs = function() return {} end,
			read_file = function() return nil end,
			load_catalogue = function() return current end,
		}
		package.loaded["modules.hotstrings.hotstrings_config"] = nil

		local ok, err = pcall(function()
			local loaded = nil
			local loads = 0
			local Config = require("modules.hotstrings.hotstrings_config")
			Config.init({
				load_mappings = function(_, mappings)
					loads = loads + 1
					loaded = mappings
				end,
			}, "virtual.toml", nil)

			current = {
				mappings = { { trigger = "healthy", replacement = "kept", group = "probe" } },
				categories = { probe = { id = "probe", sections = {}, sections_order = {} } },
				errors = 0,
				committed = true,
			}
			Config.load_all()
			helpers.assert_eq(loads, 1)
			helpers.assert_eq(loaded[1].trigger, "healthy")

			current = {
				mappings = { { trigger = "partial", replacement = "must-not-publish" } },
				categories = {},
				errors = 1,
				committed = false,
			}
			helpers.assert_eq(Config.reload(), 1, "reload must report the retained mapping count")
			helpers.assert_eq(loads, 1, "the engine must not receive an uncommitted aggregate")
			helpers.assert_eq(loaded[1].trigger, "healthy")
			helpers.assert_eq(Config.mapping_count(), 1)
			helpers.assert_eq(Config.parse_error_count(), 1)
		end)

		package.loaded["modules.hotstrings.hotstrings_config"] = nil
		package.loaded["modules.hotstrings.loader"] = previous_loader
		if not ok then error(err, 0) end
	end)

end)
