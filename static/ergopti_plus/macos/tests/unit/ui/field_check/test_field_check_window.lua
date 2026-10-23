--- tests/unit/ui/field_check/test_field_check_window.lua

--- ==============================================================================
--- MODULE: Field Check Window
--- DESCRIPTION:
--- The Debug menu rows of the one-click Mac checks:
--- 1. each manifest row maps to one check and every row is wired in the menu
---    builder, declared for macOS only with a reason, and translated;
--- 2. a click runs the check, shows the localized report and copies it on
---    request; the key accounting check announces that it watches the keys;
--- 3. a second click while a check runs only notifies.
--- ==============================================================================

local helpers = require("tests.helpers")

local MODULES = { "infra.logger", "infra.i18n", "infra.field_check", "infra.field_check_checks", "ui.field_check" }

--- Loads the window over scripted services.
--- @param body function(Window, services, world)
local function with_window(body)
	helpers.with_stub_scope(MODULES, function()
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["infra.i18n"] = { get = function(key) return "[" .. key .. "]" end }
		package.loaded["infra.field_check"] = nil
		package.loaded["infra.field_check_checks"] = nil
		package.loaded["ui.field_check"] = nil
		local Window = require("ui.field_check")
		local world = { notes = {}, alerts = {}, copies = {}, click = nil, delayed = {} }
		local services = {
			ports = function()
				return {
					path_exists = function() return false end,
					exec = function(_, _, _, callback) callback(1, "") end,
					home = function() return nil end,
					remap_facts = function() return { enabled = false, phase = "idle", guardian = "not_used" } end,
					keystats_facts = function() return { credit_source = "legacy", capture_loaded = false, ledger_drained = 0 } end,
					health_counts = function() return { lease = {} } end,
					count_keys = function(_, callback) world.finish_keys = callback end,
				}
			end,
			notify = function(title, body_text, kind) world.notes[#world.notes + 1] = { title, body_text, kind } end,
			alert = function(title, text, copy, close)
				world.alerts[#world.alerts + 1] = { title = title, text = text }
				return world.click == "copy" and copy or close
			end,
			copy = function(text) world.copies[#world.copies + 1] = text; return true end,
			after = function(_, fn) fn() end,
		}
		body(Window, services, world)
	end)
end

helpers.describe("field check menu rows", function()
	helpers.it("maps the three manifest rows to their checks", function()
		with_window(function(Window)
			helpers.assert_eq(Window.ROWS.field_check_lease.check, "lease")
			helpers.assert_eq(Window.ROWS.field_check_owned_runtime.check, "owned_runtime")
			helpers.assert_eq(Window.ROWS.field_check_key_accounting.check, "key_accounting")
		end)
	end)

	helpers.it("declares every row once for macOS only, with a reason, and wires it in the builder", function()
		local file = assert(io.open(helpers.shared("modules/menu/menu_manifest.json"), "rb"))
		local manifest = hs.json.decode(file:read("*a"))
		file:close()
		local rows = {}
		for _, row in ipairs(manifest.debug_menu) do
			if row.id and row.id:find("^field_check_") then rows[row.id] = row end
		end
		local builder = helpers.read_driver_source("ui/menu/builder.lua")
		with_window(function(Window)
			for id, entry in pairs(Window.ROWS) do
				local row = rows[id]
				helpers.assert_not_nil(row, "manifest row missing: " .. id)
				helpers.assert_eq(row.type, "command")
				helpers.assert_eq(row.i18n, entry.title)
				helpers.assert_eq(#row.platforms, 1)
				helpers.assert_eq(row.platforms[1], "hs")
				helpers.assert_type(row.reason_key, "string")
				helpers.assert_true(builder:find('["' .. id .. '"]', 1, true) ~= nil, "builder does not wire " .. id)
			end
			for id in pairs(rows) do helpers.assert_not_nil(Window.ROWS[id], "row without a check: " .. id) end
		end)
	end)
end)

helpers.describe("field check window", function()
	helpers.it("shows the localized report and copies it on request", function()
		with_window(function(Window, services, world)
			world.click = "copy"
			helpers.assert_true(Window.run("field_check_lease", services))
			helpers.assert_eq(#world.alerts, 1)
			helpers.assert_eq(world.alerts[1].title, "[menu.debug.field_check_lease]")
			helpers.assert_contains(world.alerts[1].text, "[field_check.step.cli_present]")
			helpers.assert_eq(world.copies[1], world.alerts[1].text)
			helpers.assert_eq(world.notes[#world.notes][2], "[field_check.copied]")
		end)
	end)

	helpers.it("copies nothing when the user closes the report", function()
		with_window(function(Window, services, world)
			world.click = "close"
			Window.run("field_check_owned_runtime", services)
			helpers.assert_eq(#world.copies, 0)
		end)
	end)

	helpers.it("announces the key watch only for the key accounting check, and refuses a second click", function()
		with_window(function(Window, services, world)
			helpers.assert_true(Window.run("field_check_key_accounting", services))
			helpers.assert_eq(world.notes[1][2], "[field_check.keys_prompt]")
			helpers.assert_eq(#world.alerts, 0)
			helpers.assert_eq(Window.run("field_check_lease", services), false)
			helpers.assert_eq(world.notes[2][2], "[field_check.busy]")
			world.finish_keys({ tap_running = true, presses = 3 })
			helpers.assert_eq(#world.alerts, 1)
			helpers.assert_true(Window.run("field_check_lease", services))
		end)
	end)

	helpers.it("rejects an unknown row", function()
		with_window(function(Window, services)
			helpers.assert_eq(pcall(Window.run, "field_check_nope", services), false)
		end)
	end)
end)
