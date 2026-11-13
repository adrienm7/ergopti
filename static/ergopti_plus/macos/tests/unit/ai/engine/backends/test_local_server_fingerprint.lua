--- tests/unit/ai/engine/backends/test_local_server_fingerprint.lua

--- ==============================================================================
--- MODULE: Local Server Fingerprint Contract (macOS)
--- DESCRIPTION:
--- Replays the shared fingerprint vectors against the actual catalogue, then
--- drives the real detection (ai/engine/local_servers/local_servers.lua, api_remote) and
--- the AI menu (local_server_panel) with the probes faked:
--- - vLLM answering on oMLX's port 8000 is one row, named vLLM;
--- - an oMLX row whose answer carries vLLM's owned_by is named vLLM.
---
--- ROOT CAUSE ENCODED:
--- vLLM and TabbyAPI listen by default on the ports of oMLX (8000) and
--- text-generation-webui (5000) and answer the same models listing shape, so
--- a probe of a shared address gave two rows, or the wrong server's name.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("core.text.engine.json")
local Paths = require("core.fs.engine.paths")
package.loaded["tests.support.ai.engine.backends.local_openai_backends_fixture"] = nil
local Fixture = require("tests.support.ai.engine.backends.local_openai_backends_fixture")

-- A vLLM models listing (vllm/entrypoints/openai/protocol.py ModelList)
local VLLM_LISTING = { ok = true, status = 200,
	body = '{"object":"list","data":[{"id":"Qwen/Qwen3-8B","object":"model","created":1761900000,'
		.. '"owned_by":"vllm","root":"Qwen/Qwen3-8B","parent":null,"max_model_len":32768,"permission":[]}]}' }

--- Reads one shared JSON file.
--- @param relative string
--- @return table
local function read(relative)
	local file = assert(io.open(Paths.shared(relative), "rb"))
	local root = assert(Json.decode(file:read("*a")))
	file:close()
	return root
end

--- Answers every probe of the last sweep: the named servers answer, the others are down.
--- @param world table
--- @param answers table Server id -> response.
local function answer_all(world, answers)
	local answered = {}
	for index = #world.probes, 1, -1 do
		local probe = world.probes[index]
		if not answered[probe.id] then
			answered[probe.id] = true
			probe.callback(answers[probe.id] or { ok = false, status = 0, error = "connection refused" })
		end
	end
end

helpers.describe("Local server fingerprint (local-server-fingerprint)", function()
	require("tests.lua.core.local_server_fingerprint_contract").run(read("tests/corpus/llm/local_server_fingerprint.json"),
		read("ai/data/local_servers.json"), helpers)
end)

helpers.describe("macOS local server rows at a shared address (local-server-fingerprint)", function()
	helpers.it("the catalogue owner hands the controller every shared address's fingerprint", function()
		Fixture.with_backend(function(_, LocalServers)
			helpers.assert_eq(LocalServers.IDENTITIES.vllm.group, { "omlx", "vllm" })
			helpers.assert_eq(LocalServers.IDENTITIES.tabbyapi.group, { "textgen_webui", "tabbyapi" })
			helpers.assert_eq(LocalServers.IDENTITIES.tabbyapi.rule, { model_field = "owned_by", equals = "tabbyAPI" })
			helpers.assert_eq(LocalServers.IDENTITIES.lmstudio, nil, "an unshared address is never fingerprinted")
		end)
	end)

	helpers.it("vLLM answering on oMLX's port is one row named vLLM", function()
		Fixture.with_panel(function(Panel, api, LocalServers, world, ctx)
			-- Both rows of 8000 are looked for, as when the process list is unread
			world.scan_overrides.vllm = nil
			Panel.rows(ctx)
			helpers.assert_eq(world.probe("omlx").url, "http://127.0.0.1:8000/v1/models")
			helpers.assert_eq(world.probe("vllm").url, "http://127.0.0.1:8000/v1/models")
			answer_all(world, { omlx = VLLM_LISTING, vllm = VLLM_LISTING })
			helpers.assert_eq(LocalServers.detected(), { "vllm" })
			helpers.assert_eq(LocalServers.result("omlx").shadowed_by, "vllm")
			local rows = Panel.rows(ctx)
			helpers.assert_true(Fixture.row_starting(rows, "vLLM 🖥️ — 127.0.0.1:8000") ~= nil, "the vLLM row is listed")
			helpers.assert_true(Fixture.row_starting(rows, "oMLX 🖥️") == nil, "the address is not listed twice")
			local names = {}
			for _, view in ipairs(api.local_server_views()) do
				if view.status == LocalServers.STATUS_UP then names[#names + 1] = view.display_name end
			end
			helpers.assert_eq(names, { "vLLM" })
		end)
	end)

	helpers.it("an oMLX row whose answer is vLLM's is named vLLM", function()
		Fixture.with_panel(function(Panel, api, LocalServers, world, ctx)
			Panel.rows(ctx)
			helpers.assert_eq(world.probe("vllm"), nil, "a stopped vLLM is not probed")
			answer_all(world, { omlx = VLLM_LISTING })
			helpers.assert_eq(LocalServers.detected(), { "omlx" })
			helpers.assert_eq(LocalServers.result("omlx").server, "vllm")
			helpers.assert_true(Fixture.row_starting(Panel.rows(ctx), "vLLM 🖥️ — 127.0.0.1:8000") ~= nil)
			helpers.assert_eq(api.local_server_views()[1].display_name, "vLLM")
		end)
	end)
end)
