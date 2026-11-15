--- tests/unit/modules/keymap/test_nav_layer_save.lua

--- ==============================================================================
--- MODULE: Navigation Layer Save (Linux)
--- DESCRIPTION:
--- Drives modules/keymap/nav_layer_save.lua the way the layout editor's
--- « Apply the navigation layer » does, with the real shared host logic, loader
--- and TOML codec, and a double for the remap manager.
---
--- COVERAGE:
--- 1. A valid layers.toml is published byte for byte and the remap manager is
---    asked to reload once, with no window involved (layout-editor-nav-apply).
--- 2. An action outside the vocabulary is refused before anything is written,
---    and a failed reload reports the saved file as not applied.
--- 3. The save owns no window: the module requires nothing under ui/, so the
---    navigation layer editor window can be retired without it.
--- ==============================================================================

local helpers = require("tests.helpers")

local SHARED_ROOT = helpers.driver_root() .. "/../_shared"
local FIXTURE = SHARED_ROOT .. "/tests/corpus/layer_editor/edited_layers.toml"
local MODULE_PATH = helpers.driver_root() .. "/modules/keymap/nav_layer_save.lua"





-- ====================================
-- ====================================
-- ======= 1/ Doubles and setup =======
-- ====================================
-- ====================================

--- Reads a whole file; raises when it cannot.
local function read_file(path)
	local fh, err = io.open(path, "rb")
	if not fh then error("cannot open " .. path .. ": " .. tostring(err)) end
	local content = fh:read("*a")
	fh:close()
	return content
end

--- Creates an empty folder of its own, standing for a configuration folder.
local function make_config_dir()
	local dir = os.tmpname()
	os.remove(dir)
	local ok_mkdir = os.execute('mkdir "' .. dir .. '"')
	helpers.assert_true(ok_mkdir == true or ok_mkdir == 0, "sandbox directory must exist")
	return dir
end

local function remove_config_dir(dir)
	os.remove(dir .. "/layers.toml")
	os.execute('rmdir "' .. dir .. '"')
end

--- A daemon state whose remap manager records its reloads.
local function make_state(dir)
	local world = { restarts = 0, restart_result = true }
	world.state = {
		tap_hold = { reload = function()
			world.restarts = world.restarts + 1
			return world.restart_result
		end },
		paths = { shared_root = function() return SHARED_ROOT end },
		config_paths = { get_config_dir = function() return dir end },
	}
	return world
end

local function codes(payload)
	local out = {}
	for _, err in ipairs(payload.errors or {}) do out[#out + 1] = err.code end
	table.sort(out)
	return table.concat(out, ",")
end





-- =======================================
-- =======================================
-- ======= 2/ The window-free save =======
-- =======================================
-- =======================================

helpers.describe("Linux navigation layer save", function()
	local NavLayerSave = helpers.load_module("modules.keymap.nav_layer_save")

	helpers.it("saves and applies with no window open (layout-editor-nav-apply)", function()
		local dir = make_config_dir()
		local world = make_state(dir)
		local text = read_file(FIXTURE)
		local result = NavLayerSave.apply_text(text, world.state)
		local written = read_file(dir .. "/layers.toml")
		remove_config_dir(dir)
		helpers.assert_eq(result.saved, true)
		helpers.assert_eq(result.applied, true)
		helpers.assert_eq(written, text, "the exact layers.toml text is published")
		helpers.assert_eq(world.restarts, 1, "the remap manager reloads it once")
	end)

	helpers.it("refuses an invalid layer and reports a failed reload (layout-editor-nav-apply)", function()
		local dir = make_config_dir()
		local world = make_state(dir)
		local refused = NavLayerSave.apply_text('[_meta]\nschema_version = 1\n[layers.nav.all]\n"KeyA" = "format_disk"\n',
			world.state)
		helpers.assert_eq(refused.saved, false)
		helpers.assert_eq(codes(refused), "unknown_action")
		helpers.assert_eq(world.restarts, 0)
		world.restart_result = false
		local unapplied = NavLayerSave.apply_text(read_file(FIXTURE), world.state)
		remove_config_dir(dir)
		helpers.assert_eq(unapplied.saved, true)
		helpers.assert_eq(unapplied.applied, false)
	end)

	helpers.it("owns no window (retire-layer-editor)", function()
		local source = read_file(MODULE_PATH)
		helpers.assert_true(source:find('require%("ui%.') == nil, "the save requires nothing under ui/")
	end)
end)
