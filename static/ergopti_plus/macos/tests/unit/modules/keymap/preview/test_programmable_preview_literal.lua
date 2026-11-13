--- tests/unit/modules/keymap/preview/test_programmable_preview_literal.lua

--- ==============================================================================
--- MODULE: Programmable Preview Literal Regression
--- DESCRIPTION:
--- A programmable hotstring's static preview is declared display metadata and
--- its callback output is typed literally, so the tooltip must show the bytes
--- the source declared. Braces that look like output tokens ({Left},
--- {U+0041}) must survive, while an ordinary provider value keeps the TOML
--- token projection (HS-001 / MH-001).
--- ==============================================================================

local helpers = require("tests.helpers")

local MAGIC = "★"
local LITERAL = "Literal {Left} {U+0041}"





-- =================================
-- =================================
-- ======= 1/ Fixture Owners =======
-- =================================
-- =================================

--- Resolves the provider the real rules engine registers when no builtin rule
--- owns the buffer and a programmable source declares a preview.
--- @return any result First provider return value.
local function rules_engine_user_preview()
	local result
	helpers.with_stub_scope({ "modules.dynamic_hotstrings.rules_engine", "hotstrings.engine.dynamic.core",
		"modules.dynamic_hotstrings.user_code", "modules.keystats", "modules.keystats.init" }, function()
		local closed_keystats = {}
		package.loaded["modules.keystats"] = closed_keystats
		package.loaded["modules.keystats.init"] = closed_keystats
		local Rules = helpers.load_with_stubs("modules.dynamic_hotstrings.rules_engine")
		package.loaded["modules.dynamic_hotstrings.user_code"] = {
			preview = function(buf) if buf == "@u" then return LITERAL end return nil end,
			request = function() return false end,
		}
		local fixture = {}
		local keymap = {
			is_group_enabled = function() return true end,
			is_section_enabled = function() return true end,
			register_lua_group = function() end,
			set_post_load_hook = function() end,
			register_interceptor = function(fn) fixture.interceptor = fn end,
			dynamic_rule_within_delay = function() return true end,
			register_preview_provider = function(fn) fixture.provider = fn end,
			registry_transaction = function(_, mutation) return mutation() == true end,
			invalidate_hotstring_preview = function() return true end,
			owns_visible_magic_action = function() return false end,
			inject_dynamic = function() return true end,
			add = function() end,
			set_group_context = function() end,
			sort_mappings = function() end,
		}
		helpers.assert_true(Rules.start(keymap))
		local ok, err = xpcall(function() result = fixture.provider("@u", true) end, debug.traceback)
		helpers.assert_true(Rules.stop(), "exact fixture owner must retire")
		if not ok then error(err, 0) end
	end)
	return result
end

--- Renders one provider result through the real bridge and the real output
--- token projection, returning the text of the painted row.
--- @param provider_result any Value returned by the preview provider.
--- @return string|nil text
local function render_provider_row(provider_result)
	local text
	helpers.with_stub_scope({
		"platform.input.synthetic_input", "core.events.timer_scheduler", "core.logger.engine.logger",
		"infra.manifest_reader", "modules.hotstrings.hotstrings_config",
		"modules.keymap.expander", "modules.keystats", "modules.llm",
		"modules.llm.prediction_engine", "core.ui.ui.tooltip", "modules.keymap.llm_bridge",
	}, function()
		local scheduled = {}
		local action_epoch = {}
		package.loaded["platform.input.synthetic_input"] = {
			current_action_epoch = function() return action_epoch end,
		}
		package.loaded["core.events.timer_scheduler"] = {
			hotstring_time = function() return _G.hs.timer.secondsSinceEpoch() end,
			after = function(delay, fn)
				local handle = { delay = delay, fn = fn }
				scheduled[#scheduled + 1] = handle
				return handle, true
			end,
			every = function() return { kind = "diagnostic-pump" }, true end,
			cancel = function() return true end,
		}
		package.loaded["core.logger.engine.logger"] = helpers.make_logger_stub()
		package.loaded["infra.manifest_reader"] = { default_for = function() return MAGIC end }
		package.loaded["modules.hotstrings.hotstrings_config"] = { resolve = function() return nil end }
		package.loaded["modules.keymap.expander"] = {
			resolve_magic_action = function() return { winner = nil, candidates = {} } end,
		}
		package.loaded["modules.keystats"] = {
			log_hotstring_suggested = function() end,
			log_hotstring_dismissed = function() end,
		}
		package.loaded["modules.llm"] = {
			DEFAULT_STATE = { llm_after_hotstring = false, llm_reset_on_nav = true },
		}
		package.loaded["modules.llm.prediction_engine"] = {
			set_runtime_guard = function() end,
			init = function() return true end,
			get_llm_enabled = function() return false end,
			reset = function() return true end,
		}
		package.loaded["core.ui.ui.tooltip"] = {
			set_runtime_guard = function() end,
			set_accept_callback = function() end,
			set_cancel_callback = function() end,
			set_on_show_callback = function() end,
			set_timeout = function() end,
			tint = function() return {} end,
			show_stacked = function(rows)
				text = rows and rows[1] and rows[1].text
				return true
			end,
		}
		local Bridge = helpers.load_with_stubs("modules.keymap.llm_bridge")
		local state = {
			buffer = "@u",
			mappings = {},
			groups = {},
			magic_key = MAGIC,
			no_rescan_until = 0,
			preview_providers = { function() return provider_result, {} end },
			is_repeat_feature_enabled = function() return false end,
		}
		require("modules.keymap.llm_context").seed(state, state.buffer, "")
		Bridge.init(state, { preview_star_enabled = true, preview_autocorrect_enabled = true })
		Bridge.update_preview(state.buffer)
		local delivered = 0
		while delivered < #scheduled do
			delivered = delivered + 1
			scheduled[delivered].fn()
		end
	end)
	return text
end





-- ========================================
-- ========================================
-- ======= 2/ Behavioral Regression =======
-- ========================================
-- ========================================

helpers.describe("programmable preview literal display", function()
	helpers.it("(programmable-preview-literal) rules engine marks a user preview literal", function()
		local result = rules_engine_user_preview()
		helpers.assert_eq(type(result), "table", "a user preview must carry its literal marker")
		helpers.assert_eq(result.text, LITERAL)
		helpers.assert_eq(result.literal, true)
	end)

	helpers.it("(programmable-preview-literal) bridge paints a literal provider value unchanged", function()
		helpers.assert_eq(render_provider_row({ text = LITERAL, literal = true }), LITERAL)
	end)

	helpers.it("(programmable-preview-literal) ordinary provider values keep the token projection", function()
		helpers.assert_eq(render_provider_row("x{U+0041}"), "xA")
	end)
end)

return true
