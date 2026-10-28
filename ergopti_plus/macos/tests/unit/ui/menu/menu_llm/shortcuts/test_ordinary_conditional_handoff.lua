--- tests/unit/ui/menu/menu_llm/shortcuts/test_ordinary_conditional_handoff.lua

--- ==============================================================================
--- MODULE: Ordinary Hotkey Conditional Handoff Regression Tests
--- DESCRIPTION:
--- Exercises the real registrar and public profile owner through the existing
--- real-registrar fixture. Conditional acquisition represents an acknowledged
--- source; no input-source probe, native key event, model or process is started.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Preserves the complete incoming cache, including cold transitive publications.
local function cache_snapshot()
	local snapshot = {}
	for name, value in pairs(package.loaded) do snapshot[name] = value end
	return snapshot
end

--- Runs cleanup independently so a body failure cannot abandon another handle.
--- @param body function Receives actual owners and exact fixture capabilities.
local function with_handoff_fixture(body)
	local saved_cache = cache_snapshot()
	local loaded = package.loaded
	local saved_hs, saved_lfs = rawget(_G, "hs"), rawget(_G, "lfs")
	local saved_open, saved_remove, saved_date = io.open, os.remove, os.date
	local keycode_owner, saved_keycode_map
	local outcome = table.pack(xpcall(function()
		package.loaded["tests.support.profile_delete_fixture"] = nil
		local Fixture = require("tests.support.profile_delete_fixture")
		Fixture.with_trigger_fixture({ real_registrar = true }, function(fixture)
			-- Own only this fixture's map slot; retain every raw entry and its metatable.
			-- The canonical mac_keycodes.json registry defines KeyA=0 and KeyB=11.
			keycode_owner, saved_keycode_map = _G.hs.keycodes, _G.hs.keycodes.map
			local scoped_keycode_map = {}
			for key, value in next, saved_keycode_map do scoped_keycode_map[key] = value end
			setmetatable(scoped_keycode_map, getmetatable(saved_keycode_map))
			scoped_keycode_map.a, scoped_keycode_map.b = 0, 11
			keycode_owner.map = scoped_keycode_map
			helpers.assert_eq(keycode_owner.map.a, 0, "fixture physical A must use the canonical macOS code")
			helpers.assert_eq(keycode_owner.map.b, 11, "fixture physical B must differ from physical A")
			local registrar = require("adapters.hotkey_registrar")
			local owned = {}
			local owned_claims, finalizers = {}, {}
			local function remember(token, conditional)
				if token ~= nil then
					owned[#owned + 1] = { token = token, conditional = conditional, live = true }
				end
				return token
			end
			local function release(token)
				local released = registrar.unbind(token)
				if released == true then
					for _, record in ipairs(owned) do
						if record.token == token then record.live = false end
					end
				end
				return released
			end
			local context = { fixture = fixture, registrar = registrar, release = release }
			function context.conditional(callback)
				local code = _G.hs.keycodes.map.a
				helpers.assert_eq(type(code), "number", "the fixture must expose a proven physical A")
				local token = remember(registrar.bind_conditional({ "ctrl" }, code, callback), true)
				helpers.assert_not_nil(token, "the preexisting conditional must acquire its actual registrar owner")
				local native = fixture.get_last_native_handle()
				helpers.assert_true(native ~= nil and native.enabled == true and native.deleted == false)
				return token, native, registrar.physical_identity({ "ctrl" }, code)
			end
			function context.ordinary(chord, callback)
				return remember(registrar.bind(chord, callback or function() end), false)
			end
			function context.claim(owner, rows)
				owned_claims[owner] = true
				return registrar.replace_physical_claims(owner, rows)
			end
			function context.conditional_token(callback)
				return remember(registrar.bind_conditional({ "ctrl" }, _G.hs.keycodes.map.a, callback), true)
			end
			function context.finally(action) finalizers[#finalizers + 1] = action end
			function context.calls(operation)
				local count = 0
				for _, observed in ipairs(fixture.backend.calls) do if observed == operation then count = count + 1 end end
				return count
			end
			local result = table.pack(xpcall(function() body(context) end, debug.traceback))
			-- Plans belong to this fixture; a failed oracle must not inject another
			-- fault into the independent capability-release checks below.
			fixture.backend.plans = {}
			local cleanup_errors = {}
			local function cleanup(action)
				local ok, err = xpcall(action, debug.traceback)
				if not ok then cleanup_errors[#cleanup_errors + 1] = err end
			end
			for index = #finalizers, 1, -1 do cleanup(finalizers[index]) end
			-- Public profile owners release before direct ordinary and conditional tokens.
			cleanup(function()
				helpers.assert_eq(fixture.orchestrator.disarm_shortcuts(), true,
					"fixture must retire every actual profile hotkey")
			end)
			for owner in pairs(owned_claims) do
				cleanup(function()
					helpers.assert_eq(registrar.replace_physical_claims(owner, {}), true,
						"fixture must release its exact explicit claim owner")
				end)
			end
			for _, conditional in ipairs({ false, true }) do
				for _, record in ipairs(owned) do
					if record.live and record.conditional == conditional then
						cleanup(function()
							helpers.assert_eq(release(record.token), true,
								"fixture must retire its exact registrar token")
						end)
					end
				end
			end
			cleanup(function() helpers.assert_eq(registrar.live_count(), 0, "fixture retains no registrar owner") end)
			cleanup(function() helpers.assert_nil(next(registrar.physical_claims()), "fixture retains no physical claim") end)
			cleanup(function() helpers.assert_nil(next(fixture.backend.entries), "fixture retains no native hotkey") end)
			cleanup(function()
				keycode_owner.map = saved_keycode_map
				helpers.assert_true(rawequal(keycode_owner.map, saved_keycode_map), "fixture must restore its exact keycode map slot")
			end)
			local cleanup_detail = #cleanup_errors > 0 and ("\nHANDOFF CLEANUP FAILED:\n" .. table.concat(cleanup_errors, "\n")) or ""
			if not result[1] then error(tostring(result[2]) .. cleanup_detail, 0) end
			if cleanup_detail ~= "" then error(cleanup_detail, 0) end
		end)
	end, debug.traceback))
	-- Restore even when construction, the first causal assertion, or cleanup failed.
	if keycode_owner ~= nil then keycode_owner.map = saved_keycode_map end
	_G.hs, _G.lfs = saved_hs, saved_lfs
	for name in pairs(loaded) do if saved_cache[name] == nil then loaded[name] = nil end end
	for name, value in pairs(saved_cache) do loaded[name] = value end
	helpers.assert_true(rawequal(package.loaded, loaded), "fixture must preserve the module cache table")
	for name, value in pairs(saved_cache) do
		helpers.assert_true(rawequal(loaded[name], value), "fixture must restore the exact cache entry: " .. tostring(name))
	end
	for name, value in pairs(loaded) do
		helpers.assert_true(rawequal(saved_cache[name], value), "fixture must remove a new cache entry: " .. tostring(name))
	end
	helpers.assert_true(rawequal(rawget(_G, "hs"), saved_hs) and rawequal(rawget(_G, "lfs"), saved_lfs))
	helpers.assert_true(io.open == saved_open and os.remove == saved_remove and os.date == saved_date,
		"fixture must preserve unrelated native IO and calendar ports")
	if not outcome[1] then error(outcome[2], 0) end
end

helpers.describe("ordinary hotkeys release exact conditional suspension", function()
	helpers.it("restores conditional delivery after final ordinary unbind (hotkey-ordinary-handoff)", function()
		with_handoff_fixture(function(context)
			local fired = 0
			local _, native, identity = context.conditional(function() fired = fired + 1 end)
			local fixture, registrar = context.fixture, context.registrar
			fixture.fire(native)
			helpers.assert_eq(fired, 1, "the conditional must deliver before ordinary acquisition")
			local ordinary = context.ordinary("Ctrl+A")
			helpers.assert_not_nil(ordinary)
			helpers.assert_eq(native.enabled, false, "the explicit ordinary owner must take priority")
			fixture.fire(native)
			helpers.assert_eq(fired, 1, "the suspended conditional must not deliver")
			helpers.assert_eq(context.release(ordinary), true)
			helpers.assert_nil(registrar.physical_claims()[identity], "the final ordinary claim must be gone")
			fixture.fire(native)
			helpers.assert_eq(fired, 2,
				"the exact conditional action must resume after the final ordinary claim is released")
			helpers.assert_true(native.enabled and not native.deleted, "resume must reuse the exact conditional native handle")
		end)
	end)

	helpers.it("public profile disarm restores conditional delivery (hotkey-ordinary-handoff)", function()
		with_handoff_fixture(function(context)
			local fired = 0
			local _, native, identity = context.conditional(function() fired = fired + 1 end)
			local fixture, registrar = context.fixture, context.registrar
			fixture.fire(native)
			helpers.assert_eq(fired, 1)
			helpers.assert_eq(fixture.orchestrator.apply_llm_profile_shortcut("user_p", { "ctrl" }, "a"), true)
			local profile_native = fixture.get_last_native_handle()
			helpers.assert_true(profile_native ~= native and profile_native.enabled)
			fixture.fire(profile_native)
			helpers.assert_eq(fixture.get_prediction_count(), 1, "the actual public profile callback must deliver")
			helpers.assert_eq(native.enabled, false)
			fixture.state.llm_enabled = false
			helpers.assert_eq(fixture.orchestrator.disarm_shortcuts(), true)
			helpers.assert_nil(fixture.get_profile_hk("user_p"))
			helpers.assert_eq(fixture.state.llm_profile_shortcuts.user_p, { mods = { "ctrl" }, key = "a" })
			helpers.assert_nil(registrar.physical_claims()[identity])
			helpers.assert_true(profile_native.deleted, "disarm must retire the exact ordinary native handle")
			fixture.fire(native)
			helpers.assert_eq(fired, 2,
				"disarming the public profile shortcut must resume the exact conditional editor binding")
			helpers.assert_true(native.enabled and not native.deleted)
		end)
	end)

	helpers.it("public profile chord change restores its prior conditional (hotkey-ordinary-handoff)", function()
		with_handoff_fixture(function(context)
			local fired = 0
			local _, native, identity = context.conditional(function() fired = fired + 1 end)
			local fixture, registrar = context.fixture, context.registrar
			fixture.fire(native)
			helpers.assert_eq(fired, 1)
			helpers.assert_eq(fixture.orchestrator.apply_llm_profile_shortcut("user_p", { "ctrl" }, "a"), true)
			local prior = fixture.get_last_native_handle()
			helpers.assert_eq(fixture.orchestrator.apply_llm_profile_shortcut("user_p", { "ctrl" }, "b"), true)
			local current = fixture.get_last_native_handle()
			helpers.assert_true(prior.deleted and current ~= prior and current.enabled)
			helpers.assert_eq(fixture.state.llm_profile_shortcuts.user_p, { mods = { "ctrl" }, key = "b" })
			helpers.assert_eq(fixture.get_save_count(), 2, "use the normal public persistence route")
			helpers.assert_eq(fixture.get_menu_count(), 2, "use the normal public menu refresh route")
			helpers.assert_nil(registrar.physical_claims()[identity])
			fixture.fire(native)
			helpers.assert_eq(fired, 2,
				"changing the public profile chord must release its old conditional suspension")
			helpers.assert_true(native.enabled and not native.deleted)
			fixture.fire(current)
			helpers.assert_eq(fixture.get_prediction_count(), 1, "the successor profile must remain usable")
		end)
	end)
end)

helpers.describe("ordinary hotkey conditional handoff healthy controls", function()
	helpers.it("a nonmatching ordinary chord preserves conditional delivery (hotkey-ordinary-handoff)", function()
		with_handoff_fixture(function(context)
			local fired = 0
			local _, native = context.conditional(function() fired = fired + 1 end)
			local fixture = context.fixture
			fixture.fire(native)
			helpers.assert_eq(fired, 1)
			local ordinary = context.ordinary("Ctrl+B")
			helpers.assert_not_nil(ordinary)
			helpers.assert_true(native.enabled)
			fixture.fire(native)
			helpers.assert_eq(fired, 2)
			helpers.assert_eq(context.release(ordinary), true)
			fixture.fire(native)
			helpers.assert_eq(fired, 3, "an unrelated ordinary claim must never consume conditional delivery")
		end)
	end)

	helpers.it("manual disable revokes conditional restoration intent (hotkey-ordinary-handoff)", function()
		with_handoff_fixture(function(context)
			local fired = 0
			local conditional, native, identity = context.conditional(function() fired = fired + 1 end)
			local fixture, registrar = context.fixture, context.registrar
			fixture.fire(native)
			helpers.assert_eq(fired, 1)
			local ordinary = context.ordinary("Ctrl+A")
			helpers.assert_not_nil(ordinary)
			helpers.assert_eq(registrar.setEnabled(conditional, false), true)
			helpers.assert_eq(context.release(ordinary), true)
			helpers.assert_nil(registrar.physical_claims()[identity])
			fixture.fire(native)
			helpers.assert_eq(fired, 1, "a deliberate conditional disable must not be resurrected")
			helpers.assert_eq(native.enabled, false)
			helpers.assert_eq(native.deleted, false, "manual suspension still retains its exact owner")
		end)
	end)

	helpers.it("native ordinary bind refusal restores the conditional (hotkey-ordinary-handoff)", function()
		with_handoff_fixture(function(context)
			local fired = 0
			local _, native, identity = context.conditional(function() fired = fired + 1 end)
			local fixture, registrar = context.fixture, context.registrar
			fixture.fire(native)
			helpers.assert_eq(fired, 1)
			fixture.backend.plan("native_new", { "nil" })
			helpers.assert_nil(context.ordinary("Ctrl+A"), "a refused native ordinary owner must not publish a token")
			helpers.assert_nil(registrar.physical_claims()[identity])
			helpers.assert_true(native.enabled and not native.deleted)
			fixture.fire(native)
			helpers.assert_eq(fired, 2, "existing native-bind rollback must preserve the original conditional action")
		end)
	end)
end)

helpers.describe("ordinary hotkey restoration transactions", function()
	helpers.it("two ordinary owners restore only after the last exact delete", function()
		with_handoff_fixture(function(c)
			local fired = 0
			local conditional, native, identity = c.conditional(function() fired = fired + 1 end)
			local first, second = c.ordinary("Ctrl+A"), c.ordinary("Ctrl+A")
			helpers.assert_not_nil(first)
			helpers.assert_not_nil(second)
			helpers.assert_eq(c.registrar.setEnabled(conditional, true), false,
				"an explicit claim must fence even a manual enable request")
			helpers.assert_eq(c.release(first), true)
			helpers.assert_not_nil(c.registrar.physical_claims()[identity])
			helpers.assert_eq(native.enabled, false)
			helpers.assert_eq(c.calls("native_enable"), 0)
			c.fixture.fire(native)
			helpers.assert_eq(fired, 0)
			helpers.assert_eq(c.release(second), true)
			c.fixture.fire(native)
			helpers.assert_eq(fired, 1, "the last ordinary deletion must restore the original active intent")
			helpers.assert_eq(c.calls("native_delete"), 2)
			helpers.assert_nil(c.registrar.physical_claims()[identity])
		end)
	end)

	helpers.it("explicit owner releases before the last ordinary owner", function()
		with_handoff_fixture(function(c)
			local fired = 0
			local _, native, identity = c.conditional(function() fired = fired + 1 end)
			local ordinary = c.ordinary("Ctrl+A")
			helpers.assert_not_nil(ordinary)
			helpers.assert_eq(c.claim("handoff-explicit", {{chord="Ctrl+A", action="explicit"}}), true)
			helpers.assert_eq(c.claim("handoff-explicit", {}), true)
			helpers.assert_eq(native.enabled, false)
			helpers.assert_not_nil(c.registrar.physical_claims()[identity])
			helpers.assert_eq(c.release(ordinary), true)
			c.fixture.fire(native)
			helpers.assert_eq(fired, 1, "ordinary deletion must resume after the other explicit owner released")
		end)
	end)

	helpers.it("ordinary owner releases before the last explicit owner", function()
		with_handoff_fixture(function(c)
			local fired = 0
			local _, native, identity = c.conditional(function() fired = fired + 1 end)
			local ordinary = c.ordinary("Ctrl+A")
			helpers.assert_not_nil(ordinary)
			helpers.assert_eq(c.claim("handoff-explicit", {{chord="Ctrl+A", action="explicit"}}), true)
			helpers.assert_eq(c.release(ordinary), true)
			helpers.assert_eq(native.enabled, false)
			helpers.assert_not_nil(c.registrar.physical_claims()[identity])
			helpers.assert_eq(c.calls("native_enable"), 0)
			helpers.assert_eq(c.claim("handoff-explicit", {}), true)
			c.fixture.fire(native)
			helpers.assert_eq(fired, 1, "the final explicit release must retain the ordinary suspension receipt")
		end)
	end)

	helpers.it("inactive ordinary token still reserves its physical chord", function()
		with_handoff_fixture(function(c)
			local fired = 0
			local _, native, identity = c.conditional(function() fired = fired + 1 end)
			local ordinary = c.ordinary("Ctrl+A")
			helpers.assert_not_nil(ordinary)
			helpers.assert_eq(c.registrar.setEnabled(ordinary, false), true)
			helpers.assert_not_nil(c.registrar.physical_claims()[identity])
			helpers.assert_eq(c.registrar.has_physical_conflict({"ctrl"}, 0), true)
			helpers.assert_nil(c.conditional_token(function() end))
			helpers.assert_eq(c.release(ordinary), true)
			c.fixture.fire(native)
			helpers.assert_eq(fired, 1, "only deletion ACK may release an inactive ordinary claim")
		end)
	end)

	helpers.it("a conditional disabled before acquisition grants no restoration intent", function()
		with_handoff_fixture(function(c)
			local fired = 0
			local conditional, native = c.conditional(function() fired = fired + 1 end)
			helpers.assert_eq(c.registrar.setEnabled(conditional, false), true)
			local ordinary = c.ordinary("Ctrl+A")
			helpers.assert_not_nil(ordinary)
			helpers.assert_eq(c.registrar.setEnabled(conditional, true), false,
				"a refused enable cannot invent intent after an explicit disable")
			helpers.assert_eq(c.release(ordinary), true)
			helpers.assert_eq(c.calls("native_enable"), 0)
			c.fixture.fire(native)
			helpers.assert_eq(fired, 0)
			helpers.assert_eq(native.enabled, false)
		end)
	end)

	helpers.it("revoked conditional whose delete threw never resumes", function()
		with_handoff_fixture(function(c)
			local fired = 0
			local conditional, native = c.conditional(function() fired = fired + 1 end)
			local ordinary = c.ordinary("Ctrl+A")
			helpers.assert_not_nil(ordinary)
			c.fixture.backend.plan("native_delete", {"throw"})
			helpers.assert_eq(c.release(conditional), false)
			helpers.assert_eq(c.release(ordinary), true)
			helpers.assert_eq(c.calls("native_enable"), 0)
			helpers.assert_eq(native.deleted, false)
			c.fixture.fire(native)
			helpers.assert_eq(fired, 0)
			helpers.assert_eq(c.release(conditional), true)
			helpers.assert_eq(native.deleted, true)
		end)
	end)

	helpers.it("ordinary delete throw preserves claim until its retry ACK", function()
		with_handoff_fixture(function(c)
			local fired = 0
			local _, native, identity = c.conditional(function() fired = fired + 1 end)
			local ordinary = c.ordinary("Ctrl+A")
			local ordinary_native = c.fixture.get_last_native_handle()
			helpers.assert_not_nil(ordinary)
			c.fixture.backend.plan("native_delete", {"throw", "ok"})
			helpers.assert_eq(c.release(ordinary), false)
			helpers.assert_eq(ordinary_native.deleted, false)
			helpers.assert_eq(c.registrar.physical_claims()[identity].binding_id, ordinary)
			helpers.assert_eq(c.calls("native_enable"), 0)
			helpers.assert_eq(c.release(ordinary), true)
			helpers.assert_eq(c.calls("native_delete"), 2)
			c.fixture.fire(native)
			helpers.assert_eq(fired, 1, "conditional restoration must follow the successful delete retry")
		end)
	end)

	helpers.it("enable nil retains claim-free tombstone and never deletes twice", function()
		with_handoff_fixture(function(c)
			local fired = 0
			local _, native, identity = c.conditional(function() fired = fired + 1 end)
			local ordinary = c.ordinary("Ctrl+A")
			local ordinary_native = c.fixture.get_last_native_handle()
			helpers.assert_not_nil(ordinary)
			c.fixture.backend.plan("native_enable", {"nil"})
			helpers.assert_eq(c.release(ordinary), false, "refused restoration must retain an exact cleanup receipt")
			helpers.assert_eq(ordinary_native.deleted, true)
			helpers.assert_eq(c.registrar.release_pending(ordinary), true)
			helpers.assert_eq(c.registrar.chord_of(ordinary), "Ctrl+A")
			helpers.assert_eq(c.registrar.live_count(), 2)
			helpers.assert_nil(c.registrar.physical_claims()[identity])
			helpers.assert_eq(c.registrar.has_physical_conflict({"ctrl"}, 0), false)
			local calls = #c.fixture.backend.calls
			helpers.assert_eq(c.registrar.setEnabled(ordinary, false), true)
			helpers.assert_eq(c.registrar.setEnabled(ordinary, true), false)
			helpers.assert_eq(#c.fixture.backend.calls, calls, "a deleted native owner cannot receive another native method")
			-- Exercise synchronous Lua port reentry without claiming native delivery.
			local native_enable, reentered = native.enable
			c.finally(function() native.enable = native_enable end)
			native.enable = function(self)
				reentered = c.claim("handoff-restore-reentry", {})
				return native_enable(self)
			end
			helpers.assert_eq(c.release(ordinary), true)
			helpers.assert_eq(reentered, false, "restoration must exclude a reentrant claim transaction")
			helpers.assert_eq(c.calls("native_delete"), 1)
			helpers.assert_eq(c.calls("native_enable"), 2)
			helpers.assert_eq(c.registrar.release_pending(ordinary), false)
			helpers.assert_nil(c.registrar.chord_of(ordinary))
			c.fixture.fire(native)
			helpers.assert_eq(fired, 1)
		end)
	end)

	helpers.it("partial restoration settles every matching conditional and retries only refusal", function()
		with_handoff_fixture(function(c)
			local fired = 0
			local _, first = c.conditional(function() fired = fired + 1 end)
			local _, second = c.conditional(function() fired = fired + 1 end)
			helpers.assert_true(first ~= second, "the fixture must acquire two distinct conditional native owners")
			local ordinary = c.ordinary("Ctrl+A")
			helpers.assert_not_nil(ordinary)
			c.fixture.backend.plan("native_enable", {"nil", "ok"})
			helpers.assert_eq(c.release(ordinary), false, "a refused sibling must retain the release transaction")
			helpers.assert_eq(c.calls("native_enable"), 2, "one refusal must not abandon another eligible sibling")
			c.fixture.fire(first); c.fixture.fire(second)
			helpers.assert_eq(fired, 1)
			helpers.assert_nil(next(c.registrar.physical_claims()))
			helpers.assert_eq(c.release(ordinary), true)
			helpers.assert_eq(c.calls("native_enable"), 3, "retry must target only the exact refused receipt")
			helpers.assert_eq(c.calls("native_delete"), 1)
			c.fixture.fire(first); c.fixture.fire(second)
			helpers.assert_eq(fired, 3)
		end)
	end)

	helpers.it("failed native bind compensates every matching conditional", function()
		with_handoff_fixture(function(c)
			local fired = 0
			local _, first = c.conditional(function() fired = fired + 1 end)
			local _, second = c.conditional(function() fired = fired + 1 end)
			helpers.assert_true(first ~= second, "the fixture must acquire two distinct conditional native owners")
			c.fixture.backend.plan("native_new", {"nil"})
			helpers.assert_nil(c.ordinary("Ctrl+A"))
			helpers.assert_nil(next(c.registrar.physical_claims()))
			helpers.assert_true(first.enabled and second.enabled)
			c.fixture.fire(first); c.fixture.fire(second)
			helpers.assert_eq(fired, 2)
			helpers.assert_eq(c.registrar.live_count(), 2)
		end)
	end)

	helpers.it("failed bind compensation receipt blocks reacquisition until settlement", function()
		with_handoff_fixture(function(c)
			local fired = 0
			local _, native = c.conditional(function() fired = fired + 1 end)
			c.fixture.backend.plan("native_new", {"nil"})
			c.fixture.backend.plan("native_enable", {"nil"})
			helpers.assert_nil(c.ordinary("Ctrl+A"))
			helpers.assert_eq(native.enabled, false)
			helpers.assert_nil(next(c.registrar.physical_claims()))
			local factories = c.calls("native_new")
			c.fixture.backend.plan("native_enable", {"nil"})
			helpers.assert_nil(c.ordinary("Ctrl+A"), "unsettled compensation must refuse before another native factory")
			helpers.assert_eq(c.calls("native_new"), factories)
			-- Adversarial synchronous port reentry, not an observed native callback.
			local native_bind, reentered = _G.hs.hotkey.bind
			c.finally(function() _G.hs.hotkey.bind = native_bind end)
			_G.hs.hotkey.bind = function(...)
				reentered = c.claim("handoff-reentry", {})
				return native_bind(...)
			end
			local ordinary = c.ordinary("Ctrl+A")
			helpers.assert_not_nil(ordinary)
			helpers.assert_eq(reentered, false, "ordinary acquisition must exclude a reentrant claim transaction")
			helpers.assert_eq(c.release(ordinary), true)
			c.fixture.fire(native)
			helpers.assert_eq(fired, 1)
		end)
	end)

	helpers.it("partial native suspension failure compensates all touched conditionals", function()
		with_handoff_fixture(function(c)
			local fired = 0
			local _, first = c.conditional(function() fired = fired + 1 end)
			local _, second = c.conditional(function() fired = fired + 1 end)
			helpers.assert_true(first ~= second, "the fixture must acquire two distinct conditional native owners")
			c.fixture.reset_observations()
			c.fixture.backend.plan("native_disable", {"ok", "throw"})
			helpers.assert_nil(c.ordinary("Ctrl+A"))
			helpers.assert_eq(c.calls("native_new"), 0)
			helpers.assert_nil(next(c.registrar.physical_claims()))
			c.fixture.fire(first); c.fixture.fire(second)
			helpers.assert_eq(fired, 2, "failed suspension must compensate every touched conditional")
			helpers.assert_true(first.enabled and second.enabled)
		end)
	end)

	helpers.it("manual disable cancels restoration while ordinary tombstone is pending", function()
		with_handoff_fixture(function(c)
			local fired = 0
			local conditional, native = c.conditional(function() fired = fired + 1 end)
			local ordinary = c.ordinary("Ctrl+A")
			helpers.assert_not_nil(ordinary)
			c.fixture.backend.plan("native_enable", {"nil"})
			helpers.assert_eq(c.release(ordinary), false, "the release must own its refused restoration before revocation")
			helpers.assert_eq(c.registrar.setEnabled(conditional, false), true)
			local enables = c.calls("native_enable")
			helpers.assert_eq(c.release(ordinary), true)
			helpers.assert_eq(c.calls("native_enable"), enables)
			helpers.assert_eq(c.calls("native_delete"), 1)
			c.fixture.fire(native)
			helpers.assert_eq(fired, 0)
			helpers.assert_eq(native.enabled, false)
		end)
	end)
end)

helpers.describe("public profile irreversible release settlement", function()
	helpers.it("actual public profile disarm retries acknowledged deletion restoration", function()
		with_handoff_fixture(function(c)
			local fired = 0
			local _, native, identity = c.conditional(function() fired = fired + 1 end)
			local f, r = c.fixture, c.registrar
			helpers.assert_eq(f.orchestrator.apply_llm_profile_shortcut("user_p", {"ctrl"}, "a"), true)
			local old, old_native = f.get_profile_hk("user_p"), f.get_last_native_handle()
			f.reset_observations()
			f.state.llm_enabled = false
			f.backend.plan("native_enable", {"nil"})
			helpers.assert_eq(f.orchestrator.disarm_shortcuts(), false, "public disarm must expose pending conditional restoration")
			helpers.assert_eq(old_native.deleted, true)
			helpers.assert_eq(f.get_profile_hk("user_p"), old)
			helpers.assert_eq(r.release_pending(old), true)
			helpers.assert_nil(r.physical_claims()[identity])
			f.fire(old_native); f.fire(native)
			helpers.assert_eq(f.get_prediction_count(), 0)
			helpers.assert_eq(fired, 0)
			helpers.assert_eq(f.orchestrator.disarm_shortcuts(), true)
			helpers.assert_nil(f.get_profile_hk("user_p"))
			helpers.assert_eq(r.release_pending(old), false)
			helpers.assert_eq(f.state.llm_profile_shortcuts.user_p, {mods={"ctrl"}, key="a"})
			helpers.assert_eq(f.durable().llm_profile_shortcuts.user_p, {mods={"ctrl"}, key="a"})
			helpers.assert_eq(f.get_menu_snapshot().llm_profile_shortcuts.user_p, {mods={"ctrl"}, key="a"})
			helpers.assert_eq(f.get_save_count(), 0)
			helpers.assert_eq(f.get_menu_count(), 0)
			helpers.assert_eq(c.calls("native_new"), 0)
			helpers.assert_eq(c.calls("native_delete"), 1)
			f.fire(native)
			helpers.assert_eq(fired, 1)
		end)
	end)

	helpers.it("actual public profile chord change finishes persisted candidate on retry", function()
		with_handoff_fixture(function(c)
			local fired = 0
			local _, native, identity = c.conditional(function() fired = fired + 1 end)
			local f, r = c.fixture, c.registrar
			helpers.assert_eq(f.orchestrator.apply_llm_profile_shortcut("user_p", {"ctrl"}, "a"), true)
			local old, old_native = f.get_profile_hk("user_p"), f.get_last_native_handle()
			f.reset_observations()
			f.backend.plan("native_enable", {"ok", "nil"})
			helpers.assert_eq(f.orchestrator.apply_llm_profile_shortcut("user_p", {"ctrl"}, "b"), false,
				"public apply must retain irreversible release completion on restoration refusal")
			local candidate = f.get_last_native_handle()
			helpers.assert_true(candidate ~= old_native and not candidate.deleted and old_native.deleted)
			helpers.assert_eq(f.get_profile_hk("user_p"), old)
			f.fire(candidate); f.fire(native)
			helpers.assert_eq(f.get_prediction_count(), 0)
			helpers.assert_eq(fired, 0)
			helpers.assert_eq(f.state.llm_profile_shortcuts.user_p, {mods={"ctrl"}, key="b"})
			helpers.assert_eq(f.durable().llm_profile_shortcuts.user_p, {mods={"ctrl"}, key="b"})
			helpers.assert_eq(f.get_menu_snapshot().llm_profile_shortcuts.user_p, {mods={"ctrl"}, key="b"})
			helpers.assert_eq(f.orchestrator.apply_llm_profile_shortcut("user_p", {"ctrl"}, "b"), true)
			local current = f.get_profile_hk("user_p")
			helpers.assert_true(current ~= nil and current ~= old)
			helpers.assert_true(rawequal(f.get_last_native_handle(), candidate))
			helpers.assert_eq(c.calls("native_new"), 1)
			helpers.assert_eq(c.calls("native_delete"), 1)
			helpers.assert_eq(f.get_save_count(), 1)
			helpers.assert_eq(f.get_menu_count(), 1)
			helpers.assert_nil(r.physical_claims()[identity])
			helpers.assert_eq(r.physical_claims()[r.physical_identity({"ctrl"}, 11)].binding_id, current)
			f.fire(candidate); f.fire(native)
			helpers.assert_eq(f.get_prediction_count(), 1)
			helpers.assert_eq(fired, 1)
		end)
	end)

	helpers.it("actual public old-delete exception retains original rollback", function()
		with_handoff_fixture(function(c)
			local fired = 0
			local _, native, identity = c.conditional(function() fired = fired + 1 end)
			local f, r = c.fixture, c.registrar
			helpers.assert_eq(f.orchestrator.apply_llm_profile_shortcut("user_p", {"ctrl"}, "a"), true)
			local old, old_native = f.get_profile_hk("user_p"), f.get_last_native_handle()
			f.reset_observations()
			f.backend.plan("native_delete", {"throw", "ok"})
			helpers.assert_eq(f.orchestrator.apply_llm_profile_shortcut("user_p", {"ctrl"}, "b"), false)
			local candidate = f.get_last_native_handle()
			helpers.assert_eq(f.get_profile_hk("user_p"), old)
			helpers.assert_true(old_native.enabled and not old_native.deleted and candidate.deleted)
			helpers.assert_eq(r.physical_claims()[identity].binding_id, old)
			helpers.assert_eq(f.state.llm_profile_shortcuts.user_p, {mods={"ctrl"}, key="a"})
			helpers.assert_eq(f.durable().llm_profile_shortcuts.user_p, {mods={"ctrl"}, key="a"})
			helpers.assert_eq(f.get_menu_snapshot().llm_profile_shortcuts.user_p, {mods={"ctrl"}, key="a"})
			helpers.assert_eq(c.calls("native_new"), 1)
			helpers.assert_eq(c.calls("native_delete"), 2)
			helpers.assert_eq(f.get_save_count(), 2)
			helpers.assert_eq(f.get_menu_count(), 2)
			f.fire(old_native); f.fire(native)
			helpers.assert_eq(f.get_prediction_count(), 1)
			helpers.assert_eq(fired, 0)
			helpers.assert_eq(f.orchestrator.apply_llm_profile_shortcut("user_p", {"ctrl"}, "b"), true)
			f.fire(native)
			helpers.assert_eq(fired, 1)
		end)
	end)

	helpers.it("actual deferred removal lease restores one replacement after irreversible release", function()
		with_handoff_fixture(function(c)
			local f, r = c.fixture, c.registrar
			local _, native = c.conditional(function() end)
			helpers.assert_eq(f.orchestrator.apply_llm_profile_shortcut("user_p", {"ctrl"}, "a"), true)
			local old, old_native = f.get_profile_hk("user_p"), f.get_last_native_handle()
			local lease = f.orchestrator.apply_llm_profile_shortcut("user_p", nil, nil, {defer=true})
			helpers.assert_type(lease, "table")
			local closed = false
			c.finally(function()
				if not closed then
					helpers.assert_eq(lease.restore(), true)
					helpers.assert_eq(lease.finish_rollback(), true)
					closed = true
				end
			end)
			helpers.assert_eq(lease.publish(), true)
			f.reset_observations()
			f.backend.plan("native_enable", {"nil"})
			local committed = lease.commit()
			closed = committed == true
			helpers.assert_eq(committed, false, "deferred release must report the exact conditional restoration debt")
			helpers.assert_eq(old_native.deleted, true)
			helpers.assert_eq(r.release_pending(old), true)
			helpers.assert_eq(lease.restore(), true)
			local replacement, replacement_native = f.get_profile_hk("user_p"), f.get_last_native_handle()
			helpers.assert_true(replacement ~= nil and replacement ~= old)
			helpers.assert_true(replacement_native ~= old_native and replacement_native.enabled)
			helpers.assert_eq(r.chord_of(replacement), "Ctrl+A")
			helpers.assert_nil(r.chord_of(old))
			helpers.assert_eq(lease.restore(), true, "parent rollback reassertion must reuse its replacement")
			helpers.assert_eq(f.get_profile_hk("user_p"), replacement)
			helpers.assert_eq(c.calls("native_new"), 1)
			helpers.assert_eq(c.calls("native_delete"), 1)
			helpers.assert_eq(f.state.llm_profile_shortcuts.user_p, {mods={"ctrl"}, key="a"})
			helpers.assert_eq(native.enabled, false)
			f.fire(replacement_native)
			helpers.assert_eq(f.get_prediction_count(), 1)
			helpers.assert_eq(lease.finish_rollback(), true)
			closed = true
		end)
	end)

	helpers.it("deferred rollback replacement refusal remains retryable without duplicate owners", function()
		with_handoff_fixture(function(c)
			local f, r = c.fixture, c.registrar
			c.conditional(function() end)
			helpers.assert_eq(f.orchestrator.apply_llm_profile_shortcut("user_p", {"ctrl"}, "a"), true)
			local old = f.get_profile_hk("user_p")
			local lease = f.orchestrator.apply_llm_profile_shortcut("user_p", nil, nil, {defer=true})
			helpers.assert_type(lease, "table")
			local closed = false
			c.finally(function()
				if not closed then
					helpers.assert_eq(lease.restore(), true)
					helpers.assert_eq(lease.finish_rollback(), true)
					closed = true
				end
			end)
			helpers.assert_eq(lease.publish(), true)
			f.reset_observations()
			f.backend.plan("native_enable", {"nil"})
			local committed = lease.commit()
			closed = committed == true
			helpers.assert_eq(committed, false, "deferred failure must retain rollback ownership before replacement")
			f.backend.plan("native_new", {"nil"})
			helpers.assert_eq(lease.restore(), false)
			helpers.assert_nil(r.chord_of(old))
			helpers.assert_eq(r.live_count(), 1, "only the original conditional may remain after refused replacement")
			helpers.assert_eq(c.calls("native_new"), 1)
			helpers.assert_eq(c.calls("native_delete"), 1)
			helpers.assert_eq(lease.restore(), true)
			local replacement = f.get_profile_hk("user_p")
			helpers.assert_true(replacement ~= nil and replacement ~= old)
			helpers.assert_eq(r.chord_of(replacement), "Ctrl+A")
			helpers.assert_eq(lease.restore(), true)
			helpers.assert_eq(f.get_profile_hk("user_p"), replacement)
			helpers.assert_eq(c.calls("native_new"), 2)
			helpers.assert_eq(c.calls("native_delete"), 1)
			helpers.assert_eq(lease.finish_rollback(), true)
			closed = true
		end)
	end)
end)
