--- tests/unit/core/ui/editors/test_layout_manager_tray_actions.lua

--- ==============================================================================
--- MODULE: Layout Manager Without Its Window (Linux)
--- DESCRIPTION:
--- Field report (AppImage, lgi missing): « Gérer les dispositions clavier »
--- only raised « show(): native window acquisition refused for
--- 'layout_manager' ». The layout manager is core, so its essential actions
--- must not depend on its window (maintainer decision, 2026-11-25): with no
--- native window, opening it offers to install and activate Ergopti through the
--- layout registry and says each step's result (layout-actions-windowless); the
--- tray's Layout menu carries the same actions as rows (layout-actions-tray).
--- Driven through the real webview manager and bridge; the native window
--- creator, the registry, the notifier, the problem list and the question
--- dialog are doubles.
--- ==============================================================================

local helpers = require("tests.helpers")

local ERGOPTI = "ergopti"
local INDEX = { layouts = { { id = ERGOPTI, name = "Ergopti", extension = { id = ERGOPTI } } } }

--- A registry double whose operations answer as configured.
--- @param opts table { installed?, install?, select?, uninstall?, busy?, record_error? }
--- @return table registry, table calls
local function registry_double(opts)
	local calls = {}
	local installed = opts.installed and { [ERGOPTI] = { id = ERGOPTI, extension = { id = ERGOPTI } } } or {}
	local active = ""
	local registry = {
		snapshot = function()
			return { platform = "linux", index = INDEX, installed = installed, busy = opts.busy, active = active,
				record_error = opts.record_error }
		end,
		install = function(id, done)
			calls[#calls + 1] = "install " .. id
			local answer = opts.install or { true, { entry = { id = id } } }
			if answer[1] then installed[id] = { id = id, extension = { id = id } } end
			done((table.unpack or unpack)(answer))
			return answer[1]
		end,
		select = function(id, done)
			calls[#calls + 1] = "select " .. id
			local answer = opts.select or { true, { id = id } }
			if answer[1] then active = id end
			done((table.unpack or unpack)(answer))
			return answer[1]
		end,
		uninstall = function(id, done)
			calls[#calls + 1] = "uninstall " .. id
			local answer = opts.uninstall or { true, { id = id } }
			if answer[1] then installed[id] = nil end
			done((table.unpack or unpack)(answer))
			return answer[1]
		end,
	}
	return registry, calls
end

--- The tray actions with every collaborator a double.
--- @param opts table Registry options, plus answer (the dialog's) and notifier_fails.
--- @return table actions, table record
local function actions(opts)
	local registry, calls = registry_double(opts)
	local record = { calls = calls, notices = {}, problems = {}, questions = {}, reloads = 0, restarts = 0, rebuilds = 0 }
	local deps = {
		registry = registry,
		layout_id = ERGOPTI,
		i18n = { get = function(key) return "t:" .. key end },
		notifier = { send = function(message, options)
			record.notices[#record.notices + 1] = { message = message, options = options }
			return true
		end },
		status = { report = function(problem, status_deps)
			record.problems[#record.problems + 1] = problem
			if status_deps and status_deps.notifier then
				status_deps.notifier.send(problem.body, { title = problem.title, level = "error", persistent = true })
			end
			return true
		end },
		ask = function(title, text, ok_label, cancel_label)
			record.questions[#record.questions + 1] = { title = title, text = text, ok = ok_label, cancel = cancel_label }
			return opts.answer
		end,
		daemon_state = {
			on_reload = function() record.restarts = record.restarts + 1; return true end,
			reload_layout_extensions = function() record.reloads = record.reloads + 1; return true end,
			on_config_changed = function() record.rebuilds = record.rebuilds + 1 end,
		},
		emulation = { status = function() return {} end, reload_if_started = function() return true end },
	}
	local Actions = helpers.load_module("ui.layout_manager.tray_actions")
	Actions._set_deps_for_test(deps)
	return Actions, record, deps
end

--- Opens the layout manager with no native window, as the tray row does.
--- @param body function Receives the webview manager and the error log lines.
local function without_window(body)
	local manager = require("core.ui.ui.webview_manager")
	local Logger = require("core.logger.engine.shim")
	local errors = {}
	local real_create, real_error = manager._create_gtk_window, Logger.error
	manager._create_gtk_window = function() return false, "GTK/WebKit unavailable" end
	manager._set_missing_component_probe_for_test(function() return require("core.ui.engine.gui_stack").LGI_COMPONENT end)
	Logger.error = function(_, fmt, ...)
		local ok, text = pcall(string.format, fmt, ...)
		errors[#errors + 1] = ok and text or tostring(fmt)
	end
	local ok, err = pcall(body, manager, errors)
	Logger.error = real_error
	manager._create_gtk_window = real_create
	manager._set_missing_component_probe_for_test(nil)
	require("ui.layout_manager.tray_actions")._set_deps_for_test(nil)
	if not ok then error(err, 0) end
end

--- The notices whose message is the translation of key.
--- @param record table
--- @param key string
--- @return table
local function notices_of(record, key)
	local found = {}
	for _, notice in ipairs(record.notices) do
		if notice.message:find("t:" .. key, 1, true) == 1 then found[#found + 1] = notice end
	end
	return found
end

helpers.describe("layout manager without its window (Linux)", function()
	helpers.it("offers to install and activate Ergopti when the window is refused (layout-actions-windowless)", function()
		without_window(function(manager, errors)
			local _, record = actions({ answer = true })
			helpers.assert_eq(manager.show("layout_manager"), false, "no window was opened")
			helpers.assert_eq(#record.questions, 1, "the user is asked once")
			helpers.assert_eq(record.questions[1].ok, "t:menu.layout.user_layout_install")
			helpers.assert_contains(record.questions[1].text, "t:layouts.linux_manager_offer_install")
			helpers.assert_eq(record.calls, { "install ergopti", "select ergopti" },
				"the registry installs, then activates the Ergopti layout")
			local done = notices_of(record, "layouts.linux_ergopti_installed_active")
			helpers.assert_eq(#done, 1, "the result is said in plain words")
			helpers.assert_eq(done[1].options.level, "success")
			helpers.assert_eq(record.reloads, 1, "its hotstring extension loads in place")
			helpers.assert_eq(record.restarts, 0, "the daemon is not restarted for a layout install")
			helpers.assert_eq(#record.problems, 0)
			for _, line in ipairs(errors) do
				helpers.assert_true(not line:find("native window acquisition refused", 1, true),
					"the raw refusal was logged as an error: " .. line)
			end
		end)
	end)

	helpers.it("reports a failed install with a red row and a persistent notice (layout-actions-windowless)", function()
		without_window(function(manager)
			local _, record = actions({ answer = true, install = { false, "download_failed", "HTTP 503" } })
			manager.show("layout_manager")
			helpers.assert_eq(record.calls, { "install ergopti" }, "nothing is activated after a failed install")
			helpers.assert_eq(#record.problems, 1, "a red tray row names the failure")
			local problem = record.problems[1]
			helpers.assert_eq(problem.code, "ergopti_layout_install_failed")
			helpers.assert_eq(problem.label, nil, "the tray names it by its menu.toml row")
			helpers.assert_eq(problem.body, "t:layouts.linux_ergopti_install_failed")
			helpers.assert_true(problem.active(), "the row stays while Ergopti is not installed")
			local failed = notices_of(record, "layouts.linux_ergopti_install_failed")
			helpers.assert_eq(#failed, 1)
			helpers.assert_eq(failed[1].options.persistent, true, "the failure notice stays up")
		end)
	end)

	helpers.it("fills the failure reason with the registry code's own explanation (layout-actions-windowless)", function()
		for code, key in pairs({ python_missing = "layouts.linux_needs_python",
			xorg_session = "layouts.linux_xorg_session", installer_failed = "layout_manager.failure_installer",
			no_source = "layout_manager.failure_other" }) do
			local Actions, record, deps = actions({ install = { false, code, "technical detail" } })
			deps.i18n = { get = function(wanted)
				if wanted == "layouts.linux_ergopti_install_failed" then return "failed: {1}" end
				return "t:" .. wanted
			end }
			Actions.install_and_activate(deps)
			helpers.assert_eq(record.problems[1].body, "failed: t:" .. key, code .. " reads as its explanation")
			helpers.assert_true(not record.problems[1].body:find("technical detail", 1, true),
				"the technical detail stays in the log")
			Actions._set_deps_for_test(nil)
		end
	end)

	helpers.it("explains every failure code the way the layout manager page does (layout-actions-windowless)", function()
		local Actions = helpers.load_module("ui.layout_manager.tray_actions")
		local fh = assert(io.open(helpers.driver_root() .. "/../_shared/ui/layout_manager/script.js", "rb"))
		local script = fh:read("*a")
		fh:close()
		local block = script:match("const FAILURE_KEYS = Object%.freeze%(%{(.-)%}%);")
		helpers.assert_true(block ~= nil, "the page declares its failure keys")
		local count = 0
		for code, key in block:gmatch("([%w_]+):%s*'([^']+)'") do
			count = count + 1
			helpers.assert_eq(Actions.FAILURE_KEYS[code], key, code .. " reads as on the page")
		end
		helpers.assert_true(count >= 5, "the page's codes were read: " .. count)
	end)

	helpers.it("says an install that could not be activated (layout-actions-windowless)", function()
		local Actions, record, deps = actions({ select = { false, "session_unsupported", "sway" } })
		helpers.assert_true(Actions.install_and_activate(deps), "the install was dispatched")
		helpers.assert_eq(record.calls, { "install ergopti", "select ergopti" })
		helpers.assert_eq(#notices_of(record, "layouts.linux_ergopti_installed_active"), 0)
		helpers.assert_eq(record.problems[1].code, "ergopti_layout_activate_failed")
		helpers.assert_true(record.problems[1].active(), "the row stays while Ergopti is not the active layout")
		helpers.assert_eq(record.reloads, 1, "the installed extension still loads")
		helpers.assert_eq(record.restarts, 0)
		Actions._set_deps_for_test(nil)
	end)

	helpers.it("offers to activate an installed Ergopti and points to the uninstall row (layout-actions-windowless)", function()
		local Actions, record, deps = actions({ installed = true, answer = true })
		helpers.assert_true(Actions.offer_without_window({ app_name = "layout_manager" }, deps))
		helpers.assert_eq(record.questions[1].ok, "t:menu.layout.user_layout_activate")
		helpers.assert_eq(record.calls, { "select ergopti" }, "only the activation runs")
		helpers.assert_eq(#notices_of(record, "layouts.linux_ergopti_activated"), 1)
		Actions._set_deps_for_test(nil)
	end)

	helpers.it("points to the tray rows when no dialog can ask (layout-actions-windowless)", function()
		local Actions, record, deps = actions({ answer = nil })
		helpers.assert_true(Actions.offer_without_window({ app_name = "layout_manager" }, deps))
		helpers.assert_eq(#record.calls, 0, "nothing runs unasked")
		local notice = notices_of(record, "layouts.linux_manager_use_tray")[1]
		helpers.assert_true(notice ~= nil, "a notice says where the actions are")
		helpers.assert_eq(notice.options.persistent, true)
		Actions._set_deps_for_test(nil)
	end)

	helpers.it("runs nothing when the user declines (layout-actions-windowless)", function()
		local Actions, record, deps = actions({ answer = false })
		helpers.assert_true(Actions.offer_without_window({ app_name = "layout_manager" }, deps))
		helpers.assert_eq(#record.calls, 0)
		helpers.assert_eq(#record.notices, 0)
		Actions._set_deps_for_test(nil)
	end)

	helpers.it("uninstalls Ergopti and reloads its extension (layout-actions-tray)", function()
		local Actions, record, deps = actions({ installed = true })
		helpers.assert_true(Actions.uninstall(deps))
		helpers.assert_eq(record.calls, { "uninstall ergopti" })
		helpers.assert_eq(#notices_of(record, "layouts.linux_ergopti_uninstalled"), 1)
		helpers.assert_eq(record.reloads, 1, "its hotstring extension drops in place")
		helpers.assert_eq(record.restarts, 0, "the daemon is not restarted for a layout removal")
		helpers.assert_true(record.rebuilds >= 1, "the tray shows the new state")
		Actions._set_deps_for_test(nil)
	end)

	helpers.it("names a failed uninstall in a red row while Ergopti stays installed (layout-actions-tray)", function()
		local Actions, record, deps = actions({ installed = true, uninstall = { false, "installer_failed", "exit 2" } })
		Actions.uninstall(deps)
		helpers.assert_eq(record.problems[1].code, "ergopti_layout_uninstall_failed")
		helpers.assert_eq(record.problems[1].body, "t:layouts.linux_ergopti_uninstall_failed")
		helpers.assert_true(record.problems[1].active())
		helpers.assert_eq(record.reloads, 0, "nothing changed, nothing reloads")
		helpers.assert_eq(record.restarts, 0)
		Actions._set_deps_for_test(nil)
	end)
end)

helpers.describe("layout manager tray rows (Linux)", function()
	local COMMAND = require("settings.engine.keys").COMMAND

	--- The label and action of each drawn row.
	--- @param rows table
	--- @return table
	local function drawn(rows)
		local out = {}
		for _, row in ipairs(rows) do
			out[#out + 1] = { label = row.title or row.label, fn = row.fn or row.action, disabled = row.disabled }
		end
		return out
	end

	helpers.it("declares the Linux rows and their commands in the manifest (layout-actions-tray)", function()
		local Json = require("core.text.engine.json")
		local fh = assert(io.open(helpers.driver_root() .. "/../_shared/menu/data/menu_manifest.json", "rb"))
		local manifest = Json.decode(fh:read("*a"))
		fh:close()
		local row
		for _, entry in ipairs(manifest.layout_menu) do
			if entry.id == "layout_user_install" then row = entry end
		end
		helpers.assert_true(row ~= nil, "the Layout menu declares the Ergopti rows")
		helpers.assert_eq(row.platforms, { "linux" })
		helpers.assert_eq(COMMAND.USER_LAYOUT_INSTALL, "user_layout_install")
		helpers.assert_eq(COMMAND.USER_LAYOUT_ACTIVATE, "user_layout_activate")
		helpers.assert_eq(COMMAND.USER_LAYOUT_UNINSTALL, "user_layout_uninstall")
		local owner = assert(helpers.read_module_source("ui.menu.menu_layouts"))
		helpers.assert_true(owner:find('providers["layout_user_install"]', 1, true) ~= nil, "the provider exists")
		helpers.assert_true(owner:find('require("ui.layout_manager.tray_actions").rows()', 1, true) ~= nil)
	end)

	helpers.it("draws the install row and runs it through the registry (layout-actions-tray)", function()
		local Actions, record, deps = actions({})
		local rows = drawn(Actions.rows(deps))
		helpers.assert_eq(#rows, 1, "one row while Ergopti is not installed")
		helpers.assert_contains(rows[1].label, require("core.i18n.engine.i18n").get("menu.layout.user_layout_install"))
		rows[1].fn()
		helpers.assert_eq(record.calls, { "install ergopti", "select ergopti" })
		Actions._set_deps_for_test(nil)
	end)

	helpers.it("draws the installed state with its activate and uninstall rows (layout-actions-tray)", function()
		local Actions, record, deps = actions({ installed = true })
		local rows = drawn(Actions.rows(deps))
		helpers.assert_eq(#rows, 3, "a state label, then two commands")
		local I18n = require("core.i18n.engine.i18n")
		helpers.assert_contains(rows[1].label, I18n.get("menu.layout.user_layout_installed"))
		helpers.assert_contains(rows[2].label, I18n.get("menu.layout.user_layout_activate"))
		helpers.assert_contains(rows[3].label, I18n.get("menu.layout.user_layout_uninstall"))
		rows[3].fn()
		helpers.assert_eq(record.calls, { "uninstall ergopti" })
		Actions._set_deps_for_test(nil)
	end)

	helpers.it("draws a step in flight as a label with no action (layout-actions-tray)", function()
		local Actions, _, deps = actions({ busy = { id = ERGOPTI, action = "install" } })
		local rows = drawn(Actions.rows(deps))
		helpers.assert_eq(#rows, 1)
		helpers.assert_contains(rows[1].label, require("core.i18n.engine.i18n").get("menu.layout.user_layout_busy"))
		Actions._set_deps_for_test(nil)
	end)

	helpers.it("names the layout the tray installs in the shared defaults (layout-actions-tray)", function()
		local Actions = helpers.load_module("ui.layout_manager.tray_actions")
		Actions._set_deps_for_test(nil)
		local Json = require("core.text.engine.json")
		local fh = assert(io.open(helpers.driver_root() .. "/../_shared/layouts/data/defaults.json", "rb"))
		local defaults = Json.decode(fh:read("*a"))
		fh:close()
		helpers.assert_eq(defaults.registry.ergopti_layout_id, ERGOPTI)
		local index_fh = assert(io.open(helpers.driver_root() .. "/../../layouts/registry/index.json", "rb"))
		local index = Json.decode(index_fh:read("*a"))
		index_fh:close()
		local published = false
		for _, entry in ipairs(index.layouts) do
			if entry.id == ERGOPTI then
				for _, platform in ipairs(entry.platforms) do published = published or platform == "linux" end
			end
		end
		helpers.assert_true(published, "the registry publishes that layout for Linux")
	end)
end)

return true
