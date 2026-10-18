--- tests/unit/modules/llm/features/selection/test_pending_keychain.lua

--- ==============================================================================
--- MODULE: Selection Request Authority Across Native Keychain
--- DESCRIPTION:
--- Runs actual tone/translation flows, prediction engine, core, remote resolver,
--- Text and Quartz FIFO with an encrypted active credential. Only the native
--- Keychain completion is held: revocation cannot disclose a copied selection
--- when that credential later resolves or native encoding re-enters the owner.
--- ==============================================================================

local helpers = require("tests.helpers")
local FIFO = require("tests.support.modules.llm.selection_translation_fifo")
local Tone = require("llm.tone")

local FLOWS = {
	{ name = "tone", start = function(w) return w.tone.step(Tone.MORE_FORMAL, false) end,
		reset = function(w) w.tone.reset() end },
	{ name = "translation", start = function(w) return w.flow.run("en") end,
		reset = function(w) w.flow.reset() end },
}

--- Uses real credential identity/cache logic over a deferred native secret read.
--- @param scenario function Complete native request scenario.
local function with_keychain(scenario, backboard)
	return helpers.with_fresh_modules({
		"modules.llm.tone_rewrite", "modules.llm.mlx_stream_retirement", "adapters.event_provenance",
		"tests.support.modules.llm.selection_translation_scope",
		"tests.support.modules.llm.selection_translation_destination",
	}, function()
		return FIFO.with_world(function(world)
			world.tone = require("modules.llm.tone_rewrite")
			world.pending_keys = {}
			local crypto = require("modules.llm.api_token_crypto")
			crypto.decrypt_async = function(stored, completed)
				local read = { stored = stored, completed = completed, cancelled = false }
				world.pending_keys[#world.pending_keys + 1] = read
				return { cancel = function() read.cancelled = true; return true end }
			end
			return scenario(world)
		end, nil, { token = "keychain:selection-key", provider = backboard and "backboard" or nil,
			model = backboard and "openai/gpt-4o-mini" or nil })
	end)
end

local function awaiting_key(world, flow)
	helpers.assert_true(flow.start(world))
	world.flush()
	helpers.assert_eq(#world.pending_keys, 1, "the real credential resolver must await native Keychain")
	helpers.assert_eq(world.pending_keys[1].stored, "keychain:selection-key")
	helpers.assert_eq(#world.posts, 0, "private selection must still be local")
end

helpers.describe("selection authority survives pending native Keychain", function()
	for _, flow in ipairs(FLOWS) do
		helpers.it(flow.name .. " sends its still-current selection after Keychain resolves", function()
			with_keychain(function(world)
				awaiting_key(world, flow)
				world.pending_keys[1].completed(true, "cleartext-key")
				helpers.assert_eq(#world.posts, 1)
				helpers.assert_eq(world.posts[1].headers.Authorization, "Bearer cleartext-key")
				helpers.assert_true(world.posts[1].body.messages[2].content:find("Hello", 1, true) ~= nil)
			end)
		end)
		for _, change in ipairs({ "focus", "flow reset", "engine reset", "preview off", "AI off and on", "encoding" }) do
			helpers.it(flow.name .. " refuses selection disclosure after pending-key " .. change, function()
				with_keychain(function(world)
					awaiting_key(world, flow)
					local encoded = false
					if change == "focus" then world.native_destination.change_focus("8:202")
					elseif change == "flow reset" then flow.reset(world)
					elseif change == "engine reset" then helpers.assert_true(world.engine.reset())
					elseif change == "preview off" then helpers.assert_true(world.engine.set_preview_ai_enabled(false))
					elseif change == "AI off and on" then
						helpers.assert_true(world.engine.set_llm_enabled(false))
						helpers.assert_true(world.engine.set_llm_enabled(true))
					else
						local native_encode = hs.json.encode
						hs.json.encode = function(...)
							encoded = true
							helpers.assert_true(world.engine.reset())
							return native_encode(...)
						end
					end
					world.pending_keys[1].completed(true, "cleartext-key")
					if change == "encoding" then helpers.assert_true(encoded, "the real payload must cross native encoding") end
					helpers.assert_eq(#world.posts, 0, "a revoked private selection must never reach HTTP")
					helpers.assert_eq(#world.document, 0)
					for _, notice in ipairs(world.notices) do
						helpers.assert_true(notice ~= "llm.translate.failed", "cancellation is not a provider failure")
					end
				end)
			end)
		end

		helpers.it(flow.name .. " preserves a successor sharing the same pending Keychain read", function()
			with_keychain(function(world)
				awaiting_key(world, flow)
				world.selection = "Fresh choice"
				helpers.assert_true(flow.start(world))
				world.flush()
				helpers.assert_eq(#world.pending_keys, 1, "native credential ownership must remain coalesced")
				world.pending_keys[1].completed(true, "cleartext-key")
				helpers.assert_eq(#world.posts, 1, "only the successor may publish")
				helpers.assert_true(world.posts[1].body.messages[2].content:find("Fresh choice", 1, true) ~= nil)
			end)
		end)
	end


	for _, phase in ipairs({ "assistant", "message" }) do
		helpers.it("keeps Backboard " .. phase .. " cancellation distinct from provider failure", function()
			with_keychain(function(world)
				awaiting_key(world, FLOWS[2])
				if phase == "message" then
					world.pending_keys[1].completed(true, "cleartext-key")
					helpers.assert_eq(#world.posts, 1, "only assistant creation precedes revocation")
					helpers.assert_true(world.posts[1].url:match("/assistants$") ~= nil)
				end
				world.native_destination.change_focus("8:202")
				if phase == "assistant" then world.pending_keys[1].completed(true, "cleartext-key")
				else world.posts[1].callback({ ok = true, status = 200, body = hs.json.encode({ assistant_id = "asst-1" }) }) end
				helpers.assert_eq(#world.posts, phase == "assistant" and 0 or 1, "revoked selection must never be sent")
				for _, notice in ipairs(world.notices) do
					helpers.assert_true(notice ~= "llm.translate.failed", "cancellation is not a Backboard provider failure")
				end
				helpers.assert_eq(#world.document, 0)
			end, true)
		end)
	end

	helpers.it("sends current Backboard translation after assistant creation", function()
		with_keychain(function(world)
			awaiting_key(world, FLOWS[2])
			world.pending_keys[1].completed(true, "cleartext-key")
			helpers.assert_eq(#world.posts, 1)
			world.posts[1].callback({ ok = true, status = 200, body = hs.json.encode({ assistant_id = "asst-1" }) })
			helpers.assert_eq(#world.posts, 2)
			helpers.assert_true(world.posts[2].url:match("/threads/messages$") ~= nil)
			helpers.assert_eq(world.posts[2].body.assistant_id, "asst-1")
			helpers.assert_true(world.posts[2].body.content:find("Hello", 1, true) ~= nil)
		end, true)
	end)

	helpers.it("preserves Backboard assistant HTTP failure detail for raw callers", function()
		with_keychain(function(world)
			local failure
			world.core.api_remote.request_raw(nil, "system", "selection", "", 0.1, 32,
				function() error("failed assistant must not answer") end, function(detail) failure = detail end)
			world.pending_keys[1].completed(true, "cleartext-key")
			world.posts[1].callback({ ok = false, status = 503, body = "unavailable" })
			helpers.assert_eq(type(failure), "table")
			helpers.assert_eq(failure.reason, "assistant_http_503")
			helpers.assert_eq(failure.status, 503)
		end, true)
	end)

	helpers.it("preserves an unguarded legacy remote raw request", function()
		with_keychain(function(world)
			world.core.api_remote.request_raw(nil, "legacy system", "legacy selection", "", 0.1, 32,
				function() end, function() error("the healthy legacy request must not fail") end)
			helpers.assert_eq(#world.pending_keys, 1)
			world.pending_keys[1].completed(true, "cleartext-key")
			helpers.assert_eq(#world.posts, 1)
			helpers.assert_eq(world.posts[1].body.messages[2].content, "legacy selection")
		end)
	end)
	helpers.it("retains the original final-guard exception while cancelling remote raw HTTP", function()
		with_keychain(function(world)
			local failures, errors = {}, {}
			require("infra.logger").error = function(_, template, ...)
				errors[#errors + 1] = string.format(template, ...)
			end
			world.core.api_remote.request_raw(nil, "system", "private selection", "", 0.1, 32,
				function() error("a revoked request must receive no response") end,
				function(reason) failures[#failures + 1] = reason end,
				{ current = function() error("pending-key authority boundary failure") end })
			helpers.assert_eq(#world.pending_keys, 1)
			world.pending_keys[1].completed(true, "cleartext-key")
			helpers.assert_eq(#world.posts, 0)
			helpers.assert_eq(failures[1], "cancelled")
			helpers.assert_eq(#errors, 1)
			helpers.assert_true(errors[1]:find("pending-key authority boundary failure", 1, true) ~= nil,
				"the native-boundary guard exception must remain observable")
		end)
	end)

	helpers.it("rejects a false authority instead of treating it as absent", function()
		with_keychain(function(world)
			local accepted = pcall(world.core.api_remote.request_raw, nil, "system", "private selection", "", 0.1, 32,
				function() end, function() end, { current = false })
			helpers.assert_eq(accepted, false)
			helpers.assert_eq(#world.pending_keys, 0)
			helpers.assert_eq(#world.posts, 0)
		end)
	end)

end)
