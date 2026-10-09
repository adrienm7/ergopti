--- tests/unit/infra/test_native_artifact_cleanup_retry.lua

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
 if not options.legacy then
  symbols.cleanup_with_disposition = function(pointer, out)
   assert(rawequal(pointer, h.pointer) and h.fd_closed and h.timer_settled)
   assert(out[0] == 0, "disposition must initialize UNKNOWN for each attempt")
   h.cleanups = h.cleanups + 1
   local row = options.rows[math.min(h.cleanups, #options.rows)]
   out[0] = row[2]
   if options.cleanup_hook then options.cleanup_hook(h) end
   if row[1] == "throw" then error("controlled unknown native cleanup") end
   if row[1] == 0 then h.native_closed = true end
   return row[1]
  end
 elseif options.legacy_refused then
  symbols.cleanup = function(pointer)
   assert(rawequal(pointer, h.pointer)); h.cleanups = h.cleanups + 1; return -1
  end
 end
 symbols.descriptors_closed = function(pointer) assert(rawequal(pointer, h.pointer)); return h.native_closed and 1 or 0 end
 symbols.named_remaining = function(pointer) assert(rawequal(pointer, h.pointer)); return h.native_closed and not options.names_refused and 0 or 1 end
 symbols.dispose_unpublished = function(pointer)
  assert(rawequal(pointer, h.pointer) and h.native_closed)
  h.disposes = h.disposes + 1; return options.dispose_refused and -1 or 0
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
 function ffi.new(ctype, initial)
  if ctype == "int[1]" then return { [0] = initial or -1 } end
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

local function prepared(options, body)
 controlled(options, function(h)
  h:reserve()
  assert(h.factory.cancel_transfer(h.brand))
  h:timer_ack()
  body(h)
 end)
end
local function retry(h) return h.factory.retry_transfer_cleanup(h.brand) end
local function held(h)
 assert(not h.factory.transfer_settled(h.brand) and h.disposes == 0)
end

test("legacy failed cleanup remains exactly one attempted native call", function()
 prepared({ legacy = true, legacy_refused = true }, function(h)
  held(h); assert(not retry(h)); h.factory.cancel_transfer(h.brand)
  assert(h.cleanups == 1 and h.disposes == 0)
 end)
end)
test("typed UNKNOWN remains one attempt despite explicit later retry", function()
 prepared({ rows = { { -1, 0 } } }, function(h)
  held(h); assert(not retry(h)); assert(h.cleanups == 1)
 end)
end)
test("acknowledged still-present namespace conflict permits serialized retry only", function()
 prepared({ rows = { { -1, 1 } } }, function(h)
  held(h); assert(h.cleanups == 1)
  assert(not retry(h)); held(h); assert(h.cleanups == 2)
 end)
end)
test("fixture removal acknowledges cleanup of same original namespace owner", function()
 prepared({ rows = { { -1, 1 }, { 0, 0 } } }, function(h)
  local callbacks = 0
  assert(h.factory.on_transfer_settled(h.brand, function() callbacks = callbacks + 1 end))
  assert(retry(h)); assert(h.cleanups == 2 and h.closes == 1 and h.disposes == 1 and callbacks == 1)
  assert(h.factory.transfer_settled(h.brand) and not retry(h))
  assert(h.cleanups == 2 and h.disposes == 1 and callbacks == 1)
 end)
end)
test("native throw cannot mint a retry even after writing conflict output", function()
 prepared({ rows = { { "throw", 1 } } }, function(h)
  held(h); assert(not retry(h)); assert(h.cleanups == 1)
 end)
end)
test("boolean conflict output is not an exact native receipt", function()
 prepared({ rows = { { -1, true } } }, function(h)
  held(h); assert(not retry(h)); assert(h.cleanups == 1)
 end)
end)
test("unknown conflict enumeration is never replay authority", function()
 prepared({ rows = { { -1, 2 } } }, function(h)
  held(h); assert(not retry(h)); assert(h.cleanups == 1)
 end)
end)
test("unexpected positive native status cannot mint conflict authority", function()
 prepared({ rows = { { 1, 1 } } }, function(h)
  held(h); assert(not retry(h)); assert(h.cleanups == 1)
 end)
end)
test("successful status with conflict output does not acknowledge closure", function()
 prepared({ rows = { { 0, 1 } } }, function(h)
  held(h); assert(not retry(h)); assert(h.cleanups == 1)
 end)
end)
test("physical probe refusal preserves receipt until exact original ACK", function()
 prepared({ rows = { { -1, 1 }, { 0, 0 } } }, function(h)
  h.timer_settled = false
  assert(not retry(h) and h.cleanups == 1 and h.disposes == 0)
  h.timer_settled = true
  assert(retry(h) and h.cleanups == 2 and h.disposes == 1)
 end)
end)
test("foreign raw brand cannot consume the original private receipt", function()
 prepared({ rows = { { -1, 1 }, { 0, 0 } } }, function(h)
  assert(not h.factory.retry_transfer_cleanup({}) and h.cleanups == 1)
  assert(retry(h) and h.cleanups == 2 and h.disposes == 1)
 end)
end)
test("retry port cannot cancel or retire a live uncancelled transaction", function()
 controlled({ rows = { { 0, 0 } } }, function(h)
  h:reserve(); assert(not retry(h) and h.cleanups == 0 and h.closes == 0)
  h.factory.cancel_transfer(h.brand); h:timer_ack()
  assert(h.cleanups == 1 and h.closes == 1 and h.disposes == 1)
 end)
end)
test("native cleanup reentry cannot replay one original attempt twice", function()
 local options = { rows = { { -1, 1 }, { 0, 0 } } }
 prepared(options, function(h)
  options.cleanup_hook = function()
   assert(not retry(h)); assert(not h.factory.transfer_settled(h.brand))
  end
  assert(retry(h)); assert(h.cleanups == 2 and h.disposes == 1)
 end)
end)
test("physical probe reentry cannot acquire nested cleanup", function()
 prepared({ rows = { { -1, 1 }, { 0, 0 } } }, function(h)
  h.timer_probe = function() assert(not retry(h)); assert(h.cleanups == 1) end
  assert(retry(h)); assert(h.cleanups == 2 and h.disposes == 1)
 end)
end)
test("known conflict retirement cannot reactivate revoked publication source", function()
 prepared({ rows = { { -1, 1 }, { 0, 0 } } }, function(h)
  h.source, h.phase = false, false
  assert(retry(h)); assert(h.stages == 0 and h.commits == 0 and h.cleanups == 2 and h.disposes == 1)
 end)
end)
test("post-cleanup named debt refuses disposal and all later cleanup attempts", function()
 prepared({ rows = { { 0, 0 } }, names_refused = true }, function(h)
  held(h); assert(not retry(h)); assert(h.cleanups == 1 and h.disposes == 0)
 end)
end)
test("dispose refusal cannot reclose or redispose consumed native owners", function()
 prepared({ rows = { { 0, 0 } }, dispose_refused = true }, function(h)
  assert(not h.factory.transfer_settled(h.brand) and h.disposes == 1)
  assert(not retry(h)); h.factory.cancel_transfer(h.brand)
  assert(h.cleanups == 1 and h.closes == 1 and h.disposes == 1)
 end)
end)
assert(#tests == 17, "Independent cleanup retry receiving floor changed")

test("committed first retirement attempts cleanup once and later intent consumes receipt", function()
 controlled({ rows = { { -1, 1 }, { 0, 0 } } }, function(h)
  h:reserve(); h:complete(); h:adopt(); h:hash_ack(ABC_SHA256); h:timer_ack()
  assert(h.commits == 1 and #h.callbacks == 1 and h.cleanups == 0)
  assert(not h.factory.retire_artifact(h.brand))
  assert(h.cleanups == 1 and h.disposes == 0 and not h.factory.artifact_settled(h.brand))
  assert(h.factory.retire_artifact(h.brand))
  assert(h.cleanups == 2 and h.disposes == 1 and h.factory.artifact_settled(h.brand))
  assert(#h.callbacks == 1)
 end)
end)
test("first-retirement native reentry cannot consume freshly observed conflict", function()
 local options = { rows = { { -1, 1 }, { 0, 0 } } }
 controlled(options, function(h)
  h:reserve(); h:complete(); h:adopt(); h:hash_ack(ABC_SHA256); h:timer_ack()
  local nested, listeners = nil, 0
  assert(h.factory.on_artifact_settled(h.brand, function() listeners = listeners + 1 end))
  options.cleanup_hook = function() nested = h.factory.retire_artifact(h.brand) end
  assert(not h.factory.retire_artifact(h.brand))
  assert(nested == false and h.cleanups == 1 and h.disposes == 0 and listeners == 0)
  options.cleanup_hook = nil
  assert(h.factory.retire_artifact(h.brand))
  assert(h.cleanups == 2 and h.disposes == 1 and listeners == 1 and #h.callbacks == 1)
 end)
end)
assert(#tests == 19, "Independent cleanup retry extension floor changed")
local helpers = require("tests.helpers")
helpers.describe("Native Artifact Cleanup Retry", function()
 for _, case in ipairs(tests) do helpers.it(case[1], case[2]) end
end)
return tests
