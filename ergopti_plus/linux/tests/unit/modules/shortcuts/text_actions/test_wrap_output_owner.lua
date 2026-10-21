--- tests/unit/modules/shortcuts/text_actions/test_wrap_output_owner.lua

--- ==============================================================================
--- MODULE: Wrap Output Retains Its Original Selection Owner
--- DESCRIPTION:
--- Executes Main's actual wrap construction with the real wrap controller,
--- shortcut manager, focus guard, injector and clipboard. Desktop commands and
--- evdev writes are controlled ports; this module makes no native GTK claim.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fixture = require("tests.support.text_owner_fixture")

--- Loads Main's actual wrap callback and its publication wiring.
--- @param environment table
--- @return table controller
local function main_wrap(environment)
	local file = assert(io.open(helpers.driver_root() .. "/ergopti_hotstrings.lua", "rb"))
	local source = assert(file:read("*a")); assert(file:close())
	local first = assert(source:find('local wrap_on_type = require("modules.shortcuts.wrap_on_type").new({', 1, true))
	local last = assert(source:find("\n\t-- The script-management chords", first, true))
	local body = source:sub(first, last - 1) .. "\nreturn wrap_on_type"
	local chunk
	if loadstring then chunk = assert(loadstring(body)); setfenv(chunk, environment)
	else chunk = assert(load(body, "actual Main wrap output", "t", environment)) end
	return chunk()
end

--- Runs a genuine wrap over recording native boundaries.
--- @param options table
--- @param body function
local function with_wrap(options, body)
	-- Manager's lazy writer/i18n path can construct Storage. Bind its genuine
	-- shell/logger dependencies before this model installs recording doubles.
	require("adapters.storage")
	require("toml_codec.writer")
	require("config_file_inverse")
	Fixture.with(function(guard, focus, _, _, watch)
		local names = { "adapters.clipboard", "adapters.shell_runner", "infra.display_server", "adapters.keyboard_layout",
			"modules.hotstrings.injector", "adapters.keyboard_hook", "modules.shortcuts.manager", "modules.shortcuts.wrap_on_type", "logger.shim" }
		local saved = {}
		for _, name in ipairs(names) do saved[name] = package.loaded[name] end
		local state = { primary = "baseline", clipboard = "SAVED", wire = {}, writes = {}, stops = 0, resets = 0,
			reads = 0, errors = 0, documents = { ["/field/original"] = "selected", ["/field/successor"] = "SAFE" } }
		local logger = assert(dofile(require("infra.paths").shared("lua/logger/init.lua")))
		logger.set_level("trace"); logger.set_sink(function() end)
		logger.set_error_observer(function() state.errors = state.errors + 1 end)
		package.loaded["logger.shim"] = logger
		local injector, controller, shortcuts
		local function transition(point)
			if state.moved or options.boundary ~= point then return end
			state.moved = true
			if options.change == "focus" then
				focus.path = "/field/successor"
				if point == "ctrl-down" then guard.invalidate() end
			elseif options.change == "password" then
				focus.role = 40; guard.invalidate()
			elseif options.change == "pause" then
				state.paused = true; controller.end_selection_window()
			elseif options.change == "pause-aba" then
				state.paused = true; controller.end_selection_window(); state.paused = false
			elseif options.change == "configuration-aba" then
				assert(shortcuts.set_wrap_on_type_enabled(false)); assert(shortcuts.set_wrap_on_type_enabled(true))
			elseif options.change == "successor" then
				controller.on_pointer_down()
			else error("unknown controlled transition") end
		end
		local commands = {}
		package.loaded["adapters.shell_runner"] = {
			has_command = function() return true end,
			exec_checked = function(command)
				if command:find("primary", 1, true) then state.reads = state.reads + 1; return true, state.primary end
				transition("clipboard-read"); return true, state.clipboard
			end,
			with_exact_stdin = function(_, text)
				local command = "wrap-write-" .. tostring(#commands + 1)
				commands[#commands + 1] = { command = command, text = text }; return command
			end,
			run = function(command)
				for _, item in ipairs(commands) do
					if command == item.command then
						if item.text == "SAVED" and options.restore_failure then
							if options.restore_failure == "throw" then error("controlled restore exception") end
							return false
						end
						state.clipboard = item.text; state.writes[#state.writes + 1] = item.text
						if item.text ~= "SAVED" then transition("clipboard-write") end
						return true
					end
				end
				return false
			end,
		}
		package.loaded["infra.display_server"] = { is_wayland = function() return false end,
			is_x11 = function() return true end, kind = function() return "x11" end }
		package.loaded["adapters.keyboard_hook"] = { held_text_modifier_codes = function() return {} end,
			held_shortcut_modifier_codes = function() return {} end, held_forwarded_keys = function() return {} end,
			emergency_stop = function() state.stops = state.stops + 1 end }
		local ok, err = pcall(function()
			shortcuts = helpers.load_module("modules.shortcuts.manager")
			shortcuts.init({ enabled = true, persist = false }); assert(shortcuts.set_wrap_on_type_enabled(true))
			local layout = helpers.load_module("adapters.keyboard_layout")
			layout._set_table_for_test({}) -- This wrap must use the real clipboard path.
			local key_v = layout.shortcut_keycode
			layout.shortcut_keycode = function(...) transition("paste-lookup"); return key_v(...) end
			helpers.load_module("adapters.clipboard")
			helpers.load_module("modules.shortcuts.wrap_on_type")
			injector = helpers.load_module("modules.hotstrings.injector")
			injector._set_uinput({ is_open = function() return true end, emit = function(code, value)
				state.wire[#state.wire + 1] = code .. ":" .. value
				if code == 29 and value == 1 then transition("ctrl-down") end
				if (options.native_failure == true and code == 47 and value == 1)
					or (options.native_failure == "ctrl-down" and code == 29 and value == 1) then return false end
				if code == 47 and value == 1 then state.documents[focus.path] = state.clipboard end
				return true
			end })
			injector._set_nanosleep_for_test(function(seconds)
				if seconds == .03 then transition("clipboard-settle") end
			end)
			local wrapped = setmetatable({ inject = function(...)
				if options.throw_inject then error("controlled type_text exception") end
				local _, _, _, _, publication = ...
				state.publication = publication
				if options.audit_cached and publication then
					local cached = publication.cached
					publication.cached = function()
						local before = focus.barriers
						local accepted = cached()
						helpers.assert_eq(focus.barriers, before, "per-DOWN admission must not query native focus")
						state.cached_calls = (state.cached_calls or 0) + 1
						return accepted
					end
				end
				state.result = injector.inject(...); return state.result
			end }, { __index = injector })
			local environment = setmetatable({ opts = { dry_run = false }, shortcuts = shortcuts,
				script_actions = { is_paused = function() return state.paused == true end },
				secure_focus_guard = guard, input_capture_gate = { blocks_text = function() return false end },
				privacy_owners = {}, injector = wrapped,
				engine = { reset = function() state.resets = state.resets + 1 end },
			}, { __index = _G })
			controller = main_wrap(environment)
			controller.on_pointer_down()
			state.primary = "selected"
			state.consumed = controller.on_key({ char = "‘", code = 10, mods = {} })
			state.controller, state.shortcuts, state.guard, state.watch = controller, shortcuts, guard, watch
			body(state)
		end)
		if injector then injector._set_uinput(nil); injector._set_nanosleep_for_test(nil) end
		for _, name in ipairs(names) do package.loaded[name] = saved[name] end
		if not ok then error(err, 0) end
	end)
end

helpers.describe("wrap output publication ownership", function()
	helpers.it("commits a stable Unicode wrap through the actual Main and clipboard", function()
		with_wrap({}, function(state)
			helpers.assert_eq(state.consumed, true)
			helpers.assert_eq(state.result.ok, true)
			helpers.assert_eq(state.documents["/field/original"], "‘selected’")
			helpers.assert_eq(state.documents["/field/successor"], "SAFE")
			helpers.assert_eq(state.clipboard, "SAVED")
			helpers.assert_eq(state.resets, 1)
			helpers.assert_eq(state.stops, 0)
			helpers.assert_eq(state.reads, 2, "PRIMARY retains its original baseline and changed-selection checks")
		end)
	end)

	helpers.it("keeps per-DOWN publication checks in RAM", function()
		with_wrap({ audit_cached = true }, function(state)
			helpers.assert_eq(state.consumed, true)
			helpers.assert_true((state.cached_calls or 0) > 0, "the actual injector must exercise cached admission")
			helpers.assert_eq(state.result.ok, true)
			helpers.assert_eq(state.stops, 0)
		end)
	end)

	for _, change in ipairs({ "focus", "password", "pause", "pause-aba", "configuration-aba" }) do
		for _, boundary in ipairs({ "clipboard-read", "clipboard-write", "clipboard-settle", "paste-lookup", "ctrl-down" }) do
			helpers.it("refuses " .. change .. " during " .. boundary .. " without borrowing the new field (wrap-output-owner)", function()
				with_wrap({ change = change, boundary = boundary }, function(state)
					helpers.assert_eq(state.moved, true, "the native boundary must actually execute")
					helpers.assert_eq(state.documents["/field/successor"], "SAFE", "old selection text must not reach the successor")
					helpers.assert_eq(state.documents["/field/original"], "selected", "retired wrap must not edit the original selection")
					helpers.assert_eq(state.consumed, false)
					helpers.assert_eq(state.result.ok, false)
					helpers.assert_eq(state.result.cleanup_ok, true)
					helpers.assert_eq(state.clipboard, "SAVED")
					helpers.assert_eq(state.stops, 0, "healthy cancellation must not stop the keyboard")
					helpers.assert_eq(state.errors, 0, "healthy retirement must not request an error popup")
					helpers.assert_eq(state.resets, 0, "refused output cannot publish a logical edit")
					if boundary == "ctrl-down" then
						helpers.assert_eq(table.concat(state.wire, ","), "29:1,29:0", "owned Ctrl must be released after revocation")
					end
				end)
			end)
		end
	end

	helpers.it("preserves a successor selection opened during clipboard I/O", function()
		with_wrap({ change = "successor", boundary = "clipboard-read" }, function(state)
			helpers.assert_eq(state.moved, true)
			helpers.assert_eq(state.consumed, false)
			helpers.assert_eq(state.result.ok, false)
			helpers.assert_eq(state.controller.selection_window_open(), true)
			helpers.assert_eq(state.documents["/field/original"], "selected")
			helpers.assert_eq(state.clipboard, "SAVED")
		end)
	end)

	for _, failure in ipairs({ "false", "throw" }) do
		helpers.it("keeps clipboard restoration " .. failure .. " observable and fatal", function()
			with_wrap({ restore_failure = failure }, function(state)
				helpers.assert_eq(state.consumed, false)
				helpers.assert_eq(state.result.ok, false)
				helpers.assert_eq(state.stops, 1)
				helpers.assert_true(state.errors > 0, "restoration failures must retain the real error observer")
				helpers.assert_eq(state.clipboard, "‘selected’", "a refused restoration cannot be reported as complete")
			end)
		end)
	end

	helpers.it("keeps an exception from Main type_text observable as an error", function()
		with_wrap({ throw_inject = true }, function(state)
			helpers.assert_eq(state.consumed, false)
			helpers.assert_eq(state.result, nil)
			helpers.assert_true(state.errors > 0, "an exception must not become a normal boolean refusal")
			helpers.assert_eq(state.clipboard, "SAVED")
			helpers.assert_eq(state.wire, {})
		end)
	end)

	helpers.it("keeps a simultaneous Ctrl DOWN refusal and destination revocation fatal", function()
		with_wrap({ native_failure = "ctrl-down", change = "focus", boundary = "ctrl-down" }, function(state)
			helpers.assert_eq(state.moved, true)
			helpers.assert_eq(state.consumed, false)
			helpers.assert_eq(state.result.ok, false)
			helpers.assert_eq(state.stops, 1)
			helpers.assert_true(state.errors > 0, "native failures must retain their real error observer")
			helpers.assert_eq(state.documents["/field/successor"], "SAFE")
			helpers.assert_eq(state.clipboard, "SAVED")
		end)
	end)

	helpers.it("keeps a real native paste failure fatal and restores the clipboard", function()
		with_wrap({ native_failure = true }, function(state)
			helpers.assert_eq(state.consumed, false)
			helpers.assert_eq(state.result.ok, false)
			helpers.assert_eq(state.result.cleanup_ok, true)
			helpers.assert_eq(state.stops, 1)
			helpers.assert_true(state.errors > 0, "native failures must retain their real error observer")
			helpers.assert_eq(state.clipboard, "SAVED")
		end)
	end)
end)

if os.getenv("ERGOPTI_WRAP_STORAGE_CHILD") ~= "1" then
	helpers.describe("wrap fixture constructor isolation", function()
		helpers.it("keeps a cold real store writable after the actual wrap scenarios", function()
			local uv, Shell = require("luv"), require("adapters.shell_runner")
			local directory = assert(uv.fs_mkdtemp(uv.os_tmpdir() .. "/ergopti-wrap-storage-XXXXXX"))
			local okay, detail = pcall(function()
				for _, name in ipairs({ "config", "data", "cache" }) do assert(uv.fs_mkdir(directory .. "/" .. name, 448)) end
				local script_path = directory .. "/child.lua"
				local script = assert(io.open(script_path, "wb"))
				assert(script:write("package.path = " .. string.format("%q", package.path) .. "\n"
					.. "package.cpath = " .. string.format("%q", package.cpath) .. "\n"
					.. "require('compat.utf8').install()\n"
					.. "assert(package.loaded['adapters.storage'] == nil, 'the child store must start cold')\n"
					.. "require('tests.unit.modules.shortcuts.text_actions.test_wrap_output_owner')\n"
					.. "local results = require('tests.helpers').get_results()\n"
					.. "assert(results.passed == 33 and results.failed == 0, 'all actual wrap scenarios must pass')\n"
					.. "local storage = require('adapters.storage')\n"
					.. "assert(storage.path() == os.getenv('XDG_CONFIG_HOME') .. '/ergopti_plus/storage.json', 'the store must remain private')\n"
					.. "assert(storage.set('wrap_fixture_sentinel', 'kept') == true, 'the real store must acknowledge publication')\n"
					.. "local file = assert(io.open(storage.path(), 'rb'))\n"
					.. "local bytes = assert(file:read('*a')); assert(file:close())\n"
					.. "assert(require('json').decode(bytes).wrap_fixture_sentinel == 'kept')\n"
					.. "print('COLD_WRAP_STORE_JSON_COMMITTED')\n"))
				assert(script:close())
				-- Checked capture retains the child's real status on LuaJIT too.
				local command = "env -u XDG_STATE_HOME ERGOPTI_WRAP_STORAGE_CHILD=1"
					.. " XDG_CONFIG_HOME=" .. Shell.quote(directory .. "/config")
					.. " XDG_DATA_HOME=" .. Shell.quote(directory .. "/data")
					.. " XDG_CACHE_HOME=" .. Shell.quote(directory .. "/cache")
					.. " timeout --signal=TERM --kill-after=2s 20s " .. Shell.quote(assert(uv.exepath()))
					.. " " .. Shell.quote(script_path) .. " 2>&1"
				local success, output = Shell.exec_checked(command)
				helpers.assert_eq(success, true, "the cold child must exit zero: " .. tostring(output))
				helpers.assert_true(output:find("COLD_WRAP_STORE_JSON_COMMITTED", 1, true) ~= nil,
					"the real JSON publication must finish after all actual wrap scenarios")
			end)
			assert(Shell.run("rm -rf -- " .. Shell.quote(directory)))
			if not okay then error(detail, 0) end
		end)
	end)
end
