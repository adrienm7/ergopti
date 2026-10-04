--- tests/unit/modules/hotstrings/test_catalogue_last_known_good.lua

--- ==============================================================================
--- MODULE: Catalogue Last-Known-Good Transactions
--- DESCRIPTION:
--- Proves that uncommitted TOML reads retain their source snapshot and that an
--- aggregate with an unrecoverable source never replaces the active engine.
--- ==============================================================================

local helpers = require("tests.helpers")
local Reader = require("toml_codec.reader")

local function parsed(trigger, replacement)
	return {
		meta = {},
		sections_order = { "probe" },
		source_entries = { { section = "probe", index = 1 } },
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
			registration_order = Reader.registration_order,
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
			require("tests.support.hotstring_choices").with_file(Config, { probe = true }, function()
				Config.init({
					load_mappings = function(_, mappings)
						loads = loads + 1
						loaded = mappings
						return true
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
		end)

		package.loaded["modules.hotstrings.hotstrings_config"] = nil
		package.loaded["modules.hotstrings.loader"] = previous_loader
		if not ok then error(err, 0) end
	end)

end)

helpers.describe("hotstring catalogue: runtime publication acknowledgement", function()
	local function with_catalogue(body)
		local saved = {}
		for name, module in pairs(package.loaded) do saved[name] = module end
		local stage, refusal, calls = "old", nil, 0
		package.loaded["modules.hotstrings.loader"] = {
			find_toml_files = function() return {} end,
			list_subdirs = function() return {} end,
			read_file = function() return nil end,
			load_catalogue = function()
				return { committed = true, errors = 0,
					mappings = { { trigger = stage, replacement = stage .. "-result", group = stage,
						auto_expand = true, is_case_sensitive_strict = true } },
					categories = { [stage] = { id = stage, sections = {}, sections_order = {} } } }
			end,
		}
		package.loaded["modules.hotstrings.hotstrings_config"] = nil
		local ok, err = pcall(function()
			local engine = require("hotstring_engine").new()
			local publish = engine.load_mappings
			engine.load_mappings = function(self, mappings)
				calls = calls + 1
				if refusal == "raise" then error("runtime-catalogue-refused") end
				if refusal == "false" then return false end
				return publish(self, mappings)
			end
			local Config = require("modules.hotstrings.hotstrings_config")
			Config._set_override_config_dir_for_test(os.tmpname() .. "-absent")
			require("tests.support.hotstring_choices").with_file(Config, { old = true, new = true }, function()
				Config.init(engine, "virtual-catalogue", nil)
				Config.load_all()
				local controls = {
					stage = function(value) stage = value end,
					refuse = function(value) refusal = value end,
					calls = function() return calls end,
				}
				body(Config, engine, controls)
			end)
		end)
		for name in pairs(package.loaded) do if saved[name] == nil then package.loaded[name] = nil end end
		for name, module in pairs(saved) do package.loaded[name] = module end
		if not ok then error(err, 0) end
	end

	local function match(engine, text)
		engine:reset()
		local result
		for ch in text:gmatch(".") do result = engine:on_char(ch) end
		return result and result.replacement
	end

	for _, refusal in ipairs({ "false", "raise" }) do
		helpers.it("preserves engine and menu metadata after runtime " .. refusal, function()
			with_catalogue(function(Config, engine, controls)
				controls.stage("new")
				controls.refuse(refusal)
				local count, committed, reason = Config.reload()
				helpers.assert_eq(committed, false, "caller receives refusal")
				helpers.assert_true(type(reason) == "string" and reason:find("refused", 1, true) ~= nil,
					"refusal reason is retained")
				helpers.assert_eq(count, 1, "retained count")
				helpers.assert_not_nil(Config.get_category("old"), "old menu metadata retained")
				helpers.assert_nil(Config.get_category("new"), "new menu metadata not published")
				helpers.assert_eq(match(engine, "old"), "old-result", "old engine remains effective")
				helpers.assert_nil(match(engine, "new"), "candidate does not execute")
				controls.refuse(nil)
				local _, retried = Config.reload()
				helpers.assert_eq(retried, true, "explicit retry can commit")
				helpers.assert_nil(Config.get_category("old"), "old metadata replaced after retry")
				helpers.assert_not_nil(Config.get_category("new"), "new metadata accepted after retry")
				helpers.assert_eq(match(engine, "new"), "new-result", "retry engine executes")
			end)
		end)
	end

	for _, invalid in ipairs({ "raise", "non-table" }) do
		helpers.it("refuses an incomplete catalogue when the personal provider returns " .. invalid, function()
			with_catalogue(function(Config, engine, controls)
				controls.stage("new")
				Config.set_extra_mappings_provider(function()
					if invalid == "raise" then error("personal-source-unreadable") end
					return false
				end)
				local before = controls.calls()
				local _, committed, reason = Config.reload()
				helpers.assert_eq(committed, false, "provider failure refuses whole candidate")
				helpers.assert_true(type(reason) == "string" and #reason > 0, "explicit provider failure")
				helpers.assert_eq(controls.calls(), before, "incomplete candidate never reaches engine")
				helpers.assert_eq(match(engine, "old"), "old-result", "healthy prior catalogue kept")
				helpers.assert_not_nil(Config.get_category("old"), "prior metadata kept")
			end)
		end)
	end

	helpers.it("publishes a complete retry with the personal provider and exact engine receipt", function()
		with_catalogue(function(Config, engine, controls)
			controls.stage("new")
			Config.set_extra_mappings_provider(function()
				return { { trigger = "extra", replacement = "personal", group = "new",
					auto_expand = true, is_case_sensitive_strict = true } }
			end)
			local count, committed = Config.reload()
			helpers.assert_eq(committed, true, "complete candidate acknowledged")
			helpers.assert_eq(count, 2, "both sources accepted")
			helpers.assert_eq(Config.mapping_count(), 2, "owner agrees with engine")
			helpers.assert_eq(engine:mapping_state().mappings, 2, "real engine readback agrees")
			helpers.assert_eq(match(engine, "extra"), "personal", "provider mapping executes")
			helpers.assert_eq(match(engine, "new"), "new-result", "file mapping executes")
			helpers.assert_nil(match(engine, "old"), "old mapping removed only on success")
		end)
	end)
end)
