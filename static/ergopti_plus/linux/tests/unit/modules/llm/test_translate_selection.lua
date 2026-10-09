--- tests/unit/modules/llm/test_translate_selection.lua

--- ==============================================================================
--- MODULE: Translate The Selection (Linux)
--- DESCRIPTION:
--- llm_translate_selection reads the selection the way the tone actions do,
--- asks the AI menu's current text backend for its translation into the
--- binding's language, and offers it as one tooltip candidate. Accepting it
--- replaces the selection; Escape, a dismiss or typing leave the text alone.
---
--- The real engine, shared translation helpers, profile registry, settings and
--- remote client run; only the boundaries are scripted: the HTTP transport,
--- the preferences file, the clock, the tooltip, the selection read and its
--- replacement, the focused-window probe and the interface locale.
---
--- ROOT CAUSE ENCODED:
--- A selection could only be rewritten along the tone ladder: translating it
--- meant a prompt action on the typing buffer and a retyped sentence.
--- ==============================================================================

local helpers = require("tests.helpers")
local Fakes = require("tests.fakes")
local Json = require("json")
local Translate = require("llm.translate")
local PreferencesFixture = require("tests.support.llm_preferences_fixture")

local SELECTION = "On se voit demain ?"

local ENTRY = { id = "cerebras-1", provider = "cerebras", label = "Cerebras", token = "k", model = "", base_url = "" }

local RELOADED = {
	"modules.llm.prediction_engine", "modules.llm.settings", "modules.llm.profile_settings",
	"modules.llm.display_settings", "modules.llm.trigger_settings", "modules.llm.navigation_settings",
	"modules.llm.api_remote", "modules.llm.translation",
}
local FAKED = {
	"adapters.secure_field_detector", "adapters.http_client", "modules.llm.api_entries",
	"modules.llm.profiles", "modules.llm.api_ollama",
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

--- @param relative string Path under _shared/.
--- @return table decoded
local function read_shared_json(relative)
	local fh = assert(io.open(helpers.driver_root() .. "/../_shared/" .. relative, "r"), "cannot open " .. relative)
	local raw = fh:read("*a")
	fh:close()
	return assert(Json.decode(raw), relative .. " is not valid JSON")
end

--- Runs body against the real engine with scripted boundaries.
--- @param opts table { selection?, disabled?, paused?, locale? }
--- @param body function Receives the scenario's world.
local function scenario(opts, body)
	PreferencesFixture.with(function()
		local previous = {}
		for _, name in ipairs(RELOADED) do previous[name] = package.loaded[name]; package.loaded[name] = nil end
		for _, name in ipairs(FAKED) do previous[name] = package.loaded[name] end
		local I18n = require("infra.i18n")
		local previous_locale = I18n.get_locale
		local locale = opts.locale or "fr"
		I18n.get_locale = function() return locale end
		local world = { posts = {}, notices = {}, reads = 0, replaced = {}, typed = {}, shown = nil,
			focus = "editor\1Draft", selection = opts.selection }
		package.loaded["adapters.secure_field_detector"] = {
			isSecureField = function() return false end,
			isSecureApp = function() return false end,
			isUrlBar = function() return false end,
		}
		package.loaded["adapters.http_client"] = {
			post = function(url, _, request_body, callback)
				world.posts[#world.posts + 1] = { url = url, body = Json.decode(request_body), callback = callback }
				return true
			end,
			cancel = function() return true end,
		}
		package.loaded["modules.llm.api_entries"] = {
			active = function() return ENTRY end,
			list = function() return { ENTRY } end,
		}
		package.loaded["modules.llm.profiles"] = {
			init = function() end,
			is_enabled = function() return opts.disabled ~= true end,
			get_current_model = function() return "ollama-model" end,
			get_base_url = function() return "http://127.0.0.1:11434" end,
		}
		package.loaded["modules.llm.api_ollama"] = { chat = function() end, cancel = function() return true end }

		local scheduler = Fakes.timer_scheduler()
		local engine = require("modules.llm.prediction_engine")
		engine.init({
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
				world.typed[#world.typed + 1] = candidate.to_type
				return true
			end,
			-- The daemon's seams: a copy probe, the injector's select-back, the window probe
			read_selection = function()
				world.reads = world.reads + 1
				if world.selection == nil then return false, "", "no_selection" end
				return true, world.selection, nil
			end,
			replace_selection = function(text)
				world.replaced[#world.replaced + 1] = text
				world.selection = text
				return true
			end,
			focus_id = function() return world.focus end,
		})
		world.engine = engine
		world.handlers = engine.action_handlers()
		world.config = read_shared_json("modules/llm/translate.json")

		--- The remote server answers request `index` with `text`.
		function world.respond(index, text)
			local post = assert(world.posts[index], "no request " .. index .. " was sent")
			post.callback({ ok = true, status = 200,
				body = Json.encode({ choices = { { message = { role = "assistant", content = text } } } }) })
		end

		--- Lets the pacing timer run until request `index` is sent, or long past it.
		function world.wait_for(index)
			for _ = 1, 20 do
				if world.posts[index] then return end
				scheduler.test.advance(0.5)
			end
		end

		local ok, err = pcall(body, world)
		engine.dismiss()
		I18n.get_locale = previous_locale
		for _, name in ipairs(RELOADED) do package.loaded[name] = previous[name] end
		for _, name in ipairs(FAKED) do package.loaded[name] = previous[name] end
		if not ok then error(err, 0) end
	end, { initial = BASE_PREFERENCES })
end

--- @param key string
--- @return string
local function notice(key)
	return require("infra.i18n").get(key)
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

helpers.describe("llm_translate_selection: the selection translated and offered", function()

	helpers.it("registers the action", function()
		scenario({}, function(world)
			helpers.assert_eq(type(world.handlers.llm_translate_selection), "function")
		end)
	end)

	helpers.it("translates into the interface language, offers one candidate, and replaces on accept", function()
		scenario({ selection = SELECTION, locale = "fr" }, function(world)
			helpers.assert_eq(world.handlers.llm_translate_selection("tap_3", "ui"), true)
			helpers.assert_eq(world.reads, 1, "the selection is read once")
			world.wait_for(1)
			local post = assert(world.posts[1], "one request")
			helpers.assert_eq(post.url, "https://api.cerebras.ai/v1/chat/completions", "the menu's backend")
			local messages = post.body.messages
			helpers.assert_eq(#messages, 2, "system and user only: no PREFIX / TAIL turns")
			helpers.assert_eq(messages[1].role, "system")
			helpers.assert_eq(messages[1].content, Translate.system_prompt(world.config, "Français"),
				"\"ui\" with a French interface names Français")
			helpers.assert_eq(messages[2].role, "user")
			helpers.assert_eq(messages[2].content, Translate.user_text(world.config, SELECTION))
			helpers.assert_eq(post.body.max_tokens, world.config.max_tokens)
			helpers.assert_eq(post.body.stream, false)
			helpers.assert_eq(world.shown and world.shown.meta.loading, true, "the tooltip says it is working")

			world.respond(1, "TRANSLATION: See you tomorrow?")
			helpers.assert_eq(table.concat(offered(world), "|"), "See you tomorrow?", "one candidate")
			helpers.assert_eq(world.shown.meta.loading, false)
			helpers.assert_eq(#world.replaced, 0, "nothing is replaced before acceptance")
			helpers.assert_eq(#world.notices, 0)

			helpers.assert_eq(world.engine.handle_shortcut({ key = "1", mods = {} }), true, "1 accepts")
			helpers.assert_eq(table.concat(world.replaced, "|"), "See you tomorrow?", "the selection is replaced")
			helpers.assert_eq(#world.typed, 0, "never typed at the caret")
			helpers.assert_eq(world.selection, "See you tomorrow?", "and left selected")
			helpers.assert_eq(#world.engine.get_suggestions(), 0, "the offer is gone")
		end)
	end)

	helpers.it("a fixed language ignores the interface's", function()
		scenario({ selection = SELECTION, locale = "fr" }, function(world)
			world.handlers.llm_translate_selection("tap_3", "ja")
			world.wait_for(1)
			helpers.assert_eq(world.posts[1].body.messages[1].content, Translate.system_prompt(world.config, "日本語"))
		end)
	end)

	helpers.it("Escape leaves the selection untouched", function()
		scenario({ selection = SELECTION }, function(world)
			world.handlers.llm_translate_selection("tap_3", "en")
			world.wait_for(1)
			world.respond(1, "TRANSLATION: See you tomorrow?")
			helpers.assert_eq(#world.engine.get_suggestions(), 1)
			world.engine.withdraw()
			helpers.assert_eq(#world.engine.get_suggestions(), 0)
			helpers.assert_eq(#world.replaced, 0)
			helpers.assert_eq(world.selection, SELECTION)
		end)
	end)

	helpers.it("typing while it runs drops the answer", function()
		scenario({ selection = SELECTION }, function(world)
			world.handlers.llm_translate_selection("tap_3", "en")
			world.wait_for(1)
			world.engine.on_char("x", "x", {})
			world.respond(1, "TRANSLATION: See you tomorrow?")
			helpers.assert_eq(#world.engine.get_suggestions(), 0)
			helpers.assert_eq(#world.replaced, 0)
		end)
	end)

	helpers.it("a newer trigger supersedes the one in flight", function()
		scenario({ selection = SELECTION }, function(world)
			world.handlers.llm_translate_selection("tap_3", "en")
			world.wait_for(1)
			world.handlers.llm_translate_selection("tap_3", "de")
			world.wait_for(2)
			world.respond(1, "TRANSLATION: stale")
			helpers.assert_eq(#world.engine.get_suggestions(), 0, "the superseded answer is ignored")
			world.respond(2, "TRANSLATION: Bis morgen?")
			helpers.assert_eq(table.concat(offered(world), "|"), "Bis morgen?")
		end)
	end)

	helpers.it("refuses to replace in another window", function()
		scenario({ selection = SELECTION }, function(world)
			world.handlers.llm_translate_selection("tap_3", "en")
			world.wait_for(1)
			world.respond(1, "TRANSLATION: See you tomorrow?")
			world.focus = "terminal\1Shell"
			helpers.assert_eq(world.engine.accept(1), false)
			helpers.assert_eq(#world.replaced, 0)
		end)
	end)
end)





-- ==============================================
-- ==============================================
-- ======= 3/ Refusals and failures =============
-- ==============================================
-- ==============================================

helpers.describe("llm_translate_selection: refusals and failures", function()

	helpers.it("an empty selection is told, and nothing is requested", function()
		scenario({ selection = nil }, function(world)
			helpers.assert_eq(world.handlers.llm_translate_selection("tap_3", "ui"), false)
			helpers.assert_eq(world.notices[1], notice("llm.translate.no_selection"))
			world.wait_for(1)
			helpers.assert_eq(#world.posts, 0)
		end)
	end)

	helpers.it("a blank selection is an empty one", function()
		scenario({ selection = "  \n" }, function(world)
			helpers.assert_eq(world.handlers.llm_translate_selection("tap_3", "ui"), false)
			helpers.assert_eq(world.notices[1], notice("llm.translate.no_selection"))
		end)
	end)

	helpers.it("refuses like the manual prediction while the AI is off, before reading", function()
		scenario({ selection = SELECTION, disabled = true }, function(world)
			helpers.assert_eq(world.handlers.llm_translate_selection("tap_3", "ui"), false)
			helpers.assert_eq(world.notices[1], notice("llm.manual_prediction.disabled"))
			helpers.assert_eq(world.reads, 0, "no copy chord")
			world.wait_for(1)
			helpers.assert_eq(#world.posts, 0)
		end)
	end)

	helpers.it("refuses while paused, before reading", function()
		scenario({ selection = SELECTION, paused = true }, function(world)
			helpers.assert_eq(world.handlers.llm_translate_selection("tap_3", "ui"), false)
			helpers.assert_eq(world.notices[1], notice("llm.manual_prediction.paused"))
			helpers.assert_eq(world.reads, 0)
		end)
	end)

	helpers.it("an answer without the tag is a failed translation", function()
		scenario({ selection = SELECTION }, function(world)
			world.handlers.llm_translate_selection("tap_3", "en")
			world.wait_for(1)
			world.respond(1, "See you tomorrow?")
			helpers.assert_eq(#world.engine.get_suggestions(), 0)
			helpers.assert_eq(world.notices[1], notice("llm.translate.failed"))
			helpers.assert_eq(world.shown, nil, "the working tooltip is gone")
		end)
	end)

	helpers.it("a failed request is a failed translation", function()
		scenario({ selection = SELECTION }, function(world)
			world.handlers.llm_translate_selection("tap_3", "en")
			world.wait_for(1)
			world.posts[1].callback({ ok = false, status = 500, error = "HTTP 500" })
			helpers.assert_eq(world.notices[1], notice("llm.translate.failed"))
			helpers.assert_eq(#world.replaced, 0)
		end)
	end)

	helpers.it("an invalid parameter reads nothing and sends nothing", function()
		scenario({ selection = SELECTION }, function(world)
			helpers.assert_eq(world.handlers.llm_translate_selection("tap_3", "English|2"), false)
			helpers.assert_eq(world.reads, 0)
			helpers.assert_eq(#world.posts, 0)
		end)
	end)
end)

helpers.it("translates a free language name without changing selection authority", function()
	scenario({ selection = SELECTION, locale = "fr" }, function(world)
		helpers.assert_eq(world.handlers.llm_translate_selection("tap_3", "Esperanto"), true)
		helpers.assert_eq(#world.posts, 1)
		helpers.assert_true(world.posts[1].body.messages[1].content:find("into Esperanto", 1, true) ~= nil)
		helpers.assert_eq(world.reads, 1)
		helpers.assert_eq(#world.replaced, 0, "no replacement before actual acceptance")
	end)
end)
