--- tests/unit/modules/keymap/test_nav_layer_save.lua

--- ==============================================================================
--- MODULE: Navigation Layer Save (macOS)
--- DESCRIPTION:
--- Drives modules/keymap/nav_layer_save.lua the way Ergopti Studio does, with
--- the real shared host logic, loader and TOML codec, and native doubles for
--- the file adapter, the remap facade and the notifications.
---
--- COVERAGE:
--- 1. « Apply the navigation layer » publishes the text against the file it
---    reads now, regenerates the Karabiner rules and hands the wheel bindings
---    to their owner; an invalid layer writes and regenerates nothing
---    (layout-editor-nav-apply).
--- 2. A regeneration failing after the save is notified, once
---    (leh-003-late-regeneration-failure).
--- 3. The Studio's « Navigation layer » entries read the user's layers.toml,
---    else the preset, and the key whose hold enters the layer
---    (studio-nav-entry).
--- ==============================================================================

local helpers   = require("tests.helpers")
local Json      = require("core.text.engine.json")
local TomlCodec = require("core.text.engine.toml_codec")

local FIXTURE = helpers.shared("tests/corpus/layer_editor/edited_layers.toml")
local LEGENDS = helpers.shared("tests/corpus/layer_editor/legends.json")





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

--- Writes a whole file; raises when it cannot.
local function write_file(path, content)
	local fh = assert(io.open(path, "wb"))
	fh:write(content)
	fh:close()
end

--- A fresh, empty configuration folder.
local function make_config_dir()
	local dir = helpers.temp_dir() .. "/ergopti_nav_layer_save_" .. tostring(os.time()) .. "_"
		.. tostring(math.random(100000, 999999))
	local ok_mkdir = os.execute('mkdir "' .. dir .. '"')
	helpers.assert_true(ok_mkdir == true or ok_mkdir == 0, "sandbox directory must exist")
	return dir
end

local function remove_config_dir(dir)
	os.remove(dir .. "/layers.toml")
	os.execute('rmdir "' .. dir .. '"')
end

--- Every error code of a payload's errors, sorted and joined.
local function codes(payload)
	local out = {}
	for _, err in ipairs(payload.errors or {}) do out[#out + 1] = err.code end
	table.sort(out)
	return table.concat(out, ",")
end

--- Loads a fresh save module with native doubles and runs one scenario.
--- @param scenario function(save, world)
local function with_save(scenario)
	local names = { "core.logger.engine.logger", "core.i18n.engine.i18n", "core.fs.engine.paths",
		"settings.engine.paths", "core.fs.adapters.file_system", "modules.keymap.nav_layer_save",
		"modules.shortcuts.bindings", "core.ui.engine.notifications" }
	local saved = {}
	for _, name in ipairs(names) do saved[name] = package.loaded[name] end
	local world = { dir = make_config_dir(), writes = {}, regenerations = 0, regenerate_accepts = true,
		wheel_reconciles = 0, notices = {} }
	local ok, err = xpcall(function()
		local logger = {}
		for _, level in ipairs({ "trace", "debug", "done", "info", "start", "success", "warn", "error" }) do
			logger[level] = function() end
		end
		package.loaded["core.logger.engine.logger"] = logger
		package.loaded["core.i18n.engine.i18n"] = { get = function(key) return key end }
		package.loaded["core.fs.engine.paths"] = {
			shared_root = function() return helpers.shared() end,
			shared = function(rel) return helpers.shared(rel) end,
		}
		package.loaded["settings.engine.paths"] = { get_config_dir = function() return world.dir end }
		package.loaded["modules.shortcuts.bindings"] = { reconcile_layer_wheel = function()
			world.wheel_reconciles = world.wheel_reconciles + 1
			return true
		end }
		package.loaded["core.ui.engine.notifications"] = { notify = function(title, body, kind)
			world.notices[#world.notices + 1] = { title, body, kind }
			return true
		end }
		local function publish(path, content, expected, _, admission)
			if admission and admission() ~= true then return false, "admission refused" end
			local fh = io.open(path, "rb")
			local actual = fh and fh:read("*a") or nil
			if fh then fh:close() end
			if (expected.status == "absent" and actual ~= nil)
				or (expected.status == "ok" and actual ~= expected.content) then
				return false, "source changed"
			end
			world.writes[#world.writes + 1] = { path = path, expected = expected.status }
			write_file(path, content)
			return true
		end
		package.loaded["core.fs.adapters.file_system"] = {
			read_with_status = function(path)
				local fh = io.open(path, "rb")
				if not fh then return nil, "absent" end
				local content = fh:read("*a")
				fh:close()
				return content, "ok"
			end,
			write = function() error("the save must publish against the content it read") end,
			write_if_unchanged = publish,
			write_if_unchanged_admitted = publish,
		}
		-- The remap facade, holding the shipped tap-hold keys and defaults.
		local defaults = TomlCodec.decode(read_file(helpers.shared("tap_hold/data/defaults.toml")))
		world.karabiner = {
			regenerate = function(on_done)
				world.regenerations = world.regenerations + 1
				world.on_done = on_done
				return world.regenerate_accepts
			end,
			TAP_HOLD_KEYS = Json.decode(read_file(helpers.driver_root() .. "/platform/remap/data/tap_hold_keys.json")),
			get_hold_action = function(id)
				local slot = defaults.hs_tap_hold[id]
				return slot and slot.hold or "none"
			end,
		}
		package.loaded["modules.keymap.nav_layer_save"] = nil
		scenario(require("modules.keymap.nav_layer_save"), world)
	end, debug.traceback)
	for _, name in ipairs(names) do package.loaded[name] = saved[name] end
	remove_config_dir(world.dir)
	if not ok then error(err, 0) end
end





-- =======================================
-- =======================================
-- ======= 2/ The window-free save =======
-- =======================================
-- =======================================

helpers.describe("macOS navigation layer save", function()
	helpers.it("applies the layout editor's navigation layer with no window (layout-editor-nav-apply)", function()
		with_save(function(save, world)
			local text = read_file(FIXTURE)
			local result = save.apply_text(text, { karabiner = world.karabiner })
			helpers.assert_eq(result.saved, true)
			helpers.assert_eq(result.applied, true)
			helpers.assert_eq(#world.writes, 1)
			helpers.assert_eq(world.writes[1].expected, "absent", "published against the file it read now")
			helpers.assert_eq(read_file(world.dir .. "/layers.toml"), text)
			helpers.assert_eq(world.regenerations, 1)
			helpers.assert_eq(world.wheel_reconciles, 1)
			-- A second apply replaces exactly the bytes it reads.
			helpers.assert_eq(save.apply_text(text, { karabiner = world.karabiner }).saved, true)
			helpers.assert_eq(world.writes[2].expected, "ok")
			-- An invalid layer writes and regenerates nothing.
			local refused = save.apply_text('[_meta]\nschema_version = 1\n[layers.nav.all]\n"KeyA" = "format_disk"\n',
				{ karabiner = world.karabiner })
			helpers.assert_eq(refused.saved, false)
			helpers.assert_eq(codes(refused), "unknown_action")
			helpers.assert_eq(world.regenerations, 2)
			helpers.assert_eq(save.apply_text(text, {}).saved, false, "no remap facade, no save")
			helpers.assert_eq(#world.writes, 2)
		end)
	end)

	helpers.it("(leh-003-late-regeneration-failure) a regeneration failing after the save is notified", function()
		with_save(function(save, world)
			helpers.assert_eq(save.apply_text(read_file(FIXTURE), { karabiner = world.karabiner }).applied, true)
			helpers.assert_eq(#world.notices, 0, "nothing is notified while the regeneration runs")
			world.on_done(false, "karabiner_cli_failed")
			helpers.assert_eq(#world.notices, 1, "the late failure is notified")
			helpers.assert_eq(world.notices[1], { "layout_editor.title", "layout_editor.status.nav_not_applied", "error" })
			world.on_done(true)
			helpers.assert_eq(#world.notices, 1, "a success says nothing")
		end)
	end)

	helpers.it("gives Ergopti Studio the user's layer file, else the preset, and the layer key (studio-nav-entry)", function()
		local corpus = Json.decode(read_file(LEGENDS))
		with_save(function(save, world)
			local preset = read_file(helpers.shared("layouts/data/layers.recommended.toml"))
			local nav = save.studio_nav({ karabiner = world.karabiner })
			helpers.assert_eq(nav.text, preset, "no layers.toml: the preset is where the layer starts")
			helpers.assert_eq(nav.hold, corpus.recommended_layer_keys.macos[1], "the key whose hold enters the layer")
			write_file(world.dir .. "/layers.toml", read_file(FIXTURE))
			helpers.assert_eq(save.studio_nav({ karabiner = world.karabiner }).text, read_file(FIXTURE),
				"the user's own file when there is one")
			helpers.assert_true(not pcall(save.studio_nav, {}), "no remap facade, no layer key: refused")
		end)
	end)
end)
