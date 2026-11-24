--- tests/unit/diagnostics/ui/field_check/test_field_report_window.lua

--- ==============================================================================
--- MODULE: Field Report Window Host (macOS)
--- DESCRIPTION:
--- The macOS host of the field report progress window
--- (diagnostics/ui/field_check/field_report_window.lua) over a stubbed factory:
--- 1. it opens the shared page under its manifest id, geometry and bridge, with
---    the close owner of every Ergopti window;
--- 2. the page's ready and actions reach the controller, and its pushes go to
---    window.receiveFieldReport in that exact window only;
--- 3. its close box tells the controller once; a second window replaces the
---    first, whose late messages are inert; a refused factory opens nothing.
--- ==============================================================================

local helpers = require("tests.helpers")

local MODULES = { "core.logger.engine.logger", "core.ui.ui.builder", "diagnostics.ui.field_check.field_report_window" }

--- A webview double that records its scripts.
local function fake_view()
	local view = { scripts = {}, deleted = 0 }
	function view:evaluateJavaScript(code, callback)
		self.scripts[#self.scripts + 1] = code
		if callback then callback(nil, nil) end
		return self
	end
	function view:delete() self.deleted = self.deleted + 1 end
	return view
end

--- A controller double that records what the host tells it.
local function fake_owner()
	local owner = { events = {} }
	function owner.bind(window) owner.window = window end
	function owner.on_ready() table.insert(owner.events, "ready") end
	function owner.on_action(name) table.insert(owner.events, "action:" .. tostring(name)) end
	function owner.on_closed() table.insert(owner.events, "closed") end
	return owner
end

--- Loads the host over a stubbed factory and usercontent.
local function with_host(body)
	helpers.with_stub_scope(MODULES, function()
		local world = { opened = {}, callbacks = {}, refuse = false }
		local saved_hs = _G.hs
		-- Only the webview surface is replaced; paths and the rest stay the suite's
		_G.hs = setmetatable({
			webview = {
				windowMasks = { titled = 1, closable = 2, resizable = 8 },
				usercontent = {
					new = function(name)
						world.bridge = name
						local controller = {}
						function controller:setCallback(fn)
							world.callbacks[#world.callbacks + 1] = fn
							return self
						end
						return controller
					end,
				},
			},
		}, { __index = saved_hs })
		local logger = helpers.make_logger_stub()
		logger.error = function(_, template, ...) world.error = string.format(template, ...) end
		package.loaded["core.logger.engine.logger"] = logger
		package.loaded["core.ui.ui.builder"] = {
			get_app_geometry = function(id)
				world.geometry_id = id
				return { width = 560, height = 520 }
			end,
			get_centered_frame = function(w, h) return { w = w, h = h } end,
			show_webview = function(opts)
				world.opened[#world.opened + 1] = opts
				if world.refuse then return nil end
				local view = fake_view()
				world.view = view
				assert(opts.on_webview_created(view) == true)
				return view
			end,
		}
		package.loaded["diagnostics.ui.field_check.field_report_window"] = nil
		local Host = require("diagnostics.ui.field_check.field_report_window")
		Host._reset()
		local ok, err = pcall(body, Host, world)
		_G.hs = saved_hs
		assert(ok, err)
	end)
end

helpers.describe("field report window: the macOS host", function()
	helpers.it("opens the shared page under its manifest id and bridge", function()
		with_host(function(Host, world)
			local owner = fake_owner()
			helpers.assert_true(Host.open(owner), world.error)
			local opts = world.opened[1]
			helpers.assert_eq(opts.app_id, "field_report")
			helpers.assert_eq(world.geometry_id, "field_report")
			helpers.assert_eq(world.bridge, "field_report")
			helpers.assert_eq(opts.frame.w, 560)
			helpers.assert_true(opts.delete_on_close == true, "the close owner of every Ergopti window")
			helpers.assert_contains(opts.assets_dir, "ui/field_report/")
			helpers.assert_true(Host.is_open())
		end)
	end)

	helpers.it("routes the page's messages and pushes into that window only", function()
		with_host(function(Host, world)
			local owner = fake_owner()
			Host.open(owner)
			world.callbacks[1]({ body = "ready" })
			world.callbacks[1]({ body = { action = "copy" } })
			world.callbacks[1]({ body = 42 })
			helpers.assert_eq(table.concat(owner.events, " "), "ready action:copy")
			helpers.assert_true(owner.window.push({ type = "step", id = "field_network", state = "pass" }))
			helpers.assert_contains(world.view.scripts[1], "window.receiveFieldReport({")
			helpers.assert_contains(world.view.scripts[1], '"state":"pass"')
		end)
	end)

	helpers.it("tells the controller once when its close box closes it", function()
		with_host(function(Host, world)
			local owner = fake_owner()
			Host.open(owner)
			world.opened[1].on_close()
			world.opened[1].on_close()
			helpers.assert_eq(table.concat(owner.events, " "), "closed")
			helpers.assert_true(not Host.is_open())
			helpers.assert_true(not owner.window.push({ type = "done" }), "a closed window takes no push")
			world.callbacks[1]({ body = "ready" })
			helpers.assert_eq(#owner.events, 1, "a closed window's late message is inert")
		end)
	end)

	helpers.it("replaces a window left open, and opens nothing when the factory refuses", function()
		with_host(function(Host, world)
			local first, second = fake_owner(), fake_owner()
			Host.open(first)
			helpers.assert_true(Host.open(second))
			helpers.assert_eq(table.concat(first.events, " "), "closed", "the first window is closed and told")
			world.callbacks[1]({ body = "ready" })
			helpers.assert_eq(#second.events, 0, "the first window's late message does not reach the second")
			world.callbacks[2]({ body = "ready" })
			helpers.assert_eq(second.events[1], "ready")
			second.window.close()
			world.refuse = true
			helpers.assert_true(not Host.open(fake_owner()))
			helpers.assert_true(not Host.is_open())
		end)
	end)
end)
