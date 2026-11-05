local root='/workspace/worktrees/parity-sequential-2026-11-05/linux/static/ergopti_plus/'
package.path=root..'linux/?.lua;'..root..'linux/?/init.lua;'..root..'_shared/lua/?.lua;'..root..'_shared/lua/?/init.lua;'..package.path
require('compat.utf8').install();require('tests.support.secret_service_fake').isolate();require('tests.support.menu_part_reload').install()
local H=require('tests.helpers');H.initialize_timing();require('infra.timings')
for _,name in ipairs({
'tests.unit.modules.dynamic_hotstrings.test_dynamic_hotstrings_manager',
'tests.unit.modules.dynamic_hotstrings.test_personal_info_combo_resolver',
'tests.unit.modules.dynamic_hotstrings.test_dynamic_rule_families',
'tests.unit.modules.dynamic_hotstrings.test_dynamic_expansion_log_privacy',
'tests.unit.modules.dynamic_hotstrings.test_dynamic_destination',
'tests.unit.modules.dynamic_hotstrings.test_dynamic_multibyte_trigger',
'tests.unit.modules.dynamic_hotstrings.test_dynamic_unicode_suffix',
'tests.unit.modules.dynamic_hotstrings.test_dynamic_dry_run_dispatch',
'tests.unit.modules.hotstrings.engine.test_prefix_expansions',
'tests.unit.modules.hotstrings.preview.test_preview_masks_secrets',
'tests.unit.infra.test_personal_info_fields',
'tests.unit.infra.config.test_personal_info_policy_read',
'tests.unit.ui.personal_info_editor.test_personal_info_editor_payload',
'tests.unit.ui.personal_info_editor.test_personal_info_editor_close',
'tests.unit.ui.editors.test_ui_bridge_handlers_personal_editor_fixture',
'tests.unit.ui.menu.structure.test_menu_personal_info_source'}) do
local ok,err=H.measure_module(name,function() require(name) end);assert(ok,err)
end
local r=H.get_results();print('TARGETED passed='..r.passed..' failed='..r.failed);assert(r.failed==0)
