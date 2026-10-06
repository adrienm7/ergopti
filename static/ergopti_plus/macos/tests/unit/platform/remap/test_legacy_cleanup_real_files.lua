--- tests/unit/platform/remap/test_legacy_cleanup_real_files.lua

--- ==============================================================================
--- MODULE: Legacy Cleanup Real-File Acceptance
--- DESCRIPTION:
--- Executes production cleanup over actual disposable bytes. Linux filesystem
--- SDK metadata/locks and JSON remain explicit fixtures, not native macOS proof.
--- ==============================================================================

local helpers = require("tests.helpers")
local with_fixture = require("tests.support.file_system_transaction_fixture").with_fixture
local lfs = require("lfs")
local repository = helpers.driver_root() .. "../../../"
local scenario = assert(loadfile(repository .. "tools/diagnostics/hs_legacy_cleanup_native.lua"))()
local corpus_file = assert(io.open(repository .. "tools/diagnostics/fixtures/karabiner-legacy-cleanup-acceptance.json", "rb"))
local corpus = assert(hs.json.decode(assert(corpus_file:read("*a"))))
assert(corpus_file:close())
local CASES = {
	"remove_two_signature_conflicts", "unchanged_second_request",
	"stale_destination_after_verified_backup", "existing_backup_name",
	"backup_readback_changed", "invalid_original_refuses",
}
assert(#corpus.case_ids == 6)
for index, id in ipairs(CASES) do assert(corpus.case_ids[index] == id) end

-- Actual context and adapter imports are borrowed for one complete case only.
local CONTEXT_MODULES = {
	"_generated.action_catalogue",
	"_generated.gesture_emit_actions",
	"_generated.logger_sub_files",
	"actions.assignable",
	"adapters.event_provenance",
	"adapters.json_codec",
	"adapters.key_state",
	"adapters.log_transport",
	"adapters.modifier_injector",
	"adapters.shell_runner",
	"adapters.storage",
	"adapters.synthetic_input",
	"adapters.task_environment",
	"adapters.timer_scheduler",
	"app_dirs",
	"app_parameter",
	"brightness_actions",
	"brightness_actions_data",
	"compat.utf8",
	"config_defaults",
	"config_outdated",
	"desktop_navigation",
	"diagnostics.operation_reporter",
	"diagnostics.runtime_log",
	"hotstrings.personal_files",
	"infra.config_paths",
	"infra.deferred_work",
	"infra.emergency_exit",
	"infra.keycodes",
	"infra.launcher_environment",
	"infra.log_folders",
	"infra.manifest_reader",
	"infra.notifications",
	"infra.script_chord_catalogue",
	"infra.termination_coordinator",
	"infra.toml.reader",
	"json",
	"keycodes",
	"keymap.control_signals",
	"llm.profile_selector",
	"llm.prompt_action",
	"llm.tone",
	"llm.vision",
	"modules.gestures.actions",
	"modules.gestures.actions_aux_owner",
	"modules.gestures.actions_click",
	"modules.gestures.sticky_modifiers",
	"modules.keymap.layout",
	"modules.shortcuts.actions.screen_capture_flow",
	"modules.shortcuts.actions.screenshot_save",
	"platform.remap.action_catalogue",
	"platform.remap.config",
	"platform.remap.defaults",
	"platform.remap.generator",
	"platform.remap.lease_contract",
	"platform.remap.legacy_release_fixtures",
	"platform.remap.managed_rule_removal",
	"platform.remap.nav_layer",
	"platform.remap.script_chord_rules",
	"script_chords",
	"send_input",
	"tap_hold.key_catalog",
	"text_utils",
	"toml_codec.basic_string",
	"toml_codec.bom",
	"toml_codec.key_path",
	"toml_codec.reader",
	"toml_codec.record_scanner",
	"wrap_pair",
}

helpers.describe("legacy cleanup actual file bytes and production adapter", function()
	for _, id in ipairs(CASES) do
		helpers.it(id, function()
			helpers.with_fresh_modules(CONTEXT_MODULES, function()
				with_fixture(function(fixture)
					local reserved = os.tmpname()
					assert(os.remove(reserved))
					local root = reserved .. "_legacy43"
					assert(fixture.HOST_MKDIR(root))
					local directory_owner, saved_directory_reader
					local outcome = table.pack(xpcall(function()
						local host = require("tests.stubs.hs")
						local adapter = fixture.make_adapter(nil, nil, nil, host.fs.link)
						package.loaded["adapters.file_system"] = adapter
						directory_owner, saved_directory_reader = hs.fs, hs.fs.dir
						-- SDK directory iteration is modeled by actual LuaFileSystem bytes.
						hs.fs.dir = lfs.dir
						local context = scenario.context(helpers.driver_root() .. "platform/remap/data/")
						return scenario.run_case(root, corpus, id, context)
					end, debug.traceback))
					if directory_owner then directory_owner.dir = saved_directory_reader end
					-- Inspect facts after the callback; only this exact disposable root is cleaned.
					for name in lfs.dir(root) do
						if name ~= "." and name ~= ".." then
							local path = root .. "/" .. name
							assert(lfs.symlinkattributes(path, "mode") == "file", "Unexpected retained staging debt")
							assert(os.remove(path))
						end
					end
					assert(fixture.HOST_RMDIR(root))
					if outcome[1] ~= true then error(outcome[2], 0) end
					helpers.assert_eq(outcome[2].id, id)
					helpers.assert_eq(outcome[2].passed, true)
				end)
			end)
		end)
	end
end)
