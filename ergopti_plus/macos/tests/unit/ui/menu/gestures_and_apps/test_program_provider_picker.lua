--- tests/unit/ui/menu/gestures_and_apps/test_program_provider_picker.lua

--- Actual public Hammerspoon picker sessions; native page receipts are controlled.
--- These cases do not claim SDK, uv process-group or physical WebView qualification.
local helpers = require("tests.helpers")
local SCALAR = '{"version":1,"executable":"/private/tool","arguments":["two words",""]}'

local function fixture(body)
	local saved, old_hs = {}, _G.hs
	for key, value in pairs(package.loaded) do saved[key] = value end
	local f = { pages = {}, owners = {}, calls = {}, delete_throws = false }
	local ok, failure = xpcall(function()
		package.loaded.program_provider_picker = nil
		package.loaded["ui.action_picker"] = nil
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["infra.i18n"] = { get = function(key) return key end }
		package.loaded["infra.paths"] = { shared = function() return "/controlled/shared" end }
		package.loaded["adapters.program_providers"] = { create = function()
			local owner = { resolutions = 0, invalidations = 0, retired = false }
			owner.discover = function() return { choices = { { key = "opaque-choice", label = "Reviewed provider" } } } end
			owner.resolve = function(key)
				owner.resolutions = owner.resolutions + 1
				if owner.retired or key ~= "opaque-choice" then return nil end
				return SCALAR
			end
			owner.invalidate = function() owner.invalidations = owner.invalidations + 1; owner.retired = true; return true end
			f.owners[#f.owners + 1] = owner
			return owner
		end }
		_G.hs = { webview = { usercontent = { new = function()
			local content = {}
			function content:setCallback(callback) self.callback = callback end
			f.content = content
			return content
		end } }, json = { encode = function(payload) f.payload = payload; return "{}" end } }
		package.loaded["ui.ui_builder"] = {
			get_app_geometry = function() return { width = 600, height = 500 } end,
			get_centered_frame = function() return {} end,
			show_webview = function(options)
				local page = { options = options, content = options.usercontent, scripts = {}, deletes = 0 }
				function page:evaluateJavaScript(script) self.scripts[#self.scripts + 1] = script end
				function page:delete()
					self.deletes = self.deletes + 1
					options.on_close()
					if f.delete_throws then error("controlled native deletion refusal") end
				end
				f.pages[#f.pages + 1] = page
				return page
			end,
		}
		-- Availability cases consume the actual native predicate, never a copied rule.
		package.loaded["ui.menu.shortcut_utils"] = nil
		package.loaded["adapters.apple_shortcuts_native"] = nil
		package.loaded["platform.remap.lease_helper"] = { resolve = function() return nil end }
		package.loaded["adapters.shell_runner"] = { run_async = function() error("native query forbidden") end }
		package.loaded["infra.dialog_util"] = {
			text_prompt = function(_, _, _, save) return save, f.typed end,
			block_alert = function(_, reason) f.warning = reason end,
		}
		package.loaded["modules.gestures.actions_aux_owner"] = { program_available = function() return true end }
		f.native = require("adapters.apple_shortcuts_native")
		f.utils = require("ui.menu.shortcut_utils")
		f.locale = package.loaded["infra.i18n"]
		f.native_tasks = 0
		_G.hs.task = { new = function() f.native_tasks = f.native_tasks + 1; error("native task forbidden") end }
		f.picker = require("ui.action_picker")
		function f.open(callback)
			return f.picker.open({ items = {} }, callback or function(id, parameter)
				f.calls[#f.calls + 1] = { id, parameter }; return true
			end)
		end
		function f.message(page, body)
			page.content.callback({ body = body })
		end
		function f.confirm(page, key)
			f.message(page, { action = "confirm", id = "run_program", providerKey = key or "opaque-choice", programArguments = {} })
		end
		body(f)
	end, debug.traceback)
	_G.hs = old_hs
	for key in pairs(package.loaded) do if saved[key] == nil then package.loaded[key] = nil end end
	for key, value in pairs(saved) do package.loaded[key] = value end
	package.loaded["adapters.shell_runner"] = saved["adapters.shell_runner"]
	if not ok then error(failure, 0) end
end

helpers.describe("Production macOS program provider picker sessions", function()
	helpers.it("projects only public choices and delivers the resolved scalar through the existing callback", function()
		fixture(function(f)
			helpers.assert_true(f.open())
			f.message(f.pages[1], { action = "ready" })
			helpers.assert_eq(f.payload.programProviders, { choices = { { key = "opaque-choice", label = "Reviewed provider" } } })
			f.confirm(f.pages[1])
			helpers.assert_eq(f.calls, { { "run_program", SCALAR } })
			helpers.assert_true(f.owners[1].retired)
		end)
	end)
	helpers.it("stale old-page choices cannot resolve or confirm a replacement binding", function()
		fixture(function(f)
			helpers.assert_true(f.open())
			local old = f.pages[1]
			helpers.assert_true(f.open())
			f.confirm(old)
			helpers.assert_eq(f.owners[1].resolutions, 0)
			helpers.assert_eq(f.owners[2].resolutions, 0)
			helpers.assert_eq(#f.calls, 0)
			f.confirm(f.pages[2])
			helpers.assert_eq(#f.calls, 1)
		end)
	end)
	helpers.it("resolver-driven replacement cannot publish the previous binding", function()
		fixture(function(f)
			local old, replacement = 0, 0
			helpers.assert_true(f.open(function() old = old + 1; return true end))
			f.owners[1].resolve = function()
				helpers.assert_true(f.open(function() replacement = replacement + 1; return true end))
				return SCALAR
			end
			f.confirm(f.pages[1])
			helpers.assert_eq(old, 0)
			helpers.assert_eq(replacement, 0)
			f.confirm(f.pages[2])
			helpers.assert_eq(replacement, 1)
		end)
	end)
	helpers.it("recursive resolution cannot invoke the durable callback twice", function()
		fixture(function(f)
			helpers.assert_true(f.open())
			local page, resolutions = f.pages[1], 0
			f.owners[1].resolve = function()
				resolutions = resolutions + 1
				if resolutions == 1 then f.confirm(page) end
				return SCALAR
			end
			f.confirm(page)
			helpers.assert_eq(resolutions, 1)
			helpers.assert_eq(#f.calls, 1)
		end)
	end)
	helpers.it("retains the provider after synchronous on-close followed by native delete throw", function()
		fixture(function(f)
			helpers.assert_true(f.open(function() return false end))
			local page, provider = f.pages[1], f.owners[1]
			f.delete_throws = true
			helpers.assert_eq(f.picker.close(), false)
			helpers.assert_eq(provider.invalidations, 0, "ambiguous public native close cannot revoke discovery")
			helpers.assert_eq(f.open(), false)
			helpers.assert_eq(#f.owners, 1)
			f.confirm(page)
			helpers.assert_eq(provider.resolutions, 1, "same captured provider remains retryable")
			f.delete_throws = false
			helpers.assert_true(f.picker.close())
			helpers.assert_eq(provider.invalidations, 1)
		end)
	end)
	helpers.it("a genuine public user-close invalidates choices without affecting its successor", function()
		fixture(function(f)
			helpers.assert_true(f.open())
			local old = f.pages[1]
			old.options.on_close()
			helpers.assert_true(f.owners[1].retired)
			helpers.assert_true(f.open())
			old.options.on_close()
			f.confirm(old)
			helpers.assert_eq(f.owners[2].invalidations, 0)
			helpers.assert_eq(#f.calls, 0)
			f.confirm(f.pages[2])
			helpers.assert_eq(#f.calls, 1)
		end)
	end)
	for _, invalid in ipairs({ true, 0, "", "foreign-choice" }) do
		helpers.it("refuses malformed or foreign opaque choices: " .. tostring(invalid), function()
			fixture(function(f)
				helpers.assert_true(f.open())
				local page = f.pages[1]
				f.message(page, { action = "confirm", id = "run_program", providerKey = invalid })
				helpers.assert_eq(#f.calls, 0)
				helpers.assert_eq(page.deletes, 0)
				helpers.assert_eq(page.scripts[#page.scripts], "programProviderRefused()")
			end)
		end)
	end
	helpers.it("refused persistence keeps the same discovery retryable and manual fallback available", function()
		fixture(function(f)
			local calls = 0
			helpers.assert_true(f.open(function(_, parameter)
				calls = calls + 1
				helpers.assert_eq(parameter, SCALAR)
				return calls > 1
			end))
			f.confirm(f.pages[1])
			helpers.assert_eq(f.owners[1].invalidations, 0)
			f.message(f.pages[1], { action = "confirm", id = "run_program", parameter = SCALAR })
			helpers.assert_eq(calls, 2)
			helpers.assert_true(f.owners[1].retired)
		end)
	end)
end)

local function automation(f)
	local owners = {}
	package.loaded["adapters.apple_shortcuts_native"] = { create = function()
		local owner = { invalidations = 0, retirement = true }
		owner.discover = function(callback) owner.callback = callback; return true end
		owner.invalidate = function() owner.invalidations = owner.invalidations + 1; return owner.retirement end
		owners[#owners + 1] = owner
		return owner
	end }
	package.loaded["adapters.apple_shortcuts_native"].is_chosen_program = f.native.is_chosen_program
	return owners
end

helpers.describe("Production readonly automation picker sessions", function()
	helpers.it("publishes a closed pending inventory independently of ordinary providers", function()
		fixture(function(f)
			local owners = automation(f)
			helpers.assert_true(f.open())
			f.message(f.pages[1], { action = "ready" })
			helpers.assert_eq(f.payload.automationProviders, { title = "Apple Shortcuts", choices = {}, truncated = false })
			helpers.assert_eq(f.payload.programProviderStrings.unavailableBinding, "platform_reason.program_runner_unavailable")
			owners[1].callback({ choices = { { key = "7:1", label = "日本 e\204\129\n<name>", provider = "apple_shortcuts" } }, truncated = true })
			f.message(f.pages[1], { action = "ready" })
			helpers.assert_eq(f.payload.automationProviders, { title = "Apple Shortcuts", choices = {
				{ key = "automation:7:1", label = "日本 e\204\129\n<name>", provider = "apple_shortcuts", available = false },
			}, truncated = true })
			helpers.assert_eq(f.payload.programProviders, { choices = { { key = "opaque-choice", label = "Reviewed provider" } } })
			helpers.assert_true(f.pages[1].scripts[#f.pages[1].scripts - 1]:find("updateAutomationProviders", 1, true) ~= nil)
			f.confirm(f.pages[1], "automation:7:1")
			helpers.assert_eq(#f.calls, 0)
			helpers.assert_eq(f.owners[1].resolutions, 0)
			f.confirm(f.pages[1])
			helpers.assert_eq(f.calls, { { "run_program", SCALAR } })
			helpers.assert_eq(owners[1].invalidations, 1)
		end)
	end)
	helpers.it("suppresses a retired native callback after window replacement", function()
		fixture(function(f)
			local owners = automation(f)
			helpers.assert_true(f.open())
			helpers.assert_true(f.open())
			local old_scripts, new_scripts = #f.pages[1].scripts, #f.pages[2].scripts
			owners[1].callback({ choices = { { key = "1:1", label = "retired", provider = "apple_shortcuts" } }, truncated = false })
			helpers.assert_eq(#f.pages[1].scripts, old_scripts)
			helpers.assert_eq(#f.pages[2].scripts, new_scripts)
			f.message(f.pages[2], { action = "ready" })
			helpers.assert_eq(f.payload.automationProviders.choices, {})
		end)
	end)
	helpers.it("retains native query debt without constructing a replacement query owner", function()
		fixture(function(f)
			local owners = automation(f)
			helpers.assert_true(f.open())
			owners[1].retirement = false
			helpers.assert_true(f.picker.close(), "window closure need not imply query retirement")
			helpers.assert_true(f.open(), "a manual picker remains usable")
			helpers.assert_eq(#owners, 1, "native query debt fences successor acquisition")
			f.message(f.pages[2], { action = "ready" })
			helpers.assert_eq(f.payload.programProviders, { unavailable = true })
			helpers.assert_eq(f.payload.automationProviders.choices, {})
			owners[1].retirement = true
			helpers.assert_true(f.open())
			helpers.assert_eq(#owners, 2)
		end)
	end)
end)

local RESERVED = '{"version":1,"executable":"/usr/bin/shortcuts","arguments":["run","11111111-1111-1111-1111-111111111111"]}'
local UNAVAILABLE = "platform_reason.program_runner_unavailable"

helpers.describe("Actual macOS reserved program assignment availability", function()
	helpers.it("manual reserved refusal keeps the editor retryable for an ordinary repair", function()
		fixture(function(f)
			_G.hs.json.encode = require("json").encode
			helpers.assert_true(f.open())
			local page = f.pages[1]
			f.message(page, { action = "confirm", id = "run_program", parameter = RESERVED })
			helpers.assert_eq(#f.calls, 0)
			helpers.assert_eq(page.deletes, 0)
			helpers.assert_eq(page.scripts[#page.scripts], 'programProviderRefused("' .. UNAVAILABLE .. '")')
			helpers.assert_eq(f.owners[1].invalidations, 0)
			f.message(page, { action = "confirm", id = "run_program", parameter = SCALAR })
			helpers.assert_eq(f.calls, { { "run_program", SCALAR } })
			helpers.assert_eq(page.deletes, 1)
			helpers.assert_eq(f.native_tasks, 0)
		end)
	end)
	helpers.it("resolved reserved descriptors obey the same host refusal", function()
		fixture(function(f)
			_G.hs.json.encode = require("json").encode
			helpers.assert_true(f.open())
			f.owners[1].resolve = function() return RESERVED end
			f.confirm(f.pages[1])
			helpers.assert_eq(#f.calls, 0)
			helpers.assert_eq(f.pages[1].deletes, 0)
			helpers.assert_eq(f.pages[1].scripts[#f.pages[1].scripts], 'programProviderRefused("' .. UNAVAILABLE .. '")')
			helpers.assert_eq(f.native_tasks, 0)
		end)
	end)
	for _, case in ipairs({
		{ "ordinary executable", "/private/tool", { "run" }, false },
		{ "different shortcut path", "/private/shortcuts", { "run" }, false },
		{ "other native subcommand", "/usr/bin/shortcuts", { "list" }, false },
		{ "case-sensitive subcommand", "/usr/bin/shortcuts", { "Run" }, false },
		{ "empty native arguments", "/usr/bin/shortcuts", {}, false },
		{ "chosen native UUID", "/usr/bin/shortcuts", { "run", "11111111-1111-1111-1111-111111111111" }, true },
		{ "native name parameter", "/usr/bin/shortcuts", { "run", "Workflow" }, true },
		{ "missing native direct parameter", "/usr/bin/shortcuts", { "run" }, true },
	}) do
		helpers.it("actual native predicate presentation: " .. case[1], function()
			fixture(function(f)
				local Json = require("json")
				local scalar = Json.encode({ version = 1, executable = case[2], arguments = Json.array(case[3]) })
				helpers.assert_eq(f.native.is_chosen_program(case[2], case[3]), case[4])
				helpers.assert_eq(f.utils.program_assignment_reason(scalar), case[4] and UNAVAILABLE or nil)
				helpers.assert_eq(f.native_tasks, 0)
			end)
		end)
	end
	helpers.it("malformed syntax stays with the existing parameter owner", function()
		fixture(function(f)
			helpers.assert_eq(require("program_parameter").parse("not JSON", "hs"), nil)
			helpers.assert_eq(f.utils.program_assignment_reason("not JSON"), nil)
			helpers.assert_eq(f.native_tasks, 0)
		end)
	end)
	for _, mode in ipairs({ "missing", "throw", "nil", "table" }) do
		helpers.it("unavailable native classifier refuses without disabling ordinary repair: " .. mode, function()
			fixture(function(f)
				local original = f.native.is_chosen_program
				_G.hs.json.encode = require("json").encode
				helpers.assert_true(f.open())
				if mode == "missing" then f.native.is_chosen_program = nil
				else f.native.is_chosen_program = function()
					if mode == "throw" then error("controlled classifier refusal") end
					if mode == "table" then return {} end
					return nil
				end end
				f.message(f.pages[1], { action = "confirm", id = "run_program", parameter = SCALAR })
				helpers.assert_eq(#f.calls, 0)
				helpers.assert_eq(f.pages[1].deletes, 0)
				f.native.is_chosen_program = original
				f.message(f.pages[1], { action = "confirm", id = "run_program", parameter = SCALAR })
				helpers.assert_eq(f.calls, { { "run_program", SCALAR } })
				helpers.assert_eq(f.native_tasks, 0)
			end)
		end)
	end
	helpers.it("failed reason observation clears settling before the next confirmation", function()
		fixture(function(f)
			helpers.assert_true(f.open())
			local original = f.locale.get
			f.locale.get = function(key) if key == UNAVAILABLE then error("controlled translation refusal") end; return key end
			f.message(f.pages[1], { action = "confirm", id = "run_program", parameter = RESERVED })
			helpers.assert_eq(#f.calls, 0)
			f.locale.get = original
			f.message(f.pages[1], { action = "confirm", id = "run_program", parameter = SCALAR })
			helpers.assert_eq(f.calls, { { "run_program", SCALAR } })
		end)
	end)
	helpers.it("classifier replacement cannot confirm or warn the retired page", function()
		fixture(function(f)
			helpers.assert_true(f.open())
			local old, original = f.pages[1], f.native.is_chosen_program
			local old_scripts = #old.scripts
			f.native.is_chosen_program = function(executable, arguments)
				helpers.assert_true(f.open())
				return original(executable, arguments)
			end
			f.message(old, { action = "confirm", id = "run_program", parameter = RESERVED })
			helpers.assert_eq(#f.calls, 0)
			helpers.assert_eq(#old.scripts, old_scripts)
			f.native.is_chosen_program = original
			f.message(f.pages[2], { action = "confirm", id = "run_program", parameter = SCALAR })
			helpers.assert_eq(f.calls, { { "run_program", SCALAR } })
		end)
	end)
	helpers.it("reason encoding replacement cannot warn the retired page", function()
		fixture(function(f)
			helpers.assert_true(f.open())
			local old, Json = f.pages[1], require("json")
			local old_scripts = #old.scripts
			local original = Json.quote
			local ok, err = xpcall(function()
				Json.quote = function(value)
					if value == UNAVAILABLE then helpers.assert_true(f.open()) end
					return original(value)
				end
				f.message(old, { action = "confirm", id = "run_program", parameter = RESERVED })
				helpers.assert_eq(#f.calls, 0)
				helpers.assert_eq(#old.scripts, old_scripts)
				f.message(f.pages[2], { action = "confirm", id = "run_program", parameter = SCALAR })
				helpers.assert_eq(f.calls, { { "run_program", SCALAR } })
			end, debug.traceback)
			Json.quote = original
			if not ok then error(err, 0) end
		end)
	end)
	helpers.it("native prompt refuses a reserved value and still accepts an ordinary replacement", function()
		fixture(function(f)
			local gestures = { parameter_prompt = function() return "Program" end }
			f.typed = RESERVED
			helpers.assert_eq(f.utils.ask_parameter_value(gestures, "run_program", "program", "T", RESERVED), nil)
			helpers.assert_eq(f.warning, UNAVAILABLE)
			f.typed = SCALAR
			helpers.assert_eq(f.utils.ask_parameter_value(gestures, "run_program", "program", "T", RESERVED), SCALAR)
			helpers.assert_eq(f.native_tasks, 0)
		end)
	end)
	helpers.it("public commit refuses before any writer and permits an ordinary replacement", function()
		fixture(function(f)
			local calls = 0
			local function transaction(_, _, scalar) calls = calls + 1; helpers.assert_eq(scalar, SCALAR); return true end
			helpers.assert_eq(f.utils.commit_action_parameter({}, "keyboard__cmd_1", "run_program", RESERVED, {}, transaction), false)
			helpers.assert_eq(calls, 0)
			helpers.assert_eq(f.warning, UNAVAILABLE)
			helpers.assert_true(f.utils.commit_action_parameter({}, "keyboard__cmd_1", "run_program", SCALAR, {}, transaction))
			helpers.assert_eq(calls, 1)
			helpers.assert_eq(f.native_tasks, 0)
		end)
	end)
	helpers.it("stored reserved bytes remain editable and ordinary stored values have no refusal hint", function()
		fixture(function(f)
			local scalar = RESERVED
			local gestures = {
				get_action_parameter_spec = function() return "program" end,
				get_action_parameter = function() return scalar end,
				parameter_prompt = function() return "Program" end, parameter_error = function() return "Invalid" end,
				send_vocabulary = function() return {} end, llm_prompt_choices = function() return {} end,
				llm_prompt_default_count = function() return 1 end, llm_vision_choices = function() return {} end,
				llm_language_choices = function() return {} end, program_admission_available = function() return true end,
				program_binding_supported = function() return true end,
			}
			local items = { { type = "action", id = "run_program" } }
			f.utils.picker_parameter_fields(gestures, items, "keyboard__cmd_1")
			helpers.assert_eq(items[1].parameterValue, RESERVED)
			helpers.assert_eq(items[1].hint, UNAVAILABLE)
			helpers.assert_eq(items[1].disabled, nil)
			scalar = SCALAR
			local repaired = { { type = "action", id = "run_program" } }
			f.utils.picker_parameter_fields(gestures, repaired, "keyboard__cmd_1")
			helpers.assert_eq(repaired[1].hint, nil)
			helpers.assert_eq(repaired[1].parameterValue, SCALAR)
			helpers.assert_eq(f.native_tasks, 0)
		end)
	end)
	helpers.it("physical fallback nil cannot produce a parameterized entry draft", function()
		fixture(function(f)
			f.typed = RESERVED
			local scalar = f.utils.ask_parameter_value({ parameter_prompt = function() return "Program" end }, "run_program", "program", "T", RESERVED)
			local planner = require("shortcuts.physical_entries").new({ parse = function() return true end, owns = function() return true end }, {
				is_assignable = function() return true end, get_action_parameter_spec = function() return "program" end,
				validate_action_parameter = function(_, value) return require("program_parameter").parse(value, "hs") ~= nil end,
				split_action_parameter_key = function() return nil end,
			}, { parameter_section = "gestures.action_parameters" })
			local rows, reason = planner.plan({ operation = "add", slot = "position", action = "run_program", parameter = scalar }, { assignments = {}, parameters = {} })
			helpers.assert_eq(rows, nil)
			helpers.assert_eq(reason, "invalid_parameter")
			helpers.assert_eq(f.native_tasks, 0)
		end)
	end)
end)


helpers.describe("action picker scalar native JSON boundary", function()
	helpers.it("(hs-scalar-json-picker) actual unavailable reason reaches the retained picker with native table-only JSON", function()
		fixture(function(f)
			local Json = require("json")
			local reason = 'Unavailable é漢😀\r\n\t"\\");globalThis.__injected=true;//'
			f.locale.get = function(key) return key == UNAVAILABLE and reason or key end
			local native_tables = 0
			-- This is a native-contract double, not the actual Hammerspoon encoder.
			_G.hs.json.encode = function(value)
				helpers.assert_eq(type(value), "table", "Hammerspoon 1.1.1 JSON requires a table")
				native_tables = native_tables + 1
				return Json.encode(value)
			end
			helpers.assert_true(f.open())
			local page = f.pages[1]
			local initial_scripts, initial_native_tables = #page.scripts, native_tables
			f.message(page, { action = "confirm", id = "run_program", parameter = RESERVED })
			helpers.assert_eq(#page.scripts, initial_scripts + 1, "an unavailable native action must explain its refusal")
			local quoted = assert(page.scripts[#page.scripts]:match('^programProviderRefused%((.*)%)$'))
			helpers.assert_eq(Json.decode(quoted), reason)
			helpers.assert_eq(quoted:find("[%z\1-\31]"), nil)
			helpers.assert_eq(native_tables, initial_native_tables)
			helpers.assert_eq(#f.calls, 0)
			helpers.assert_eq(page.deletes, 0)
			f.message(page, { action = "confirm", id = "run_program", parameter = SCALAR })
			helpers.assert_eq(f.calls, { { "run_program", SCALAR } }, "ordinary repair remains available")
		end)
	end)
	for _, mode in ipairs({ "nil", "false", "throw" }) do
		helpers.it("(hs-scalar-json-picker) unavailable reason quotation " .. mode .. " cannot confirm", function()
			fixture(function(f)
				local Json = require("json")
				local original = Json.quote
				local ok, err = xpcall(function()
					helpers.assert_true(f.open())
					local initial_scripts = #f.pages[1].scripts
					Json.quote = function(value)
						if value ~= UNAVAILABLE then return original(value) end
						if mode == "throw" then error("PRIVATE_REFUSAL_REASON") end
						if mode == "false" then return false end
					end
					f.message(f.pages[1], { action = "confirm", id = "run_program", parameter = RESERVED })
					helpers.assert_eq(#f.pages[1].scripts, initial_scripts)
					helpers.assert_eq(#f.calls, 0)
					helpers.assert_eq(f.pages[1].deletes, 0)
				end, debug.traceback)
				Json.quote = original
				if not ok then error(err, 0) end
			end)
		end)
	end
	helpers.it("(hs-scalar-json-picker) reason encoding reentry cannot target a replacement picker", function()
		fixture(function(f)
			local Json = require("json")
			local original = Json.quote
			local ok, err = xpcall(function()
				helpers.assert_true(f.open())
				local old = f.pages[1]
				local initial_scripts = #old.scripts
				Json.quote = function(value)
					if value == UNAVAILABLE then helpers.assert_true(f.open()) end
					return original(value)
				end
				f.message(old, { action = "confirm", id = "run_program", parameter = RESERVED })
				helpers.assert_eq(#f.pages, 2)
				helpers.assert_eq(#old.scripts, initial_scripts)
				helpers.assert_true(#f.pages[2].scripts > 0, "the replacement retains its own startup scripts")
				for _, code in ipairs(f.pages[2].scripts) do
					helpers.assert_nil(code:find("programProviderRefused", 1, true))
				end
				helpers.assert_eq(#f.calls, 0)
			end, debug.traceback)
			Json.quote = original
			if not ok then error(err, 0) end
		end)
	end)
end)

helpers.it("(hs-scalar-json-picker) invalid UTF-8 reason neither dispatches nor confirms", function()
	fixture(function(f)
		f.locale.get = function(key) return key == UNAVAILABLE and ("PRIVATE" .. string.char(0xC0, 0xAF)) or key end
		helpers.assert_true(f.open())
		local page = f.pages[1]
		local initial_scripts = #page.scripts
		local errors = {}
		package.loaded["infra.logger"].error = function(_, template, ...)
			errors[#errors + 1] = string.format(template, ...)
		end
		f.message(page, { action = "confirm", id = "run_program", parameter = RESERVED })
		helpers.assert_eq(#page.scripts, initial_scripts)
		helpers.assert_eq(#f.calls, 0)
		helpers.assert_eq(page.deletes, 0)
		helpers.assert_eq(#errors, 1)
		helpers.assert_nil(errors[1]:find("PRIVATE", 1, true))
	end)
end)
