--- tests/unit/ui/menu/structure/test_menu_rebuild_owner.lua

--- ==============================================================================
--- MODULE: Deferred Tray Publication Ownership
--- DESCRIPTION:
--- Exercises duplicate refreshes, live callback authority, native refusal and
--- reentrant publishers without replacing GTK's independent ID ownership.
--- ==============================================================================

local helpers = require("tests.helpers")
local Factory = dofile(helpers.driver_root() .. "/ui/menu/rebuild_owner.lua")

local function fixture()
	local state = { builds = 0, publications = 0, actions = 0, errors = {}, value = "initial", active = true, lost = 0 }
	state.options = {
		current = function() return state.active end,
		build = function()
			state.builds = state.builds + 1
			local value = state.value
			state.original = { { title = value, menu = { { title = "Action", fn = function(argument)
				state.actions = state.actions + 1
				return value, argument
			end } } } }
			return state.original, value
		end,
		publish = function(items)
			state.publications = state.publications + 1
			state.visible = items
			return true
		end,
		on_error = function(reason) state.errors[#state.errors + 1] = reason end,
		notify_lost = function() state.lost = state.lost + 1; return true end,
	}
	return state
end

helpers.describe("menu rebuild: coalesced publication owner", function()
	helpers.it("coalesces a callback burst and publishes only the latest committed context", function()
		local state = fixture()
		local owner = Factory.new(state.options)
		for _, value in ipairs({ "first", "second", "latest" }) do state.value = value; helpers.assert_true(owner.request()) end
		helpers.assert_eq(state.builds, 0); helpers.assert_eq(state.publications, 0)
		helpers.assert_true(owner.pump())
		helpers.assert_eq(state.builds, 1); helpers.assert_eq(state.publications, 1)
		local value, argument = state.visible[1].menu[1].fn("argument")
		helpers.assert_eq(value, "latest"); helpers.assert_eq(argument, "argument")
		helpers.assert_eq(owner.pump(), false)
		helpers.assert_eq(state.publications, 1)
	end)

	helpers.it("copies rows and revokes every old nested callback before a deferred rebuild", function()
		local state = fixture(); local owner = Factory.new(state.options)
		owner.request(); helpers.assert_true(owner.pump())
		local old, original = state.visible[1].menu[1].fn, state.original[1].menu[1].fn
		helpers.assert_true(old ~= original); helpers.assert_true(state.visible ~= state.original)
		owner.request(); helpers.assert_eq(old(), false); helpers.assert_eq(state.actions, 0)
		state.value = "fresh"; helpers.assert_true(owner.pump())
		helpers.assert_eq(old(), false); helpers.assert_eq(state.visible[1].menu[1].fn(), "fresh")
		helpers.assert_eq(state.actions, 1)
	end)

	helpers.it("rechecks generation after a current callback reenters refresh", function()
		local state = fixture(); local owner; local revoke = false
		state.options.current = function() if revoke then revoke = false; owner.request() end; return true end
		owner = Factory.new(state.options); owner.request(); helpers.assert_true(owner.pump())
		revoke = true; helpers.assert_eq(state.visible[1].menu[1].fn(), false)
		helpers.assert_eq(state.actions, 0)
	end)

	helpers.it("fences current and builder reentrance and retains a newer dirty generation", function()
		local state = fixture(); local owner; local initial = state.options.build; local reenter = true
		state.options.current = function() helpers.assert_eq(owner.pump(), false); return true end
		state.options.build = function()
			local items = initial()
			if reenter then reenter = false; owner.request(); helpers.assert_eq(owner.pump(), false) end
			return items
		end
		owner = Factory.new(state.options); owner.request(); helpers.assert_eq(owner.pump(), false)
		helpers.assert_eq(state.publications, 0)
		helpers.assert_true(owner.pump()); helpers.assert_eq(state.publications, 1)
	end)

	for _, failure in ipairs({ "false", "throw" }) do
		local mode = failure
		helpers.it("retains publication debt after native " .. mode .. " and retries once per pump", function()
			local state = fixture(); local owner; local refuse = true; local publish = state.options.publish
			state.options.publish = function(items)
				helpers.assert_eq(items[1].menu[1].fn(), false, "candidate cannot act before publication ACK")
				if refuse then
					state.publications = state.publications + 1
					if mode == "throw" then error("native refusal") end
					return false
				end
				return publish(items)
			end
			state.options.on_error = function(reason)
				state.errors[#state.errors + 1] = reason; helpers.assert_eq(owner.pump(), false)
			end
			owner = Factory.new(state.options); owner.request()
			for pass = 1, 3 do helpers.assert_eq(owner.pump(), false); helpers.assert_eq(state.publications, pass) end
			helpers.assert_eq(#state.errors, 1); helpers.assert_eq(state.errors[1], "publication-refused")
			refuse = false; helpers.assert_true(owner.pump())
			helpers.assert_eq(state.visible[1].menu[1].fn(), "initial")
		end)
	end

	helpers.it("does not acknowledge an intermediate menu when publish requests a successor", function()
		local state = fixture(); local owner; local initial = state.options.publish; local reenter = true
		state.options.publish = function(items)
			initial(items)
			if reenter then reenter = false; owner.request() end
			return true
		end
		owner = Factory.new(state.options); owner.request(); helpers.assert_eq(owner.pump(), false)
		local retired = state.visible[1].menu[1].fn
		helpers.assert_eq(retired(), false); helpers.assert_true(owner.pump())
		helpers.assert_eq(retired(), false); helpers.assert_eq(state.visible[1].menu[1].fn(), "initial")
	end)

	helpers.it("keeps a stopped publisher terminal even when it reports native success", function()
		local state = fixture(); local owner
		state.options.publish = function(items) state.visible = items; owner.stop(); return true end
		owner = Factory.new(state.options); owner.request(); helpers.assert_eq(owner.pump(), false)
		helpers.assert_eq(state.visible[1].menu[1].fn(), false)
		helpers.assert_eq(owner.request(), false); helpers.assert_eq(owner.pump(), false)
		helpers.assert_true(owner.stop())
	end)

	helpers.it("stops pending work without calling the builder or native publisher", function()
		local state = fixture(); local owner = Factory.new(state.options)
		owner.request(); helpers.assert_true(owner.stop()); helpers.assert_eq(owner.pump(), false)
		helpers.assert_eq(state.builds, 0); helpers.assert_eq(state.publications, 0)
	end)

	helpers.it("contains a failed or malformed builder and retries a corrected tree", function()
		local state = fixture(); local build = state.options.build; local broken = true
		state.options.build = function() if broken then return nil end; return build() end
		local owner = Factory.new(state.options); owner.request(); helpers.assert_eq(owner.pump(), false)
		helpers.assert_eq(state.publications, 0); helpers.assert_eq(state.errors[1], "build-refused")
		broken = false; helpers.assert_true(owner.pump())
	end)

	helpers.it("does not confuse an appearance refusal with native menu publication", function()
		local state = fixture()
		state.options.appearance = function() error("icon refused") end
		local owner = Factory.new(state.options); owner.request(); helpers.assert_true(owner.pump())
		helpers.assert_eq(state.errors[1], "appearance-refused")
		helpers.assert_eq(state.visible[1].menu[1].fn(), "initial")
		helpers.assert_eq(owner.pump(), false); helpers.assert_eq(state.publications, 1)
	end)

	helpers.it("does not acknowledge a successor requested by an appearance callback", function()
		local state = fixture(); local owner; local reenter = true
		state.options.appearance = function() if reenter then reenter = false; owner.request() end end
		owner = Factory.new(state.options); owner.request(); helpers.assert_eq(owner.pump(), false)
		helpers.assert_eq(state.visible[1].menu[1].fn(), false)
		helpers.assert_true(owner.pump())
	end)

	helpers.it("pins producer and publication functions instead of mutable option fields", function()
		local state = fixture(); local owner = Factory.new(state.options)
		state.options.build, state.options.publish, state.options.current = function() error("replacement") end, nil, nil
		owner.request(); helpers.assert_true(owner.pump()); helpers.assert_eq(state.publications, 1)
	end)
end)

--- A tray with one check row whose checkmark reads a live switch.
local function check_fixture()
	local state = { on = false, runs = 0, lost = 0, visible = nil }
	state.options = {
		current = function() return true end,
		build = function()
			local shown = state.on
			return { { title = "Features", menu = { { title = "Preview", checked = shown, fn = function()
				state.runs = state.runs + 1
				state.on = not state.on
				return state.on
			end } } } }
		end,
		publish = function(items) state.visible = items; return true end,
		notify_lost = function() state.lost = state.lost + 1; return true end,
	}
	return state
end

helpers.describe("menu rebuild: clicks during a refresh", function()
	helpers.it("(menu-click-held-during-refresh) replays a retired-row click on the refreshed menu", function()
		local state = fixture(); local owner = Factory.new(state.options)
		owner.request(); helpers.assert_true(owner.pump())
		local old = state.visible[1].menu[1].fn
		state.value = "initial"; owner.request()
		helpers.assert_eq(old("argument"), false, "the retired row does not run its own action")
		helpers.assert_eq(state.actions, 0)
		helpers.assert_true(owner.pump())
		helpers.assert_eq(state.actions, 1, "the held click ran once on the refreshed menu")
		helpers.assert_eq(state.lost, 0)
		helpers.assert_true(owner.pump() == false); helpers.assert_eq(state.actions, 1, "a held click runs once")
	end)

	helpers.it("(menu-click-intent-skip) skips a held check-row click whose row already shows its state", function()
		local state = check_fixture(); local owner = Factory.new(state.options)
		owner.request(); helpers.assert_true(owner.pump())
		local first, second = state.visible[1].menu[1].fn, state.visible[1].menu[1].fn
		helpers.assert_eq(first(), true, "the first click turns the row on")
		owner.request()
		helpers.assert_eq(second(), false, "a second click on the stale unchecked row is held")
		helpers.assert_true(owner.pump())
		helpers.assert_eq(state.runs, 1, "the held click asked for checked, which the row already shows")
		helpers.assert_eq(state.on, true, "the switch is not toggled back")
	end)

	helpers.it("(menu-click-intent-run) runs a held check-row click whose row still lacks its state", function()
		local state = check_fixture(); local owner = Factory.new(state.options)
		owner.request(); helpers.assert_true(owner.pump())
		local stale = state.visible[1].menu[1].fn
		owner.request()
		helpers.assert_eq(stale(), false)
		helpers.assert_true(owner.pump())
		helpers.assert_eq(state.runs, 1); helpers.assert_eq(state.on, true)
	end)

	helpers.it("(menu-click-lost-notice) reports a held click whose row the refreshed menu lacks", function()
		local state = fixture(); local owner = Factory.new(state.options)
		owner.request(); helpers.assert_true(owner.pump())
		local old = state.visible[1].menu[1].fn
		state.value = "renamed"; owner.request(); old()
		helpers.assert_true(owner.pump())
		helpers.assert_eq(state.actions, 0, "a click never runs on a different row")
		helpers.assert_eq(state.lost, 1, "the user is told the click was not applied")
	end)

	helpers.it("(menu-click-held-retry) keeps a held click across a refused publication", function()
		local state = fixture(); local refuse = true; local publish = state.options.publish
		state.options.publish = function(items) if refuse then return false end; return publish(items) end
		local owner = Factory.new(state.options)
		refuse = false; owner.request(); helpers.assert_true(owner.pump())
		local old = state.visible[1].menu[1].fn
		refuse = true; owner.request(); old()
		helpers.assert_eq(owner.pump(), false); helpers.assert_eq(state.actions, 0)
		refuse = false; helpers.assert_true(owner.pump())
		helpers.assert_eq(state.actions, 1)
	end)

	helpers.it("(menu-click-dropped-logged) logs a click dropped by a stopped tray", function()
		local warnings = {}
		local previous = package.loaded["logger.shim"]
		package.loaded["logger.shim"] = { info = function() end, error = function() end,
			warn = function(_, fmt, ...) warnings[#warnings + 1] = string.format(fmt, ...) end }
		local ok, err = pcall(function()
			local Owner = dofile(helpers.driver_root() .. "/ui/menu/rebuild_owner.lua")
			local state = fixture(); local owner = Owner.new(state.options)
			owner.request(); helpers.assert_true(owner.pump())
			local old = state.visible[1].menu[1].fn
			owner.request(); old()
			helpers.assert_true(owner.stop())
			helpers.assert_eq(state.actions, 0)
			helpers.assert_eq(#warnings, 1, "the held click is reported when the tray stops")
			helpers.assert_true(warnings[1]:find("Action", 1, true) ~= nil, warnings[1])
			old()
			helpers.assert_eq(#warnings, 2, "a click on a stopped tray is reported")
		end)
		package.loaded["logger.shim"] = previous
		if not ok then error(err, 0) end
	end)
end)

local function compile(text, environment)
	if setfenv then
		local chunk = assert(loadstring(text, "actual-menu-wiring"))
		setfenv(chunk, environment)
		return chunk
	end
	return assert(load(text, "actual-menu-wiring", "t", environment))
end

helpers.describe("menu rebuild: actual Main and tray boundaries", function()
	helpers.it("publishes the initial Main menu, coalesces callbacks and pumps after physical input", function()
		local file = assert(io.open(helpers.driver_root() .. "/ergopti_hotstrings.lua", "rb"))
		local source = file:read("*a"); file:close()
		local order, menus, stopped, checkpoints = {}, {}, false, 0
		local environment = setmetatable({
			privacy_owners = { watch = { pump = function() end }, startup_checkpoint = function()
				checkpoints = checkpoints + 1
				helpers.assert_eq(#menus, 1, "checkpoint follows acknowledged initial publication")
				helpers.assert_eq(table.concat(order, ","), "build", "checkpoint precedes input pumping")
				return true
			end },
			shutdown = { is_requested = function() return stopped end, request = function() error("unexpected shutdown") end },
			menu_builder = { build = function(ctx)
				order[#order + 1] = "build"
				return { { title = "Action", fn = function() return "current" end } }
			end },
			tray_menu = { setMenu = function(items) menus[#menus + 1] = items; return true end,
				setPaused = function() end, pump = function() end },
			_build_menu_ctx = function() return { paused = false } end,
			Logger = { error = function() error("unexpected publication error") end }, LOG = "test",
			keyboard_hook = { isRunning = function() return true end, isRecovering = function() return false end,
				pump = function() order[#order + 1] = "keyboard" end },
			keylogger = { pump_flush = function() end },
			secure_focus_guard = { has_context_operation = function() return false end },
			RuntimeGuard = { call = function(_, callback) callback(); return true end },
			event_loop = { run = function(options) options.onIdle() end },
			stop_input_loop = function() error("unexpected input failure") end,
		}, { __index = _G })
		local start = assert(source:find("privacy_owners.menu_rebuild = (function(", 1, true))
		local ending = assert(source:find("\n\t\telse\n", start, true))
		compile(source:sub(start, ending - 1), environment)()
		helpers.assert_eq(#menus, 1, "startup must publish before the loop")
		helpers.assert_eq(checkpoints, 1, "Main retains its post-publication shutdown checkpoint")
		local previous = menus[1][1].fn
		environment.rebuild_tray_menu(); environment.rebuild_tray_menu()
		helpers.assert_eq(#menus, 1); helpers.assert_eq(previous(), false)
		local idle = assert(source:find("\n\tevent_loop.run({", ending, true))
		local idle_end = assert(source:find("\n\t-- 8.14)", idle, true))
		compile(source:sub(idle, idle_end - 1), environment)()
		helpers.assert_eq(table.concat(order, ","), "build,keyboard,build")
		helpers.assert_eq(#menus, 2); helpers.assert_eq(previous(), false)
		helpers.assert_eq(menus[2][1].fn(), "current")
		stopped = true; helpers.assert_eq(menus[2][1].fn(), false)
	end)

	helpers.it("(menu-startup-checkpoint) refuses continuation after shutdown during initial publication", function()
		local file = assert(io.open(helpers.driver_root() .. "/ergopti_hotstrings.lua", "rb"))
		local source = assert(file:read("*a")); assert(file:close())
		local order, menus, requested, retired = {}, {}, false, 0
		local environment = setmetatable({
			continued = false,
			privacy_owners = { finish_startup = function()
				retired = retired + 1; order[#order + 1] = "retire"
			end },
			shutdown = { is_requested = function() return requested end },
			menu_builder = { build = function()
				order[#order + 1] = "build"
				return { { title = "Action", fn = function() error("retired menu action") end } }
			end },
			tray_menu = { setMenu = function(items)
				menus[#menus + 1] = items; order[#order + 1] = "publish"
				requested = true
				return true
			end, setPaused = function() end },
			_build_menu_ctx = function() return { paused = false } end,
			Logger = { error = function() error("unexpected publication error") end }, LOG = "test",
		}, { __index = _G })
		local checkpoint = assert(source:find("privacy_owners.startup_checkpoint = function()", 1, true))
		local checkpoint_end = assert(source:find("\n\tif not privacy_owners.startup_checkpoint()", checkpoint, true))
		compile(source:sub(checkpoint, checkpoint_end - 1), environment)()
		local start = assert(source:find("privacy_owners.menu_rebuild = (function(", 1, true))
		local ending = assert(source:find("\n\t\telse\n", start, true))
		compile(source:sub(start, ending - 1) .. "\ncontinued = true\n", environment)()
		helpers.assert_eq(#menus, 1, "native publication reached the shutdown boundary")
		helpers.assert_eq(retired, 1, "the actual Main checkpoint retires startup on refusal")
		helpers.assert_eq(table.concat(order, ","), "build,publish,retire")
		helpers.assert_eq(environment.continued, false, "refusal returns before the continuation sentinel")
		helpers.assert_eq(menus[1][1].fn(), false, "shutdown revokes the published callback")
	end)

	helpers.it("returns an exact native publication receipt and retains refused trees", function()
		local available, accepted = true, true
		local indicator = { is_available = function() return available end,
			create = function() return true end, set_menu = function() return accepted end }
		local environment = setmetatable({ require = function(name)
			if name == "platform.tray.appindicator" then return indicator end
			if name == "logger.shim" then return { debug = function() end, warn = function() end } end
			if name == "tray.protocol" then return { resolve_tray_icon = function() return "input-keyboard" end } end
			if name == "infra.paths" then return { shared_root = function() return "/synthetic" end } end
			error("unexpected tray dependency: " .. name)
		end }, { __index = _G })
		local file = assert(io.open(helpers.driver_root() .. "/adapters/tray_menu.lua", "rb"))
		local source = file:read("*a"); file:close()
		local tray = compile(source, environment)()
		helpers.assert_eq(tray.setMenu({}), true)
		accepted = false
		local retained = { { title = "Retained" } }
		helpers.assert_eq(tray.setMenu(retained), false)
		helpers.assert_eq(tray.getMenu(), retained)
		indicator.set_menu = function() error("native refusal") end
		local rejected = { { title = "Native exception" } }
		local called, reason = pcall(tray.setMenu, rejected)
		helpers.assert_eq(called, false)
		helpers.assert_true(type(reason) == "string" and reason:find("native refusal", 1, true) ~= nil)
		helpers.assert_eq(tray.getMenu(), rejected)
		available = false
		local cold = compile(source, environment)()
		helpers.assert_eq(cold.setMenu(retained), false)
		helpers.assert_eq(cold.getMenu(), retained)
	end)
end)
