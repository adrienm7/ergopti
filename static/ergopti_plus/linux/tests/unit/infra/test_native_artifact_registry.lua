--- tests/unit/infra/test_native_artifact_registry.lua

--- Actual Lua registry/lease/target calls with explicitly controlled native ports.
--- These fixed causal controls do not qualify the C backend, kernel or installer.
local Output = require("infra.archive_output")
local Target = require("infra.http_output_target")
local tests = {}
local function test(name, body) tests[#tests + 1] = { name, body } end
local ABC_SHA256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
local function fixture(options)
 options = options or {}
 local h = { now = 0.25, source = true, phase = true, opens = 0, closes = 0, creates = 0,
  stages = 0, commits = 0, cleanups = 0, disposes = 0, hashes = 0, writes = {}, bytes = "",
  timer_settled = false, timer_listeners = {}, hash_settled = false, hash_listeners = {}, callbacks = {} }
 local saved = {}
 local names = { "ffi", "luv", "infra.paths", "infra.monotonic", "infra.managed_http_deadline", "infra.fd_sha256" }
 for _, name in ipairs(names) do saved[name] = package.loaded[name] end
 local function restore()
  for _, name in ipairs(names) do package.loaded[name] = saved[name] end
 end
 h.restore = restore
 local timer = { started = options.timer_started ~= false }
 function timer:is_settled()
  if h.timer_probe then h.timer_probe() end
  return h.timer_settled
 end
 function timer:cancel() h.timer_cancelled = true; return true end
 function timer:on_settled(fn) h.timer_listeners[#h.timer_listeners + 1] = fn; return true end
 function h:timer_ack()
  self.timer_settled = true
  for _, fn in ipairs(self.timer_listeners) do fn() end
 end
 local hash = {}
 function hash:is_settled() return h.hash_settled end
 function hash:cancel() h.hash_cancelled = true; return true end
 function hash:on_settled(fn) h.hash_listeners[#h.hash_listeners + 1] = fn; return true end
 function h:hash_ack(digest, receipt)
  assert(self.hash_callback)
  self.hash_callback(digest, receipt)
  self.hash_settled = true
  for _, fn in ipairs(self.hash_listeners) do fn() end
 end
 local symbols = {}
 symbols.abi_version = function() return options.abi or 1 end
 symbols.clock_ms = function() return h.now + (options.clock_offset or 0) end
 symbols.create_directory = function(parent, deadline, out)
  assert(parent:sub(1, 1) == "/" and deadline == 100.5)
  h.creates = h.creates + 1; h.pointer = {}; out[0] = h.pointer; return 0
 end
 symbols.allocate_output = function(pointer, deadline, out)
  assert(rawequal(pointer, h.pointer) and deadline == 100.5)
  h.opens = h.opens + 1; out[0] = 97; return 0
 end
 symbols.stage = function(pointer, fd, bytes, name, deadline)
  assert(rawequal(pointer, h.pointer) and fd == 97 and bytes == 3)
  assert(name == "ergopti-linux.tar.gz" and deadline == 50.5)
  assert(h.hash_settled and not h.fd_closed, "stage must use original settled-hash retained FD")
  h.stages = h.stages + 1
  if options.stage then return options.stage(h) end
  return 0
 end
 symbols.commit = function(pointer)
  assert(rawequal(pointer, h.pointer) and h.fd_closed and h.timer_settled)
  h.commits = h.commits + 1; return 0
 end
 symbols.copy_display_path = function(pointer, buffer, capacity)
  assert(rawequal(pointer, h.pointer) and capacity == 4352)
  buffer.text = options.no_display_nul and string.rep("x", 4352) or options.empty_display and ""
   or "/tmp/controlled-private/ergopti-linux.tar.gz"
  return 0 -- Actual publication ABI: success status, never byte count.
 end
 symbols.cleanup = function(pointer)
  assert(rawequal(pointer, h.pointer))
  assert(h.opens == 0 or h.fd_closed, "cleanup precedes original descriptor ACK")
  assert(h.opens == 0 or h.timer_settled or options.no_timer, "cleanup precedes original timer ACK")
  h.cleanups = h.cleanups + 1; h.native_closed = true; return 0
 end
 symbols.descriptors_closed = function(pointer) assert(rawequal(pointer, h.pointer)); return h.native_closed and 1 or 0 end
 symbols.named_remaining = function(pointer) assert(rawequal(pointer, h.pointer)); return h.native_closed and 0 or 1 end
 symbols.dispose_unpublished = function(pointer)
  assert(rawequal(pointer, h.pointer) and h.native_closed)
  h.disposes = h.disposes + 1; return 0
 end
 local library = setmetatable({}, { __index = function(_, key)
  local name = key:match("^ergopti_archive_publication_(.+)$")
  return symbols[name]
 end })
 local ffi = { os = "Linux", C = {}, cdef = function() end, cast = function(_, value) return value end }
 function ffi.load(path)
  assert(path == "/actual-driver/bin/libergopti_archive_publication.so")
  if options.missing then error("native component absent") end
  return library
 end
 function ffi.new(ctype)
  if ctype == "int[1]" then return { [0] = -1 } end
  if ctype == "struct ergopti_archive_publication *[1]" or ctype == "char[4352]" then return {} end
  error("unexpected fixture native allocation " .. ctype)
 end
 function ffi.string(buffer, length)
  return (buffer.text .. string.rep("\0", math.max(0, length - #buffer.text))):sub(1, length)
 end
 function ffi.C.close(fd)
  assert(fd == 97); h.closes = h.closes + 1
  if options.close_refused then return -1 end
  h.fd_closed = true; return 0
 end
 function ffi.errno() return 13 end
 function ffi.C.ftruncate(fd) assert(fd == 97); h.bytes = ""; return 0 end
 function ffi.C.open() error("original pathname open must never be used") end
 package.loaded.ffi = ffi
 package.loaded.luv = { hrtime = function() return h.now * 1e6 end,
  fs_write = function(fd, chunk, offset, callback)
   assert(fd == 97 and offset == #h.bytes)
   h.writes[#h.writes + 1] = { chunk = chunk, callback = callback }; return {}
  end }
 package.loaded["infra.paths"] = { driver_root = function() return "/actual-driver" end }
 package.loaded["infra.monotonic"] = { now_ms = function() return h.now end,
  has_hires = function() return options.coarse ~= true end, backend = function() return "luv.hrtime" end }
 package.loaded["infra.managed_http_deadline"] = { start = function(_, callback)
  h.expire = callback
  if options.timer_throw then error("unknown timer construction") end
  return timer
 end }
 package.loaded["infra.fd_sha256"] = { native = function() return { start = function(fd, bytes, current, deadline, callback)
  assert(fd == 97 and bytes == 3 and deadline == 50.5 and current() == true)
  h.hashes = h.hashes + 1; h.hash_callback = callback; return hash
 end } end }
 h.factory, h.unavailable = Output.native_artifact("ergopti-linux.tar.gz")
 function h:reserve()
  self.brand, self.target = self.factory.reserve_transfer({ tag = "1.2.3", download_url = "https://release/archive",
   checksum_url = "https://release/checksum" }, {}, function()
   if self.lineage_probe then self.lineage_probe() end
   return self.source
  end, function()
   if self.phase_probe then self.phase_probe() end
   return self.phase
  end, 100.5)
  return self.brand, self.target
 end
 function h:complete()
  local producer = { settled = false }
  function producer:is_settled() return self.settled end
  function producer:on_settled(fn) h.producer_ack = fn; return true end
  local input = { closed = false }
  function input:reader_closed() return self.closed end
  function input:on_reader_closed(_, _, fn) h.reader_ack = fn; return true end
  function input:abort() h.aborted = true; return true end
  function input:pause() return true end
  function input:resume() return true end
  function input:live() return h.source end
  function input:write_ack() end
  function input:continuation_receipt(_, owner, result)
   if not rawequal(owner, producer) or not rawequal(result, h.result) then return nil end
   return { result = result, reader_eof = true, physical_settled = producer.settled, cancelled = false, received_bytes = 3 }
  end
  local sink = assert(Target.attach(self.target, producer, input))
  assert(sink:consume("abc"))
  self.bytes = "abc"; self.writes[1].callback(nil, 3)
  assert(sink:eof()); input.closed = true; self.reader_ack()
  producer.settled = true; self.producer_ack()
  self.result = { ok = true }
  self.completion = assert(Target.complete(self.target, producer, self.result))
  assert(self.factory.bind_checksum(self.brand, ABC_SHA256))
 end
 function h:adopt()
  self.operation = self.factory.seal_and_adopt(self.brand, self.completion, ABC_SHA256, 50.5, function(path, error_message, receipt)
   self.callbacks[#self.callbacks + 1] = { path = path, error = error_message, receipt = receipt }
  end)
  return self.operation
 end
 return h
end
local function controlled(options, body)
 local saved = {}
 local names = { "ffi", "luv", "infra.paths", "infra.monotonic", "infra.managed_http_deadline", "infra.fd_sha256" }
 for _, name in ipairs(names) do saved[name] = package.loaded[name] end
 local ok, err = xpcall(function() body(fixture(options)) end, debug.traceback)
 for _, name in ipairs(names) do package.loaded[name] = saved[name] end
 if not ok then error(err, 0) end
end
for _, options in ipairs({ { missing = true }, { abi = 2 }, { coarse = true }, { clock_offset = 1 } }) do
 test("native prerequisite refusal " .. (options.missing and "missing" or options.abi and "ABI" or options.coarse and "coarse" or "clock"), function()
  controlled(options, function(h)
   assert(h.factory == nil and h.creates == 0 and h.opens == 0)
   assert(h.unavailable.cause == "unknown" and h.unavailable.message_key == "network.failure.unknown")
  end)
 end)
end
test("private factory reserves actual allocation and exports only brand/target", function()
 controlled({}, function(h)
  h:reserve(); assert(type(h.brand) == "table" and type(h.target) == "table")
  assert(next(h.brand) == nil and h.opens == 1 and h.creates == 1 and not h.factory.transfer_settled(h.brand))
  h.factory.cancel_transfer(h.brand); assert(h.closes == 1 and h.cleanups == 0)
  h:timer_ack(); assert(h.factory.transfer_settled(h.brand) and h.cleanups == 1 and h.disposes == 1)
 end)
end)
test("timer refusal retains original owner until exact timer ACK", function()
 controlled({ timer_started = false }, function(h)
  h:reserve(); assert(h.target == nil and h.opens == 1 and h.closes == 1)
  assert(not h.factory.transfer_settled(h.brand) and h.cleanups == 0)
  h:timer_ack(); assert(h.factory.transfer_settled(h.brand) and h.cleanups == 1)
 end)
end)
test("ambiguous timer constructor cannot invent transfer settlement", function()
 controlled({ timer_throw = true }, function(h)
  h:reserve(); assert(h.target == nil and h.closes == 1)
  h:timer_ack(); assert(not h.factory.transfer_settled(h.brand) and h.cleanups == 0)
 end)
end)
test("same-FD staging waits for physical hash then original timer ACK before commit", function()
 controlled({}, function(h)
  h:reserve(); h:complete(); assert(h:adopt())
  assert(h.stages == 0 and h.commits == 0 and not h.operation:is_settled())
  h:hash_ack(ABC_SHA256); assert(h.stages == 1 and h.closes == 1 and h.commits == 0)
  assert(#h.callbacks == 0 and not h.factory.transfer_settled(h.brand))
  h:timer_ack(); assert(h.commits == 1 and h.operation:is_settled() and h.factory.transfer_settled(h.brand))
  assert(#h.callbacks == 1 and h.callbacks[1].path == "/tmp/controlled-private/ergopti-linux.tar.gz")
 end)
end)
test("matching digest cannot override actual typed read failure", function()
 controlled({}, function(h)
  h:reserve(); h:complete(); h:adopt()
  h:hash_ack(ABC_SHA256, { native_errno = "EIO" })
  assert(h.stages == 0 and h.commits == 0)
  h:timer_ack(); assert(h.operation:is_settled() and h.callbacks[1].path == nil)
  assert(h.callbacks[1].receipt.stage == "file_read" and h.callbacks[1].receipt.native_errno == "EIO")
 end)
end)
test("independent wrong checksum never stages a retained inode", function()
 controlled({}, function(h)
  h:reserve(); h:complete(); h:adopt(); h:hash_ack(string.rep("0", 64))
  assert(h.stages == 0 and h.commits == 0)
  h:timer_ack(); assert(h.operation:is_settled() and h.callbacks[1].path == nil)
 end)
end)
test("late old timer ACK refuses original-deadline publication and cleans staged debt", function()
 controlled({}, function(h)
  h:reserve(); h:complete(); h:adopt(); h:hash_ack(ABC_SHA256)
  h.now = 50.5; h:timer_ack()
  assert(h.stages == 1 and h.commits == 0 and h.cleanups == 1)
  assert(h.operation:is_settled() and h.callbacks[1].path == nil)
 end)
end)
test("old FD close refusal retains debt and prevents publication", function()
 controlled({ close_refused = true }, function(h)
  h:reserve(); h:complete(); h:adopt(); h:hash_ack(ABC_SHA256); h:timer_ack()
  assert(h.stages == 1 and h.closes == 1 and h.commits == 0 and h.cleanups == 0)
  assert(not h.operation:is_settled() and #h.callbacks == 0)
 end)
end)
test("C policy refusal cannot fabricate a native permission cause", function()
 controlled({ stage = function() return -1 end }, function(h)
  h:reserve(); h:complete(); h:adopt(); h:hash_ack(ABC_SHA256); h:timer_ack()
  assert(h.stages == 1 and h.commits == 0 and h.operation:is_settled())
  assert(h.callbacks[1].path == nil and h.callbacks[1].receipt == nil)
 end)
end)
test("stage reentrant source withdrawal retires exact transfer without commit", function()
 controlled({ stage = function(h) h.source = false; return 0 end }, function(h)
  h:reserve(); h:complete(); h:adopt(); h:hash_ack(ABC_SHA256); h:timer_ack()
  assert(h.stages == 1 and h.commits == 0 and h.callbacks[1].path == nil)
 end)
end)
test("forged equality brand never borrows registry authority", function()
 controlled({}, function(h)
  h:reserve()
  local calls = 0; local mt = { __eq = function() calls = calls + 1; return true end }
  setmetatable(h.brand, mt)
  local forged = setmetatable({}, mt)
  local ok, err = xpcall(function()
   assert(h.factory.bind_checksum(forged, ABC_SHA256) == false)
   assert(h.factory.cancel_transfer(forged) == false and calls == 0)
  end, debug.traceback)
  setmetatable(h.brand, nil)
  if not ok then error(err, 0) end
  h.factory.cancel_transfer(h.brand); h:timer_ack()
 end)
end)
test("mutable public operation fields cannot manufacture physical ACK", function()
 controlled({}, function(h)
  h:reserve(); h:complete(); h:adopt()
  h.operation.done = true; h.operation.listeners = {}; h.operation.constructing = false
  assert(not h.operation:is_settled() and not h.factory.transfer_settled(h.brand))
  h:hash_ack(ABC_SHA256); assert(not h.operation:is_settled())
  h:timer_ack(); assert(h.operation:is_settled())
 end)
end)
test("immutable checksum admission refuses reentrant second commitment", function()
 controlled({}, function(h)
  h:reserve()
  local nested
  h.phase_probe = function()
   h.phase_probe = nil
   nested = h.factory.bind_checksum(h.brand, string.rep("0", 64))
  end
  assert(h.factory.bind_checksum(h.brand, ABC_SHA256) == true and nested == false)
  assert(h.factory.bind_checksum(h.brand, string.rep("0", 64)) == false)
  h.factory.cancel_transfer(h.brand); h:timer_ack()
 end)
end)
test("original adoption reserves before reentrant initial phase probe", function()
 controlled({}, function(h)
  h:reserve(); h:complete()
  local nested
  h.phase_probe = function()
   h.phase_probe = nil
   nested = h.factory.seal_and_adopt(h.brand, h.completion, ABC_SHA256, 50.5, function() error("nested publication") end)
  end
  assert(h:adopt() ~= nil and nested == nil and h.hashes == 1)
  h:hash_ack(ABC_SHA256); h:timer_ack(); assert(#h.callbacks == 1)
 end)
end)
test("lineage cancellation during finishing delivers one refusal and no commit", function()
 controlled({}, function(h)
  h:reserve(); h:complete(); h:adopt(); h:hash_ack(ABC_SHA256)
  h.lineage_probe = function()
   h.lineage_probe = nil; h.factory.cancel_transfer(h.brand)
  end
  h:timer_ack()
  assert(h.commits == 0 and h.cleanups == 1 and #h.callbacks == 1)
  assert(h.callbacks[1].path == nil and h.operation:is_settled())
 end)
end)
test("physical lease probe cancellation cannot duplicate finishing", function()
 controlled({}, function(h)
  h:reserve(); h:complete(); h:adopt(); h:hash_ack(ABC_SHA256)
  h.timer_probe = function()
   h.timer_probe = nil; h.factory.cancel_transfer(h.brand)
  end
  h:timer_ack()
  assert(h.commits == 0 and h.cleanups == 1 and #h.callbacks == 1)
  assert(h.callbacks[1].path == nil and h.operation:is_settled())
 end)
end)
for _, options in ipairs({ { no_display_nul = true }, { empty_display = true } }) do
 test("bounded display refusal " .. (options.no_display_nul and "no terminator" or "empty"), function()
  controlled(options, function(h)
   h:reserve(); h:complete(); h:adopt(); h:hash_ack(ABC_SHA256); h:timer_ack()
   assert(h.commits == 1 and h.cleanups == 1 and #h.callbacks == 1 and h.callbacks[1].path == nil)
  end)
 end)
end
test("foreign artifact completion is refused before hash and remains unconsumed", function()
 controlled({}, function(h)
  h:reserve(); h:complete()
  controlled({}, function(foreign)
   foreign:reserve(); foreign:complete()
   local refused = h.factory.seal_and_adopt(h.brand, foreign.completion, ABC_SHA256, 50.5, function() end)
   assert(refused ~= nil and refused.started == false and h.hashes == 0 and foreign.hashes == 0)
   h:timer_ack(); assert(refused:is_settled())
   assert(foreign:adopt() ~= nil and foreign.hashes == 1)
   foreign:hash_ack(ABC_SHA256); foreign:timer_ack(); assert(#foreign.callbacks == 1)
  end)
 end)
end)
assert(#tests == 23, "native registry independent control floor")

-- Genuine normal registration retains every independent body and oracle.
local helpers = require("tests.helpers")
helpers.describe("Native Artifact Registry", function()
	assert(#tests == 23, "Independent case floor changed")
	for _, case in ipairs(tests) do
		assert(type(case[1]) == "string" and type(case[2]) == "function", "Independent registration refused")
		helpers.it(case[1], case[2])
	end
end)
return tests
