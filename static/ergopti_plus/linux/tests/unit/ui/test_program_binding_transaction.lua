--- tests/unit/ui/test_program_binding_transaction.lua

--- Exercises the actual picker callback, state owners and conditional file writer.
local helpers = require("tests.helpers")
local Sandbox = require("test.config_unused_keys_contract").sandbox
local Writer = require("toml_codec.writer")
local Codec = require("toml_codec")
local Json = require("json")

local PRIOR = Json.encode({ version = 1, executable = "/private/prior-program", arguments = { "private-prior" } })
local NEXT = Json.encode({ version = 1, executable = "/private/next-program", arguments = { "private-next" } })
local CASES = {
	{ binding = "tap_3", section = "gestures", slot = "tap_3", module = "modules.gestures.manager" },
	{ binding = "keyboard__ctrl_j", section = "shortcuts.keyboard", slot = "ctrl_j", module = "modules.shortcuts.keyboard_shortcuts" },
	{ binding = "tap_key__number_row_left", section = "shortcuts.tap_keys", slot = "number_row_left", module = "modules.shortcuts.tap_keys" },
	{ binding = "script__script_altgr_enter", section = "shortcuts.script_control", slot = "script_altgr_enter", module = "modules.shortcuts.script_chords" },
}

--- Loads the exact production helper without booting unrelated tray providers.
local function callback(logger)
	local file = assert(io.open(helpers.driver_root() .. "/ui/menu/menu_builder.lua", "rb"))
	local source = file:read("*a"); file:close()
	local body = assert(source:match("(local function assign_parameterized_action%(.+\nend)\n\n%-%-%- Opens the shared searchable"))
	local factory = assert(load("return function(Logger) " .. body .. "\nreturn assign_parameterized_action end", "actual-program-picker"))()
	return factory(logger)
end

--- Renders the real binding providers while omitting unrelated top-level menus.
local function menu_rows(gestures, path)
	package.loaded["modules.shortcuts.manager"] = nil
	local shortcuts = require("modules.shortcuts.manager")
	shortcuts.init({ persist = true, config_path = path })
	-- A renderer captures its native dependencies and manifest cache at load.
	-- This fixture owns that instance as well as the real binding providers.
	package.loaded["infra.manifest_menu"] = nil
	local manifest = require("infra.manifest_menu")
	local original = manifest.get_array
	local adapter = {}; for key, value in pairs(manifest) do adapter[key] = value end
	adapter.get_array = function(key)
		if key == "top_level" then return { { id = "gestures" }, { id = "shortcuts" }, { id = "quit" } } end
		return original(key)
	end
	package.loaded["infra.manifest_menu"] = adapter
	package.loaded["ui.menu.menu_builder"] = nil
	return require("ui.menu.menu_builder").build({ gestures = gestures, shortcuts = shortcuts,
		is_paused = function() return false end, on_quit = function() end })
end

local function with_case(spec, body)
	local source = "[" .. spec.section .. "]\n" .. spec.slot .. " = \"run_program\"\n"
		.. "[gesture_parameters]\n" .. spec.binding .. "__run_program = " .. Json.encode(PRIOR) .. "\n"
		.. "[unrelated]\nkeep = 42\n"
	local loaded = {}; for name, value in pairs(package.loaded) do loaded[name] = value end
	local batch = Writer.batch_write
	local ok, failure = pcall(function()
		Sandbox.with_config(source, function(path)
			-- The actual contextual keyboard row reads the trigger owner too. A
			-- previous missing-default fixture may have cached it against a stubbed
			-- manifest; load this dependency against the restored production owner.
			for _, name in ipairs({ "modules.gestures.manager", "modules.shortcuts.keyboard_shortcuts", "modules.shortcuts.tap_keys",
				"modules.shortcuts.script_chords", "modules.hotstrings.magic_key", "infra.program_binding_transaction" }) do package.loaded[name] = nil end
			local controls = { changed = 0, backups = {}, logs = {}, publications = 0 }
			local logger = {}
			for _, level in ipairs({ "error", "warn", "info", "debug", "trace", "start", "success", "done" }) do
				logger[level] = function(_, message, ...)
					controls.logs[#controls.logs + 1] = string.format(message, ...)
				end
			end
			package.loaded["logger.shim"] = logger
			package.loaded["infra.config_paths"] = { config = function() return path end }
			package.loaded["adapters.storage"] = { get = function(_, default) return default end }
			package.loaded["ui.gesture_conflicts"] = { notify_boot = function() end, rows = function() return {} end }
			package.loaded["adapters.evdev_reader"] = { TOUCHPAD = "touchpad", close = function() error("picker must not close input") end }
			package.loaded["adapters.shell_runner"] = { has_command = function() return true end,
				quote = function(value) return "'" .. value .. "'" end }
			local gestures = require("modules.gestures.manager")
			gestures.init({ persist = true, config_path = path, enabled = false })
			local acquire_parameters = gestures.acquire_parameter_configuration
			gestures.acquire_parameter_configuration = function(token)
				controls.token = token
				return acquire_parameters(token)
			end
			local provider = require(spec.module)
			assert(provider.get_action(spec.slot) == "run_program")
			local apply_parameters = gestures.apply_parameter_configuration
			gestures.apply_parameter_configuration = function(token, state)
				if state[spec.binding .. "__run_program"] == PRIOR and controls.on_restore then controls.on_restore() end
				if controls.refuse_restore and state[spec.binding .. "__run_program"] == PRIOR then return false end
				return apply_parameters(token, state)
			end
			local method = provider == gestures and "apply_parameter_configuration_actions" or "apply_configuration"
			local apply_assignments = provider[method]
			provider[method] = function(token, state)
				local accepted = apply_assignments(token, state)
				if controls.refuse_application then controls.refuse_application = false; return false end
				return accepted
			end
			local release_name = provider == gestures and "release_parameter_configuration" or "release_configuration"
			local release = provider[release_name]
			provider[release_name] = function(token)
				if controls.refuse_release == "before" then return false end
				local result = release(token)
				if controls.on_release then controls.on_release() end
				if controls.refuse_release == "after" then return false end
				return result
			end
			if provider ~= gestures then
				local parameter_release = gestures.release_parameter_configuration
				gestures.release_parameter_configuration = function(token)
					local result = parameter_release(token)
					if controls.on_parameter_release then controls.on_parameter_release() end
					if controls.refuse_parameter_release then return false end
					return result
				end
			end
			local files = {
				read = function(target) return Writer.read_classified(target) end,
				read_with_status = function(target) return Writer.read_classified(target) end,
				write = function() error("unconditional publication") end,
				write_if_unchanged = function(target, content, expected)
					if target ~= path then controls.backups[#controls.backups + 1] = target end
					if target == path then
						controls.publications = controls.publications + 1
						if controls.before_publish then controls.before_publish(path) end
						if controls.refuse_publish then return false, "private-next native refusal" end
						if controls.refuse_candidate and content:find("private-next", 1, true) then
							return false, "private-next candidate refusal"
						end
					end
					return Writer.publish_if_unchanged(target, content, nil, expected)
				end,
			}
			package.loaded["adapters.file_system"] = files
			local called, err = pcall(body, callback(logger), gestures, provider, controls, path, source)
			for _, backup in ipairs(controls.backups) do os.remove(backup); os.remove(backup .. ".tmp") end
			if not called then error(err, 0) end
		end)
	end)
	Writer.batch_write = batch
	for name in pairs(package.loaded) do if loaded[name] == nil then package.loaded[name] = nil end end
	for name, value in pairs(loaded) do package.loaded[name] = value end
	assert(ok, failure)
end

helpers.describe("Linux program picker transaction", function()
	helpers.it("(program-picker) owns its real renderer independently of a previous menu fixture", function()
		with_case(CASES[2], function(_, gestures, _, controls, path, source)
			local previous = require("infra.manifest_menu")
			local foreign = {}
			for name, value in pairs(previous) do foreign[name] = value end
			foreign.build = function(key, ...)
				if key == "shortcuts_menu" then return {} end
				return previous.build(key, ...)
			end
			package.loaded["infra.manifest_menu"] = foreign
			local selected
			package.loaded["ui.action_picker.bridge"] = { open = function(options, confirm)
				if options.current == "run_program" then selected = confirm end
				return true
			end }
			local rows = menu_rows(gestures, path)
			local picker_label = require("infra.i18n").get("dialog.action_picker.label") .. "…"
			local function open_current(tree)
				for _, row in ipairs(tree) do
					if row.title == picker_label and type(row.fn) == "function" then row.fn() end
					if selected then return end
					if row.menu then open_current(row.menu) end
				end
			end
			open_current(rows)
			helpers.assert_type(selected, "function", "the owned actual keyboard provider remains reachable")
			controls.refuse_publish = true
			helpers.assert_eq(selected("run_program", nil, NEXT), false)
			helpers.assert_eq(Sandbox.read_bytes(path), source)
			helpers.assert_eq(gestures.get_action_parameter("keyboard__ctrl_j", "run_program"), PRIOR)
		end)
	end)
	for _, spec in ipairs(CASES) do
		helpers.it("(program-picker) preserves exact prior scalar when " .. spec.binding .. " publication refuses", function()
			with_case(spec, function(pick, gestures, provider, controls, path, source)
				local original = Writer.batch_write
				Writer.batch_write = function(target, updates, ...)
					if updates[1].section == spec.section then return false, "injected assignment publication refusal" end
					return original(target, updates, ...)
				end
				controls.refuse_publish = true
				helpers.assert_eq(pick({ is_paused = function() return false end }, gestures, spec.binding, "run_program",
					function() return provider.set_action(spec.slot, "run_program") end, NEXT), false)
				helpers.assert_eq(Sandbox.read_bytes(path), source, "failed confirmation must preserve exact prior source")
				helpers.assert_eq(gestures.get_action_parameter(spec.binding, "run_program"), PRIOR,
					"failed confirmation cannot replace the executable of an existing binding")
			end)
		end)
		helpers.it("(program-picker) commits " .. spec.binding .. " scalar and assignment together", function()
			with_case(spec, function(pick, gestures, provider, controls, path)
				local split_calls = 0
				helpers.assert_eq(pick({ is_paused = function() return false end }, gestures, spec.binding, "run_program",
					function() split_calls = split_calls + 1; return provider.set_action(spec.slot, "run_program") end, NEXT), true)
				helpers.assert_eq(split_calls, 0, "program edits use the joint owner rather than a second persistence callback")
				helpers.assert_eq(controls.publications, 1, "one conditional config publication owns both fields")
				helpers.assert_eq(Codec.decode(Sandbox.read_bytes(path)).gesture_parameters[spec.binding .. "__run_program"], NEXT)
				helpers.assert_eq(gestures.get_action_parameter(spec.binding, "run_program"), NEXT)
				helpers.assert_eq(provider.get_action(spec.slot), "run_program")
				helpers.assert_eq(Codec.decode(Sandbox.read_bytes(path)).unrelated.keep, 42)
			end)
		end)
		helpers.it("(program-picker) retains " .. spec.binding .. " compensation debt until exact recovery", function()
			with_case(spec, function(pick, gestures, provider, controls, path, source)
				controls.refuse_application, controls.refuse_restore = true, true
				local function edit() return pick({ is_paused = function() return false end }, gestures, spec.binding,
					"run_program", function() return provider.set_action(spec.slot, "run_program") end, NEXT) end
				helpers.assert_eq(edit(), false)
				helpers.assert_eq(Sandbox.read_bytes(path), source, "runtime refusal publishes no changed canonical source")
				helpers.assert_eq(gestures.get_action_parameter(spec.binding, "run_program"), NEXT, "failed inverse remains owned")
				helpers.assert_eq(gestures.set_action_parameter(spec.binding, "run_program", PRIOR), false, "new parameter writes are fenced")
				helpers.assert_eq(provider.set_action(spec.slot, "none"), false, "new assignment writes are fenced")
				helpers.assert_eq(gestures.acquire_parameter_configuration({}), false, "execution admission remains owned")
				helpers.assert_eq(edit(), false, "successor cannot borrow unacknowledged compensation")
				controls.refuse_restore, controls.refuse_publish = false, true
				helpers.assert_eq(edit(), false, "retry restores debt before the next independent publication refusal")
				helpers.assert_eq(gestures.get_action_parameter(spec.binding, "run_program"), PRIOR)
				helpers.assert_eq(Sandbox.read_bytes(path), source)
				controls.refuse_publish = false
				helpers.assert_eq(edit(), true, "settled owners admit a new confirmed edit")
				for _, line in ipairs(controls.logs) do
					helpers.assert_eq(line:find("private-next", 1, true), nil, "failure diagnostics contain no private argv")
					helpers.assert_eq(line:find("/private/", 1, true), nil, "failure diagnostics contain no executable path")
				end
			end)
		end)
		helpers.it("(program-picker) preserves foreign source during " .. spec.binding .. " publication conflict", function()
			with_case(spec, function(pick, gestures, provider, controls, path)
				local foreign = "[foreign]\nkeep = \"external writer\"\n"
				controls.before_publish = function(target) Sandbox.write_bytes(target, foreign) end
				helpers.assert_eq(pick({ is_paused = function() return false end }, gestures, spec.binding, "run_program",
					function() return provider.set_action(spec.slot, "run_program") end, NEXT), false)
				helpers.assert_eq(Sandbox.read_bytes(path), foreign, "rollback never overwrites a foreign source")
				helpers.assert_eq(gestures.get_action_parameter(spec.binding, "run_program"), PRIOR)
			end)
		end)
		helpers.it("(program-picker) omits " .. spec.binding .. " executable and argv from actual provider rows", function()
			with_case(spec, function(_, gestures, _, controls, path)
				local rows = menu_rows(gestures, path)
				local labels = {}
				local function collect(tree)
					for _, row in ipairs(tree) do
						if row.title then labels[#labels + 1] = row.title end
						if row.menu then collect(row.menu) end
					end
				end
				collect(rows)
				helpers.assert_true(#labels > 20, "actual declared providers must produce a populated menu")
				for _, label in ipairs(labels) do
					helpers.assert_eq(label:find("private-prior", 1, true), nil, "menu contains no private argument")
					helpers.assert_eq(label:find("/private/", 1, true), nil, "menu contains no executable path")
				end
			end)
		end)
		helpers.it("(program-picker) propagates " .. spec.binding .. " refusal through its actual provider callback", function()
			with_case(spec, function(_, gestures, _, controls, path, source)
				local selected
				package.loaded["ui.action_picker.bridge"] = { open = function(options, confirm)
					if options.current == "run_program" then selected = confirm end
					return true
				end }
				local rows = menu_rows(gestures, path)
				local picker_label = require("infra.i18n").get("dialog.action_picker.label") .. "…"
				local function open_current(tree)
					for _, row in ipairs(tree) do
						if row.title == picker_label and type(row.fn) == "function" then row.fn() end
						if selected then return end
						if row.menu then open_current(row.menu) end
					end
				end
				open_current(rows)
				helpers.assert_eq(type(selected), "function", "actual native provider must open the current binding's picker")
				controls.refuse_publish = true
				helpers.assert_eq(selected("run_program", nil, NEXT), false, "UI callback returns the durable transaction refusal")
				helpers.assert_eq(Sandbox.read_bytes(path), source)
				helpers.assert_eq(gestures.get_action_parameter(spec.binding, "run_program"), PRIOR)
			end)
		end)
	end
	helpers.it("(program-picker) retains parameter ownership until physical program retirement is acknowledged", function()
		with_case(CASES[1], function(pick, gestures, provider, controls, path, source)
			local stopped = gestures.stop_programs
			local refusing = true
			gestures.stop_programs = function() if refusing then return false end; return stopped() end
			local function edit() return pick({ is_paused = function() return false end }, gestures, "tap_3", "run_program",
				function() return provider.set_action("tap_3", "run_program") end, NEXT) end
			helpers.assert_eq(edit(), false)
			helpers.assert_eq(gestures.set_action("tap_3", "none"), false, "unsettled child retains the mutation fence")
			helpers.assert_eq(edit(), false)
			helpers.assert_eq(Sandbox.read_bytes(path), source)
			helpers.assert_eq(controls.publications, 0)
			refusing = false
			helpers.assert_eq(edit(), true, "a terminal receipt releases the retired owner before the next edit")
		end)
	end)
	helpers.it("(program-picker) rejects reentrant edits during configuration acquisition", function()
		with_case(CASES[1], function(pick, gestures, provider, controls)
			local acquire = gestures.acquire_parameter_configuration
			local nested, acquisitions = nil, 0
			gestures.acquire_parameter_configuration = function(token)
				acquisitions = acquisitions + 1
				nested = require("infra.program_binding_transaction").apply("tap_3", PRIOR, function() return false end)
				return acquire(token)
			end
			helpers.assert_eq(pick({ is_paused = function() return false end }, gestures, "tap_3", "run_program",
				function() return provider.set_action("tap_3", "run_program") end, NEXT), true)
			helpers.assert_eq(nested, false, "nested acquisition cannot replace the current transaction")
			helpers.assert_eq(acquisitions, 1)
			helpers.assert_eq(controls.publications, 1)
		end)
	end)
	helpers.it("(program-picker) assignment snapshot and application require an exact owned token", function()
		with_case(CASES[1], function(_, gestures)
			helpers.assert_eq(gestures.parameter_configuration_actions_snapshot(nil), nil)
			helpers.assert_eq(gestures.apply_parameter_configuration_actions(nil, gestures.get_all_actions()), false)
			local token = {}
			helpers.assert_eq(gestures.acquire_parameter_configuration(token), true)
			helpers.assert_eq(gestures.parameter_configuration_actions_snapshot({}), nil)
			local actions = gestures.parameter_configuration_actions_snapshot(token)
			helpers.assert_eq(type(actions), "table")
			actions.tap_3 = "future_unknown_action"
			helpers.assert_eq(gestures.apply_parameter_configuration_actions(token, actions), false)
			helpers.assert_eq(gestures.get_action("tap_3"), "run_program")
			helpers.assert_eq(gestures.release_parameter_configuration(token), true)
		end)
	end)
	for _, mode in ipairs({ "before", "after" }) do
		helpers.it("(program-picker) preserves the inverse when lease release refuses " .. mode .. " mutation", function()
			with_case(CASES[2], function(pick, gestures, provider, controls, path, source)
				controls.refuse_release = mode
				local function edit() return pick({ is_paused = function() return false end }, gestures, "keyboard__ctrl_j",
					"run_program", function() return provider.set_action("ctrl_j", "run_program") end, NEXT) end
				helpers.assert_eq(edit(), false)
				helpers.assert_eq(Sandbox.read_bytes(path), source, "refused release cannot discard the committed publication's inverse")
				helpers.assert_eq(gestures.get_action_parameter("keyboard__ctrl_j", "run_program"), PRIOR)
				controls.refuse_release, controls.refuse_publish = nil, true
				helpers.assert_eq(edit(), false)
				helpers.assert_eq(Sandbox.read_bytes(path), source)
			end)
		end)
	end
	for _, spec in ipairs(CASES) do
		for _, mode in ipairs({ "before", "after" }) do
			helpers.it("(program-picker) releases recovered publication debt for " .. spec.binding .. " after " .. mode .. " lease refusal", function()
				with_case(spec, function(pick, gestures, provider, controls, path, source)
					local function edit() return pick({ is_paused = function() return false end }, gestures, spec.binding,
						"run_program", function() return provider.set_action(spec.slot, "run_program") end, NEXT) end
					controls.refuse_release, controls.refuse_restore = mode, true
					helpers.assert_eq(edit(), false, "committed publication retains refused native compensation")
					helpers.assert_eq(gestures.get_action_parameter(spec.binding, "run_program"), NEXT)
					helpers.assert_eq(Codec.decode(Sandbox.read_bytes(path)).gesture_parameters[spec.binding .. "__run_program"], NEXT)
					helpers.assert_eq(require("infra.program_binding_transaction").pending(), true)
					controls.refuse_release, controls.refuse_restore, controls.refuse_candidate = nil, false, true
					helpers.assert_eq(edit(), false, "recover the prior inverse before the next candidate's independent refusal")
					helpers.assert_eq(Sandbox.read_bytes(path), source, "recovered compensation restores exact original bytes")
					helpers.assert_eq(gestures.get_action_parameter(spec.binding, "run_program"), PRIOR)
					helpers.assert_eq(require("infra.program_binding_transaction").pending(), false,
						"successful retained compensation must retire the candidate source guard and release its leases")
					helpers.assert_eq(gestures.set_action_parameter(spec.binding, "run_program", PRIOR), true,
						"terminal compensation admits subsequent ordinary preference mutation")
				end)
			end)
		end
	end
	helpers.it("(program-picker) rejects a nested edit during retained inverse compensation", function()
		with_case(CASES[1], function(pick, gestures, provider, controls, path, source)
			local function edit() return pick({ is_paused = function() return false end }, gestures, "tap_3", "run_program",
				function() return provider.set_action("tap_3", "run_program") end, NEXT) end
			controls.refuse_application, controls.refuse_restore = true, true
			helpers.assert_eq(edit(), false)
			local nested, nested_retry, inverses = nil, nil, 0
			controls.refuse_restore = false
			controls.on_restore = function()
				inverses = inverses + 1
				if inverses == 1 then
					nested_retry = controls.token.retry_restore()
					nested = require("infra.program_binding_transaction").apply("tap_3", NEXT, function() return false end)
				end
			end
			controls.refuse_publish = true
			helpers.assert_eq(edit(), false)
			helpers.assert_eq(nested, false)
			helpers.assert_eq(nested_retry, false, "native inverse callback cannot borrow the active owner's retry")
			helpers.assert_eq(inverses, 2, "one retained inverse and one later independent publication inverse")
			helpers.assert_eq(Sandbox.read_bytes(path), source)
			helpers.assert_eq(gestures.get_action_parameter("tap_3", "run_program"), PRIOR)
		end)
	end)
	helpers.it("(program-picker) rejects a nested edit during retained native retirement", function()
		with_case(CASES[1], function(pick, gestures, provider, controls, path, source)
			local stop = gestures.stop_programs
			local refuse, retirement_calls, nested, nested_retry = true, 0, nil, nil
			gestures.stop_programs = function()
				if refuse then return false end
				retirement_calls = retirement_calls + 1
				if retirement_calls == 1 then
					nested_retry = controls.token.retry_restore()
					nested = require("infra.program_binding_transaction").apply("tap_3", NEXT, function() return false end)
				end
				return stop()
			end
			local function edit() return pick({ is_paused = function() return false end }, gestures, "tap_3", "run_program",
				function() return provider.set_action("tap_3", "run_program") end, NEXT) end
			helpers.assert_eq(edit(), false)
			refuse, controls.refuse_publish = false, true
			helpers.assert_eq(edit(), false)
			helpers.assert_eq(nested, false)
			helpers.assert_eq(nested_retry, false, "native retirement cannot recursively settle the same owner")
			helpers.assert_eq(retirement_calls, 2, "one retained retirement and the next independent transaction retirement")
			helpers.assert_eq(Sandbox.read_bytes(path), source)
		end)
	end)
	helpers.it("(program-picker) rejects a nested edit from the release pause getter", function()
		with_case(CASES[1], function(pick, gestures, provider, controls, path, source)
			local retrying, nested, nested_retry, reads = false, nil, nil, 0
			local function paused()
				if retrying then
					reads = reads + 1
					if reads == 1 then
						nested_retry = controls.token.retry_restore()
						nested = require("infra.program_binding_transaction").apply("tap_3", NEXT, function() return false end)
					end
				end
				return false
			end
			local function edit() return pick({ is_paused = paused }, gestures, "tap_3", "run_program",
				function() return provider.set_action("tap_3", "run_program") end, NEXT) end
			controls.refuse_application, controls.refuse_restore = true, true
			helpers.assert_eq(edit(), false)
			controls.refuse_restore, controls.refuse_publish, retrying = false, true, true
			helpers.assert_eq(edit(), false)
			helpers.assert_eq(nested, false)
			helpers.assert_eq(nested_retry, false, "release pause callback cannot enter an active journal retry")
			helpers.assert_eq(reads, 4, "one retry release, then the next acquisition, runtime application and release pause checks")
			helpers.assert_eq(Sandbox.read_bytes(path), source)
		end)
	end)
	helpers.it("(program-picker) retains a refused release without overwriting a foreign canonical source", function()
		with_case(CASES[2], function(pick, gestures, provider, controls, path)
			local foreign = "[foreign]\nkeep = 17\n"
			controls.refuse_release = "after"
			controls.on_release = function() Sandbox.write_bytes(path, foreign) end
			local function edit() return pick({ is_paused = function() return false end }, gestures, "keyboard__ctrl_j", "run_program",
				function() return provider.set_action("ctrl_j", "run_program") end, NEXT) end
			helpers.assert_eq(edit(), false)
			helpers.assert_eq(Sandbox.read_bytes(path), foreign, "ambiguous release never restores over foreign bytes")
			helpers.assert_eq(gestures.set_action_parameter("keyboard__ctrl_j", "run_program", PRIOR), false)
			controls.refuse_release, controls.on_release = nil, nil
			helpers.assert_eq(edit(), false, "foreign canonical source cannot admit the retained inverse")
			helpers.assert_eq(Sandbox.read_bytes(path), foreign)
		end)
	end)
	helpers.it("(program-picker) keeps a logical mutation fence after the last lease is ambiguously released", function()
		with_case(CASES[2], function(pick, gestures, provider, controls, path, source)
			local foreign, candidate
			controls.refuse_parameter_release = true
			controls.on_parameter_release = function()
				candidate = Sandbox.read_bytes(path)
				foreign = candidate .. "\n[foreign]\nkeep = 23\n"
				Sandbox.write_bytes(path, foreign)
			end
			helpers.assert_eq(pick({ is_paused = function() return false end }, gestures, "keyboard__ctrl_j", "run_program",
				function() return provider.set_action("ctrl_j", "run_program") end, NEXT), false)
			helpers.assert_eq(Sandbox.read_bytes(path), foreign)
			local runner = require("adapters.program_runner")
			local spawn, acquisitions = runner.spawn, 0
			runner.spawn = function(...) acquisitions = acquisitions + 1; return spawn(...) end
			local called, started = pcall(gestures.run_program, "keyboard__ctrl_j")
			runner.spawn = spawn
			helpers.assert_eq(called, true)
			helpers.assert_eq(started, false, "actual runtime refuses pending journal debt before native acquisition")
			helpers.assert_eq(acquisitions, 0, "the actual native runner constructor remains uncalled")
			helpers.assert_eq(gestures.set_action_parameter("keyboard__ctrl_j", "run_program", PRIOR), false,
				"retained journal debt blocks ordinary parameter writes even after the last physical lease was released")
			helpers.assert_eq(gestures.acquire_parameter_configuration({}), false, "another configuration owner cannot borrow journal debt")
			helpers.assert_eq(pick({ is_paused = function() return false end }, gestures, "keyboard__ctrl_j", "none",
				function() return provider.set_action("ctrl_j", "none") end), false,
				"the native picker cannot sidestep program debt by assigning an unparameterized action")
			helpers.assert_eq(Sandbox.read_bytes(path), foreign, "foreign bytes remain authoritative")
			controls.refuse_parameter_release, controls.on_parameter_release, controls.refuse_candidate = false, nil, true
			Sandbox.write_bytes(path, candidate)
			helpers.assert_eq(pick({ is_paused = function() return false end }, gestures, "keyboard__ctrl_j", "run_program",
				function() return provider.set_action("ctrl_j", "run_program") end, NEXT), false)
			helpers.assert_eq(Sandbox.read_bytes(path), source, "an exact matching checkpoint admits the retained inverse")
			helpers.assert_eq(gestures.get_action_parameter("keyboard__ctrl_j", "run_program"), PRIOR)
			helpers.assert_eq(require("infra.program_binding_transaction").pending(), false, "terminal recovery releases logical debt")
		end)
	end)
	helpers.it("(program-picker) refuses nested publication during configuration path resolution", function()
		with_case(CASES[1], function(pick, gestures, provider, controls, path)
			local nested, reads = nil, 0
			package.loaded["infra.config_paths"] = { config = function()
				reads = reads + 1
				if reads == 1 then nested = require("infra.program_binding_transaction").apply("tap_3", NEXT,
					function() return false end) end
				return path
			end }
			helpers.assert_eq(pick({ is_paused = function() return false end }, gestures, "tap_3", "run_program",
				function() return provider.set_action("tap_3", "run_program") end, NEXT), true)
			helpers.assert_eq(nested, false, "an unresolved outer path retains the exact construction claim")
			helpers.assert_eq(reads, 1)
			helpers.assert_eq(controls.publications, 1)
		end)
	end)
end)
