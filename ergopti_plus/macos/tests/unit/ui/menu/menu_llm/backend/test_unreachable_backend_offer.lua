--- tests/unit/ui/menu/menu_llm/backend/test_unreachable_backend_offer.lua

--- ==============================================================================
--- MODULE: Unreachable Backend Offer Building Blocks
--- DESCRIPTION:
--- The pieces the error of an unreachable Ollama stands on
--- (llm-enable-unreachable-local drives them end to end):
--- - dialog_util.choose asks with one button per fix, beyond the two buttons of
---   hs.dialog.blockAlert, and escapes every label into its AppleScript;
--- - a local-server sweep that a newer sweep supersedes still tells its caller
---   when fresh verdicts exist, so the error always opens;
--- - the offer lists the servers that the real sweep found answering, each with
---   its first model, and survives a dialog that fails.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("json")




-- =====================================
-- =====================================
-- ======= 1/ Helpers ==================
-- =====================================
-- =====================================

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

--- Loads dialog_util with a recording AppleScript runner.
--- @param answer function (script) -> ok, result, raw
--- @param callback function Receives (Dialog, scripts).
local function with_dialog(answer, callback)
	helpers.with_fresh_modules({ "infra.dialog_util", "infra.logger", "adapters.shell_runner",
		"adapters.timer_scheduler" }, function()
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		local scripts = {}
		local Dialog = helpers.load_with_stubs("infra.dialog_util", {
			osascript = {
				applescript = function(script)
					scripts[#scripts + 1] = script
					return answer(script)
				end,
			},
			focus = function() return true end,
		})
		callback(Dialog, scripts)
	end)
end

--- A models answer of the OpenAI dialect.
--- @param ids table Model ids.
--- @return table response
local function models_answer(ids)
	local data = {}
	for index, id in ipairs(ids) do data[index] = { id = id, object = "model" } end
	return { ok = true, status = 200, body = json.encode({ object = "list", data = data }), headers = {} }
end




-- =====================================
-- =====================================
-- ======= 2/ Dialog ===================
-- =====================================
-- =====================================

helpers.describe("A choice among several fixes (unreachable-backend-dialog)", function()
	helpers.it("two fixes are two buttons of one alert, the first the default (unreachable-backend-dialog)", function()
		with_dialog(function() return true, "Use \"oMLX\" 50%", "" end, function(Dialog, scripts)
			local index = Dialog.choose("Ollama ne répond pas", "Rien à C:\\x", { "Use \"oMLX\" 50%", "Start" },
				"Keep off", "Apply")
			helpers.assert_eq(index, 1)
			local script = scripts[1]
			helpers.assert_true(script:find('display dialog "Rien à C:\\\\x" with title "ErgoptiPlus — Ollama ne répond pas"', 1, true) ~= nil,
				script)
			helpers.assert_true(script:find('buttons {"Keep off", "Start", "Use \\"oMLX\\" 50%"}', 1, true) ~= nil,
				"cancel at the left, the preferred fix at the right: " .. script)
			helpers.assert_true(script:find('default button "Use \\"oMLX\\" 50%" cancel button "Keep off"', 1, true) ~= nil,
				script)
			helpers.assert_true(script:find("on error number -128", 1, true) ~= nil, "a cancel is an answer, not an error")
		end)
	end)

	helpers.it("more fixes than an alert holds are a list (unreachable-backend-dialog)", function()
		with_dialog(function() return true, "C", "" end, function(Dialog, scripts)
			helpers.assert_eq(Dialog.choose("T", "M", { "A", "B", "C" }, "Keep off", "Apply"), 3)
			helpers.assert_true(scripts[1]:find('choose from list {"A", "B", "C"}', 1, true) ~= nil, scripts[1])
			helpers.assert_true(scripts[1]:find('with title "ErgoptiPlus — T" with prompt "M"', 1, true) ~= nil,
				scripts[1])
			helpers.assert_true(scripts[1]:find('default items {"A"} OK button name "Apply" cancel button name "Keep off"',
				1, true) ~= nil, scripts[1])
		end)
	end)

	helpers.it("cancel answers nil; a failed dialog or an unknown answer raises (unreachable-backend-dialog)", function()
		with_dialog(function() return true, "", "" end, function(Dialog)
			helpers.assert_nil(Dialog.choose("T", "M", { "A" }, "Keep off", "Apply"))
		end)
		with_dialog(function() return false, { NSAppleScriptErrorNumber = -1 }, "denied" end, function(Dialog)
			local ok, err = pcall(Dialog.choose, "T", "M", { "A" }, "Keep off", "Apply")
			helpers.assert_eq(ok, false)
			helpers.assert_true(tostring(err):find("the dialog failed", 1, true) ~= nil, tostring(err))
		end)
		with_dialog(function() return true, "Z", "" end, function(Dialog)
			local ok, err = pcall(Dialog.choose, "T", "M", { "A" }, "Keep off", "Apply")
			helpers.assert_eq(ok, false)
			helpers.assert_true(tostring(err):find("unknown choice", 1, true) ~= nil, tostring(err))
		end)
		with_dialog(function() return true, "A", "" end, function(Dialog, scripts)
			local ok, err = pcall(Dialog.choose, "T", "M", { "A", "A" }, "Keep off", "Apply")
			helpers.assert_eq(ok, false)
			helpers.assert_true(tostring(err):find("distinct non-empty labels", 1, true) ~= nil,
				"two identical buttons could not be told apart: " .. tostring(err))
			helpers.assert_eq(#scripts, 0, "nothing is shown for an invalid choice")
		end)
	end)
end)




-- =====================================
-- =====================================
-- ======= 3/ Sweep And Offer ==========
-- =====================================
-- =====================================

--- Runs a scenario over the real remote backend and detection, with the
--- probe clients faked, and the offer module loaded fresh.
--- @param scenario function Receives (Offer, world).
local function with_offer(scenario)
	helpers.with_fresh_modules({
		"modules.llm.local_servers", "modules.llm.api_remote", "modules.llm",
		"modules.llm.ollama_endpoint", "infra.dialog_util", "infra.notifications",
		"ui.menu.menu_llm.runtime_install_offer", "ui.menu.menu_llm.unreachable_backend_offer",
		"infra.i18n",
	}, function()
		local api = helpers.load_with_stubs("modules.llm.api_remote")
		local LocalServers = require("modules.llm.local_servers")
		local world = { probes = {}, dialogs = {}, actions = {}, installed = false }
		local probe_clients = get_upvalue(api.detect_local_servers, "_local_probe_clients")
		assert(type(probe_clients) == "table", "the probe clients must be reachable")
		world.native_clients = {}
		for _, id in ipairs(LocalServers.ORDER) do
			local active, observers = nil, {}
			local client = {}
			local function retire(request)
				if active ~= request then return false end
				active = nil
				local pending = observers
				observers = {}
				for _, callback in ipairs(pending) do callback() end
				return true
			end
			-- Each HTTP double retains one exact request. Accepted cancellation
			-- retires it immediately unless a scenario deliberately holds cleanup.
			function client.get(url, _, callback)
				assert(active == nil, "a native predecessor must retire before another get")
				local request = { cancelled = false }
				active = request
				world.probes[#world.probes + 1] = { id = id, url = url, callback = function(response)
					if retire(request) ~= true or request.cancelled then return false end
					return callback(response)
				end }
				return true
			end
			function client.cancel()
				if active == nil then return true end
				active.cancelled = true
				if world.hold_cancellation then return false end
				return retire(active)
			end
			function client.isSettled() return active == nil end
			function client.onSettled(callback)
				assert(type(callback) == "function")
				if active == nil then callback() else observers[#observers + 1] = callback end
				return true
			end
			function client.settle_cancelled()
				assert(active ~= nil and active.cancelled, "only the original cancelled request can retire")
				return retire(active)
			end
			world.native_clients[id] = client
			probe_clients[id] = client
		end
		package.loaded["modules.llm"] = { api_remote = api, DEFAULT_STATE = { llm_ollama_port = 11434 } }
		package.loaded["ui.menu.menu_llm.runtime_install_offer"] = {
			is_installed = function() return world.installed end,
		}
		package.loaded["infra.dialog_util"] = {
			choose = function(title, message, choices, cancel)
				world.dialogs[#world.dialogs + 1] = { title = title, message = message, choices = choices, cancel = cancel }
				if world.dialog_error then error(world.dialog_error) end
				return world.pick
			end,
		}
		package.loaded["infra.notifications"] = { notify = function() return true end }
		-- format keeps its arguments visible: "key|arg1|arg2"
		package.loaded["infra.i18n"] = {
			get = function(key) return key end,
			format = function(key, ...)
				local parts = { key }
				for _, value in ipairs({ ... }) do parts[#parts + 1] = tostring(value) end
				return table.concat(parts, "|")
			end,
		}
		local Offer = require("ui.menu.menu_llm.unreachable_backend_offer")
		Offer.reset()
		--- Answers the last probe of every server: those not named are down.
		function world.answer(answers)
			local latest = {}
			for _, probe in ipairs(world.probes) do latest[probe.id] = probe end
			for _, id in ipairs(LocalServers.ORDER) do
				latest[id].callback(answers[id] or { ok = false, status = 0, error = "connection refused" })
			end
		end
		world.request = {
			backend = "ollama",
			actions = {
				use_server = function(id, model) world.actions[#world.actions + 1] = "use:" .. id .. ":" .. model; return true end,
				start = function() world.actions[#world.actions + 1] = "start"; return true end,
				install = function() world.actions[#world.actions + 1] = "install"; return true end,
			},
		}
		scenario(Offer, world, api, LocalServers)
	end)
end

helpers.describe("The offer lists what the real sweep found (unreachable-backend-dialog)", function()
	helpers.it("a server that answers is a button with its first model and its address (unreachable-backend-dialog)",
		function()
			with_offer(function(Offer, world)
				world.pick = 1
				helpers.assert_eq(Offer.offer(world.request), true)
				helpers.assert_eq(#world.dialogs, 0, "the error waits for the fresh sweep")
				helpers.assert_eq(#world.probes, 4, "every local server is probed")
				world.answer({ omlx = models_answer({ "Qwen3-8B-4bit", "gemma-3-4b-it" }) })
				helpers.assert_eq(#world.dialogs, 1)
				local dialog = world.dialogs[1]
				helpers.assert_eq(dialog.choices, {
					"llm.unreachable.use_server|oMLX|Qwen3-8B-4bit|127.0.0.1:8000",
					"llm.unreachable.install|Ollama",
				})
				helpers.assert_true(dialog.message:find("llm.unreachable.body_missing|Ollama|http://127.0.0.1:11434", 1, true)
					~= nil, dialog.message)
				helpers.assert_true(dialog.message:find("llm.unreachable.servers_found|oMLX", 1, true) ~= nil, dialog.message)
				helpers.assert_eq(world.actions, { "use:omlx:Qwen3-8B-4bit" })
			end)
		end)

	helpers.it("a newer sweep carries the older one's caller, so the error still opens (unreachable-backend-dialog)",
		function()
			with_offer(function(Offer, world, api)
				world.pick = nil
				local menu_sweeps = 0
				Offer.offer(world.request)
				-- The menu searches again before the first sweep answered
				api.detect_local_servers(function() menu_sweeps = menu_sweeps + 1 end)
				helpers.assert_eq(#world.probes, 8)
				world.answer({ lmstudio = models_answer({ "qwen2.5-7b-instruct" }) })
				helpers.assert_eq(menu_sweeps, 1)
				helpers.assert_eq(#world.dialogs, 1, "the superseded caller hears the newer verdicts")
				helpers.assert_eq(#world.dialogs[1].choices, 2)
				helpers.assert_eq(world.actions, {}, "keeping the AI off runs no fix")
			end)
		end)

	helpers.it("a dialog that fails is logged and the next failure asks again (unreachable-backend-dialog)", function()
		with_offer(function(Offer, world)
			world.installed = true
			world.dialog_error = "AppleScript refused"
			Offer.offer(world.request)
			world.answer({})
			helpers.assert_eq(#world.dialogs, 1)
			helpers.assert_eq(world.dialogs[1].choices, { "llm.unreachable.start|Ollama" },
				"an installed Ollama is started, not downloaded")
			world.dialog_error = nil
			world.pick = 1
			helpers.assert_eq(Offer.offer(world.request), true, "the failed dialog no longer counts as open")
			world.answer({})
			helpers.assert_eq(world.actions, { "start" })
		end)
	end)
end)

helpers.describe("Unreachable offer exact native predecessor (unreachable-backend-native-owner)", function()
	helpers.it("keeps the original caller pending until cancelled native requests retire and fresh answers arrive (unreachable-backend-native-owner)", function()
		with_offer(function(Offer, world, api, LocalServers)
			world.pick = nil
			Offer.offer(world.request)
			helpers.assert_eq(#world.probes, 4)
			helpers.assert_eq(#world.dialogs, 0)
			local old = {}
			for index, probe in ipairs(world.probes) do old[index] = probe.callback end
			world.hold_cancellation = true
			local menu_sweeps = 0
			api.detect_local_servers(function() menu_sweeps = menu_sweeps + 1 end)
			helpers.assert_eq(#world.probes, 4, "refused native cancellation cannot acquire successor requests")
			helpers.assert_eq(#world.dialogs, 0)
			helpers.assert_eq(menu_sweeps, 0)
			for _, id in ipairs(LocalServers.ORDER) do
				helpers.assert_eq(world.native_clients[id].isSettled(), false)
				helpers.assert_true(world.native_clients[id].settle_cancelled())
			end
			helpers.assert_eq(#world.probes, 8, "only actual predecessor terminals admit the new sweep")
			helpers.assert_eq(#world.dialogs, 0, "physical retirement alone is not a models verdict")
			for _, callback in ipairs(old) do
				helpers.assert_eq(callback(models_answer({ "stale-model" })), false)
			end
			helpers.assert_eq(#world.dialogs, 0)
			helpers.assert_eq(menu_sweeps, 0)
			world.answer({ omlx = models_answer({ "fresh-model" }) })
			helpers.assert_eq(menu_sweeps, 1)
			helpers.assert_eq(#world.dialogs, 1)
			helpers.assert_eq(world.actions, {})
			helpers.assert_true(world.dialogs[1].choices[1]:find("fresh-model", 1, true) ~= nil)
			helpers.assert_nil(world.dialogs[1].choices[1]:find("stale-model", 1, true))
		end)
	end)
end)
