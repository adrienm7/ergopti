--- tests/unit/ui/field_check/test_field_check_composer_row.lua

--- ==============================================================================
--- MODULE: Composer Check Row
--- DESCRIPTION:
--- The Debug menu's « Test the composed layout », the one row every driver
--- shows (the Mac-only field checks are declared for macOS alone):
--- 1. the manifest declares it once for every platform, the window maps it to
---    the composer check and the menu builder wires it;
--- 2. a click runs the shared steps over the driver's composer environment,
---    writes the evidence record and shows the localized report;
--- 3. an environment the driver cannot build is a failed step, not a lost run.
--- ==============================================================================

local helpers = require("tests.helpers")

local MODULES = { "infra.logger", "infra.i18n", "infra.field_check", "infra.field_check_checks", "ui.field_check" }

--- A composer environment that completes every step, recording what it was asked.
--- @param calls table Receives "save" / "remove".
--- @return table env
local function scripted_env(calls)
	local installed = {}
	local env = {
		composer_id = "composed",
		declaration_path = "/cfg/layout_composer/composition.json",
		deps = nil,
		exists = function() return false end,
		log = function() end,
	}
	env.registry = {
		composer_save = function(_, on_done)
			calls[#calls + 1] = "save"
			installed.composed = { sha256 = "abc" }
			on_done(true, nil, nil, false, { enabled = true })
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
	function env.host_ready() return "pass", "enabled" end
	return env
end

--- Loads the window over scripted services.
--- @param composer_env function|nil ports.composer_env
--- @param body function(Window, world)
local function with_window(composer_env, body)
	helpers.with_stub_scope(MODULES, function()
		local world = { notes = {}, alerts = {}, evidence = {} }
		local logger = helpers.make_logger_stub()
		logger.evidence = function(_, message, ...) world.evidence[#world.evidence + 1] = string.format(message, ...) end
		package.loaded["infra.logger"] = logger
		package.loaded["infra.i18n"] = { get = function(key) return "[" .. key .. "]" end }
		package.loaded["infra.field_check"] = nil
		package.loaded["infra.field_check_checks"] = nil
		package.loaded["ui.field_check"] = nil
		local Window = require("ui.field_check")
		local services = {
			ports = function() return { composer_env = composer_env } end,
			notify = function(title, text, kind) world.notes[#world.notes + 1] = { title, text, kind } end,
			alert = function(title, text) world.alerts[#world.alerts + 1] = { title = title, text = text } return "close" end,
			copy = function() return true end,
			after = function(_, fn) fn() end,
		}
		world.services = services
		body(Window, world)
	end)
end

helpers.describe("composer check row", function()
	helpers.it("is declared once for every platform and wired in the menu (composer-check)", function()
		local file = assert(io.open(helpers.shared("modules/menu/menu_manifest.json"), "rb"))
		local manifest = hs.json.decode(file:read("*a"))
		file:close()
		local rows = {}
		for _, row in ipairs(manifest.debug_menu) do
			if row.id == "composer_check" then rows[#rows + 1] = row end
		end
		helpers.assert_eq(#rows, 1, "declared once")
		helpers.assert_eq(rows[1].type, "command")
		helpers.assert_eq(rows[1].i18n, "menu.debug.composer_check")
		helpers.assert_nil(rows[1].platforms, "shown on every platform")
		local builder = helpers.read_driver_source("ui/menu/builder.lua")
		helpers.assert_true(builder:find('["composer_check"]', 1, true) ~= nil, "the builder wires the row")
		with_window(nil, function(Window)
			helpers.assert_eq(Window.SHARED_ROWS.composer_check.check, "composer")
			helpers.assert_eq(Window.SHARED_ROWS.composer_check.title, rows[1].i18n)
			helpers.assert_nil(Window.ROWS.composer_check, "it is not one of the Mac-only rows")
		end)
	end)

	helpers.it("runs the shared steps, records the evidence and shows the report (composer-check)", function()
		local calls = {}
		with_window(function() return scripted_env(calls) end, function(Window, world)
			helpers.assert_true(Window.run("composer_check", world.services))
			helpers.assert_eq(table.concat(calls, ","), "save,remove", "a fresh run installs then removes")
			helpers.assert_eq(#world.evidence, 1, "one evidence record")
			helpers.assert_eq(world.evidence[1], "Field check result: check=composer verdict=pass steps=6 "
				.. "composer_fixture=pass composer_mode=info:fresh composer_install=pass composer_copy=pass "
				.. "composer_ready=pass:enabled composer_cleanup=pass")
			helpers.assert_eq(#world.alerts, 1)
			helpers.assert_contains(world.alerts[1].text, "[field_check.step.composer_ready]")
			helpers.assert_contains(world.alerts[1].text, "[field_check.verdict_pass]")
		end)
	end)

	helpers.it("records a driver that cannot build its environment as a failed step (composer-check)", function()
		with_window(function() return nil end, function(Window, world)
			helpers.assert_true(Window.run("composer_check", world.services))
			helpers.assert_contains(world.evidence[1], "verdict=fail steps=1 composer_fixture=fail:unusable")
		end)
	end)
end)
