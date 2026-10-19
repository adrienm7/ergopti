--- tests/unit/modules/llm/features/screen_answer/test_session_ownership.lua

--- ==============================================================================
--- MODULE: Screen Answer Session Ownership Regression
--- DESCRIPTION:
--- Compose real Screen, Core, Engine and provider dispatch across held credentials,
--- model listings and replies. A screenshot and its transcript retain the exact
--- answer revision that admitted them, even when the screen generation survives.
--- ==============================================================================

local helpers = require("tests.helpers")
local Json = require("json")
local Fixture = require("tests.support.modules.llm.screen_answer_fixture")
local Scope = require("tests.support.modules.llm.selection_translation_scope")

local function upvalue(fn, target)
	for index = 1, 256 do
		local name, value = debug.getupvalue(fn, index)
		if not name then break end
		if name == target then return value, index end
	end
end

local function with_world(scenario, text_token)
	return helpers.with_fresh_modules({ "modules.llm.screen_answer", "modules.llm.local_model_offer",
		"infra.dialog_util", "modules.shortcuts.script_control" }, function()
		return Scope.run(function()
			local world = Fixture.build_world()
			local api = world.core.api_remote
			api.set_entries({
				{ id = "text", provider = "cerebras", token = text_token or "cerebras-token", model = "qwen-3.8-27b" },
				{ id = "vision", provider = "openai", token = "keychain:pending-screen", model = "gpt-4o" },
			})
			api.set_active_entry_id("text")
			local _, index = upvalue(api.is_ready, "_is_ready")
			debug.setupvalue(api.is_ready, assert(index), true)
			local crypto = require("modules.llm.api_token_crypto")
			helpers.assert_true(crypto.is_encrypted("keychain:pending-screen"))
			local decrypt = crypto.decrypt_async
			world.keys = {}
			crypto.decrypt_async = function(stored, done)
				if stored == "keychain:pending-screen" or stored == "keychain:pending-text" then
					world.keys[#world.keys + 1] = done
					return { cancel = function() return true end }
				end
				return decrypt(stored, done)
			end
			return scenario(world)
		end)
	end)
end

local function answer(post, text)
	post.callback({ ok = true, status = 200, headers = {}, body = Json.encode({
		choices = { { message = { content = text }, finish_reason = "stop" } },
	}) })
end

local function capture(world, backend)
	helpers.assert_true(Fixture.trigger(world, "llm_screen_region", backend or "openai|gpt-4.1-mini"))
	world.captures[1].on_image("image", "private-screen-base64")
	return world.engine.current_request_revision()
end

local function replace(world, change)
	if change == "reset" then helpers.assert_true(world.engine.reset())
	else helpers.assert_not_nil(world.engine.open_answer_surface("successor")) end
	return world.engine.current_request_revision(), world.hides
end

local function preserved(world, revision, hides)
	helpers.assert_eq(world.engine.current_request_revision(), revision, "the old owner cannot reset its successor")
	helpers.assert_eq(world.hides, hides, "the old owner cannot hide its successor")
	helpers.assert_eq(#world.notices, 0, "retirement is not a screen-reading failure")
end

helpers.describe("private screen data retains the exact answer session", function()
	helpers.it("completes one current vision and all three text answers", function()
		with_world(function(world)
			capture(world)
			helpers.assert_eq(#world.vision_posts, 0)
			world.keys[1](true, "vision-key")
			helpers.assert_eq(#world.vision_posts, 1)
			answer(world.vision_posts[1], "SCREEN: private transcript")
			for index = 1, 3 do answer(assert(world.text_posts[index]), "ANSWER: Candidate " .. index) end
			helpers.assert_eq(#world.text_posts, 3)
			helpers.assert_eq(#world.engine.get_predictions(), 3)
			helpers.assert_true(world.engine.is_visible())
		end)
	end)

	for _, change in ipairs({ "reset", "replacement" }) do
		helpers.it("does not post a private image after " .. change .. " during Keychain", function()
			with_world(function(world)
				capture(world)
				local revision, hides = replace(world, change)
				world.keys[1](true, "vision-key")
				helpers.assert_eq(#world.vision_posts, 0)
				preserved(world, revision, hides)
			end)
		end)

		for _, text in ipairs({ "SCREEN: private old transcript", "no screen tag" }) do
			helpers.it("drops a vision reply after " .. change .. " (" .. text .. ")", function()
				with_world(function(world)
					capture(world)
					world.keys[1](true, "vision-key")
					local revision, hides = replace(world, change)
					answer(world.vision_posts[1], text)
					helpers.assert_eq(#world.text_posts, 0, "an old transcription must not borrow a new revision")
					preserved(world, revision, hides)
				end)
			end)
		end

		helpers.it("does not post a locally preflighted image after " .. change, function()
			with_world(function(world)
				capture(world, "local")
				helpers.assert_eq(#world.local_gets, 1)
				local revision, hides = replace(world, change)
				Fixture.list_local_models(world, { world.flow.config().default_models["local"] })
				helpers.assert_eq(#world.local_posts, 0)
				preserved(world, revision, hides)
			end)
		end)
	end

	helpers.it("posts a current local image after the actual model listing", function()
		with_world(function(world)
			capture(world, "local")
			helpers.assert_eq(#world.local_posts, 0)
			Fixture.list_local_models(world, { world.flow.config().default_models["local"] })
			helpers.assert_eq(#world.local_posts, 1)
		end)
	end)

	helpers.it("does not lend a new revision after the prompt-language read", function()
		with_world(function(world)
			capture(world)
			world.keys[1](true, "vision-key")
			local profiles = require("modules.llm.profiles")
			local language = profiles.prompt_language
			profiles.prompt_language = function()
				helpers.assert_not_nil(world.engine.open_answer_surface("successor during language read"))
				return language()
			end
			answer(world.vision_posts[1], "SCREEN: private old transcript")
			helpers.assert_eq(#world.text_posts, 0)
			helpers.assert_eq(#world.notices, 0)
		end)
	end)

	for _, change in ipairs({ "reset", "replacement" }) do
		helpers.it("does not post private text after " .. change .. " during its Keychain", function()
			with_world(function(world)
				capture(world)
				world.keys[1](true, "vision-key")
				answer(world.vision_posts[1], "SCREEN: private transcript")
				helpers.assert_eq(#world.keys, 2)
				local revision, hides = replace(world, change)
				world.keys[2](true, "text-key")
				helpers.assert_eq(#world.text_posts, 0)
				preserved(world, revision, hides)
			end, "keychain:pending-text")
		end)
	end
	for _, change in ipairs({ "current", "screen reset" }) do
		helpers.it("retains text credential continuation for " .. change, function()
			with_world(function(world)
				capture(world)
				world.keys[1](true, "vision-key")
				answer(world.vision_posts[1], "SCREEN: private transcript")
				helpers.assert_eq(#world.keys, 2)
				if change == "screen reset" then world.flow.reset() end
				world.keys[2](true, "text-key")
				helpers.assert_eq(#world.text_posts, change == "current" and 1 or 0)
				helpers.assert_eq(#world.notices, 0)
			end, "keychain:pending-text")
		end)
	end

	for _, verdict in ipairs({ "false", "truthy", "raised", "legacy" }) do
		helpers.it("requires strict optional local continuation for " .. verdict, function()
			with_world(function(world)
				local failures, errors = {}, {}
				require("infra.logger").error = function(_, format, ...)
					errors[#errors + 1] = string.format(format, ...)
				end
				local guard
				if verdict ~= "legacy" then
					guard = function()
						if verdict == "raised" then error("producer retired") end
						if verdict == "truthy" then return 1 end
						return false
					end
				end
				local model = world.flow.config().default_models["local"]
				require("modules.llm.api_ollama").request_vision({ model = model, messages = {} },
					function() error("no reply has been received") end,
					function(reason) failures[#failures + 1] = reason end, guard)
				Fixture.list_local_models(world, { model })
				helpers.assert_eq(#world.local_posts, verdict == "legacy" and 1 or 0)
				helpers.assert_eq(#failures, verdict == "legacy" and 0 or 1)
				if verdict ~= "legacy" then helpers.assert_eq(failures[1], "cancelled") end
				helpers.assert_eq(#errors, verdict == "raised" and 1 or 0)
				if verdict == "raised" then
					helpers.assert_true(errors[1]:find("producer retired", 1, true) ~= nil)
				end
			end)
		end)
	end

end)
