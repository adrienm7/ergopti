--- tests/unit/modules/keymap/llm_bridge/test_private_expansion_never_prompted.lua

--- ==============================================================================
--- MODULE: Regression — a private expansion never reaches an AI prompt
--- DESCRIPTION:
--- (private-ai-context) rules_engine registers the personal-information
--- expansions (phone, SSN, IBAN) as ordinary mappings flagged is_private. They
--- are not final results, so their replacement stays in the hotstring buffer,
--- and the bridge mirrors that buffer into the AI context (`llm_buffer`) at each
--- preview: the next prediction request, local (Ollama, MLX) or remote, then
--- carried the secret in its prompt. Linux does not (its AI context object
--- clears on a private replacement); macOS now withholds everything up to the
--- last private expansion through the shared ContextBuffer.after_private rule.
---
--- The test runs the real registry, expander, rules engine, keymap bridge and
--- prediction engine; only the HTTP transport (a remote Cerebras entry, whose
--- requests are captured) and the tooltip canvas are faked.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("json")
local ApplyFixture = require("tests.support.apply_prediction_fixture")

local SECRET = "2840175123456"
local PREFIX = "28401"  -- rules_engine registers the first five digits of the SSN
local ENTRY_ID = "private-ai-context"

-- The pipeline replaces whole families of modules with doubles; later test files
-- of the same process must find the modules and the Hammerspoon stub they had.
local PRISTINE_MODULES, PRISTINE_HS = {}, _G.hs
for name, module in pairs(package.loaded) do PRISTINE_MODULES[name] = module end

--- Puts the module cache and the Hammerspoon global back as they were at load.
local function restore_environment()
	for name in pairs(package.loaded) do
		if PRISTINE_MODULES[name] == nil then package.loaded[name] = nil end
	end
	for name, module in pairs(PRISTINE_MODULES) do package.loaded[name] = module end
	_G.hs = PRISTINE_HS
end

--- A test case that leaves the environment as it found it, whatever happens.
--- @param name string
--- @param body function
local function it(name, body)
	helpers.it(name, function()
		local ok, failure = xpcall(body, debug.traceback)
		restore_environment()
		if not ok then error(failure, 0) end
	end)
end

--- Returns one named closure upvalue, or nil when the closure does not own it.
--- @param fn function Closure to inspect.
--- @param target string Upvalue name.
--- @return any value
--- @return number|nil index
local function get_upvalue(fn, target)
	for index = 1, 256 do
		local name, value = debug.getupvalue(fn, index)
		if not name then break end
		if name == target then return value, index end
	end
	return nil, nil
end

--- Builds the real pipeline around a captured HTTP transport.
--- @return table world { state, expander, bridge, engine, posts, mapping }
local function build_world()
	local world = { posts = {} }

	for name in pairs(package.loaded) do
		if type(name) == "string" and (name:find("^modules%.") or name:find("^adapters%.")
			or name:find("^infra%.") or name:find("^ui%.")) then
			package.loaded[name] = nil
		end
	end
	local _gestures = helpers.load_with_stubs("modules.gestures")
	local front_app = {
		title = function() return "E2EApp" end,
		name = function() return "E2EApp" end,
		bundleID = function() return "test.e2e" end,
		path = function() return "/Applications/E2E.app" end,
		pid = function() return 7 end,
	}
	helpers.load_with_stubs("infra.logger", {
		application = { frontmostApplication = function() return front_app end },
	})
	package.loaded["infra.logger"] = helpers.make_logger_stub()
	package.loaded["modules.keystats"] = {
		get_live_stats = function() return { wpm_physical = 0 } end,
		log_llm = function() end,
		log_llm_failed = function() end,
		log_llm_suggested = function() end,
		log_llm_dismissed = function() end,
		log_hotstring = function() end,
		log_hotstring_suggested = function() end,
		log_hotstring_dismissed = function() end,
		notify_synthetic = function() end,
		set_buffer = function() end,
	}
	-- Every other tooltip operation succeeds: a reset that could not hide would abort the request.
	local noop = function() return true end
	package.loaded["ui.tooltip"] = setmetatable({
		show_loading = function() return true end,
		show = function() return true end,
		show_predictions = function() return true end,
		get_current_index = function() return 1 end,
		make_diff_styled = function() return true end,
		reset_llm_timer = function() return true end,
		mark_chain_complete = function() return true end,
		set_chain_start = function() return true end,
		is_visible = function() return false end,
		is_hotstring_visible = function() return false end,
		tint = function() return {} end,
	}, { __index = function() return noop end })
	package.loaded["adapters.tooltip_renderer"] = setmetatable({}, { __index = function() return noop end })

	local State = helpers.load_with_stubs("modules.keymap.state")
	local Registry = require("modules.keymap.registry")
	local Expander = require("modules.keymap.expander")
	local RulesEngine = require("modules.dynamic_hotstrings.rules_engine")
	local core = require("modules.llm")
	local bridge = require("modules.keymap.llm_bridge")
	local engine = require("modules.llm.prediction_engine")
	-- The foreground window of the test is an ordinary, unprotected one.
	require("modules.llm.app_filter").is_blocked = function() return false end

	local CoreState = get_upvalue(core.get_active_profile, "CoreState")
	assert(type(CoreState) == "table", "the LLM core state must be reachable")
	CoreState.backend = "api"
	CoreState.active_profile_id = "advanced"
	local api = core.api_remote
	api.set_entries({ { id = ENTRY_ID, provider = "cerebras", token = "e2e-token", model = "qwen-3.8-27b" } })
	api.set_active_entry_id(ENTRY_ID)
	local _, ready_index = get_upvalue(api.is_ready, "_is_ready")
	assert(ready_index, "the remote readiness flag must be reachable")
	debug.setupvalue(api.is_ready, ready_index, true)
	local inference = get_upvalue(api.cancel_streaming, "_infer_client")
	assert(type(inference) == "table", "the remote HTTP owner must be reachable")
	inference.post = function(url, headers, body, callback)
		world.posts[#world.posts + 1] = { url = url, body = json.decode(body), callback = callback }
		return true
	end

	local state = State.new({ trigger_char = "★", expansion_delay = 0.4 }, { autocorrection = 0.3 })
	state.DELAYS = { llm_prediction = 1 }
	assert(Registry.init(state) == true)
	assert(bridge.init(state, {}) == true)
	assert(Expander.init(state, Registry, bridge) == true)
	engine.set_llm_enabled(true)
	engine.set_llm_num_predictions(1)
	engine.set_llm_sequential_mode(false)

	RulesEngine.inject_data({ social_security_number = SECRET }, "★")
	RulesEngine.start({
		add = Registry.add,
		set_group_context = Registry.set_group_context,
		sort_mappings = Registry.sort_mappings,
		is_section_enabled = function() return true end,
		is_group_enabled = function() return true end,
		register_lua_group = function() end,
		set_post_load_hook = function() end,
		register_interceptor = function() end,
		register_preview_provider = function() end,
		registry_transaction = function(_, mutation) return mutation() == true end,
	})
	for _, m in ipairs(state.mappings) do
		if m.trigger == PREFIX then world.mapping = m end
	end
	assert(world.mapping, "the SSN prefix mapping must be registered")
	assert(world.mapping.is_private == true and world.mapping.final_result ~= true,
		"the premise: a private mapping that is not a final result")

	world.state, world.expander, world.bridge, world.engine = state, Expander, bridge, engine
	return world
end

--- Types text the way the keymap does: append, then refresh the preview.
--- @param world table
--- @param text string
local function type_text(world, text)
	world.state.buffer = world.state.buffer .. text
	world.bridge.update_preview(world.state.buffer)
end

--- Fires the private expansion from its typed trigger.
--- @param world table
local function expand_private(world)
	type_text(world, "mon numero " .. PREFIX)
	assert(world.expander.try_auto_expand(world.mapping, 1, false) == true, "the private mapping must expand")
	world.bridge.update_preview(world.state.buffer)
end

--- Requests a manual prediction and returns the user turn of the request sent.
--- @param world table
--- @return string|nil content Nil when no request left.
local function prompted_text(world)
	local before = #world.posts
	-- An empty context is refused before anything is sent: that is the point.
	world.engine.request_manual_prediction()
	local post = world.posts[before + 1]
	if not post then return nil end
	local parts = {}
	for _, message in ipairs(post.body.messages) do parts[#parts + 1] = tostring(message.content) end
	return table.concat(parts, "\n")
end

helpers.describe("a private expansion never reaches an AI prompt (private-ai-context)", function()
	it("a request right after the expansion carries nothing of it", function()
		local world = build_world()
		type_text(world, "Voici ")
		expand_private(world)
		helpers.assert_true(world.state.buffer:find(SECRET, 1, true) ~= nil,
			"the premise: the hotstring buffer holds the secret")
		local prompt = prompted_text(world)
		helpers.assert_true(prompt == nil or (prompt:find(SECRET, 1, true) == nil
			and prompt:find(PREFIX, 1, true) == nil and prompt:find("Voici", 1, true) == nil),
			"the prompt must not carry the secret, its trigger or the text before it: " .. tostring(prompt))
	end)

	it("a request after more typing carries only the typed text, to a remote provider", function()
		local world = build_world()
		type_text(world, "Voici ")
		expand_private(world)
		type_text(world, " et ensuite je vous envoie le reste du dossier")
		local prompt = prompted_text(world)
		helpers.assert_true(prompt ~= nil, "text typed after the secret is a valid context")
		helpers.assert_true(prompt:find(SECRET, 1, true) == nil and prompt:find(PREFIX, 1, true) == nil,
			"the secret and its trigger are withheld: " .. prompt)
		helpers.assert_true(prompt:find("le reste du dossier", 1, true) ~= nil,
			"what the user typed afterwards still reaches the model")
	end)

	it("deleting into the secret and typing on never shows its remains", function()
		local world = build_world()
		type_text(world, "Voici ")
		expand_private(world)
		for _ = 1, 3 do
			world.state.buffer = world.state.buffer:sub(1, -2)
			world.bridge.update_preview(world.state.buffer)
		end
		helpers.assert_true(world.state.buffer:find(SECRET:sub(1, 8), 1, true) ~= nil,
			"the premise: most of the secret is still in the hotstring buffer")
		type_text(world, " puis la suite de la phrase")
		local prompt = prompted_text(world)
		helpers.assert_true(prompt ~= nil and prompt:find("la suite de la phrase", 1, true) ~= nil,
			"the text typed after the Backspaces is the context")
		helpers.assert_true(prompt:find(SECRET:sub(1, 8), 1, true) == nil,
			"no part of the secret survives a Backspace through it: " .. prompt)
	end)

	it("an ordinary expansion still feeds the context", function()
		local world = build_world()
		world.bridge.update_preview("")
		type_text(world, "bonjour je vous écris au sujet du dossier")
		local prompt = prompted_text(world)
		helpers.assert_true(prompt ~= nil and prompt:find("au sujet du dossier", 1, true) ~= nil,
			"without a private expansion the context is the typed text")
	end)

	it("the AI context holds only what was typed after the expansion", function()
		local world = build_world()
		type_text(world, "Voici ")
		expand_private(world)
		type_text(world, " merci beaucoup pour votre")
		helpers.assert_eq(world.state.llm_buffer, " merci beaucoup pour votre")
		helpers.assert_true(world.state.llm_private_mark ~= "", "the mark outlives the typing")
	end)
end)

helpers.describe("the other doors of the AI context stay shut too (private-ai-context)", function()
	it("the automatic agent watches the typing without the secret", function()
		local world = build_world()
		local seen = {}
		require("modules.llm.agent_runner").observe_typing = function(text) seen[#seen + 1] = text end
		type_text(world, "Voici ")
		type_text(world, "mon numero " .. PREFIX)
		seen = {}  -- what the user typed before the mapping fired is theirs to send
		helpers.assert_true(world.expander.try_auto_expand(world.mapping, 1, false), "the private mapping expands")
		world.bridge.update_preview(world.state.buffer)
		type_text(world, " merci")
		helpers.assert_true(#seen > 0, "the agent observes each keystroke")
		for _, text in ipairs(seen) do
			helpers.assert_true(text:find(PREFIX, 1, true) == nil and text:find(SECRET, 1, true) == nil,
				"the agent never receives the secret: " .. text)
		end
		helpers.assert_eq(seen[#seen], " merci")
	end)

	it("accepting a prediction after the expansion keeps the secret out of the context", function()
		local buffer = "Voici " .. SECRET .. " merci pour"
		local result = ApplyFixture.run({
			text = " votre aide",
			buffer = buffer,
			llm_buffer = " merci pour",
			llm_private_mark = "Voici " .. SECRET,
		})
		helpers.assert_eq(result.applied, true)
		helpers.assert_true(result.state.buffer:find(SECRET, 1, true) ~= nil, "the premise: the buffer still holds it")
		helpers.assert_eq(result.state.llm_buffer, " merci pour votre aide",
			"the context is what follows the secret, the accepted words included")
	end)

	it("a head cut of the hotstring buffer keeps describing it", function()
		local world = build_world()
		local bridge, state = world.bridge, world.state
		local before = "xxSECRET tail"
		bridge.mark_private_context("xxSECRET")
		bridge.private_context_trimmed(before, 2)
		helpers.assert_eq(state.llm_private_mark, "SECRET")
		local after = before:sub(3)
		bridge.update_preview(after)
		helpers.assert_eq(state.llm_buffer, " tail", "the cut buffer still hides the secret")
		bridge.private_context_trimmed(after, 6)
		helpers.assert_eq(state.llm_private_mark, "", "a secret cut away entirely leaves nothing to hide")
		bridge.update_preview(" tail more")
		helpers.assert_eq(state.llm_buffer, " tail more")
	end)
end)
