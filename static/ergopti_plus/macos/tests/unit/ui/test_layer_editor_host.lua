--- tests/unit/ui/test_layer_editor_host.lua

--- ==============================================================================
--- MODULE: Navigation Layer Editor Host (macOS)
--- DESCRIPTION:
--- Drives ui/layer_editor through its bridge the way the shared page does, with
--- the real shared host logic, loader and TOML codec, and native doubles for the
--- window, the file adapter and the remap facade.
---
--- COVERAGE:
--- 1. "ready" sends the user's file, and the problems every OS's loader finds.
--- 2. A save is refused, and nothing is written or regenerated, when the text
---    is not a string, is too large, names an action outside the vocabulary,
---    or binds something one of the three OSes cannot resolve.
--- 3. End to end: the page's scripted session (_shared/tests/corpus/
---    layer_editor/edited_layers.toml) is published through the atomic
---    adapter, the Karabiner rules are regenerated, the window closes, and the
---    navigation layer then generated from the folder carries every macOS edit.
--- 4. A refused regeneration keeps the window open; Cancel closes it, and a
---    message from a closed window does nothing.
--- ==============================================================================

local helpers   = require("tests.helpers")
local Json      = require("json")

local FIXTURE = helpers.shared("tests/corpus/layer_editor/edited_layers.toml")





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
	local dir = helpers.temp_dir() .. "/ergopti_layer_editor_" .. tostring(os.time()) .. "_"
		.. tostring(math.random(100000, 999999))
	local ok_mkdir = os.execute('mkdir "' .. dir .. '"')
	helpers.assert_true(ok_mkdir == true or ok_mkdir == 0, "sandbox directory must exist")
	return dir
end

local function remove_config_dir(dir)
	os.remove(dir .. "/layers.toml")
	os.execute('rmdir "' .. dir .. '"')
end

--- Loads a fresh editor with native doubles and runs one scenario.
--- @param scenario function(editor, world)
local function with_editor(scenario)
	local names = { "infra.logger", "infra.i18n", "infra.paths", "infra.config_paths", "adapters.file_system",
		"ui.ui_builder", "ui.layer_editor", "platform.remap.nav_layer" }
	local saved = {}
	for _, name in ipairs(names) do saved[name] = package.loaded[name] end
	local prior_hs = _G.hs
	local world = { dir = make_config_dir(), bridges = {}, views = {}, writes = {}, regenerations = 0,
		regenerate_accepts = true, logs = {} }
	local ok, err = xpcall(function()
		local logger = {}
		for _, level in ipairs({ "trace", "debug", "done", "info", "start", "success", "warn", "error" }) do
			logger[level] = function(_, message, ...)
				local ok_fmt, text = pcall(string.format, message, ...)
				world.logs[#world.logs + 1] = level .. ": " .. (ok_fmt and text or tostring(message))
			end
		end
		package.loaded["infra.logger"] = logger
		package.loaded["infra.i18n"] = { get = function(key) return key end }
		package.loaded["infra.paths"] = {
			shared_root = function() return helpers.shared() end,
			shared = function(rel) return helpers.shared(rel) end,
		}
		package.loaded["infra.config_paths"] = { get_config_dir = function() return world.dir end }
		package.loaded["adapters.file_system"] = {
			read_with_status = function(path)
				local fh = io.open(path, "rb")
				if not fh then return nil, "absent" end
				local content = fh:read("*a")
				fh:close()
				return content, "ok"
			end,
			write = function() error("the editor must publish against the content it read") end,
			write_if_unchanged = function(path, content, expected)
				world.writes[#world.writes + 1] = { path = path, expected = expected and expected.status }
				write_file(path, content)
				return true
			end,
		}
		package.loaded["ui.ui_builder"] = {
			get_app_geometry = function(id)
				world.geometry_id = id
				return { width = 1100, height = 760 }
			end,
			get_centered_frame = function(w, h) return { w = w, h = h } end,
			force_focus = function(view, is_new, lifecycle)
				view.fronted = is_new == false and lifecycle.is_current() == true
				return true
			end,
			show_webview = function(options)
				local view = { scripts = {}, deleted = false, options = options }
				function view:evaluateJavaScript(js) self.scripts[#self.scripts + 1] = js end
				function view:delete()
					self.deleted = true
					options.on_close()
				end
				function view:bringToFront() error("bringToFront pins the editor above other apps") end
				world.views[#world.views + 1] = view
				return view
			end,
		}
		_G.hs = { webview = { usercontent = { new = function(name)
			local bridge = { name = name }
			function bridge:setCallback(callback) self.callback = callback end
			world.bridges[#world.bridges + 1] = bridge
			return bridge
		end } } }
		world.karabiner = { regenerate = function()
			world.regenerations = world.regenerations + 1
			return world.regenerate_accepts
		end }
		package.loaded["ui.layer_editor"] = nil
		scenario(require("ui.layer_editor"), world)
	end, debug.traceback)
	for _, name in ipairs(names) do package.loaded[name] = saved[name] end
	_G.hs = prior_hs
	remove_config_dir(world.dir)
	if not ok then error(err, 0) end
end

--- Posts a message from the page of the n-th window.
local function post(world, body, index)
	world.bridges[index or #world.bridges].callback({ body = body })
end

--- The payload of the last call the page received to one of its functions.
local function last_call(world, fn_name, index)
	local view = world.views[index or #world.views]
	for i = #view.scripts, 1, -1 do
		local payload = view.scripts[i]:match("window%." .. fn_name .. "%((.*)%)$")
		if payload then return Json.decode(payload) end
	end
	return nil
end

--- Every error code of a payload's errors, sorted and joined.
local function codes(payload)
	local out = {}
	for _, err in ipairs(payload.errors or {}) do out[#out + 1] = err.code end
	table.sort(out)
	return table.concat(out, ",")
end





-- =============================
-- =============================
-- ======= 2/ The bridge =======
-- =============================
-- =============================

helpers.describe("macOS navigation layer editor host", function()
	helpers.it("opens the shared page on its own bridge and sends the user's file on ready", function()
		with_editor(function(editor, world)
			write_file(world.dir .. "/layers.toml",
				'[_meta]\nschema_version = 1\n\n[layers.nav.all]\n"Space" = "spotlight"\n')
			helpers.assert_eq(editor.open({ karabiner = world.karabiner }), true)
			helpers.assert_eq(world.bridges[1].name, "layer_editor_bridge")
			helpers.assert_eq(world.geometry_id, "layer_editor")
			helpers.assert_true(world.views[1].options.assets_dir:match("_shared/ui/layer_editor/$") ~= nil,
				"the window loads the shared page")
			post(world, "ready")
			local init = last_call(world, "init")
			helpers.assert_not_nil(init, "ready must call init()")
			helpers.assert_eq(init.os, "macos")
			helpers.assert_eq(init.path, world.dir .. "/layers.toml")
			helpers.assert_true(init.text:match('"Space" = "spotlight"') ~= nil, "init() carries the file's text")
			-- Spotlight exists on macOS only: the other two OSes' loaders refuse it,
			-- and the one error they share is reported once.
			helpers.assert_eq(codes(init), "unavailable_on_os")
			helpers.assert_eq(editor.open({ karabiner = world.karabiner }), true)
			helpers.assert_eq(#world.views, 1, "a second open brings the window to the front")
			helpers.assert_eq(world.views[1].fronted, true,
				"the open window is presented by the shared focus helper (ui-focus-not-topmost)")
		end)
	end)

	helpers.it("refuses, writes nothing and regenerates nothing for an invalid save", function()
		with_editor(function(editor, world)
			editor.open({ karabiner = world.karabiner })
			local refused = {
				{ text = nil, code = "invalid_payload" },
				{ text = 42, code = "invalid_payload" },
				{ text = string.rep("#", 70000), code = "invalid_payload" },
				{ text = '[_meta]\nschema_version = 1\n[layers.nav.all]\n"KeyA" = "format_disk"\n', code = "unknown_action" },
				{ text = '[_meta]\nschema_version = 1\n[layers.nav.all]\n"KeyA" = "keystroke:fn+KeyB"\n',
					code = "unavailable_on_os" },
				{ text = '[_meta]\nschema_version = 1\n[layers.nav.all]\n"KeyA" = { a = 1 }\n', code = "toml_invalid" },
			}
			helpers.assert_true(#refused >= 6, "every refusal kind is covered")
			for _, case in ipairs(refused) do
				post(world, { action = "save", text = case.text })
				local result = last_call(world, "saveResult")
				helpers.assert_eq(result.saved, false)
				helpers.assert_eq(codes(result), case.code)
			end
			helpers.assert_eq(#world.writes, 0, "a refused save writes nothing")
			helpers.assert_eq(world.regenerations, 0, "a refused save regenerates nothing")
			helpers.assert_eq(world.views[1].deleted, false, "a refused save keeps the window open")
			helpers.assert_nil(io.open(world.dir .. "/layers.toml", "rb"), "no layers.toml was created")
		end)
	end)

	helpers.it("publishes the page's session, regenerates, closes, and the generated layer carries it (e2e)", function()
		with_editor(function(editor, world)
			local text = read_file(FIXTURE)
			editor.open({ karabiner = world.karabiner })
			post(world, { action = "save", text = text })
			local result = last_call(world, "saveResult")
			helpers.assert_eq(result.saved, true)
			helpers.assert_eq(result.applied, true)
			helpers.assert_eq(#world.writes, 1)
			helpers.assert_eq(world.writes[1].path, world.dir .. "/layers.toml")
			helpers.assert_eq(world.writes[1].expected, "absent", "published against the absent file it read")
			helpers.assert_eq(read_file(world.dir .. "/layers.toml"), text)
			helpers.assert_eq(world.regenerations, 1)
			helpers.assert_eq(world.views[1].deleted, true, "a saved and applied layer closes the window")

			local NavLayer = helpers.load_with_stubs("platform.remap.nav_layer")
			local layer = NavLayer.load({ shared_root = helpers.shared(), config_dir = world.dir })
			local rule = NavLayer.build_rule(layer.bindings, layer.registry)
			local sent = {}
			for _, m in ipairs(rule.manipulators) do
				local to = m.to and m.to[1]
				if to then
					local mods = {}
					for _, mod in ipairs(to.modifiers or {}) do mods[#mods + 1] = mod end
					table.sort(mods)
					sent[m.from.key_code or m.from.pointing_button] = tostring(to.key_code or to.pointing_button) .. "[" .. table.concat(mods, ",") .. "]"
				end
			end
			helpers.assert_eq(sent.t, "z[command,shift]", "KeyT: the macOS edit, ⌘⇧Z")
			helpers.assert_eq(sent.g ~= nil and sent.g:match("^f12") ~= nil, true, "KeyG keeps F12 on macOS")
			helpers.assert_eq(sent.q, "up_arrow[command,shift]", "an untouched key keeps its recommended binding")
		end)
	end)

	helpers.it("keeps the window open when the regeneration is refused, and Cancel closes it", function()
		with_editor(function(editor, world)
			world.regenerate_accepts = false
			editor.open({ karabiner = world.karabiner })
			post(world, { action = "save", text = read_file(FIXTURE) })
			local result = last_call(world, "saveResult")
			helpers.assert_eq(result.saved, true)
			helpers.assert_eq(result.applied, false)
			helpers.assert_eq(world.views[1].deleted, false, "a layer not applied keeps the window open")
			-- A message WebKit had already queued when the window closed still
			-- reaches the callback it was bound to.
			local stale = world.bridges[1].callback
			post(world, { action = "cancel" })
			helpers.assert_eq(world.views[1].deleted, true)
			helpers.assert_nil(world.bridges[1].callback, "closing releases the bridge")
			local before = #world.views[1].scripts
			stale({ body = "ready" })
			stale({ body = { action = "save", text = read_file(FIXTURE) } })
			helpers.assert_eq(#world.views[1].scripts, before, "a closed window's messages do nothing")
			helpers.assert_eq(world.regenerations, 1)
		end)
	end)

	helpers.it("refuses to open without a remap facade to apply the layer", function()
		with_editor(function(editor, world)
			helpers.assert_eq(editor.open({}), false)
			helpers.assert_eq(#world.views, 0)
		end)
	end)
end)
