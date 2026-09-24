--- tests/unit/ui/test_healthcheck_probes.lua

--- ==============================================================================
--- MODULE: Diagnostics Probes (Linux)
--- DESCRIPTION:
--- The asynchronous half of the diagnostics snapshot, over controlled adapters:
--- 1. github_api reads api.github.com's rate limit through the libuv HTTP
---    client, under its own owner so it never cancels the updater's request;
--- 2. system_details reads the kanata version and the logs volume's free space
---    from asynchronous children;
--- 3. without libuv every probe answers "unsupported" instead of blocking the
---    event loop with a synchronous fallback;
--- 4. a cancelled run publishes nothing and stops its requests and children.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Runs body with the real probes over recorded adapters.
--- @param async boolean Whether libuv is available.
--- @param body function(Probes, world)
local function with_probes(async, body)
	local names = { "ui.healthcheck.probes", "adapters.http_client", "adapters.shell_runner" }
	local saved = {}
	for _, name in ipairs(names) do saved[name] = package.loaded[name] end
	local world = { requests = {}, children = {}, cancelled_owners = {}, cancelled_children = 0 }
	package.loaded["adapters.http_client"] = {
		HAS_ASYNC = async,
		get = function(url, headers, options, callback)
			world.requests[#world.requests + 1] = { url = url, headers = headers, options = options, callback = callback }
			return true
		end,
		cancel = function(owner) world.cancelled_owners[#world.cancelled_owners + 1] = owner; return true end,
	}
	package.loaded["adapters.shell_runner"] = {
		HAS_ASYNC = async,
		run_async = function(executable, args, options, callback)
			world.children[#world.children + 1] = { executable = executable, args = args, options = options,
				callback = callback }
			return { cancel = function() world.cancelled_children = world.cancelled_children + 1 end }
		end,
	}
	package.loaded["ui.healthcheck.probes"] = nil
	local ok, err = pcall(body, require("ui.healthcheck.probes"), world)
	for _, name in ipairs(names) do package.loaded[name] = saved[name] end
	if not ok then error(err, 0) end
end

--- Starts the probes of the real schema with a recorder.
--- @param Probes table
--- @param state table|nil Daemon state.
--- @return table run, table answers
local function start(Probes, state)
	local schema = helpers.load_module("ui.healthcheck.bridge").config().schema
	local answers = {}
	local run = Probes.start(schema, { logs_dir = "/home/jdoe/.local/state/ergopti_plus/logs" }, state or {},
		function(id, result, sections) answers[id] = { result = result, sections = sections } end)
	return run, answers
end

helpers.describe("diagnostics probes (linux)", function()
	helpers.it("reads GitHub's rate limit under the probe's own owner", function()
		with_probes(true, function(Probes, world)
			local _, answers = start(Probes)
			local request = world.requests[1]
			helpers.assert_eq(request.url, "https://api.github.com/rate_limit")
			helpers.assert_eq(request.options.owner, "diagnostics.github")
			helpers.assert_eq(request.options.https_only, true)
			request.callback({ status = 200, body = '{"resources":{"core":{"limit":60,"remaining":12}}}' })
			helpers.assert_eq(answers.github_api.result.state, "ok")
			helpers.assert_eq(answers.github_api.sections.network.github_api, "HTTP 200, 12/60")
		end)
	end)

	helpers.it("reads the kanata version and the free space from asynchronous children", function()
		with_probes(true, function(Probes, world)
			local _, answers = start(Probes)
			helpers.assert_eq(world.children[1].executable, "kanata")
			helpers.assert_eq(world.children[2].executable, "df")
			world.children[1].callback({ ok = true, stdout = "kanata 1.7.0\n" })
			world.children[2].callback({ ok = true, stdout = "Filesystem 1024-blocks Used Available Capacity Mounted on\n"
				.. "/dev/nvme0n1p3 490000000 200000000 250000000 45% /home\n" })
			helpers.assert_eq(answers.system_details.result.state, "ok")
			helpers.assert_eq(answers.system_details.sections.versions.kanata, "kanata 1.7.0")
			helpers.assert_eq(answers.system_details.sections.system.disk_free, 250000000 * 1024)
		end)
	end)

	helpers.it("answers unsupported without libuv rather than blocking the loop", function()
		with_probes(false, function(Probes, world)
			local _, answers = start(Probes, { llm = { is_enabled = function() return true end,
				get_base_url = function() return "http://localhost:11434" end } })
			helpers.assert_eq(answers.github_api.result.state, "unsupported")
			helpers.assert_eq(answers.ai_health.result.state, "unsupported")
			helpers.assert_eq(answers.system_details.result.state, "unsupported")
			helpers.assert_eq(#world.requests, 0)
			helpers.assert_eq(#world.children, 0)
		end)
	end)

	helpers.it("a cancelled run publishes nothing and stops its requests and children", function()
		with_probes(true, function(Probes, world)
			local run, answers = start(Probes)
			run.cancel()
			world.requests[1].callback({ status = 200, body = "{}" })
			world.children[1].callback({ ok = true, stdout = "kanata 1.7.0\n" })
			helpers.assert_nil(answers.github_api, "nothing of a cancelled run reaches the page")
			helpers.assert_nil(answers.system_details)
			helpers.assert_eq(world.cancelled_owners, { "diagnostics.github" })
			helpers.assert_eq(world.cancelled_children, 2)
		end)
	end)
end)
