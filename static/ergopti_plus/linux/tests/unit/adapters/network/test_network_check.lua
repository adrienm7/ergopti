--- tests/unit/adapters/network/test_network_check.lua

--- ==============================================================================
--- MODULE: Network Field Check (Linux)
--- DESCRIPTION:
--- The Debug menu's « Test network (PAC, proxy, download) » over scripted
--- collaborators:
--- 1. the shared steps (network/field_check_network.lua) report in the order
---    macOS and Windows use, and a helper cannot add a step;
--- 2. the Linux ports read the proxy kinds from the environment, GNOME and KDE,
---    run the route lookup and the managed request, and name each failure with
---    a closed token;
--- 3. no URL, host or PAC content reaches a step value, the evidence record or
---    the window text;
--- 4. the window runs one check at a time, records one evidence line, and copies
---    exactly what it shows.
--- ==============================================================================

local helpers = require("tests.helpers")

local Shared = require("network.field_check_network")
local Report = require("field_check_report")
local Ports = helpers.load_module("adapters.network_check_ports")

local PAC_URL = "http://pac.intranet.example/proxy.pac"
local FEED_URL = "https://feed.example.test/releases.atom"
local GOOD_PAC = "function FindProxyForURL(url, host) { return 'DIRECT'; }"

--- Collaborators for the ports, with overrides.
--- @param overrides table|nil
--- @return table deps, table calls
local function deps(overrides)
	local calls = { requests = {}, lookups = {}, commands = {} }
	local base = {
		environment = function() return {} end,
		exec = function(command)
			calls.commands[#calls.commands + 1] = command
			return nil
		end,
		has_command = function() return false end,
		feed_url = function() return FEED_URL end,
		lookup = function(url, options, callback)
			calls.lookups[#calls.lookups + 1] = { url = url, options = options }
			callback({ ok = true, proxies = { "direct://" } })
			return {}
		end,
		http_get = function(url, headers, options, callback)
			calls.requests[#calls.requests + 1] = { url = url, options = options }
			if url == PAC_URL then
				callback({ ok = true, status = 200, body = GOOD_PAC })
			else
				callback({ ok = true, status = 200, body = "<feed></feed>" })
			end
			return true
		end,
	}
	for key, value in pairs(overrides or {}) do base[key] = value end
	return base, calls
end

--- Runs the shared steps over the Linux ports and returns the finished result.
--- @param overrides table|nil
--- @return table steps by identity, table result, table calls
local function run(overrides)
	local collaborators, calls = deps(overrides)
	local report = Report.new_report("network")
	local finished = 0
	Shared.run(Ports.new(collaborators), report, function() finished = finished + 1 end)
	helpers.assert_eq(finished, 1, "the check settles exactly once")
	local result = report.result()
	local steps = {}
	for _, step in ipairs(result.steps) do steps[step.id] = step end
	return steps, result, calls
end

helpers.describe("network field check: the shared steps", function()
	helpers.it("(linux-network-check) reports the seven steps in the order every driver uses", function()
		local _, result = run({
			has_command = function(name) return name == "gsettings" end,
			exec = function(command)
				if command:find("autoconfig-url", 1, true) then return "'" .. PAC_URL .. "'" end
				if command:find(" mode", 1, true) then return "'auto'" end
			end,
		})
		local order = {}
		for _, step in ipairs(result.steps) do order[#order + 1] = step.id end
		helpers.assert_eq(order, Shared.STEP_IDS)
		helpers.assert_true(result.passed)
	end)

	helpers.it("(linux-network-check) a helper cannot add, repeat or rename a step", function()
		local steps = Shared.parse_chain_lines(
			"step route_lookup pass selected\nstep route_lookup fail again\nstep invented pass x\n"
			.. "step tls bogus_state trusted\nstep transfer pass http_200\n")
		helpers.assert_eq(steps.route_lookup.value, "selected", "the first line of an identity wins")
		helpers.assert_nil(steps.invented)
		helpers.assert_nil(steps.tls, "an unknown state is dropped")
		helpers.assert_eq(steps.transfer.state, "pass")
	end)
end)

helpers.describe("network field check: the Linux ports", function()
	helpers.it("(linux-network-check) names the kinds from the environment, GNOME and KDE", function()
		local settings = Ports.read_settings(deps({
			environment = function() return { https_proxy = "http://secret.corp.example:3128", no_proxy = "" } end,
			has_command = function(name) return name == "gsettings" or name == "kreadconfig6" end,
			exec = function(command)
				if command:find("org.gnome.system.proxy mode", 1, true) then return "'manual'" end
				if command:find("ProxyType", 1, true) then return "2" end
				if command:find("Proxy Config Script", 1, true) then return "http://kde.example/p.pac" end
			end,
		}))
		helpers.assert_eq(settings.kinds, "env+gnome_manual+kde_pac")
		helpers.assert_eq(settings.pac_url, "http://kde.example/p.pac")
		helpers.assert_eq(Ports.read_settings(deps()).kinds, "none")
	end)

	helpers.it("(linux-network-check) skips both PAC steps when no PAC is configured", function()
		local steps, result = run()
		helpers.assert_eq(steps.proxy_settings.value, "none")
		helpers.assert_eq(steps.pac_download.state, "skip")
		helpers.assert_eq(steps.pac_download.value, "no_pac")
		helpers.assert_eq(steps.pac_script.state, "skip")
		helpers.assert_true(result.passed)
	end)

	helpers.it("(linux-network-check) names a PAC that cannot be downloaded or is not a script", function()
		local gnome = {
			has_command = function(name) return name == "gsettings" end,
			exec = function(command)
				if command:find("autoconfig-url", 1, true) then return "'" .. PAC_URL .. "'" end
				if command:find(" mode", 1, true) then return "'auto'" end
			end,
		}
		local down = {}
		for key, value in pairs(gnome) do down[key] = value end
		down.http_get = function(url, _, _, callback)
			callback(url == PAC_URL and { ok = false, status = 404, body = "" } or { ok = true, status = 200, body = "<feed/>" })
			return true
		end
		local steps, result = run(down)
		helpers.assert_true(not result.passed)
		helpers.assert_eq(steps.pac_download.state, "fail")
		helpers.assert_eq(steps.pac_download.value, "http_404")
		helpers.assert_eq(steps.pac_script.value, "invalid")
		local page = {}
		for key, value in pairs(gnome) do page[key] = value end
		page.http_get = function(url, _, _, callback)
			callback(url == PAC_URL and { ok = true, status = 200, body = "<html>login</html>" } or { ok = true, status = 200, body = "<feed/>" })
			return true
		end
		local bad = run(page)
		helpers.assert_eq(bad.pac_download.state, "pass")
		helpers.assert_eq(bad.pac_script.state, "fail")
	end)

	helpers.it("(linux-network-check) fails the route step with the native refusal and still tries the request", function()
		local steps, result, calls = run({
			lookup = function(_, _, callback) callback({ ok = false, error = "proxy-native-failed" }); return {} end,
		})
		helpers.assert_true(not result.passed)
		helpers.assert_eq(steps.route_lookup.state, "fail")
		helpers.assert_eq(steps.route_lookup.value, "proxy-native-failed")
		helpers.assert_eq(#calls.requests, 1, "the request runs after a refused lookup")
		local refused = run({ lookup = function() return nil, "proxy-owner-busy" end })
		helpers.assert_eq(refused.route_lookup.value, "proxy-owner-busy", "a dispatch refusal is a closed name too")
	end)

	helpers.it("(linux-network-check) turns each request failure into a closed token", function()
		local cases = {
			{ result = { ok = false, status = 0, failure_receipt = { stage = "tls" } }, tls = "fail", token = "certificate" },
			{ result = { ok = false, status = 0, failure_receipt = { stage = "proxy_connect" } }, tls = "skip", token = "proxy_connect" },
			{ result = { ok = false, status = 0, failure_receipt = { stage = "proxy_resolve" } }, tls = "skip", token = "proxy_resolve" },
			{ result = { ok = false, status = 0, failure_receipt = { stage = "connect" } }, tls = "skip", token = "connect" },
			{ result = { ok = false, status = 503, failure_receipt = { stage = "http", http_status = 503 } }, tls = "skip", token = "http_503" },
			{ result = { ok = false, status = 0, error = "timeout" }, tls = "skip", token = "timeout" },
			{ result = { ok = false, status = 0, error = "curl exited with code 6 for a private.example host" }, tls = "skip", token = "failed" },
		}
		for _, case in ipairs(cases) do
			local steps, result = run({
				http_get = function(_, _, _, callback) callback(case.result); return true end,
			})
			helpers.assert_true(not result.passed)
			helpers.assert_eq(steps.tls.state, case.tls, case.token)
			helpers.assert_eq(steps.transfer.state, "fail")
			helpers.assert_eq(steps.transfer.value, case.token)
		end
		local refused = run({ http_get = function() return false end })
		helpers.assert_eq(refused.transfer.value, "failed", "a request the transport refuses to start")
	end)

	helpers.it("(linux-network-check) routes the request through the managed owner with a bound", function()
		local _, _, calls = run()
		helpers.assert_eq(calls.requests[1].url, FEED_URL)
		helpers.assert_eq(calls.requests[1].options.owner, Ports.OWNER)
		helpers.assert_true(calls.requests[1].options.https_only)
		helpers.assert_eq(calls.requests[1].options.timeout_ms, Ports.REQUEST_TIMEOUT_MS)
		helpers.assert_eq(calls.lookups[1].options.timeout_ms, Ports.LOOKUP_TIMEOUT_MS)
	end)

	helpers.it("(linux-network-check) no address, host or PAC content reaches a step or the evidence line", function()
		local steps, result = run({
			environment = function() return { https_proxy = "http://secret.corp.example:3128" } end,
			has_command = function(name) return name == "gsettings" end,
			exec = function(command)
				if command:find("autoconfig-url", 1, true) then return "'" .. PAC_URL .. "'" end
				if command:find(" mode", 1, true) then return "'auto'" end
			end,
			http_get = function(url, _, _, callback)
				callback(url == PAC_URL
					and { ok = true, status = 200, body = "function FindProxyForURL(u,h){return 'PROXY secret.corp.example:8080';}" }
					or { ok = false, status = 0, error = "could not resolve host feed.example.test" })
				return true
			end,
		})
		local line = Report.format_log_line(result)
		local text = Report.format_text(result, function(key) return key end)
		for _, needle in ipairs({ "intranet", "secret.corp", "feed.example", "://", "PROXY" }) do
			helpers.assert_true(not line:find(needle, 1, true), "the evidence line carries " .. needle)
			helpers.assert_true(not text:find(needle, 1, true), "the window text carries " .. needle)
		end
		helpers.assert_eq(steps.proxy_settings.value, "env+gnome_pac")
	end)

	helpers.it("(linux-network-check) an unreadable settings source is a failed step, not a lost run", function()
		local steps = run({ environment = function() error("PRIVATE /home/PrivateUser") end })
		helpers.assert_eq(steps.proxy_settings.state, "info", "an unreadable environment only drops its kind")
		local broken = run({ has_command = function() error("PRIVATE /home/PrivateUser") end })
		helpers.assert_eq(broken.proxy_settings.state, "fail")
		helpers.assert_eq(broken.proxy_settings.value, "unreadable")
		helpers.assert_eq(broken.pac_download.state, "skip")
	end)
end)

--- Loads the window over a recording logger and scripted services.
--- @param ports table The ports the window runs over.
--- @param body function(Window, world)
local function with_window(ports, body)
	local saved = {}
	for _, name in ipairs({ "logger.shim", "ui.network_check", "ui.field_check_window" }) do saved[name] = package.loaded[name] end
	local world = { evidence = {}, errors = {}, notes = {}, dialogs = {}, copies = {}, deferred = {}, click = "close" }
	local logger = helpers.make_logger_stub()
	logger.evidence = function(_, message, ...) world.evidence[#world.evidence + 1] = string.format(message, ...) end
	logger.error = function(_, message, ...) world.errors[#world.errors + 1] = string.format(message, ...) end
	package.loaded["logger.shim"] = logger
	package.loaded["ui.network_check"] = nil
	package.loaded["ui.field_check_window"] = nil
	local ok, err = xpcall(function()
		local Window = require("ui.network_check")
		Window._reset()
		world.services = {
			translate = function(key) return "[" .. key .. "]" end,
			env = function() return ports end,
			notify = function(message) world.notes[#world.notes + 1] = message end,
			dialog = function(title, text, copy_label, close_label)
				world.dialogs[#world.dialogs + 1] = { title = title, text = text, copy = copy_label, close = close_label }
				return world.click == "copy"
			end,
			copy = function(text) world.copies[#world.copies + 1] = text; return true end,
			defer = function(fn) world.deferred[#world.deferred + 1] = fn end,
		}
		function world.flush()
			local pending = world.deferred
			world.deferred = {}
			for _, fn in ipairs(pending) do fn() end
		end
		body(Window, world)
	end, debug.traceback)
	for name, module in pairs(saved) do package.loaded[name] = module end
	if not ok then error(err, 0) end
end

helpers.describe("network field check window (Linux)", function()
	helpers.it("(linux-network-check) runs the steps, records one evidence line and shows the report", function()
		with_window(Ports.new((deps())), function(Window, world)
			helpers.assert_true(Window.run(world.services))
			helpers.assert_eq(#world.evidence, 1)
			helpers.assert_eq(world.evidence[1], "Network check result: check=network verdict=pass steps=7 "
				.. "proxy_settings=info:none pac_download=skip:no_pac pac_script=skip:no_pac "
				.. "route_lookup=pass:selected_direct tls=pass:trusted transfer=pass:http_200 digest=skip:get_only")
			helpers.assert_eq(#world.dialogs, 0, "the dialog opens from a fresh turn of the loop")
			world.flush()
			helpers.assert_eq(world.dialogs[1].title, "[menu.debug.field_check_network]")
			helpers.assert_contains(world.dialogs[1].text, "[field_check.step.route_lookup] : selected_direct")
		end)
	end)

	helpers.it("(linux-network-check) copies exactly what the window shows", function()
		with_window(Ports.new((deps())), function(Window, world)
			world.click = "copy"
			Window.run(world.services)
			world.flush()
			helpers.assert_eq(world.copies[1], world.dialogs[1].text)
			helpers.assert_eq(world.notes[#world.notes], "[field_check.copied]")
		end)
	end)

	helpers.it("(linux-network-check) refuses a second click while a check runs", function()
		local pending
		local collaborators = deps({ http_get = function(_, _, _, callback) pending = callback; return true end })
		with_window(Ports.new(collaborators), function(Window, world)
			helpers.assert_true(Window.run(world.services))
			helpers.assert_true(Window.is_running())
			helpers.assert_true(not Window.run(world.services), "a second click is refused")
			helpers.assert_eq(world.notes[1], "[field_check.busy]")
			pending({ ok = true, status = 200, body = "" })
			helpers.assert_true(not Window.is_running())
			helpers.assert_eq(#world.evidence, 1)
		end)
	end)

	helpers.it("(linux-network-check) an environment the driver cannot build is a failed step", function()
		with_window(nil, function(Window, world)
			world.services.env = function() return nil, "no ports" end
			helpers.assert_true(Window.run(world.services))
			helpers.assert_contains(world.evidence[1], "verdict=fail")
			helpers.assert_contains(world.evidence[1], "proxy_settings=fail:unusable")
			helpers.assert_true(not Window.is_running())
		end)
	end)
end)
