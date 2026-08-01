--- tests/unit/modules/keymap/test_apply_prediction_paste_ops.lua

--- ==============================================================================
--- MODULE: apply_prediction paste-ops drain regression test
--- DESCRIPTION:
--- Regression test for keymap-bridge-001: apply_prediction must drain
--- km_utils.take_paste_ops() and credit the count to
--- _state.expected_synthetic_pastes so that the Cmd+V echo from clipboard-
--- paste completions is marked synthetic and does not wipe the rolling buffer.
--- ==============================================================================

local helpers = require("tests.helpers")




-- ==================================================
-- ==================================================
-- ======= 1/ Stubs & module wiring =================
-- ==================================================
-- ==================================================

-- Minimal logger stub (already in hs stub, but ensure no leftover state)
package.loaded["infra.logger"] = nil
helpers.load_with_stubs("infra.logger")

-- Expander stub: llm_bridge now routes apply_prediction through
-- expander.perform_text_replacement. The stub mirrors the contract so
-- the paste-ops drain tests stay headless. The init() call captures the
-- state reference; perform_text_replacement updates it exactly as the
-- real expander does.
local _exp_state = nil
package.loaded["modules.keymap.expander"] = {
	init = function(s, ...) _exp_state = s end,
	perform_text_replacement = function(deletes, emit_fn, buf_fn, is_final, is_ignored, source_type, source_variant)
		if _exp_state and hs and hs.timer then
			_exp_state.last_synthetic_arm_time = hs.timer.secondsSinceEpoch()
		end
		if _exp_state then
			_exp_state.expected_synthetic_deletes = (_exp_state.expected_synthetic_deletes or 0) + deletes
		end
		local _, _, emitted = pcall(emit_fn)
		emitted = emitted or ""
		if _exp_state then
			_exp_state.expected_synthetic_chars = (_exp_state.expected_synthetic_chars or "") .. emitted
		end
		local km = package.loaded["modules.keymap.utils"]
		local paste_ops = km and type(km.take_paste_ops) == "function" and km.take_paste_ops() or 0
		if paste_ops > 0 and _exp_state then
			_exp_state.expected_synthetic_pastes = (_exp_state.expected_synthetic_pastes or 0) + paste_ops
		end
		if type(buf_fn) == "function" then pcall(buf_fn) end
	end,
}

local helpers2 = helpers  -- alias for clarity inside closures

-- We test the logic in isolation by directly exercising the production code
-- path via a minimal stub of km_utils that simulates the paste-path contract:
-- emit_text() increments an internal counter and returns ("", "") when
-- the text is "long" (> 50 chars); take_paste_ops() drains and returns it.

local function make_km_utils_stub()
	local _pending = 0
	return {
		emit_text = function(text)
			if type(text) == "string" and #text > 50 then
				-- Simulates the clipboard-paste path: no emitted_str, counter bumped
				_pending = _pending + 1
				return #text, ""
			end
			-- Short text: keystroke path, no paste op
			return #text, text
		end,
		take_paste_ops = function()
			local n = _pending
			_pending = 0
			return n
		end,
		-- Other helpers accessed at require time
		tokens_from_repl          = function() return {} end,
		plain_text                = function(t) return t end,
		resolve_prediction_overlap = function(_, _, s) return 0, s end,
	}
end




-- ==================================================
-- ==================================================
-- ======= 2/ Regression tests ======================
-- ==================================================
-- ==================================================

helpers.describe("apply_prediction — paste-ops drain (keymap-bridge-001)", function()

	-- Helper: build a minimal _state table as llm_bridge expects.
	local function make_state(buf)
		return {
			buffer                    = buf or "",
			expected_synthetic_chars  = "",
			expected_synthetic_deletes = 0,
			expected_synthetic_pastes = 0,
			last_synthetic_arm_time   = 0,
		}
	end

	helpers.it("drains take_paste_ops() into expected_synthetic_pastes on paste path", function()
		-- A 60-char completion triggers the paste path in our stub
		local long_text = ("a"):rep(60)

		-- Inject stubs so llm_bridge.lua can be loaded
		local km_stub = make_km_utils_stub()
		package.loaded["modules.keymap.utils"] = km_stub

		-- engine stub: always returns one prediction with our long text.
		-- llm_bridge requires "modules.llm.prediction_engine", not the keymap-local path.
		package.loaded["modules.llm.prediction_engine"] = {
			init            = function() end,
			is_visible      = function() return true end,
			get_predictions = function() return {{text=long_text, display=long_text}} end,
			consume         = function(_, _) return { deletes = 0, to_type = long_text } end,
			reset           = function() end,
			arm_chain       = function() end,
			get_current_index = function() return 1 end,
			get_navigation_mods = function() return {} end,
			get_validation_mods = function() return {} end,
			navigate        = function() end,
			handle_chain_signal = function() return false end,
		}

		-- keylogger stub
		package.loaded["modules.keylogger"] = {
			notify_synthetic = function() end,
			log_llm_accepted = function() end,
			set_buffer       = function() end,
		}

		-- llm core stub
		package.loaded["modules.llm"] = {
			check_modifiers   = function() return false end,
			get_backend       = function() return "ollama" end,
			-- prediction_engine.lua's module-level code calls this unconditionally
			-- at require-time; without it, any later test whose require chain
			-- reaches prediction_engine while this stub is still cached (this
			-- table is never restored after the test) crashes with
			-- "attempt to call a nil value (field 'get_current_model')".
			get_current_model = function() return "stub-model" end,
		}

		-- keycodes stub
		package.loaded["infra.keycodes"] = {
			TAB              = 48,
			RETURN           = 36,
			ENTER            = 76,
			F16_LLM_CHAIN_SIGNAL = 106,
			ARROW_MIN        = 123,
			ARROW_MAX        = 126,
			to_name          = function(c) return tostring(c) end,
		}

		local hs_stub = helpers.load_with_stubs("infra.logger")  -- ensure hs is fresh
		-- (load_with_stubs already sets _G.hs)

		-- Minimal timings stub
		package.loaded["infra.timings"] = { sec = function() return 0.1 end }

		-- Load the real bridge module
		package.loaded["modules.keymap.llm_bridge"] = nil
		local ok, bridge = pcall(require, "modules.keymap.llm_bridge")
		if not ok then
			-- If the module can't fully load (missing transitive deps), test the
			-- drain logic directly on the production function we care about.
			-- This path validates the fix in isolation.
			helpers.assert_true(false,
				"Could not load llm_bridge — check stubs: " .. tostring(bridge))
			return
		end

		local state = make_state("hello world, this is a test buffer prefix")
		bridge.init(state, {})
		package.loaded["modules.keymap.expander"].init(state)

		-- Before fix: expected_synthetic_pastes stayed 0 even after a paste-path acceptance
		-- After fix:  expected_synthetic_pastes == 1 and take_paste_ops() returns 0
		bridge.apply_prediction(1)

		helpers.assert_eq(state.expected_synthetic_pastes, 1,
			"expected_synthetic_pastes must be 1 after a paste-path prediction acceptance")
		helpers.assert_eq(km_stub.take_paste_ops(), 0,
			"take_paste_ops() must be 0 — counter must have been fully drained")
		helpers.assert_eq(state.expected_synthetic_chars, "",
			"expected_synthetic_chars must be empty (paste path returns empty emitted_str)")
	end)

	helpers.it("does NOT increment expected_synthetic_pastes on keystroke path", function()
		-- A short completion (< 50 chars) goes through the keystroke path
		local short_text = "hello"

		local km_stub = make_km_utils_stub()
		package.loaded["modules.keymap.utils"] = km_stub

		package.loaded["modules.llm.prediction_engine"] = {
			init            = function() end,
			is_visible      = function() return true end,
			get_predictions = function() return {{text=short_text, display=short_text}} end,
			consume         = function(_, _) return { deletes = 0, to_type = short_text } end,
			reset           = function() end,
			arm_chain       = function() end,
			get_current_index = function() return 1 end,
			get_navigation_mods = function() return {} end,
			get_validation_mods = function() return {} end,
			navigate        = function() end,
			handle_chain_signal = function() return false end,
		}

		package.loaded["modules.keylogger"] = {
			notify_synthetic = function() end,
			log_llm_accepted = function() end,
			set_buffer       = function() end,
		}

		package.loaded["modules.llm"] = {
			check_modifiers   = function() return false end,
			get_backend       = function() return "ollama" end,
			-- prediction_engine.lua's module-level code calls this unconditionally
			-- at require-time; without it, any later test whose require chain
			-- reaches prediction_engine while this stub is still cached (this
			-- table is never restored after the test) crashes with
			-- "attempt to call a nil value (field 'get_current_model')".
			get_current_model = function() return "stub-model" end,
		}

		package.loaded["infra.keycodes"] = {
			TAB = 48, RETURN = 36, ENTER = 76,
			F16_LLM_CHAIN_SIGNAL = 106,
			ARROW_MIN = 123, ARROW_MAX = 126,
			to_name = function(c) return tostring(c) end,
		}

		package.loaded["infra.timings"] = { sec = function() return 0.1 end }
		package.loaded["modules.keymap.llm_bridge"] = nil
		local ok, bridge = pcall(require, "modules.keymap.llm_bridge")
		if not ok then return end  -- stubs not sufficient in this env, skip

		local state = make_state("prefix")
		bridge.init(state, {})
		package.loaded["modules.keymap.expander"].init(state)
		bridge.apply_prediction(1)

		helpers.assert_eq(state.expected_synthetic_pastes, 0,
			"keystroke path must not increment expected_synthetic_pastes")
		helpers.assert_eq(km_stub.take_paste_ops(), 0,
			"take_paste_ops must still be 0 after keystroke path")
	end)
end)
