--- tests/unit/ui/menu/structure/test_custom_layout_selection.lua

--- ==============================================================================
--- MODULE: Custom Layout Tray Selection Receipts
--- DESCRIPTION:
--- Exercises the actual layout menu provider, renderer and registry selection.
--- The installed record follows the shipped catalogue; only process completion
--- is controlled so the tray must wait for native acknowledgement before it
--- replaces the old authoritative checks.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")

--- Runs the real layout owner with a controlled installer completion port.
--- @param options table { deferred?, failure?, listener? }
--- @param body function Receives the current rendered menu and native settlement.
local function scenario(options, body)
	local previous = {}
	for _, name in ipairs({ "modules.keymap.layout_registry", "ui.menu.menu_builder" }) do
		previous[name] = package.loaded[name]
		package.loaded[name] = nil
	end
	local ok, detail = xpcall(function()
		local registry = require("modules.keymap.layout_registry")
		local file = assert(io.open(helpers.driver_root() .. "/../../layouts/registry/index.json", "rb"))
		local catalogue = assert(Json.decode(file:read("*a")))
		assert(file:close())
		local installed = {}
		for _, entry in ipairs(catalogue.layouts) do
			if entry.id == "ergol" or entry.id == "ergopti" then installed[entry.id] = entry end
		end
		assert(installed.ergol and installed.ergopti)
		local content = Json.encode({ schema_version = 1, layouts = installed })
		local world = { redraws = 0, calls = 0 }
		local deps = {
			settings = { installed_file = "installed.json" },
			local_dir = "/fixture/layouts/", installer = "/fixture/installer.py",
			decode_json = Json.decode, encode_json = Json.encode,
			read = function(path) if path == "/fixture/layouts/installed.json" then return content end end,
			exists = function(path)
				return path == "/fixture/layouts/installed.json" or path == "/fixture/layouts/ergol.keylayout"
					or path == "/fixture/layouts/ergopti.keylayout"
			end,
			translate = function(key) return key end,
			run = function(_, args, _, callback)
				if args[1] == "-c" then callback({ exit_code = 0, stdout = "", stderr = "" })
				elseif world.deferred then world.pending = callback
				else callback(world.result or { exit_code = 0, stdout = '{"ok":true,"verified":true}', stderr = "" }) end
				return true
			end,
		}
		assert(registry.select("ergol", function(selected) assert(selected) end, deps))
		local native_snapshot, native_select = registry.snapshot, registry.select
		package.loaded["modules.keymap.layout_registry"] = {
			snapshot = function() return native_snapshot(deps) end,
			select = function(id, done)
				world.calls = world.calls + 1
				return native_select(id, done, deps)
			end,
		}
		local builder, layouts = require("ui.menu.menu_builder"), nil
		local index = 1
		while true do
			local name, value = debug.getupvalue(builder.build, index)
			if name == nil then break end
			if name == "_build_layouts" then assert(layouts == nil); layouts = value end
			index = index + 1
		end
		assert(type(layouts) == "function", "the actual registered layout provider is required")
		local renderer = require("infra.manifest_menu")
		local context = { layout = "qwerty" }
		function world.render()
			world.menu = assert(renderer.render_rows({ assert(layouts(context)) }, "custom-layout-selection")[1])
		end
		if options.listener ~= false then
			context.on_menu_changed = function() world.redraws = world.redraws + 1; world.render() end
		end
		function world.row(title, items)
			for _, item in ipairs(items or { world.menu }) do
				if item.title == title then return item end
				if item.menu then local found = world.row(title, item.menu); if found then return found end end
			end
		end
		function world.settle(success)
			local callback = assert(world.pending)
			world.pending = nil
			callback({ exit_code = success and 0 or 1, stdout = success and '{"ok":true,"verified":true}' or '{"ok":false,"detail":"refused"}', stderr = "" })
		end
		function world.active() return native_snapshot(deps).active end
		world.render()
		world.deferred = options.deferred
		if options.failure then world.result = { exit_code = 1, stdout = '{"ok":false,"detail":"refused"}', stderr = "" } end
		body(world)
	end, debug.traceback)
	for name, module in pairs(previous) do package.loaded[name] = module end
	for _, name in ipairs({ "modules.keymap.layout_registry", "ui.menu.menu_builder" }) do
		if previous[name] == nil then package.loaded[name] = nil end
	end
	if not ok then error(detail, 0) end
end

helpers.describe("custom layout tray selection acknowledgement", function()
	for _, deferred in ipairs({ false, true }) do
		for _, success in ipairs({ false, true }) do
			helpers.it("(custom-layout-menu-ack) publishes acknowledged checks deferred=" .. tostring(deferred) .. " success=" .. tostring(success), function()
				scenario({ deferred = deferred, failure = not success }, function(world)
					helpers.assert_true(world.row("Ergo-L").checked)
					helpers.assert_eq(world.row("Ergopti").checked, false)
					world.row("Ergopti").fn()
					helpers.assert_eq(world.calls, 1)
					if deferred then
						helpers.assert_eq(world.active(), "ergol")
						helpers.assert_eq(world.redraws, 0, "pending activation cannot publish optimistic checks")
						helpers.assert_true(world.row("Ergo-L").checked)
						helpers.assert_eq(world.row("Ergopti").checked, false)
						world.settle(success)
					end
					helpers.assert_eq(world.active(), success and "ergopti" or "ergol")
					helpers.assert_eq(world.redraws, success and 1 or 0, "only acknowledged activation must rebuild the menu")
					helpers.assert_eq(world.row("Ergopti").checked, success, "the menu must mark the actual active registry layout")
					helpers.assert_eq(world.row("Ergo-L").checked, not success)
				end)
			end)
		end
	end

	helpers.it("(custom-layout-menu-ack) retains the last successful checks after the next activation fails", function()
		scenario({ deferred = true }, function(world)
			world.row("Ergopti").fn(); world.settle(true)
			helpers.assert_eq(world.redraws, 1)
			helpers.assert_true(world.row("Ergopti").checked)
			world.row("Ergo-L").fn()
			helpers.assert_eq(world.redraws, 1)
			world.settle(false)
			helpers.assert_eq(world.active(), "ergopti")
			helpers.assert_eq(world.redraws, 1)
			helpers.assert_true(world.row("Ergopti").checked)
			helpers.assert_eq(world.row("Ergo-L").checked, false)
		end)
	end)

	helpers.it("(custom-layout-menu-ack) permits registry activation without an optional menu observer", function()
		scenario({ listener = false }, function(world)
			world.row("Ergopti").fn()
			helpers.assert_eq(world.active(), "ergopti")
			helpers.assert_eq(world.redraws, 0)
		end)
	end)
end)
