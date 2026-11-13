--- tests/unit/modules/hotstrings/catalogue/test_catalogue_last_known_good.lua

--- ==============================================================================
--- MODULE: Catalogue Last-Known-Good Transactions
--- DESCRIPTION:
--- Proves that uncommitted TOML reads retain their source snapshot and that an
--- aggregate with an unrecoverable source never replaces the active engine.
--- ==============================================================================

local helpers = require("tests.helpers")
local Reader = require("core.text.engine.toml_codec.reader")

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
		local previous_reader = package.loaded["core.text.engine.toml_codec.reader"]
		local previous_loader = package.loaded["modules.hotstrings.loader"]
		local states = {}
		package.loaded["core.text.engine.toml_codec.reader"] = {
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
		package.loaded["core.text.engine.toml_codec.reader"] = previous_reader
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
			local engine = require("hotstrings.engine.matcher").new()
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


helpers.describe("hotstring choice rollback keeps the published catalogue", function()
	local function with_choice_runtime(callback, choices)
		local previous_loader = package.loaded["modules.hotstrings.loader"]
		local previous_config = package.loaded["modules.hotstrings.hotstrings_config"]
		local Writer = require("core.text.engine.toml_codec.writer")
		local previous_writer = Writer.batch_write
		local state = { reads = 0, writes = 0, unavailable = false }
		package.loaded["modules.hotstrings.loader"] = {
			find_toml_files = function() return {} end,
			list_subdirs = function() return {} end,
			read_file = function() return nil end,
			load_catalogue = function()
				state.reads = state.reads + 1
				if state.unavailable then return { committed = false, errors = 1, mappings = {}, categories = {} } end
				return { committed = true, errors = 0,
					categories = { probe = { id = "probe", sections = { main = {} }, sections_order = { "main" } } },
					mappings = { { trigger = "xyz", replacement = "candidate", group = "probe", section = "main", auto_expand = true } } }
			end,
		}
		package.loaded["modules.hotstrings.hotstrings_config"] = nil
		local ok, err = pcall(function()
			local Config = require("modules.hotstrings.hotstrings_config")
			local Engine = require("hotstrings.engine.matcher").new()
			require("tests.support.hotstring_choices").with_file(Config, choices, function(path)
				helpers.assert_true(Config.init(Engine, "virtual.toml"))
				local _, committed = Config.load_all()
				helpers.assert_eq(committed, true)
				local source = require("tests.support.hotstring_choices").read(path)
				Writer.batch_write = function(...)
					if state.allow_writes then
						state.writes = state.writes + 1
						return previous_writer(...)
					end
					state.writes, state.unavailable = state.writes + 1, true
					return false, "injected concurrent configuration refusal"
				end
				callback(Config, Engine, state, path, source)
			end)
		end)
		Writer.batch_write = previous_writer
		package.loaded["modules.hotstrings.loader"] = previous_loader
		package.loaded["modules.hotstrings.hotstrings_config"] = previous_config
		if not ok then error(err, 0) end
	end

	for _, selection in ipairs({ "group", "section", "bulk", "category" }) do
		helpers.it("restores exact " .. selection .. " mappings without rescanning refused sources (choice-rollback-image)", function()
			local choices = "[hotstrings]\ngroups = { probe = " .. tostring(selection == "section")
				.. " }\n[hotstrings.modules.probe]\nmain = " .. tostring(selection == "group") .. "\n"
			with_choice_runtime(function(Config, Engine, state, path, source)
				local previous = Engine:mapping_state()
				local select = selection == "group" and function() return Config.enable_group("probe") end
					or selection == "section" and function() return Config.toggle_section("probe", "main") end
					or selection == "bulk" and function() return Config.enable_all() end
					or function() return Config.set_category_scope_enabled({ "probe" }, true) end
				helpers.assert_eq(select(), false, "the candidate file was refused")
				Engine:reset(); Engine:on_char("x"); Engine:on_char("y")
				helpers.assert_nil(Engine:on_char("z"), "a refused selection must never leave its candidate expanding")
				helpers.assert_eq(Config.is_group_enabled("probe"), selection == "section")
				helpers.assert_eq(Config.is_section_checked("probe", "main"), selection == "group")
				helpers.assert_eq(state.reads, 2, "inverse publication must use retained RAM, without another source scan")
				helpers.assert_eq(state.writes, 1, "rollback must not rewrite the refused choice")
				helpers.assert_eq(require("tests.support.hotstring_choices").read(path), source)
				helpers.assert_eq(Engine:mapping_state().generation, previous.generation + 2,
					"candidate and exact inverse both have acknowledged generations")
			end, choices)
		end)
	end

	helpers.it("retains the lease until the exact inverse acknowledges publication (choice-rollback-image)", function()
		with_choice_runtime(function(Config, Engine, state, path, source)
			local original = Engine.load_mappings
			local inverse_allowed, calls = false, 0
			Engine.load_mappings = function(self, mappings)
				calls = calls + 1
				if calls > 1 and not inverse_allowed then return false end
				return original(self, mappings)
			end
			helpers.assert_eq(Config.enable_group("probe"), false)
			helpers.assert_eq(Config.acquire({}), false, "an unacknowledged inverse retains exclusive ownership")
			helpers.assert_eq(Config.retry_personal_gate_cleanup(), false)
			helpers.assert_eq(Config.disable_all(), false, "another selection cannot interleave the inverse")
			helpers.assert_eq(state.writes, 1)
			inverse_allowed = true
			helpers.assert_eq(Config.retry_personal_gate_cleanup(), true)
			helpers.assert_eq(Config.is_group_enabled("probe"), false)
			Engine:reset(); Engine:on_char("x"); Engine:on_char("y")
			helpers.assert_nil(Engine:on_char("z"))
			helpers.assert_eq(state.reads, 2, "native retry still uses the original immutable image")
			helpers.assert_eq(require("tests.support.hotstring_choices").read(path), source)
			local next_owner = {}
			helpers.assert_eq(Config.acquire(next_owner), true)
			helpers.assert_eq(Config.release(next_owner), true)
		end, "[hotstrings]\ngroups = { probe = false }\n[hotstrings.modules.probe]\nmain = true\n")
	end)

	helpers.it("never replaces a foreign generation while its inverse is pending (choice-rollback-image)", function()
		with_choice_runtime(function(Config, Engine, state)
			local original = Engine.load_mappings
			local calls = 0
			Engine.load_mappings = function(self, mappings)
				calls = calls + 1
				if calls > 1 then return false end
				return original(self, mappings)
			end
			helpers.assert_eq(Config.enable_group("probe"), false)
			helpers.assert_eq(original(Engine, { { trigger = "xyz", replacement = "foreign", auto_expand = true } }), true)
			local foreign = Engine:mapping_state()
			helpers.assert_eq(Config.retry_personal_gate_cleanup(), false)
			helpers.assert_eq(Engine:mapping_state(), foreign, "the original candidate no longer owns this generation")
			Engine:reset(); Engine:on_char("x"); Engine:on_char("y")
			helpers.assert_eq(Engine:on_char("z").replacement, "foreign")
			helpers.assert_eq(state.reads, 2)
			helpers.assert_eq(state.writes, 1)
			helpers.assert_eq(Config.acquire({}), false, "foreign state cannot acknowledge the old inverse")
		end, "[hotstrings]\ngroups = { probe = false }\n[hotstrings.modules.probe]\nmain = true\n")
	end)

	helpers.it("restores publication completed before a reporting exception (choice-rollback-image)", function()
		with_choice_runtime(function(Config, Engine, state)
			local Logger = require("core.logger.engine.shim")
			local previous, raised = Logger.success, false
			Logger.success = function(module, message, ...)
				if module == "modules.hotstrings.hotstrings_config" and message:sub(1, 7) == "Loaded " then
					raised = true
					error("injected post-publication reporting failure")
				end
				return previous(module, message, ...)
			end
			local ok, committed = pcall(Config.enable_group, "probe")
			Logger.success = previous
			helpers.assert_eq(ok, true)
			helpers.assert_eq(raised, true, "the failure follows acknowledged engine publication")
			helpers.assert_eq(committed, false)
			Engine:reset(); Engine:on_char("x"); Engine:on_char("y")
			helpers.assert_nil(Engine:on_char("z"), "the exact inverse also owns exceptional completion")
			helpers.assert_eq(Config.is_group_enabled("probe"), false)
			helpers.assert_eq(state.reads, 2)
			helpers.assert_eq(state.writes, 0)
		end, "[hotstrings]\ngroups = { probe = false }\n[hotstrings.modules.probe]\nmain = true\n")
	end)

	for _, mode in ipairs({ "enable", "disable" }) do
		for _, selection in ipairs({ "group", "all" }) do
			helpers.it("refuses pending " .. mode .. " " .. selection .. " no-ops (choice-owner-preadmission)", function()
				local before = mode == "disable"
				with_choice_runtime(function(Config, Engine, state, path, source)
					local original, calls = Engine.load_mappings, 0
					Engine.load_mappings = function(self, mappings)
						calls = calls + 1
						if calls > 1 then return false end
						return original(self, mappings)
					end
					local request = selection == "group" and function() return Config[mode .. "_group"]("probe") end
						or Config[mode .. "_all"]
					helpers.assert_eq(request(), false, "the initial file publication refuses")
					helpers.assert_eq(request(), false, "a retained candidate is never an acknowledged no-op")
					helpers.assert_eq(state.writes, 1)
					helpers.assert_eq(Config.acquire({}), false)
					helpers.assert_eq(require("tests.support.hotstring_choices").read(path), source)
				end, "[hotstrings]\ngroups = { probe = " .. tostring(before)
					.. " }\n[hotstrings.modules.probe]\nmain = true\n")
			end)
		end
	end

	for _, selection in ipairs({ "section", "all" }) do
		helpers.it("plans " .. selection .. " intent after settling the inverse (choice-owner-preadmission)", function()
			with_choice_runtime(function(Config, Engine, state, path)
				local original, calls = Engine.load_mappings, 0
				local inverse_allowed = false
				Engine.load_mappings = function(self, mappings)
					calls = calls + 1
					if calls > 1 and not inverse_allowed then return false end
					return original(self, mappings)
				end
				local request = selection == "section" and function() return Config.toggle_section("probe", "main") end
					or Config.enable_all
				helpers.assert_eq(request(), false)
				inverse_allowed, state.unavailable, state.allow_writes = true, false, true
				helpers.assert_true(request(), "the fresh intent must use the restored committed choices")
				helpers.assert_eq(state.writes, 2, "an acknowledged intent is persisted after inverse retirement")
				helpers.assert_eq(Config.is_group_enabled("probe"), true)
				helpers.assert_eq(Config.is_section_checked("probe", "main"), true)
				Engine:reset(); Engine:on_char("x"); Engine:on_char("y")
				helpers.assert_eq(Engine:on_char("z").replacement, "candidate")
				local document = require("core.text.engine.toml_codec").decode(require("tests.support.hotstring_choices").read(path))
				helpers.assert_eq(document.hotstrings.modules.probe.main, true)
			end, "[hotstrings]\ngroups = { probe = " .. tostring(selection == "section")
				.. " }\n[hotstrings.modules.probe]\nmain = false\n")
		end)
	end
end)

helpers.describe("hotstring catalogue: removed source lifetime", function()
	helpers.it("does not revive a removed override when its path returns malformed", function()
		local uv = require("luv")
		local root = assert(uv.fs_mkdtemp(uv.os_tmpdir() .. "/ergopti-source-life-XXXXXX"))
		local path = root .. "/autocorrection.toml"
		local function write(bytes)
			local f = assert(io.open(path, "wb")); assert(f:write(bytes)); assert(f:close())
		end
		local function match(engine)
			engine:reset(false)
			local result
			for c in ("owned"):gmatch(".") do result = engine:on_char(c) end
			return result
		end
		local ok, err = pcall(function()
			write('[probe]\n"owned" = { output = "OLD", auto_expand = true }\n')
			local Config = helpers.load_module("modules.hotstrings.hotstrings_config")
			local engine = require("hotstrings.engine.matcher").new()
			Config._set_override_config_dir_for_test(root)
			local id = "autocorrection"
			require("tests.support.hotstring_choices").with_file(Config,
				'[hotstrings]\ngroups = { autocorrection = true }\n[hotstrings.modules]\nautocorrection = { probe = true }\n', function()
				assert(Config.init(engine, root))
				local _, published = Config.load_all(); helpers.assert_true(published)
				local first = match(engine); helpers.assert_not_nil(first, "the override source is live")
				helpers.assert_eq(first.replacement, "OLD")
				-- A healthy sibling read in a refused aggregate is not the live source.
				write('[probe]\n"owned" = { output = "UNPUBLISHED", auto_expand = true }\n')
				local sibling = root .. "/incomplete.toml"
				local f = assert(io.open(sibling, "wb")); assert(f:write('[probe]\n"broken" = { output = ')); assert(f:close())
				_, published = Config.reload(); helpers.assert_eq(published, false)
				helpers.assert_eq(match(engine).replacement, "OLD")
				write('[probe]\n"owned" = { output = '); assert(os.remove(sibling))
				_, published = Config.reload(); helpers.assert_true(published)
				helpers.assert_eq(match(engine).replacement, "OLD", "unpublished source cannot replace the active fallback")
				assert(os.remove(path))
				local original_load = engine.load_mappings
				engine.load_mappings = function() return false end
				_, published = Config.reload(); helpers.assert_eq(published, false)
				engine.load_mappings = original_load
				helpers.assert_eq(match(engine).replacement, "OLD", "a refused removal leaves the live engine intact")
				local owner = {}; helpers.assert_true(Config.acquire(owner))
				local inverse = assert(Config.configuration_snapshot())
				local borrowed = require("modules.hotstrings.loader").capture_source_snapshots()
				_, published = Config.load_all(); helpers.assert_true(published)
				write('[probe]\n"owned" = { output = ')
				_, published = Config.load_all()
				helpers.assert_eq(published, false, "an ordinary candidate cannot borrow an inverse-only snapshot")
				_, published = Config.load_all(nil, nil, borrowed)
				helpers.assert_eq(published, false, "a public load cannot supply its own inverse receipt")
				helpers.assert_nil(match(engine), "the removed mapping stays inactive during the transaction")
				helpers.assert_true(Config.restore_configuration(owner, inverse), "the explicit inverse may restore its retained source")
				helpers.assert_eq(match(engine).replacement, "OLD")
				helpers.assert_true(Config.release(owner))
				assert(os.remove(path))
				_, published = Config.reload(); helpers.assert_true(published)
				helpers.assert_nil(match(engine), "a removed source is no longer live")
				write('[probe]\n"owned" = { output = ')
				_, published = Config.reload()
				helpers.assert_eq(published, false, "a newly reappearing malformed source has no current snapshot")
				helpers.assert_nil(match(engine), "the old removed mapping must not be revived")
			end)
		end)
		os.remove(path); uv.fs_rmdir(root)
		if not ok then error(err, 0) end
	end)
end)

helpers.describe("hotstring catalogue: unreadable discovery", function()
	helpers.it("continues to load an explicitly selected TOML file", function()
		local uv = require("luv")
		local root = assert(uv.fs_mkdtemp(uv.os_tmpdir() .. "/ergopti-explicit-file-XXXXXX"))
		local path = root .. "/custom.toml"
		local file = assert(io.open(path, "wb"))
		assert(file:write('[probe]\n"exactfile" = { output = "FOUND", auto_expand = true }\n')); assert(file:close())
		local ok, err = pcall(function()
			local Config = helpers.load_module("modules.hotstrings.hotstrings_config")
			local engine = require("hotstrings.engine.matcher").new()
			Config._set_override_config_dir_for_test(root)
			require("tests.support.hotstring_choices").with_file(Config, { custom = true }, function()
				assert(Config.init(engine, path))
				local _, published = Config.load_all(nil, true)
				helpers.assert_true(published)
				helpers.assert_eq(Config.mapping_count(), 1)
			end)
		end)
		os.remove(path); uv.fs_rmdir(root)
		if not ok then error(err, 0) end
	end)

	helpers.it("discovers a personal folder created after daemon startup", function()
		local uv = require("luv")
		local root = assert(uv.fs_mkdtemp(uv.os_tmpdir() .. "/ergopti-late-personal-XXXXXX"))
		local personal = root .. "/hotstrings"
		local file = assert(io.open("ergopti_hotstrings.lua", "rb"))
		local source = assert(file:read("*a")); assert(file:close())
		local first = assert(source:find("local function resolve_config_path(", 1, true))
		local last = assert(source:find("local function reload_hotstrings(", first, true))
		local chunk = assert(loadstring(source:sub(first, last - 1) .. "\nreturn resolve_config_path"))
		setfenv(chunk, setmetatable({ DEFAULT_CONFIG_DIR = personal }, { __index = _G }))
		local resolve = chunk()
		local ok, err = pcall(function()
			local Config = helpers.load_module("modules.hotstrings.hotstrings_config")
			local engine = require("hotstrings.engine.matcher").new()
			Config._set_override_config_dir_for_test(root)
			local id = require("hotstrings.engine.catalogue.personal_files").describe({ "custom.toml" }).id
			require("tests.support.hotstring_choices").with_file(Config, { [id] = true }, function()
				assert(Config.init(engine, resolve(nil)))
				local _, published = Config.load_all(nil, true); helpers.assert_true(published)
				assert(uv.fs_mkdir(personal, 448))
				local out = assert(io.open(personal .. "/custom.toml", "wb"))
				assert(out:write('[probe]\n"lateword" = { output = "FOUND", auto_expand = true }\n')); assert(out:close())
				_, published = Config.reload(); helpers.assert_true(published)
				engine:reset(false)
				local match
				for c in ("lateword"):gmatch(".") do match = engine:on_char(c) end
				helpers.assert_not_nil(match, "reload must read the newly created personal folder")
				helpers.assert_eq(match.replacement, "FOUND")
			end)
		end)
		os.remove(personal .. "/custom.toml"); uv.fs_rmdir(personal); uv.fs_rmdir(root)
		if not ok then error(err, 0) end
	end)

	helpers.it("distinguishes an absent personal root from an absent bundled root", function()
		local uv = require("luv")
		local root = assert(uv.fs_mkdtemp(uv.os_tmpdir() .. "/ergopti-scan-roots-XXXXXX"))
		local bad_root, link_root = root .. "/not-a-directory", root .. "/link-directory"
		local stream = assert(io.open(bad_root, "wb")); assert(stream:write("not a directory")); assert(stream:close())
		assert(uv.fs_symlink(root, link_root))
		local paths = require("infra.paths")
		local original_shared = paths.shared
		local ok, err = pcall(function()
			local Config = helpers.load_module("modules.hotstrings.hotstrings_config")
			local engine = require("hotstrings.engine.matcher").new()
			Config._set_override_config_dir_for_test(root)
			require("tests.support.hotstring_choices").with_file(Config, {}, function()
				assert(Config.init(engine, root .. "/absent-personal"))
				local _, published, _, receipt = Config.load_all(nil, true)
				helpers.assert_true(published, "an absent personal root is optional")
				helpers.assert_true(receipt.complete)
				paths.shared = function(path)
					if path == "hotstrings/data/catalogue" then return root .. "/absent-bundled" end
					return original_shared(path)
				end
				_, published = Config.load_all(nil, true)
				helpers.assert_eq(published, false, "an absent bundled root cannot certify a catalogue")
				paths.shared = function(path)
					if path == "hotstrings/data/catalogue" then return nil end
					return original_shared(path)
				end
				_, published = Config.load_all(nil, true)
				helpers.assert_eq(published, false, "an unresolved bundled root cannot certify a catalogue")
				for _, invalid in ipairs({ bad_root, link_root }) do
					paths.shared = function(path)
						if path == "hotstrings/data/catalogue" then return invalid end
						return original_shared(path)
					end
					local _, published, reason = Config.load_all(nil, true)
					helpers.assert_eq(published, false, "a file or no-follow link cannot certify a bundled directory")
					helpers.assert_eq(reason, "source-unavailable", "discovery must reject the root itself")
				end
			end)
		end)
		paths.shared = original_shared
		os.remove(bad_root); os.remove(link_root)
		uv.fs_rmdir(root)
		if not ok then error(err, 0) end
	end)

	helpers.it("retains the published personal source when a nested directory cannot be listed", function()
		local uv = require("luv")
		local root = assert(uv.fs_mkdtemp(uv.os_tmpdir() .. "/ergopti-scan-refusal-XXXXXX"))
		local nested = root .. "/private"
		assert(uv.fs_mkdir(nested, 448))
		local path = nested .. "/owned.toml"
		local f = assert(io.open(path, "wb"))
		assert(f:write('[probe]\n"owned" = { output = "OLD", auto_expand = true }\n')); assert(f:close())
		local function match(engine, trigger)
			engine:reset(false)
			local result
			for c in (trigger or "owned"):gmatch(".") do result = engine:on_char(c) end
			return result
		end
		local ok, err = pcall(function()
			local Config = helpers.load_module("modules.hotstrings.hotstrings_config")
			local engine = require("hotstrings.engine.matcher").new()
			Config._set_override_config_dir_for_test(root)
			local id = require("hotstrings.engine.catalogue.personal_files").describe({ "private", "owned.toml" }).id
			require("tests.support.hotstring_choices").with_file(Config, { [id] = true }, function()
				assert(Config.init(engine, root))
				Config.set_extra_mappings_provider(function()
					return { { trigger = "independent", replacement = "KEPT", auto_expand = true, is_case_sensitive_strict = true } }
				end)
				assert(uv.fs_chmod(nested, 0))
				local probe = uv.fs_opendir(nested)
				if probe then
					uv.fs_closedir(probe)
					print("  SKIP filesystem identity can list a mode-000 directory")
					return
				end
				local _, published, _, startup = Config.load_all(nil, true)
				helpers.assert_true(published, "cold boot must retain independently available mappings")
				helpers.assert_eq(startup.complete, false, "partial source discovery must be explicit")
				helpers.assert_eq(match(engine, "independent").replacement, "KEPT")
				assert(uv.fs_chmod(nested, 448))
				_, published = Config.reload(); helpers.assert_true(published)
				helpers.assert_eq(match(engine).replacement, "OLD")
				assert(uv.fs_chmod(nested, 0))
				_, published = Config.reload()
				helpers.assert_eq(published, false, "a failed directory listing cannot certify a removed source")
				helpers.assert_eq(match(engine).replacement, "OLD", "the last acknowledged matcher remains live")
				assert(uv.fs_chmod(nested, 448))
				_, published = Config.reload(); helpers.assert_true(published)
				helpers.assert_eq(match(engine).replacement, "OLD")
			end)
		end)
		uv.fs_chmod(nested, 448); os.remove(path); uv.fs_rmdir(nested); uv.fs_rmdir(root)
		if not ok then error(err, 0) end
	end)
end)
