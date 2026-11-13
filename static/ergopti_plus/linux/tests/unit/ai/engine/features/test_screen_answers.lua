--- tests/unit/ai/engine/features/test_screen_answers.lua

--- ==============================================================================
--- MODULE: Answers To What Is On The Screen (Linux)
--- DESCRIPTION:
--- llm_screen_region / llm_screen_full capture the screen to a private file, a
--- vision model transcribes it, and the AI menu's text backend drafts the three
--- answers of vision.json, offered in the prediction tooltip. Accepting one
--- types it at the caret. llm_screen_error runs the same region flow with the
--- error_answers instead: the cause, then the fix.
---
--- The real engine, vision helpers, request builder, remote client, profile
--- registry and settings run; only the boundaries are scripted: the capture
--- (a real temporary file), the HTTP transport, the preferences file, the
--- clock, the tooltip and the typing.
---
--- ROOT CAUSE ENCODED:
--- No request could carry an image, so nothing on the screen could be answered:
--- the user had to retype a message before any prediction could reply to it.
--- The first screen action to watsonx or Vertex AI was refused while its
--- access token was fetched: its endpoint was resolved synchronously.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fakes = require("tests.fakes")
local Json = require("core.text.engine.json")
local Base64 = require("core.lifecycle.engine.compat.base64")
local Vision = require("ai.engine.prediction.vision")
local PreferencesFixture = require("tests.support.ai.preferences_fixture")

-- The bytes the fake capture writes: a PNG signature and a body
local IMAGE = "\137PNG\r\n\26\nfake screen pixels"

local SCREEN = "Salut, on se voit demain à 14h ?"

-- The menu's text backend: a Cerebras entry, active. The OpenAI entry only
-- holds the key the vision binding uses.
local CEREBRAS = { id = "cerebras-1", provider = "cerebras", label = "Cerebras", token = "ck", model = "", base_url = "" }
local OPENAI = { id = "openai-1", provider = "openai", label = "OpenAI", token = "ok-key", model = "", base_url = "" }
local GEMINI = { id = "gemini-1", provider = "gemini", label = "Gemini", token = "gk", model = "", base_url = "" }
-- A provider exchanging its key for an access token (api_providers.json auth)
local WATSONX = { id = "watsonx-1", provider = "watsonx", label = "watsonx", token = "ibm-api-key", model = "",
	base_url = "https://us-south.ml.cloud.ibm.com/ml/gateway/v1" }

local RELOADED = {
	"ai.engine.prediction.engine", "ai.engine.settings.settings", "ai.engine.settings.profile_settings",
	"ai.engine.settings.display_settings", "ai.engine.settings.trigger_settings", "ai.engine.settings.navigation_settings",
	"ai.engine.api.api_remote", "ai.engine.prediction.vision_request", "ai.engine.ollama.local_model_probe", "ai.engine.ollama.local_model_offer",
}
local FAKED = {
	"platform.focus.secure_field_detector", "core.network.adapters.http_client", "ai.engine.settings.api_entries",
	"ai.engine.settings.profiles", "ai.engine.api.api_ollama",
}

local BASE_PREFERENCES = {
	["llm.models.selected"] = "api",
	["llm.profiles.active"] = "basic",
	["llm.profiles.auto_profile_for_model"] = false,
}





-- ==========================
-- ==========================
-- ======= 1/ Harness =======
-- ==========================
-- ==========================

--- @param path string
--- @return boolean
local function exists(path)
	local handle = io.open(path, "rb")
	if handle then handle:close() end
	return handle ~= nil
end

--- Runs body against the real engine with scripted boundaries.
--- @param opts table { stored?, entries?, disabled?, paused? }
--- @param body function Receives the scenario's world.
local function scenario(opts, body)
	local stored = {}
	for key, value in pairs(BASE_PREFERENCES) do stored[key] = value end
	for key, value in pairs(opts.stored or {}) do stored[key] = value end
	PreferencesFixture.with(function()
		local previous = {}
		for _, name in ipairs(RELOADED) do previous[name] = package.loaded[name]; package.loaded[name] = nil end
		for _, name in ipairs(FAKED) do previous[name] = package.loaded[name] end
		local world = { posts = {}, probes = {}, model_offers = {}, model_installs = {}, ollama = {}, notices = {}, captures = {}, shown = nil, typed = {},
			cancelled_owners = {} }
		local entries = opts.entries or { CEREBRAS, OPENAI }
		package.loaded["platform.focus.secure_field_detector"] = {
			isSecureField = function() return false end,
			isSecureApp = function() return false end,
			isUrlBar = function() return false end,
		}
		package.loaded["core.network.adapters.http_client"] = {
			get = function(url, headers, options, callback)
				world.probes[#world.probes + 1] = { url = url, owner = options.owner, callback = callback }
				return true
			end,
			post = function(url, headers, request_body, callback, options)
				world.posts[#world.posts + 1] = { url = url, headers = headers, body = Json.decode(request_body),
					callback = callback, owner = type(options) == "table" and options.owner or nil }
				return true
			end,
			cancel = function(owner)
				world.cancelled_owners[#world.cancelled_owners + 1] = owner
				return true
			end,
		}
		package.loaded["ai.engine.settings.api_entries"] = {
			active = function() return entries[1] end,
			list = function() return entries end,
		}
		package.loaded["ai.engine.settings.profiles"] = {
			init = function() end,
			is_enabled = function() return opts.disabled ~= true end,
			get_current_model = function() return "ollama-model" end,
			get_base_url = function() return "http://127.0.0.1:11434" end,
		}
		package.loaded["ai.engine.api.api_ollama"] = {
			chat = function(_, model, messages, request_opts, _, on_done)
				world.ollama[#world.ollama + 1] = { model = model, messages = messages, opts = request_opts,
					on_done = on_done }
			end,
			cancel = function() return true end,
		}

		require("ai.engine.ollama.local_model_offer")._reset_for_test({
			confirm = function(title, text)
				world.model_offers[#world.model_offers + 1] = { title = title, text = text }
				return opts.download_choice == true
			end,
			install = function(base_url, model)
				world.model_installs[#world.model_installs + 1] = { base_url = base_url, model = model }
				return true
			end,
			notify = function(text) world.notices[#world.notices + 1] = text; return true end,
		})
		local scheduler = Fakes.timer_scheduler()
		local engine = require("ai.engine.prediction.engine")
		engine.init({ focus_id = function() return "owned-screen-target" end,
			scheduler = scheduler,
			clock_ms = function() return scheduler.now * 1000 end,
			engine = { current_buffer = function() return "" end, reset = function() end },
			is_paused = function() return opts.paused == true end,
			notify = function(text) world.notices[#world.notices + 1] = text; return true end,
			overlay = {
				show = function(candidates, meta)
					world.shown = { candidates = candidates, meta = meta }
					return true
				end,
				hide = function() world.shown = nil; return true end,
				is_showing = function() return world.shown ~= nil and #world.shown.candidates > 0 end,
			},
			apply_prediction = function(candidate)
				world.typed[#world.typed + 1] = { deletes = candidate.deletes, text = candidate.to_type }
				return true
			end,
			-- The capture writes a real file in a real private directory, and
			-- finishes when the scenario says so.
			capture_screen = function(mode, max_edge, on_done)
				local pipe = io.popen("mktemp -d")
				local dir = pipe:read("*l")
				pipe:close()
				local capture = { mode = mode, max_edge = max_edge, on_done = on_done, dir = dir,
					path = dir .. "/screen.png", cancelled = false }
				local handle = io.open(capture.path, "wb")
				handle:write(IMAGE)
				handle:close()
				world.captures[#world.captures + 1] = capture
				capture.settle = function() os.remove(capture.path); os.remove(capture.dir) end
				local handle = { path = capture.path, dir = capture.dir, cancel = function() capture.cancelled = true end,
					discard = function() capture.settle(); return true end }
				if opts.delayed_capture_cleanup then
					handle.discard = function() capture.cleanup_registered = true; return true end
				elseif opts.malformed_capture then
					handle.discard = nil
				end
				return handle
			end,
		})
		world.engine = engine
		world.handlers = engine.action_handlers()
		world.config = Json.decode(assert(io.open(helpers.driver_root()
			.. "/../_shared/ai/data/vision.json", "r")):read("*a"))

		--- The remote server answers request `index` with an OpenAI-shaped `text`.
		function world.respond(index, text)
			local post = assert(world.posts[index], "no request " .. index .. " was sent")
			post.callback({ ok = true, status = 200,
				body = Json.encode({ choices = { { message = { role = "assistant", content = text } } } }) })
		end

		--- Lets the pacing timer run until request `index` is sent, or long past it.
		function world.wait_for(index)
			for _ = 1, 20 do
				if world.posts[index] or world.ollama[index] then return end
				scheduler.test.advance(0.5)
			end
		end

		local ok, err = pcall(body, world)
		engine.dismiss()
		for _, capture in ipairs(world.captures) do
			os.remove(capture.path)
			os.remove(capture.dir)
		end
		for _, name in ipairs(RELOADED) do package.loaded[name] = previous[name] end
		for _, name in ipairs(FAKED) do package.loaded[name] = previous[name] end
		if not ok then error(err, 0) end
	end, { initial = stored })
end

helpers.it("vision configuration refuses a FIFO rather than blocking", function()
	local uv = require("luv")
	local Paths = require("core.fs.engine.paths")
	local original_shared, original_request = Paths.shared, package.loaded["ai.engine.prediction.vision_request"]
	local source = assert(original_shared("ai/data/vision.json"))
	local dir = assert(uv.fs_mkdtemp((os.getenv("TMPDIR") or "/tmp") .. "/ergopti-vision-XXXXXX"))
	local path = dir .. "/vision.json"
	local made = os.execute("mkfifo '" .. path .. "'")
	assert(made == 0 or made == true)
	package.loaded["ai.engine.prediction.vision_request"] = nil
	local Request = require("ai.engine.prediction.vision_request")
	Paths.shared = function(relative)
		if relative == "ai/data/vision.json" then return path end
		return original_shared(relative)
	end
	local exited, process = false, nil
	process = assert(uv.spawn("sh", { args = { "-c", 'sleep 1; cat "$2" > "$1"', "fixture", path, source } }, function()
		exited = true
		process:close()
	end))
	local ok, config = pcall(Request.config)
	Paths.shared, package.loaded["ai.engine.prediction.vision_request"] = original_shared, original_request
	os.remove(path)
	os.remove(dir)
	while not exited do uv.run("once") end
	assert(ok, config)
	helpers.assert_nil(config, "a FIFO must not supply the vision configuration")
end)

helpers.describe("screen answers: missing local model admission", function()
	helpers.it("offers the absent vision model before transmitting the screenshot", function()
		scenario({ download_choice = true }, function(world)
			helpers.assert_true(world.handlers.llm_screen_region("tap_3", "local"))
			local capture = world.captures[1]
			capture.on_done({ status = "ok", scaled = true })
			helpers.assert_eq(#world.posts, 0)
			helpers.assert_eq(#world.probes, 1)
			world.probes[1].callback({ ok = true, status = 200, body = '{"models":[]}' })
			helpers.assert_eq(#world.posts, 0)
			helpers.assert_eq(#world.model_offers, 1)
			helpers.assert_eq(#world.model_installs, 1)
			helpers.assert_eq(world.model_installs[1].model, world.config.default_models["local"])
			helpers.assert_eq(exists(capture.path), false, "the private capture remains deleted")
			helpers.assert_eq(exists(capture.dir), false)
			helpers.assert_eq(#world.typed, 0)
		end)
	end)

	helpers.it("a withdrawn vision preflight cannot offer its missing model", function()
		scenario({ download_choice = true }, function(world)
			helpers.assert_true(world.handlers.llm_screen_region("tap_3", "local"))
			world.captures[1].on_done({ status = "ok", scaled = true })
			local probe = world.probes[1]
			world.engine.withdraw()
			local cancelled = false
			for _, owner in ipairs(world.cancelled_owners) do cancelled = cancelled or owner == "llm_vision" end
			helpers.assert_true(cancelled, "Escape withdraws the actual vision HTTP owner")
			probe.callback({ ok = true, status = 200, body = '{"models":[]}' })
			helpers.assert_eq(#world.posts, 0)
			helpers.assert_eq(#world.model_offers, 0)
			helpers.assert_eq(#world.model_installs, 0)
		end)
	end)
end)

helpers.describe("screen answers: native preflight refusal ownership", function()
	helpers.it("a refused cancellation cannot replace the existing vision request or its model", function()
		local names = { "core.network.adapters.http_client", "ai.engine.ollama.local_model_probe", "ai.engine.prediction.vision_request" }
		local previous = {}
		for _, name in ipairs(names) do previous[name] = package.loaded[name]; package.loaded[name] = nil end
		local probes, posts, refused = {}, {}, true
		package.loaded["core.network.adapters.http_client"] = {
			get = function(url, _, options, callback)
				probes[#probes + 1] = { url = url, owner = options.owner, callback = callback }
				return true
			end,
			post = function(_, _, encoded, callback)
				posts[#posts + 1] = { body = Json.decode(encoded), callback = callback }
				return true
			end,
			cancel = function() return not refused end,
		}
		local ok, err = xpcall(function()
			local Request = require("ai.engine.prediction.vision_request")
			local target = { base_url = "http://127.0.0.1:11434", format = "ollama",
				url = "http://127.0.0.1:11434/api/chat", headers = {} }
			local completed, displaced = {}, 0
			helpers.assert_true(Request.send(target, { model = "first" },
				function(text, failure) completed[#completed + 1] = { text = text, failure = failure } end))
			helpers.assert_eq(Request.cancel(), false)
			helpers.assert_eq(Request.send(target, { model = "second" }, function() displaced = displaced + 1 end), false)
			helpers.assert_eq(#probes, 1, "refusal preserves the existing native lease")
			helpers.assert_eq(probes[1].owner, "llm_vision")
			probes[1].callback({ ok = true, status = 200, body = '{"models":[{"name":"first"}]}' })
			helpers.assert_eq(#posts, 1)
			helpers.assert_eq(posts[1].body.model, "first")
			posts[1].callback({ ok = true, status = 200, body = '{"message":{"content":"original answer"}}' })
			helpers.assert_eq(#completed, 1)
			helpers.assert_eq(completed[1].text, "original answer")
			helpers.assert_nil(completed[1].failure)
			helpers.assert_eq(displaced, 0)
			refused = false
			helpers.assert_true(Request.cancel())
		end, debug.traceback)
		for _, name in ipairs(names) do package.loaded[name] = previous[name] end
		if not ok then error(err, 0) end
	end)
end)

--- Compares two decoded JSON values structurally.
--- @return boolean equal, string|nil where
local function deep_equal(a, b, where)
	where = where or "$"
	if type(a) ~= type(b) then return false, where .. ": " .. type(a) .. " vs " .. type(b) end
	if type(a) ~= "table" then return a == b, a == b and nil or (where .. ": " .. tostring(a) .. " vs " .. tostring(b)) end
	for k, v in pairs(a) do
		local ok, why = deep_equal(v, b[k], where .. "." .. tostring(k))
		if not ok then return false, why end
	end
	for k in pairs(b) do
		if a[k] == nil then return false, where .. "." .. tostring(k) .. " is missing" end
	end
	return true
end

--- The locale string the prompts receive for {language}.
--- @return string
local function language()
	return require("core.i18n.engine.i18n").get_locale()
end

--- @param key string
--- @return string
local function notice(key)
	return require("core.i18n.engine.i18n").get(key)
end

--- The candidate texts on offer.
--- @param world table
--- @return table
local function offered(world)
	local texts = {}
	for index, candidate in ipairs(world.engine.get_suggestions()) do texts[index] = candidate.to_type end
	return texts
end





-- ==============================================
-- ==============================================
-- ======= 2/ The flow, end to end ==============
-- ==============================================
-- ==============================================

helpers.describe("screen actions: a region read by an API model, answered by the menu's backend", function()

	helpers.it("registers both screen actions", function()
		scenario({}, function(world)
			helpers.assert_eq(type(world.handlers.llm_screen_region), "function")
			helpers.assert_eq(type(world.handlers.llm_screen_full), "function")
		end)
	end)

	helpers.it("refuses a FIFO screenshot without sending its contents", function()
		scenario({}, function(world)
			local uv = require("luv")
			helpers.assert_true(world.handlers.llm_screen_region("tap_3", "openai|gpt-4.1-mini"))
			local capture = world.captures[1]
			assert(os.remove(capture.path))
			local made = os.execute("mkfifo '" .. capture.path .. "'")
			assert(made == 0 or made == true)
			-- Release a blocking reader so the regression fails rather than hanging.
			local exited, process = false, nil
			process = assert(uv.spawn("sh", { args = { "-c", 'sleep 1; printf x > "$1"', "fixture", capture.path } }, function()
				exited = true
				process:close()
			end))
			capture.on_done({ status = "ok", scaled = true })
			while not exited do uv.run("once") end
			helpers.assert_eq(#world.posts, 0, "special files must not be sent as screenshots")
			helpers.assert_eq(uv.fs_lstat(capture.path), nil)
			helpers.assert_eq(uv.fs_lstat(capture.dir), nil)
		end)
	end)

	helpers.it("does not block checking an undeletable FIFO screenshot", function()
		scenario({}, function(world)
			local uv = require("luv")
			helpers.assert_true(world.handlers.llm_screen_region("tap_3", "openai|gpt-4.1-mini"))
			local capture = world.captures[1]
			assert(os.remove(capture.path))
			local made = os.execute("mkfifo '" .. capture.path .. "'")
			assert(made == 0 or made == true)
			local exited, exit_code, process = false, nil, nil
			process = assert(uv.spawn("sh", { args = { "-c", 'sleep 1; printf x > "$1"', "fixture", capture.path } }, function(code)
				exit_code, exited = code, true
				process:close()
			end))
			local remove = os.remove
			os.remove = function(path)
				if path == capture.path then return nil, "injected deletion failure" end
				return remove(path)
			end
			local ok, err = pcall(capture.on_done, { status = "ok", scaled = true })
			os.remove = remove
			remove(capture.path)
			remove(capture.dir)
			while not exited do uv.run("once") end
			assert(ok, err)
			helpers.assert_true(exit_code ~= 0, "cleanup opened the FIFO and consumed the writer")
			helpers.assert_eq(#world.posts, 0)
		end)
	end)

	helpers.it("captures, reads, drafts three answers in order, and types the accepted one", function()
		scenario({}, function(world)
			helpers.assert_eq(world.handlers.llm_screen_region("tap_3", "openai|gpt-4.1-mini"), true)
			helpers.assert_eq(#world.captures, 1, "one capture")
			local capture = world.captures[1]
			helpers.assert_eq(capture.mode, "region")
			helpers.assert_eq(capture.max_edge, world.config.max_image_edge, "downscaled to vision.json's edge")
			helpers.assert_eq(#world.posts, 0, "nothing is sent before the capture finished")

			capture.on_done({ status = "ok", scaled = true })
			helpers.assert_eq(exists(capture.path), false, "the screenshot is deleted once read")
			helpers.assert_eq(exists(capture.dir), false, "and its private directory")
			helpers.assert_eq(#world.posts, 1, "one vision request")
			local vision = world.posts[1]
			helpers.assert_eq(vision.url, "https://api.openai.com/v1/chat/completions")
			helpers.assert_eq(vision.headers.Authorization, "Bearer ok-key", "the OpenAI entry's own key")
			helpers.assert_eq(vision.owner, "llm_vision", "its own transport owner")
			local expected = Vision.build_request("openai", {
				model = "gpt-4.1-mini",
				system = world.config.read_prompt,
				text = Vision.READ_USER_TEXT,
				image = Base64.encode(IMAGE),
				mime = world.config.image_mime,
				max_tokens = world.config.read_max_tokens,
			})
			local same, where = deep_equal(vision.body, expected)
			helpers.assert_true(same, "the body is vision.build_request's: " .. tostring(where))
			helpers.assert_eq(world.shown and world.shown.meta.loading, true, "the tooltip says it is working")

			world.respond(1, "SCREEN: " .. SCREEN)
			for index, answer in ipairs(world.config.answers) do
				world.wait_for(index + 1)
				local post = assert(world.posts[index + 1], "answer request " .. index)
				helpers.assert_eq(post.url, "https://api.cerebras.ai/v1/chat/completions", "the menu's backend")
				helpers.assert_eq(post.body.messages[1].content, Vision.fill_language(answer.prompt, language()),
					answer.id .. ": its own prompt, language filled in")
				helpers.assert_eq(post.body.messages[2].content, "SCREEN:\n" .. SCREEN, answer.id .. ": the screen")
				helpers.assert_eq(post.body.max_tokens, world.config.answer_max_tokens)
				helpers.assert_eq(post.body.stream, false)
				world.respond(index + 1, "ANSWER: answer " .. index .. "\nsecond line")
			end
			helpers.assert_eq(table.concat(offered(world), "|"),
				"answer 1\nsecond line|answer 2\nsecond line|answer 3\nsecond line", "three candidates, in order")
			helpers.assert_eq(world.shown.meta.loading, false)
			helpers.assert_eq(#world.typed, 0, "nothing is typed before acceptance")
			helpers.assert_eq(#world.notices, 0)

			helpers.assert_eq(world.engine.handle_shortcut({ key = "1", mods = {} }), true, "1 accepts")
			helpers.assert_eq(#world.typed, 1)
			helpers.assert_eq(world.typed[1].deletes, 0, "nothing is erased")
			helpers.assert_eq(world.typed[1].text, "answer 1\nsecond line", "the first answer is typed")
		end)
	end)

	helpers.it("keeps operators in screen transcription and generated fixes", function()
		scenario({}, function(world)
			world.handlers.llm_screen_full("tap_3", "openai")
			world.captures[1].on_done({ status = "ok", scaled = false })
			world.respond(1, "**SCREEN:** result = x**2")
			world.wait_for(2)
			helpers.assert_eq(world.posts[2].body.messages[2].content, "SCREEN:\nresult = x**2")
			world.respond(2, "ANSWER: result = x**2")
			world.wait_for(3); world.respond(3, "ANSWER: second")
			world.wait_for(4); world.respond(4, "ANSWER: third")
			helpers.assert_eq(offered(world)[1], "result = x**2")
			helpers.assert_true(world.engine.handle_shortcut({ key = "1", mods = {} }))
			helpers.assert_eq(world.typed[1].text, "result = x**2")
		end)
	end)

	helpers.it("keeps the order when one answer fails and offers the others", function()
		scenario({}, function(world)
			world.handlers.llm_screen_full("tap_3", "openai")
			helpers.assert_eq(world.captures[1].mode, "full")
			world.captures[1].on_done({ status = "ok", scaled = false })
			helpers.assert_eq(world.posts[1].body.model, world.config.default_models.openai, "the default model")
			world.respond(1, "SCREEN: " .. SCREEN)
			world.wait_for(2); world.respond(2, "ANSWER: first")
			world.wait_for(3); world.respond(3, "no tag at all")
			world.wait_for(4); world.respond(4, "ANSWER: third")
			helpers.assert_eq(table.concat(offered(world), "|"), "first|third")
			helpers.assert_eq(#world.notices, 0)
		end)
	end)

	helpers.it("reads locally through Ollama's /api/chat with the image, and answers through Ollama", function()
		scenario({ stored = { ["llm.models.selected"] = "ollama" } }, function(world)
			helpers.assert_eq(world.handlers.llm_screen_region("tap_3", "local"), true)
			world.captures[1].on_done({ status = "ok", scaled = true })
			helpers.assert_eq(#world.posts, 0, "the local model must be acknowledged first")
			helpers.assert_eq(#world.probes, 1)
			helpers.assert_eq(world.probes[1].owner, "llm_vision")
			world.probes[1].callback({ ok = true, status = 200,
				body = Json.encode({ models = { { name = world.config.default_models["local"] } } }) })
			local vision = world.posts[1]
			helpers.assert_eq(vision.url, "http://127.0.0.1:11434/api/chat")
			helpers.assert_eq(vision.body.model, world.config.default_models["local"])
			helpers.assert_eq(vision.body.messages[2].images[1], Base64.encode(IMAGE), "the image rides along")
			helpers.assert_eq(vision.body.stream, false)
			vision.callback({ ok = true, status = 200,
				body = Json.encode({ message = { role = "assistant", content = "<think>hm</think>SCREEN: " .. SCREEN } }) })
			for index = 1, 3 do
				world.wait_for(index)
				local request = assert(world.ollama[index], "Ollama answer " .. index)
				helpers.assert_eq(request.opts.stream, false)
				helpers.assert_eq(request.opts.line_mode, false, "multi-line answers are not cut")
				helpers.assert_eq(request.messages[2].content, "SCREEN:\n" .. SCREEN)
				request.on_done("**ANSWER:** local " .. index, nil)
			end
			helpers.assert_eq(table.concat(offered(world), "|"), "local 1|local 2|local 3")
		end)
	end)

	helpers.it("sends a Gemini vision request with the key in the URL", function()
		scenario({ entries = { CEREBRAS, GEMINI } }, function(world)
			helpers.assert_eq(world.handlers.llm_screen_full("tap_3", "gemini"), true)
			world.captures[1].on_done({ status = "ok", scaled = true })
			helpers.assert_eq(world.posts[1].url, "https://generativelanguage.googleapis.com/v1beta/models/"
				.. world.config.default_models.gemini .. ":generateContent?key=gk")
			helpers.assert_eq(world.posts[1].body.contents[1].parts[1].inline_data.data, Base64.encode(IMAGE))
		end)
	end)
end)





-- ==============================================
-- ==============================================
-- ======= 3/ Refusals and failures =============
-- ==============================================
-- ==============================================

helpers.describe("screen actions: a provider exchanging its key waits for its token (access-token-lease)", function()
	--- Answers the token exchange, request `index`, with an access token.
	local function grant(world, index)
		local post = assert(world.posts[index], "no exchange was sent")
		post.callback({ ok = true, status = 200, body = Json.encode({ access_token = "iam-token", expires_in = 3600 }) })
	end

	helpers.it("the first screen action waits for the token, then captures and sends it as Bearer", function()
		scenario({ entries = { CEREBRAS, WATSONX } }, function(world)
			helpers.assert_eq(world.handlers.llm_screen_region("tap_3", "watsonx|ibm/granite-vision-3-3-2b"), true)
			helpers.assert_eq(#world.captures, 0, "no capture before the address is known")
			helpers.assert_eq(#world.notices, 0, "not refused while the token is fetched")
			helpers.assert_eq(world.posts[1].url, "https://iam.cloud.ibm.com/identity/token")
			grant(world, 1)
			helpers.assert_eq(#world.captures, 1, "the capture starts once the token arrived")
			world.captures[1].on_done({ status = "ok", scaled = true })
			helpers.assert_eq(world.posts[2].url, WATSONX.base_url .. "/chat/completions")
			helpers.assert_eq(world.posts[2].headers.Authorization, "Bearer iam-token", "the token, never the key")
		end)
	end)

	helpers.it("a refused exchange is told and captures nothing", function()
		scenario({ entries = { CEREBRAS, WATSONX } }, function(world)
			helpers.assert_eq(world.handlers.llm_screen_full("tap_3", "watsonx|ibm/granite-vision-3-3-2b"), true)
			world.posts[1].callback({ ok = false, status = 400, body = "",
				error_body = Json.encode({ errorMessage = "Provided API key could not be found" }) })
			helpers.assert_eq(world.notices[1], notice("llm.manual_prediction.backend_not_ready"))
			helpers.assert_eq(#world.captures, 0)
			helpers.assert_eq(#world.posts, 1, "no vision request")
		end)
	end)

	helpers.it("a screen action dropped while it waits never captures when the token arrives", function()
		scenario({ entries = { CEREBRAS, WATSONX } }, function(world)
			helpers.assert_eq(world.handlers.llm_screen_region("tap_3", "watsonx|ibm/granite-vision-3-3-2b"), true)
			world.engine.drop_vision("typing")
			grant(world, 1)
			helpers.assert_eq(#world.captures, 0)
			helpers.assert_eq(#world.notices, 0)
		end)
	end)

	helpers.it("with a fresh token the next screen action captures at once", function()
		scenario({ entries = { CEREBRAS, WATSONX } }, function(world)
			world.handlers.llm_screen_region("tap_3", "watsonx|ibm/granite-vision-3-3-2b")
			grant(world, 1)
			world.captures[1].on_done({ status = "cancelled", scaled = false })
			helpers.assert_eq(world.handlers.llm_screen_region("tap_3", "watsonx|ibm/granite-vision-3-3-2b"), true)
			helpers.assert_eq(#world.captures, 2, "no second wait")
			helpers.assert_eq(#world.posts, 1, "no second exchange")
		end)
	end)
end)

helpers.describe("screen actions: refusals, cancellations and failures", function()

	helpers.it("a cancelled region sends nothing and says nothing", function()
		scenario({}, function(world)
			world.handlers.llm_screen_region("tap_3", "openai")
			local capture = world.captures[1]
			capture.on_done({ status = "cancelled", scaled = false })
			helpers.assert_eq(#world.posts, 0, "no request")
			helpers.assert_eq(#world.notices, 0, "no notice")
			helpers.assert_eq(exists(capture.dir), false, "the private directory is gone")
		end)
	end)

	helpers.it("a failed capture is told", function()
		scenario({}, function(world)
			world.handlers.llm_screen_full("tap_3", "openai")
			world.captures[1].on_done({ status = "failed", scaled = false, reason = "no tool" })
			helpers.assert_eq(world.notices[1], notice("llm.vision.capture_failed"))
			helpers.assert_eq(#world.posts, 0)
			helpers.assert_eq(exists(world.captures[1].dir), false)
		end)
	end)

	helpers.it("a backend without a default model is refused before any capture", function()
		scenario({}, function(world)
			helpers.assert_eq(world.handlers.llm_screen_region("tap_3", "cerebras"), false)
			helpers.assert_eq(world.notices[1], notice("llm.vision.no_model"))
			helpers.assert_eq(#world.captures, 0, "no capture")
		end)
	end)

	helpers.it("a provider without a stored key is refused before any capture", function()
		scenario({}, function(world)
			helpers.assert_eq(world.handlers.llm_screen_region("tap_3", "anthropic"), false)
			helpers.assert_eq(world.notices[1], notice("llm.manual_prediction.backend_not_ready"))
			helpers.assert_eq(#world.captures, 0)
			helpers.assert_eq(world.handlers.llm_screen_region("tap_3", "nosuchprovider|m"), false)
			helpers.assert_eq(#world.captures, 0, "an unknown provider is refused too")
		end)
	end)

	helpers.it("refuses like the manual prediction while the AI is off, without capturing", function()
		scenario({ disabled = true }, function(world)
			helpers.assert_eq(world.handlers.llm_screen_region("tap_3", "openai"), false)
			helpers.assert_eq(world.notices[1], notice("llm.manual_prediction.disabled"))
			helpers.assert_eq(#world.captures, 0)
		end)
	end)

	helpers.it("refuses while paused, without capturing", function()
		scenario({ paused = true }, function(world)
			helpers.assert_eq(world.handlers.llm_screen_full("tap_3", "openai"), false)
			helpers.assert_eq(world.notices[1], notice("llm.manual_prediction.paused"))
			helpers.assert_eq(#world.captures, 0)
		end)
	end)

	helpers.it("a failed vision request is told, and the screenshot is still deleted", function()
		scenario({}, function(world)
			world.handlers.llm_screen_region("tap_3", "openai")
			world.captures[1].on_done({ status = "ok", scaled = true })
			world.posts[1].callback({ ok = false, status = 401, error_body = '{"error":{"message":"bad key"}}',
				error = "HTTP 401" })
			helpers.assert_eq(world.notices[1], notice("llm.vision.read_failed"))
			helpers.assert_eq(#world.posts, 1, "no answer is requested")
			helpers.assert_eq(exists(world.captures[1].path), false)
			helpers.assert_eq(world.shown, nil, "the working tooltip is gone")
		end)
	end)

	helpers.it("an answer without a SCREEN block is a failed reading", function()
		scenario({}, function(world)
			world.handlers.llm_screen_region("tap_3", "openai")
			world.captures[1].on_done({ status = "ok", scaled = true })
			world.respond(1, "I cannot see anything.")
			helpers.assert_eq(world.notices[1], notice("llm.vision.read_failed"))
			helpers.assert_eq(#world.posts, 1)
		end)
	end)

	helpers.it("three failed answers are a failed reading", function()
		scenario({}, function(world)
			world.handlers.llm_screen_region("tap_3", "openai")
			world.captures[1].on_done({ status = "ok", scaled = true })
			world.respond(1, "SCREEN: " .. SCREEN)
			for index = 2, 4 do
				world.wait_for(index)
				world.respond(index, "nothing")
			end
			helpers.assert_eq(#world.engine.get_suggestions(), 0)
			helpers.assert_eq(world.notices[1], notice("llm.vision.read_failed"))
		end)
	end)
end)





-- ==============================================
-- ==============================================
-- ======= 4/ One flow at a time ================
-- ==============================================
-- ==============================================

helpers.describe("screen capture cleanup ownership", function()
	helpers.it("refuses a capture without an explicit cleanup owner", function()
		scenario({ malformed_capture = true }, function(world)
			helpers.assert_eq(world.handlers.llm_screen_full("tap_3", "openai"), false)
			local capture = world.captures[1]
			helpers.assert_true(capture.cancelled)
			helpers.assert_true(exists(capture.path), "unproven capture cannot be deleted before retirement")
			helpers.assert_eq(#world.posts, 0)
			capture.settle()
		end)
	end)

	helpers.it("keeps a cancelled image until its capture owner settles", function()
		scenario({ delayed_capture_cleanup = true }, function(world)
			world.handlers.llm_screen_full("tap_3", "openai")
			local capture = world.captures[1]
			world.engine.drop_vision("typing")
			helpers.assert_true(capture.cancelled and capture.cleanup_registered)
			helpers.assert_true(exists(capture.path), "the engine cannot race the child by deleting early")
			capture.settle()
			helpers.assert_eq(exists(capture.dir), false)
		end)
	end)
end)

helpers.describe("screen actions: a newer action supersedes the previous one", function()

	helpers.it("drops a superseded capture and deletes it at once", function()
		scenario({}, function(world)
			world.handlers.llm_screen_region("tap_3", "openai")
			world.handlers.llm_screen_full("tap_3", "openai")
			local first, second = world.captures[1], world.captures[2]
			helpers.assert_eq(first.cancelled, true, "the first tool is stopped")
			helpers.assert_eq(exists(first.dir), false, "and its file deleted")
			first.on_done({ status = "ok", scaled = true })
			helpers.assert_eq(#world.posts, 0, "the stale capture is not sent")
			second.on_done({ status = "ok", scaled = true })
			helpers.assert_eq(#world.posts, 1, "the newer one is")
		end)
	end)

	helpers.it("ignores a superseded transcription and superseded answers", function()
		scenario({}, function(world)
			world.handlers.llm_screen_region("tap_3", "openai")
			world.captures[1].on_done({ status = "ok", scaled = true })
			world.respond(1, "SCREEN: first screen")
			world.wait_for(2)
			helpers.assert_eq(#world.posts, 2, "the first flow asks its first answer")
			world.handlers.llm_screen_full("tap_3", "openai")
			world.respond(2, "ANSWER: stale")
			helpers.assert_eq(#world.engine.get_suggestions(), 0, "the stale answer is dropped")
			world.captures[2].on_done({ status = "ok", scaled = true })
			helpers.assert_eq(world.posts[3].owner, "llm_vision", "the newer flow reads its own capture")
			world.respond(3, "SCREEN: second screen")
			world.wait_for(4)
			helpers.assert_eq(world.posts[4].body.messages[2].content, "SCREEN:\nsecond screen")
		end)
	end)

	helpers.it("typing drops the reading in flight", function()
		scenario({}, function(world)
			world.handlers.llm_screen_region("tap_3", "openai")
			world.captures[1].on_done({ status = "ok", scaled = true })
			world.engine.on_char("x", "x", {})
			local withdrawn = false
			for _, owner in ipairs(world.cancelled_owners) do withdrawn = withdrawn or owner == "llm_vision" end
			helpers.assert_true(withdrawn, "the vision request is withdrawn")
			world.respond(1, "SCREEN: " .. SCREEN)
			helpers.assert_eq(#world.posts, 1, "no answer is requested")
			helpers.assert_eq(#world.notices, 0)
		end)
	end)
end)





-- ==============================================
-- ==============================================
-- ======= 5/ "Why this error?" =================
-- ==============================================
-- ==============================================

helpers.describe("llm_screen_error: the region flow with the error answers", function()

	helpers.it("registers the action", function()
		scenario({}, function(world)
			helpers.assert_eq(type(world.handlers.llm_screen_error), "function")
		end)
	end)

	helpers.it("reads a region, asks the cause then the fix, offers them in order and types the fix", function()
		scenario({}, function(world)
			local answers = world.config.error_answers
			helpers.assert_eq(#answers, 2, "vision.json ships two error answers")
			helpers.assert_eq(answers[1].id, "cause")
			helpers.assert_eq(answers[2].id, "fix")
			helpers.assert_eq(world.handlers.llm_screen_error("tap_3", "openai"), true)
			local capture = world.captures[1]
			helpers.assert_eq(capture.mode, "region", "the user draws the region")
			capture.on_done({ status = "ok", scaled = true })
			helpers.assert_eq(exists(capture.dir), false, "the screenshot is deleted once read")
			helpers.assert_eq(world.posts[1].owner, "llm_vision", "one vision request")
			world.respond(1, "SCREEN: npm ERR! missing script: start")
			for index, answer in ipairs(answers) do
				world.wait_for(index + 1)
				local post = assert(world.posts[index + 1], "error answer request " .. index)
				helpers.assert_eq(post.url, "https://api.cerebras.ai/v1/chat/completions", "the menu's backend")
				helpers.assert_eq(post.body.messages[1].content, Vision.fill_language(answer.prompt, language()),
					answer.id .. ": its own prompt, language filled in")
				helpers.assert_eq(post.body.messages[2].content, "SCREEN:\nnpm ERR! missing script: start",
					answer.id .. ": the screen")
				helpers.assert_eq(post.body.stream, false)
				world.respond(index + 1, index == 1 and "ANSWER: The package has no start script."
					or "ANSWER: npm run dev")
			end
			helpers.assert_true(world.posts[2].body.messages[1].content:find(language(), 1, true) ~= nil,
				"the cause is asked in the interface language")
			world.wait_for(4)
			helpers.assert_eq(#world.posts, 3, "no third answer: the error list has two")
			helpers.assert_eq(table.concat(offered(world), "|"), "The package has no start script.|npm run dev",
				"cause first, fix second")
			helpers.assert_eq(#world.typed, 0, "nothing is typed before acceptance")
			helpers.assert_eq(world.engine.handle_shortcut({ key = "2", mods = {} }), true, "2 accepts")
			helpers.assert_eq(world.typed[1].deletes, 0, "nothing is erased")
			helpers.assert_eq(world.typed[1].text, "npm run dev", "the fix is typed at the caret")
		end)
	end)

	helpers.it("skips a failing answer and offers the other", function()
		scenario({}, function(world)
			world.handlers.llm_screen_error("tap_3", "openai")
			world.captures[1].on_done({ status = "ok", scaled = true })
			world.respond(1, "SCREEN: " .. SCREEN)
			world.wait_for(2)
			world.posts[2].callback({ ok = false, status = 500, error = "HTTP 500" })
			world.wait_for(3)
			world.respond(3, "ANSWER: the fix")
			helpers.assert_eq(table.concat(offered(world), "|"), "the fix")
			helpers.assert_eq(#world.notices, 0)
		end)
	end)

	helpers.it("both answers failing is a failed reading", function()
		scenario({}, function(world)
			world.handlers.llm_screen_error("tap_3", "openai")
			world.captures[1].on_done({ status = "ok", scaled = true })
			world.respond(1, "SCREEN: " .. SCREEN)
			world.wait_for(2); world.respond(2, "no tag")
			world.wait_for(3); world.respond(3, "no tag either")
			helpers.assert_eq(#world.engine.get_suggestions(), 0)
			helpers.assert_eq(world.notices[1], notice("llm.vision.read_failed"))
		end)
	end)

	helpers.it("refuses before any capture while the AI is off, paused or without a model", function()
		scenario({ disabled = true }, function(world)
			helpers.assert_eq(world.handlers.llm_screen_error("tap_3", "openai"), false)
			helpers.assert_eq(world.notices[1], notice("llm.manual_prediction.disabled"))
			helpers.assert_eq(#world.captures, 0)
		end)
		scenario({ paused = true }, function(world)
			helpers.assert_eq(world.handlers.llm_screen_error("tap_3", "openai"), false)
			helpers.assert_eq(world.notices[1], notice("llm.manual_prediction.paused"))
			helpers.assert_eq(#world.captures, 0)
		end)
		scenario({}, function(world)
			helpers.assert_eq(world.handlers.llm_screen_error("tap_3", "cerebras"), false)
			helpers.assert_eq(world.notices[1], notice("llm.vision.no_model"))
			helpers.assert_eq(#world.captures, 0)
		end)
	end)

	helpers.it("a newer screen action supersedes it", function()
		scenario({}, function(world)
			world.handlers.llm_screen_error("tap_3", "openai")
			world.handlers.llm_screen_region("tap_3", "openai")
			helpers.assert_eq(world.captures[1].cancelled, true, "the first capture is stopped")
			world.captures[1].on_done({ status = "ok", scaled = true })
			helpers.assert_eq(#world.posts, 0, "the stale capture is not sent")
		end)
	end)
end)
