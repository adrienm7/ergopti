local root = assert(arg[1], 'source root argument required')
local linux = root .. '/static/ergopti_plus/linux'
package.path = linux..'/?.lua;'..linux..'/?/init.lua;'..root..'/static/ergopti_plus/_shared/lua/?.lua;'..root..'/static/ergopti_plus/_shared/lua/?/init.lua;'..package.path
require('test.runner_home').isolate()
require('compat.utf8').install()
require('infra.timings')
local H = require('tests.helpers')
H.initialize_timing()
local cases = {
 'tests.unit.ui.webview.test_webview_native_lifecycle',
 'tests.unit.ui.webview.test_webview_retired_bridge',
 'tests.unit.ui.webview.test_webview_page_messages',
 'tests.unit.ui.webview.test_webview_toggle',
 'tests.unit.ui.webview.test_webkit_host',
 'tests.unit.ui.editors.test_ui_bridge_handlers_personal_editor_fixture',
 'tests.unit.ui.personal_info_editor.test_personal_info_editor_close',
 'tests.unit.ui.personal_info_editor.test_personal_info_editor_payload',
 'tests.unit.ui.editors.action_picker.test_close_successor',
 'tests.unit.ui.downloads.test_document_lease_contract',
 'tests.unit.ui.downloads.test_managed_document_retirement',
 'tests.unit.infra.network.test_managed_http_deadline_native',
}
for _, name in ipairs(cases) do
 local ok, detail = pcall(require, name)
 assert(ok, name..': '..tostring(detail))
end
local results = H.get_results()
print('SCOPE_RECEIPT passed='..results.passed..' failed='..results.failed)
assert(results.failed == 0)
