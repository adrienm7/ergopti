local root='/workspace/worktrees/parity-sequential-2026-11-05/linux/static/ergopti_plus/'
package.path=root..'linux/?.lua;'..root..'linux/?/init.lua;'..root..'_shared/lua/?.lua;'..root..'_shared/lua/?/init.lua;'..package.path
require('compat.utf8').install()
require('tests.support.secret_service_fake').isolate()
require('tests.support.menu_part_reload').install()
local H=require('tests.helpers'); H.initialize_timing()
require('infra.timings')
for _,name in ipairs({
'tests.unit.ui.metrics.test_wpm_readouts','tests.unit.ui.metrics.test_wpm_widget_persistence',
'tests.unit.adapters.system.test_wpm_surface_lifecycle','tests.unit.ui.menu.structure.test_metrics_widget_menu_parity',
'tests.unit.infra.preferences.test_metrics_preferences','tests.unit.infra.scope.test_metrics_scope'}) do
local ok,err=H.measure_module(name,function() require(name) end)
assert(ok,err)
end
local r=H.get_results(); print('TARGETED passed='..r.passed..' failed='..r.failed); assert(r.failed==0)
