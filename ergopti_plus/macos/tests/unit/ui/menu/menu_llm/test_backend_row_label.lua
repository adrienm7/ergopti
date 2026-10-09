--- tests/unit/ui/menu/menu_llm/test_backend_row_label.lua

--- ==============================================================================
--- MODULE: The Backend Row Names The Selected Option
--- DESCRIPTION:
--- Regression backend-row-selected-option. The AI menu's Backend row read
--- « Moteur IA (Backend) : » and a second copy of the backend's brand. The
--- maintainer asked on 2026-09-30 for the option selected in the Backend
--- submenu itself, cut before its em dash, emoji included: « MLX 🚀 »,
--- « Ollama 🦙 », « API 🌐 », or a local server's name when its row is ticked.
--- These cases build the real backend rows and read the expected text from the
--- ticked option, so the row cannot drift from the submenu again.
--- ==============================================================================

local helpers = require("tests.helpers")

local OWNED_MODULES = {
	"modules.llm", "infra.i18n", "infra.logger", "infra.manifest_menu",
	"infra.dialog_util", "infra.notifications", "modules.llm.ollama_binary",
	"modules.llm.mlx_deps_checker", "modules.llm.ollama_deps_checker",
	"ui.menu.menu_llm.runtime_install_offer", "ui.menu.menu_llm.backend_panel",
	"ui.menu.menu_llm.backend_labels", "ui.menu.menu_llm.mlx_repair_offer",
	"modules.llm.mlx_bootstrap_diagnosis", "infra.deferred_work",
	"modules.llm.backend_detector",
}

--- A runtime checker double that reports its runtime installed.
--- @return table checker
local function installed_checker()
	return {
		check_and_install_deps = function(on_complete) if on_complete then on_complete(true) end return true end,
		install_for_selection = function(on_complete) if on_complete then on_complete(true) end return true end,
		runtime_available = function() return true end,
		runtime_installed = function() return true end,
		is_task_running = function() return false end,
	}
end

--- Builds the real Backend row and submenu for one selected backend.
--- @param backend string The selected backend.
--- @param local_rows table|nil Rows the local server panel would add.
--- @return string title, table rows, table warnings
local function build(backend, local_rows)
	local title, rows
	local warnings = {}
	helpers.with_fresh_modules(OWNED_MODULES, function()
		package.loaded["modules.llm"] = {
			DEFAULT_STATE = { llm_model_mlx = "mlx-default", llm_model_ollama = "ollama-default" },
			get_backend = function() return backend end,
			set_backend = function() return true end,
			load_api_entries = function() return true end,
		}
		package.loaded["infra.i18n"] = {
			get = function(key) return key end,
			format = function(key) return key end,
		}
		local logger = helpers.make_logger_stub()
		logger.warn = function(_, message) warnings[#warnings + 1] = message end
		package.loaded["infra.logger"] = logger
		package.loaded["infra.manifest_menu"] = { render_rows = function(items) return items end }
		package.loaded["infra.notifications"] = { notify = function() return true end }
		package.loaded["infra.dialog_util"] = { block_alert = function() return "" end }
		package.loaded["modules.llm.mlx_deps_checker"] = installed_checker()
		package.loaded["modules.llm.ollama_deps_checker"] = installed_checker()
		local previous_execute = os.execute
		local previous_hs_execute = hs.execute
		os.execute = function() return true end
		hs.execute = function() return "arm64" end
		local ok, err = xpcall(function()
			local BackendPanel = require("ui.menu.menu_llm.backend_panel")
			title, rows = BackendPanel.build({
				state = { llm_backend = backend, llm_model = "", llm_model_mlx = "", llm_model_ollama = "" },
				keymap = { set_llm_backend_name = function() return true end },
				paused = false,
				models_mgr = {},
				get_display_model_name = function(name) return name end,
				switch_model = function() return true end,
				disable_model = function() return true end,
				save_prefs = function() return true end,
				update_menu = function() return true end,
				WarmupCtrl = { warmup = function() return true end },
				reset_llm_health_status = function() return true end,
				local_server_rows = local_rows and function() return local_rows end or nil,
			})
		end, debug.traceback)
		os.execute = previous_execute
		hs.execute = previous_hs_execute
		if not ok then error(err, 0) end
	end)
	return title, rows, warnings
end

--- The label of the last ticked row, cut before its em dash, independently of
--- the module under test.
--- @param rows table Backend submenu rows.
--- @return string|nil
local function ticked_head(rows)
	local label = nil
	for _, row in ipairs(rows) do
		if row.checked then label = row.label end
	end
	if not label then return nil end
	local dash = label:find("—", 1, true)
	helpers.assert_true(dash ~= nil, "the ticked option carries a description after an em dash: " .. label)
	return (label:sub(1, dash - 1):gsub("%s+$", ""))
end

helpers.describe("The Backend row names the selected option (backend-row-selected-option)", function()
	for backend, expected in pairs({ mlx = "MLX 🚀", ollama = "Ollama 🦙", api = "API 🌐" }) do
		helpers.it("reads « " .. expected .. " » with the " .. backend .. " backend", function()
			local title, rows = build(backend)
			helpers.assert_eq(title, expected, "the row names the selected option, emoji included")
			helpers.assert_eq(title, ticked_head(rows), "the row is the ticked option cut before its em dash")
		end)
	end

	helpers.it("names a ticked local server rather than the API row above it", function()
		local title, rows = build("api", {
			{ separator = true },
			{ label = "LM Studio 🖥️ — localhost:1234", checked = true, items = {} },
		})
		helpers.assert_eq(title, "LM Studio 🖥️")
		helpers.assert_eq(title, ticked_head(rows))
	end)

	helpers.it("says the backend is unknown when no option is ticked", function()
		local title, _, warnings = build("retired")
		helpers.assert_eq(title, "menu.llm.backend_unknown")
		helpers.assert_eq(#warnings, 1, "the unknown backend is reported once")
	end)
end)

helpers.describe("An option's head (backend-row-selected-option)", function()
	helpers.it("stops at the first em dash and keeps a label without one whole", function()
		local BackendLabels = helpers.with_fresh_modules({ "ui.menu.menu_llm.backend_labels" }, function()
			return require("ui.menu.menu_llm.backend_labels")
		end)
		helpers.assert_eq(BackendLabels.head("MLX 🚀 — Recommandé — natif"), "MLX 🚀")
		helpers.assert_eq(BackendLabels.head("  Sans tiret  "), "Sans tiret")
	end)
end)

return true
