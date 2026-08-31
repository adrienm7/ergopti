--- static/ergopti_plus/linux/tests/unit/meta/test_terminator_no_fallback.lua

--- ==============================================================================
--- MODULE: Terminator No-Fallback Invariant Test (Linux driver)
--- DESCRIPTION:
--- Regression guard for the fail-fast hardening of the daemon entry point. The
--- terminator catalogue is the single source of truth (shared keymap.terminators)
--- and ships alongside the daemon, so a require failure is a broken install. The
--- daemon must NOT silently degrade to a hardcoded minimal {space . , newline}
--- set — that would produce wrong word-boundary detection and therefore wrong
--- expansions (rule 5.3/5.4). It must Logger.error + error() instead.
---
--- This test text-scans ergopti_hotstrings.lua (it does not require it — the
--- daemon pulls in evdev/uinput bindings unavailable in the headless harness).
--- ==============================================================================

local helpers = require("tests.helpers")

local DRIVER_ROOT = helpers.driver_root()
local DAEMON_PATH = DRIVER_ROOT .. "/ergopti_hotstrings.lua"

local function read_file(path)
	local fh = io.open(path, "r")
	if not fh then return nil end
	local content = fh:read("*a")
	fh:close()
	return content
end





-- ===================================================
-- ===================================================
-- ======= 1/ No Hardcoded Terminator Fallback =======
-- ===================================================
-- ===================================================

helpers.describe("linux: daemon fails fast on a missing terminator catalogue", function()
	local src = read_file(DAEMON_PATH)

	helpers.it("ergopti_hotstrings.lua is readable", function()
		helpers.assert_true(type(src) == "string" and #src > 0,
			"could not read " .. DAEMON_PATH)
	end)

	if type(src) == "string" then
		helpers.it("still loads the shared keymap.terminators single source", function()
			-- Loaded via pcall(require, "keymap.terminators") — match the module ref.
			helpers.assert_true(src:find('"keymap%.terminators"') ~= nil,
				"daemon must require the shared keymap.terminators module")
		end)

		helpers.it("does not declare a hardcoded minimal terminator fallback", function()
			helpers.assert_true(src:find("_fallback") == nil,
				"the minimal {space . , newline} fallback must be gone (fail fast instead)")
		end)

		helpers.it("fails loudly (error) when the catalogue cannot load", function()
			-- The terminators loader block must raise rather than return a stub.
			helpers.assert_true(src:find("keymap%.terminators is required") ~= nil,
				"daemon must error() with a clear message on a terminators load failure")
		end)
	end
end)




-- ===================================================
-- ===================================================
-- ======= 2/ Persistence rollback ===================
-- ===================================================
-- ===================================================

helpers.describe("linux: word-delimiter menu changes are durable", function()
	helpers.it("rolls a live toggle back when the atomic preference write fails", function()
		local Terminators = require("keymap.terminators")
		local menu_builder = helpers.load_module("ui.menu.menu_builder")
		local before = Terminators.is_terminator_enabled("space")
		local persists, rebuilds = 0, 0
		local config = {
			get_groups = function() return {} end,
			get_categories = function() return {} end,
			get_category_order = function() return {} end,
			is_group_enabled = function() return true end,
		}
		local menu = menu_builder.build({
			_version = "9.9.9",
			config = config,
			on_persist_terminators = function() persists = persists + 1 ; return false end,
			on_menu_changed = function() rebuilds = rebuilds + 1 end,
		})

		local space_row = nil
		local function find_space(items)
			for _, item in ipairs(items or {}) do
				if type(item) == "table" then
					if type(item.title) == "string" and item.title:find("␣ : Espace", 1, true) then
						space_row = item
						return
					end
					find_space(item.menu)
					if space_row then return end
				end
			end
		end
		find_space(menu)
		helpers.assert_not_nil(space_row, "the live catalogue row must be reachable in the menu")
		helpers.assert_true(type(space_row.fn) == "function", "the row must expose its click callback")
		space_row.fn()

		helpers.assert_eq(persists, 1, "one click must request one atomic persistence transaction")
		helpers.assert_eq(rebuilds, 0, "a failed change must not rebuild a menu advertising success")
		helpers.assert_eq(Terminators.is_terminator_enabled("space"), before,
			"the live matcher must return to the durable delimiter state")
	end)
end)
