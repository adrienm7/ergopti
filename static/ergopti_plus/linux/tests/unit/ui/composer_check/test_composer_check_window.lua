--- tests/unit/ui/composer_check/test_composer_check_window.lua

--- ==============================================================================
--- MODULE: Composer Check Window (Linux)
--- DESCRIPTION:
--- The Debug menu's « Test the composed layout »:
--- 1. a click runs the shared steps over the driver's composer environment,
---    writes one evidence record and shows the localized report with a
---    « Copy report » button that copies exactly what the window shows;
--- 2. a second click while a check runs only says so, and the check can run
---    again once it finished;
--- 3. an environment the driver cannot build, and a check that raises, are
---    failed steps, not lost runs;
--- 4. the menu row is declared once for every platform and the Linux menu
---    routes it to this window.
--- ==============================================================================

local helpers = require("tests.helpers")

local MODULES = { "logger.shim", "ui.composer_check" }

--- A composer environment that completes every step.
--- @param calls table Receives "save" / "remove".
--- @return table env
local function scripted_env(calls)
	local installed = {}
	local env = {
		composer_id = "composed",
		declaration_path = "/cfg/layout_composer/composition.json",
		exists = function() return false end,
		log = function() end,
	}
	env.registry = {
		composer_save = function(_, on_done)
			calls[#calls + 1] = "save"
			installed.composed = { sha256 = "abc" }
			on_done(true, nil, nil, false, { verified = true })
		end,
		composer_remove = function(on_done)
			calls[#calls + 1] = "remove"
			installed.composed = nil
			on_done(true)
		end,
	}
	function env.snapshot() return { installed = installed } end
	function env.read_fixture() return { declaration = "{}", keylayout = "<keyboard/>" } end
	function env.read_copy() return "<keyboard/>" end
	function env.sha256(_, callback) callback("abc", nil) end
	function env.host_ready() return "pass", "verified" end
	return env
end

--- Loads the window over a recording logger and scripted services.
--- @param build_env function|nil services.env
--- @param body function(Window, world)
local function with_window(build_env, body)
	local saved = {}
	for _, name in ipairs(MODULES) do saved[name] = package.loaded[name] end
	local world = { evidence = {}, errors = {}, notes = {}, dialogs = {}, copies = {}, deferred = {}, click = "close" }
	local logger = helpers.make_logger_stub()
	logger.evidence = function(_, message, ...) world.evidence[#world.evidence + 1] = string.format(message, ...) end
	logger.error = function(_, message, ...) world.errors[#world.errors + 1] = string.format(message, ...) end
	package.loaded["logger.shim"] = logger
	package.loaded["ui.composer_check"] = nil
	local ok, err = xpcall(function()
		local Window = require("ui.composer_check")
		Window._reset()
		world.services = {
			translate = function(key) return "[" .. key .. "]" end,
			env = build_env,
			notify = function(message) world.notes[#world.notes + 1] = message end,
			dialog = function(title, text, copy_label, close_label)
				world.dialogs[#world.dialogs + 1] = { title = title, text = text, copy = copy_label, close = close_label }
				return world.click == "copy"
			end,
			copy = function(text) world.copies[#world.copies + 1] = text; return true end,
			defer = function(fn) world.deferred[#world.deferred + 1] = fn end,
		}
		function world.flush()
			local pending = world.deferred
			world.deferred = {}
			for _, fn in ipairs(pending) do fn() end
		end
		body(Window, world)
	end, debug.traceback)
	for _, name in ipairs(MODULES) do package.loaded[name] = saved[name] end
	if not ok then error(err, 0) end
end

helpers.describe("composer check window (Linux)", function()
	helpers.it("runs the shared steps, records the evidence and shows the report (composer-check)", function()
		local calls = {}
		with_window(function() return scripted_env(calls) end, function(Window, world)
			helpers.assert_true(Window.run(world.services))
			helpers.assert_eq(table.concat(calls, ","), "save,remove", "a fresh run installs then removes")
			helpers.assert_eq(#world.evidence, 1, "one evidence record")
			helpers.assert_eq(world.evidence[1], "Composer check result: check=composer verdict=pass steps=6 "
				.. "composer_fixture=pass composer_mode=info:fresh composer_install=pass composer_copy=pass "
				.. "composer_ready=pass:verified composer_cleanup=pass")
			helpers.assert_eq(#world.dialogs, 0, "the dialog opens from a fresh turn of the loop")
			world.flush()
			helpers.assert_eq(#world.dialogs, 1)
			helpers.assert_eq(world.dialogs[1].title, "[menu.debug.composer_check]")
			helpers.assert_eq(world.dialogs[1].copy, "[field_check.copy]")
			helpers.assert_eq(world.dialogs[1].close, "[field_check.close]")
			helpers.assert_contains(world.dialogs[1].text, "[field_check.verdict_pass]")
			helpers.assert_contains(world.dialogs[1].text, "[field_check.step.composer_ready] : verified")
			helpers.assert_eq(#world.copies, 0, "nothing is copied unless asked")
		end)
	end)

	helpers.it("copies exactly the report the window shows (composer-check)", function()
		with_window(function() return scripted_env({}) end, function(Window, world)
			world.click = "copy"
			Window.run(world.services)
			world.flush()
			helpers.assert_eq(#world.copies, 1)
			helpers.assert_eq(world.copies[1], world.dialogs[1].text)
			helpers.assert_eq(world.notes[#world.notes], "[field_check.copied]")
		end)
	end)

	helpers.it("refuses a second click while a check runs and runs again afterwards (composer-check)", function()
		local pending
		with_window(function()
			local env = scripted_env({})
			env.registry.composer_save = function(_, on_done) pending = on_done end
			return env
		end, function(Window, world)
			helpers.assert_true(Window.run(world.services))
			helpers.assert_true(Window.is_running(), "the install has not answered yet")
			helpers.assert_true(not Window.run(world.services), "a second click is refused")
			helpers.assert_eq(world.notes[1], "[field_check.busy]")
			pending(true, nil, nil, false, { verified = true })
			helpers.assert_true(not Window.is_running(), "the check settled")
			helpers.assert_eq(#world.evidence, 1)
		end)
		with_window(function() return scripted_env({}) end, function(Window, world)
			helpers.assert_true(Window.run(world.services))
			helpers.assert_true(Window.run(world.services), "and it runs again once finished")
		end)
	end)

	helpers.it("records a driver that cannot build its environment as a failed step (composer-check)", function()
		with_window(function() return nil, "no registry" end, function(Window, world)
			helpers.assert_true(Window.run(world.services))
			helpers.assert_eq(world.evidence[1], "Composer check result: check=composer verdict=fail steps=1 "
				.. "composer_fixture=fail:unusable")
			helpers.assert_true(not Window.is_running(), "and the check is not left busy")
		end)
	end)

	helpers.it("records a check that raises and stays usable (composer-check)", function()
		with_window(function()
			local env = scripted_env({})
			env.snapshot = function() error("the record exploded") end
			return env
		end, function(Window, world)
			helpers.assert_true(Window.run(world.services))
			helpers.assert_contains(world.evidence[1], "verdict=fail")
			helpers.assert_contains(world.evidence[1], "internal_error=fail:raised")
			helpers.assert_true(not Window.is_running())
		end)
	end)

	helpers.it("declares the row once for every platform and routes it in the menu (composer-check)", function()
		local Json = require("json")
		local handle = assert(io.open(helpers.driver_root() .. "/../_shared/modules/menu/menu_manifest.json", "rb"))
		local manifest = Json.decode(handle:read("*a"))
		handle:close()
		local rows = {}
		for _, row in ipairs(manifest.debug_menu) do
			if row.id == "composer_check" then rows[#rows + 1] = row end
		end
		helpers.assert_eq(#rows, 1, "declared once")
		helpers.assert_eq(rows[1].i18n, "menu.debug.composer_check")
		helpers.assert_nil(rows[1].platforms, "shown on every platform")
		local builder = assert(io.open(helpers.driver_root() .. "/ui/menu/menu_builder.lua", "rb"))
		local source = builder:read("*a")
		builder:close()
		helpers.assert_true(source:find('["composer_check"] = call_ctx("on_composer_check")', 1, true) ~= nil,
			"the Linux debug menu routes the row")
		local main = assert(io.open(helpers.driver_root() .. "/ergopti_hotstrings.lua", "rb"))
		local daemon = main:read("*a")
		main:close()
		helpers.assert_true(daemon:find('on_composer_check = function() require("ui.composer_check").run() end', 1, true) ~= nil,
			"the daemon supplies the row's action")
	end)
end)
