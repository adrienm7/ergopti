--- tests/unit/core/ui/webview/test_native_dialog_titles.lua

--- ==============================================================================
--- MODULE: Native Dialog Caption Ownership
--- DESCRIPTION:
--- Exercises public dialog consumers and the genuine generated title composer.
--- Native argument receipts remain separate from body, keyboard-release, results
--- and cancellation observations. Assertions run after intercepted callbacks.
--- ==============================================================================

local h = require("tests.helpers")
local Shell = require("core.process.adapters.shell_runner")
-- The owned dialog host's command words every native site starts with.
local DIALOG = require("core.ui.ui.native_dialog").command()

--- Owns module replacements and pipe restoration for one completed scenario.
--- @param body function Receives effect observations and a shell authority.
local function scenario(body)
	local names = { "core.ui.ui.text_prompt", "apps.ui.chooser", "settings.ui.dir_picker", "gestures.ui.conflicts",
		"gestures.engine.system_actions", "core.i18n.engine.i18n", "core.process.adapters.shell_runner", "core.ui.ui.modal",
		"core.fs.adapters.storage", "core.events.loop", "platform.input.keyboard_hook",
		"hotstrings.ui.menu.programmatic_hotstrings", "hotstrings.engine.matcher.preferences", "menu.engine.manifest_menu" }
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
	package.loaded["core.i18n.engine.i18n"] = { get = function(key) return labels[key] or key end,
		section = function(key) return labels[key] or key end }
	package.loaded["core.ui.ui.modal"] = { run = function(fn) observed.modals = observed.modals + 1; return fn() end }
	package.loaded["core.fs.adapters.storage"] = {
		get = function(_, default) return default end,
		set = function(key, value) observed.writes[#observed.writes + 1] = { key, value }; return true end,
	}
	package.loaded["core.events.loop"] = {
		defer = function(fn) observed.queued[#observed.queued + 1] = fn; return true end,
	}
	local shell = {
		quote = Shell.quote,
		has_command = function(binary) return binary == observed.backend end,
		exec_line = function(command) observed.commands[#observed.commands + 1] = command; return observed.answer end,
		exec_checked = function(command)
			observed.commands[#observed.commands + 1] = command
			local accepted = observed.status == 0 or observed.status == true
			return accepted, observed.answer or "", accepted and nil or "command exited with status 1", accepted and nil or require("diagnostics.engine.adapter_errors").COMMAND_EXITED_NONZERO, accepted and nil or 1
		end,
	}
	package.loaded["core.process.adapters.shell_runner"] = shell
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
	h.it("(linux-native-titles) the choice prompt brands its caption and hides the value column", function()
		package.loaded["core.ui.ui.choice_prompt"] = nil
		local ok, command = pcall(function()
			return require("core.ui.ui.choice_prompt").command("Vision provider", "Pick one",
				{ { value = "--question", label = "--title=OpenAI" } })
		end)
		package.loaded["core.ui.ui.choice_prompt"] = nil
		h.assert_true(ok, tostring(command))
		h.assert_eq(command, DIALOG .. " --list --no-markup --hide-header --title='ErgoptiPlus — Vision provider'"
			.. " --text='Pick one' --column='' --column='' --hide-column=1 --print-column=1 -- '--question' '--title=OpenAI' 2>/dev/null")
	end)
	h.it("(linux-native-titles) the text prompt brands chrome while retaining masking, choices and exact value", function()
		scenario(function(observed)
			observed.answer, observed.status = " exact value \n", 0
			local value = require("core.ui.ui.text_prompt").ask("Native 'caption'", "Preserved <body>", " Initial ", true,
				{ "--hide-text", "Second 'choice'" })
			h.assert_eq(value, " exact value ")
			h.assert_eq(observed.modals, 1)
			h.assert_eq(observed.commands[1], DIALOG .. " --entry --title='ErgoptiPlus — Native '\\''caption'\\'''"
				.. " --text='Preserved <body>' --entry-text=' Initial ' --hide-text -- '--hide-text' 'Second '\\''choice'\\''' 2>/dev/null")
		end)
	end)
	h.it("(linux-native-titles) a cancelled prompt remains nil and an accepted empty answer remains empty", function()
		scenario(function(observed)
			observed.answer, observed.status = "", 1
			local prompt = require("core.ui.ui.text_prompt")
			h.assert_eq(prompt.ask("Title", "Body", ""), nil)
			observed.status = true
			h.assert_eq(prompt.ask("Title", "Body", ""), "")
			h.assert_eq(observed.modals, 2)
		end)
	end)
	h.it("(linux-native-titles) the application chooser keeps its filter and id", function()
		scenario(function(observed, shell)
			observed.answer, observed.status = "/usr/share/applications/org.example.Native.desktop", 0
			h.assert_eq(require("apps.ui.chooser").pick(shell, "Choose application", { resolve = function()
				return observed.answer, "found"
			end }), "org.example.Native")
			h.assert_eq(observed.commands[1], DIALOG .. " --file-selection --title='ErgoptiPlus — Choose application'"
				.. " --filename='/usr/share/applications/' --file-filter='*.desktop' 2>/dev/null")
			h.assert_eq(observed.modals, 1)
		end)
	end)
	h.it("(linux-native-titles) the directory picker keeps its normalized result", function()
		scenario(function(observed, shell)
			observed.answer, observed.status = "/owned/chosen/", 0
			local paths = { default_config_dir = function() return "/owned/default" end }
			local value = require("settings.ui.dir_picker").pick(shell, paths, require("core.i18n.engine.i18n"), "/owned/current")
			h.assert_eq(value, "/owned/chosen")
			h.assert_eq(observed.commands[1], DIALOG .. " --file-selection --directory"
				.. " --title='ErgoptiPlus — Select configuration folder' --filename='/owned/current/' 2>/dev/null")
			h.assert_eq(observed.modals, 1)
		end)
	end)
	h.it("(linux-native-titles) system confirmation preserves safe cancellation and command chaining", function()
		scenario(function()
			local command = require("gestures.engine.system_actions").confirmed_command("Owned action", "printf owned")
			h.assert_eq(command:sub(1, #DIALOG + 1), DIALOG .. " ", "the owned dialog asks, never a host tool")
			h.assert_true(command:find("ErgoptiPlus — Confirm action", 1, true) ~= nil)
			h.assert_true(command:find("dialog.confirm_action.message", 1, true) ~= nil)
			h.assert_eq(command:sub(-#" && { printf owned; }"), " && { printf owned; }")
			h.assert_true(command:find("--default-cancel", 1, true) ~= nil)
		end)
	end)
	h.it("(linux-native-titles) gesture conflict chrome is branded without changing cancellation persistence", function()
		scenario(function(observed)
			local admitted = require("gestures.ui.conflicts").show({ key = "swipe_3", slot = "swipe_3_left" })
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
	h.it("(linux-model-delete-owner) refuses deletion if the page closes during confirmation", function()
		local names = { "menu.ui.builder.builder", "ai.ui.menu.llm", "ai.ui.menu.backend_rows", "core.ui.ui.modal" }
		local saved = {}
		for _, name in ipairs(names) do saved[name] = package.loaded[name]; package.loaded[name] = nil end
		local previous_execute, options, deletions, live, paused = os.execute, nil, 0, true, false
		package.loaded["ai.ui.menu.backend_rows"] = {
			bind_page = function(_, bound) options = bound end,
			caption = function() return "model" end,
		}
		package.loaded["core.ui.ui.modal"] = { run = function(fn) return fn() end }
		os.execute = function() live = false; return 0 end
		local ok, err = xpcall(function()
			require("menu.ui.builder.builder").build({ _version = "9.9.9", paused = false,
				is_paused = function() return paused end, on_quit = function() end,
				llm = { is_enabled = function() return false end,
					delete_model = function() deletions = deletions + 1; return true end } })
			h.assert_type(options, "table")
			h.assert_eq(options.delete_model("model:1", function() return live end), false)
			h.assert_eq(deletions, 0)
			live = true
			os.execute = function() paused = true; return 0 end
			h.assert_eq(options.delete_model("model:1", function() return live end), false)
			h.assert_eq(deletions, 0)
		end, debug.traceback)
		os.execute = previous_execute
		for _, name in ipairs(names) do package.loaded[name] = saved[name] end
		if not ok then error(err, 0) end
	end)

	h.it("(linux-native-titles) real Uninstall callbacks brand confirmation and failure without changing body or refusal", function()
		-- The prompt captures its Shell owner; load it under this scenario's authority.
		local names = { "menu.ui.builder.builder", "menu.ui.transactions.uninstall", "core.lifecycle.engine.installation", "core.ui.ui.modal", "ai.ui.menu.backend_rows",
			"core.ui.ui.text_prompt" }
		local saved = {}
		for _, name in ipairs(names) do saved[name] = package.loaded[name]; package.loaded[name] = nil end
		local original_execute, original_checked = os.execute, Shell.exec_checked
		local logger = require("core.logger.engine.shim")
		local original_error, original_info = logger.error, logger.info
		local commands, accepted, modals, dialogs = {}, nil, 0, nil
		package.loaded["ai.ui.menu.backend_rows"] = {
			bind_page = function(_, options) dialogs = options.dialogs end,
			caption = function() return "model button" end,
		}
		package.loaded["core.lifecycle.engine.installation"] = { is_source_run = function() return false end }
		package.loaded["core.ui.ui.modal"] = { run = function(fn) modals = modals + 1; return fn() end }
		package.loaded["menu.ui.transactions.uninstall"] = { run = function(opts)
			accepted = opts.confirm(opts.title, "Preserved <confirmation>")
			opts.fail("Preserved <failure>")
		end }
		os.execute = function(command)
			commands[#commands + 1] = command
			return command:find("dialog_host.lua' --question", 1, true) and 256 or 0
		end
		local ok, err = xpcall(function()
			local i18n = require("core.i18n.engine.i18n")
			local items = require("menu.ui.builder.builder").build({ _version = "9.9.9", on_quit = function() end, llm = { is_enabled = function() return false end } })
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
			h.assert_eq(commands[1], DIALOG .. " --question --title=" .. title
				.. " --text='Preserved &lt;confirmation&gt;' --ok-label=" .. Shell.quote(i18n.get("button.remove"))
				.. " --cancel-label=" .. Shell.quote(i18n.get("button.cancel")) .. " 2>/dev/null")
			h.assert_eq(commands[2], DIALOG .. " --error --title=" .. title
				.. " --text='Preserved &lt;failure&gt;' 2>/dev/null")
			h.assert_type(dialogs, "table", "the model selector page receives the native dialog ports")
			dialogs.info("Native information", "Preserved information body")
			h.assert_eq(commands[3], DIALOG .. " --info --title='ErgoptiPlus — Native information'"
				.. " --text='Preserved information body' 2>/dev/null")
			dialogs.error("Preserved untitled failure")
			h.assert_eq(commands[4], DIALOG .. " --error --title=" .. Shell.quote("ErgoptiPlus — " .. i18n.get("common.error_title"))
				.. " --text='Preserved untitled failure' 2>/dev/null")
			dialogs.error("Preserved explicit empty caption", "")
			h.assert_eq(commands[5], DIALOG .. " --error --title='ErgoptiPlus'"
				.. " --text='Preserved explicit empty caption' 2>/dev/null")
			h.assert_eq(modals, 5)
			dialogs.error("Invalid URL <host>&value")
			h.assert_true(commands[6]:find("Invalid URL &lt;host&gt;&amp;value", 1, true) ~= nil)
			dialogs.info("Information", "Model <name>&value")
			h.assert_true(commands[7]:find("Model &lt;name&gt;&amp;value", 1, true) ~= nil)
			Shell.exec_checked = function(command) commands[#commands + 1] = command; return true, "" end
			dialogs.prompt("Prompt", "Provider <name>&value", "")
			h.assert_true(commands[8]:find("Provider &lt;name&gt;&amp;value", 1, true) ~= nil)
			local logs = {}
			logger.error = function(_, fmt, ...) logs[#logs + 1] = string.format(fmt, ...) end
			logger.info = function(_, fmt, ...) logs[#logs + 1] = string.format(fmt, ...) end
			os.execute = function() return 1 end
			dialogs.error("URL https://user:synthetic-secret@example.invalid")
			dialogs.info("Result", "synthetic-private-response")
			h.assert_eq(#logs, 2)
			h.assert_true(not logs[1]:find("synthetic-secret", 1, true))
			h.assert_true(not logs[2]:find("synthetic-private-response", 1, true))
		end, debug.traceback)
		os.execute, Shell.exec_checked = original_execute, original_checked
		logger.error, logger.info = original_error, original_info
		for _, name in ipairs(names) do package.loaded[name] = saved[name] end
		if not ok then error(err, 0) end
	end)
end)


h.describe("programmable source problems open no dialog", function()
	-- A refused source action used to open a native question offering to open
	-- the source. The row now names the problem instead: a refusal redraws the
	-- menu and runs no native dialog, whatever the problem.
	for _, problem in ipairs({ false, "missing", "failed" }) do
		h.it("(linux-native-titles-programmable) a refused reload opens no dialog and redraws the row, problem "
			.. tostring(problem), function()
			scenario(function(observed, shell)
				local calls = { reload = 0, create = 0, path = 0, changed = 0 }
				local native = {
					is_enabled = function() return true end,
					reload_user_code = function() calls.reload = calls.reload + 1; return false end,
					create_user_code_example = function() calls.create = calls.create + 1; return false end,
					user_code_source_path = function() calls.path = calls.path + 1; return "/owned/source 'programmable'.lua" end,
					user_code_problem = function() return problem or nil end,
				}
				local ctx = { dyn_hotstrings = native, paused = false, is_paused = function() return false end,
					on_menu_changed = function() calls.changed = calls.changed + 1 end }
				package.loaded["hotstrings.engine.matcher.preferences"] = { get = function(key)
					if key == "hotstrings.dynamic.user_code.enabled" then return true end
					h.assert_eq(key, "hotstrings.dynamic.user_code.time_activation_seconds")
					return 0.5
				end }
				package.loaded["platform.input.keyboard_hook"] = { while_released = function()
					error("a source problem never releases the keyboard for a dialog")
				end }
				shell.run = function(command)
					observed.commands[#observed.commands + 1] = command
					return false
				end
				local rows = require("hotstrings.ui.menu.programmatic_hotstrings").build(ctx)
				h.assert_eq(#rows, 4, "the actual manifest renderer must expose all declared source controls")
				local title = rows[1].title
				if problem then
					h.assert_eq(title, "menu.hotstrings.user_code.title — menu.hotstrings.user_code.problem_" .. problem)
				else
					h.assert_eq(title, "menu.hotstrings.user_code.title")
				end
				h.assert_eq(rows[2].disabled == true, problem == "missing", "only a missing source has nothing to open")
				h.assert_eq(rows[3].fn(), false, "native reload refusal remains a refusal")
				h.assert_eq(rows[4].fn(), false, "a refused example creation enables nothing")
				h.assert_eq(calls.reload, 1); h.assert_eq(calls.create, 1)
				h.assert_eq(calls.changed, 2, "each refusal redraws the menu so the row shows the state")
				h.assert_eq(calls.path, 0, "nothing offers or opens the source")
				h.assert_eq(observed.modals, 0, "no native modal opens")
				h.assert_eq(observed.commands, {}, "no native question or editor command runs")
			end)
		end)
	end
end)


h.describe("one-click check report caption (linux-native-titles)", function()
	h.it("(linux-native-titles) the check report brands its caption and keeps the body plain text", function()
		scenario(function(observed)
			observed.status = 1
			local runner = require("diagnostics.ui.field_check.window").new({
				label = "Owned check", log = "owned_check", check_id = "owned", title_key = "Native 'check'",
				steps = function(_, _, finish) finish() end, env = function() return {} end,
				unusable_step = "owned_env",
			})
			h.assert_true(runner.run())
			h.assert_eq(#observed.queued, 1, "the report opens from a fresh event-loop turn")
			observed.queued[1]()
			h.assert_eq(observed.modals, 1)
			h.assert_eq(#observed.commands, 1)
			local command = observed.commands[1]
			local head = DIALOG .. " --question --no-markup --title='ErgoptiPlus — Native '\\''check'\\''' --text="
			h.assert_eq(command:sub(1, #head), head)
			local tail = " --ok-label='field_check.copy' --cancel-label='field_check.close'"
			h.assert_eq(command:sub(-#tail), tail, "Close answers the dialog without a copy")
		end)
	end)
end)


h.describe("native caption consumer inventory", function()
	h.it("(linux-native-titles) every production CLI caption remains in the independently bounded owner inventory", function()
		local expected = {
			["core.ui.ui.text_prompt"] = 1,
			-- The picker, its verification error and the open_path picker retain
			-- their composed caption; test_app_chooser proves the error dialog.
			["apps.ui.chooser"] = 3,
			["settings.ui.dir_picker"] = 1,
			["gestures.ui.conflicts"] = 1,
			["gestures.engine.system_actions"] = 1,
			["menu.ui.builder.dialogs"] = 3,
			["ai.engine.ollama.local_model_offer"] = 1,
			-- The enable refusal tests prove the policy-owned native caption and modal receipts.
			["ai.ui.enable_refusal"] = 1,
			-- The one-click check runner owns the caption of every check report.
			["diagnostics.ui.field_check.window"] = 1,
			-- The list prompt's caption is proven by the choice prompt case.
			["core.ui.ui.choice_prompt"] = 1,
			-- The bundled apps' entry, question, message and file dialogs compose
			-- their caption; test_bundled_apps_launcher proves each one.
			["apps.dialogs"] = 4,
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
			-- Keyed by module name, as the code requires it, not by path.
			local child = path:sub(#root + 2):gsub("%.lua$", ""):gsub("/", ".")
			local file = assert(io.open(path, "rb"))
			local source = assert(file:read("*a")); assert(file:close())
			local _, count = source:gsub("%-%-title", "")
			if count > 0 then observed[child] = count end
		end
		h.assert_eq(observed, expected, "new native caption sites require their own behavior and policy evidence")
		local file = assert(io.open(root .. "/uninstall.sh", "rb"))
		local source = assert(file:read("*a")); assert(file:close())
		local _, count = source:gsub("%-%-title", "")
		-- One caption, GUI_TITLE from the tested GUI handoff, shown by the owned dialog
		-- host (tools/test/test-linux-uninstall-sandbox.cjs proves it).
		h.assert_eq(count, 1, "the independent removal worker shows its one handed-off caption through the owned dialog")
	end)
end)

--- Receives an original picker through a private executable's real exit status.
--- @param status number Independent child exit code.
--- @param output string Independent child stdout.
--- @param application_root string|nil Real XDG data root for the application chooser.
--- @return string receipt
local function picker_exit_receipt(status, output, application_root)
	local created, directory = Shell.exec_checked("mktemp -d")
	assert(created)
	directory = directory:gsub("[\r\n]+$", "")
	local executable, worker = directory .. "/dialog", directory .. "/worker.lua"
	local function write(path, content)
		local file = assert(io.open(path, "wb"))
		assert(file:write(content)); assert(file:close())
	end
	local ok, receipt = xpcall(function()
		write(executable, "#!/bin/sh\nprintf '%s' " .. Shell.quote(output) .. "\nexit " .. status .. "\n")
		assert(Shell.run("chmod u+x " .. Shell.quote(executable)))
		write(worker, "package.path = " .. string.format("%q", package.path) .. "\n"
			.. "local shell = require('core.process.adapters.shell_runner')\n"
			-- The private executable stands in for the owned dialog host.
			.. "package.loaded['core.ui.ui.native_dialog'] = { command = function() return shell.quote(" .. string.format("%q", executable) .. ") end }\n"
			.. "local modals = 0\n"
			.. "package.loaded['core.ui.ui.modal'] = { run = function(fn) modals = modals + 1; return fn() end }\n"
			.. "local paths = { default_config_dir = function() return '/owned/default' end }\n"
			.. (application_root and "local value = require('apps.ui.chooser').pick(shell, 'Choose application', {resolve=function() return "
				.. string.format("%q", output:gsub("\n$", "")) .. ", 'found' end})\n"
				or "local value = require('settings.ui.dir_picker').pick(shell, paths, nil, '/owned/current')\n")
			.. "io.write(value == nil and 'refused' or 'accepted|' .. value)\n"
			.. "io.write('|modal:' .. modals)\n")
		local command = "env PATH=" .. Shell.quote(directory .. ":" .. (os.getenv("PATH") or ""))
			.. (application_root and " XDG_DATA_HOME=" .. Shell.quote(application_root) or "")
			.. " " .. Shell.quote(arg[-1] or "luajit") .. " " .. Shell.quote(worker)
		local executed, result, reason = Shell.exec_checked(command)
		assert(executed, tostring(reason))
		return result
	end, debug.traceback)
	os.remove(executable); os.remove(worker)
	local removed = Shell.run("rmdir " .. Shell.quote(directory))
	assert(removed, "private picker fixture must retire")
	assert(ok, receipt)
	return receipt
end

h.describe("native configuration picker exit receipts", function()
	do local backend = "owned dialog"
		h.it("linux-config-picker-exit: " .. backend .. " accepts successful normalized selection", function()
			h.assert_eq(picker_exit_receipt(0, "/owned/chosen/\n"), "accepted|/owned/chosen|modal:1")
		end)
		for _, case in ipairs({
			{ "spaces", "/  configuration  " },
			{ "carriage return", "/configuration\r" },
			{ "trailing line feed", "/configuration\n" },
			{ "embedded line feed", "/config\nuration" },
		}) do
			h.it("picker-native-path-bytes: " .. backend .. " preserves a real folder's " .. case[1], function()
				local created, directory = Shell.exec_checked("mktemp -d")
				assert(created)
				directory = directory:gsub("[\r\n]+$", "")
				local selected = directory .. case[2]
				local ok, receipt = xpcall(function()
					assert(Shell.run("mkdir -- " .. Shell.quote(selected)))
					return picker_exit_receipt(0, selected .. "\n")
				end, debug.traceback)
				assert(Shell.run("rmdir -- " .. Shell.quote(selected) .. " " .. Shell.quote(directory)))
				if not ok then error(receipt, 0) end
				h.assert_eq(receipt, "accepted|" .. selected .. "|modal:1",
					"only the CLI's final LF is framing; filename bytes must survive")
			end)
		end
		for _, status in ipairs({ 1, 7 }) do
			h.it("linux-config-picker-exit: " .. backend .. " refuses absolute stdout after exit " .. status, function()
				h.assert_eq(picker_exit_receipt(status, "/untrusted/selection\n"), "refused|modal:1")
			end)
		end
		h.it("linux-config-picker-exit: " .. backend .. " refuses successful empty stdout", function()
			h.assert_eq(picker_exit_receipt(0, ""), "refused|modal:1")
		end)
	end
end)

h.describe("native application picker record admission", function()
	do local backend = "owned dialog"
		h.it("picker-native-record: " .. backend .. " never replaces a selected desktop file with its first line", function()
			local created, directory = Shell.exec_checked("mktemp -d")
			assert(created)
			directory = directory:gsub("[\r\n]+$", "")
			local applications = directory .. "/applications"
			local prefix = applications .. "/owned.desktop"
			local selected = prefix .. "\nother.desktop"
			local ok, receipt = xpcall(function()
				assert(Shell.run("mkdir -- " .. Shell.quote(applications)))
				for _, filename in ipairs({ prefix, selected }) do
					local file = assert(io.open(filename, "wb"))
					assert(file:write("[Desktop Entry]\nType=Application\nName=Owned\nExec=true\n"))
					assert(file:close())
				end
				return picker_exit_receipt(0, selected .. "\n", directory)
			end, debug.traceback)
			os.remove(prefix); os.remove(selected)
			assert(Shell.run("rmdir -- " .. Shell.quote(applications) .. " " .. Shell.quote(directory)))
			if not ok then error(receipt, 0) end
			h.assert_eq(receipt, "refused|modal:1",
				"an unsupported desktop-file id must be refused, never turned into another installed app")
		end)
	end
end)


h.describe("configuration filesystem root", function()
	do local backend = "owned dialog"
		h.it("linux-config-root: picker preserves a successful root selection: " .. backend, function()
			scenario(function(observed, shell)
				observed.answer, observed.status = "/\n", 0
				local paths = { default_config_dir = function() return "/owned/default" end }
				local picker = require("settings.ui.dir_picker")
				h.assert_eq(picker.pick(shell, paths, require("core.i18n.engine.i18n"), "/"), "/")
				h.assert_eq(picker.normalize(paths, "///"), "/")
				h.assert_eq(picker.normalize(paths, ""), "/owned/default")
				h.assert_eq(picker.normalize(paths, nil), "/owned/default")
				h.assert_eq(picker.normalize(paths, "relative"), nil)
			end)
		end)
	end
end)
