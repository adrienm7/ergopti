-- Original public TapKeys/Reader/Hook and two genuine native Capture owners.
local root=assert(arg[1], 'Pass the repository root')
local here=assert(arg[0]:match('^(.*)/[^/]+$'))
local generated=arg[2] or here..'/generated'
local driver=root..'/static/ergopti_plus/linux'
package.path=driver..'/?.lua;'..driver..'/?/init.lua;'..root..'/static/ergopti_plus/_shared/lua/?.lua;'..root..'/static/ergopti_plus/_shared/lua/?/init.lua;'..package.path
require('compat.utf8').install();require('test.runner_home').isolate()
local h=require('tests.helpers');h.initialize_timing()
local modules={
 'tests.unit.adapters.layout.test_xkb_capture_exact_evdev_event',
 'tests.unit.adapters.layout.test_xkb_capture_semantic_controls',
 'tests.unit.adapters.layout.test_xkb_capture_direct_sources_retain',
 'tests.unit.adapters.keyboard_hook.test_keyboard_hook_xkb_capture_live_stream',
 'tests.unit.adapters.keyboard_hook.test_keyboard_hook_xkb_capture_position_native_effect',
 'tests.unit.modules.shortcuts.text_actions.test_tap_keys',
}
for _,name in ipairs(modules)do assert(require(name))end
local r=h.get_results();assert(r.passed>0);print('RESULT '..assert(require('json').encode({passed=r.passed,failed=r.failed,failures=r.failures,modules=modules})));os.exit(r.failed==0 and 0 or 1)
