--- tests/unit/meta/test_audit_senior_hs_fixes.lua

--- ==============================================================================
--- MODULE: Audit Senior Hammerspoon Regression Tests
--- DESCRIPTION:
--- Static source guards for the five bugs identified by the Hammerspoon expert
--- audit and fixed in the same commit:
---   1. MLX port 49317 hardcoded in shutdownCallback (init.lua)
---   2. script_watchers not stopped on shutdown (init.lua)
---   3. Scroll deadlock: process_frame crash leaves isBlockingScroll=true
---      (engine.lua + gestures/init.lua)
---   4. hs.chooser leak: old instance never :delete()'d (models_selector.lua)
---   5. http_client singleton cancels in-flight inference on health ping
---      (api_ollama.lua)
--- ==============================================================================

local helpers = require("tests.helpers")

-- Takes a selector unique to one production file rather than that file's
-- path, so moving or splitting a module cannot turn these invariants into
-- path errors.
local function read_source(selector)
	local src = helpers.read_driver_source(selector)
	return src
end

helpers.describe("Audit-senior Hammerspoon fixes", function()


	-- =========================================
	-- ===== 1) MLX port — no hardcoded 49317
	-- =========================================

	helpers.it("the MLX orphan kill must not hard-code port 49317 (resolved via get_port)", function()
		-- The bug: lsof -tiTCP:49317 regardless of user-configured port.
		-- The fix: resolve port via api_mlx.get_port(). The sweep moved into the shared
		-- menu_llm.terminate_orphan_mlx_server() (called by BOTH the shutdown callback
		-- and script_quit) so the two quit paths cannot drift (F-M7).
		local init_src = read_source("local function has_common_hotstring_groups") -- init.lua
		assert(init_src, "init.lua must be readable")
		assert(not init_src:find("tiTCP:49317", 1, true),
			"init.lua: must not hard-code port 49317")
		assert(init_src:find("terminate_orphan_mlx_server", 1, true),
			"init.lua: shutdownCallback must delegate to the shared terminate_orphan_mlx_server")

		local menu_src = read_source("local function format_shortcut_title") -- ui/menu/menu_llm/init.lua
		assert(menu_src, "menu_llm/init.lua must be readable")
		assert(not menu_src:find("tiTCP:49317", 1, true),
			"menu_llm: terminate_orphan_mlx_server must not hard-code port 49317")
		assert(menu_src:find("get_port", 1, true),
			"menu_llm: terminate_orphan_mlx_server must resolve the live MLX port via get_port()")
	end)


	-- ==================================================
	-- ===== 2) script_watchers — explicit :stop() loop
	-- ==================================================

	helpers.it("init.lua shutdownCallback must stop all script_watchers", function()
		local src = read_source("local function has_common_hotstring_groups") -- init.lua
		assert(src, "init.lua must be readable")
		-- The bug: _G.script_watchers pinned to prevent GC but never :stop()'d.
		-- The fix: loop over the table and pcall w:stop() in shutdownCallback.
		assert(
			src:find("script_watchers", 1, true) and src:find(":stop()", 1, true),
			"init.lua: shutdownCallback must iterate _G.script_watchers and call :stop() on each"
		)
	end)


	-- ============================================================
	-- ===== 3a) Scroll deadlock — M.emergency_reset() exported
	-- ============================================================

	helpers.it("engine.lua must export M.emergency_reset() for scroll unblock on crash", function()
		local src = read_source("local function triggerLiveAxisIfNeeded") -- modules/gestures/engine.lua
		assert(src, "modules/gestures/engine.lua must be readable")
		-- The bug: process_frame can crash after startScrollBlock(); isBlockingScroll
		-- stays true forever because no cleanup runs on the error path.
		-- The fix: export M.emergency_reset() which calls resetGS() (and thus
		-- stopScrollBlock()), giving the frame-callback error handler a safe hook.
		assert(
			src:find("function M%.emergency_reset", 1, false),
			"engine.lua: M.emergency_reset() must be exported so the frame-callback " ..
			"error path can force a scroll unblock"
		)
		assert(
			src:find("resetGS()", 1, true),
			"engine.lua: M.emergency_reset() must call resetGS() to clear isBlockingScroll"
		)
	end)


	-- ======================================================================
	-- ===== 3b) Scroll deadlock — error path in gestures/init.lua calls it
	-- ======================================================================

	helpers.it("gestures/init.lua frame callback must call emergency_reset on process_frame error", function()
		local src = read_source("local function schedule_emergency_recycle") -- modules/gestures/init.lua
		assert(src, "modules/gestures/init.lua must be readable")
		-- The fix adds: if not Logger.pcall(...) then pcall(Engine.emergency_reset) end
		assert(
			src:find("Engine%.emergency_reset", 1, false),
			"gestures/init.lua: frame callback must call Engine.emergency_reset " ..
			"when process_frame throws, to prevent permanent scroll deadlock"
		)
	end)


	-- =====================================================================
	-- ===== 4) Chooser leak — stale instance deleted before new creation
	-- =====================================================================

	helpers.it("models_selector.lua must delete old chooser before creating a new one", function()
		local src = read_source("\"Failed to create usercontent bridge for custom model dialog.\"") -- ui/menu/menu_llm/models_selector.lua
		assert(src, "models_selector.lua must be readable")
		-- The bug: _model_browser_chooser is overwritten without calling :delete(),
		-- leaking the previous C-backed hs.chooser object into process memory.
		-- The fix: explicitly delete the stale instance before reassigning.
		assert(
			src:find("stale:delete()", 1, true) or src:find("_model_browser_chooser.*:delete", 1, false),
			"models_selector.lua: must call :delete() on the old chooser before " ..
			"creating a new one to prevent native object leaks"
		)
	end)


	-- ====================================================================
	-- ===== 5) HTTP client singleton — split into infer + check clients
	-- ====================================================================

	helpers.it("api_ollama.lua must use separate _infer_client and _check_client", function()
		local src = read_source("local function read_ollama_port_override") -- modules/llm/api_ollama.lua
		assert(src, "modules/llm/api_ollama.lua must be readable")
		-- The bug: a single HttpClient is reused for both inference POST /api/chat
		-- and health-check GET /api/tags. A background ping would cancel any
		-- in-flight completion request, leaving the UI frozen.
		-- The fix: two independent clients.
		assert(
			not src:find("local HttpClient%s*=", 1, false),
			"api_ollama.lua: must not use a single shared HttpClient — " ..
			"split into _infer_client and _check_client"
		)
		assert(
			src:find("_infer_client", 1, true),
			"api_ollama.lua: must declare _infer_client for inference POST calls"
		)
		assert(
			src:find("_check_client", 1, true),
			"api_ollama.lua: must declare _check_client for health-check GET calls"
		)
		assert(
			src:find("_check_client%.get", 1, false),
			"api_ollama.lua: check_availability() must use _check_client.get, not the shared client"
		)
		assert(
			src:find("_infer_client%.post", 1, false),
			"api_ollama.lua: inference calls must use _infer_client.post, not the shared client"
		)
	end)

end)
