--- tests/unit/modules/hotstrings/magic_key/test_magic_key_source_caller_cohort_after.lua

--- ==============================================================================
--- MODULE: Physical Magic Key (Linux)
--- DESCRIPTION:
--- `hotstrings.magic_key_source` names the physical key that types the magic
--- key, on every driver. Linux used a fixed key: whatever its XKB layout put
--- the magic key on, with no way to choose another. These cases replay the
--- shared decisions with evdev codes, read the canonical config.toml leaf, and
--- drive the consumption decision the keyboard hook asks for every grabbed
--- key-down: the chosen key is consumed, the magic key typed in its place and
--- handed to the character path; every other press stays the application's.
--- ==============================================================================

package.loaded["tests.support.modules.hotstrings.magic_key.magic_key_source_fixture"] = nil
local Fixture = require("tests.support.modules.hotstrings.magic_key.magic_key_source_fixture")
local helpers, KEY_J, with_source, wire, run_due, caller_cohort, native_caption_corpus, with_magic_notice, magic_notice_cache_snapshot, assert_magic_notice_cache_restored, capture_pause_controller, with_collision_source =
	Fixture.helpers, Fixture.KEY_J, Fixture.with_source, Fixture.wire, Fixture.run_due, Fixture.caller_cohort, Fixture.native_caption_corpus, Fixture.with_magic_notice, Fixture.magic_notice_cache_snapshot, Fixture.assert_magic_notice_cache_restored, Fixture.capture_pause_controller, Fixture.with_collision_source




helpers.describe("magic key source: caller cohort after layout and admission callbacks", function()
	helpers.it("retains an unchanged actual source without typing or publishing", function()
		caller_cohort(function(Source)
			local source = Source.editor_source()
			helpers.assert_eq(source.status, "ready")
			helpers.assert_eq(source.candidates[1].text, ";")
			helpers.assert_true(source.candidates[1].direct)
		end)
	end)
	for _, kind in ipairs({ "group", "session", "preference", "origin", "source export", "collaborator", "observed issuer", "final source callback" }) do
		helpers.it("refuses a " .. kind .. " retirement after direct enumeration", function()
			caller_cohort(function(Source, Preferences, capture, layout, state, path, deps)
				local getter, replacements = capture.source_generation, 0
				state.on_plan = function()
					if kind == "group" then
						state.on_group = function() state.group = 1; state.native_epoch = state.native_epoch + 1 end
					elseif kind == "session" then helpers.assert_true(layout.refresh(path))
					elseif kind == "preference" then helpers.assert_true(Source.set("KeyJ"))
					elseif kind == "source export" then
						capture.source_generation = function() replacements = replacements + 1; return 1 end
					elseif kind == "collaborator" then deps.direct_source_admitted = function() return true end
					elseif kind == "observed issuer" then state.observed = false
					elseif kind == "final source callback" then
						state.on_source = function() helpers.assert_true(Source.set("KeyJ")) end
					end
				end
				if kind == "origin" then state.on_admit = function() state.origin.ready = false; state.origin.generation = 2 end end
				local called, result = pcall(Source.editor_source)
				capture.source_generation = getter
				if not called then error(result, 0) end
				helpers.assert_eq(result.status, "unavailable")
				helpers.assert_eq(result.candidates, {})
				helpers.assert_eq(result.reason, "direct-source-changed")
				helpers.assert_eq(replacements, 0, "replacement cannot acquire the retained source's authority")
				if kind == "preference" or kind == "final source callback" then helpers.assert_eq(Source.get(), "KeyJ") end
			end)
		end)
	end
end)




helpers.describe("independent final-source-callback origin currency", function()
 helpers.it("refuses origin retirement after the earlier origin rejoin", function()
  caller_cohort(function(Source, Preferences, capture, layout, state)
   state.on_plan = function()
    state.on_source = function() state.origin.ready = false; state.origin.generation = 2 end
   end
   local result = Source.editor_source()
   helpers.assert_eq(state.origin.ready, false, "the final native callback withdrew origin")
   helpers.assert_eq(result.status, "unavailable", "origin must rejoin after the final source callback")
   helpers.assert_eq(result.candidates, {})
  end)
 end)
end)




helpers.describe("independent final-origin-callback capture currency", function()
 helpers.it("refuses same-map capture replacement during final origin rejoin", function()
  caller_cohort(function(Source, Preferences, capture, layout, state, path, deps)
   local reads, fired = 0, false
   deps.input_source_receipt = function()
    reads = reads + 1
    if reads == 2 then fired = true; helpers.assert_true(layout.refresh(path)) end
    return { generation = state.origin.generation, ready = state.origin.ready }
   end
   local result = Source.editor_source()
   helpers.assert_true(fired, "the final origin getter replaced the actual capture session")
   helpers.assert_eq(result.status, "unavailable", "same-map Capture retirement must survive the final origin callback")
   helpers.assert_eq(result.candidates, {})
  end)
 end)
end)




helpers.describe("editor source: retained Capture RAM owner", function()
	helpers.it("a native issuer closure cannot survive same-map Capture replacement", function()
		caller_cohort(function(_, _, capture, layout, _, path)
			local generation, _, current = capture.source_generation()
			helpers.assert_type(generation, "number")
			helpers.assert_type(current, "function")
			helpers.assert_true(current())
			helpers.assert_true(layout.refresh(path))
			helpers.assert_eq(current(), false, "issuer identity alone cannot keep a destroyed Capture session current")
		end)
	end)

	helpers.it("a source query cannot borrow the session its callback created", function()
		caller_cohort(function(_, _, capture, layout, state, path)
			state.on_source = function() helpers.assert_true(layout.refresh(path)) end
			local generation, reason, current = capture.source_generation()
			helpers.assert_nil(generation)
			helpers.assert_eq(reason, "native-source-owner-changed")
			helpers.assert_nil(current)
		end)
	end)

	helpers.it("does not manufacture an issuer for an unsealed controlled source tuple", function()
		caller_cohort(function(_, _, capture, _, state)
			local backend
			for index = 1, 100 do
				local name, value = debug.getupvalue(capture.source_generation, index)
				if name == "_backend" then backend = value; break end
				if not name then break end
			end
			-- The predecessor exports source_identity directly through its wrapper.
			if not backend then
				local _, identity = debug.getupvalue(capture.source_generation, 1)
				for index = 1, 100 do
					local name, value = debug.getupvalue(identity, index)
					if name == "_backend" then backend = value; break end
					if not name then break end
				end
			end
			helpers.assert_type(backend, "table")
			backend.source_group = function() return state.group, state.native_epoch end
			local generation, _, current = capture.source_generation()
			helpers.assert_type(generation, "number")
			helpers.assert_nil(current, "RAM owner wrapping cannot upgrade absent native issuer evidence")
		end)
	end)
end)




helpers.describe("declared physical magic notice captions", function()
	for code, original in pairs(native_caption_corpus.locales) do
		helpers.it("(native-magic-caption) receives original notice title/body through actual capture in " .. code, function()
			with_magic_notice(function(f)
				f.locale.set_locale(code)
				f.capture()
				helpers.assert_eq(f.notices[1], { title = original.captions.magic_key_source_notice.original_bare_caption,
					message = f.i18n.get("dialog.magic_key_source.prompt"), level = "info" })
				helpers.assert_true(f.source.on_key({ code = 57, mods = {} }))
				run_due(f.calls)
				helpers.assert_eq(f.notices[2], { title = original.captions.magic_key_source_notice.original_bare_caption,
					message = f.i18n.get("dialog.magic_key_source.not_a_candidate"), level = "warning" })
				helpers.assert_eq(f.source.get(), "auto")
				helpers.assert_eq(f.changed(), 0)
				helpers.assert_eq(f.calls.typed, {})
			end)
		end)
	end
	helpers.it("(native-magic-caption) actual declaration withdrawal refuses delivery and exact repair preserves capture", function()
		with_magic_notice(function(f)
			local original, observed = f.policy.native_presentation, 0
			f.policy.native_presentation = function() observed = observed + 1; return {} end
			f.capture()
			helpers.assert_eq(f.notices, {})
			helpers.assert_eq(observed, 0)
			helpers.assert_true(f.source.on_key({ code = 1, mods = {} }))
			run_due(f.calls)
			f.policy.native_presentation = original
			f.capture()
			helpers.assert_eq(#f.notices, 1)
			helpers.assert_eq(f.notices[1].title, f.i18n.get("dialog.magic_key_source.title"))
			helpers.assert_eq(f.source.get(), "auto")
		end)
	end)
	helpers.it("(native-magic-caption) wrong kind, platform, borrowed receipt and locale drift refuse bare titles", function()
		with_magic_notice(function(f)
			helpers.assert_nil(f.native.prepare("magic_key_source_notice", "dialog"))
			helpers.assert_nil(f.native.prepare("profile_shortcut_dialog", "dialog"))
			helpers.assert_nil(f.native.title({}))
			f.locale.set_locale("fr")
			local receipt = f.native.prepare("magic_key_source_notice", "notification")
			helpers.assert_type(receipt, "table")
			f.locale.set_locale("es")
			helpers.assert_nil(f.native.title(receipt))
			f.locale.set_locale("fr")
			helpers.assert_eq(f.native.title(receipt), native_caption_corpus.locales.fr.captions.magic_key_source_notice.original_bare_caption)
		end)
	end)
end)




helpers.describe("physical magic notice fixture lifecycle", function()
	helpers.it("(native-magic-caption-lifecycle) setup import failure restores every owned cache entry", function()
		local saved, primary, secondary = magic_notice_cache_snapshot(), {}, {}
		local preload, original = package.preload, package.preload["infra.locale"]
		local ok, failure = pcall(function()
			rawset(preload, "infra.locale", function() error(primary, 0) end)
			with_magic_notice(function() error("setup failure must prevent scenario entry", 0) end, secondary)
		end)
		local restored, restore_failure = pcall(function() rawset(preload, "infra.locale", original) end)
		helpers.assert_true(restored, restore_failure)
		helpers.assert_true(rawequal(rawget(preload, "infra.locale"), original))
		helpers.assert_eq(ok, false)
		helpers.assert_true(rawequal(failure, primary), "setup primary object must survive independent cleanup")
		helpers.assert_eq(secondary, {})
		assert_magic_notice_cache_restored(saved)
	end)
	helpers.it("(native-magic-caption-lifecycle) scenario primary survives real policy locale and cache restoration", function()
		local saved, primary, secondary = magic_notice_cache_snapshot(), {}, {}
		local owner, lookup, locale, previous
		local ok, failure = pcall(function()
			with_magic_notice(function(f)
				owner, lookup, locale, previous = f.policy, f.policy.native_presentation, f.locale, f.locale.current_locale()
				f.policy.native_presentation = function() return {} end
				f.locale.set_locale(previous == "es" and "fr" or "es")
				error(primary, 0)
			end, secondary)
		end)
		helpers.assert_eq(ok, false)
		helpers.assert_true(rawequal(failure, primary))
		helpers.assert_eq(secondary, {})
		helpers.assert_true(rawequal(owner.native_presentation, lookup))
		helpers.assert_eq(locale.current_locale(), previous)
		assert_magic_notice_cache_restored(saved)
	end)
	helpers.it("(native-magic-caption-lifecycle) simultaneous reset failure remains separate while later restores complete", function()
		local saved, primary, cleanup_primary, secondary = magic_notice_cache_snapshot(), {}, {}, {}
		local source, reset, owner, lookup, locale, previous
		local ok, failure = pcall(function()
			with_magic_notice(function(f)
				source, reset = f.source, f.source._reset_for_test
				owner, lookup, locale, previous = f.policy, f.policy.native_presentation, f.locale, f.locale.current_locale()
				source._reset_for_test = function() reset(); error(cleanup_primary, 0) end
				f.policy.native_presentation = function() return {} end
				f.locale.set_locale(previous == "es" and "fr" or "es")
				error(primary, 0)
			end, secondary)
		end)
		-- Restore the control's own function replacement even if the scenario failed.
		local restored, restore_failure = pcall(function() source._reset_for_test = reset end)
		helpers.assert_true(restored, restore_failure)
		helpers.assert_true(rawequal(source._reset_for_test, reset))
		helpers.assert_eq(ok, false)
		helpers.assert_true(rawequal(failure, primary), "cleanup failure must not replace the scenario primary")
		helpers.assert_eq(#secondary, 1)
		helpers.assert_eq(secondary[1].operation, "physical_source_reset")
		helpers.assert_true(rawequal(secondary[1].failure, cleanup_primary))
		helpers.assert_true(rawequal(owner.native_presentation, lookup))
		helpers.assert_eq(locale.current_locale(), previous)
		assert_magic_notice_cache_restored(saved)
	end)
end)




helpers.describe("magic key source: capture answer queue admission", function()
	for _, mode in ipairs({ "refuse", "throw", "premature" }) do
		helpers.it("keeps the physical key native and the capture retryable after " .. mode, function()
			with_source(nil, function(Source, Preferences, path)
				local state = { active = true, replace = true, typed_ok = true, answer = mode }
				local calls = wire(Source, state)
				local chosen, refused = {}, {}
				local handlers = {
					on_chosen = function(value) chosen[#chosen + 1] = value end,
					on_refused = function(reason) refused[#refused + 1] = reason end,
				}
				helpers.assert_true(Source.capture(handlers))
				helpers.assert_eq(Source.on_key({ code = KEY_J, mods = {} }), false)
				run_due(calls)
				helpers.assert_eq(chosen, {})
				helpers.assert_eq(refused, {})
				helpers.assert_eq(Source.get(), "auto")
				local handle = io.open(path, "rb")
				if handle then handle:close() end
				helpers.assert_nil(handle, "refused scheduling creates no preference document")
				helpers.assert_eq(Source.capture(handlers), false, "the original timed capture remains owned")
				state.answer = nil
				helpers.assert_true(Source.on_key({ code = KEY_J, mods = {} }))
				helpers.assert_eq(chosen, {}, "persistence remains outside the key callback")
				run_due(calls)
				helpers.assert_eq(chosen, { "KeyJ" })
				helpers.assert_eq(Source.get(), "KeyJ")
				helpers.assert_eq(#calls.typed, 0)
				helpers.assert_eq(#calls.dispatched, 0)
				Source._reset_for_test()
			end)
		end)
	end
end)




helpers.describe("magic key source: genuine pause notification retires captures", function()
	for _, stage in ipairs({ "waiting", "answered", "roundtrip" }) do
		helpers.it("discards a " .. stage .. " capture at the real daemon pause callback", function()
			with_source(nil, function(Source, Preferences, path)
				local state = { active = true, replace = true, typed_ok = true }
				local calls = wire(Source, state)
				local controller = capture_pause_controller(Source, state)
				local chosen = {}
				local handlers = { on_chosen = function(value) chosen[#chosen + 1] = value end, on_refused = function() end }
				helpers.assert_true(Source.capture(handlers))
				if stage ~= "waiting" then helpers.assert_true(Source.on_key({ code = KEY_J, mods = {} })) end
				controller.toggle_pause()
				if stage == "roundtrip" then controller.toggle_pause() end
				if stage == "waiting" then helpers.assert_eq(Source.on_key({ code = KEY_J, mods = {} }), false) end
				run_due(calls)
				helpers.assert_eq(chosen, {})
				helpers.assert_eq(Source.get(), "auto")
				local file = io.open(path, "rb"); if file then file:close() end
				helpers.assert_nil(file, "retired capture cannot create preferences")
				if stage ~= "roundtrip" then controller.toggle_pause() end
				helpers.assert_true(Source.capture(handlers), "resume permits a fresh capture, not the old choice")
				helpers.assert_true(Source.on_key({ code = KEY_J, mods = {} }))
				run_due(calls)
				helpers.assert_eq(chosen, { "KeyJ" })
				Source._reset_for_test()
			end)
		end)
	end

	for _, stage in ipairs({ "before_press", "after_answer" }) do
		helpers.it("refuses capture input after grab loss " .. stage, function()
			with_source(nil, function(Source)
				local state = { active = true, replace = true, typed_ok = true }
				local calls = wire(Source, state)
				local chosen = {}
				local handlers = { on_chosen = function(value) chosen[#chosen + 1] = value end, on_refused = function() end }
				helpers.assert_true(Source.capture(handlers))
				if stage == "after_answer" then helpers.assert_true(Source.on_key({ code = KEY_J, mods = {} })) end
				state.grab = false
				if stage == "before_press" then helpers.assert_eq(Source.on_key({ code = KEY_J, mods = {} }), false) end
				run_due(calls)
				helpers.assert_eq(chosen, {})
				helpers.assert_eq(Source.get(), "auto")
				state.grab = true
				helpers.assert_true(Source.capture(handlers))
				Source._reset_for_test()
			end)
		end)
	end

	helpers.it("leaves the physical key native if pause and resume occur inside deferred submission", function()
		with_source(nil, function(Source)
			local state = { active = true, replace = true, typed_ok = true }
			local calls = wire(Source, state)
			local controller = capture_pause_controller(Source, state)
			local chosen = {}
			local handlers = { on_chosen = function(value) chosen[#chosen + 1] = value end, on_refused = function() end }
			helpers.assert_true(Source.capture(handlers))
			state.answer_pause = function() controller.toggle_pause(); controller.toggle_pause() end
			helpers.assert_eq(Source.on_key({ code = KEY_J, mods = {} }), false)
			run_due(calls)
			helpers.assert_eq(chosen, {})
			helpers.assert_eq(Source.get(), "auto")
			helpers.assert_true(Source.capture(handlers))
			Source._reset_for_test()
		end)
	end)
end)




helpers.describe("magic key source: newer admitted capture requests fence queued predecessors", function()
	local function handlers(chosen)
		return { on_chosen = function(value) chosen[#chosen + 1] = value end,
			on_refused = function() error("This declared candidate should not be refused") end }
	end
	helpers.it("a fresh admitted B fences queued A while preserving B and its later answer", function()
		with_source(nil, function(Source, Preferences, path)
			local calls = wire(Source, { active = true, replace = true, typed_ok = true })
			local a, b = {}, {}
			helpers.assert_true(Source.capture(handlers(a)))
			helpers.assert_true(Source.on_key({ code = KEY_J, mods = {} }))
			helpers.assert_true(Source.capture(handlers(b)), "a fresh request can start after A answer admission")
			run_due(calls)
			helpers.assert_eq(a, {}, "the superseded A callback must not notify")
			helpers.assert_eq(b, {})
			helpers.assert_eq(Source.get(), "auto", "the superseded A callback must not persist")
			local file = io.open(path, "rb"); if file then file:close() end
			helpers.assert_nil(file, "A cannot create a preference document after B admission")
			helpers.assert_eq(Source.capture(handlers({})), false, "B remains the exact pending capture")
			helpers.assert_true(Source.on_key({ code = KEY_J, mods = {} }))
			run_due(calls)
			helpers.assert_eq(a, {})
			helpers.assert_eq(b, { "KeyJ" })
			Source._reset_for_test()
		end)
	end)
	helpers.it("a refused B timeout grants no generation authority over acknowledged A", function()
		with_source(nil, function(Source)
			local state = { active = true, replace = true, typed_ok = true, fail_arm = false }
			local actual_init = Source.init
			Source.init = function(dependencies)
				local actual_defer = dependencies.defer
				dependencies.defer = function(callback, delay)
					if delay > 0 and state.fail_arm then return false end
					return actual_defer(callback, delay)
				end
				return actual_init(dependencies)
			end
			local calls = wire(Source, state); Source.init = actual_init
			local a, b = {}, {}
			helpers.assert_true(Source.capture(handlers(a)))
			helpers.assert_true(Source.on_key({ code = KEY_J, mods = {} }))
			state.fail_arm = true
			helpers.assert_eq(Source.capture(handlers(b)), false)
			run_due(calls)
			helpers.assert_eq(a, { "KeyJ" }, "unadmitted B cannot invalidate the accepted prior answer")
			helpers.assert_eq(b, {})
			Source._reset_for_test()
		end)
	end)
	helpers.it("stale A submission cannot cancel B created by a reentrant answer callback", function()
		with_source(nil, function(Source)
			local state = { active = true, replace = true, typed_ok = true }
			local calls = wire(Source, state)
			local a, b = {}, {}
			helpers.assert_true(Source.capture(handlers(a)))
			state.answer_pause = function()
				state.answer_pause = nil
				Source.cancel_capture()
				helpers.assert_true(Source.capture(handlers(b)), "reentrant B must actually be admitted")
			end
			helpers.assert_eq(Source.on_key({ code = KEY_J, mods = {} }), false)
			helpers.assert_eq(Source.capture(handlers({})), false, "the stale mismatch path must preserve B")
			run_due(calls)
			helpers.assert_eq(a, {})
			helpers.assert_eq(Source.get(), "auto")
			helpers.assert_true(Source.on_key({ code = KEY_J, mods = {} }))
			run_due(calls)
			helpers.assert_eq(a, {})
			helpers.assert_eq(b, { "KeyJ" })
			Source._reset_for_test()
		end)
	end)
end)




helpers.describe("magic key source: native timeout throw is a refused capture admission", function()
	local function timed_throw_source(Source, state)
		local init = Source.init
		Source.init = function(dependencies)
			local actual_defer = dependencies.defer
			dependencies.defer = function(callback, delay)
				if delay > 0 and state.throw_arm then
					if state.reentrant then state.reentrant() end
					error("Controlled native timeout submission refusal")
				end
				return actual_defer(callback, delay)
			end
			return init(dependencies)
		end
		local calls = wire(Source, state); Source.init = init
		return calls
	end
	local function answer(chosen)
		return { on_chosen = function(value) chosen[#chosen + 1] = value end,
			on_refused = function() error("Timed admission failure must not publish a choice") end }
	end
	helpers.it("returns false instead of propagating an initial native timeout exception", function()
		with_source(nil, function(Source)
			local state = { active = true, replace = true, typed_ok = true, throw_arm = true }
			timed_throw_source(Source, state)
			local called, started = pcall(Source.capture, answer({}))
			helpers.assert_true(called, "native timer refusal must remain a typed false result")
			helpers.assert_eq(started, false, "a thrown timeout was not admitted")
			Source._reset_for_test()
		end)
	end)
	helpers.it("does not leak the capture slot after a throwing initial timeout", function()
		with_source(nil, function(Source)
			local state = { active = true, replace = true, typed_ok = true, throw_arm = true }
			local calls = timed_throw_source(Source, state)
			local failed, fresh = {}, {}
			pcall(Source.capture, answer(failed))
			state.throw_arm = false
			helpers.assert_true(Source.capture(answer(fresh)), "the failed candidate must release only its own slot")
			helpers.assert_true(Source.on_key({ code = KEY_J, mods = {} }))
			run_due(calls)
			helpers.assert_eq(failed, {})
			helpers.assert_eq(fresh, { "KeyJ" })
			Source._reset_for_test()
		end)
	end)
	helpers.it("preserves queued A generation when B timeout submission throws", function()
		with_source(nil, function(Source)
			local state = { active = true, replace = true, typed_ok = true, throw_arm = false }
			local calls = timed_throw_source(Source, state)
			local a, b = {}, {}
			helpers.assert_true(Source.capture(answer(a)))
			helpers.assert_true(Source.on_key({ code = KEY_J, mods = {} }))
			state.throw_arm = true
			local called, started = pcall(Source.capture, answer(b))
			run_due(calls)
			helpers.assert_eq(a, { "KeyJ" }, "B acquired no generation authority over the prior acknowledged A")
			helpers.assert_eq(b, {})
			helpers.assert_true(called)
			helpers.assert_eq(started, false)
			state.throw_arm = false
			helpers.assert_true(Source.capture(answer({})), "failed B must leave no hidden capture debt")
			Source._reset_for_test()
		end)
	end)
	helpers.it("failed A timeout cannot cancel reentrant admitted B", function()
		with_source(nil, function(Source)
			local state = { active = true, replace = true, typed_ok = true, throw_arm = true }
			local calls = timed_throw_source(Source, state)
			local a, b = {}, {}
			state.reentrant = function()
				state.reentrant, state.throw_arm = nil, false
				Source.cancel_capture()
				helpers.assert_true(Source.capture(answer(b)))
			end
			local called, started = pcall(Source.capture, answer(a))
			helpers.assert_true(called)
			helpers.assert_eq(started, false)
			helpers.assert_eq(Source.capture(answer({})), false, "reentrant B remains the exact admitted owner")
			helpers.assert_true(Source.on_key({ code = KEY_J, mods = {} }))
			run_due(calls)
			helpers.assert_eq(a, {})
			helpers.assert_eq(b, { "KeyJ" })
			Source._reset_for_test()
		end)
	end)
end)




helpers.describe("configured Magic Key collision receipt", function()
	helpers.it("(magic-collision) observes the real plain replacement consumer without typing during capture", function()
		with_collision_source('[hotstrings]\nmagic_key_source = "KeyJ"\n', function(Source)
			local calls = wire(Source, { active = true, replace = true, typed_ok = true })
			local frame = assert(Source.capture_collision_inventory())
			helpers.assert_eq(frame.claims, { { kind = "chord", binding = "magic_key_source__replacement", code = 36, mods = {} } })
			helpers.assert_true(frame.current()); helpers.assert_true(frame.sealed())
			helpers.assert_eq(calls.typed, {}); helpers.assert_eq(calls.dispatched, {})
			helpers.assert_true(Source.on_key({ code = 36, mods = {} }))
			helpers.assert_eq(calls.typed, { "★" }); helpers.assert_eq(calls.dispatched, { { char = "★", code = 36 } })
		end)
	end)
	for _, case in ipairs({
		{ name = "absent automatic source", content = nil, state = { active = true, replace = true } },
		{ name = "explicit automatic source", content = '[hotstrings]\nmagic_key_source = "auto"\n', state = { active = true, replace = true } },
		{ name = "paused owner", state = { active = false, replace = true } },
		{ name = "replacement switched off", state = { active = true, replace = false } },
		{ name = "untypable replacement", state = { active = true, replace = true, typable = false } },
		{ name = "prior native owner refusal", state = { active = true, replace = true, blocked_code = 36 } },
	}) do
		helpers.it("(magic-collision) has no replacement reservation for " .. case.name, function()
			local content = case.content
			if not case.name:find("automatic", 1, true) then content = '[hotstrings]\nmagic_key_source = "KeyJ"\n' end
			with_collision_source(content, function(Source)
				local calls = wire(Source, case.state)
				local frame = assert(Source.capture_collision_inventory())
				helpers.assert_eq(frame.claims, {}); helpers.assert_true(frame.current())
				helpers.assert_eq(Source.on_key({ code = 36, mods = {} }), false)
				helpers.assert_eq(calls.typed, {}); helpers.assert_eq(calls.dispatched, {})
			end)
		end)
	end
	helpers.it("(magic-collision) refuses waiting and accepted queued choices until real settlement", function()
		with_collision_source('[hotstrings]\nmagic_key_source = "KeyJ"\n', function(Source)
			local calls, chosen = wire(Source, { active = true, replace = true, typed_ok = true }), {}
			helpers.assert_true(Source.capture({ on_chosen = function(value) chosen[#chosen + 1] = value end, on_refused = function() error("candidate is admitted") end }))
			helpers.assert_nil(Source.capture_collision_inventory())
			helpers.assert_true(Source.on_key({ code = 46, mods = {} }))
			helpers.assert_eq(chosen, {}, "the accepted key has not yet published its preference")
			helpers.assert_nil(Source.capture_collision_inventory(), "_capture is now nil but the genuine queued setter remains pending")
			run_due(calls)
			helpers.assert_eq(chosen, { "KeyC" })
			local frame = assert(Source.capture_collision_inventory())
			helpers.assert_eq(frame.claims[1].code, 46); helpers.assert_true(frame.current())
			helpers.assert_eq(calls.typed, {}); helpers.assert_eq(calls.dispatched, {})
		end)
	end)
	helpers.it("(magic-collision) cancellation withdraws a queued choice without retiring a successor", function()
		with_collision_source('[hotstrings]\nmagic_key_source = "KeyJ"\n', function(Source)
			local calls, chosen = wire(Source, { active = true, replace = true, typed_ok = true }), {}
			helpers.assert_true(Source.capture({ on_chosen = function(value) chosen[#chosen + 1] = value end, on_refused = function() error("cancelled request must not notify") end }))
			helpers.assert_true(Source.on_key({ code = 46, mods = {} }))
			Source.cancel_capture()
			local successor = assert(Source.capture_collision_inventory())
			run_due(calls)
			helpers.assert_eq(chosen, {}); helpers.assert_eq(Source.get(), "KeyJ")
			helpers.assert_true(successor.current()); helpers.assert_eq(successor.claims[1].code, 36)
		end)
	end)
	helpers.it("(magic-collision) real preference acquisition and inverse revoke the original frame", function()
		with_collision_source('[hotstrings]\nmagic_key_source = "KeyJ"\n', function(Source, Preferences)
			wire(Source, { active = true, replace = true, typed_ok = true })
			local frame, snapshot, token = assert(Source.capture_collision_inventory()), assert(Preferences.snapshot()), {}
			helpers.assert_true(Preferences.acquire(token)); helpers.assert_eq(frame.current(), false)
			helpers.assert_nil(Source.capture_collision_inventory())
			helpers.assert_true(Preferences.adopt(token, snapshot.document))
			helpers.assert_true(Preferences.restore(token, snapshot)); helpers.assert_true(Preferences.release(token))
			helpers.assert_eq(frame.current(), false, "restoring equal values cannot restore the old preference generation")
			helpers.assert_true(assert(Source.capture_collision_inventory()).current())
		end)
	end)
	helpers.it("(magic-collision) refuses changed source bytes before the preference cache refresh", function()
		with_collision_source('[hotstrings]\nmagic_key_source = "KeyJ"\n', function(Source, Preferences, path)
			wire(Source, { active = true, replace = true, typed_ok = true })
			local frame, generation = assert(Source.capture_collision_inventory()), Preferences.generation()
			local file = assert(io.open(path, "wb")); file:write('[hotstrings]\nmagic_key_source = "KeyC"\n'); file:close()
			helpers.assert_eq(Preferences.generation(), generation)
			helpers.assert_eq(frame.current(), false); helpers.assert_nil(Source.capture_collision_inventory())
			helpers.assert_true(Preferences.refresh())
			local fresh = assert(Source.capture_collision_inventory())
			helpers.assert_eq(fresh.claims[1].code, 46); helpers.assert_true(fresh.current())
		end)
	end)
	helpers.it("(magic-collision) late initialization revokes the known inactive constructor frame", function()
		with_collision_source('[hotstrings]\nmagic_key_source = "KeyJ"\n', function(Source)
			local frame = assert(Source.capture_collision_inventory())
			helpers.assert_eq(frame.claims, {}); helpers.assert_true(frame.current())
			wire(Source, { active = true, replace = true, typed_ok = true })
			helpers.assert_eq(frame.current(), false)
			helpers.assert_eq(assert(Source.capture_collision_inventory()).claims[1].code, 36)
		end)
	end)
end)




helpers.describe("accepted Magic choice observation ends on every callback exit", function()
	helpers.it("(magic-pending-finally) chosen handler error propagates after real publication without retaining observation debt", function()
		with_collision_source('[hotstrings]\nmagic_key_source = "KeyJ"\n', function(Source)
			local calls = wire(Source, { active = true, replace = true, typed_ok = true })
			local primary, chosen = {}, {}
			helpers.assert_true(Source.capture({
				on_chosen = function(value) chosen[#chosen + 1] = value; error(primary, 0) end,
				on_refused = function() error("the real setter must accept KeyC") end,
			}))
			helpers.assert_true(Source.on_key({ code = 46, mods = {} }))
			helpers.assert_nil(Source.capture_collision_inventory())
			local ok, failure = pcall(run_due, calls)
			helpers.assert_eq(ok, false); helpers.assert_true(rawequal(failure, primary))
			helpers.assert_eq(chosen, { "KeyC" }); helpers.assert_eq(Source.get(), "KeyC")
			local frame = assert(Source.capture_collision_inventory())
			helpers.assert_eq(frame.claims[1].code, 46); helpers.assert_true(frame.current())
			helpers.assert_eq(calls.typed, {}); helpers.assert_eq(calls.dispatched, {})
		end)
	end)
	helpers.it("(magic-pending-finally) refused handler error propagates after real setter refusal without retaining observation debt", function()
		with_collision_source('[hotstrings]\nmagic_key_source = "KeyJ"\n', function(Source, _, path)
			local calls = wire(Source, { active = true, replace = true, typable = false })
			local primary, refused = {}, {}
			local file = assert(io.open(path, "rb")); local before = file:read("*a"); file:close()
			helpers.assert_true(Source.capture({
				on_chosen = function() error("the real untypable setter must refuse") end,
				on_refused = function(reason) refused[#refused + 1] = reason; error(primary, 0) end,
			}))
			helpers.assert_true(Source.on_key({ code = 46, mods = {} }))
			local ok, failure = pcall(run_due, calls)
			helpers.assert_eq(ok, false); helpers.assert_true(rawequal(failure, primary))
			helpers.assert_eq(refused, { "dialog.magic_key_source.untypable" }); helpers.assert_eq(Source.get(), "KeyJ")
			file = assert(io.open(path, "rb")); local after = file:read("*a"); file:close()
			helpers.assert_eq(after, before)
			local frame = assert(Source.capture_collision_inventory())
			helpers.assert_eq(frame.claims, {}); helpers.assert_true(frame.current())
			helpers.assert_eq(calls.typed, {}); helpers.assert_eq(calls.dispatched, {})
		end)
	end)
	helpers.it("(magic-pending-finally) deferred readiness error propagates without a setter or retained observation debt", function()
		with_collision_source('[hotstrings]\nmagic_key_source = "KeyJ"\n', function(Source, _, path)
			local primary, throwing, notified = {}, false, 0
			local state = setmetatable({ active = true, replace = true, typed_ok = true }, {
				__index = function(_, name) if name == "grab" and throwing then error(primary, 0) end end,
			})
			local calls = wire(Source, state)
			local file = assert(io.open(path, "rb")); local before = file:read("*a"); file:close()
			helpers.assert_true(Source.capture({ on_chosen = function() notified = notified + 1 end,
				on_refused = function() notified = notified + 1 end }))
			helpers.assert_true(Source.on_key({ code = 46, mods = {} }))
			throwing = true
			local ok, failure = pcall(run_due, calls)
			throwing = false
			helpers.assert_eq(ok, false); helpers.assert_true(rawequal(failure, primary))
			helpers.assert_eq(notified, 0); helpers.assert_eq(Source.get(), "KeyJ")
			file = assert(io.open(path, "rb")); local after = file:read("*a"); file:close()
			helpers.assert_eq(after, before)
			local frame = assert(Source.capture_collision_inventory())
			helpers.assert_eq(frame.claims[1].code, 36); helpers.assert_true(frame.current())
		end)
	end)
	helpers.it("(magic-pending-finally) throwing predecessor cannot clear an accepted reentrant successor choice", function()
		with_collision_source('[hotstrings]\nmagic_key_source = "KeyJ"\n', function(Source)
			local calls = wire(Source, { active = true, replace = true, typed_ok = true })
			local primary, successor = {}, {}
			helpers.assert_true(Source.capture({ on_chosen = function()
				helpers.assert_true(Source.capture({ on_chosen = function(value) successor[#successor + 1] = value end,
					on_refused = function() error("successor must accept its genuine key") end }))
				helpers.assert_true(Source.on_key({ code = 36, mods = {} }))
				error(primary, 0)
			end, on_refused = function() error("predecessor must accept its genuine key") end }))
			helpers.assert_true(Source.on_key({ code = 46, mods = {} }))
			local ok, failure = pcall(run_due, calls)
			helpers.assert_eq(ok, false); helpers.assert_true(rawequal(failure, primary))
			helpers.assert_eq(Source.get(), "KeyC"); helpers.assert_eq(successor, {})
			helpers.assert_nil(Source.capture_collision_inventory(), "the successor still owns a real deferred setter")
			run_due(calls)
			helpers.assert_eq(successor, { "KeyJ" }); helpers.assert_eq(Source.get(), "KeyJ")
			local frame = assert(Source.capture_collision_inventory())
			helpers.assert_eq(frame.claims[1].code, 36); helpers.assert_true(frame.current())
			helpers.assert_eq(calls.typed, {}); helpers.assert_eq(calls.dispatched, {})
		end)
	end)
end)

