--- tests/unit/ui/editors/lifecycle/test_native_close_release.lua

--- ==============================================================================
--- MODULE: Native Editor Close Reference Release
--- DESCRIPTION:
--- Runs four real controllers and the real factory against the packaged native
--- close contract. A red-button close must retire the native reference; an
--- explicit deferred delete must remain bound to its exact former window.
--- ==============================================================================

local helpers = require("tests.helpers")
require("core.logger.engine")

local EDITORS = {
	"ui.hotstring_editor", "ui.hotstrings_config_window", "ui.personal_info_editor", "ui.prompt_editor",
}

local function with_native_editor(name, scenario)
	return helpers.with_stub_scope({
		"ui.hotstring_editor", "ui.hotstring_editor.save_validation", "ui.hotstrings_config_window",
		"ui.personal_info_editor", "ui.prompt_editor", "ui.ui_builder", "ui.webview_close_owner", "core.events.timer_scheduler",
		"adapters.webview_result", "infra.deferred_work", "core.fs.engine.paths", "core.fs.engine.dir", "infra.notifications",
		"infra.toml.reader", "infra.toml.writer", "modules.hotstrings.hotstrings_config",
		"modules.hotstrings.hotstrings_config_schema", "adapters.hotkey_registrar", "keyboard.engine.chord",
		"infra.log_folders", "core.i18n.engine.core", "core.text.engine.json", "core.fs.adapters.json_codec", "diagnostics.engine.reports.redact",
		"core.ui.engine.window_titles", "core.ui.engine.webview.presentation", "core.lifecycle.engine.launcher_environment", "adapters.log_transport",
		"core.fs.engine.app_dirs", "infra.logger", "core.i18n.engine.locale", "_generated.logger_sub_files", "core.ui.engine.webview.i18n_seed",
		"tests.support.native_webview_close_fixture", "core.text.engine.utils_core", "lfs", "core.fs.engine.module_source_identity",
		"core.text.engine.toml_codec.writer", "core.text.engine.toml_codec.bom", "core.lifecycle.engine.compat.utf8", "core.text.engine.toml_codec.key_path", "core.text.engine.toml_codec.record_scanner",
		"settings.engine.migration.migrate", "core.text.engine.toml_codec.leaf_rows", "core.fs.engine.module_source_directory", "core.text.engine.toml_codec.reader",
		"core.text.engine.toml_codec.basic_string", "diagnostics.engine.operation_reporter", "core.fs.adapters.file_system",
		"hotstrings.engine.publication_recovery", "hotstrings.engine.delay_resolver", "hotstrings.engine.catalogue.personal_files",
		"hotstrings.engine.priority", "infra.toml.record_editor", "hotstrings.engine.extensions",
	}, function()
		local h = { windows = {}, retained = {}, deferred = {}, callbacks = {} }
		local construct = require("tests.support.native_webview_close_fixture")(h)
		local function new_window()
			local view = construct()
			function view:evaluateJavaScript() assert(not self.disposed); return self end
			return view
		end
		local editor = helpers.load_with_stubs(name, {
			webview = { new = new_window, windowMasks = { titled = 1, closable = 2, resizable = 8 },
				usercontent = { new = function()
					local bridge = {}
					function bridge:setCallback(callback) h.callbacks[self] = callback; return self end
					return bridge
				end } },
			drawing = { windowLevels = { normal = 0, floating = 3 } },
			focus = function() end,
			screen = { mainScreen = function()
				return { frame = function() return { x = 0, y = 0, w = 1400, h = 900 } end }
			end },
		})
		if name == "ui.hotstring_editor" then editor.init(helpers.shared("hotstrings/data/catalogue/defaults.toml"), {}) end
		function h.open() return editor.open({}, function() return true end) end
		function h.drain() h.drain_native_close() end
		scenario(editor, h)
	end)
end


--- LuaFileSystem's native loader also publishes a process global on cold load.
local function with_editor(name, scenario)
	local previous_lfs = rawget(_G, "lfs")
	rawset(_G, "lfs", nil)
	local outcome = table.pack(xpcall(function()
		return with_native_editor(name, scenario)
	end, debug.traceback))
	rawset(_G, "lfs", previous_lfs)
	if not outcome[1] then error(outcome[2], 0) end
	return table.unpack(outcome, 2, outcome.n)
end

helpers.describe("editors release their closed native windows", function()
	for _, name in ipairs(EDITORS) do
		helpers.it(name .. " releases native user close before reopening", function()
			with_editor(name, function(editor, h)
				helpers.assert_true(h.open())
				local first = h.windows[1]
				first:user_close()
				h.drain()
				helpers.assert_nil(h.retained[first], "native udRef survives dropping the controller's Lua owner")
				helpers.assert_eq(first.deletes, 1, "user close owns one deferred native delete")
				helpers.assert_true(h.open())
				local successor = h.windows[2]
				helpers.assert_true(h.retained[successor])
				helpers.assert_eq(successor.disposed, false)
				helpers.assert_true(editor.close())
				h.drain()
				helpers.assert_nil(next(h.retained))
			end)
		end)
		helpers.it(name .. " keeps explicit deferred deletion bound to the old window", function()
			with_editor(name, function(editor, h)
				helpers.assert_true(h.open())
				local first = h.windows[1]
				helpers.assert_true(editor.close())
				helpers.assert_eq(#h.deferred, 1)
				helpers.assert_true(h.retained[first], "native fade completion is still pending")
				helpers.assert_true(h.open())
				local successor = h.windows[2]
				h.drain()
				helpers.assert_nil(h.retained[first])
				helpers.assert_eq(first.deletes, 1)
				helpers.assert_true(h.retained[successor], "old native completion cannot consume the successor")
				helpers.assert_eq(successor.disposed, false)
				helpers.assert_true(editor.close())
				h.drain()
				helpers.assert_nil(next(h.retained))
			end)
		end)
	end
end)
