--- tests/support/modules/llm/backends/local_openai_backends_fixture.lua

--- ==============================================================================
--- MODULE: Shared fixture for test_local_openai_backends
--- DESCRIPTION:
--- Prelude shared by the test_local_openai_backends_* test files: their modules, default
--- state and scenario fixture. Each test file loads it fresh, so no state
--- leaks from one file to the next.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("json")

local SERVERS = { "omlx", "lmstudio", "llamacpp", "jan" }

--- Reads a shared JSON file.
--- @param relative string Path under _shared/.
--- @return table decoded
local function read_json(relative)
	local fh = assert(io.open(helpers.shared(relative), "r"), "cannot open " .. relative)
	local raw = fh:read("*a")
	fh:close()
	return assert(json.decode(raw))
end

--- Returns one named closure upvalue.
--- @param fn function
--- @param target string
--- @return any value
local function get_upvalue(fn, target)
	for index = 1, 256 do
		local name, value = debug.getupvalue(fn, index)
		if not name then break end
		if name == target then return value end
	end
	return nil
end

--- A models answer.
--- @param ids table Model ids.
--- @return table response
local function models_answer(ids)
	local data = {}
	for index, id in ipairs(ids) do data[index] = { id = id, object = "model" } end
	return { ok = true, status = 200, body = json.encode({ object = "list", data = data }), headers = {} }
end

--- A chat completion answer.
--- @param content string
--- @return table response
local function completion_answer(content)
	return { ok = true, status = 200, headers = {}, body = json.encode({
		choices = { { index = 0, message = { role = "assistant", content = content }, finish_reason = "stop" } },
	}) }
end

--- Runs a scenario over a fresh remote backend and fresh detection, with the
--- probe, inference and agent HTTP clients faked.
--- @param scenario function Receives (api, LocalServers, world).
local function with_backend(scenario)
	helpers.with_fresh_modules({ "modules.llm.local_servers", "modules.llm.api_remote" }, function()
		local api = helpers.load_with_stubs("modules.llm.api_remote")
		local LocalServers = require("modules.llm.local_servers")
		local world = { probes = {}, posts = {} }
		local probe_clients = get_upvalue(api.detect_local_servers, "_local_probe_clients")
		assert(type(probe_clients) == "table", "the probe clients must be reachable")
		for _, id in ipairs(LocalServers.ORDER) do
			probe_clients[id] = {
				cancel = function() return true end,
				isSettled = function() return true end,
				onSettled = function(callback) callback(); return true end,
				get = function(url, headers, callback)
					world.probes[#world.probes + 1] = { id = id, url = url, headers = headers, callback = callback }
					return true
				end,
			}
		end
		for _, name in ipairs({ "_infer_client", "_vision_client" }) do
			local client = get_upvalue(name == "_infer_client" and api.cancel_streaming or api.request_chat, name)
			assert(type(client) == "table", name .. " must be reachable")
			client.post = function(url, headers, body, callback)
				world.posts[#world.posts + 1] = {
					client = name, url = url, headers = headers, body = json.decode(body), callback = callback,
				}
				return true
			end
		end
		--- The last probe of one server.
		function world.probe(id)
			for index = #world.probes, 1, -1 do
				if world.probes[index].id == id then return world.probes[index] end
			end
			return nil
		end
		scenario(api, LocalServers, world)
	end)
end

--- Answers the probes of the last sweep: every server not named is down.
--- @param world table
--- @param answers table Server id -> response.
local function answer_sweep(world, answers)
	for _, id in ipairs(SERVERS) do
		world.probe(id).callback(answers[id] or { ok = false, status = 0, error = "connection refused" })
	end
end





local function with_panel(scenario)
	local owned = {
		"ui.menu.menu_llm.local_server_panel", "ui.menu.menu_llm.api_panel", "modules.llm",
		"infra.dialog_util", "infra.notifications", "infra.deferred_work",
	}
	with_backend(function(api, LocalServers, world)
		helpers.with_fresh_modules(owned, function()
			world.notices, world.persists, world.menus, world.activations, world.warmups = {}, 0, 0, 0, 0
			world.dialog_answer = { "OK", "" }
			-- Deferred work runs at once unless a scenario holds it to model the
			-- menu build that has not returned yet.
			world.deferred, world.hold_deferred = {}, false
			package.loaded["infra.deferred_work"] = {
				after = function(delay, callback, label)
					world.deferred[#world.deferred + 1] = { delay = delay, label = label, callback = callback }
					if not world.hold_deferred then callback() end
					return true
				end,
			}
			package.loaded["modules.llm"] = {
				api_remote = api,
				persist_api_entries = function(callback)
					world.persists = world.persists + 1
					callback(true, nil, true)
				end,
			}
			package.loaded["infra.dialog_util"] = {
				text_prompt = function(_, _, default, ok_label, cancel_label)
					world.last_default = default
					return world.dialog_answer[1] == "OK" and ok_label or cancel_label, world.dialog_answer[2]
				end,
			}
			package.loaded["infra.notifications"] = {
				notify = function(title, body, kind, on_click)
					world.notices[#world.notices + 1] = { title = title, body = body, kind = kind, on_click = on_click }
					return true
				end,
			}
			local Panel = require("ui.menu.menu_llm.local_server_panel")
			local ctx = {
				state = { llm_backend = "ollama", llm_model = "" },
				paused = false,
				is_paused = function() return false end,
				keymap = {
					reset_predictions = function() return true end,
					reset_predictions_for_configuration = function() return true end,
				},
				update_menu = function() world.menus = world.menus + 1 end,
				WarmupCtrl = { warmup = function() world.warmups = world.warmups + 1 end },
				activate_api = function() world.activations = world.activations + 1 end,
			}
			scenario(Panel, api, LocalServers, world, ctx)
		end)
	end)
end

local function row_starting(rows, prefix)
	for _, row in ipairs(rows) do
		if type(row.label) == "string" and row.label:sub(1, #prefix) == prefix then return row end
	end
	return nil
end

return {
	SERVERS = SERVERS,
	answer_sweep = answer_sweep,
	completion_answer = completion_answer,
	get_upvalue = get_upvalue,
	json = json,
	models_answer = models_answer,
	read_json = read_json,
	row_starting = row_starting,
	with_backend = with_backend,
	with_panel = with_panel,
}
