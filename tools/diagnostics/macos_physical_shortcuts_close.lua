-- tools/diagnostics/macos_physical_shortcuts_close.lua
-- Actual native PhysicalShortcuts observation; no modeled native success.
-- Only business scope/catalogue ports are controlled. Native observation wrappers
-- forward the real methods and returns, without forcing visibility or callbacks.
local M = {}

function M.run(config, done)
 assert(type(config) == 'table' and type(done) == 'function')
 assert(type(config.production_root) == 'string' and type(config.source_revision) == 'string')
 assert(type(config.nonce) == 'string' and config.expected_version == hs.processInfo.version)
 local root = config.production_root
 package.path = root .. '/macos/?.lua;' .. root .. '/macos/?/init.lua;'
  .. root .. '/_shared/lua/?.lua;' .. root .. '/_shared/lua/?/init.lua;' .. package.path
 local Logger = require('infra.logger')
 local policy = assert(io.open(root .. '/_shared/modules/diagnostics/redaction.json', 'rb'))
 local policy_bytes = assert(policy:read('*a')); assert(policy:close())
 Logger.initialize_privacy(policy_bytes)
 local Host = require('ui.physical_shortcuts')
 local UI = require('ui.ui_builder')
 local Scheduler = require('adapters.timer_scheduler')
 for fn, suffix in pairs({ [Host.open] = '/macos/ui/physical_shortcuts/init.lua',
  [UI.show_webview] = '/macos/ui/ui_builder.lua', [Scheduler.after] = '/macos/adapters/timer_scheduler.lua' }) do
  assert(debug.getinfo(fn, 'S').source == '@' .. root .. suffix, 'foreign production owner')
 end
 assert(package.loaded['modules.keylogger.physical_capture'] == nil, 'capture owner already present')
 assert(hs.screen.mainScreen(), 'native GUI unavailable')
 -- Native object metatables exist only after the lazy modules register them.
 assert(rawequal(require('hs.webview'), hs.webview), 'native WebView module identity differs')
 assert(type(hs.webview.usercontent) == 'table', 'native UCC module unavailable')
 local view_mt = assert(hs.getObjectMetatable('hs.webview'))
 local bridge_mt = assert(hs.getObjectMetatable('hs.webview.usercontent'))
 local original = { windowCallback = assert(view_mt.windowCallback),
  delete = assert(view_mt.delete), setCallback = assert(bridge_mt.setCallback) }
 local state = { cases = {}, timers = {}, finished = false, observing = false, errors = {}, phase = 'starting' }
 local baseline_timers = Scheduler.activeCount()
 local started = hs.timer.absoluteTime()
 local finish
 local function capture_error(message)
  state.errors[#state.errors + 1] = tostring(message)
  if finish then finish() end
 end
 local function guarded(body)
  local ok, err = xpcall(body, debug.traceback)
  if not ok then capture_error(err) end
 end
 local function later(body)
  local timer
  timer = assert(hs.timer.doAfter(0.05, function()
   state.timers[timer] = nil
   if not state.finished then guarded(body) end
  end))
  state.timers[timer] = true
 end
 local function await(condition, body)
  later(function()
   assert((hs.timer.absoluteTime() - started) / 1e9 < 35, 'native PhysicalShortcuts deadline exceeded')
   if condition() then body() else await(condition, body) end
  end)
 end
 local function current_for(view)
  for _, entry in ipairs(state.cases) do if rawequal(entry.view, view) then return entry end end
 end
 view_mt.windowCallback = function(view, callback, ...)
  if state.observing and type(callback) == 'function' then
   local entry = assert(state.current)
   assert(entry.view == nil or rawequal(entry.view, view), 'unexpected second native view')
   entry.view = view
   local forwarded = function(action, ...)
    if action == 'closing' then
     -- Observe the native state before the real production callback changes it.
     local ok, visible = pcall(function() return view:isVisible() end)
     entry.notifications[#entry.notifications + 1] = {
      action = action, visible_read = ok, visible = visible,
      userdata_live_before = getmetatable(view) ~= nil,
     }
    end
    return callback(action, ...)
   end
   return original.windowCallback(view, forwarded, ...)
  end
  return original.windowCallback(view, callback, ...)
 end
 view_mt.delete = function(view, ...)
  local entry = current_for(view)
  if entry then entry.deletes = entry.deletes + 1 end
  return original.delete(view, ...)
 end
 bridge_mt.setCallback = function(controller, callback, ...)
  local entry
  for _, candidate in ipairs(state.cases) do
   if rawequal(candidate.bridge, controller) then entry = candidate; break end
  end
  if not entry and state.observing and type(callback) == 'function' then
   entry = assert(state.current)
   assert(entry.bridge == nil, 'unexpected second native controller')
   entry.bridge = controller
  end
  local consumed_before_detach = entry ~= nil and callback == nil
  and entry.view ~= nil and getmetatable(entry.view) == nil
  if entry then
   if type(callback) == 'function' then entry.binds = entry.binds + 1
   elseif callback == nil then
    entry.detaches = entry.detaches + 1
    entry.consumed_before_detach = consumed_before_detach
   end
  end
  local results = table.pack(original.setCallback(controller, callback, ...))
  if entry then
   if type(callback) == 'function' then
    entry.weak.callback = callback
    entry.bind_ack = rawequal(results[1], controller)
   elseif callback == nil then
    entry.detach_ack = rawequal(results[1], controller)
   end
  end
  return table.unpack(results, 1, results.n)
 end
 local receipt = {}
 finish = function()
  if state.finished then return end
  state.finished = true
  view_mt.windowCallback, view_mt.delete = original.windowCallback, original.delete
  bridge_mt.setCallback = original.setCallback
  for timer in pairs(state.timers) do
   local ok, ack = pcall(function() return timer:stop() end)
   if not ok or not rawequal(ack, timer) then state.errors[#state.errors + 1] = 'probe timer stop refused' end
  end
  state.timers = {}
  receipt.schema_version, receipt.contract = 1, 'native.physical-shortcuts-close'
  receipt.nonce, receipt.source_revision = config.nonce, config.source_revision
  receipt.pid, receipt.version = hs.processInfo.processID, hs.processInfo.version
  receipt.arch, receipt.source_manifest_digest = hs.processInfo.arch, config.source_manifest_digest
  receipt.status, receipt.errors = #state.errors == 0 and 'ok' or 'error', state.errors
  receipt.observers_restored = view_mt.windowCallback == original.windowCallback
   and view_mt.delete == original.delete and bridge_mt.setCallback == original.setCallback
  receipt.ucc_userdata_gc = 'unmeasured; actual controllers deliberately retained'
  receipt.native_input = 'not attempted; no physical capture, eventtap, synthetic key or AppleEvent'
  receipt.product_timer_baseline = baseline_timers
  receipt.product_timer_final = Scheduler.activeCount()
  if #state.errors > 0 then
   local observation = { phase = state.phase, cases = {}, timer_active_count = receipt.product_timer_final }
   for _, entry in ipairs(state.cases) do
    observation.cases[#observation.cases + 1] = {
     name = entry.name, window_id = entry.window_id, host_pid = entry.host_pid,
     view_observed = entry.view ~= nil, bridge_observed = entry.bridge ~= nil,
     visible_before = entry.visible_before == true,
     native_delete_requests = entry.deletes, notifications = entry.notifications,
     userdata_consumed = entry.view ~= nil and getmetatable(entry.view) == nil,
     bind_attempts = entry.binds, bind_acknowledged = entry.bind_ack == true,
     detach_attempts = entry.detaches, detach_acknowledged = entry.detach_ack == true,
     consumed_before_detach = entry.consumed_before_detach == true,
     callback_alive = entry.weak.callback ~= nil, timer_active_count = receipt.product_timer_final,
    }
   end
   receipt.failure_observation = observation
  end
  done(receipt)
 end
 local token = {}
 local options = { scope = {
  physical_delivery_available = function() return true end, -- controlled business capability; never exercised as input
  capture_editor_inventory = function() return { assignments = {}, parameters = {} }, token end,
  editor_source_current = function(value) return rawequal(value, token) end,
  edit = function() error('native close probe must not publish shortcut edits') end,
 }, gestures = {
  is_assignable = function() return false end,
  get_action_parameter_spec = function() return nil end,
  validate_action_parameter = function() return false end,
  split_action_parameter_key = function() return nil end,
  get_action_label = function(value) return tostring(value) end,
 } }
 local function open_case(name)
  state.phase = name .. '.open'
  local entry = { name = name, deletes = 0, binds = 0, detaches = 0, notifications = {},
   weak = setmetatable({}, { __mode = 'v' }) }
  state.cases[#state.cases + 1], state.current = entry, entry
  state.observing = true
  local called, opened = xpcall(function() return Host.open(options) end, debug.traceback)
  state.observing = false
  assert(called and opened == true, 'real host open failed: ' .. tostring(opened))
  assert(type(entry.view) == 'userdata' and type(entry.bridge) == 'userdata', 'native observations missing')
  assert(entry.binds == 1 and entry.bind_ack, 'actual host bridge binding not acknowledged')
  assert(entry.view:deleteOnClose() == false, 'physical host unexpectedly enables native automatic GC')
  local window = assert(entry.view:hswindow())
  entry.host_pid = window:application():pid()
  assert(entry.host_pid == hs.processInfo.processID, 'foreign native window')
  entry.window_id = assert(window:id())
  assert(math.type(entry.window_id) == 'integer' and entry.window_id > 0)
  collectgarbage('collect'); collectgarbage('collect')
  assert(entry.weak.callback ~= nil, 'missing native registry retention control')
  state.phase = name .. '.await_visible'
  return entry, window
 end
 local function verify_retirement(entry, after)
  state.phase = entry.name .. '.await_retirement'
  await(function()
   collectgarbage('collect'); collectgarbage('collect')
   return getmetatable(entry.view) == nil and entry.detach_ack == true
    and entry.weak.callback == nil and Scheduler.activeCount() == baseline_timers
  end, function()
   assert(entry.deletes == 1, 'physical host requested more than one native delete')
   assert(#entry.notifications >= 1, 'native closing notification was not observed')
   assert(entry.detaches == 1 and entry.detach_ack, 'actual controller detach not exact-once acknowledged')
   assert(entry.consumed_before_detach == true, 'bridge detached before native window consumption')
   for _, event in ipairs(entry.notifications) do
    assert(event.visible_read and type(event.visible) == 'boolean', 'missing native notification visibility')
   end
   receipt[entry.name] = { window_id = entry.window_id, host_pid = entry.host_pid, native_delete_requests = entry.deletes,
    notifications = entry.notifications, userdata_consumed = true, visible_before = true,
    native_auto_delete_disabled = true, callback_retained_before = true,
    exact_bridge_detach = true, consumed_before_detach = entry.consumed_before_detach,
    callback_collected = true, product_timer_retired = true }
   assert(Host.close() == true, 'settled public close not idempotent')
   assert(entry.deletes == 1, 'idempotent close repeated native destruction')
   after()
  end)
 end
 guarded(function()
  local user, user_window = open_case('ax_user_close')
  await(function() return user.view:isVisible() == true end, function()
   user.visible_before = true
   state.phase = 'ax_user_close.request_ax_close'
   local accepted = user_window:close()
   receipt.ax_close_ack = accepted == true
   assert(accepted == true, 'actual AX close refused; no Lua-delete fallback')
   verify_retirement(user, function()
    local explicit = open_case('public_close')
    assert(not rawequal(explicit.view, user.view), 'successor reused consumed userdata')
    await(function() return explicit.view:isVisible() == true end, function()
     explicit.visible_before = true
     state.phase = 'public_close.request_public_close'
     receipt.public_close_initial_return = Host.close()
     verify_retirement(explicit, function()
      assert(package.loaded['modules.keylogger.physical_capture'] == nil, 'probe created a capture owner')
      finish()
     end)
    end)
   end)
  end)
 end)
 return state
end

return M
