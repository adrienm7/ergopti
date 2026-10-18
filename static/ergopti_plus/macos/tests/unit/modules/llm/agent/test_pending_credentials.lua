--- tests/unit/modules/llm/agent/test_pending_credentials.lua

--- ==============================================================================
--- MODULE: Agent Pending Credential Authority
--- DESCRIPTION:
--- Exercise the real runner and remote transport while a native credential is
--- pending. Revoking the action must prevent dispatch of its private payload.
--- ==============================================================================

local helpers = require("tests.helpers")
local World = require("tests.support.agent_world")
local Scope = require("tests.support.modules.llm.selection_translation_scope")

require("logger")

local OWNED = {
	"modules.llm.agent_runner", "modules.llm.agent_learning", "modules.llm.agent_connectors",
	"llm.agent", "llm.agent_learning", "adapters.system_info", "infra.locale",
	"infra.dialog_util", "modules.llm.local_model_offer", "llm.translate",
	"adapters.event_provenance", "compat.utf8", "locale.core", "modules.shortcuts.script_control",
}

local function with_agent(options, scenario)
	helpers.with_fresh_modules(OWNED, function()
		Scope.run(function()
			local world = World.build_world(options)
			local remote = require("modules.llm.api_remote")
			local crypto = require("modules.llm.api_token_crypto")
			world.pending = {}
			crypto.is_encrypted = function(value) return value:sub(1, 9) == "keychain:" end
			crypto.decrypt_async = function(_, callback)
				world.pending[#world.pending + 1] = callback
				return { cancel = function() return true end }
			end
			remote.set_entries({
				{ id = "chat", provider = "cerebras", model = World.MODEL, token = "keychain:chat" },
				{ id = "board", provider = "backboard", token = "keychain:board" },
				{ id = "decision", provider = "typesafe", token = "keychain:decision" },
			})
			local codec = require("adapters.json_codec")
			local encode = codec.encode
			codec.encode = function(body)
				if world.on_encode then world.on_encode(body) end
				return encode(body)
			end
			scenario(world)
		end)
	end)
end

local SYSTEMS = {
	{ name = "System 2 chat", options = {}, start = function(w) return w.runner.run_selection() end },
	{ name = "System 2 Backboard", options = { system2 = "backboard" },
		start = function(w) return w.runner.run_selection() end },
	{ name = "System 1 chat", options = { mode = "auto", system1 = "cerebras" },
		start = function(w) w.runner.observe_typing(World.SELECTION); World.settle(w); return true end },
	{ name = "System 1 decisions", options = { mode = "auto", system1 = "typesafe" },
		start = function(w) w.runner.observe_typing(World.SELECTION); World.settle(w); return true end },
	{ name = "System 1 Backboard Jev", options = { mode = "auto", system1 = "backboard|typesafe/jev-1.13" },
		start = function(w) w.runner.observe_typing(World.SELECTION); World.settle(w); return true end },
}

helpers.describe("agent request authority survives pending native credentials", function()
	for _, system in ipairs(SYSTEMS) do
		for _, revocation in ipairs({ "off", "reset", "pause" }) do
			helpers.it(system.name .. " rejects a credential after " .. revocation .. " (agent-pending-authority)", function()
				with_agent(system.options, function(world)
					helpers.assert_true(system.start(world))
					helpers.assert_eq(#world.pending, 1, "the original native key must be pending")
					helpers.assert_eq(#world.posts, 0)
					if revocation == "off" then world.runner.set_mode("off")
					elseif revocation == "reset" then world.runner.reset()
					else package.loaded["modules.shortcuts.script_control"] = { is_paused = function() return true end } end
					world.pending[1](true, "fixture-key")
					helpers.assert_eq(#world.posts, 0, "revoked private agent input must not reach HTTP")
					helpers.assert_eq(#world.renders, 0)
				end)
			end)
		end

		helpers.it(system.name .. " dispatches with a still-current credential (agent-pending-authority)", function()
			with_agent(system.options, function(world)
				helpers.assert_true(system.start(world))
				helpers.assert_eq(#world.pending, 1)
				world.pending[1](true, "fixture-key")
				helpers.assert_eq(#world.posts, 1, "the healthy request must reach the actual HTTP boundary")
			end)
		end)

		helpers.it(system.name .. " rechecks after encoding (agent-pending-authority)", function()
			with_agent(system.options, function(world)
				helpers.assert_true(system.start(world))
				helpers.assert_eq(#world.pending, 1)
				world.on_encode = function() world.runner.reset() end
				world.pending[1](true, "fixture-key")
				helpers.assert_eq(#world.posts, 0, "encoding cannot revive a retired action")
			end)
		end)
	end

	helpers.it("keeps a newer selection while its predecessor awaits a credential (agent-pending-authority)", function()
		with_agent({}, function(world)
			helpers.assert_true(world.runner.run_selection())
			world.selection = "Successor private input"
			helpers.assert_true(world.runner.run_selection())
			helpers.assert_eq(#world.pending, 2)
			world.pending[1](true, "fixture-key")
			helpers.assert_eq(#world.posts, 0)
			world.pending[2](true, "fixture-key")
			helpers.assert_eq(#world.posts, 1)
			helpers.assert_true(world.posts[1].body.messages[2].content:find("Successor private input", 1, true) ~= nil)
		end)
	end)

	for index = 1, 2 do
		local system = SYSTEMS[index]
		for _, change in ipairs({ "surface closed", "pause and resume" }) do
			helpers.it(system.name .. " rejects a late credential after " .. change .. " (agent-surface-authority)", function()
				with_agent(system.options, function(world)
					local paused = false
					package.loaded["modules.shortcuts.script_control"] = { is_paused = function() return paused end }
					helpers.assert_true(system.start(world))
					helpers.assert_eq(#world.pending, 1)
					if change == "pause and resume" then
						paused = true
						world.runner.cancel_typing("pause")
					end
					-- The pause bridge and dismissal both invalidate the answer surface.
					world.engine.reset()
					paused = false
					world.pending[1](true, "fixture-key")
					helpers.assert_eq(#world.posts, 0, "a retired answer surface cannot send private input")
				end)
			end)
		end
	end

	for _, system1 in ipairs({ false, true }) do
		helpers.it("rechecks Backboard authority after assistant creation for System " .. (system1 and "1" or "2")
			.. " (agent-pending-authority)", function()
			local system = SYSTEMS[system1 and 5 or 2]
			with_agent(system.options, function(world)
				helpers.assert_true(system.start(world))
				world.pending[1](true, "fixture-key")
				helpers.assert_eq(#world.posts, 1)
				helpers.assert_true(world.posts[1].url:find("/assistants", 1, true) ~= nil)
				world.runner.set_mode("off")
				world.posts[1].callback({ ok = true, status = 200, body = '{"assistant_id":"owned-assistant"}' })
				helpers.assert_eq(#world.posts, 1, "an assistant response cannot dispatch a revoked private message")
			end)
		end)
	end
end)
