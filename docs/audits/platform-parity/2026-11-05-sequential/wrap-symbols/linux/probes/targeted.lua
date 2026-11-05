local root='/workspace/worktrees/parity-sequential-2026-11-05/linux/static/ergopti_plus/'
package.path=root..'linux/?.lua;'..root..'linux/?/init.lua;'..root..'_shared/lua/?.lua;'..root..'_shared/lua/?/init.lua;'..package.path
require('compat.utf8').install()
require('tests.support.secret_service_fake').isolate()
require('tests.support.menu_part_reload').install()
local H=require('tests.helpers');H.initialize_timing();require('infra.timings')
for _,name in ipairs({
'tests.unit.modules.shortcuts.text_actions.test_wrap_pair_parameter_vectors',
'tests.unit.modules.shortcuts.text_actions.test_wrap_on_type',
'tests.unit.modules.shortcuts.text_actions.test_wrap_output_owner',
'tests.unit.infra.scope.test_shortcuts_scope_configured_wrap_symbol',
'tests.unit.adapters.synthetic_input.test_clipboard_selection_transaction',
'tests.unit.adapters.synthetic_input.test_clipboard_failure_atomic',
'tests.unit.adapters.synthetic_input.test_clipboard_partial_write',
'tests.unit.adapters.synthetic_input.test_clipboard_snapshot_restorability',
'tests.unit.adapters.synthetic_input.test_clipboard_prepared_stage',
'tests.unit.adapters.synthetic_input.test_selected_output_range',
'tests.unit.modules.hotstrings.injector.test_selected_output_custody'}) do
local ok,err=H.measure_module(name,function() require(name) end);assert(ok,err)
end
local r=H.get_results();print('TARGETED passed='..r.passed..' failed='..r.failed);assert(r.failed==0)
