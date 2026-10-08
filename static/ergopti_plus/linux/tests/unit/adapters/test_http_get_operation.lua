--- static/ergopti_plus/linux/tests/unit/adapters/test_http_get_operation.lua

--- Actual public wrapper + actual Managed coordinator; child/timer ports below
--- are independent models, not libuv/native runtime qualification.
local helpers = require("tests.helpers")
local function with_client(config, body)
 config = config or {}
 local names = { "adapters.http_client", "adapters.curl_http_client", "adapters.system_proxy",
  "infra.proxy_policy", "infra.monotonic", "infra.managed_http_deadline" }
 local saved = {}; for _, name in ipairs(names) do saved[name] = { value = package.loaded[name] } end
 local state = { now = 0.25, logical = 0, children = {}, timers = {} }
 local core = { HAS_ASYNC = true, default_timeout_ms = function() return 1000 end }
 function core.preflight(_, headers)
  if config.preflight_refused then return false, "independent preflight refusal" end
  return true, nil, {}, headers, false
 end
 function core.rebind_prepared_headers() return {} end
 function core.dispatch_owned(_, _, _, options, _, complete)
  local child = { started = true, closed = false, listeners = {} }
  function child:is_settled() return self.closed end
  function child:on_settled(observer) self.listeners[#self.listeners + 1] = observer; return true end
  function child:request_cancel() self.cancelled = true; return true end
  function child:logical(receipt) options.on_native_terminal(receipt) end
  function child:ack(receipt)
   self.closed = true
   if not self.cancelled then complete(receipt) end
   for _, observer in ipairs(self.listeners) do observer() end
  end
  state.children[#state.children + 1] = child; return child
 end
 local ok, failure = xpcall(function()
  package.loaded["adapters.http_client"] = nil
  package.loaded["adapters.curl_http_client"] = core
  package.loaded["adapters.system_proxy"] = { lookup_owned = function() error("direct route started GIO") end }
  package.loaded["infra.proxy_policy"] = { load = function() return {
   route = function() return { mode = "direct" } end,
   selection = function() return { { mode = "direct" } } end, can_retry = function() return false end,
  } end, environment = function() return {} end }
  package.loaded["infra.monotonic"] = { now_ms = function() return state.now end }
  package.loaded["infra.managed_http_deadline"] = { start = function(deadline, expired)
   local token = { started = true, closed = false, listeners = {}, deadline = deadline, expired = expired }
   function token:is_settled() return self.closed end
   function token:on_settled(observer) self.listeners[#self.listeners + 1] = observer; return true end
   function token:cancel() self.cancelled = true; return true end
   function token:ack() self.closed = true; for _, observer in ipairs(self.listeners) do observer() end end
   state.timers[#state.timers + 1] = token; return token
  end }
  local client = require("adapters.http_client")
  body(client, state)
 end, debug.traceback)
 for _, name in ipairs(names) do package.loaded[name] = saved[name].value end
 if not ok then error(failure, 0) end
end
local function start(client, state, observer)
 return client.get("http://127.0.0.1:9000/fixed", {}, { owner = "receipt", timeout_ms = 1000 }, function(receipt)
  state.logical = state.logical + 1; if observer then observer(receipt) end
 end)
end
local function response() return { ok = true, status = 200, body = "original bytes", headers = { ETag = "original header" } } end
helpers.describe("Boolean GET exact second operation", function()
 helpers.it("keeps the first Boolean and logical identity while returning exact physical ownership", function()
  with_client(nil, function(client, state)
   local seen, listener_arity
   local sent, operation = start(client, state, function(receipt) seen = receipt end)
   helpers.assert_true(sent)
   helpers.assert_eq(type(operation), "table")
   helpers.assert_nil(operation:settled_result())
   operation:on_settled(function(...) listener_arity = select("#", ...) end)
   local receipt = response(); state.children[1]:logical(receipt)
   helpers.assert_true(rawequal(receipt, seen), "generic logical callback identity is preserved")
   helpers.assert_eq(state.logical, 1)
   helpers.assert_eq(operation:is_settled(), false)
   state.children[1]:ack(receipt)
   helpers.assert_nil(operation:settled_result())
   state.timers[1]:ack()
   helpers.assert_true(operation:is_settled())
   helpers.assert_eq(operation:settled_result().body, "original bytes")
   helpers.assert_eq(listener_arity, 0, "existing settlement listener argument tuple is unchanged")
  end)
 end)
 helpers.it("public settled field cannot mint a physical receipt", function()
  with_client(nil, function(client, state)
   local _, operation = start(client, state)
   operation._settled = true
   helpers.assert_nil(operation:settled_result())
   operation._settled = false -- Restore the original controlled owner's field.
   local receipt = response(); state.children[1]:logical(receipt); state.children[1]:ack(receipt); state.timers[1]:ack()
   helpers.assert_eq(operation:settled_result().status, 200)
  end)
 end)
 helpers.it("snapshots body and headers before logical mutation and returns detached copies", function()
  with_client(nil, function(client, state)
   local failure = { stage = "curl", failure_provenance = "verified" }
   local _, operation = start(client, state, function(receipt)
    receipt.body = "borrowed bytes"; receipt.headers.ETag = "borrowed header"; receipt.ok = false
   end)
   local receipt = response(); receipt.failure_receipt = failure
   state.children[1]:logical(receipt); state.children[1]:ack(receipt); state.timers[1]:ack()
   local first = operation:settled_result()
   helpers.assert_eq(first.body, "original bytes")
   helpers.assert_eq(first.headers.ETag, "original header")
   helpers.assert_true(first.ok)
   helpers.assert_true(rawequal(first.failure_receipt, failure), "actual private failure evidence identity is retained")
   first.body = "changed copy"; first.headers.ETag = "changed copy"
   local second = operation:settled_result()
   helpers.assert_eq(second.body, "original bytes")
   helpers.assert_eq(second.headers.ETag, "original header")
  end)
 end)
 helpers.it("late timer retirement exposes genuine timeout rather than earlier logical success", function()
  with_client(nil, function(client, state)
   local _, operation = start(client, state)
   local receipt = response(); state.children[1]:logical(receipt); state.children[1]:ack(receipt)
   state.now = state.timers[1].deadline + 0.25; state.timers[1]:ack()
   helpers.assert_eq(state.logical, 1)
   helpers.assert_eq(operation:settled_result().ok, false)
   helpers.assert_eq(operation:settled_result().error, "timeout")
  end)
 end)
 helpers.it("cancelled final retirement cannot expose parked success", function()
  with_client(nil, function(client, state)
   local _, operation = start(client, state)
   local receipt = response(); state.children[1]:logical(receipt)
   operation:cancel()
   helpers.assert_nil(operation:settled_result())
   state.children[1]:ack(receipt); state.timers[1]:ack()
   helpers.assert_eq(operation:settled_result().error, "cancelled")
   helpers.assert_eq(state.logical, 1)
  end)
 end)
 helpers.it("known no-resource preflight refusal retains an immutable final failure", function()
  with_client({ preflight_refused = true }, function(client, state)
   local sent, operation = start(client, state, function(receipt) receipt.error = "forged failure" end)
   helpers.assert_eq(sent, false)
   helpers.assert_true(operation:is_settled())
   helpers.assert_eq(operation:settled_result().error, "independent preflight refusal")
   helpers.assert_eq(#state.children + #state.timers, 0)
  end)
 end)
end)

helpers.describe("canonical final-result source binding", function()
 helpers.it("original expiration retains timeout after parked success with positive clock remaining", function()
  with_client(nil, function(client, state)
   local _, operation = start(client, state)
   local receipt = response()
   state.children[1]:logical(receipt); state.children[1]:ack(receipt)
   helpers.assert_nil(operation:settled_result())
   helpers.assert_true(state.now < state.timers[1].deadline)
   state.timers[1].expired() -- Original captured expiration law, no new clock/budget.
   state.timers[1]:ack()
   helpers.assert_eq(operation:settled_result().ok, false)
   helpers.assert_eq(operation:settled_result().error, "timeout")
   helpers.assert_eq(state.logical, 1)
  end)
 end)
end)
