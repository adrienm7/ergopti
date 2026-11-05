local root = assert(arg[1], 'source root required')
local mac = root .. '/static/ergopti_plus/macos'
local shared = root .. '/static/ergopti_plus/_shared/lua'
package.path = mac..'/?.lua;'..mac..'/?/init.lua;'..mac..'/tests/stubs/?.lua;'..shared..'/?.lua;'..shared..'/?/init.lua;'..package.path
local helpers = require('tests.helpers')
helpers.warm_timings()
local with_picker = require('tests.support.ui.usercontent_reference_fixture')
for _, mode in ipairs({'healthy','throw','false','nil','async_error','encode_throw','encode_nil'}) do
  with_picker(function(picker,h)
    assert(h.open())
    local view, uc = h.views[1], h.controllers[1]
    local attempts, callbacks = 0, 0
    function view:evaluateJavaScript(script, completion)
      attempts = attempts + 1
      if completion then callbacks = callbacks + 1 end
      if mode == 'throw' then error('native submission refused') end
      if mode == 'false' then return false end
      if mode == 'nil' then return nil end
      if mode == 'async_error' and completion then completion(nil,{code=4,domain='WKErrorDomain'}) end
      return self
    end
    if mode == 'encode_throw' then hs.json.encode = function() error('cannot encode') end end
    if mode == 'encode_nil' then hs.json.encode = function() return nil end end
    h.post(uc,view,{action='ready'})
    assert(#h.errors == 0, 'new diagnosis exists; re-evaluate candidate')
    assert(callbacks == 0)
    assert(view.deleted == false)
    print(('picker mode=%s attempts=%d completion_observers=%d errors=%d view_open=%s'):format(mode,attempts,callbacks,#h.errors,tostring(not view.deleted)))
    assert(picker.close())
  end)
end
-- Healthy exact-source, late-message, stale-close and nil-error-sentinel controls.
with_picker(function(picker,h)
  local accepted=0
  assert(h.open(function() accepted=accepted+1;return true end))
  local a,uc=h.views[1],h.controllers[1]
  h.post(uc,{}, {action='confirm',id='next'})
  assert(accepted==0)
  h.post(uc,a,{action='confirm',id='next'})
  assert(accepted==1 and a.deleted)
  assert(h.open())
  h.post(uc,a,{action='cancel'})
  assert(not h.views[2].deleted)
  assert(picker.close())
  print('picker healthy confirm=1 foreign_source=0 stale_cancel_successor_delete=0')
end)
local Result=require('adapters.webview_result')
assert(not Result.is_error(nil) and not Result.is_error({code=0}))
assert(Result.is_error({code=0,domain='WKErrorDomain'}) and Result.is_error(false))
print('native-error nil/sentinel accepted; real code-zero domain and false rejected')
