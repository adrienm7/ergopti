--- tests/unit/modules/llm/backends/test_local_server_port_discovery.lua

--- ==============================================================================
--- MODULE: Local Server Port Discovery Integration
--- DESCRIPTION:
--- Drives api_remote.detect_local_servers through the port scan seam and the
--- real sweep:
--- - a server whose settings file moved it to port 8181 is probed and listed there;
--- - a server whose process does not run is not probed;
--- - a sweep in which nothing answers still reports none;
--- - local_server_views gives the selector page's per-server shape;
--- - a request of an entry stored at the default address goes to the scanned port.
---
--- ROOT CAUSE ENCODED:
--- The maintainer's oMLX listened on 8181, set in its app (~/.omlx/settings.json),
--- while the sweep probed the catalogue port 8000 only: "none answers" every sweep.
--- ==============================================================================

local helpers = require("tests.helpers")
package.loaded["tests.support.modules.llm.backends.local_openai_backends_fixture"] = nil
local Fixture = require("tests.support.modules.llm.backends.local_openai_backends_fixture")
local models_answer = Fixture.models_answer
local with_backend = Fixture.with_backend

--- Marks every catalogue server but the given ones as not running.
--- @param world table
--- @param running table Server id -> fields of its scan result.
local function only_running(world, running)
	for _, id in ipairs(Fixture.SERVERS) do
		world.scan_overrides[id] = running[id] or { running = false, pids = {}, detail = "no running process" }
	end
end

--- Returns the view of one server.
--- @param views table
--- @param id string
--- @return table|nil
local function view_of(views, id)
	for _, view in ipairs(views) do if view.id == id then return view end end
	return nil
end

helpers.describe("Local server port discovery (local-server-ports)", function()
	helpers.it("probes oMLX at the 8181 of its settings file and lists it there", function()
		with_backend(function(api, LocalServers, world)
			only_running(world, { omlx = { base_url = "http://127.0.0.1:8181/v1", port = 8181, source = "config",
				detail = "/Users/u/.omlx/settings.json" } })
			local done = {}
			helpers.assert_eq(api.detect_local_servers(function(changed) done[#done + 1] = changed end), true)
			helpers.assert_eq(#world.probes, 1, "only the running server is probed")
			helpers.assert_eq(world.probe("omlx").url, "http://127.0.0.1:8181/v1/models")
			world.probe("omlx").callback(models_answer({ "qwen3" }))
			helpers.assert_eq(done, { true })
			helpers.assert_eq(LocalServers.detected(), { "omlx" })
			helpers.assert_eq(LocalServers.result("omlx").base_url, "http://127.0.0.1:8181/v1")
			local view = view_of(api.local_server_views(), "omlx")
			helpers.assert_eq(view, { id = "omlx", display_name = "oMLX", port = 8181, port_source = "config",
				base_url = "http://127.0.0.1:8181/v1", models = { "qwen3" }, status = "up" })
			helpers.assert_eq(view_of(api.local_server_views(), "jan").reason, "not_running")
		end)
	end)

	helpers.it("a server found on a listening port is probed there", function()
		with_backend(function(api, LocalServers, world)
			only_running(world, { jan = { base_url = "http://127.0.0.1:1338/v1", port = 1338, source = "listening" } })
			api.detect_local_servers()
			helpers.assert_eq(#world.probes, 1)
			helpers.assert_eq(world.probe("jan").url, "http://127.0.0.1:1338/v1/models")
			world.probe("jan").callback(models_answer({ "jan-nano" }))
			helpers.assert_eq(LocalServers.detected(), { "jan" })
			helpers.assert_eq(view_of(api.local_server_views(), "jan").port_source, "listening")
		end)
	end)

	helpers.it("no running server: nothing is probed and the sweep reports none", function()
		with_backend(function(api, LocalServers, world)
			only_running(world, {})
			local done = {}
			helpers.assert_eq(api.detect_local_servers(function(changed) done[#done + 1] = changed end), true)
			helpers.assert_eq(#world.probes, 0, "a server whose process does not run is not probed")
			helpers.assert_eq(done, { false })
			helpers.assert_eq(LocalServers.detected(), {})
			helpers.assert_eq(LocalServers.is_sweeping(), false)
		end)
	end)

	helpers.it("running servers that do not answer are still reported as none", function()
		with_backend(function(api, LocalServers, world)
			api.detect_local_servers()
			helpers.assert_eq(#world.probes, 4)
			Fixture.answer_sweep(world, {})
			helpers.assert_eq(LocalServers.detected(), {})
			helpers.assert_eq(view_of(api.local_server_views(), "omlx").reason, "no_answer")
		end)
	end)

	helpers.it("a request of an entry stored at the default address goes to the scanned port", function()
		with_backend(function(api, _, world)
			only_running(world, { omlx = { base_url = "http://127.0.0.1:8181/v1", port = 8181, source = "config" } })
			api.detect_local_servers()
			world.probe("omlx").callback(models_answer({ "qwen3" }))
			api.set_entries({ { id = "local-omlx", provider = "omlx", base_url = "", token = "", model = "qwen3" } })
			api.set_active_entry_id("local-omlx")
			api.request_raw(nil, "Complete the text.", "Bonjour, je", "", 0.2, 32, function() end, function() end)
			helpers.assert_eq(#world.posts, 1)
			helpers.assert_eq(world.posts[1].url, "http://127.0.0.1:8181/v1/chat/completions")
		end)
	end)

	helpers.it("a detection asked during the scan joins it", function()
		with_backend(function(api, _, world)
			local pending
			api._scan_ports = function(_, on_done) pending = on_done; return true end
			local done = {}
			api.detect_local_servers(function() done[#done + 1] = "first" end)
			api.detect_local_servers(function() done[#done + 1] = "second" end)
			helpers.assert_eq(#world.probes, 0, "no probe before the scan settles")
			local stopped = {}
			for _, id in ipairs(require("modules.llm.local_servers").ORDER) do
				stopped[id] = { id = id, running = false, pids = {} }
			end
			pending(stopped)
			helpers.assert_eq(done, { "first", "second" })
		end)
	end)
end)
