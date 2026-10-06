--- tests/unit/ui/test_native_dialog_titles.lua

--- ==============================================================================
--- MODULE: Native Dialog Caption Ownership
--- DESCRIPTION:
--- Exercises public dialog consumers and the genuine generated title composer.
--- Native argument receipts remain separate from body, keyboard-release, results
--- and cancellation observations. Assertions run after intercepted callbacks.
--- ==============================================================================

local h = require("tests.helpers")
local Shell = require("adapters.shell_runner")

--- Owns module replacements and pipe restoration for one completed scenario.
--- @param body function Receives effect observations and a shell authority.
local function scenario(body)
	local names = { "ui.text_prompt", "ui.app_chooser", "ui.config_dir_picker", "ui.gesture_conflicts",
		"modules.gestures.system_actions", "infra.i18n", "adapters.shell_runner", "ui.modal",
		"adapters.storage", "adapters.event_loop", "adapters.keyboard_hook",
		"ui.menu.programmatic_hotstrings", "infra.hotstring_preferences", "infra.manifest_menu" }
	local saved, observed = {}, { commands = {}, modals = 0, queued = {}, writes = {} }
	for _, name in ipairs(names) do saved[name] = package.loaded[name]; package.loaded[name] = nil end
	local original_popen = io.popen
	local labels = {
		["dialog.config_folder.select_title"] = "Select configuration folder",
		["menu.gestures.conflict_title"] = "Gesture conflicts",
		["dialog.confirm_action.title"] = "Confirm action",
		["common.error_title"] = "Native 'error'",
		["menu.hotstrings.user_code.error"] = "Preserved <programmable failure>",
		["menu.hotstrings.user_code.open_source"] = "Open source",
		["common.close"] = "Keep closed",
	}
	package.loaded["infra.i18n"] = { get = function(key) return labels[key] or key end,
		section = function(key) return labels[key] or key end }
	package.loaded["ui.modal"] = { run = function(fn) observed.modals = observed.modals + 1; return fn() end }
	package.loaded["adapters.storage"] = {
		get = function(_, default) return default end,
		set = function(key, value) observed.writes[#observed.writes + 1] = { key, value }; return true end,
	}
	package.loaded["adapters.event_loop"] = {
		defer = function(fn) observed.queued[#observed.queued + 1] = fn; return true end,
	}
	local shell = {
		quote = Shell.quote,
		has_command = function(binary) return binary == observed.backend end,
		exec_line = function(command) observed.commands[#observed.commands + 1] = command; return observed.answer end,
		exec_checked = function(command)
			observed.commands[#observed.commands + 1] = command
			local accepted = observed.status == 0 or observed.status == true
			return accepted, observed.answer or "", accepted and nil or "command exited with status 1"
		end,
	}
	package.loaded["adapters.shell_runner"] = shell
	io.popen = function(command)
		observed.commands[#observed.commands + 1] = command
		return { read = function() return observed.answer end, close = function() return observed.status end }
	end
	local ok, err = xpcall(function() body(observed, shell) end, debug.traceback)
	io.popen = original_popen
	for _, name in ipairs(names) do package.loaded[name] = saved[name] end
	if not ok then error(err, 0) end
end

h.describe("native dialog captions (linux-native-titles)", function()
	h.it("(linux-native-titles) the text prompt brands chrome while retaining masking, choices and exact value", function()
		scenario(function(observed)
			observed.answer, observed.status = " exact value \n", 0
			local value = require("ui.text_prompt").ask("Native 'caption'", "Preserved <body>", " Initial ", true,
				{ "First choice", "Second 'choice'" })
			h.assert_eq(value, " exact value ")
			h.assert_eq(observed.modals, 1)
			h.assert_eq(observed.commands[1], "zenity --entry --title='ErgoptiPlus — Native '\\''caption'\\'''"
				.. " --text='Preserved <body>' --entry-text=' Initial ' --hide-text 'First choice' 'Second '\\''choice'\\''' 2>/dev/null")
		end)
	end)
	h.it("(linux-native-titles) a cancelled prompt remains nil and an accepted empty answer remains empty", function()
		scenario(function(observed)
			observed.answer, observed.status = "", 1
			local prompt = require("ui.text_prompt")
			h.assert_eq(prompt.ask("Title", "Body", ""), nil)
			observed.status = true
			h.assert_eq(prompt.ask("Title", "Body", ""), "")
			h.assert_eq(observed.modals, 2)
		end)
	end)
	for _, backend in ipairs({ "zenity", "kdialog" }) do
		h.it("(linux-native-titles) the application chooser keeps its backend, filter and id: " .. backend, function()
			scenario(function(observed, shell)
				observed.backend, observed.answer = backend, "/usr/share/applications/org.example.Native.desktop"
				h.assert_eq(require("ui.app_chooser").pick(shell, "Choose application"), "org.example.Native")
				local expected = backend == "zenity"
					and "zenity --file-selection --title='ErgoptiPlus — Choose application' --filename='/usr/share/applications/' --file-filter='*.desktop' 2>/dev/null"
					or "kdialog --getopenfilename '/usr/share/applications/' '*.desktop' --title 'ErgoptiPlus — Choose application' 2>/dev/null"
				h.assert_eq(observed.commands[1], expected)
				h.assert_eq(observed.modals, 1)
			end)
		end)
		h.it("(linux-native-titles) the directory picker keeps its backend and normalized result: " .. backend, function()
			scenario(function(observed, shell)
				observed.backend, observed.answer = backend, "/owned/chosen/"
				local paths = { default_config_dir = function() return "/owned/default" end }
				local value = require("ui.config_dir_picker").pick(shell, paths, require("infra.i18n"), "/owned/current")
				h.assert_eq(value, "/owned/chosen")
				local expected = backend == "zenity"
					and "zenity --file-selection --directory --title='ErgoptiPlus — Select configuration folder' --filename='/owned/current/' 2>/dev/null"
					or "kdialog --getexistingdirectory '/owned/current' --title 'ErgoptiPlus — Select configuration folder' 2>/dev/null"
				h.assert_eq(observed.commands[1], expected)
				h.assert_eq(observed.modals, 1)
			end)
		end)
		h.it("(linux-native-titles) system confirmation preserves safe cancellation and command chaining: " .. backend, function()
			scenario(function(observed)
				observed.backend = backend
				local command = require("modules.gestures.system_actions").confirmed_command("Owned action", "printf owned",
					function(binary) return binary == backend end)
				h.assert_true(command:find("ErgoptiPlus — Confirm action", 1, true) ~= nil)
				h.assert_true(command:find("dialog.confirm_action.message", 1, true) ~= nil)
				h.assert_eq(command:sub(-#" && { printf owned; }"), " && { printf owned; }")
				h.assert_true(command:find(backend == "zenity" and "--default-cancel" or "; [ $? -eq 1 ]; }", 1, true) ~= nil)
			end)
		end)
	end
	h.it("(linux-native-titles) gesture conflict chrome is branded without changing cancellation persistence", function()
		scenario(function(observed)
			local admitted = require("ui.gesture_conflicts").show({ key = "swipe_3", slot = "swipe_3_left" })
			h.assert_eq(admitted, true)
			h.assert_eq(#observed.commands, 0)
			observed.queued[1]()
			h.assert_true(observed.commands[1]:find("--title='ErgoptiPlus — Gesture conflicts'", 1, true) ~= nil)
			h.assert_true(observed.commands[1]:find("--text='gesture.slots.swipe_3_left\ngestures.system.warning'", 1, true) ~= nil)
			h.assert_eq(observed.modals, 1)
			h.assert_eq(#observed.writes, 0, "native cancellation never creates a dismissal receipt")
		end)
	end)
end)


h.describe("native menu dialog captions", function()
	h.it("(linux-native-titles) real Uninstall callbacks brand confirmation and failure without changing body or refusal", function()
		local names = { "ui.menu.menu_builder", "ui.menu.uninstall", "infra.installation", "ui.modal", "ui.menu.llm_backend_rows" }
		local saved = {}
		for _, name in ipairs(names) do saved[name] = package.loaded[name]; package.loaded[name] = nil end
		local original_execute = os.execute
		local commands, accepted, modals, dialogs = {}, nil, 0, nil
		package.loaded["ui.menu.llm_backend_rows"] = { rows = function(_, ports) dialogs = ports; return {} end }
		package.loaded["infra.installation"] = { is_source_run = function() return false end }
		package.loaded["ui.modal"] = { run = function(fn) modals = modals + 1; return fn() end }
		package.loaded["ui.menu.uninstall"] = { run = function(opts)
			accepted = opts.confirm(opts.title, "Preserved <confirmation>")
			opts.fail("Preserved <failure>")
		end }
		os.execute = function(command)
			if command == "command -v zenity >/dev/null 2>&1" then return 0 end
			commands[#commands + 1] = command
			return command:find("zenity --question", 1, true) and 1 or 0
		end
		local ok, err = xpcall(function()
			local i18n = require("infra.i18n")
			local items = require("ui.menu.menu_builder").build({ _version = "9.9.9", on_quit = function() end, llm = { is_enabled = function() return false end } })
			local found
			for _, item in ipairs(items) do
				for _, row in ipairs(item.menu or {}) do
					if row.title == i18n.get("menu.global.uninstall") then found = row.fn or row.action end
				end
			end
			h.assert_type(found, "function", "real rendered Uninstall row must exist")
			found()
			h.assert_eq(accepted, false, "native Cancel remains a refusal")
			h.assert_eq(modals, 2, "both real dialog callbacks release the keyboard")
			local title = Shell.quote("ErgoptiPlus — " .. i18n.get("menu.global.uninstall"))
			h.assert_eq(commands[1], "zenity --question --title=" .. title
				.. " --text='Preserved &lt;confirmation&gt;' --ok-label=" .. Shell.quote(i18n.get("button.remove"))
				.. " --cancel-label=" .. Shell.quote(i18n.get("button.cancel")) .. " 2>/dev/null")
			h.assert_eq(commands[2], "zenity --error --title=" .. title
				.. " --text='Preserved &lt;failure&gt;' 2>/dev/null")
			h.assert_type(dialogs, "table", "real model provider receives its native dialog ports")
			dialogs.info("Native information", "Preserved information body")
			h.assert_eq(commands[3], "zenity --info --title='ErgoptiPlus — Native information'"
				.. " --text='Preserved information body' 2>/dev/null")
			dialogs.error("Preserved untitled failure")
			h.assert_eq(commands[4], "zenity --error --title=" .. Shell.quote("ErgoptiPlus — " .. i18n.get("common.error_title"))
				.. " --text='Preserved untitled failure' 2>/dev/null")
			dialogs.error("Preserved explicit empty caption", "")
			h.assert_eq(commands[5], "zenity --error --title='ErgoptiPlus'"
				.. " --text='Preserved explicit empty caption' 2>/dev/null")
			h.assert_eq(modals, 5)
		end, debug.traceback)
		os.execute = original_execute
		for _, name in ipairs(names) do package.loaded[name] = saved[name] end
		if not ok then error(err, 0) end
	end)
end)


h.describe("programmable source native dialog caption", function()
	local replies = {
		{ name = "affirmative repair", dialog = true, repair = true },
		{ name = "cancelled dialog", dialog = false },
		{ name = "unavailable dialog", dialog = nil },
		{ name = "nonboolean dialog acknowledgement", dialog = "yes" },
		{ name = "repair command refusal", dialog = true, repair = false },
		{ name = "foreign owner during affirmative dialog", dialog = true, foreign = true },
		{ name = "modal handoff refusal", modal_refused = true },
	}
	for _, reply in ipairs(replies) do
		h.it("(linux-native-titles-programmable) actual error callback preserves caption and repair policy: " .. reply.name, function()
			scenario(function(observed, shell)
				local calls = { reload = 0, create = 0, enable = 0, time = 0, path = 0, changed = 0 }
				local native = {
					is_enabled = function() return true end,
					reload_user_code = function() calls.reload = calls.reload + 1; return false end,
					create_user_code_example = function() calls.create = calls.create + 1; return false end,
					set_user_code_enabled = function() calls.enable = calls.enable + 1; return false end,
					set_user_code_time_activation = function() calls.time = calls.time + 1; return false end,
					user_code_source_path = function() calls.path = calls.path + 1; return "/owned/source 'programmable'.lua" end,
				}
				local ctx = { dyn_hotstrings = native, paused = false, is_paused = function() return false end,
					on_menu_changed = function() calls.changed = calls.changed + 1 end }
				package.loaded["infra.hotstring_preferences"] = { get = function(key)
					if key == "hotstrings.dynamic.user_code.enabled" then return false end
					h.assert_eq(key, "hotstrings.dynamic.user_code.time_activation_seconds")
					return 0.5
				end }
				-- Exercise genuine modal delegation with an exact native keyboard
				-- handoff receipt, rather than replacing the dialog consumer itself.
				local released = false
				package.loaded["adapters.keyboard_hook"] = { while_released = function(fn, options)
					observed.modals = observed.modals + 1
					h.assert_nil(options)
					if reply.modal_refused then return false end
					released = true
					local result = fn()
					released = false
					return result
				end }
				package.loaded["ui.modal"] = nil
				shell.run = function(command)
					observed.commands[#observed.commands + 1] = command
					if command:find("zenity --question", 1, true) == 1 then
						h.assert_true(released, "the native dialog owns a released keyboard")
						if reply.foreign then ctx.dyn_hotstrings = {} end
						return reply.dialog
					end
					h.assert_eq(released, false, "repair runs after the modal keyboard receipt returns")
					return reply.repair
				end
				local rows = require("ui.menu.programmatic_hotstrings").build(ctx)
				h.assert_eq(#rows, 4, "the actual manifest renderer must expose all declared source controls")
				h.assert_eq(calls, { reload = 0, create = 0, enable = 0, time = 0, path = 0, changed = 0 },
					"rendering cannot enter any native source loading or factory execution port")
				h.assert_eq(#observed.commands, 0)
				h.assert_eq(observed.modals, 0)
				h.assert_type(rows[3].fn, "function", "the actual declared reload command must be reachable")
				h.assert_eq(rows[3].fn(), false, "native reload refusal remains a refusal even after repair is offered")
				h.assert_eq(calls.reload, 1)
				h.assert_eq(calls.create, 0); h.assert_eq(calls.enable, 0); h.assert_eq(calls.time, 0)
				h.assert_eq(calls.changed, 0, "failed source publication cannot refresh successful state")
				h.assert_eq(observed.modals, 1)
				h.assert_eq(released, false)
				if reply.modal_refused then
					h.assert_eq(observed.commands, {})
				else
					h.assert_eq(observed.commands[1], "zenity --question --title=" .. Shell.quote("ErgoptiPlus — Native 'error'")
						.. " --text='Preserved <programmable failure>' --ok-label='Open source' --cancel-label='Keep closed' 2>/dev/null")
				end
				local opened = reply.dialog == true and not reply.foreign
				h.assert_eq(calls.path, opened and 1 or 0, "only affirmative repair can read the captured owner's source path")
				h.assert_eq(#observed.commands, reply.modal_refused and 0 or (opened and 2 or 1))
				if opened then
					h.assert_eq(observed.commands[2], "xdg-open " .. Shell.quote("/owned/source 'programmable'.lua") .. " >/dev/null 2>&1 &")
				end
			end)
		end)
	end
end)


h.describe("native caption consumer inventory", function()
	h.it("(linux-native-titles) every production CLI caption remains in the independently bounded owner inventory", function()
		local expected = {
			["ui/text_prompt.lua"] = 1,
			["ui/app_chooser.lua"] = 2,
			["ui/config_dir_picker.lua"] = 2,
			["ui/gesture_conflicts.lua"] = 1,
			["modules/gestures/system_actions.lua"] = 2,
			["ui/menu/menu_builder.lua"] = 3,
			-- The seven real programmable error-callback cases above prove its exact
			-- branded question caption, modal handoff and affirmative-only repair.
			["ui/menu/programmatic_hotstrings.lua"] = 1,
			["modules/llm/local_model_offer.lua"] = 2,
			-- The enable refusal tests prove both policy-owned native captions and modal receipts.
			["ui/llm_enable_refusal.lua"] = 2,
		}
		local observed = {}
		local root = h.driver_root()
		-- Match the runner's supported LuaJIT-only profile: find is available even
		-- when the optional LuaFileSystem extension is not installed. The checked
		-- shell owner preserves command failure instead of accepting an empty walk.
		local listed, paths, list_error = Shell.exec_checked("find " .. Shell.quote(root)
			.. " -type d -name tests -prune -o -type f -name '*.lua' -print0")
		h.assert_true(listed, "production caption discovery must succeed: " .. tostring(list_error))
		h.assert_true(#paths > 0, "production caption discovery must find real Lua source")
		h.assert_eq(paths:sub(-1), "\0", "production discovery finishes every exact pathname record")
		for path in paths:gmatch("([^%z]+)%z") do
			h.assert_eq(path:sub(1, #root + 1), root .. "/", "discovered source belongs to the exact driver root")
			local child = path:sub(#root + 2)
			local file = assert(io.open(path, "rb"))
			local source = assert(file:read("*a")); assert(file:close())
			local _, count = source:gsub("%-%-title", "")
			if count > 0 then observed[child] = count end
		end
		h.assert_eq(observed, expected, "new native caption sites require their own behavior and policy evidence")
		local file = assert(io.open(root .. "/uninstall.sh", "rb"))
		local source = assert(file:read("*a")); assert(file:close())
		local _, count = source:gsub("%-%-title", "")
		h.assert_eq(count, 1, "the independent removal worker has exactly one caption supplied by its tested GUI handoff")
	end)
end)
