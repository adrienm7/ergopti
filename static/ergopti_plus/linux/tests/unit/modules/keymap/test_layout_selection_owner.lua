--- tests/unit/modules/keymap/test_layout_selection_owner.lua

--- ==============================================================================
--- MODULE: Layout Selection Shares Native Mutation Ownership
--- DESCRIPTION:
--- The real registry and shared manager controller run against a private
--- installed-record store and controlled process/HTTP completion ports. Native
--- mutations must reserve the same slot, settle exactly once, and release it
--- before callbacks can start another operation.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")
local Controller = require("layouts.manager_bridge")

--- Runs a fresh real registry with controlled native completion ordering.
--- @param body function Receives the registry, dependencies and observable world.
local function scenario(body)
	local previous = package.loaded["modules.keymap.layout_registry"]
	package.loaded["modules.keymap.layout_registry"] = nil
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
		local files = {
			["/fixture/layouts/installed.json"] = Json.encode({ schema_version = 1, layouts = installed }),
			["/fixture/layouts/ergol.keylayout"] = "fixture", ["/fixture/layouts/ergopti.keylayout"] = "fixture",
		}
		local world = { pending = {}, requests = {}, states = {}, calls = {}, eager = true }
		local deps = {
			settings = assert(registry.settings()), local_dir = "/fixture/layouts/", installer = "/fixture/installer.py",
			decode_json = Json.decode, encode_json = Json.encode,
			read = function(path) return files[path] end,
			exists = function(path) return files[path] ~= nil end,
			write = function(path, content) files[path] = content; return true end,
			delete = function(path) files[path] = nil; return true end,
			ensure_dir = function() return true end,
			translate = function(key) return key end,
			transport = { get = function(_, _, _, callback)
				if world.eager then callback(200, Json.encode(catalogue), nil, {})
				else world.requests[#world.requests + 1] = callback end
			end },
			run = function(_, args, _, callback)
				if world.probe_failure then
					world.probe_failure = false
					callback({ exit_code = -1, stdout = "", stderr = "", error = "python missing", not_found = true })
					return false
				end
				if args[1] == "-c" then callback({ exit_code = 0, stdout = "", stderr = "" })
				elseif world.eager then callback({ exit_code = 0, stdout = '{"ok":true,"verified":true}', stderr = "" })
				else world.pending[#world.pending + 1] = { action = args[2], id = args[#args], callback = callback } end
				return true
			end,
		}
		registry.refresh(function(outcome) assert(outcome.index) end, deps)
		assert(registry.select("ergopti", function(selected) assert(selected) end, deps))
		-- Keep the admitted catalogue in RAM, with no offline cache to finish a
		-- held install after this fixture explicitly refuses its HTTP refresh.
		files[deps.local_dir .. deps.settings.index_file] = nil
		world.eager = false
		function world.snapshot() return registry.snapshot(deps) end
		function world.settle(index, success)
			local operation = assert(world.pending[index])
			assert(operation.callback, "a native completion must be consumed exactly once")
			local callback = operation.callback
			operation.callback = nil
			callback({ exit_code = success and 0 or 1,
				stdout = success and '{"ok":true,"verified":true}' or '{"ok":false,"detail":"refused"}', stderr = "" })
		end
		local adapter = { snapshot = world.snapshot }
		for _, method in ipairs({ "select", "uninstall", "install" }) do
			adapter[method] = function(id, done)
				local call = { method = method, id = id, callbacks = 0 }
				world.calls[#world.calls + 1] = call
				call.accepted = registry[method](id, function(selected, code, ...)
					call.callbacks, call.ok, call.code = call.callbacks + 1, selected, code
					done(selected, code, ...)
				end, deps)
				return call.accepted
			end
		end
		world.controller = Controller.new({
			registry = adapter, push = function(_, state) world.states[#world.states + 1] = state; return true end,
			strings = function() return {} end, log = function() end,
		})
		body(registry, deps, world)
	end, debug.traceback)
	package.loaded["modules.keymap.layout_registry"] = previous
	if not ok then error(detail, 0) end
end

helpers.describe("layout selection shares the registry operation slot", function()
	for _, pair in ipairs({ { "select", "select" }, { "select", "uninstall" }, { "uninstall", "select" },
		{ "select", "install" }, { "install", "select" } }) do
		helpers.it("(layout-selection-owner) refuses overlapping " .. pair[1] .. " then " .. pair[2], function()
			scenario(function(registry, _, world)
				helpers.assert_true(world.controller.on_message({ action = pair[1], id = "ergol" }))
				local busy = world.snapshot().busy
				helpers.assert_type(busy, "table", "the first mutation must publish its pending owner")
				helpers.assert_eq(busy.id, "ergol"); helpers.assert_eq(busy.action, pair[1])
				helpers.assert_true(world.controller.on_message({ action = pair[2], id = "ergol" }))
				helpers.assert_eq(world.calls[1].accepted, true)
				helpers.assert_eq(world.calls[2].accepted, false, "the competitor must be refused before acquiring any native resource")
				helpers.assert_eq(world.calls[2].callbacks, 1)
				helpers.assert_eq(world.calls[2].ok, false)
				helpers.assert_eq(world.calls[2].code, registry.FAILURE_BUSY)
				helpers.assert_eq(world.calls[1].callbacks, 0)
				helpers.assert_eq(world.snapshot().busy, busy, "refusal cannot clear the live operation")
				if pair[1] == "install" then
					helpers.assert_eq(#world.requests, 1); helpers.assert_eq(#world.pending, 0)
					world.requests[1](404, "", "offline", {})
				else
					helpers.assert_eq(#world.pending, 1); helpers.assert_eq(#world.requests, 0)
					world.settle(1, true)
				end
				helpers.assert_eq(world.calls[1].callbacks, 1)
				helpers.assert_eq(world.calls[2].callbacks, 1)
				helpers.assert_nil(world.snapshot().busy)
				local settled = world.snapshot()
				helpers.assert_true(settled.active == "" or settled.installed[settled.active] ~= nil,
					"a late activation cannot publish a layout already removed from the record")
			end)
		end)
	end

	for _, success in ipairs({ false, true }) do
		helpers.it("(layout-selection-owner) releases selection before a reentrant callback success=" .. tostring(success), function()
			scenario(function(registry, deps, world)
				local first, second, accepted = 0, 0, false
				helpers.assert_true(registry.select("ergol", function(selected)
					first = first + 1
					helpers.assert_eq(selected, success)
					helpers.assert_nil(world.snapshot().busy)
					accepted = registry.select("ergopti", function(next_selected) second = second + 1; helpers.assert_true(next_selected) end, deps)
				end, deps))
				world.settle(1, success)
				helpers.assert_true(accepted)
				helpers.assert_eq(first, 1); helpers.assert_eq(second, 0)
				local successor = world.snapshot().busy
				helpers.assert_type(successor, "table", "the reentrant operation must own its pending slot")
				helpers.assert_eq(successor.id, "ergopti", "old completion must not clear its reentrant successor")
				world.settle(2, true)
				helpers.assert_eq(first, 1); helpers.assert_eq(second, 1)
				helpers.assert_nil(world.snapshot().busy)
				helpers.assert_eq(world.snapshot().active, "ergopti")
			end)
		end)
	end

	helpers.it("(layout-selection-owner) releases a synchronous helper refusal before reentry", function()
		scenario(function(registry, deps, world)
			world.probe_failure = true
			local first, second = 0, 0
			helpers.assert_true(registry.select("ergol", function(selected, code)
				first = first + 1
				helpers.assert_eq(selected, false); helpers.assert_eq(code, registry.FAILURE_SELECT)
				helpers.assert_nil(world.snapshot().busy)
				helpers.assert_true(registry.select("ergopti", function(ok) second = second + 1; helpers.assert_true(ok) end, deps))
			end, deps))
			helpers.assert_eq(first, 1); helpers.assert_eq(second, 0)
			local successor = world.snapshot().busy
			helpers.assert_type(successor, "table", "the reentrant operation must own its pending slot")
			helpers.assert_eq(successor.id, "ergopti")
			world.settle(1, true)
			helpers.assert_eq(first, 1); helpers.assert_eq(second, 1)
			helpers.assert_nil(world.snapshot().busy)
		end)
	end)
end)
