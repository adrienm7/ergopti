--- tests/unit/ui/menu/structure/test_compose_input_method_row.lua

--- ==============================================================================
--- MODULE: Compose Input Method Row Tests
--- DESCRIPTION:
--- Layout > « Custom layouts » on Linux: the row that says how far GTK 3
--- composes, from the state the user installer records, and its pins to that
--- installer, the menu manifest and every locale.
--- ==============================================================================

local helpers = require("tests.helpers")
local Row = require("ui.menu.compose_input_method_row")

local function rows_for(state_text, env)
	env = env or {}
	local read_path
	local rows = Row.rows({
		t = function(key) return key end,
		getenv = function(name) return env[name] end,
		read_file = function(path)
			read_path = path
			return state_text
		end,
	})
	return rows, read_path
end

local function read(path)
	local handle = assert(io.open(path, "rb"))
	local text = handle:read("*a")
	handle:close()
	return text
end

helpers.describe("compose input method row", function()
	helpers.it("(gtk3-compose-ibus) names each installer state", function()
		local root = { ERGOPTI_XKB_USER_ROOT = "/tmp/xkb" }
		local rows, path = rows_for("no_ibus\n", root)
		helpers.assert_eq(path, "/tmp/xkb/" .. Row.STATE_FILE)
		helpers.assert_eq(rows, { { label = "menu.layout.compose_single_character", disabled = true } })
		helpers.assert_eq(rows_for("ibus_active\n", root)[1].label, "menu.layout.compose_ibus")
		helpers.assert_eq(rows_for("other_active\n", root)[1].label, "menu.layout.compose_other_input_method")
		helpers.assert_eq(rows_for("ibus_enabled\n", root)[1].label, "menu.layout.compose_ibus_next_login",
			"IBus written by Ergopti reaches GTK at the next login")
		root.GTK_IM_MODULE = "ibus"
		helpers.assert_eq(rows_for("ibus_enabled\n", root)[1].label, "menu.layout.compose_ibus")
	end)

	helpers.it("(gtk3-compose-ibus) draws nothing without a Compose block or for an unknown state", function()
		helpers.assert_eq(rows_for(nil), {}, "no state file: no managed Compose block")
		helpers.assert_eq(rows_for("guess\n"), {}, "an unknown state is never shown as a known one")
		helpers.assert_eq(rows_for(""), {})
	end)

	helpers.it("(gtk3-compose-ibus) the installer, the manifest and every locale name the same row", function()
		local driver = helpers.driver_root()
		local installer = read(driver .. "/../../ergopti/linux/xkb_installation/user_layout_installer.py")
		helpers.assert_eq(installer:match('\nCOMPOSE_STATE_NAME = "([^"]+)"'), Row.STATE_FILE)
		helpers.assert_eq(installer:match('\nENV_USER_ROOT = "([^"]+)"'), Row.ROOT_ENV)
		local package = read(driver .. "/../../ergopti/linux/xkb_installation/layout_package.py")
		for _, state in ipairs({ "ibus_active", "ibus_enabled", "other_active", "no_ibus" }) do
			helpers.assert_true(package:find('= "' .. state .. '"\n', 1, true) ~= nil, state)
			local key = Row.label_key(state, nil)
			helpers.assert_true(key ~= nil, state)
		end
		local manifest = read(driver .. "/../_shared/menu/data/menu.toml")
		helpers.assert_true(manifest:find('id = "compose_input_method"\nplatforms = ["linux"]', 1, true) ~= nil)
		local json = require("core.text.engine.json")
		for _, locale in ipairs({ "en", "fr" }) do
			local catalogue = json.decode(read(driver .. "/../_shared/core/i18n/data/locales/" .. locale .. ".json"))
			for _, key in ipairs({ "menu.layout.compose_ibus", "menu.layout.compose_ibus_next_login",
				"menu.layout.compose_other_input_method", "menu.layout.compose_single_character" }) do
				helpers.assert_true(type(catalogue[key]) == "string", locale .. " " .. key)
			end
		end
	end)
end)
