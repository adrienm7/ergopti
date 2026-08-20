--- tests/unit/ui/menu/menu_llm/test_settings_mlx_port.lua

--- ==============================================================================
--- MODULE: settings_manager — MLX server port configuration
--- DESCRIPTION:
--- Locks down the menu handler that lets the user move Ergopti's MLX server off the
--- dedicated default port. set_mlx_port() prompts, validates against api_mlx's port
--- bounds, applies via api_mlx.set_port (which persists to hs.settings + rebuilds the
--- server URL), and only then fires on_applied (the server relaunch). reset_mlx_port()
--- restores the dedicated default. The contract under test:
---   * a valid port is applied AND on_applied fires;
---   * an out-of-range port is rejected — no change, no relaunch;
---   * empty input resets to the dedicated default;
---   * reset_mlx_port restores the default and fires on_applied.
---
--- FEATURES & RATIONALE:
--- 1. Dialog stub: lib.dialog_util is replaced BEFORE requiring settings_manager so
---    the prompt returns a scripted value; restored afterwards for downstream tests.
--- 2. The stub echoes the OK-button label it is handed, so the handler's
---    `btn == i18n.get("button.ok")` gate passes regardless of the harness locale.
--- ==============================================================================

local helpers = require("tests.helpers")

-- Scripted dialog: text_prompt(title, msg, default, ok_label, cancel_label) returns
-- (ok_label, value). Echoing ok_label makes the handler's OK-gate pass locale-free.
local prompt_value = { "54321" }
local _real_dialog = package.loaded["infra.dialog_util"]
package.loaded["infra.dialog_util"] = {
	text_prompt = function(_title, _msg, _default, ok_label, _cancel_label)
		return ok_label, prompt_value[1]
	end,
}

package.loaded["ui.menu.menu_llm.settings_manager"] = nil
local Settings = require("ui.menu.menu_llm.settings_manager")

package.loaded["modules.llm.api_mlx"] = nil
local ApiMlx = require("modules.llm.api_mlx")

local function make_settings(update_menu)
	local deps = {
		state       = { llm_backend = "mlx" },
		save_prefs  = function() end,
		update_menu = update_menu or function() end,
		keymap      = nil,
	}
	return Settings.new(deps)
end




-- =========================================================
-- =========================================================
-- ======= 1/ set_mlx_port / reset_mlx_port =================
-- =========================================================
-- =========================================================

helpers.describe("settings_manager — MLX port configuration", function()
	helpers.it("exposes set_mlx_port and reset_mlx_port", function()
		local s = make_settings()
		helpers.assert_eq(type(s.set_mlx_port), "function")
		helpers.assert_eq(type(s.reset_mlx_port), "function")
	end)

	helpers.it("set_mlx_port applies a valid port and fires on_applied", function()
		ApiMlx.set_port(ApiMlx.get_default_port())
		prompt_value[1] = "54321"
		local applied = false
		make_settings().set_mlx_port(function() applied = true end)
		helpers.assert_eq(ApiMlx.get_port(), 54321)
		helpers.assert_true(applied, "on_applied must fire after a successful change")
	end)

	helpers.it("set_mlx_port rejects an out-of-range port — no change, no on_applied", function()
		ApiMlx.set_port(54321)
		prompt_value[1] = "80"  -- below the 1024 minimum
		local applied = false
		make_settings().set_mlx_port(function() applied = true end)
		helpers.assert_eq(ApiMlx.get_port(), 54321)
		helpers.assert_true(applied == false, "on_applied must NOT fire on invalid input")
	end)

	helpers.it("empty input resets to the dedicated default", function()
		ApiMlx.set_port(54321)
		prompt_value[1] = "   "
		make_settings().set_mlx_port(nil)
		helpers.assert_eq(ApiMlx.get_port(), ApiMlx.get_default_port())
	end)

	helpers.it("reset_mlx_port restores the dedicated default and fires on_applied", function()
		ApiMlx.set_port(54321)
		local applied = false
		make_settings().reset_mlx_port(function() applied = true end)
		helpers.assert_eq(ApiMlx.get_port(), ApiMlx.get_default_port())
		helpers.assert_true(applied, "on_applied must fire after reset")
	end)

	helpers.it("refreshes the menu after a throwing apply callback and returns false (HS-016)", function()
		local Logger = require("infra.logger")
		Logger.ring_buffer_clear()
		ApiMlx.set_port(ApiMlx.get_default_port())
		prompt_value[1] = "54321"
		local refreshes = 0
		local settings = make_settings(function() refreshes = refreshes + 1 end)
		local result = settings.set_mlx_port(function() error("port apply exploded") end)
		local matching = 0
		for _, line in ipairs(Logger.ring_buffer_snapshot()) do
			if line:find("[ERROR]", 1, true)
				and line:find("MLX port apply", 1, true)
				and line:find("port apply exploded", 1, true)
				and line:find("stack traceback", 1, true) then
				matching = matching + 1
			end
		end

		helpers.assert_eq(result, false,
			"a thrown apply callback cannot publish a successful settings action")
		helpers.assert_eq(refreshes, 1,
			"menu refresh is finally-style cleanup after the port itself committed")
		helpers.assert_eq(matching, 1)
	end)
end)

-- Restore real modules so downstream test files see production wiring.
package.loaded["infra.dialog_util"] = _real_dialog
package.loaded["ui.menu.menu_llm.settings_manager"] = nil
package.loaded["modules.llm.api_mlx"] = nil
