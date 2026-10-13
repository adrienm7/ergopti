--- tests/unit/modules/llm/test_ai_agent_local_model.lua

--- ==============================================================================
--- MODULE: AI Agent Local Model (macOS)
--- DESCRIPTION:
--- Runs the agent on the local backend (Ollama) over the real runner, shared
--- logic, prediction engine and local transport (tests/support/agent_world.lua):
--- the model a System names must be one the local server lists before any
--- chat request is sent, a missing one is named with a Download button that
--- hands it to the AI menu's download owner, and a failed answer logs the
--- server's own error.
---
--- ROOT CAUSES ENCODED:
--- 1. "local" without a model resolves to agent.json's default_models.local
---    (qwen2.5:7b), which nothing ever pulls: the agent posted it blindly and
---    Ollama answered HTTP 404 {"error":"model 'qwen2.5:7b' not found"}.
--- 2. The transport logged the empty transport error instead of that body, and
---    the user only read "The agent could not answer", with nothing to press.
--- ==============================================================================

local helpers = require("tests.helpers")
local World = require("tests.support.agent_world")

local CONFIG = World.CONFIG
local SELECTION = World.SELECTION
local DEFAULT_MODEL = CONFIG.default_models["local"]
local TWO_ACTIONS = World.TWO_ACTIONS
local build_world, trigger = World.build_world, World.trigger

--- Requires an exact refusal from a production callback.
local function assert_false(value, message)
	helpers.assert_eq(value, false, message)
end

--- Drives the real offer and configured endpoint through held native UI ports.
--- @param scenario function
local function with_consent_world(scenario)
	local world = build_world({ system2 = "local" })
	local offer = require("modules.llm.local_model_offer")
	local api = require("modules.llm.api_ollama")
	local storage = require("adapters.storage")
	local before = storage.get("llm.ollama_port")
	local function port(value)
		helpers.assert_true(storage.set("llm.ollama_port", value))
		helpers.assert_eq(api.get_base_url(), "http://127.0.0.1:" .. tostring(value))
	end
	port(11470)
	world.alert_answer = "first"
	local ok, err = xpcall(function() scenario(world, offer, api, port) end, debug.traceback)
	storage.set("llm.ollama_port", before)
	if not ok then error(err, 0) end
end

--- Answers a captured local chat request with a model's text.
--- @param post table
--- @param content string
local function answer_local(post, content)
	post.callback({ ok = true, status = 200, body = require("json").encode({ message = { content = content } }) })
end

--- Answers a captured local chat request with an HTTP failure.
--- @param post table
--- @param status number
--- @param body string
local function fail_local(post, status, body)
	post.callback({ ok = false, status = status, body = body, error = "", headers = {} })
end

--- Asserts that no log line holds the private selection.
--- @param world table
local function assert_selection_never_logged(world)
	for _, line in ipairs(world.logs) do
		helpers.assert_true(not line.text:find(SELECTION, 1, true), "a log line holds the selection: " .. line.text)
	end
end

helpers.describe("AI agent local model (ai-agent-local-model)", function()
	helpers.it("(local-model-requester) refuses an agent Download after its run is reset or superseded in the modal", function()
		for _, change in ipairs({ "reset", "supersede" }) do
			with_consent_world(function(world)
				local dialog = require("infra.dialog_util")
				local previous = dialog.block_alert
				dialog.block_alert = function(...)
					if change == "reset" then world.runner.reset() else trigger(world, "llm_agent_selection") end
					return previous(...)
				end
				trigger(world, "llm_agent_selection")
				World.list_local_models(world, {})
				helpers.assert_eq(#world.installs, 0, "held consent cannot revive the original cancelled requester")
				dialog.block_alert = previous
				world.runner.set_system2("local")
				world.runner.set_mode("action")
				trigger(world, "llm_agent_selection")
				World.list_local_models(world, {})
				helpers.assert_eq(#world.installs, 1, "a fresh current requester still downloads normally")
			end)
		end
	end)

	helpers.it("(local-model-requester) refuses an agent Download after System2 or its mode withdraws the run", function()
		for _, change in ipairs({ "off", "remote", "aba", "mode_off" }) do
			with_consent_world(function(world)
				local dialog = require("infra.dialog_util")
				local previous = dialog.block_alert
				dialog.block_alert = function(...)
					if change == "mode_off" then world.runner.set_mode("off")
					else world.runner.set_system2(change == "remote" and "cerebras" or "") end
					if change == "aba" then world.runner.set_system2("local") end
					return previous(...)
				end
				trigger(world, "llm_agent_selection")
				World.list_local_models(world, {})
				helpers.assert_eq(#world.installs, 0, "selection changes do not grant the old manual requester another download")
				dialog.block_alert = previous
				world.runner.set_mode("action")
				world.runner.set_system2("local")
				trigger(world, "llm_agent_selection")
				World.list_local_models(world, {})
				helpers.assert_eq(#world.installs, 1, "a fresh allowed requester follows the new selection")
			end)
		end
	end)

	helpers.it("(local-model-requester) refuses an expired requester before any endpoint or service acquisition", function()
		with_consent_world(function(world, offer, api)
			local reads = 0
			local capture = api.capture_service_owner
			api.capture_service_owner = function() reads = reads + 1; return capture() end
			local opts = { current = function() return false end }
			assert_false(offer.offer(DEFAULT_MODEL, opts))
			assert_false(offer.install(DEFAULT_MODEL, opts))
			helpers.assert_eq(reads, 0, "expired requester authority must be checked before source readers")
			helpers.assert_eq(#world.alerts, 0)
			helpers.assert_eq(#world.installs, 0)
		end)
	end)

	helpers.it("(local-model-requester) preserves manual downloads and automatic notices while prediction is disabled", function()
		with_consent_world(function(world, offer)
			world.engine.set_llm_enabled(false)
			trigger(world, "llm_agent_selection")
			World.list_local_models(world, {})
			helpers.assert_eq(#world.installs, 1, "action-mode agents remain independent of prediction enablement")
			helpers.assert_true(offer.install(DEFAULT_MODEL, { current = function() return true end }))
			helpers.assert_eq(#world.installs, 2, "explicit menu Download remains allowed")
			helpers.assert_true(offer.offer(DEFAULT_MODEL, { automatic = true }))
			world.runner.reset()
			world.notifications[#world.notifications].on_click()
			helpers.assert_eq(#world.installs, 3, "automatic source-bound notices survive transient requester cancellation")
		end)
	end)

	helpers.it("(local-model-requester) refuses malformed and expired predicates without acquiring private source data", function()
		for _, current in ipairs({ false, 17, function() return nil end, function() return 17 end,
			function() error("private-requester-secret") end }) do
			with_consent_world(function(world, offer, api)
				local reads = 0
				local capture = api.capture_service_owner
				api.capture_service_owner = function() reads = reads + 1; return capture() end
				assert_false(offer.offer(DEFAULT_MODEL, { current = current }))
				assert_false(offer.install(DEFAULT_MODEL, { current = current }))
				helpers.assert_eq(reads, 0)
				helpers.assert_eq(#world.alerts + #world.installs, 0)
				for _, row in ipairs(world.logs) do
					helpers.assert_true(not row.text:find("private-requester-secret", 1, true))
				end
			end)
		end
	end)

	helpers.it("(local-model-requester) rechecks currency after source readers and retains the captured predicate through completion", function()
		with_consent_world(function(world, offer, api)
			local alive = true
			local capture = api.capture_service_owner
			api.capture_service_owner = function() local owner = capture(); alive = false; return owner end
			assert_false(offer.offer(DEFAULT_MODEL, { current = function() return alive end }))
			helpers.assert_eq(#world.alerts + #world.installs, 0)
			api.capture_service_owner = capture
			alive = true
			local options = { current = function() return alive end }
			local done, current
			local forgot = 0
			api.forget_local_models = function() forgot = forgot + 1 end
			offer.set_installer(function(_, callback, predicate) done, current = callback, predicate; return true end)
			local dialog = require("infra.dialog_util")
			local previous = dialog.block_alert
			dialog.block_alert = function(...) options.current = function() return false end; return previous(...) end
			helpers.assert_true(offer.offer(DEFAULT_MODEL, options))
			helpers.assert_true(current(), "mutable options cannot replace the captured predicate")
			alive = false
			assert_false(current())
			done(true)
			helpers.assert_eq(forgot, 0, "stale completion cannot invalidate another requester's inventory")
		end)
	end)

	helpers.it("(local-model-consent-affinity) refuses a held Download after the actual configured endpoint changes", function()
		with_consent_world(function(world, offer, _, port)
			local dialog = require("infra.dialog_util")
			local previous = dialog.block_alert
			dialog.block_alert = function(...)
				port(11471)
				return previous(...)
			end
			assert_false(offer.offer(DEFAULT_MODEL), "A's consent must not acquire B's download")
			helpers.assert_eq(#world.installs, 0)
			dialog.block_alert = previous
			helpers.assert_true(offer.offer(DEFAULT_MODEL))
			helpers.assert_eq(#world.installs, 1, "a fresh B consent still downloads normally")
		end)
	end)

	helpers.it("(local-model-consent-affinity) refuses installer replacement and same-function registration ABA during a dialog", function()
		for _, reset in ipairs({ false, true }) do
			with_consent_world(function(world, offer)
				local old_calls, new_calls = 0, 0
				local original = function() old_calls = old_calls + 1; return true end
				offer.set_installer(original)
				local dialog = require("infra.dialog_util")
				local previous = dialog.block_alert
				dialog.block_alert = function(...)
					if reset then offer.reset(); offer.set_installer(original)
					else offer.set_installer(function() new_calls = new_calls + 1; return true end) end
					return previous(...)
				end
				assert_false(offer.offer(DEFAULT_MODEL))
				helpers.assert_eq(old_calls, 0)
				helpers.assert_eq(new_calls, 0)
				dialog.block_alert = previous
			end)
		end
	end)

	helpers.it("(local-model-consent-affinity) fences stale notification clicks while a new endpoint receives its own offer", function()
		with_consent_world(function(world, offer, _, port)
			helpers.assert_true(offer.offer(DEFAULT_MODEL, { automatic = true }))
			local old = world.notifications[1]
			port(11471)
			old.on_click()
			helpers.assert_eq(#world.alerts, 0, "an A notification must not open B's consent")
			helpers.assert_eq(#world.installs, 0)
			helpers.assert_true(offer.offer(DEFAULT_MODEL, { automatic = true }))
			helpers.assert_eq(#world.notifications, 2, "notification deduplication belongs to its origin")
			assert_false(offer.offer(DEFAULT_MODEL, { automatic = true }))
			world.notifications[2].on_click()
			helpers.assert_eq(#world.alerts, 1)
			helpers.assert_eq(#world.installs, 1)
		end)
	end)

	helpers.it("(local-model-consent-affinity) fences replaced notification registrations without starving their successor", function()
		with_consent_world(function(world, offer)
			helpers.assert_true(offer.offer(DEFAULT_MODEL, { automatic = true }))
			local old = world.notifications[1]
			local calls = 0
			offer.set_installer(function() calls = calls + 1; return true end)
			old.on_click()
			helpers.assert_eq(#world.alerts, 0)
			helpers.assert_eq(calls, 0)
			helpers.assert_true(offer.offer(DEFAULT_MODEL, { automatic = true }))
			world.notifications[2].on_click()
			helpers.assert_eq(calls, 1)
		end)
	end)

	helpers.it("(local-model-notice-admission) refuses retained clicks from unacknowledged notifications", function()
		for _, response in ipairs({ false, "accepted", "throw", true }) do
			with_consent_world(function(world, offer)
				local notify = require("infra.notifications")
				local retained
				notify.notify = function(_, _, _, on_click)
					retained = on_click
					on_click()
					helpers.assert_eq(#world.installs, 0, "an early callback cannot manufacture send admission")
					if response == "throw" then error("private-notification-secret") end
					return response
				end
				helpers.assert_eq(offer.offer(DEFAULT_MODEL, { automatic = true }), response == true)
				if response == true then
					helpers.assert_eq(#world.installs, 1, "an accepted send delivers its queued current click once")
					retained()
					helpers.assert_eq(#world.installs, 1)
				else
					retained()
					helpers.assert_eq(#world.alerts, 0)
					helpers.assert_eq(#world.installs, 0)
				end
				for _, line in ipairs(world.logs) do
					assert_false(line.text:find("private-notification-secret", 1, true) ~= nil)
				end
			end)
		end
	end)

	helpers.it("(local-model-consent-affinity) keeps a late A completion from invalidating B's cache or notification", function()
		with_consent_world(function(world, offer, api, port)
			local forgets = 0
			api.forget_local_models = function() forgets = forgets + 1 end
			helpers.assert_true(offer.install(DEFAULT_MODEL))
			port(11471)
			helpers.assert_true(offer.offer(DEFAULT_MODEL, { automatic = true }))
			world.installs[1].on_done(true)
			helpers.assert_eq(forgets, 0, "A's completion cannot invalidate B's acknowledged cache")
			assert_false(offer.offer(DEFAULT_MODEL, { automatic = true }), "B's notice is still owned")
		end)
	end)

	helpers.it("(local-model-notice-affinity) keeps a newer same-source notice after an older pull succeeds", function()
		for _, earlier_notice in ipairs({ false, true }) do
			with_consent_world(function(world, offer)
				if earlier_notice then
					helpers.assert_true(offer.offer(DEFAULT_MODEL, { automatic = true }))
					helpers.assert_true(offer.install(DEFAULT_MODEL))
				end
				helpers.assert_true(offer.install(DEFAULT_MODEL))
				local older_pull = world.installs[#world.installs]
				if earlier_notice then world.installs[1].on_done(true) end
				helpers.assert_true(offer.offer(DEFAULT_MODEL, { automatic = true }))
				local newer_notice = world.notifications[#world.notifications]
				older_pull.on_done(true)
				assert_false(offer.offer(DEFAULT_MODEL, { automatic = true }),
					"an old success must not clear a notice posted after its installation admission")
				newer_notice.on_click()
				world.installs[#world.installs].on_done(true)
				helpers.assert_true(offer.offer(DEFAULT_MODEL, { automatic = true }),
					"the exact current notice is cleared by its own completed download")
			end)
		end
	end)

	helpers.it("(local-model-consent-affinity) accepts one current completion and ignores repeats or registration replacement", function()
		with_consent_world(function(world, offer, api)
			local forgets = 0
			api.forget_local_models = function() forgets = forgets + 1 end
			helpers.assert_true(offer.install(DEFAULT_MODEL))
			world.installs[1].on_done(true)
			world.installs[1].on_done(true)
			helpers.assert_eq(forgets, 1, "the registered callback is one-shot")
			helpers.assert_true(offer.install(DEFAULT_MODEL))
			offer.set_installer(function() return true end)
			world.installs[2].on_done(true)
			helpers.assert_eq(forgets, 1, "a replaced installer cannot affect its successor's cache")
		end)
	end)

	helpers.it("(local-model-consent-affinity) publishes synchronous completion only after exact installer admission", function()
		with_consent_world(function(_, offer, api)
			local forgets = 0
			api.forget_local_models = function() forgets = forgets + 1 end
			offer.set_installer(function(_, done) done(true); return false end)
			assert_false(offer.install(DEFAULT_MODEL))
			helpers.assert_eq(forgets, 0, "a callback cannot manufacture refused installation admission")
			offer.set_installer(function(_, done) done(true); return true end)
			helpers.assert_true(offer.install(DEFAULT_MODEL))
			helpers.assert_eq(forgets, 1)
			offer.set_installer(function() return false end)
			assert_false(offer.offer(DEFAULT_MODEL), "the Download button reports dispatch refusal truthfully")
		end)
	end)

	helpers.it("(local-model-consent-affinity) refuses malformed endpoint acquisition without leaking its error", function()
		with_consent_world(function(world, offer, api)
			api.get_base_url = function() error("private-endpoint-secret") end
			assert_false(offer.offer(DEFAULT_MODEL))
			helpers.assert_eq(#world.alerts, 0)
			helpers.assert_eq(#world.installs, 0)
			for _, line in ipairs(world.logs) do
				assert_false(line.text:find("private-endpoint-secret", 1, true) ~= nil)
			end
		end)
		for _, malformed in ipairs({ false, 17, "" }) do
			with_consent_world(function(world, offer, api)
				api.get_base_url = function() return malformed end
				assert_false(offer.offer(DEFAULT_MODEL))
				helpers.assert_eq(#world.alerts, 0)
				helpers.assert_eq(#world.installs, 0)
			end)
		end
		with_consent_world(function(world, offer, api)
			local old = api.get_base_url
			api.get_base_url = function()
				api.get_base_url = old
				return old()
			end
			assert_false(offer.offer(DEFAULT_MODEL), "endpoint reader replacement during acquisition is refused")
			helpers.assert_eq(#world.alerts, 0)
			helpers.assert_eq(#world.installs, 0)
			helpers.assert_true(offer.offer(DEFAULT_MODEL), "the stable reader permits fresh consent")
			helpers.assert_eq(#world.installs, 1)
		end)
		for _, reader in ipairs({
			function() return nil end,
			function() return false end,
			function() error("private-service-secret") end,
			function() return function() return nil end end,
			function() return function() return false end end,
			function() return function() error("private-service-secret") end end,
		}) do
			with_consent_world(function(world, offer, api)
				api.capture_service_owner = reader
				assert_false(offer.offer(DEFAULT_MODEL))
				helpers.assert_eq(#world.alerts, 0)
				helpers.assert_eq(#world.installs, 0)
				for _, line in ipairs(world.logs) do
					assert_false(line.text:find("private-service-secret", 1, true) ~= nil)
				end
			end)
		end
		with_consent_world(function(world, offer)
			world.alert_answer = "cancel"
			helpers.assert_true(offer.offer(DEFAULT_MODEL))
			helpers.assert_eq(#world.installs, 0, "cancellation does not dispatch")
			world.alert_answer = "first"
			helpers.assert_true(offer.offer(DEFAULT_MODEL))
			helpers.assert_eq(#world.installs, 1, "cancellation releases the dialog owner")
		end)
	end)
	helpers.it("(ai-agent-local-model) sends nothing before the local server lists the model, then posts it", function()
		helpers.assert_eq(DEFAULT_MODEL, "qwen2.5:7b", "agent.json's local default, the model of the report")
		local world = build_world({ system2 = "local" })
		trigger(world, "llm_agent_selection")
		helpers.assert_eq(#world.posts, 0, "no chat request names an unverified model")
		helpers.assert_eq(#world.gets, 1, "the local server is asked for its models")
		helpers.assert_true(world.gets[1].url:match("/api/tags$") ~= nil, world.gets[1].url)

		World.list_local_models(world, { "llama3.2:3b", DEFAULT_MODEL })
		helpers.assert_eq(#world.posts, 1, "the listed model is requested")
		helpers.assert_true(world.posts[1].url:match("/api/chat$") ~= nil, world.posts[1].url)
		helpers.assert_eq(world.posts[1].body.model, DEFAULT_MODEL)
		answer_local(world.posts[1], TWO_ACTIONS)
		helpers.assert_eq(#world.renders[#world.renders].texts, 2, "the actions are offered")

		-- A verified model is not listed again; a named one is matched as the
		-- server names it, its implicit ":latest" tag included
		trigger(world, "llm_agent_selection")
		helpers.assert_eq(#world.gets, 1, "the verified model is not listed again")
		helpers.assert_eq(#world.posts, 2)
		world.runner.set_system2("local|Mistral")
		trigger(world, "llm_agent_selection")
		helpers.assert_eq(#world.gets, 2, "another model is verified first")
		World.list_local_models(world, { "mistral:latest" })
		helpers.assert_eq(world.posts[3].body.model, "Mistral")
		helpers.assert_eq(#world.alerts, 0, "nothing is missing")
	end)

	helpers.it("(ai-agent-local-model) names a model the local server lacks, never requests it, and downloads it", function()
		local world = build_world({ system2 = "local" })
		world.alert_answer = "first"
		trigger(world, "llm_agent_selection")
		World.list_local_models(world, { "llama3.2:3b" })
		helpers.assert_eq(#world.posts, 0, "the missing model is never requested")
		helpers.assert_eq(#world.alerts, 1, "the user is told, with a button")
		local alert = world.alerts[1]
		helpers.assert_eq(alert.title, world.i18n.get("llm.local_model.missing_title"))
		helpers.assert_eq(alert.message, world.i18n.format("llm.local_model.missing_body", DEFAULT_MODEL))
		helpers.assert_true(alert.message:find(DEFAULT_MODEL, 1, true) ~= nil, "the missing model is named")
		helpers.assert_eq(alert.buttons[1], world.i18n.get("menu.llm.btn_download"))
		helpers.assert_eq(alert.buttons[2], world.i18n.get("common.cancel"))
		helpers.assert_eq(#world.installs, 1, "the Download button hands the model to the download owner")
		helpers.assert_eq(world.installs[1].model, DEFAULT_MODEL)
		for _, notice in ipairs(world.notices) do
			helpers.assert_true(notice ~= world.i18n.get("llm.agent.failed"), "no vague failure over the named one")
		end

		-- Once downloaded, the next request lists the models again and posts
		world.installs[1].on_done(true)
		trigger(world, "llm_agent_selection")
		helpers.assert_eq(#world.gets, 2)
		World.list_local_models(world, { DEFAULT_MODEL })
		helpers.assert_eq(#world.posts, 1)
		helpers.assert_eq(world.posts[1].body.model, DEFAULT_MODEL)

		-- Cancel downloads nothing
		local declined = build_world({ system2 = "local" })
		trigger(declined, "llm_agent_selection")
		World.list_local_models(declined, {})
		helpers.assert_eq(#declined.alerts, 1)
		helpers.assert_eq(#declined.installs, 0, "Cancel downloads nothing")
	end)

	helpers.it("(ai-agent-local-model) reads a 404 model-not-found body, names the model and offers its download", function()
		local world = build_world({ system2 = "local" })
		world.alert_answer = "first"
		trigger(world, "llm_agent_selection")
		World.list_local_models(world, { DEFAULT_MODEL })
		helpers.assert_eq(#world.posts, 1)
		-- Removed since it was listed: Ollama 0.24's scheduler answer
		fail_local(world.posts[1], 404, '{"error":"model \\"qwen2.5:7b\\" not found, try pulling it first"}')
		helpers.assert_true(World.logged(world, "error", 'HTTP 404 (model "qwen2.5:7b" not found, try pulling it first)'),
			"the server's error is logged")
		helpers.assert_eq(#world.alerts, 1, "the missing model is named, with a button")
		helpers.assert_eq(world.alerts[1].message, world.i18n.format("llm.local_model.missing_body", DEFAULT_MODEL))
		helpers.assert_eq(#world.installs, 1)
		helpers.assert_eq(world.installs[1].model, DEFAULT_MODEL)
		assert_selection_never_logged(world)

		-- The listing was stale: the next request verifies the model again
		trigger(world, "llm_agent_selection")
		helpers.assert_eq(#world.posts, 1, "not requested again before a new listing")
		helpers.assert_true(#world.gets >= 1 and not world.gets[#world.gets].answered, "a new listing is asked for")

		-- The chat handler's own wording (single quotes) is read as well
		local other = build_world({ system2 = "local|qwen3:14b" })
		trigger(other, "llm_agent_selection")
		World.list_local_models(other, { "qwen3:14b" })
		fail_local(other.posts[1], 404, '{"error":"model \'qwen3:14b\' not found"}')
		helpers.assert_eq(#other.alerts, 1)
		helpers.assert_eq(other.alerts[1].message, other.i18n.format("llm.local_model.missing_body", "qwen3:14b"))
	end)

	helpers.it("(ai-agent-local-model) logs the server's error body of any other failure, never the request", function()
		local world = build_world({ system2 = "local" })
		trigger(world, "llm_agent_selection")
		World.list_local_models(world, { DEFAULT_MODEL })
		fail_local(world.posts[1], 500, '{"error":"llama runner process has terminated: signal: killed"}')
		helpers.assert_true(World.logged(world, "error",
			"HTTP 500 (llama runner process has terminated: signal: killed)"), "the server's error is logged")
		helpers.assert_eq(#world.alerts, 0, "no download is offered for another failure")
		helpers.assert_eq(world.notices[#world.notices], world.i18n.get("llm.agent.failed"))
		assert_selection_never_logged(world)

		-- A plain-text 404 (a server without /api/chat) is not a missing model
		local old = build_world({ system2 = "local" })
		trigger(old, "llm_agent_selection")
		World.list_local_models(old, { DEFAULT_MODEL })
		fail_local(old.posts[1], 404, "404 page not found")
		helpers.assert_true(World.logged(old, "error", "HTTP 404 (404 page not found)"), "the body is logged")
		helpers.assert_eq(#old.alerts, 0, "no model is named when none is missing")
	end)

	helpers.it("(ai-agent-local-model) the automatic mode notifies once instead of opening a dialog while typing", function()
		local world = build_world({ system1 = "local", system2 = "cerebras", mode = "auto" })
		world.runner.observe_typing("Bonjour. Rappelle-moi d'appeler Paul demain à 9h")
		World.settle(world)
		helpers.assert_eq(#world.gets, 1, "System 1's local model is verified first")
		World.list_local_models(world, {})
		helpers.assert_eq(#world.posts, 0, "the missing model is never requested")
		helpers.assert_eq(#world.alerts, 0, "no dialog takes the keystrokes")
		helpers.assert_eq(#world.notifications, 1)
		local notification = world.notifications[1]
		helpers.assert_eq(notification.title, world.i18n.get("llm.local_model.missing_title"))
		helpers.assert_eq(notification.body, world.i18n.format("llm.local_model.missing_click", DEFAULT_MODEL))

		world.runner.observe_typing("Bonjour. Rappelle-moi d'appeler Paul demain à 10h")
		World.settle(world)
		World.list_local_models(world, {})
		helpers.assert_eq(#world.notifications, 1, "one notification per model")

		-- Its click opens the dialog, whose button downloads the model
		world.alert_answer = "first"
		notification.on_click()
		helpers.assert_eq(#world.alerts, 1)
		helpers.assert_eq(#world.installs, 1)
		helpers.assert_eq(world.installs[1].model, DEFAULT_MODEL)
	end)
end)
