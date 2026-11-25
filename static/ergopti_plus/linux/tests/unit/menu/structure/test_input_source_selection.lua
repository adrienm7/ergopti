--- tests/unit/menu/structure/test_input_source_selection.lua

--- ==============================================================================
--- MODULE: Input Source Tray Selection Receipts
--- DESCRIPTION:
--- Exercises the actual layout menu provider and renderer: the « Sources de
--- saisie » rows switch the desktop to an installed registry layout, and their
--- ticks follow the desktop's acknowledged reading, never the click. The former
--- « Disposition personnalisée » list did the same switch through the layout
--- registry; the 2026-11-19 menu rework left that switch to the input sources,
--- while « Disposition à émuler » names the registry layouts as emulations.
--- Only the desktop switcher and the dialog host are controlled.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("core.text.engine.json")

-- Modules the scenario reloads so the tray root captures its controlled ports.
local RELOADED = { "modules.keymap.layout_registry", "menu.ui.builder.builder", "core.ui.ui.modal" }

--- Runs the real layout owner over a controlled desktop switcher.
--- @param options table { deferred?, failure?, listener? }
--- @param body function Receives the world: the rendered menu and the native settlement.
local function scenario(options, body)
	local previous = {}
	for _, name in ipairs(RELOADED) do
		previous[name] = package.loaded[name]
		package.loaded[name] = nil
	end
	local execute = os.execute
	local world = { redraws = 0, calls = {}, dialogs = {} }
	-- The dialog host is recorded and answered; the tray never opens a window here.
	package.loaded["core.ui.ui.modal"] = { run = function(callback) return callback() end }
	os.execute = function(command)
		if type(command) == "string" and command:find("dialog_host.lua", 1, true) then
			world.dialogs[#world.dialogs + 1] = command
			return 0
		end
		return execute(command)
	end
	local ok, detail = xpcall(function()
		local registry = require("modules.keymap.layout_registry")
		local file = assert(io.open(helpers.driver_root() .. "/../../layouts/registry/index.json", "rb"))
		local catalogue = assert(Json.decode(file:read("*a")))
		assert(file:close())
		local installed, names = {}, {}
		for _, entry in ipairs(catalogue.layouts) do
			if entry.id == "ergol" or entry.id == "ergopti" then installed[entry.id], names[entry.id] = entry, entry.name end
		end
		assert(names.ergol and names.ergopti)
		world.names = names
		local content = Json.encode({ schema_version = 1, layouts = installed })
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
		}
		local native_snapshot = registry.snapshot
		package.loaded["modules.keymap.layout_registry"] = {
			snapshot = function() return native_snapshot(deps) end,
			select = function() error("the tray no longer switches through the layout registry", 0) end,
		}

		-- The desktop: the two installed registry layouts are its input sources.
		-- `reading` is what the switcher last read; only a refresh updates it.
		local desktop = { active = "ergol" }
		local reading = { active = "ergol" }
		local switcher = {
			backend = function() return "gnome" end,
			choices = function()
				return {
					{ id = "ergol", label = names.ergol, active = reading.active == "ergol" },
					{ id = "ergopti", label = names.ergopti, active = reading.active == "ergopti" },
				}
			end,
			refresh = function(on_done)
				local changed = reading.active ~= desktop.active
				reading.active = desktop.active
				on_done(changed)
			end,
			select = function(id, on_done)
				world.calls[#world.calls + 1] = id
				local function answer(success)
					if success then desktop.active = id end
					on_done(success, success and nil or "refused", nil)
				end
				if world.deferred then world.pending = answer else answer(not world.failure) end
			end,
		}

		local builder, layouts = require("menu.ui.builder.builder"), nil
		local index = 1
		while true do
			local name, value = debug.getupvalue(builder.build, index)
			if name == nil then break end
			if name == "_build_layouts" then assert(layouts == nil); layouts = value end
			index = index + 1
		end
		assert(type(layouts) == "function", "the actual registered layout provider is required")
		local renderer = require("menu.engine.manifest_menu")
		local context = { layout = "qwerty", pause_layout = { switcher = function() return switcher end } }
		function world.render()
			world.menu = assert(renderer.render_rows({ assert(layouts(context)) }, "input-source-selection")[1])
		end
		if options.listener ~= false then
			context.on_menu_changed = function() world.redraws = world.redraws + 1; world.render() end
		end
		-- An input source is a row of the layout menu itself; the same names also
		-- appear inside the pause pickers and the emulation submenu.
		function world.source(id)
			for _, item in ipairs(world.menu.menu or {}) do
				if item.title == names[id] and item.menu == nil then return item end
			end
			error("no input source row named " .. tostring(names[id]), 0)
		end
		function world.settle(success)
			local answer = assert(world.pending)
			world.pending = nil
			answer(success)
		end
		function world.active() return reading.active end
		world.render()
		world.deferred = options.deferred
		world.failure = options.failure
		body(world)
	end, debug.traceback)
	os.execute = execute
	for _, name in ipairs(RELOADED) do package.loaded[name] = previous[name] end
	if not ok then error(detail, 0) end
end

--- Asserts the dialogs the tray asked for: one error per refused switch.
--- @param world table
--- @param refusals number
local function assert_refusals(world, refusals)
	helpers.assert_eq(#world.dialogs, refusals, "each refused switch is told once, and only then")
	local told = require("core.i18n.engine.i18n").get("menu.layout.select_failed")
	for _, command in ipairs(world.dialogs) do
		helpers.assert_true(command:find(" --error", 1, true) ~= nil, command)
		helpers.assert_true(command:find(told, 1, true) ~= nil, command)
	end
end

helpers.describe("input source tray selection acknowledgement", function()
	for _, deferred in ipairs({ false, true }) do
		for _, success in ipairs({ false, true }) do
			helpers.it("(input-source-menu-ack) publishes acknowledged checks deferred=" .. tostring(deferred) .. " success=" .. tostring(success), function()
				scenario({ deferred = deferred, failure = not success }, function(world)
					helpers.assert_true(world.source("ergol").checked)
					helpers.assert_eq(world.source("ergopti").checked, false)
					world.source("ergopti").fn()
					helpers.assert_eq(world.calls, { "ergopti" })
					if deferred then
						helpers.assert_eq(world.active(), "ergol")
						helpers.assert_eq(world.redraws, 0, "pending activation cannot publish optimistic checks")
						world.render()
						helpers.assert_true(world.source("ergol").checked)
						helpers.assert_eq(world.source("ergopti").checked, false)
						world.settle(success)
					end
					helpers.assert_eq(world.active(), success and "ergopti" or "ergol")
					-- Every answer re-reads the desktop, a refusal included, so the
					-- ticks are the desktop's own and never the click's.
					helpers.assert_eq(world.redraws, 1, "the answer rebuilds the menu once from a fresh reading")
					helpers.assert_eq(world.source("ergopti").checked, success, "the menu must mark the actual active layout")
					helpers.assert_eq(world.source("ergol").checked, not success)
					assert_refusals(world, success and 0 or 1)
				end)
			end)
		end
	end

	helpers.it("(input-source-menu-ack) retains the last successful checks after the next switch fails", function()
		scenario({ deferred = true }, function(world)
			world.source("ergopti").fn(); world.settle(true)
			helpers.assert_eq(world.redraws, 1)
			helpers.assert_true(world.source("ergopti").checked)
			world.source("ergol").fn()
			helpers.assert_eq(world.redraws, 1)
			world.settle(false)
			helpers.assert_eq(world.active(), "ergopti")
			helpers.assert_true(world.source("ergopti").checked)
			helpers.assert_eq(world.source("ergol").checked, false)
			helpers.assert_eq(world.calls, { "ergopti", "ergol" })
			assert_refusals(world, 1)
		end)
	end)

	helpers.it("(input-source-menu-ack) permits a switch without an optional menu observer", function()
		scenario({ listener = false }, function(world)
			world.source("ergopti").fn()
			helpers.assert_eq(world.active(), "ergopti")
			helpers.assert_eq(world.redraws, 0)
			assert_refusals(world, 0)
		end)
	end)

	helpers.it("(input-source-menu-ack) names the registry layouts under « Disposition à émuler » without switching", function()
		scenario({}, function(world)
			local caption = require("core.i18n.engine.i18n").get("menu.layout.emulated_layout")
			local emulation
			for _, item in ipairs(world.menu.menu or {}) do
				if type(item.title) == "string" and item.title:find(caption, 1, true) == 1 then emulation = item end
			end
			helpers.assert_true(type(emulation) == "table" and type(emulation.menu) == "table",
				"the emulation submenu is drawn")
			local listed = {}
			for _, item in ipairs(emulation.menu) do listed[item.title] = item end
			-- Never chosen yet, the installed registry layout is one of « Others… »,
			-- the picker of every layout (maintainer decision of 2026-11-25).
			local i18n = require("core.i18n.engine.i18n")
			helpers.assert_true(listed[i18n.get("menu.layout.emulation_others")] ~= nil,
				"the installed registry layout can be emulated from « Others… »")
			helpers.assert_nil(listed[world.names.ergol], "a layout never chosen is no quick choice")
			helpers.assert_true(listed[i18n.get("onboarding.layout.emulated_none")].checked,
				"no emulation is chosen by the fixture")
			helpers.assert_eq(#world.calls, 0, "drawing the menu switches nothing")
		end)
	end)
end)
