--- tests/unit/modules/llm/backends/test_ai_runtime_selection_install_ollama_download_offer.lua

--- ==============================================================================
--- MODULE: AI Runtimes Install Only On Backend Selection
--- DESCRIPTION:
--- The app no longer bundles Ollama, and neither AI runtime may be fetched at
--- startup, when the AI is enabled with another backend, or after an update.
--- These cases drive the real resolver, both dependency checkers and the menu's
--- selection router against a fake filesystem and recorded native tasks:
--- 1. The resolver order (Ollama.app, ~/Applications, Homebrew, Ergopti's own
---    Application Support copy, PATH) and the retired ERGOPTI_OLLAMA_BIN.
--- 2. Boot checks and non-selection checks settle "missing" without a task.
--- 3. The first selection installs exactly once; a re-selection reuses it.
--- 4. The Ollama offer: accept downloads into the folder the resolver then
---    finds, decline opens the website and keeps the AI off with a message,
---    and a checksum failure surfaces the localized error.
--- 5. The typing path never reaches runtime detection.
--- ==============================================================================

local helpers = require("tests.helpers")
package.loaded["tests.support.modules.llm.backends.ai_runtime_selection_install_fixture"] = nil
local Fixture = require("tests.support.modules.llm.backends.ai_runtime_selection_install_fixture")
local MANAGED_BIN = Fixture.MANAGED_BIN
local MANAGED_DIR = Fixture.MANAGED_DIR
local fake_fs = Fixture.fake_fs
local load_ollama_checker = Fixture.load_ollama_checker
local new_state = Fixture.new_state
local scoped = Fixture.scoped
local set_upvalue = Fixture.set_upvalue
local task_api = Fixture.task_api





-- ========================================
-- ========================================
-- ======= 4/ Ollama Download Offer =======
-- ========================================
-- ========================================

helpers.describe("Ollama download offer (ai-runtime-offer)", function()
	local function load_offer(choice_key, record)
		local i18n = require("infra.i18n")
		package.loaded["infra.dialog_util"] = {
			block_alert = function(...)
				record.dialogs = record.dialogs + 1
				record.dialog_args = table.pack(...)
				record.dialog_history[#record.dialog_history + 1] = record.dialog_args
				if record.dialog_args[1] == i18n.get("ollama.native_offer_title") then
					return i18n.get("ollama.native_offer_keep")
				end
				return i18n.get(choice_key)
			end,
		}
		package.loaded["infra.notifications"] = {
			notify = function(title, body, kind, on_click)
				record.notices[#record.notices + 1] = { title = title, body = body, kind = kind, on_click = on_click }
				return true
			end,
		}
		package.loaded["ui.menu.menu_llm.runtime_install_offer"] = nil
		local Offer = helpers.load_with_stubs("ui.menu.menu_llm.runtime_install_offer", {
			fs = fake_fs(record.state),
			task = task_api(record.state),
			host = record.state.host,
			urlevent = { openURL = function(url) record.urls[#record.urls + 1] = url return true end },
		})
		-- The loader refreshes every ui.menu cache; bind the original model owner last.
		if record.state.model_manager then
			package.loaded["ui.menu.menu_llm.models_manager_ollama"] = record.state.model_manager
		end
		return Offer
	end

	local function new_record()
		return { dialogs = 0, dialog_history = {}, notices = {}, urls = {}, state = new_state() }
	end

	helpers.it("accepting downloads into the folder the resolver then finds", scoped(function()
		local record = new_record()
		local checker = load_ollama_checker(record.state)
		local Offer = load_offer("ollama.offer_download", record)
		package.loaded["modules.llm.ollama_deps_checker"] = checker
		local result
		helpers.assert_true(Offer.select_ollama(function(ok) result = ok end))
		helpers.assert_eq(record.dialogs, 1)
		helpers.assert_eq(#record.state.tasks, 1)
		helpers.assert_eq(record.state.tasks[1].args[6], MANAGED_DIR)
		record.state.executables[MANAGED_BIN] = true
		record.state.tasks[1].done(0, "", "")
		helpers.assert_eq(result, true)
		helpers.assert_true(Offer.is_installed("ollama"))

		helpers.assert_true(Offer.select_ollama())
		helpers.assert_eq(record.dialogs, 2, "a new migration choice never reuses the stock download consent")
		local i18n = require("infra.i18n")
		helpers.assert_eq(record.dialog_history[1][1], i18n.get("ollama.runtime_missing_title"))
		helpers.assert_eq(record.dialog_history[1][2], i18n.get("ollama.offer_body"))
		helpers.assert_eq(record.dialog_history[1][3], i18n.get("ollama.offer_download"))
		helpers.assert_eq(record.dialog_history[1][4], i18n.get("ollama.offer_website"))
		helpers.assert_eq(record.dialog_history[2][1], i18n.get("ollama.native_offer_title"))
		helpers.assert_eq(record.dialog_history[2][2], i18n.get("ollama.native_migration_body"))
		helpers.assert_eq(record.dialog_history[2][3], i18n.get("ollama.native_offer_install"))
		helpers.assert_eq(record.dialog_history[2][4], i18n.get("ollama.native_offer_keep"))
		helpers.assert_eq(record.state.tasks[2].args[5], MANAGED_BIN)
		helpers.assert_eq(record.state.tasks[2].args[6], "")
		record.state.tasks[2].done(0, "", "")
		helpers.assert_eq(record.state.daemon.calls, 0)
		helpers.assert_eq(#record.state.daemon_tasks, 0)
		helpers.assert_eq(checker.get_state(), "ready")
		helpers.assert_eq(checker.get_daemon_state(), "pending")
	end))

	helpers.it("declining opens the website and keeps the AI off with a message", scoped(function()
		local record = new_record()
		local checker = load_ollama_checker(record.state)
		local Offer = load_offer("ollama.offer_website", record)
		package.loaded["modules.llm.ollama_deps_checker"] = checker
		helpers.assert_eq(Offer.select_ollama(), false)
		helpers.assert_eq(record.dialogs, 1)
		helpers.assert_eq(#record.state.tasks, 0, "a decline never downloads")
		helpers.assert_eq(record.urls[1], "https://ollama.com/download")
		helpers.assert_eq(#record.notices, 1)
		helpers.assert_eq(record.notices[1].body,
			require("infra.i18n").get("ollama.runtime_missing_body"))
	end))

	helpers.it("a found Ollama is reused after its explicit native KEEP choice", scoped(function()
		local record = new_record()
		record.state.executables["/opt/homebrew/bin/ollama"] = true
		local checker = load_ollama_checker(record.state)
		local Offer = load_offer("ollama.offer_download", record)
		package.loaded["modules.llm.ollama_deps_checker"] = checker
		helpers.assert_true(Offer.select_ollama())
		helpers.assert_eq(record.dialogs, 1)
		local i18n = require("infra.i18n")
		helpers.assert_eq(record.dialog_args[1], i18n.get("ollama.native_offer_title"))
		helpers.assert_eq(record.dialog_args[2], i18n.get("ollama.native_migration_body"))
		helpers.assert_eq(record.dialog_args[3], i18n.get("ollama.native_offer_install"))
		helpers.assert_eq(record.dialog_args[4], i18n.get("ollama.native_offer_keep"))
		helpers.assert_eq(record.state.tasks[1].args[5], "/opt/homebrew/bin/ollama")
		helpers.assert_eq(record.state.tasks[1].args[6], "")
		record.state.tasks[1].done(0, "", "")
		helpers.assert_eq(record.state.daemon.calls, 0)
		helpers.assert_eq(#record.state.daemon_tasks, 0)
		helpers.assert_eq(checker.get_state(), "ready")
		helpers.assert_eq(checker.get_daemon_state(), "pending")
		helpers.assert_eq(checker.is_daemon_ready(), false)
	end))

	helpers.it("migration observes original HTTP, warmup, stream and model requirement debt", scoped(function()
		local record = new_record()
		record.state.executables["/opt/homebrew/bin/ollama"] = true
		local checker = load_ollama_checker(record.state)
		local Offer = load_offer("ollama.offer_download", record)
		package.loaded["modules.llm.ollama_deps_checker"] = checker
		helpers.assert_true(rawequal(require("ui.menu.menu_llm.models_manager_ollama"), record.state.model_manager),
			"the real router must consult this original model owner")
		helpers.assert_eq(#record.state.http_clients, 5)
		for _, client in ipairs(record.state.http_clients) do
			client.settled = false
			helpers.assert_eq(Offer.select_ollama(), false)
			helpers.assert_eq(record.dialogs, 0, "pending HTTP cleanup cannot lend migration authority")
			helpers.assert_eq(client.cancel_calls, 0, "the admission query cannot cancel another owner")
			client.settled = true
		end
		local api = record.state.api
		helpers.assert_true(set_upvalue(api.warmup, "_warmup_active", true))
		helpers.assert_eq(Offer.select_ollama(), false)
		helpers.assert_eq(record.dialogs, 0, "live warmup cannot lend migration authority")
		helpers.assert_true(set_upvalue(api.warmup, "_warmup_active", false))
		local stream_signals = 0
		local stream = { terminate = function() stream_signals = stream_signals + 1; return true, "pending" end }
		helpers.assert_true(set_upvalue(api.cancel_streaming, "_active_stream_task", stream))
		helpers.assert_eq(Offer.select_ollama(), false)
		helpers.assert_eq(record.dialogs, 0, "the original stream must be idle before migration")
		helpers.assert_eq(stream_signals, 0, "migration query cannot terminate a stream")
		helpers.assert_true(set_upvalue(api.cancel_streaming, "_active_stream_task", nil))
		record.state.model_requirement_pending = true
		helpers.assert_eq(record.state.model_manager.migration_idle(), false, "the requirement owner is pending")
		helpers.assert_eq(Offer.select_ollama(), false)
		helpers.assert_eq(record.dialogs, 0)
		record.state.model_requirement_pending = false
		record.state.model_tasks.original = {}
		helpers.assert_eq(record.state.model_manager.migration_idle(), false, "the original model task is pending")
		helpers.assert_eq(Offer.select_ollama(), false)
		helpers.assert_eq(record.dialogs, 0)
		record.state.model_tasks.original = nil
		helpers.assert_true(Offer.select_ollama())
		helpers.assert_eq(record.dialogs, 1)
		helpers.assert_eq(record.state.tasks[1].args[5], "/opt/homebrew/bin/ollama")
		helpers.assert_eq(record.state.tasks[1].args[6], "")
		record.state.tasks[1].done(0, "", "")
		helpers.assert_eq(record.state.daemon.calls, 0)
	end))

	helpers.it("a boot with the API backend posts no runtime notice", scoped(function()
		local record = new_record()
		local Offer = load_offer("ollama.offer_download", record)
		package.loaded["modules.llm.ollama_deps_checker"] = load_ollama_checker(record.state)
		helpers.assert_eq(Offer.notify_if_missing("api"), false)
		helpers.assert_eq(Offer.notify_if_missing("ollama"), true)
		helpers.assert_eq(record.dialogs, 0, "boot never shows the download offer")
		helpers.assert_eq(#record.state.tasks, 0, "boot never downloads")
	end))

	helpers.it("the boot notice of a missing Ollama opens its download offer when clicked", scoped(function()
		local record = new_record()
		local checker = load_ollama_checker(record.state)
		local Offer = load_offer("ollama.offer_download", record)
		package.loaded["modules.llm.ollama_deps_checker"] = checker
		helpers.assert_true(Offer.notify_if_missing("ollama"))
		helpers.assert_eq(#record.notices, 1)
		helpers.assert_eq(record.notices[1].body,
			require("infra.i18n").get("ollama.runtime_missing_click"),
			"the notice used to name the menu row to select, with no action of its own")
		-- Called below: a notice without its click fails there.
		helpers.assert_not_nil(record.notices[1].on_click,
			"the notice carries the click that opens its fix")
		helpers.assert_eq(record.dialogs, 0)
		helpers.assert_eq(#record.state.tasks, 0)
		record.notices[1].on_click()
		helpers.assert_eq(record.dialogs, 1, "the click opens the download offer, which asks first")
		helpers.assert_eq(#record.state.tasks, 1, "accepting the offer downloads Ollama")
		helpers.assert_eq(record.state.tasks[1].args[6], MANAGED_DIR)
		record.state.executables[MANAGED_BIN] = true
		record.state.tasks[1].done(0, "", "")

		record.notices[1].on_click()
		helpers.assert_eq(record.dialogs, 1, "a runtime installed since the notice offers nothing")
		helpers.assert_eq(#record.state.tasks, 1)
	end))
end)





-- ====================================
-- ====================================
-- ======= 5/ Trigger Ownership =======
-- ====================================
-- ====================================

helpers.describe("AI runtime triggers stay off the boot and typing paths (ai-runtime-triggers)", function()
	--- Counts `.install_for_selection(` calls in code, ignoring comments and the
	--- two checker definitions, so a new caller anywhere is visible.
	local function count_calls(text)
		local calls = 0
		for line in text:gmatch("[^\n]+") do
			local code = line:gsub("%-%-.*$", "")
			if not code:find("function M.install_for_selection(", 1, true) then
				for _ in code:gmatch("%.install_for_selection%(") do calls = calls + 1 end
			end
		end
		return calls
	end

	helpers.it("only the selection router grants a runtime install", function()
		local everywhere = helpers.read_driver_source("install_for_selection(")
		helpers.assert_not_nil(everywhere)
		local router, router_err = helpers.read_driver_unit("local function mlx_deps()")
		helpers.assert_not_nil(router, router_err)
		helpers.assert_eq(count_calls(router), 2, "the router owns one call per runtime")
		helpers.assert_eq(count_calls(everywhere), 2,
			"no boot, update, model or other-backend path may grant an install")
	end)

	helpers.it("boot schedules no checker for a remote API backend", function()
		local init, init_err = helpers.read_driver_unit("local function start_llm_bootstrap")
		helpers.assert_not_nil(init, init_err)
		local start = init:find("local function start_llm_bootstrap", 1, true)
		local body = init:sub(start, init:find("\nend\n", start, true))
		helpers.assert_true(body:find("and mlx_deps_checker or ollama_deps_checker", 1, true) == nil,
			"a non-MLX backend (API) must not fall through to the Ollama checker")
		helpers.assert_true(body:find("BACKEND_OLLAMA", 1, true) ~= nil)
		helpers.assert_true(body:find("install_for_selection", 1, true) == nil,
			"boot never grants a download")
	end)

	helpers.it("the typing path never probes for a runtime", function()
		for _, banner in ipairs({
			"--- MODULE: LLM Prediction Engine\n",
			"--- MODULE: LLM Streaming Handler\n",
			"--- MODULE: Keymap LLM Bridge\n",
		}) do
			local text, err = helpers.read_driver_unit(banner)
			helpers.assert_not_nil(text, err)
			for _, probe in ipairs({ "ollama_binary", "runtime_install_offer",
				".runtime_available(", ".runtime_installed(", "_deps_checker" }) do
				helpers.assert_true(text:find(probe, 1, true) == nil,
					banner .. " must not reach " .. probe)
			end
		end
	end)
end)
