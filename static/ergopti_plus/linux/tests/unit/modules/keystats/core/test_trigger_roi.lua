--- tests/unit/modules/keystats/core/test_trigger_roi.lua

--- The portable trigger metrics corpus runs under the Linux LuaJIT ABI.
local helpers = require("tests.helpers")
local corpus = assert(loadfile(helpers.driver_root() .. "/../_shared/tests/corpus/keystats/trigger_roi.lua"))()
corpus(helpers)

local Home = require("tests.support.keystats_home_fixture")
local Native = require("tests.support.keystats_native_fixture")
local Json = require("core.text.engine.json")

local function context(window)
	return { app_id = "Editor", title = "Document", native_identity = window or "x11:owner:1" }
end

local function unknown() return false end

local function start(collector)
	helpers.assert_true(collector.init(Home.options({ sqlite_path = Home.fresh_db() })))
	require("tests.support.metrics_consent_fixture").enable(collector)
	return require("modules.keystats.sqlite_writer")
end

local function rows(writer)
	local result = {}
	for _, encoded in ipairs(assert(writer.query_rows("SELECT json_object('kind',kind,'app',app,'ts',ts,'meta',json(meta_json)) FROM events_roi ORDER BY id;"))) do
		result[#result + 1] = assert(Json.decode(encoded))
	end
	return result
end

Home.it("Linux trigger ROI: native snapshots survive refusal and finish once with private gains", function()
	Native.with(function(collector)
		local writer = start(collector)
		local now = require("infra.monotonic").now_ms()
		for index = 1, 10 do collector.record_hotstring("Editor", "😀", "😀😀", now + index, "static", 1, index == 10) end
		collector.record_hotstring("Editor", "SECRET", "x", now + 11, "static", 6, true)
		collector.record_hotstring("Editor", "empty", "", now + 12, "static", 5, false)
		local start_flush, captured = writer.start_flush
		writer.start_flush = function(_, payload) captured = payload; return nil end
		local called, failure = pcall(function()
			helpers.assert_eq(collector.flush(), false, "a refused acquisition cannot acknowledge the ROI source")
			helpers.assert_eq(#captured.raw.roi, 1)
			helpers.assert_eq(captured.raw.roi[1].meta, { session_saved = 20, session_fired = 10 })
		end)
		writer.start_flush = start_flush
		if not called then error(failure, 0) end
		Native.flush(collector)
		local actual = rows(writer)
		helpers.assert_eq(#actual, 1)
		helpers.assert_eq(actual[1].ts, captured.raw.roi[1].ts, "retry preserves the event's original capture stamp")
		helpers.assert_eq(actual[1].meta, { session_saved = 20, session_fired = 10 })
		Native.flush(collector)
		helpers.assert_eq(#rows(writer), 1, "a second flush never replays a committed snapshot")
		collector.stop()
		for _ = 1, 1000 do
			if collector.stop() then break end
			require("luv").run("nowait")
			require("luv").sleep(1)
		end
		helpers.assert_true(collector.stop())
		actual = rows(writer)
		helpers.assert_eq(#actual, 2)
		helpers.assert_eq(actual[2].meta, { session_saved = 20, session_fired = 12 }, "zero-gain private and empty expansions count without content")
		helpers.assert_nil(Json.encode(actual):find("SECRET", 1, true))
	end)
end)

Home.it("Linux trigger ROI: native candidates respect context, edits, privacy and pause boundaries", function()
	Native.with(function(collector)
		local writer = start(collector)
		local function text(value, owner) return collector.record_roi_text(value, owner or context(), unknown) end
		for _ = 1, 4 do text("ÉCOLE ") end
		text("Écolex")
		collector.record_roi_key("backspace", {}, context(), unknown)
		collector.record_roi_key("enter", {}, context(), unknown)
		for _ = 1, 5 do
			text("frag")
			collector.observe_roi_context(context("x11:owner:2"))
			collector.observe_roi_context(context())
			text("ment ")
			text("cross")
			collector.discard_roi()
			text("ing ")
			text("secure")
			collector.set_secure_field(true)
			text("withheld ")
			collector.set_secure_field(false)
			text("slice ", { app_id = "Editor", title = "Document" })
			text("nav")
			collector.record_roi_key("left", {}, context(), unknown)
			text("tail ")
			collector.record_roi_text("KNOWN ", context(), function() return true end)
		end
		text("parity ")
		collector.suspend_collection()
		helpers.assert_eq(text("paused "), false)
		collector.resume_collection()
		for _ = 1, 4 do text("parity ") end
		Native.flush(collector)
		local words = {}
		for _, event in ipairs(rows(writer)) do words[event.meta.word] = event.meta.occurrences end
		helpers.assert_eq(words, { ["École"] = 5, ment = 5, tail = 5, parity = 5 })
	end)
end)

helpers.it("Linux trigger ROI: the real engine excludes strict Unicode triggers only after catalogue admission", function()
	local engine = require("modules.hotstrings.engine").new()
	helpers.assert_nil(engine:is_known_trigger("école"))
	helpers.assert_true(engine:load_mappings({ { trigger = "ÉCOLE", replacement = "class", is_case_sensitive_strict = true } }))
	helpers.assert_true(engine:is_known_trigger("école"))
	helpers.assert_eq(engine:is_known_trigger("other"), false)
	helpers.assert_eq(engine:load_mappings({ { trigger = "other", replacement = "x", personal_source = {} } }), false)
	helpers.assert_true(engine:is_known_trigger("école"), "a refused reload retains the admitted exclusion set")
	helpers.assert_eq(engine:is_known_trigger("other"), false)
	helpers.assert_true(engine:load_mappings({}))
	helpers.assert_eq(engine:is_known_trigger("école"), false, "an admitted empty catalogue removes old exclusions")
end)

Home.it("Linux trigger ROI: refused collection never captures physical metadata or the calendar", function()
	Native.with(function(collector)
		local writer = start(collector)
		local hook, calendar = require("adapters.keyboard_hook"), require("modules.keystats.calendar")
		local original_layout, original_capture = hook.get_layout, calendar.capture
		local function refused(owner)
			local physical, clocks = 0, 0
			hook.get_layout = function() physical = physical + 1; error("refused input consulted its physical provider") end
			calendar.capture = function() clocks = clocks + 1; error("refused input consulted its calendar") end
			local ok, failure = xpcall(function()
				helpers.assert_eq(collector.observe_roi_context(owner), false)
				helpers.assert_eq(collector.record_roi_text("withheld ", owner, unknown), false)
				helpers.assert_eq(collector.record_roi_key("backspace", {}, owner, unknown), false)
			end, debug.traceback)
			hook.get_layout, calendar.capture = original_layout, original_capture
			if not ok then error(failure, 0) end
			helpers.assert_eq({ physical, clocks }, { 0, 0 }, "refusal precedes both metadata owners")
		end
		local configuration = assert(collector.configuration_snapshot())
		configuration.enabled = false; helpers.assert_true(collector.apply_configuration(configuration))
		refused(context())
		configuration.enabled = true; helpers.assert_true(collector.apply_configuration(configuration))
		collector.suspend_collection(); refused(context()); collector.resume_collection()
		collector.set_secure_field(true); refused(context()); collector.set_secure_field(false)
		configuration.disabled_apps = { "Editor" }; helpers.assert_true(collector.apply_configuration(configuration))
		refused(context())
		configuration.disabled_apps = {}; helpers.assert_true(collector.apply_configuration(configuration))
		refused(nil)
		refused("unknown")
		for _, owner in ipairs({ {}, { app_id = "Editor", title = "Document" },
			{ app_id = "Unknown", title = "Document", native_identity = "owned" },
			{ app_id = "Editor", native_identity = "owned" },
			{ app_id = "Editor", title = "Document", native_identity = 0 },
			{ app_id = "Editor", title = "Document", native_identity = math.huge } }) do refused(owner) end
		local physical, clocks = 0, 0
		hook.get_layout = function() physical = physical + 1; return original_layout() end
		calendar.capture = function() clocks = clocks + 1; return original_capture() end
		local ok, failure = xpcall(function()
			helpers.assert_true(collector.observe_roi_context(context()))
			helpers.assert_true(collector.record_roi_text("x", context(), unknown))
			helpers.assert_true(collector.record_roi_key("backspace", {}, context(), unknown))
		end, debug.traceback)
		hook.get_layout, calendar.capture = original_layout, original_capture
		if not ok then error(failure, 0) end
		helpers.assert_eq({ physical, clocks }, { 3, 3 }, "admitted observations retain both real capture owners")
		for _ = 1, 5 do collector.record_roi_text("admitted ", context(), unknown) end
		Native.flush(collector)
		local actual = rows(writer)
		helpers.assert_eq(#actual, 1)
		helpers.assert_eq(actual[1].meta.word, "admitted")
	end)
end)

Home.it("Linux trigger ROI: early cipher refusal still retires queued text and keeps numerical totals", function()
	Native.with(function(collector)
		local writer = start(collector)
		local hook, cipher = require("adapters.keyboard_hook"), require("modules.keystats.text_cipher")
		local original_layout, original_enabled = hook.get_layout, cipher.is_enabled
		local probes = { { "on", "observe" }, { "unknown", "text" }, { "on", "key" }, { "unknown", "shortcut" } }
		for _, probe in ipairs(probes) do
			local configuration = assert(collector.configuration_snapshot())
			configuration.enabled = true; helpers.assert_true(collector.apply_configuration(configuration))
			for _ = 1, 5 do collector.record_roi_text("retiredcandidate ", context(), unknown) end
			local now = require("infra.monotonic").now_ms()
			for index = 1, 10 do collector.record_hotstring("Editor", "x", "xx", now + index, "static", 1, true) end
			if probe[1] == "unknown" then
				configuration.enabled = false; helpers.assert_true(collector.apply_configuration(configuration))
			end
			local physical = 0
			hook.get_layout = function() physical = physical + 1; error("closed cipher policy consulted physical metadata") end
			cipher.is_enabled = function() if probe[1] == "on" then return true end end
			local ok, failure = xpcall(function()
				if probe[2] == "observe" then helpers.assert_eq(collector.observe_roi_context(context()), false)
				elseif probe[2] == "text" then helpers.assert_eq(collector.record_roi_text("withheld ", context(), unknown), false)
				else helpers.assert_eq(collector.record_roi_key(probe[2] == "key" and "backspace" or "shortcut", {}, context(), unknown), false) end
			end, debug.traceback)
			hook.get_layout, cipher.is_enabled = original_layout, original_enabled
			if not ok then error(failure, 0) end
			helpers.assert_eq(physical, 0)
			Native.flush(collector)
		end
		local actual = rows(writer)
		helpers.assert_eq(#actual, #probes, "every entry point retires queued text while numerical snapshots survive")
		for index, event in ipairs(actual) do
			helpers.assert_eq(event.kind, "roi_snapshot")
			helpers.assert_eq(event.meta, { session_saved = index * 10, session_fired = index * 10 })
		end
	end)
end)

Home.it("Linux trigger ROI: actual daemon callbacks exclude synthetic output and interrupted physical fragments", function()
	Native.with(function(collector)
		local writer = start(collector)
		local engine = require("modules.hotstrings.engine").new()
		assert(engine:load_mappings({ { trigger = "KNOWN", replacement = "expansion", is_case_sensitive_strict = true } }))
		local stop, matched = {}, 0
		engine.on_char = function() matched = matched + 1; error(stop) end
		local admitted, paused = true, false
		local environment = setmetatable({
			keystats = collector, engine = engine, _cached_app_id = "Editor",
			injector = { _is_injecting = function() return false end },
			script_actions = { is_paused = function() return paused end },
			secure_focus_guard = { blocks_text = function() return not admitted end,
				capture_text_owner = function() return {} end, current_context = context,
				invalidate = collector.discard_roi },
			TapHold = { observe_copy_activity = function() end },
			wrap_on_type = { on_pointer_down = function() end }, Logger = { debug = function() end },
			keyboard_hook = { held_modifiers = function() return {} end },
			Monotonic = require("infra.monotonic"),
			WordReset = { observe_key = function() return false end, cascade_max_arrows = function() return 0 end,
				click_resets_word = function() return false end },
			terminators_mod = { is_terminator = function() return false end },
		}, { __index = _G })
		local handle = assert(io.open(helpers.driver_root() .. "/ergopti_hotstrings.lua", "rb"))
		local source = assert(handle:read("*a")); assert(handle:close())
		local function compile(body)
			local chunk
			if loadstring then chunk = assert(loadstring(body)); setfenv(chunk, environment)
			else chunk = assert(load(body, "actual ROI daemon owner", "t", environment)) end
			return chunk()
		end
		local first = assert(source:find("\tlocal function handle_char(", 1, true))
		local last = assert(source:find("\n\ton_char = input_capture_gate.guard(handle_char)", first, true))
		local character = compile(source:sub(first, last - 1) .. "\nreturn handle_char")
		first = assert(source:find("if not injector.set_output_observer(", 1, true)) + #"if not injector.set_output_observer("
		last = assert(source:find("\n\tend, keystats.discard_roi) then", first, true)) + #"\n\tend"
		local synthetic = compile("return " .. source:sub(first, last - 1))
		first = assert(source:find("\tlocal function on_pointer_event(", 1, true))
		last = assert(source:find("\n\t-- Text the daemon types itself", first, true))
		local pointer = compile(source:sub(first, last - 1) .. "\nreturn on_pointer_event")
		first = assert(source:find("\tlocal function on_click(code)", 1, true))
		last = assert(source:find("\n\t-- A pointer event", first, true))
		local click = compile(source:sub(first, last - 1) .. "\nreturn on_click")
		local function type_text(text)
			for _, cp in require("core.lifecycle.engine.compat.utf8").codes(text) do
				local ok, failure = pcall(character, require("core.lifecycle.engine.compat.utf8").char(cp), 30)
				if admitted and not paused then helpers.assert_eq(ok, false); helpers.assert_eq(failure, stop)
				else helpers.assert_true(ok) end
			end
		end
		for _ = 1, 5 do
			type_text("physical ")
			for char in ("remapped "):gmatch(".") do synthetic(char, true); type_text(char) end
			type_text("known ")
			type_text("frag")
			synthetic("GENERATED ")
			type_text("ment ")
			type_text("prefix")
			pointer("motion", 0, 1, "fixture")
			type_text("tail ")
			type_text("cut")
			click()
			type_text("tail ")
			type_text("sta")
			environment.physical_privacy_admission = { code = 30, allowed = false }
			local before = matched
			character("x", 30)
			helpers.assert_eq(matched, before, "the physical press's refusal keeps its text out of the matcher")
			type_text("le ")
		end
		admitted = false
		type_text("hidden hidden hidden hidden hidden ")
		admitted, paused = true, true
		type_text("paused paused paused paused paused ")
		paused = false
		Native.flush(collector)
		local words = {}
		for _, event in ipairs(rows(writer)) do words[event.meta.word] = event.meta.occurrences end
		helpers.assert_eq(words, { physical = 5, remapped = 5, ment = 5, prefixtail = 5, tail = 5 })
	end)
end)


Home.it("Linux trigger ROI: requested encryption purges new text without deleting history or numerical totals", function()
	Native.with(function(collector)
		local writer = start(collector)
		local preferences = require("infra.metrics_preferences")
		local function text(value) return collector.record_roi_text(value, context(), unknown) end
		for _ = 1, 5 do text("historical ") end
		Native.flush(collector)
		helpers.assert_eq(#rows(writer), 1)
		for _ = 1, 5 do text("discarded ") end
		for _ = 1, 4 do text("fresh ") end
		text("fragment")
		local now = require("infra.monotonic").now_ms()
		for index = 1, 10 do collector.record_hotstring("Editor", "x", "xx", now + index, "static", 1, true) end
		local configuration = assert(collector.configuration_snapshot())
		configuration.encrypt = true
		helpers.assert_true(preferences.set("metrics.encrypt", true))
		-- Requested ON with an effective OFF provider must still close text. This
		-- posture is also used by configuration compensation when a key is absent.
		helpers.assert_eq(configuration.cipher_enabled, false)
		helpers.assert_true(collector.apply_configuration(configuration))
		Native.flush(collector)
		local actual = rows(writer)
		helpers.assert_eq(#actual, 2, "the queued candidate is purged while the numeric snapshot survives")
		helpers.assert_eq(actual[1].meta.word, "historical", "capture-time history is not deleted")
		helpers.assert_eq(actual[2].meta, { session_saved = 10, session_fired = 10 })
		for _ = 1, 5 do helpers.assert_eq(text("withheld "), false) end
		configuration.encrypt = false
		helpers.assert_true(preferences.set("metrics.encrypt", false))
		helpers.assert_true(collector.apply_configuration(configuration))
		text("tail ")
		text("fresh ")
		Native.flush(collector)
		helpers.assert_eq(#rows(writer), 2, "OFF cannot resurrect the old fragment or four-occurrence counter")
		for _ = 1, 4 do text("fresh ") end
		Native.flush(collector)
		actual = rows(writer)
		helpers.assert_eq(#actual, 3)
		helpers.assert_eq(actual[3].meta.word, "fresh")
		helpers.assert_nil(Json.encode(actual):find("discarded", 1, true))
		helpers.assert_nil(Json.encode(actual):find("withheld", 1, true))
	end)
end)

Home.it("Linux trigger ROI: canonical policy closes a queued acquisition and unknown cipher states fail closed", function()
	Native.with(function(collector)
		local writer = start(collector)
		local preferences = require("infra.metrics_preferences")
		local cipher = require("modules.keystats.text_cipher")
		local policy = require("modules.keystats.roi_policy")
		local original_enabled, original_get = cipher.is_enabled, preferences.get
		local called, failure = xpcall(function()
			helpers.assert_true(policy.current())
			for _, value in ipairs({ true, "false", 0 }) do
				cipher.is_enabled = function() return value end
				helpers.assert_eq(policy.text_enabled(false), false)
			end
			cipher.is_enabled = function() end
			helpers.assert_eq(policy.text_enabled(false), false)
			cipher.is_enabled = function() error("provider unavailable") end
			helpers.assert_eq(policy.text_enabled(false), false)
			cipher.is_enabled = function() return false end
			helpers.assert_eq(policy.text_enabled(nil), false)
			helpers.assert_eq(policy.text_enabled(true), false)
			preferences.get = function() error("preference unavailable") end
			helpers.assert_eq(policy.current(), false)
			preferences.get = original_get
			cipher.is_enabled = original_enabled
			for _ = 1, 5 do collector.record_roi_text("queued ", context(), unknown) end
			-- No input or collector configuration callback follows this persisted
			-- transition: acquisition itself must recheck the canonical owner.
			helpers.assert_true(preferences.set("metrics.encrypt", true))
			Native.flush(collector)
			helpers.assert_eq(#rows(writer), 0)
			helpers.assert_true(preferences.set("metrics.encrypt", false))
			collector.record_roi_text("queued ", context(), unknown)
			Native.flush(collector)
			helpers.assert_eq(#rows(writer), 0, "canonical transition also purged the old occurrence map")
		end, debug.traceback)
		cipher.is_enabled, preferences.get = original_enabled, original_get
		if not called then error(failure, 0) end
	end)
end)

Home.it("Linux trigger ROI: the native writer admits only numerical new events under encryption", function()
	Native.with(function(collector)
		local writer = start(collector)
		helpers.assert_true(require("infra.metrics_preferences").set("metrics.encrypt", true))
		local function event(kind, meta)
			return { ts = "2026-11-07T12:00:00Z", date = "2026-11-07", app = "Editor", kind = kind, meta = meta }
		end
		local function commit(events)
			local operation = assert(writer.start_flush("fixture", {
				raw = { typing = {}, hotstrings = {}, shortcuts = {}, switches = {}, roi = events }, upserts = {},
			}))
			local uv, now = require("luv"), require("infra.monotonic").now_ms
			local until_ms = now() + require("infra.timings").ms("keystats", "sqlite_operation_timeout_ms")
			while not operation:is_settled() and now() < until_ms do
				operation:pump()
				if operation:is_retryable() then operation:cancel() end
				uv.run("nowait"); uv.sleep(1)
			end
			helpers.assert_true(operation:is_settled(), "the native privacy transaction must retire")
			return operation.result.committed
		end
		helpers.assert_true(commit({ event("new_trigger_candidate", { word = "SECRET", occurrences = 5 }),
			event("trigger_halflife", { trigger = "SECRET", days_since = 30 }),
			event("roi_snapshot", { session_saved = 12, session_fired = 10 }) }))
		local actual = rows(writer)
		helpers.assert_eq(#actual, 1)
		helpers.assert_eq(actual[1].meta, { session_saved = 12, session_fired = 10 })
		helpers.assert_eq(commit({ event("roi_snapshot", { session_saved = 12, session_fired = 10, word = "SECRET" }) }), false,
			"the numerical exception cannot carry disguised textual metadata")
		helpers.assert_eq(#rows(writer), 1)
		helpers.assert_nil(Json.encode(rows(writer)):find("SECRET", 1, true))
	end)
end)


Home.it("Linux trigger ROI: a refused encryption attempt purges old candidates before known-OFF capture resumes", function()
	Native.with(function(collector)
		local writer = start(collector)
		local cipher = require("modules.keystats.text_cipher")
		local original_available = cipher.is_available
		local called, failure = xpcall(function()
			for _ = 1, 5 do collector.record_roi_text("discarded ", context(), unknown) end
			for _ = 1, 4 do collector.record_roi_text("renewed ", context(), unknown) end
			cipher.is_available = function() return false end
			helpers.assert_eq(collector.set_encrypt_enabled(true), false)
			helpers.assert_eq(collector.is_encrypt_enabled(), false, "a refused provider cannot publish ON")
			collector.record_roi_text("renewed ", context(), unknown)
			Native.flush(collector)
			helpers.assert_eq(#rows(writer), 0, "failed activation still purges queued text and old occurrence maps")
			for _ = 1, 4 do collector.record_roi_text("renewed ", context(), unknown) end
			Native.flush(collector)
			helpers.assert_eq(#rows(writer), 1)
			helpers.assert_eq(rows(writer)[1].meta.word, "renewed", "known OFF admits only fresh occurrences")
		end, debug.traceback)
		cipher.is_available = original_available
		if not called then error(failure, 0) end
	end)
end)

Home.it("Linux trigger ROI: an owned pre-activation append settles before fresh known-OFF capture", function()
	Native.with(function(collector)
		local writer = start(collector)
		for _ = 1, 5 do collector.record_roi_text("owned ", context(), unknown) end
		helpers.assert_eq(collector.flush(), false)
		helpers.assert_true(collector.has_flush_debt())
		for _ = 1, 4 do collector.record_roi_text("renewed ", context(), unknown) end
		helpers.assert_eq(collector.set_encrypt_enabled(true), false, "ON cannot overtake a native persistence owner")
		helpers.assert_eq(collector.is_encrypt_enabled(), false)
		for _ = 1, 5 do helpers.assert_eq(collector.record_roi_text("blocked ", context(), unknown), false) end
		Native.flush(collector)
		helpers.assert_eq(#rows(writer), 1, "the pre-activation append retains its capture-time policy")
		helpers.assert_eq(rows(writer)[1].meta.word, "owned")
		Native.flush(collector) -- off-input canonical observation after exact retirement
		collector.record_roi_text("renewed ", context(), unknown)
		Native.flush(collector)
		helpers.assert_eq(#rows(writer), 1, "the purged four-occurrence map cannot resume")
		for _ = 1, 4 do collector.record_roi_text("renewed ", context(), unknown) end
		Native.flush(collector)
		helpers.assert_eq(#rows(writer), 2)
		helpers.assert_eq(rows(writer)[2].meta.word, "renewed")
	end)
end)


Home.it("Linux trigger ROI: encryption refusal clears last-use text before later native idle checks", function()
	local clock, cipher = require("infra.monotonic"), require("modules.keystats.text_cipher")
	local original_now, original_available = clock.now_ms, cipher.is_available
	local offset = 0
	clock.now_ms = function() return original_now() + offset end
	local called, failure = xpcall(function()
		Native.with(function(collector)
			local writer = start(collector)
			collector.record_hotstring("Editor", "forgotten", "long replacement", clock.now_ms(), "static", 9, false)
			cipher.is_available = function() return false end
			helpers.assert_eq(collector.set_encrypt_enabled(true), false)
			offset = offset + 31 * 24 * 60 * 60 * 1000
			Native.flush(collector)
			helpers.assert_eq(#rows(writer), 0, "a pre-attempt last-use entry cannot emit after text is re-enabled")
			collector.record_hotstring("Editor", "current", "long replacement", clock.now_ms(), "static", 7, false)
			offset = offset + 31 * 24 * 60 * 60 * 1000
			Native.flush(collector)
			local actual = rows(writer)
			helpers.assert_eq(#actual, 1, "the real idle owner still emits for a freshly admitted known-OFF use")
			helpers.assert_eq(actual[1].kind, "trigger_halflife")
			helpers.assert_eq(actual[1].meta.trigger, "current")
		end)
	end, debug.traceback)
	clock.now_ms, cipher.is_available = original_now, original_available
	if not called then error(failure, 0) end
end)


Home.it("Linux trigger ROI: a reentrant refused acquisition cannot resurrect revoked text", function()
	Native.with(function(collector)
		local writer = start(collector)
		for _ = 1, 5 do collector.record_roi_text("revokedcandidate ", context(), unknown) end
		for index = 1, 10 do collector.record_hotstring("Editor", "x", "xx", nil, "static", 1, true) end
		local start_flush, captured = writer.start_flush
		writer.start_flush = function(_, payload)
			captured = payload
			helpers.assert_true(collector.has_flush_debt(), "the collector reserves before entering the external allocation")
			helpers.assert_eq(collector.set_encrypt_enabled(true), false)
			return nil
		end
		local called, failure = pcall(function() helpers.assert_eq(collector.flush(), false) end)
		writer.start_flush = start_flush
		if not called then error(failure, 0) end
		helpers.assert_eq(collector.has_flush_debt(), false, "nil acquisition owns no native append")
		helpers.assert_eq(#captured.raw.roi, 1, "the detached unstarted source is purged before it can be restored")
		helpers.assert_eq(captured.raw.roi[1].kind, "roi_snapshot")
		Native.flush(collector)
		local actual = rows(writer)
		helpers.assert_eq(#actual, 1)
		helpers.assert_eq(actual[1].meta, { session_saved = 10, session_fired = 10 })
		helpers.assert_nil(Json.encode(actual):find("revokedcandidate", 1, true))
	end)
end)


Home.it("Linux trigger ROI: an observed unknown canonical policy stays closed on the input path", function()
	Native.with(function(collector)
		local writer = start(collector)
		local preferences = require("infra.metrics_preferences")
		local original = preferences.get
		local called, failure = xpcall(function()
			preferences.get = function() error("canonical policy unavailable") end
			Native.flush(collector)
			for _ = 1, 5 do
				helpers.assert_eq(collector.record_roi_text("unknowncapture ", context(), unknown), false)
			end
		end, debug.traceback)
		preferences.get = original
		if not called then error(failure, 0) end
		Native.flush(collector)
		helpers.assert_eq(#rows(writer), 0, "OFF recovery cannot publish text captured under unknown posture")
		for _ = 1, 5 do collector.record_roi_text("freshcapture ", context(), unknown) end
		Native.flush(collector)
		helpers.assert_eq(rows(writer)[1].meta.word, "freshcapture")
	end)
end)

Home.it("Linux trigger ROI: reentrant canonical observation retires source before native acquisition", function()
	Native.with(function(collector)
		local writer = start(collector)
		for _ = 1, 5 do collector.record_roi_text("preacquisition ", context(), unknown) end
		local preferences = require("infra.metrics_preferences")
		local original, reentered = preferences.get, false
		preferences.get = function(...)
			if collector.has_flush_debt() and not reentered then
				reentered = true
				helpers.assert_eq(collector.set_encrypt_enabled(true), false)
			end
			return original(...)
		end
		local called, failure = xpcall(function() Native.flush(collector) end, debug.traceback)
		preferences.get = original
		if not called then error(failure, 0) end
		helpers.assert_true(reentered, "the real writer rechecks policy before launching its native reservation")
		helpers.assert_eq(#rows(writer), 0, "the retired provisional source cannot enter a new append")
	end)
end)


helpers.it("Linux trigger ROI: real canonical file transitions reject malformed encryption without input reparsing", function()
	Home.run(function()
		local path = require("infra.config_paths").config("config.toml")
		local shell = require("adapters.shell_runner")
		assert(shell.run("mkdir -p " .. shell.quote(path:match("^(.*)/[^/]+$"))))
		local function write(source)
			local file = assert(io.open(path, "wb")); assert(file:write(source)); assert(file:close())
		end
		write('[metrics]\nenabled = true\nencrypt = "true"\n')
		Native.with(function(collector)
			helpers.assert_true(collector.init(Home.options({ sqlite_path = Home.fresh_db() })))
			local writer = require("modules.keystats.sqlite_writer")
			local preferences = require("infra.metrics_preferences")
			local original_get, reads = preferences.get, 0
			preferences.get = function(...) reads = reads + 1; return original_get(...) end
			local called, failure = xpcall(function()
				for _, source in ipairs({ '[metrics]\nenabled = true\nencrypt = "true"\n',
					'metrics = []\n', '[[metrics]]\nencrypt = false\n' }) do
					write(source)
					Native.flush(collector)
					local before = reads
					for _ = 1, 5 do helpers.assert_eq(collector.record_roi_text("malformedrequest ", context(), unknown), false) end
					helpers.assert_eq(reads, before, "input uses the observed RAM policy, never reparses configuration")
				end
				write('[metrics]\nenabled = true\nencrypt = false\n')
				Native.flush(collector)
				helpers.assert_eq(#rows(writer), 0)
				for _ = 1, 5 do collector.record_roi_text("freshvalid ", context(), unknown) end
				Native.flush(collector)
				helpers.assert_eq(#rows(writer), 1)
				helpers.assert_eq(rows(writer)[1].meta.word, "freshvalid")
			end, debug.traceback)
			preferences.get = original_get
			if not called then error(failure, 0) end
		end)
	end)
end)


Home.it("Linux trigger ROI: effective cipher activation closes text before calling the provider", function()
	Native.with(function(collector)
		local writer = start(collector)
		for _ = 1, 5 do collector.record_roi_text("discarded ", context(), unknown) end
		for _ = 1, 4 do collector.record_roi_text("renewed ", context(), unknown) end
		local configuration = assert(collector.configuration_snapshot())
		configuration.cipher_enabled = true
		helpers.assert_eq(configuration.encrypt, false, "requested and effective posture are distinct configuration fields")
		local cipher = require("modules.keystats.text_cipher")
		local original_available, observed = cipher.is_available, false
		cipher.is_available = function()
			observed = true
			helpers.assert_eq(collector.record_roi_text("duringactivation ", context(), unknown), false,
				"the provider cannot reenter still-admitted textual capture")
			return false
		end
		local called, failure = pcall(function() helpers.assert_eq(collector.apply_configuration(configuration), false) end)
		cipher.is_available = original_available
		if not called then error(failure, 0) end
		helpers.assert_true(observed)
		Native.flush(collector)
		helpers.assert_eq(#rows(writer), 0)
		collector.record_roi_text("renewed ", context(), unknown)
		Native.flush(collector)
		helpers.assert_eq(#rows(writer), 0, "a refused effective activation cannot resurrect old occurrences")
		for _ = 1, 4 do collector.record_roi_text("renewed ", context(), unknown) end
		Native.flush(collector)
		helpers.assert_eq(rows(writer)[1].meta.word, "renewed")
	end)
end)
