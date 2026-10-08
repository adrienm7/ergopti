--- tests/unit/infra/test_managed_output_hops.lua

--- Normal discovery adapter for frozen independent controlled-native cases.
--- This adapter does not establish physical curl, filesystem or enterprise coverage.

local helpers = require("tests.helpers")

--- Actual coordinator, shared transition policy, retained lease and target.
--- Controlled native acknowledgements do not qualify real GIO/curl or files.
local Managed = require("infra.managed_http")
local Output = require("infra.archive_output")
local Target = require("infra.http_output_target")
local Routing = require("network.proxy_policy")
local Redirect = require("network.http_redirect")
local Json = require("json")
local Paths = require("infra.paths")
local function data(path)
 local file = assert(io.open(assert(Paths.shared(path)), "rb"))
 local bytes = assert(file:read("*a")); assert(file:close()); return assert(Json.decode(bytes))
end
local routing = assert(Routing.new(data("modules/network/proxy_policy.json")))
local law = assert(Redirect.new(data("data/http/redirect_policy.json"), data("data/http/transport_policy.json")))
local INITIAL, DEST = "https://updates.example/archive", "https://cdn.example/archive"
local tests = {}
local function test(name, fn) tests[#tests + 1] = { name, fn } end
local function fixture(config)
 config = config or {}
 local h = { now = 0.25, source = true, bytes = "", truncates = 0, writes = {}, proxies = {}, curls = {}, results = {}, timers = {} }
 local function clock() return h.now end
 local function timer(at, expired)
  local op = { started = true, at = at, listeners = {} }
  function op:is_settled() return self.settled == true end
  function op:on_settled(fn) self.listeners[#self.listeners + 1] = fn; return true end
  function op:cancel()
   if not self.settled then self.settled = true; for _, fn in ipairs(self.listeners) do fn() end end
   return true
  end
  h.timers[#h.timers + 1] = op; op.expired = expired; return op
 end
 local lease = assert(Output.new({ now_ms = clock, deadline = timer, open = function() return 7 end,
  close = function() h.fd_closed = true; return true end,
  truncate = function() h.truncates = h.truncates + 1; h.bytes = ""; return true end,
  write = function(_, body, _, done) h.writes[#h.writes + 1] = { body = body, done = done }; return {} end,
  hash = function() error("hops never hash") end,
 }).reserve("/owned", {}, function() return h.source end, 900.25))
 local target = assert(Target.create(lease, assert(lease:begin())))
 local function curl(url, headers, _, options, _, done)
  local child = { started = true, url = url, headers = headers, options = options, done = done, listeners = {}, received = 0 }
  function child:is_settled() return self.settled == true end
  function child:on_settled(fn) self.listeners[#self.listeners + 1] = fn; return true end
  function child:request_cancel() self.cancelled = true; return true end
  local input = { closed = false }
  function input:pause() return true end
  function input:resume() return true end
  function input:live() return h.source and not child.cancelled end
  function input:write_ack() end
  function input:reader_closed() return self.closed end
  function input:on_reader_closed(_, _, fn) self.close_listener = fn; return true end
  function input:abort() child.cancelled = true; return true end
  function input:continuation_receipt(_, producer, result)
   if not rawequal(producer, child) or not rawequal(result, child.result) then return nil end
   if config.report_hook then config.report_hook(h) end
   return { result = result, reader_eof = child.eof == true, physical_settled = child.settled == true,
    cancelled = child.cancelled == true, received_bytes = child.received }
  end
  child.input = input; child.sink = assert(Target.attach(options.output_target, child, input))
  h.curls[#h.curls + 1] = child; return child
 end
 local proxy = {}
 function proxy.lookup_owned(url, options, done)
  local child = { started = true, url = url, options = options, done = done, listeners = {} }
  function child.is_settled() return child.settled == true end
  function child.on_settled(fn) child.listeners[#child.listeners + 1] = fn; return true end
  function child.cancel() child.cancelled = true; return true end
  h.proxies[#h.proxies + 1] = child; return child
 end
 local coordinator = assert(Managed.new({ policy = routing, proxy = proxy, curl = curl,
  clock = clock, deadline = timer, environment = function() return {} end,
  redirect = function() return law end, output = Target, report = function() end,
 }))
 local options = { owner = "archive-transfer", method = "GET", buffered = false, owned_api = true,
  follow_redirects = false, archive_redirects = true, output_target = target, timeout_ms = 800,
  absolute_deadline_ms = 500.25 }
 local headers = { Authorization = "fixture-private", ["X-Api-Key"] = "fixture-private", Accept = "application/octet-stream" }
 h.operation = coordinator.start(INITIAL, headers, nil, options, nil,
  function(result, completion) h.results[#h.results + 1] = { result = result, completion = completion } end,
  { authorized = function() return h.source end, prepare = function() return options end })
 function h:proxy_ack(index)
  local child = assert(self.proxies[index]); child.settled = true
  child.done({ ok = true, proxies = { "http://proxy.invalid:81" }, backend = "GProxyResolverGnome" })
  for _, fn in ipairs(child.listeners) do fn() end
 end
 function h:body(index, value)
  local child = assert(self.curls[index]); assert(child.sink:consume(value)); child.received = child.received + #value
 end
 function h:write_ack()
  for _, work in ipairs(self.writes) do
   if not work.acked then work.acked = true; self.bytes = self.bytes .. work.body; work.done(nil, #work.body) end
  end
 end
 function h:terminal(index, status, next_url)
  local child = assert(self.curls[index])
  child.result = { ok = status == 200, status = status,
   redirect_receipt = { format = "curl-single-hop-v1", http_status = status, curl_exit = 0,
    num_redirects = 0, effective_url = child.url, redirect_url = next_url or "" } }
  child.eof = true; assert(child.sink:eof()); child.options.on_native_terminal(child.result)
 end
 function h:physical_ack(index)
  local child = assert(self.curls[index]); child.input.closed = true; child.input.close_listener()
  child.settled = true; child.done(assert(child.result)); for _, fn in ipairs(child.listeners) do fn() end
 end
 h.lease = lease
 return h
end

test("nonzero intermediate body is discarded before exact final archive bytes", function()
 local h = fixture(); h:proxy_ack(1); h:body(1, "discard this"); h:write_ack(); h:terminal(1, 302, DEST)
 assert(#h.proxies == 1 and h.bytes == "discard this")
 h:physical_ack(1); assert(#h.proxies == 2 and h.bytes == "" and h.truncates == 2)
 h:proxy_ack(2); h:body(2, "final bytes"); h:write_ack(); h:terminal(2, 200); h:physical_ack(2)
 assert(#h.results == 1 and h.results[1].result.ok == true and type(h.results[1].completion) == "table")
 assert(h.bytes == "final bytes" and h.operation:is_settled())
end)
test("every redirect URL is resolved before its own native curl and secrets are stripped", function()
 local h = fixture(); h:proxy_ack(1); h:terminal(1, 302, DEST); h:physical_ack(1)
 assert(h.proxies[2].url == DEST and #h.curls == 1)
 h:proxy_ack(2); local child = h.curls[2]
 assert(child.url == DEST and child.headers.Authorization == nil and child.headers["X-Api-Key"] == nil)
 assert(child.headers.Accept == "application/octet-stream" and child.options.follow_redirects == false)
end)
test("absolute archive phase deadline shrinks across redirect and never restarts", function()
 local h = fixture(); h:proxy_ack(1); h.now = 100.25; h:terminal(1, 302, DEST); h:physical_ack(1)
 assert(h.proxies[2].options.timeout_ms == 400)
 h.now = 200.25; h:proxy_ack(2); assert(h.curls[2].options.timeout_ms == 300)
 assert(h.timers[2].at == 500.25)
end)
test("cancel before physical ACK cannot redirect or publish artifact", function()
 local h = fixture(); h:proxy_ack(1); h:terminal(1, 302, DEST)
 assert(h.operation:cancel() == false); h:physical_ack(1)
 assert(#h.proxies == 1 and #h.results == 0 and h.truncates == 1)
end)
test("source withdrawal inside native continuation probe prevents successor", function()
 local h = fixture({ report_hook = function(state) state.source = false end })
 h:proxy_ack(1); h:terminal(1, 302, DEST); h:physical_ack(1)
 assert(#h.proxies == 1 and #h.results == 0 and h.truncates == 1)
end)
test("writer debt cannot be mistaken for physically retired continuation", function()
 local h = fixture(); h:proxy_ack(1); h:body(1, "pending"); h:terminal(1, 302, DEST); h:physical_ack(1)
 assert(#h.proxies == 1 and h.truncates == 1)
 assert(#h.results == 1 and h.results[1].result.ok == false and h.results[1].completion == nil)
end)
test("unprocessed original deadline refuses late success capability", function()
 local h = fixture(); h:proxy_ack(1); h:body(1, "abc"); h:write_ack(); h.now = 500.25
 h:terminal(1, 200); h:physical_ack(1)
 assert(#h.results == 1 and h.results[1].result.ok == false and h.results[1].completion == nil)
end)
test("source withdrawal inside final completion probe cannot publish token", function()
 local h = fixture({ report_hook = function(state) state.source = false end })
 h:proxy_ack(1); h:body(1, "abc"); h:write_ack(); h:terminal(1, 200); h:physical_ack(1)
 assert(#h.results == 0)
end)
assert(#tests == 8, "Independent frozen output case floor must remain 8")
helpers.describe("test_managed_output_hops", function()
	for _, case in ipairs(tests) do
		helpers.it(case[1], case[2])
	end
end)
