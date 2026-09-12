--- tests/unit/ui/menu/menu_llm/test_shortcut_prompt_settlement.lua

--- ==============================================================================
--- MODULE: LLM Shortcut Prompt Settlement
--- DESCRIPTION:
--- Exercises the primary/profile shortcut owner and the real confirmed profile
--- Delete action through refusal-capable registrar seams. Real Hammerspoon-shaped
--- doubles keep enable=self|nil, disable=self, and delete=void|throw contracts.
--- Tests preserve handle identity and invoke retained callbacks so a
--- bookkeeping-only rollback cannot pass.
--- ==============================================================================

local helpers = require("tests.helpers")

local Fixture = require("tests.support.profile_delete_fixture")
local with_delete_fixture = Fixture.with_delete_fixture

--- Loads the real shared shortcut prompt around a deterministic dialog result.
--- @param raw string Prompt input.
--- @param body function Test callback receiving the real utility.
local function with_real_shortcut_prompt(raw, body)
	local saved_dialog = package.loaded["infra.dialog_util"]
	local saved_i18n = package.loaded["infra.i18n"]
	local saved_logger = package.loaded["infra.logger"]
	local saved_shortcuts = package.loaded["ui.menu.shortcut_utils"]
	local ok, err = xpcall(function()
		package.loaded["infra.dialog_util"] = {
			text_prompt = function() return "OK", raw end,
			alert = function() return true end,
		}
		package.loaded["infra.i18n"] = {get = function(key) return key end}
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["ui.menu.shortcut_utils"] = nil
		body(require("ui.menu.shortcut_utils"))
	end, debug.traceback)
	package.loaded["infra.dialog_util"] = saved_dialog
	package.loaded["infra.i18n"] = saved_i18n
	package.loaded["infra.logger"] = saved_logger
	package.loaded["ui.menu.shortcut_utils"] = saved_shortcuts
	if not ok then error(err, 0) end
end

helpers.describe("HS-033 shortcut prompt settlement propagation", function()
	for _, raw in ipairs({"ctrl+b", ""}) do
		for _, outcome in ipairs({"false", "nil", "throw"}) do
			helpers.it("HS-033 prompt returns refusal for " .. outcome .. " callback on '" .. raw .. "'", function()
				with_real_shortcut_prompt(raw, function(shortcuts)
					local function refuse()
						if outcome == "throw" then error("apply refused", 0) end
						if outcome == "false" then return false end
						return nil
					end
					helpers.assert_eq(shortcuts.prompt_shortcut({on_apply = refuse}), false)
				end)
			end)
		end
	end

	helpers.it("HS-033 prompt reports literal committed callback success", function()
		with_real_shortcut_prompt("ctrl+b", function(shortcuts)
			helpers.assert_eq(shortcuts.prompt_shortcut({
				on_apply = function() return true end,
			}), true)
		end)
	end)

	helpers.it("HS-033 profile shortcut menu action propagates prompt refusal", function()
		with_delete_fixture({active_profile = "basic"},
			function(_, _, _, shortcut_action)
				package.loaded["ui.menu.shortcut_utils"].prompt_shortcut = function()
					return false
				end
				helpers.assert_eq(shortcut_action(), false)
			end)
	end)

	helpers.it("HS-033 primary shortcut menu action propagates prompt refusal", function()
		local saved_app_picker = package.loaded["infra.app_picker"]
		local saved_i18n = package.loaded["infra.i18n"]
		local saved_logger = package.loaded["infra.logger"]
		local saved_manifest = package.loaded["infra.manifest_menu"]
		local saved_llm = package.loaded["modules.llm"]
		local saved_shortcuts = package.loaded["ui.menu.shortcut_utils"]
		local saved_panel = package.loaded["ui.menu.menu_llm.trigger_panel"]
		local ok, err = xpcall(function()
			package.loaded["infra.app_picker"] = {build_menu = function() return {} end}
			package.loaded["infra.i18n"] = {get = function(key) return key end}
			package.loaded["infra.logger"] = helpers.make_logger_stub()
			package.loaded["infra.manifest_menu"] = {render_rows = function(rows) return rows end}
			package.loaded["modules.llm"] = {
				DEFAULT_STATE = {llm_debounce = 0.2},
			}
			package.loaded["ui.menu.shortcut_utils"] = {
				prompt_shortcut = function() return false end,
				shortcut_to_label = function() return "None" end,
			}
			package.loaded["ui.menu.menu_llm.trigger_panel"] = nil
			local rows = require("ui.menu.menu_llm.trigger_panel").build({
				state = {},
				is_disabled = false,
				settings_mgr = {},
				apply_llm_shortcut = function() return false end,
			})
			helpers.assert_type(rows[1] and rows[1].action, "function")
			helpers.assert_eq(rows[1].action(), false)
		end, debug.traceback)
		package.loaded["infra.app_picker"] = saved_app_picker
		package.loaded["infra.i18n"] = saved_i18n
		package.loaded["infra.logger"] = saved_logger
		package.loaded["infra.manifest_menu"] = saved_manifest
		package.loaded["modules.llm"] = saved_llm
		package.loaded["ui.menu.shortcut_utils"] = saved_shortcuts
		package.loaded["ui.menu.menu_llm.trigger_panel"] = saved_panel
		if not ok then error(err, 0) end
	end)
end)

return true
