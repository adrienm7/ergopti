--- tests/unit/modules/keymap/expansion/test_hotstring_final_result.lua

--- ==============================================================================
--- MODULE: Final-result hotstrings (macOS)
--- DESCRIPTION:
--- Replays the shared final_result_vectors.json corpus through the real registry
--- and expander (try_expand, the arbitration the event tap also reaches), with a
--- virtual screen fed by the replacement transaction. The tap owns the completing
--- event, so a key that fires nothing is what reaches the application. The same
--- corpus runs on Windows (test_hotstring_final_result.ahk) and Linux
--- (test_hotstring_final_result.lua).
--- ==============================================================================

local helpers = require("tests.helpers")

local _     = helpers.load_with_stubs("infra.logger")
local State = helpers.load_with_stubs("modules.keymap.state")

--- Reads the shared corpus.
--- @return table corpus
local function load_corpus()
	local path = helpers.driver_root() .. "/../_shared/tests/corpus/hotstrings/final_result_vectors.json"
	local file = assert(io.open(path, "rb"))
	local raw = file:read("*a")
	file:close()
	return assert(require("json").decode(raw), "final_result_vectors.json must be valid JSON")
end

--- Builds a live registry and expander with the OS-facing collaborators stubbed.
--- @param rules table Corpus rules.
--- @param max_arrows number hotstrings.cascade_max_arrows.
--- @return table state, table expander, table registry, table view
local function fresh_engine(rules, max_arrows)
	package.loaded["ui.tooltip"]        = { hide = function() end, hide_forced = function() end }
	package.loaded["modules.keystats"] = {
		notify_synthetic = function() end,
		set_buffer       = function() end,
		log_hotstring    = function() end,
	}
	for name in pairs(package.loaded) do
		if type(name) == "string" and name:match("^modules%.keymap%.")
			and name ~= "modules.keymap.state" then
			package.loaded[name] = nil
		end
	end
	package.loaded["infra.text_utils"] = nil
	package.loaded["text_utils"]       = nil

	local Registry = require("modules.keymap.registry")
	local Expander = require("modules.keymap.expander")
	local state = State.new({ trigger_char = "\xe2\x98\x85", expansion_delay = 0.4 }, {})
	Registry.init(state)
	Expander.init(state, Registry, {
		update_preview  = function() end,
		get_llm_enabled = function() return false end,
		start_timer     = function() end,
	})
	for index, rule in ipairs(rules) do
		-- One source per rule: the same trigger from one source is one entry.
		state.current_group = "source_" .. index
		Registry.add(rule.trigger, rule.replacement, {
			auto_expand              = rule.auto == true,
			is_word                  = rule.word_start == true,
			priority                 = rule.priority,
			final_result             = rule.final_result == true,
			is_case_sensitive        = rule.case_sensitive == true,
			is_case_sensitive_strict = rule.case_sensitive == true,
		})
	end
	Registry.sort_mappings()
	state.start_is_word_boundary = true
	state.CASCADE_MAX_ARROWS = max_arrows

	local view = { screen = "" }
	local typed
	require("modules.keymap.utils").emit_text = function(text)
		typed = text
		return require("infra.text_utils").utf8_len(text), text, text
	end
	Expander.perform_text_replacement = function(deletes, emit_action, buffer_action, is_final,
		_ignored, _source, _variant, _is_private, terminator_spec)
		typed = nil
		emit_action()
		buffer_action()
		-- The real commit half of a final replacement, which forgets the buffer.
		if is_final then state.suppress_rescan() end
		view.screen = view.screen:sub(1, #view.screen - deletes) .. (typed or "")
			.. (terminator_spec and terminator_spec.chars or "")
		return true
	end
	return state, Expander, Registry, view
end

--- Types `typed` and returns what the application shows.
--- @param rules table Corpus rules.
--- @param typed string The typed characters.
--- @param max_arrows number hotstrings.cascade_max_arrows.
--- @return string screen
local function replay(rules, typed, max_arrows)
	local state, expander, registry, view = fresh_engine(rules, max_arrows)
	-- The corpus names its own end characters, whatever the local catalogue says.
	local catalogue_terminator = registry.is_terminator
	registry.is_terminator = function(char)
		return char == " " or char == "\t" or char == "\n" or catalogue_terminator(char)
	end

	--- One keystroke in the order of the tap's run_trigger_checks (keymap/init.lua):
	--- the end-character entries of the previous letter, then the immediate ones.
	local function press(ch)
		local previous = state.buffer:sub(-1)
		state.buffer = state.buffer .. ch
		if registry.is_terminator(ch) and previous ~= "" then
			for _, m in ipairs(registry.mappings_for_tail(previous) or {}) do
				if not m.auto then
					local fired, reason = expander.try_terminator_expand(m, ch, 1, false)
					if fired then return true end
					if reason == "noop_final" then return false end
				end
			end
		end
		for _, m in ipairs(registry.mappings_for_tail(ch) or {}) do
			if m.auto then
				local fired, reason = expander.try_auto_expand(m, 1, false)
				if fired then return true end
				if reason == "noop_final" then return false end
			end
		end
		return false
	end

	for ch in typed:gmatch(".") do
		if press(ch) ~= true then view.screen = view.screen .. ch end
	end
	return view.screen
end

local CORPUS = load_corpus()

helpers.describe("macOS expander: the shared final_result_vectors.json corpus", function()
	local matrix = CORPUS.matrix
	for _, personal_auto in ipairs(matrix.personal_auto) do
		for _, bundled_auto in ipairs(matrix.bundled_auto) do
			for _, case_sensitive in ipairs(matrix.case_sensitive) do
				for _, output in ipairs(matrix.output) do
					for _, arrows in ipairs(matrix.max_arrows) do
						for _, end_char in ipairs(matrix.end_char) do
							local name = string.format("(hotstring-final-result) personal_auto=%s bundled_auto=%s cs=%s output=%s arrows=%d end=%d",
								tostring(personal_auto), tostring(bundled_auto), tostring(case_sensitive), output, arrows, end_char:byte())
							helpers.it(name, function()
								local screen = replay({
									{ trigger = matrix.trigger, replacement = output, auto = personal_auto, word_start = true,
										priority = matrix.personal_priority, final_result = true, case_sensitive = case_sensitive },
									{ trigger = matrix.trigger, replacement = matrix.bundled, auto = bundled_auto, word_start = true,
										priority = matrix.bundled_priority },
								}, matrix.trigger .. end_char, arrows)
								helpers.assert_eq(screen, output .. end_char, name)
							end)
						end
					end
				end
			end
		end
	end

	for _, vector in ipairs(CORPUS.vectors) do
		helpers.it(vector.id .. " (hotstring-final-result)", function()
			helpers.assert_eq(replay(vector.rules, vector.typed, vector.max_arrows), vector.expect_screen, vector.description)
		end)
	end
end)
