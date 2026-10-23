--- tests/unit/ui/menu/shortcuts/test_program_binding_transaction.lua

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
--- @param extra table|nil Further menu context owners, such as the physical magic key.
local function menu_rows(gestures, path, extra)
	package.loaded["modules.shortcuts.manager"] = nil
	local shortcuts = require("modules.shortcuts.manager")
	shortcuts.init({ persist = true, config_path = path })
	-- A renderer captures its native dependencies and manifest cache at load.
	-- This fixture owns that instance as well as the real binding providers.
	package.loaded["infra.manifest_menu"] = nil
	local manifest = require("infra.manifest_menu")
	local root, selected, boundary = manifest.get_root(), {}, nil
	for _, row in ipairs(manifest.get_array("top_level")) do
		local applicable = row.platforms == nil
		for _, platform in ipairs(row.platforms or {}) do
			if platform == "linux" then applicable = true end
		end
		if row.id == "---" and applicable then boundary = row end
		if row.id == "gestures" or row.id == "shortcuts" then selected[#selected + 1] = row end
		if row.id == "quit" and applicable then
			assert(boundary, "the actual declared boundary must precede native Quit")
			selected[#selected + 1], selected[#selected + 2] = boundary, row
		end
	end
	-- Select genuine source records through the renderer's actual root and reader.
	root.top_level = selected
	package.loaded["ui.menu.menu_builder"] = nil
	local ctx = { gestures = gestures, shortcuts = shortcuts,
		is_paused = function() return false end, on_quit = function() end }
	for name, value in pairs(extra or {}) do ctx[name] = value end
	return require("ui.menu.menu_builder").build(ctx)
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

--- Opens the real picker and configuration writer over two private folders.
--- @param body function Scenario using the retained native page and disk sources.
local function with_configuration_picker(body)
	require("tests.support.ui.menu.llm.numeric_configuration_fixture").with_configuration(function(f)
		local suffix = "[shortcuts.keyboard]\nctrl_j = \"run_program\"\n[gesture_parameters]\n"
			.. "keyboard__ctrl_j__run_program = " .. Json.encode(PRIOR) .. "\n"
		for _, id in ipairs({ "a", "b" }) do
			Sandbox.write_bytes(f.dirs[id] .. "/config.toml", f.bytes(id) .. suffix)
		end
		for _, name in ipairs({ "modules.gestures.manager", "modules.shortcuts.keyboard_shortcuts", "modules.shortcuts.tap_keys",
			"modules.shortcuts.script_chords", "modules.hotstrings.magic_key", "infra.program_binding_transaction",
			"ui.action_picker.bridge" }) do package.loaded[name] = nil end
		local seen = { logs = {}, changed = 0 }
		local logger = {}
		for _, level in ipairs({ "error", "warn", "info", "debug", "trace", "start", "success", "done" }) do
			logger[level] = function(_, message, ...) seen.logs[#seen.logs + 1] = string.format(message, ...) end
		end
		package.loaded["logger.shim"] = logger
		package.loaded["ui.gesture_conflicts"] = { notify_boot = function() end, rows = function() return {} end }
		package.loaded["adapters.evdev_reader"] = { TOUCHPAD = "touchpad" }
		package.loaded["adapters.program_providers"] = {}
		local gestures = require("modules.gestures.manager")
		gestures.init({ persist = true, config_path = f.paths.config("config.toml"), enabled = false })
		local keyboard = require("modules.shortcuts.keyboard_shortcuts")
		local bridge = require("ui.action_picker.bridge")
		local function find(rows, predicate)
			for _, row in ipairs(rows or {}) do
				if predicate(row) then return row end
				local found = find(row.menu, predicate); if found then return found end
			end
		end
		function f.open_picker()
			local rows = menu_rows(gestures, f.paths.config("config.toml"), {
				on_menu_changed = function() seen.changed = seen.changed + 1 end,
			})
			local prefix = keyboard.get_slot_label("ctrl_j") .. " → "
			local slot = assert(find(rows, function(row)
				return type(row.title) == "string" and row.title:sub(1, #prefix) == prefix
			end), "the actual keyboard slot is rendered")
			local title = require("infra.i18n").get("dialog.action_picker.label") .. "…"
			local command = assert(find(slot.menu, function(row) return row.title == title and type(row.fn) == "function" end))
			command.fn()
			assert(bridge.is_open() and f.host.is_visible("action_picker"), "the real picker session is open")
		end
		function f.change_folder(id)
			assert(f.host.show("paths_editor"))
			local result = require("ui.paths_editor.bridge").on_message({ action = "save", configDir = f.dirs[id] }, {
				config_paths = f.paths, webview_manager = f.host, on_reload = function() return true end,
			})
			helpers.assert_eq({ result.saved, result.reloaded, result.hidden }, { true, true, true })
			helpers.assert_eq(f.paths.config("config.toml"), f.dirs[id] .. "/config.toml")
			helpers.assert_eq(f.host.is_visible("action_picker"), true, "saving paths does not retire another page")
		end
		function f.pick(action, parameter)
			bridge.on_message({ action = "confirm", id = action, parameter = parameter }, {})
		end
		function f.cancel() bridge.on_message({ action = "cancel" }, {}) end
		body(f, keyboard, bridge, seen)
	end)
end

helpers.describe("Linux action picker opening configuration", function()
	for _, vector in ipairs({ { action = "none", identical = false }, { action = "none", identical = true },
		{ action = "send_text", parameter = "private picked text", identical = false } }) do
		helpers.it("(picker-opening-config) refuses " .. vector.action .. " after switching to "
			.. (vector.identical and "byte-identical" or "different") .. " folder", function()
			with_configuration_picker(function(f, keyboard, bridge, seen)
				if vector.identical then Sandbox.write_bytes(f.dirs.b .. "/config.toml", f.bytes("a")) end
				local before = { a = f.bytes("a"), b = f.bytes("b") }
				f.open_picker()
				f.change_folder("b")
				f.pick(vector.action, vector.parameter)
				local bound_logs = 0
				for _, line in ipairs(seen.logs) do if line:find("Bound ", 1, true) then bound_logs = bound_logs + 1 end end
				helpers.assert_eq({ source_a = f.bytes("a"), source_b = f.bytes("b"), action = keyboard.get_action("ctrl_j"),
					changed = seen.changed, picker_open = bridge.is_open(), bound_logs = bound_logs },
					{ source_a = before.a, source_b = before.b, action = "run_program", changed = 0, picker_open = true, bound_logs = 0 },
					"a retained A picker must refuse B publication, runtime mutation and false success together")
				f.cancel()
				helpers.assert_eq(bridge.is_open(), false)
			end)
		end)
	end
	for _, folder in ipairs({ "a", "b" }) do
		for _, action in ipairs({ "none", "send_text" }) do
			helpers.it("(picker-opening-config) commits a fresh " .. folder .. " picker for " .. action, function()
				with_configuration_picker(function(f, keyboard, bridge, seen)
					local before_a = f.bytes("a")
					if folder == "b" then f.open_picker(); f.change_folder("b"); f.cancel() end
					f.open_picker()
					f.pick(action, action == "send_text" and "new page text" or nil)
					helpers.assert_eq(f.document(folder).shortcuts.keyboard.ctrl_j, action)
					helpers.assert_eq(keyboard.get_action("ctrl_j"), action)
					helpers.assert_eq(seen.changed, 1)
					helpers.assert_eq(bridge.is_open(), false)
					if action == "send_text" then
						helpers.assert_eq(f.document(folder).gesture_parameters.keyboard__ctrl_j__send_text, "new page text")
					end
					if folder == "b" then helpers.assert_eq(f.bytes("a"), before_a) end
				end)
			end)
		end
	end
end)

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


--- Opens the genuine rendered picker for this fixture's one configured program.
local function parameterized_confirmation(gestures, path)
	-- The existing reduced fixture omits the post-commit desktop notice port.
	-- Its genuine signature is show({ key, slot }) -> queued; never open a UI here.
	local notices = {}
	package.loaded["ui.gesture_conflicts"].show = function(group)
		notices[#notices + 1] = { key = group.key, slot = group.slot }
		return true
	end
	local selected, opened = nil, 0
	package.loaded["ui.action_picker.bridge"] = { open = function(options, confirm)
		if options.current == "run_program" then selected, opened = confirm, opened + 1 end
		return true
	end }
	local rows = menu_rows(gestures, path)
	local picker_label = require("infra.i18n").get("dialog.action_picker.label") .. "…"
	local function visit(tree)
		for _, row in ipairs(tree) do
			if row.title == picker_label and type(row.fn) == "function" then row.fn() end
			if row.menu then visit(row.menu) end
		end
	end
	visit(rows)
	helpers.assert_eq(opened, 1, "the actual configured row owns the confirmation")
	helpers.assert_type(selected, "function")
	return selected, notices
end

helpers.describe("Linux parameterized assignment transaction", function()
	for _, spec in ipairs(CASES) do
		helpers.it("(parameterized-picker) refuses " .. spec.binding .. " without retaining a new URL parameter", function()
			with_case(spec, function(_, gestures, provider, controls, path)
				local prior, candidate = "https://prior.example/path", "https://next.example/path"
				helpers.assert_true(gestures.set_action_parameter(spec.binding, "open_url", prior))
				local source = Sandbox.read_bytes(path)
				local confirm, notices = parameterized_confirmation(gestures, path)
				local original = Writer.batch_write
				Writer.batch_write = function(target, updates, ...)
					for _, row in ipairs(updates) do
						if target == path and row.section == spec.section and row.key == spec.slot then
							return false, "controlled assignment publication refusal"
						end
					end
					return original(target, updates, ...)
				end
				controls.refuse_publish = true
				local accepted = confirm("open_url", nil, candidate)
				helpers.assert_eq(accepted, false)
				helpers.assert_eq(#notices, 0, "refused assignment cannot announce success")
				helpers.assert_eq(Sandbox.read_bytes(path), source, "a refused selection preserves the exact complete source")
				helpers.assert_eq(gestures.get_action_parameter(spec.binding, "open_url"), prior,
					"assignment refusal cannot publish its parameter independently")
				helpers.assert_eq(provider.get_action(spec.slot), "run_program")
				helpers.assert_eq(gestures.get_action_parameter(spec.binding, "run_program"), PRIOR)
			end)
		end)
		helpers.it("(parameterized-picker) commits " .. spec.binding .. " text and assignment in one publication", function()
			with_case(spec, function(_, gestures, provider, controls, path)
				local candidate = "literal text % and é"
				local confirm, notices = parameterized_confirmation(gestures, path)
				local before = controls.publications
				helpers.assert_eq(confirm("send_text", nil, candidate), true)
				helpers.assert_eq(#notices, spec.binding == "tap_3" and 1 or 0)
				if #notices > 0 then helpers.assert_eq(notices[1], { key = "tap_3", slot = "tap_3" }) end
				helpers.assert_eq(controls.publications - before, 1, "one conditional publication contains both fields")
				local document = Codec.decode(Sandbox.read_bytes(path))
				local assignment = document
				for part in spec.section:gmatch("[^.]+") do assignment = assignment[part] end
				helpers.assert_eq(assignment[spec.slot], "send_text")
				helpers.assert_eq(document.gesture_parameters[spec.binding .. "__send_text"], candidate)
				helpers.assert_eq(gestures.get_action_parameter(spec.binding, "send_text"), candidate)
				helpers.assert_eq(provider.get_action(spec.slot), "send_text")
				helpers.assert_eq(document.unrelated.keep, 42)
				helpers.assert_eq(gestures.get_action_parameter(spec.binding, "run_program"), PRIOR)
			end)
		end)
	end
	helpers.it("(parameterized-picker) leaves unparameterized None on its original assignment path", function()
		with_case(CASES[2], function(_, gestures, provider, controls, path)
			local confirm, notices = parameterized_confirmation(gestures, path)
			helpers.assert_eq(confirm("none"), true)
			helpers.assert_eq(#notices, 0)
			helpers.assert_eq(provider.get_action("ctrl_j"), "none")
			helpers.assert_eq(Codec.decode(Sandbox.read_bytes(path)).shortcuts.keyboard.ctrl_j, "none")
			helpers.assert_eq(gestures.get_action_parameter("keyboard__ctrl_j", "run_program"), PRIOR)
			helpers.assert_eq(controls.publications, 0, "None does not construct a parameter transaction")
		end)
	end)
end)


helpers.describe("parameter transaction physical boundary", function()
	for _, selected in ipairs({
		{ label = "default program", action = nil, scalar = NEXT },
		{ label = "URL", action = "open_url", scalar = "https://next.example/path" },
		{ label = "literal text", action = "send_text", scalar = "not physical output" },
	}) do
		helpers.it("(parameterized-physical-boundary) refuses recognized physical " .. selected.label .. " before acquiring logical leases", function()
			local spec = { binding = "keyboard__physical_none_KeyJ", section = "shortcuts.keyboard",
				slot = "physical_none_KeyJ", module = "modules.shortcuts.keyboard_shortcuts" }
			with_case(spec, function(_, gestures, provider, controls, path, source)
				helpers.assert_eq(provider.configuration_domain(spec.binding), "keyboard", "the genuine provider recognizes this physical registry slot")
				helpers.assert_type(gestures.action_parameter_update(spec.binding, selected.action or "run_program", selected.scalar), "table",
					"the actual central parameter constructor accepts this binding and scalar")
				helpers.assert_eq(provider.physical_delivery_available(), false, "public physical delivery remains genuinely unavailable")
				local prior_parameters = gestures.get_all_action_parameters()
				local stopped, original_stop = 0, gestures.stop_programs
				gestures.stop_programs = function() stopped = stopped + 1; return original_stop() end
				helpers.assert_eq(controls.token, nil)
				helpers.assert_eq(require("infra.program_binding_transaction").apply(spec.binding, selected.scalar,
					function() return false end, selected.action), false)
				helpers.assert_eq(Sandbox.read_bytes(path), source)
				helpers.assert_eq(gestures.get_all_action_parameters(), prior_parameters)
				helpers.assert_eq(provider.get_action(spec.slot), "run_program")
				helpers.assert_eq(controls.publications, 0)
				helpers.assert_eq(controls.token, nil, "no parameter lease was acquired")
				helpers.assert_eq(stopped, 0, "refusal precedes native program retirement")
			end)
		end)
	end
end)


helpers.describe("Linux tap key rows and the physical magic key", function()
	--- Loads the real physical magic key owner over a private preference file.
	local function magic_source(content)
		local file = os.tmpname()
		Sandbox.write_bytes(file, content)
		package.loaded["modules.hotstrings.magic_key_source"] = nil
		local Preferences = helpers.load_module("infra.hotstring_preferences")
		assert(Preferences._set_file_for_test(file))
		return require("modules.hotstrings.magic_key_source"), file
	end

	--- Every rendered row title, depth first.
	local function titles(tree, out)
		out = out or {}
		for _, row in ipairs(tree) do
			if row.title then out[#out + 1] = row.title end
			if row.menu then titles(row.menu, out) end
		end
		return out
	end

	for _, case in ipairs({
		{ source = "Backquote", marked = 1, why = "the key left of 1 is the physical magic key and has an action" },
		{ source = "Minus", marked = 0, why = "Minus has no action, so no row takes the magic key" },
		{ source = "auto", marked = 0, why = "the automatic source owns no tap key" },
	}) do
		helpers.it("(tap-key-magic-override) " .. case.why, function()
			with_case(CASES[3], function(_, gestures, _, controls, path)
				local Source, file = magic_source('[hotstrings]\nmagic_key_source = "' .. case.source .. '"\n')
				local reason = " — " .. require("infra.i18n").get(Source.TAP_OVERRIDE_REASON)
				helpers.assert_true(reason ~= " — " .. Source.TAP_OVERRIDE_REASON, "the reason is translated")
				local selected
				package.loaded["ui.action_picker.bridge"] = { open = function(options, confirm)
					if options.current == "run_program" then selected = confirm end
					return true
				end }
				local rows = menu_rows(gestures, path, { magic_key_source = Source })
				local all, marked = titles(rows), {}
				helpers.assert_true(#all > 20, "actual declared providers must produce a populated menu")
				for _, title in ipairs(all) do
					if title:sub(-#reason) == reason then marked[#marked + 1] = title end
				end
				helpers.assert_eq(#marked, case.marked, table.concat(marked, " | "))
				local picker_label = require("infra.i18n").get("dialog.action_picker.label") .. "…"
				local function open_current(tree)
					for _, row in ipairs(tree) do
						if row.title == picker_label and type(row.fn) == "function" then row.fn() end
						if selected then return end
						if row.menu then open_current(row.menu) end
					end
				end
				open_current(rows)
				helpers.assert_type(selected, "function", "the tap key row opens its picker")
				local before = #controls.logs
				helpers.assert_eq(selected("run_program", nil, NEXT), true)
				local warned = 0
				for index = before + 1, #controls.logs do
					if controls.logs[index]:find("takes the physical magic key", 1, true) then warned = warned + 1 end
				end
				helpers.assert_eq(warned, case.marked, "the assignment is logged exactly when it takes the magic key")
				os.remove(file)
			end)
		end)
	end
end)
