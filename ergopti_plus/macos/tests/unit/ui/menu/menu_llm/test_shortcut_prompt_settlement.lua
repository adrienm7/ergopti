--- tests/unit/ui/menu/menu_llm/test_shortcut_prompt_settlement.lua

--- ==============================================================================
--- MODULE: LLM Shortcut Prompt Settlement
--- DESCRIPTION:
--- Exercises the profile shortcut prompt and the real confirmed profile Delete
--- action through refusal-capable registrar seams, and pins the retirement of
--- the trigger submenu's dedicated shortcut row. Real Hammerspoon-shaped
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

	-- The dedicated trigger shortcut is retired: a prediction on demand is the
	-- llm_generate_prediction action in a keyboard slot (Ctrl+Space recommended),
	-- so the trigger submenu opens on its debounce row and prompts for no chord.
	helpers.it("the trigger submenu draws no dedicated shortcut row (llm-trigger-shortcut-retired)", function()
		local saved_app_picker = package.loaded["infra.app_picker"]
		local saved_i18n = package.loaded["infra.i18n"]
		local saved_logger = package.loaded["infra.logger"]
		local saved_manifest = package.loaded["infra.manifest_menu"]
		local saved_llm = package.loaded["modules.llm"]
		local saved_shortcuts = package.loaded["ui.menu.shortcut_utils"]
		local saved_panel = package.loaded["ui.menu.menu_llm.trigger_panel"]
		local prompts = 0
		local ok, err = xpcall(function()
			package.loaded["infra.app_picker"] = {build_menu = function() return {} end}
			package.loaded["infra.i18n"] = {get = function(key) return key end}
			package.loaded["infra.logger"] = helpers.make_logger_stub()
			package.loaded["infra.manifest_menu"] = assert(require("menu.renderer").new({
				platform = "hs",
				manifest_path = function() return helpers.driver_root() .. "../_shared/modules/menu/menu_manifest.json" end,
				json_decode = function(raw) return require("json").decode(raw) end,
				i18n = {get = function(key) return key end, section = function(key) return key end},
				logger = package.loaded["infra.logger"],
			}))
			package.loaded["modules.llm"] = {
				DEFAULT_STATE = {llm_debounce = 0.2},
			}
			package.loaded["ui.menu.shortcut_utils"] = {
				prompt_shortcut = function() prompts = prompts + 1 return false end,
				shortcut_to_label = function() return "None" end,
			}
			package.loaded["ui.menu.menu_llm.trigger_panel"] = nil
			local rows = require("ui.menu.menu_llm.trigger_panel").build({
				state = {llm_debounce = 0.2},
				is_disabled = false,
				settings_mgr = {},
			})
			helpers.assert_true(#rows > 0, "the trigger submenu must still draw its rows")
			helpers.assert_eq(rows[1].title, "menu.llm.debounce_label",
				"the debounce row now opens the trigger submenu")
			for _, row in ipairs(rows) do
				helpers.assert_true(row.title ~= "menu.llm.trigger_shortcut_label",
					"no row may prompt for a dedicated trigger shortcut")
				if type(row.fn) == "function" and row.title ~= "menu.llm.debounce_label" then
					row.fn()
				end
			end
			helpers.assert_eq(prompts, 0, "no row may open the shortcut prompt")
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
