--- tests/unit/ui/menu/menu_llm/test_models_manager_mlx_adopt.lua

--- ==============================================================================
--- MODULE: MLX Models Manager — cross-session server adoption regression
--- DESCRIPTION:
--- Locks down start_server's cross-session adoption path. After a Hammerspoon
--- reload the in-memory hs.task handle is gone, but the detached Python MLX
--- server from the previous session is still listening on :8080 with the model
--- already resident in GPU memory. start_server must ADOPT that live server
--- (probe /v1/models, confirm it serves the target model, call on_success) and
--- skip the destructive port-8080 sweep + cold reload — otherwise every reload
--- kills a healthy server and pays a 45-90 s cold start ("rond rouge / jaune
--- trop longtemps au démarrage").
---
--- The bug: reuse was gated only on in-memory state (deps.active_tasks +
--- obj._server_target), both wiped on reload, so the live server was never
--- detected before the sweep destroyed it.
---
--- FEATURES & RATIONALE:
--- 1. Adoption path is observable without a live MLX server: the adopt branch
---    uses hs.execute (sync curl) and returns BEFORE any hs.task.new, whereas
---    the sweep + relaunch path calls hs.task.new. So "task launched?" cleanly
---    distinguishes adopt from cold-restart.
--- ==============================================================================

local helpers = require("tests.helpers")

-- A prior test (e.g. test_backend_detector_respects_user_override) may have
-- installed a minimal api_mlx stub that lacks get_port, which models_manager_mlx
-- calls at module level. Clear it so the real implementation is loaded fresh.
--
-- The server-lifecycle sibling (models_manager_mlx_server) must ALSO be cleared:
-- start_server lives there since the models-manager split, and that module captures
-- `local hs = hs` at load time. A prior load_with_stubs test swaps the _G.hs
-- TABLE, so a stale server module would call the old hs.execute/hs.task (whose
-- defaults return ""), and the `hs.execute`/`hs.task.new` stubs this test sets on
-- the current _G.hs would never be seen. Reloading re-captures the current _G.hs.
package.loaded["modules.llm.api_mlx"]                      = nil
package.loaded["ui.menu.menu_llm.models_manager_mlx"]       = nil
package.loaded["ui.menu.menu_llm.models_manager_mlx_server"] = nil
local MlxMgr = require("ui.menu.menu_llm.models_manager_mlx")

-- /v1/models payload shape mlx_lm.server returns; id carries the HF repo path.
local function models_body(repo)
	return '{"object":"list","data":[{"id":"' .. repo .. '","object":"model"}]}'
end

--- Builds a manager bound to a no-op deps table with an empty active_tasks map
--- (mirrors the post-reload state: no in-memory server handle).
local function make_manager()
	local deps = {
		active_tasks  = {},
		update_icon   = function(_) end,
		reset_menubar = function() end,
		save_prefs    = function() end,
		update_menu   = function() end,
		state         = { llm_backend = "mlx" },
		keymap        = nil,
	}
	return MlxMgr.new(deps, {})
end

--- Swaps hs.execute + hs.task.new for the duration of fn, capturing how many
--- server tasks were launched. Restores the originals afterwards.
--- @param exec_stdout string The body hs.execute returns for the /v1/models probe.
--- @param fn function Receives a table with a live `task_count` field.
local function with_probe(exec_stdout, fn)
	local hs = _G.hs
	local prev_exec = hs.execute
	local prev_task_new = hs.task.new
	local ctx = { task_count = 0 }

	hs.execute = function(_cmd) return exec_stdout end
	hs.task.new = function(_bin, _cb, _args)
		ctx.task_count = ctx.task_count + 1
		return {
			start     = function() end,
			terminate = function() end,
			isRunning = function() return false end,
		}
	end

	local ok, err = pcall(fn, ctx)

	hs.execute = prev_exec
	hs.task.new = prev_task_new
	return ok, err, ctx
end





-- =====================================================
-- =====================================================
-- ======= 1/ Adoption of a live previous server =======
-- =====================================================
-- =====================================================

helpers.describe("models_manager_mlx — cross-session adoption", function()
	helpers.it("adopts a running server that already serves the target model (no relaunch)", function()
		local mgr = make_manager()
		-- Repo-path model name passes straight through get_mlx_repo (no presets needed).
		local target = "test-org/AdoptModel-4bit"
		local on_success_called = false

		local ok, err, ctx = with_probe(models_body("test-org/AdoptModel-4bit"), function()
			mgr.start_server(target, function() on_success_called = true end, function() end,
				{ silent_notifications = true })
		end)

		helpers.assert_true(ok, "start_server must not throw on the adoption path: " .. tostring(err))
		helpers.assert_true(on_success_called, "adoption must call on_success so the prediction lock is released")
		helpers.assert_eq(ctx.task_count, 0, "adoption must NOT launch a server task (no sweep, no cold restart)")
	end)

	helpers.it("does NOT adopt when no server is listening — falls through to relaunch", function()
		local mgr = make_manager()
		local target = "test-org/AdoptModel-4bit"
		local on_success_called = false

		-- Empty body = connection refused (curl prints nothing); must not be mistaken
		-- for a live server. The relaunch path is expected to spawn at least the
		-- port-8080 sweep task; downstream launch may error under stubs (no venv),
		-- which is fine — we only assert it attempted a relaunch and did not adopt.
		local _ok, _err, ctx = with_probe("", function()
			mgr.start_server(target, function() on_success_called = true end, function() end,
				{ silent_notifications = true })
		end)

		helpers.assert_true(not on_success_called, "must not adopt (call on_success) when no live server matches")
		helpers.assert_true(ctx.task_count >= 1, "with no live server, start_server must attempt a relaunch (sweep/launch task)")
	end)

	helpers.it("does NOT adopt a server serving a DIFFERENT model — relaunches for the target", function()
		local mgr = make_manager()
		local target = "test-org/AdoptModel-4bit"
		local on_success_called = false

		-- A live server, but for another model: adopting it would serve wrong predictions.
		local _ok, _err, ctx = with_probe(models_body("other-org/SomethingElse-8bit"), function()
			mgr.start_server(target, function() on_success_called = true end, function() end,
				{ silent_notifications = true })
		end)

		helpers.assert_true(not on_success_called, "must not adopt a server running a different model")
		helpers.assert_true(ctx.task_count >= 1, "model mismatch must trigger a relaunch, not adoption")
	end)
end)
