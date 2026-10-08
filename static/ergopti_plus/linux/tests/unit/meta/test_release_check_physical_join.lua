--- static/ergopti_plus/linux/tests/unit/meta/test_release_check_physical_join.lua

--- Real Manager/Transfer/Managed imports, independent controlled native child
--- and timer ACKs. The existing explicit unit artifact fixture supplies only
--- modeled allocation/publication; these controls prove no native runtime IO.
local helpers = require("tests.helpers")
local Managed = require("infra.managed_http")
local Model = require("tests.support.updater_native_model")

local function release_body(manager, count)
 local entries = {}
 for index = 1, count or 1 do
  entries[index] = '{"tag_name":"v2.0.' .. index .. '","assets":['
   .. '{"name":"' .. manager.LINUX_ASSET_NAME .. '","browser_download_url":"https://example.invalid/archive"},'
   .. '{"name":"' .. manager.LINUX_CHECKSUM_ASSET_NAME .. '","browser_download_url":"https://example.invalid/checksum"}]}'
 end
 return '[' .. table.concat(entries, ',') .. ']'
end
local function with_manager(config, body)
 config = config or {}
 Model.with_fixture(function(manager)
  local state = { now = 0.25, curls = {}, timers = {}, operations = {}, logical = 0, checks = 0 }
  local coordinator
  coordinator = assert(Managed.new({
   policy = { route = function()
    if config.refuse_route then return nil, "independent route refused" end
    return { mode = "direct" }
   end,
    selection = function() return { { mode = "direct" } } end, can_retry = function() return false end },
   proxy = { lookup_owned = function() error("fixed direct route must not start lookup") end },
   clock = function() return state.now end, environment = function() return {} end,
   report = function() end,
   deadline = function(deadline, expired)
    local timer = { started = true, closed = false, listeners = {}, deadline = deadline, expired = expired }
    function timer:is_settled() return self.closed end
    function timer:on_settled(observer)
     if self.closed then observer() else self.listeners[#self.listeners + 1] = observer end
     return true
    end
    function timer:cancel() self.cancelled = true; return true end
    function timer:ack()
     if self.closed then return end
     self.closed = true; local pending = self.listeners; self.listeners = {}
     for _, observer in ipairs(pending) do observer() end
    end
    state.timers[#state.timers + 1] = timer; return timer
   end,
   curl = function(url, _, _, options, _, done)
    local child = { started = true, closed = false, listeners = {}, url = url, options = options }
    function child:is_settled() return self.closed end
    function child:on_settled(observer)
     if self.closed then observer() else self.listeners[#self.listeners + 1] = observer end
     return true
    end
    function child:request_cancel() self.cancelled = true; return true end
    function child:logical(result) options.on_native_terminal(result) end
    function child:ack(result)
     if self.closed then return end
     self.closed = true
     if not self.cancelled then done(result) end
     local pending = self.listeners; self.listeners = {}
     for _, observer in ipairs(pending) do observer() end
    end
    state.curls[#state.curls + 1] = child
    if config.during_native then config.during_native(manager, state, child) end
    return child
   end,
  }))
  local port = {}
  local function options(source, owned)
   local value = {}; for name, field in next, source do value[name] = field end
   value.method, value.buffered, value.owned_api = "GET", true, owned
   return value
  end
  function port.get(url, headers, source, done)
   local operation = coordinator.start(url, headers, nil, options(source, false), nil, function(result)
    state.logical = state.logical + 1; done(result)
    if config.after_logical then config.after_logical(manager, state, result) end
   end)
   state.operations[#state.operations + 1] = operation
   if config.before_return then config.before_return(manager, state, operation) end
   return operation.started, operation
  end
  function port.get_owned(url, headers, source, done)
   local value = options(source, true)
   return coordinator.start(url, headers, nil, value, nil, done,
    { authorized = source.authorized, prepare = function() return value end })
  end
  -- Transfer captures both actual API ports before its first checksum request.
  -- This control cancels at checksum; an archive call is an explicit failure,
  -- never a synthetic downstream success or native output qualification.
  function port.download_output_owned() error("release-check control must not dispatch an archive") end
  function port.cancel(owner) return coordinator.cancel(owner) end
  manager._http_client = port
  manager.current_version = function() return "1.0.0" end
  state.manager = manager
  state.answer = function(count) return { ok = true, status = 200, body = release_body(manager, count) } end
  state.finish = function(index, result)
   state.curls[index]:ack(result); state.timers[index]:ack()
  end
  body(manager, state)
 end)
end

helpers.describe("release-check original physical page owner", function()
 helpers.it("callback-triggered actual download waits for child and original timer close ACK", function()
  with_manager(nil, function(manager, state)
   local downloaded, error_text, admitted
   helpers.assert_true(manager.check_for_updates("main", function(available)
    state.checks = state.checks + 1
    helpers.assert_true(available)
    admitted = manager.download_update(nil, function(path, err) downloaded, error_text = path, err end)
   end))
   local response = state.answer()
   state.curls[1]:logical(response)
   helpers.assert_eq(state.logical, 1, "generic HTTP logical callback is still early")
   helpers.assert_eq(state.checks, 0, "check callback cannot expose a busy native owner")
   helpers.assert_eq(manager.get_state(), "checking")
   state.curls[1]:ack(response)
   helpers.assert_eq(state.checks, 0, "child ACK alone does not retire the original deadline")
   state.timers[1]:ack()
   helpers.assert_eq(state.checks, 1)
   helpers.assert_true(admitted, "first owned checksum must be admitted after its exact predecessor")
   helpers.assert_eq(#state.curls, 2, "the real Transfer acquires exactly its checksum child")
   helpers.assert_nil(error_text)
   helpers.assert_nil(downloaded)
   helpers.assert_true(manager.cancel_update())
   state.finish(2, { ok = false, status = 0, body = "", error = "cancelled" })
   helpers.assert_eq(error_text, "update transaction cancelled")
  end)
 end)
 helpers.it("pagination cannot acquire page two at the first logical response", function()
  with_manager(nil, function(manager, state)
   local completions = 0
   helpers.assert_true(manager._fetch_releases("main", function() completions = completions + 1 end))
   local response = state.answer(20)
   state.curls[1]:logical(response)
   helpers.assert_eq(#state.curls, 1)
   state.curls[1]:ack(response)
   helpers.assert_eq(#state.curls, 1)
   state.timers[1]:ack()
   helpers.assert_eq(#state.curls, 2)
   state.curls[2]:logical(state.answer())
   helpers.assert_eq(completions, 0)
   state.finish(2, state.answer())
   helpers.assert_eq(completions, 1)
  end)
 end)
 helpers.it("logical cancellation leaves checking pending through both physical ACKs", function()
  with_manager(nil, function(manager, state)
   local completions, error_text = 0, nil
   helpers.assert_true(manager.check_for_updates("main", function(_, _, err)
    completions = completions + 1; error_text = err
   end))
   state.curls[1]:logical(state.answer())
   helpers.assert_true(manager.cancel_update())
   helpers.assert_eq(completions, 0)
   helpers.assert_eq(manager.get_state(), "checking")
   helpers.assert_eq(manager.check_for_updates("main"), false, "cancellation debt remains a busy check")
   state.curls[1]:ack(state.answer())
   helpers.assert_eq(completions, 0)
   state.timers[1]:ack()
   helpers.assert_eq(completions, 1)
   helpers.assert_eq(error_text, "cancelled")
   helpers.assert_eq(manager.get_state(), "idle")
  end)
 end)
 helpers.it("late original timer ACK replaces earlier logical success with genuine timeout", function()
  with_manager(nil, function(manager, state)
   local received, completions
   completions = 0
   helpers.assert_true(manager._fetch_releases("main", function(body, _, err)
    completions = completions + 1; received = { body = body, error = err }
   end))
   state.curls[1]:logical(state.answer())
   state.curls[1]:ack(state.answer())
   state.now = state.timers[1].deadline + 0.25
   state.timers[1]:ack()
   helpers.assert_eq(completions, 1)
   helpers.assert_nil(received.body)
   helpers.assert_eq(received.error, "timeout")
  end)
 end)
 helpers.it("a logical consumer cannot replace the physical page body", function()
  with_manager({ after_logical = function(_, _, value) value.body = "[invalid]"; value.ok = false end }, function(manager, state)
   local body, failure
   helpers.assert_true(manager._fetch_releases("main", function(value, _, err) body, failure = value, err end))
   local response = state.answer()
   local original = response.body
   state.curls[1]:logical(response)
   state.finish(1, response)
   helpers.assert_eq(body, original)
   helpers.assert_nil(failure)
  end)
 end)
 helpers.it("construction-time terminal remains parked until returned owner capture", function()
  with_manager({ during_native = function(manager, _, child)
   child:logical({ ok = true, status = 200, body = release_body(manager) })
  end }, function(manager, state)
   local completions = 0
   helpers.assert_true(manager._fetch_releases("main", function() completions = completions + 1 end))
   helpers.assert_eq(completions, 0)
   state.finish(1, state.answer())
   helpers.assert_eq(completions, 1)
  end)
 end)
 helpers.it("missing settlement receipt method retains unknown ownership", function()
  with_manager({ before_return = function(_, _, operation) operation.settled_result = nil end }, function(manager, state)
   local completions = 0
   helpers.assert_true(manager.check_for_updates("main", function() completions = completions + 1 end))
   state.curls[1]:logical(state.answer()); state.finish(1, state.answer())
   helpers.assert_eq(completions, 0)
   helpers.assert_eq(manager.get_state(), "checking")
  end)
 end)
 helpers.it("captured settlement methods survive public method replacement", function()
  with_manager(nil, function(manager, state)
   local completions = 0
   helpers.assert_true(manager._fetch_releases("main", function() completions = completions + 1 end))
   local operation = state.operations[1]
   operation.is_settled = function() error("mutable replacement must not be borrowed") end
   operation.settled_result = function() error("mutable receipt method must not be borrowed") end
   state.curls[1]:logical(state.answer()); state.finish(1, state.answer())
   helpers.assert_eq(completions, 1)
  end)
 end)
 helpers.it("a settlement probe cancellation cannot consume parked success", function()
  with_manager({ before_return = function(manager, state, operation)
   local original = operation.is_settled
   operation.is_settled = function(self)
    if not state.revoked then state.revoked = true; helpers.assert_true(manager.cancel_update()) end
    return original(self)
   end
  end }, function(manager, state)
   local body, error_text, completions = nil, nil, 0
   helpers.assert_true(manager.check_for_updates("main", function(_, _, err)
    completions = completions + 1; error_text = err
   end))
   helpers.assert_eq(completions, 0)
   helpers.assert_eq(manager.get_state(), "checking")
   state.finish(1, state.answer())
   helpers.assert_eq(completions, 1)
   helpers.assert_eq(error_text, "cancelled")
   helpers.assert_nil(body)
  end)
 end)
 helpers.it("nested original settlement notification publishes the check once", function()
  with_manager({ before_return = function(_, state, operation)
   local original_probe, original_observe = operation.is_settled, operation.on_settled
   local listener
   operation.on_settled = function(self, observer) listener = observer; return original_observe(self, observer) end
   operation.is_settled = function(self)
    local settled = original_probe(self)
    if settled and listener and not state.reentered then state.reentered = true; listener() end
    return settled
   end
  end }, function(manager, state)
   local completions = 0
   helpers.assert_true(manager._fetch_releases("main", function() completions = completions + 1 end))
   state.curls[1]:logical(state.answer()); state.finish(1, state.answer())
   helpers.assert_eq(completions, 1)
   helpers.assert_true(state.reentered)
  end)
 end)
 for _, refusal in ipairs({ "false", "throw" }) do
  local mode = refusal
  helpers.it("original settlement subscription " .. mode .. " keeps unknown page debt", function()
   with_manager({ before_return = function(_, _, operation)
    operation.on_settled = function() if mode == "throw" then error("original subscription refused") end; return false end
   end }, function(manager, state)
    local completions = 0
    helpers.assert_true(manager.check_for_updates("main", function() completions = completions + 1 end))
    state.curls[1]:logical(state.answer()); state.finish(1, state.answer())
    helpers.assert_eq(completions, 0)
    helpers.assert_eq(manager.get_state(), "checking")
   end)
  end)
 end
 for _, page in ipairs({ 1, 2 }) do
  local cancelled_page = page
  helpers.it("metadata cancellation acquires no page " .. page .. " child", function()
   with_manager(nil, function(manager, state)
    local build = manager._build_fetch_request
    manager._build_fetch_request = function(channel, number)
     if number == cancelled_page then helpers.assert_true(manager.cancel_update()) end
     return build(channel, number)
    end
    local completions, error_text = 0, nil
    manager._fetch_releases("main", function(_, _, err) completions = completions + 1; error_text = err end)
    if cancelled_page == 2 then state.curls[1]:logical(state.answer(20)); state.finish(1, state.answer(20)) end
    helpers.assert_eq(#state.curls, cancelled_page - 1)
    helpers.assert_eq(completions, 1)
    helpers.assert_eq(error_text, "cancelled")
   end)
  end)
 end
 for _, action in ipairs({ "channel", "cache" }) do
  local mutation = action
  helpers.it("retained page cancel debt refuses " .. action .. " mutation", function()
   with_manager(nil, function(manager, state)
    local original_channel = manager.get_channel()
    helpers.assert_true(manager.check_for_updates("main", function() end))
    if mutation == "channel" then
     local replacement = original_channel == "main" and "dev" or "main"
     helpers.assert_eq(manager.set_channel(replacement), false)
     helpers.assert_eq(manager.get_channel(), original_channel)
    else helpers.assert_eq(manager.clear_cached_release(), false) end
    helpers.assert_eq(manager.get_state(), "checking")
    state.finish(1, state.answer())
    helpers.assert_eq(manager.get_state(), "idle")
   end)
  end)
 end
end)

helpers.describe("release-check genuine pre-start retirement", function()
 helpers.it("a refused native start retains checking until original pipe and timer ACK", function()
  with_manager({ during_native = function(_, _, child)
   child.started = false
   child:logical({ ok = false, status = 0, body = "", error = "independent pre-start pipe retirement failed" })
  end }, function(manager, state)
   local completions, error_text = 0, nil
   helpers.assert_true(manager.check_for_updates("main", function(_, _, err)
    completions = completions + 1; error_text = err
   end), "the check owns the known pending refusal despite get's false first scalar")
   helpers.assert_eq(state.operations[1].started, false)
   helpers.assert_eq(completions, 0)
   helpers.assert_eq(manager.get_state(), "checking")
   state.curls[1]:ack({ ok = false, status = 0, body = "", error = "independent pre-start pipe retirement failed" })
   helpers.assert_eq(completions, 0)
   state.timers[1]:ack()
   helpers.assert_eq(completions, 1)
   helpers.assert_eq(error_text, "independent pre-start pipe retirement failed")
   helpers.assert_eq(manager.get_state(), "idle")
  end)
 end)
 helpers.it("a genuine no-child route refusal keeps the original false admission and one failure", function()
  with_manager({ refuse_route = true }, function(manager, state)
   local completions, error_text = 0, nil
   local sent = manager.check_for_updates("main", function(_, _, err)
    completions = completions + 1; error_text = err
   end)
   helpers.assert_eq(sent, false)
   helpers.assert_eq(#state.curls + #state.timers, 0)
   helpers.assert_eq(completions, 1)
   helpers.assert_eq(error_text, "independent route refused")
   helpers.assert_eq(manager.get_state(), "idle")
  end)
 end)
end)
