--- tests/unit/ui/menu/test_program_picker_providers.lua

--- Drives actual menu providers and helpers with independent persistence receipts.
local helpers = require("tests.helpers")
local ProgramParameter = require("program_parameter")
local SCALAR = '{"version":1,"executable":"/private/tool","arguments":["two words",""]}'

local function with_provider(kind, options, body)
	local saved = {}
	for name, value in pairs(package.loaded) do saved[name] = value end
	local fixture = { action = options.foreign_native or "none", canonical_action = "none", parameters = { retained = "unrelated" },
		canonical_parameters = { retained = "unrelated" }, saves = 0, updates = 0, sets = 0, errors = 0 }
	local function copy(source)
		local result = {}
		for key, value in pairs(source) do result[key] = value end
		return result
	end
	local function receipt(mode)
		if mode == "throw" then error("synthetic refusal") end
		if mode == "nil" then return nil end
		return mode ~= "false"
	end
	local publish_assignment
	local function set_action(_, value)
		fixture.sets = fixture.sets + 1
		fixture.action = value
		if value == "run_program" then
			local committed = receipt(options.assign)
			if committed ~= true then return committed end
		end
		if kind ~= "script" then
			if publish_assignment(value) ~= true then return false end
			fixture.canonical_action = value
		end
		return true
	end
	local gestures = {
		is_assignable = function() return true end,
		program_binding_supported = function() return true end,
		program_admission_available = function()
			if options.readiness == "throw" then error(SCALAR) end
			if options.readiness == "nil" then return nil end
			return options.readiness ~= "false"
		end,
		get_sg_names = function() return { "none", "run_program" } end,
		get_action_label = function(value) return value end,
		get_action_parameter_spec = function(action) return action == "run_program" and "program" or nil end,
		get_action_parameter = function(binding, action) return fixture.parameters[binding .. "__" .. action] or "" end,
		get_all_action_parameters = function() return copy(fixture.parameters) end,
		replace_action_parameters = function(snapshot) fixture.parameters = copy(snapshot); return true end,
		set_action_parameter = function(binding, action, value)
			fixture.parameters[binding .. "__" .. action] = value
			return receipt(options.parameter)
		end,
		validate_action_parameter = function(_, value) return ProgramParameter.parse(value, "hs") ~= nil end,
		parameter_prompt = function() return "Program" end,
		parameter_error = function() return "Invalid program" end,
		send_vocabulary = function() return {} end,
		llm_prompt_choices = function() return {} end,
		llm_prompt_default_count = function() return 1 end,
		llm_vision_choices = function() return {} end,
		llm_language_choices = function() return {} end,
	}
	local binding = kind == "keyboard" and "keyboard__cmd_1" or kind == "tap" and "tap_key__number_row_left" or "script__script_altgr_enter"
	local picker_callback, rows, state
	local ok, failure = xpcall(function()
		package.loaded["infra.i18n"] = { get = function(key) return key end,
			section = function(key) return key end, decorate_section = function(key) return key end }
		local logger = helpers.make_logger_stub()
		logger.error = function(_, message, ...) fixture.errors = fixture.errors + 1; fixture.last_error = string.format(message, ...); if message:find("did not commit", 1, true) then fixture.transaction_error = string.format(message, ...) end end
		package.loaded["infra.logger"] = logger
		package.loaded["infra.dialog_util"] = { text_prompt = function(_, _, _, confirm, cancel)
			return options.cancel and cancel or confirm, SCALAR
		end }
		package.loaded["infra.deferred_work"] = { after = function(_, callback) callback(); return true end }
		package.loaded["ui.action_picker"] = { open = function(settings, callback)
			helpers.assert_eq(settings.items[1].id, "run_program")
			helpers.assert_eq(settings.items[1].disabled, options.unavailable and true or nil, "program selection must follow registration readiness")
			if options.unavailable then helpers.assert_eq(settings.items[1].hint, "platform_reason.program_runner_unavailable") end
			picker_callback = callback
		end }
		package.loaded["modules.gestures.actions_aux_owner"] = { program_available = function() return true end }
		package.loaded["modules.shortcuts.input_source_conflict"] = { check = function(_, _, callback) callback({}); return true end }
		package.loaded["adapters.shell_runner"] = {}
		package.loaded["adapters.input_source_broker"] = { subscribe = function() return true end }
		package.loaded["modules.shortcuts.bindings"] = { reconcile_tap_keys = function()
			if fixture.action == "run_program" then return receipt(options.reconcile) end
			return true
		end }
		package.loaded["modules.shortcuts.tap_keys"] = {
			ensure_loaded = function() end, keys = function() return { { id = "number_row_left" } } end,
			get_action = function() return fixture.action end, set_action = set_action,
			binding_id = function(id) return "tap_key__" .. id end, display_name = function() return "1" end,
		}
		package.loaded["modules.shortcuts"] = {
			DEFAULT_STATE = { shortcuts = true },
			get_keyboard_slot_groups = function() return { { prefix = "cmd_", fixed = true } } end,
			assigned_keyboard_slots = function() return { { id = "cmd_1", action = fixture.action } } end,
			get_keyboard_action = function() return fixture.action end, set_keyboard_action = set_action,
			keyboard_binding_id = function(id) return "keyboard__" .. id end,
			get_keyboard_slot_label = function(id) return id end,
			get_keyboard_slot_chord = function() return { "cmd" }, "1" end,
		}
		for _, name in ipairs({ "ui.menu.shortcut_utils", "ui.menu.menu_keyboard_slots", "ui.menu.menu_tap_keys", "ui.menu.menu_shortcuts" }) do package.loaded[name] = nil end
		state = { shortcuts = true, script_control_shortcuts = { script_altgr_enter = "none" } }
		local ctx = { gestures = gestures, state = state, shortcuts = {},
			save_prefs = function()
				fixture.saves = fixture.saves + 1
				local committed = receipt(options.save)
				if committed == true then
					fixture.canonical_parameters = copy(fixture.parameters)
					fixture.canonical_action = fixture.action
				end
				return committed
			end,
			updateMenu = function() fixture.updates = fixture.updates + 1 end,
		}
		local owner
		owner, publish_assignment = require("tests.support.program_parameter_fixture")(gestures, state, kind,
			function() return fixture.action end, ctx.save_prefs)
		ctx.commit_program_parameter = owner.apply
		if kind == "keyboard" then
			rows = require("ui.menu.menu_keyboard_slots").provide_rows(ctx)
			rows[1].items[1].action()
		elseif kind == "tap" then
			rows = require("ui.menu.menu_tap_keys").provide_rows(ctx)
			rows[1].action()
		else
			package.loaded["modules.shortcuts.actions.text"] = { WRAP_GROUPS = {} }
			package.loaded["ui.menu.menu_utils"] = {}
			package.loaded["infra.manifest_reader"] = {}
			package.loaded["infra.manifest_menu"] = { group_receiver = require("tests.support.declared_menu_parent_fixture").new().group_receiver, build = function(id, _, _, groups, _, providers)
				if id == "shortcuts_menu" then return groups.script_control() end
				rows = providers.script_control_shortcuts()
				return rows
			end }
			ctx.script_control = { ACTIONS = { "run_program" }, SCRIPT_BINDING_PREFIX = "script__",
				script_chord_slots = function() return { { id = "script_altgr_enter" } } end,
				set_shortcut_action = set_action,
				get_shortcut_actions = function() return { script_altgr_enter = fixture.action } end,
			}
			require("ui.menu.menu_shortcuts").build(ctx)
			rows[1].items[1].action()
		end
		body(fixture, function()
			if kind ~= "script" then
				helpers.assert_type(picker_callback, "function")
				if options.cancel then return picker_callback("run_program") end
				picker_callback("run_program", SCALAR)
			end
		end, state)
	end, debug.traceback)
	package.loaded["adapters.shell_runner"] = saved["adapters.shell_runner"]
	for name in pairs(package.loaded) do if saved[name] == nil then package.loaded[name] = nil end end
	for name, value in pairs(saved) do package.loaded[name] = value end
	if not ok then error(failure, 0) end
end

for _, kind in ipairs({ "keyboard", "tap", "script" }) do
	local binding = kind == "keyboard" and "keyboard__cmd_1" or kind == "tap" and "tap_key__number_row_left" or "script__script_altgr_enter"
	helpers.describe("program transaction through actual " .. kind .. " provider", function()
		for _, stage in ipairs({ "parameter", "assign", "save" }) do
			for _, mode in ipairs({ "false", "nil", "throw" }) do
				helpers.it("restores both owners after " .. stage .. " " .. mode, function()
					with_provider(kind, { [stage] = mode }, function(fixture, pick, state)
						pick()
						helpers.assert_eq(fixture.action, "none")
						helpers.assert_eq(fixture.canonical_action, "none")
						helpers.assert_eq(fixture.parameters, { retained = "unrelated" })
						helpers.assert_eq(fixture.canonical_parameters, { retained = "unrelated" })
						helpers.assert_eq(fixture.updates, 0)
						helpers.assert_true(fixture.errors > 0, "refusal must be diagnosed")
						if kind == "script" then helpers.assert_eq(state.script_control_shortcuts.script_altgr_enter, "none") end
					end)
				end)
			end
		end
		helpers.it("preserves both owners when the parameter prompt is cancelled", function()
			with_provider(kind, { cancel = true }, function(fixture, pick)
				pick()
				helpers.assert_eq(fixture.action, "none")
				helpers.assert_eq(fixture.canonical_action, "none")
				helpers.assert_eq(fixture.parameters, { retained = "unrelated" })
				helpers.assert_eq(fixture.canonical_parameters, { retained = "unrelated" })
				helpers.assert_eq(fixture.sets, 0)
				helpers.assert_eq(fixture.saves, 0)
				helpers.assert_eq(fixture.updates, 0)
			end)
		end)
		helpers.it("publishes parameter and assignment together", function()
			with_provider(kind, {}, function(fixture, pick)
				pick()
				helpers.assert_eq(fixture.action, "run_program", fixture.transaction_error or fixture.last_error)
				helpers.assert_eq(fixture.canonical_action, "run_program")
				helpers.assert_eq(fixture.canonical_parameters, { retained = "unrelated", [binding .. "__run_program"] = SCALAR })
				helpers.assert_eq(fixture.saves, 1)
				helpers.assert_eq(fixture.updates, 1)
			end)
		end)
	end)
end

helpers.describe("program tap reconciliation transaction", function()
	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("restores both owners after native reconciliation " .. mode, function()
			with_provider("tap", { reconcile = mode }, function(fixture, pick)
				pick()
				helpers.assert_eq(fixture.action, "none")
				helpers.assert_eq(fixture.canonical_action, "none")
				helpers.assert_eq(fixture.parameters, { retained = "unrelated" })
				helpers.assert_eq(fixture.saves, 0)
				helpers.assert_eq(fixture.updates, 0)
			end)
		end)
	end
end)

helpers.describe("actual program picker admission readiness", function()
	for _, mode in ipairs({ "false", "nil", "throw" }) do
		helpers.it("discloses unavailable ownership after a " .. mode .. " readiness receipt", function()
			with_provider("keyboard", { readiness = mode, unavailable = true }, function(fixture)
				helpers.assert_eq(fixture.sets, 0)
				helpers.assert_eq(fixture.saves, 0)
			end)
		end)
	end
end)

helpers.describe("script program native assignment ownership", function()
	helpers.it("preserves a native slot that disagrees with its menu state", function()
		with_provider("script", { foreign_native = "copy" }, function(fixture, _, state)
			helpers.assert_eq(fixture.action, "copy")
			helpers.assert_eq(state.script_control_shortcuts.script_altgr_enter, "none")
			helpers.assert_eq(fixture.parameters, { retained = "unrelated" })
			helpers.assert_eq(fixture.sets, 0)
			helpers.assert_eq(fixture.saves, 0)
			helpers.assert_eq(fixture.updates, 0)
		end)
	end)
end)

helpers.describe("program fixture final publication admission", function()
	for _, mode in ipairs({ "false", "nil", "table", "throw" }) do
		helpers.it("keeps the exact source after final admission " .. mode, function()
			with_provider("script", {}, function()
				local port = package.loaded["adapters.file_system"]
				local before, status = port.read_with_status("config")
				local called = 0
				local result = port.write_if_unchanged_admitted("config", "candidate", { status = status, content = before }, nil,
					function()
						called = called + 1
						if mode == "throw" then error("private admission refusal") end
						if mode == "table" then return {} end
						if mode == "nil" then return nil end
						return false
					end)
				helpers.assert_eq(result, false)
				helpers.assert_eq(called, 1)
				helpers.assert_eq(port.read_with_status("config"), before)
			end)
		end)
	end
	helpers.it("refuses a genuine external write even when the caller mutates its expected source", function()
		with_provider("script", {}, function()
			local port = package.loaded["adapters.file_system"]
			local before, status = port.read_with_status("config")
			local expected, external_ack = { status = status, content = before }, nil
			local result = port.write_if_unchanged_admitted("config", "candidate", expected, nil, function()
				external_ack = port.write_if_unchanged("config", "external-successor", expected)
				expected.content = "external-successor"
				return true
			end)
			helpers.assert_eq(external_ack, true)
			helpers.assert_eq(result, false)
			helpers.assert_eq(port.read_with_status("config"), "external-successor")
		end)
	end)
end)
