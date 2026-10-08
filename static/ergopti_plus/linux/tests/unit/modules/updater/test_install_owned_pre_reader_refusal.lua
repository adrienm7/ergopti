--- tests/unit/modules/updater/test_install_owned_pre_reader_refusal.lua

--- Actual installer entry point, without acquiring a reader or filesystem port.
--- Literal cleanup receipts are controlled ACKs, not native cleanup evidence.
local Installer = require("modules.updater.installer")
local tests = {}
local function test(name, body) tests[#tests + 1] = { name, body } end
local function fixture(options)
 options = options or {}
 local h = { reads = 0, finishes = 0, callbacks = {}, physical = false, listeners = {}, signals = 0 }
 local reservation = {}
 local child = {}
 function child:is_settled()
  if h.physical_probe then h.physical_probe() end
  return h.physical
 end
 function child:request_cancel() h.signals = h.signals + 1; return true end
 function child:on_settled(listener) h.listeners[#h.listeners + 1] = listener; return true end
 local factory = {
  install_current = function(token)
   assert(rawequal(token, reservation))
   if options.source_throws then error("original deadline observation refused") end
   return false -- The original install admission expired before the first reader.
  end,
  install_feed = function() h.reads = h.reads + 1; error("no reader may be acquired") end,
  finish_install = function(token, keep, done)
   assert(rawequal(token, reservation) and keep == true)
   h.finishes = h.finishes + 1; h.done = done
   if options.construct then options.construct(h, done, child) end
   if options.return_nil then return nil end
   if options.throw then error("unknown acquired cleanup debt") end
   return child
  end,
 }
 h.child = child
 h.operation = assert(Installer.install_owned({ factory = factory, reservation = reservation }, function(...)
  h.callbacks[#h.callbacks + 1] = { ... }
 end))
 assert(h.operation.started == true and h.finishes == 1 and h.reads == 0)
 function h:ack()
  self.physical = true
  for _, listener in ipairs(self.listeners) do listener() end
 end
 function h:complete()
  self.done({ ok = true }); self:ack()
  assert(self.operation:is_settled() == true and #self.callbacks == 1 and self.callbacks[1][1] == false)
  assert(type(self.callbacks[1][2]) == "string" and self.reads == 0 and self.finishes == 1)
 end
 return h
end
test("known original deadline refusal joins cleanup before releasing busy", function()
 local h = fixture(); assert(not h.operation:is_settled() and #h.callbacks == 0)
 h.done({ ok = true }); assert(not h.operation:is_settled() and #h.callbacks == 0)
 h:ack(); assert(h.operation:is_settled() and #h.callbacks == 1 and h.callbacks[1][1] == false and h.reads == 0)
end)
test("throwing initial admission still joins fixed pre-reader reservation cleanup", function()
 local h = fixture({ source_throws = true }); h:complete()
end)
test("logical cancellation never substitutes for original cleanup ACK", function()
 local h = fixture(); assert(h.operation:request_cancel() == true and h.signals == 1)
 h.done({ ok = true }); assert(not h.operation:is_settled() and #h.callbacks == 0)
 assert(h.operation:cancel() == false and h.signals == 1)
 h:ack(); assert(h.operation:is_settled() and #h.callbacks == 1 and h.callbacks[1][1] == false)
end)
test("public child method replacement cannot borrow physical cleanup authority", function()
 local h = fixture()
 h.child.is_settled = function() return true end
 h.child.request_cancel = function() error("replacement signal") end
 h.child.on_settled = function() error("replacement observer") end
 h.done({ ok = true }); assert(not h.operation:is_settled() and #h.callbacks == 0)
 assert(h.operation:request_cancel() == true and h.signals == 1)
 h:ack(); assert(h.operation:is_settled() and #h.callbacks == 1)
end)
test("early cleanup callback is buffered until original child acquisition and ACK", function()
 local h = fixture({ construct = function(_, done) done({ ok = true }) end })
 assert(not h.operation:is_settled() and #h.callbacks == 0)
 h:ack(); assert(h.operation:is_settled() and #h.callbacks == 1 and h.callbacks[1][1] == false)
end)
test("early callback followed by throwing cleanup constructor retains unknown debt", function()
 local h = fixture({ construct = function(_, done) done({ ok = true }) end, throw = true })
 h.physical = true
 assert(not h.operation:is_settled() and #h.callbacks == 0)
 assert(h.operation:request_cancel() == true and not h.operation:is_settled() and h.reads == 0)
end)
test("nil unknown cleanup acquisition cannot manufacture pre-reader physical success", function()
 local h = fixture({ return_nil = true })
 h.done({ ok = true }); h:ack()
 assert(not h.operation:is_settled() and #h.callbacks == 0 and h.reads == 0)
end)
test("physical observer reentry consumes one known-refusal completion", function()
 local h = fixture(); h.done({ ok = true })
 h.physical_probe = function() h.physical_probe = nil; h.listeners[1]() end
 h:ack(); assert(h.operation:is_settled() and #h.callbacks == 1 and h.reads == 0)
 h.listeners[1](); h.done({ ok = true }); assert(#h.callbacks == 1)
end)
assert(#tests == 8, "known pre-reader cleanup receiving-boundary floor")

-- Genuine normal registration retains every independent body and oracle.
local helpers = require("tests.helpers")
helpers.describe("Known Pre-Reader Install Refusal", function()
	assert(#tests == 8, "Independent case floor changed")
	for _, case in ipairs(tests) do
		assert(type(case[1]) == "string" and type(case[2]) == "function", "Independent registration refused")
		helpers.it(case[1], case[2])
	end
end)
return tests
