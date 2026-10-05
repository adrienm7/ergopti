--- tests/unit/modules/llm/test_enable_admission.lua

--- ==============================================================================
--- MODULE: Linux Owned AI Enable Admission
--- DESCRIPTION:
--- Exercises real controller ownership, then the engine and durable preference
--- seams. Scripted HTTP receipts represent actual terminal adapter fields.
--- ==============================================================================

local helpers = require("tests.helpers")
local function test(name, body) helpers.it(name .. " (ai-enable-admission)", body) end
local PreferencesFixture = require("tests.support.llm_preferences_fixture")

local function with_owner(body, options)
	options = options or {}
	local names = { "adapters.http_client", "modules.llm.enable_admission", "ui.llm_enable_refusal",
		"modules.llm.prediction_engine", "modules.llm.profiles", "infra.llm_preferences",
		"modules.llm.local_servers", "modules.llm.api_entries", "adapters.keyboard_hook",
		"adapters.shell_runner", "infra.i18n", "window_titles" }
	local previous = {}
	for _, name in ipairs(names) do previous[name] = package.loaded[name] end
	local world = { calls = {}, commits = {}, rejects = {}, changes = 0, cancels = {}, cancel_ok = true }
	world.live = { backend = "ollama", model = "model:2b", origin = "http://127.0.0.1:11434",
		generation = 1, enabled = false, paused = false, blocked = false, source = { status = "absent" } }
	local Http = {
		get = function(url, _, request, callback)
			world.calls[#world.calls + 1] = { url = url, request = request, callback = callback }
			if options.synchronous then callback(options.synchronous) end
			return options.dispatched ~= false
		end,
		cancel = function(owner)
			world.cancels[#world.cancels + 1] = owner
			return world.cancel_ok
		end,
	}
	world.owned_http = {}
	package.loaded["adapters.http_client"] = require("tests.support.owned_http_fixture").attach(Http, world.owned_http)
	package.loaded["modules.llm.enable_admission"] = nil
	world.owner = require("modules.llm.enable_admission").new({
		snapshot = function()
			if world.unreadable then error("unreadable source") end
			local snapshot = {}
			for key, value in pairs(world.live) do snapshot[key] = value end
			return snapshot
		end,
		commit = function(source)
			world.commits[#world.commits + 1] = source
			return world.write_ok ~= false
		end,
		reject = function(origin, reason, _, _, _, cleanup_only)
			world.rejects[#world.rejects + 1] = { origin, reason }
			world.cleanup_only = cleanup_only
			if world.on_reject then world.on_reject() end
			return world.choice
		end,
		changed = function() world.changes = world.changes + 1 end,
	})
	world.good = { ok = true, status = 200, body = '{"version":"0.12.3"}' }
	function world.answer(receipt, index) world.calls[index or #world.calls].callback(receipt or world.good) end
	function world.load_engine(backend)
		local preferences = PreferencesFixture.new({ initial = {
			["llm.enabled"] = false, ["llm.models.selected"] = backend or "ollama",
			["llm.models.ollama"] = "model:2b",
		} })
		package.loaded["infra.llm_preferences"] = preferences
		package.loaded["modules.llm.profiles"] = nil
		package.loaded["modules.llm.prediction_engine"] = nil
		world.private_source, world.private_current, world.view_current = {}, true, true
		world.servers = {
			is_stale = function() return world.discovery_stale ~= false end,
			is_sweeping = function() return world.sweeping == true end,
			detected = function() return { "lm_studio" } end,
			result = function() return { status = "up", models = { "typed:model" }, base_url = "http://127.0.0.1:1234/v1" } end,
			servers = function() return { lm_studio = { label = "LM Studio" } } end,
			capture = function() return world.private_source end,
			is_current = function(receipt, model)
				return world.view_current and receipt == world.private_source and model == "typed:model"
			end,
			apply = function(receipt, fields, admit)
				if not admit() or not world.servers.is_current(receipt, fields.model) or world.apply_refused then return nil end
				world.applied = (world.applied or 0) + 1
				world.active_entry = { id = "local-entry", model = fields.model }
				if world.after_apply then world.after_apply(preferences) end
				return { saved = true, entry = world.active_entry }
			end,
		}
		package.loaded["modules.llm.local_servers"] = world.servers
		package.loaded["modules.llm.api_entries"] = {
			capture_source = function() return world.private_source end,
			source_is_current = function(source) return world.private_current and source == world.private_source end,
			active = function() return world.active_entry end,
		}
		package.loaded["ui.llm_enable_refusal"] = { show = function(origin, replacements)
			world.rejects[#world.rejects + 1] = { origin }
			world.replacements = replacements
			if world.on_notice then world.on_notice(preferences) end
			local selected = replacements and replacements[world.choice_index or 0]
			return true, false, selected and selected.value
		end }
		world.engine = require("modules.llm.prediction_engine")
		world.engine.init({ is_paused = function() return world.live.paused end })
		return world.engine, preferences
	end
	function world.use_native_notice()
		package.loaded["adapters.shell_runner"] = {
			has_command = function(name) return name == "zenity" end,
			quote = function(value) return "'" .. value:gsub("'", "'\\''") .. "'" end,
			exec_checked = function()
				if world.during_dialog then world.during_dialog() end
				return true, world.native_answer or "replacement_1\n"
			end,
		}
		package.loaded["infra.i18n"] = { get = function(key) return key end }
		package.loaded["window_titles"] = { compose = function(value) return value end }
		local Hook = helpers.load_module("adapters.keyboard_hook")
		package.loaded["ui.llm_enable_refusal"] = nil
		return Hook
	end
	local ok, err = xpcall(function() body(world) end, debug.traceback)
	for _, name in ipairs(names) do package.loaded[name] = previous[name] end
	if not ok then error(err, 0) end
end

helpers.describe("owned Linux enable version admission", function()
	test("exposes the actual master and backend revision to retained streaming commands", function()
		with_owner(function(world)
			local engine = world.load_engine("api")
			local initial = engine.streaming_revision()
			helpers.assert_true(type(initial) == "number")
			helpers.assert_eq(engine.streaming_revision(), initial)
			engine.disable()
			helpers.assert_true(engine.streaming_revision() > initial)
			local disabled = engine.streaming_revision()
			engine.set_backend("ollama")
			helpers.assert_true(engine.streaming_revision() > disabled)
		end)
	end)

	test("does not publish before a complete successful version receipt", function()
		with_owner(function(world)
			helpers.assert_true(world.owner.enable())
			helpers.assert_eq(#world.commits, 0)
			helpers.assert_eq(world.calls[1].url, "http://127.0.0.1:11434/api/version")
			helpers.assert_eq(world.calls[1].request.owner, "llm_enable_admission")
			helpers.assert_eq(world.calls[1].request.follow_redirects, false)
			world.answer()
			helpers.assert_eq(world.commits, { world.live.source })
			helpers.assert_eq(world.changes, 1)
			helpers.assert_eq(world.owner.pending(), false)
		end)
	end)

	for _, receipt in ipairs({
		{ ok = false, status = 0, body = "" }, { ok = false, status = 401, body = "unauthorized" },
		{ ok = true, status = 200, body = '{"models":[]}' },
	}) do
		test("keeps AI off and names its origin on a refused terminal " .. receipt.status .. ":" .. receipt.body, function()
			with_owner(function(world)
				helpers.assert_true(world.owner.enable())
				world.answer(receipt)
				helpers.assert_eq(#world.commits, 0)
				helpers.assert_eq(#world.rejects, 1)
				helpers.assert_eq(world.rejects[1][1], world.live.origin)
				helpers.assert_eq(world.changes, 0)
			end)
		end)
	end


	test("requests a fresh receipt only after explicit current retry", function()
		with_owner(function(world)
			helpers.assert_true(world.owner.enable())
			world.choice = "retry"
			world.answer({ ok = false, status = 503, body = "" }, 1)
			helpers.assert_eq(#world.calls, 2)
			helpers.assert_eq(#world.commits, 0)
			helpers.assert_true(world.owner.pending())
			helpers.assert_eq(world.calls[2].url, world.calls[1].url)
			world.answer(world.good, 1)
			helpers.assert_eq(#world.commits, 0, "an old failed request cannot publish the retry")
			world.answer(world.good, 2)
			helpers.assert_eq(#world.commits, 1)
			helpers.assert_eq(world.changes, 1)
		end)
	end)

	for _, change in ipairs({ { "origin", "http://127.0.0.1:21434" },
		{ "generation", 2 }, { "paused", true }, { "blocked", true } }) do
		test("does not retry after " .. change[1] .. " changes during the offer", function()
			with_owner(function(world)
				world.choice = "retry"
				world.on_reject = function() world.live[change[1]] = change[2] end
				helpers.assert_true(world.owner.enable())
				world.answer({ ok = false, status = 503, body = "" })
				helpers.assert_eq(#world.calls, 1)
				helpers.assert_eq(#world.commits, 0)
				helpers.assert_eq(world.owner.pending(), false)
			end)
		end)
	end

	for _, mutation in ipairs({
		{ "backend", "api" }, { "model", "model:3b" }, { "origin", "http://127.0.0.1:21434" },
		{ "generation", 3 }, { "paused", true }, { "blocked", true }, { "enabled", true },
	}) do
		test("drops a late answer after " .. mutation[1] .. " changes", function()
			with_owner(function(world)
				helpers.assert_true(world.owner.enable())
				world.live[mutation[1]] = mutation[2]
				world.answer()
				helpers.assert_eq(#world.commits + #world.rejects, 0)
				helpers.assert_eq(world.owner.pending(), false)
			end)
		end)
	end

	test("retains cancellation refusal debt and never accepts the old answer", function()
		with_owner(function(world)
			helpers.assert_true(world.owner.enable())
			world.cancel_ok = false
			helpers.assert_eq(world.owner.cancel(), false)
			helpers.assert_eq(world.owner.enable(), false)
			helpers.assert_true(world.owner.pending())
			world.answer()
			helpers.assert_eq(#world.commits + #world.rejects, 0)
			helpers.assert_eq(world.owner.pending(), false)
			helpers.assert_true(world.owner.enable())
			world.cancel_ok = true
			helpers.assert_true(world.owner.cancel())
			world.answer()
			helpers.assert_eq(#world.commits, 0)
		end)
	end)

	test("does not publish an answer delivered before dispatch refusal", function()
		with_owner(function(world)
			helpers.assert_eq(world.owner.enable(), false)
			helpers.assert_eq(#world.commits, 0)
			helpers.assert_eq(#world.rejects, 1)
			helpers.assert_eq(world.owner.pending(), false)
		end, { dispatched = false, synchronous = { ok = true, status = 200, body = '{"version":"1"}' } })
	end)

	test("preserves persistence refusal and does not refresh an uncommitted state", function()
		with_owner(function(world)
			world.write_ok = false
			helpers.assert_true(world.owner.enable())
			world.answer()
			helpers.assert_eq(#world.commits, 1)
			helpers.assert_eq(world.changes, 0)
		end)
	end)

	test("keeps API enabling independent of an unreachable local server", function()
		with_owner(function(world)
			world.live.backend, world.live.origin, world.live.model = "api", nil, nil
			helpers.assert_true(world.owner.enable())
			helpers.assert_eq(#world.calls, 0)
			helpers.assert_eq(#world.commits, 1)
			helpers.assert_eq(world.changes, 1)
		end)
	end)
end)

helpers.describe("Linux prediction enable publication", function()
	test("keeps actual grabbed retry pending after its own reset until a fresh receipt arrives", function()
		local request_options = { dispatched = false }
		with_owner(function(world)
			local engine, preferences = world.load_engine()
			world.discovery_stale = false
			local Hook = world.use_native_notice()
			world.native_answer = "retry\n"
			world.during_dialog = function() request_options.dispatched = true end
			local resets = 0
			Hook._test_drive({ { type = 1, code = 30, value = 1 } }, {
				onChar = function() world.outer_result = engine.enable() end,
				onDesync = function() resets = resets + 1; engine.cancel() end,
				onEmitRaw = function() return true end,
			}, true)
			helpers.assert_eq(resets, 1)
			helpers.assert_true(world.outer_result)
			helpers.assert_eq(#world.calls, 2)
			helpers.assert_eq(world.applied, nil)
			helpers.assert_eq(preferences.get("llm.enabled"), false)
			world.answer(world.good, 2)
			helpers.assert_true(preferences.get("llm.enabled"))
			helpers.assert_true(engine.is_enabled())
		end, request_options)
	end)

	for _, mode in ipairs({ "unchanged", "extra_cancel", "source", "pause", "regrab", "cleanup_debt" }) do
		test("requires the actual grabbed modal restoration and only its owned reset: " .. mode, function()
			with_owner(function(world)
				local engine, preferences = world.load_engine()
				world.discovery_stale, world.choice_index = false, 1
				world.cancel_ok = mode ~= "cleanup_debt"
				-- This mode explicitly owns a partial native allocation despite refusal.
				world.owned_http.refused_dispatch_acquired = mode == "cleanup_debt"
				local Hook = world.use_native_notice()
				local Reader = require("adapters.evdev_reader")
				local grab = Reader.grab
				if mode == "regrab" then Reader.grab = function() return false end end
				world.during_dialog = function()
					if mode == "source" then preferences.set("llm.models.ollama", "foreign:model")
					elseif mode == "pause" then world.live.paused = true end
				end
				local resets = 0
				local ran, failure = pcall(Hook._test_drive, { { type = 1, code = 30, value = 1 } }, {
					onChar = function() world.outer_result = engine.enable() end,
					onDesync = function()
						resets = resets + 1
						engine.cancel()
						if mode == "extra_cancel" then engine.cancel() end
					end,
					onEmitRaw = function() return true end,
				}, true)
				Reader.grab = grab
				helpers.assert_true(ran, tostring(failure))
				helpers.assert_eq(resets, mode == "regrab" and 0 or 1)
				if mode == "unchanged" then
					helpers.assert_eq(world.applied, 1)
					helpers.assert_true(world.outer_result)
					helpers.assert_eq(preferences.get("llm.models.selected"), "api")
					helpers.assert_true(engine.is_enabled())
				else
					helpers.assert_eq(world.outer_result, false)
					helpers.assert_eq(preferences.get("llm.models.selected"), "ollama")
					helpers.assert_eq(engine.is_enabled(), false)
					helpers.assert_eq(#world.calls, 1, "a refusal cannot dispatch a successor")
				end
			end, { dispatched = false })
		end)
	end

	test("selects an explicitly confirmed current cached server through both acknowledged owners", function()
		with_owner(function(world)
			local engine, preferences = world.load_engine()
			world.discovery_stale, world.choice_index = false, 1
			helpers.assert_true(engine.enable())
			world.answer({ ok = false, status = 0, body = "" })
			helpers.assert_eq(type(world.replacements), "table", "the refused enable offers cached server choices")
			helpers.assert_eq(#world.replacements, 1)
			helpers.assert_true(world.replacements[1].label:find("typed:model", 1, true) ~= nil)
			helpers.assert_eq(world.applied, 1)
			helpers.assert_eq(preferences.get("llm.models.selected"), "api")
			helpers.assert_true(preferences.get("llm.enabled"))
			helpers.assert_true(engine.is_enabled())
			helpers.assert_eq(#world.calls, 1, "API activation does not retry the unreachable Ollama")
		end)
	end)

	for _, enable_refused in ipairs({ false, true }) do
		test("reports a synchronous replacement enable's actual acknowledged state: refused=" .. tostring(enable_refused), function()
			with_owner(function(world)
				local engine, preferences = world.load_engine()
				world.discovery_stale, world.choice_index = false, 1
				if enable_refused then
					-- Refuse only master enable; the backend's independent guarded
					-- batch must still publish before this intended partial refusal.
					local write = preferences.set_many
					preferences.set_many = function(values, source, admission)
						if values["llm.enabled"] ~= nil then return false end
						return write(values, source, admission)
					end
				end
				helpers.assert_eq(engine.enable(), not enable_refused)
				helpers.assert_eq(world.applied, 1)
				helpers.assert_eq(preferences.get("llm.models.selected"), "api")
				helpers.assert_eq(preferences.get("llm.enabled"), not enable_refused)
				helpers.assert_eq(engine.is_enabled(), not enable_refused)
			end, { dispatched = false })
		end)
	end

	for _, drift in ipairs({ "pause", "source", "verdict", "freshness", "sweep" }) do
		test("refuses cached replacement after modal " .. drift .. " drift", function()
			with_owner(function(world)
				local engine, preferences = world.load_engine()
				world.discovery_stale, world.choice_index = false, 1
				world.on_notice = function(port)
					if drift == "pause" then world.live.paused = true
					elseif drift == "source" then port.set("llm.models.ollama", "different:model")
					elseif drift == "freshness" then world.discovery_stale = true
					elseif drift == "sweep" then world.sweeping = true
					else world.view_current = false end
				end
				engine.enable(); world.answer({ ok = false, status = 0, body = "" })
				helpers.assert_eq(world.applied, nil)
				helpers.assert_eq(preferences.get("llm.models.selected"), "ollama")
				helpers.assert_eq(engine.is_enabled(), false)
			end)
		end)
	end

	for _, failure in ipairs({ "source", "private_source", "dismissal", "dismissal_cancel", "dismissal_same_source", "publisher" }) do
		test("preserves an acknowledged saved-but-not-selected server after " .. failure .. " refusal", function()
			with_owner(function(world)
				local engine, preferences = world.load_engine()
				world.discovery_stale, world.choice_index = false, 1
				if failure == "publisher" then world.apply_refused = true
				elseif failure == "dismissal" or failure == "dismissal_cancel" or failure == "dismissal_same_source" then
					local dismiss = engine.dismiss
					engine.dismiss = function()
						engine.dismiss = dismiss
						dismiss()
						if failure == "dismissal_cancel" then engine.cancel()
						elseif failure == "dismissal_same_source" then
							local get_many = preferences.get_many
							local _, same_source = get_many({ "llm.models.ollama" })
							preferences.set("llm.models.ollama", preferences.get("llm.models.ollama"))
							preferences.get_many = function(paths)
								local values = get_many(paths)
								return values, same_source
							end
						else preferences.set("llm.models.ollama", "foreign:model") end
					end
				else
					world.after_apply = function(port)
						if failure == "source" then port.set("llm.models.ollama", "foreign:model")
						else world.private_current = false end
					end
				end
				engine.enable(); world.answer({ ok = false, status = 0, body = "" })
				if failure == "publisher" then helpers.assert_nil(world.applied)
				else helpers.assert_eq(world.applied, 1) end
				helpers.assert_eq(preferences.get("llm.models.selected"), "ollama")
				helpers.assert_eq(preferences.get("llm.enabled"), false)
				helpers.assert_eq(engine.is_enabled(), false)
			end)
		end)
	end

	for _, mode in ipairs({ "stale", "sweeping", "unselected" }) do
		test("keeps the AI off without an explicitly selected usable cached choice: " .. mode, function()
			with_owner(function(world)
				local engine = world.load_engine()
				world.discovery_stale = mode == "stale"
				world.sweeping = mode == "sweeping"
				world.choice_index = mode ~= "unselected" and 1 or nil
				engine.enable(); world.answer({ ok = false, status = 0, body = "" })
				helpers.assert_eq(world.applied, nil)
				helpers.assert_eq(engine.is_enabled(), false)
			end)
		end)
	end
	test("API activation publishes without a local model or version request", function()
		with_owner(function(world)
			local engine, preferences = world.load_engine("api")
			package.loaded["modules.llm.profiles"].get_current_model = function() return nil end
			helpers.assert_true(engine.enable())
			helpers.assert_true(engine.is_enabled())
			helpers.assert_true(preferences.get("llm.enabled"))
			helpers.assert_eq(#world.calls, 0, "the API owner does not contact a local Ollama server")
			helpers.assert_eq(#world.rejects, 0)
		end)
	end)

	test("persists disabled until the actual controller acknowledges current Ollama", function()
		with_owner(function(world)
			local engine, preferences = world.load_engine()
			helpers.assert_true(engine.enable(function() world.changes = world.changes + 1 end))
			helpers.assert_eq(engine.is_enabled(), false)
			helpers.assert_eq(preferences.get("llm.enabled"), false)
			world.answer()
			helpers.assert_true(engine.is_enabled())
			helpers.assert_true(preferences.get("llm.enabled"))
			helpers.assert_eq(world.changes, 1)
		end)
	end)

	test("a preference A-B-A edit invalidates the pending enable", function()
		with_owner(function(world)
			local engine, preferences = world.load_engine()
			helpers.assert_true(engine.enable())
			helpers.assert_true(preferences.set("llm.models.ollama", "model:3b"))
			helpers.assert_true(preferences.set("llm.models.ollama", "model:2b"))
			world.answer()
			helpers.assert_eq(engine.is_enabled(), false)
			helpers.assert_eq(preferences.get("llm.enabled"), false)
		end)
	end)

	test("a pause and resume cannot revive a pre-pause answer", function()
		with_owner(function(world)
			local engine, preferences = world.load_engine()
			helpers.assert_true(engine.enable())
			world.live.paused = true
			engine.on_pause_change(true)
			world.live.paused = false
			engine.on_pause_change(false)
			world.answer()
			helpers.assert_eq(engine.is_enabled(), false)
			helpers.assert_eq(preferences.get("llm.enabled"), false)
		end)
	end)

	test("a scope owner must settle the probe before taking its reversible snapshot", function()
		with_owner(function(world)
			local engine = world.load_engine()
			helpers.assert_true(engine.enable())
			local scope = { pending = function() return false end }
			helpers.assert_true(engine.acquire_configuration(scope))
			helpers.assert_nil(engine.configuration_snapshot(scope))
			world.cancel_ok = false
			helpers.assert_eq(engine.quiesce_configuration(scope), false)
			world.cancel_ok = true
			world.answer()
			helpers.assert_eq(engine.is_enabled(), false)
			helpers.assert_true(engine.release_configuration(scope))
		end)
	end)
end)

helpers.describe("enable admission owns actual HTTP creator and physical debt", function()
	test("cancel signal acceptance does not acknowledge physical version probe retirement", function()
		with_owner(function(world)
			world.owned_http.settled = false
			helpers.assert_true(world.owner.enable())
			helpers.assert_eq(world.owner.cancel(), false)
			helpers.assert_eq(#world.cancels, 1, "controlled native termination was accepted")
			helpers.assert_true(world.owner.pending())
			world.owned_http.operations[1]:acknowledge()
			helpers.assert_eq(world.owner.pending(), false)
			world.answer(world.good)
			helpers.assert_eq(#world.commits, 0)
		end)
	end)

	test("version constructor reserves cleanup before native capability returns", function()
		with_owner(function(world)
			world.owned_http.during_create = function()
				world.cancel_during_create = world.owner.cancel()
				world.pending_during_create = world.owner.pending()
			end
			helpers.assert_eq(world.owner.enable(), false)
			helpers.assert_eq(world.cancel_during_create, false)
			helpers.assert_true(world.pending_during_create)
			helpers.assert_eq(#world.calls, 0, "revoked constructor never dispatches the legacy scripted network effect")
			helpers.assert_eq(world.owner.pending(), false, "known unwound no-resource constructor may acknowledge")
		end)
	end)

	test("version source snapshot cannot acknowledge cancellation before its creator unwinds", function()
		with_owner(function(world)
			local owner, cancelled, pending
			owner = require("modules.llm.enable_admission").new({
				snapshot = function()
					cancelled, pending = owner.cancel(), owner.pending()
					return world.live
				end,
				commit = function() return true end,
				reject = function() return nil end,
			})
			helpers.assert_eq(owner.enable(), false)
			helpers.assert_eq(cancelled, false)
			helpers.assert_true(pending)
			helpers.assert_eq(#world.calls, 0)
			helpers.assert_eq(owner.pending(), false)
		end)
	end)

	test("a logical version response waits for the independent physical settlement proof", function()
		with_owner(function(world)
			world.owned_http.settled = false
			helpers.assert_true(world.owner.enable())
			world.answer(world.good)
			helpers.assert_eq(#world.commits, 0)
			helpers.assert_true(world.owner.pending())
			world.owned_http.operations[1]:acknowledge()
			helpers.assert_eq(#world.commits, 1)
			helpers.assert_eq(world.owner.pending(), false)
		end)
	end)
end)

helpers.describe("enable settlement after source withdrawal", function()
	test("suppressed stale version delivery releases only its exact physically settled owner", function()
		with_owner(function(world)
			helpers.assert_true(world.owner.enable())
			world.live.generation = world.live.generation + 1
			world.answer(world.good)
			helpers.assert_eq(world.owner.pending(), false)
			helpers.assert_eq(#world.commits, 0)
			helpers.assert_eq(#world.rejects, 0)
			helpers.assert_true(world.owner.enable(), "settled stale ownership permits a fresh independent source capture")
			helpers.assert_eq(#world.calls, 2)
		end)
	end)
end)

helpers.describe("enable refusal notice retains physical admission", function()
	test("known empty false-start does not turn cancel refusal into native debt", function()
		with_owner(function(world)
			world.cancel_ok = false
			helpers.assert_eq(world.owner.enable(), false)
			helpers.assert_eq(world.owner.pending(), false)
			helpers.assert_eq(world.cleanup_only, false)
			helpers.assert_eq(#world.rejects, 1)
			helpers.assert_eq(#world.commits, 0)
		end, { dispatched = false })
	end)

	test("partial false-start shows read-only refusal without retry before physical ACK", function()
		local options = { dispatched = false }
		with_owner(function(world)
			world.owned_http.refused_dispatch_acquired, world.owned_http.settled = true, false
			world.choice = "retry"
			helpers.assert_eq(world.owner.enable(), false)
			helpers.assert_true(world.owner.pending())
			helpers.assert_eq(world.cleanup_only, true)
			helpers.assert_eq(#world.calls, 1)
			helpers.assert_eq(#world.commits, 0)
			world.owned_http.operations[1]:acknowledge()
			helpers.assert_eq(world.owner.pending(), false)
			options.dispatched, world.choice = true, nil
			helpers.assert_true(world.owner.enable())
			helpers.assert_eq(#world.calls, 2)
		end, options)
	end)

	test("actual native refusal with partial cleanup offers no cached acquisition", function()
		with_owner(function(world)
			local engine, preferences = world.load_engine()
			world.discovery_stale, world.choice_index = false, 1
			world.owned_http.refused_dispatch_acquired, world.owned_http.settled = true, false
			helpers.assert_eq(engine.enable(), false)
			helpers.assert_eq(#world.replacements, 0)
			helpers.assert_eq(world.applied, nil)
			helpers.assert_eq(preferences.get("llm.enabled"), false)
			helpers.assert_eq(engine.disable(), false)
			world.owned_http.operations[1]:acknowledge()
		end, { dispatched = false })
	end)
end)
