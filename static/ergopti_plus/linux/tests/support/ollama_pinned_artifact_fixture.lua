--- tests/support/ollama_pinned_artifact_fixture.lua

--- Controlled native ports for the actual pinned registry, not C/kernel evidence.
local Output = require("infra.archive_output")
local Target = require("infra.http_output_target")
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
  assert(name == "ollama-linux-amd64.tar.zst" and deadline == 50.5)
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
   or "/tmp/controlled-private/ollama-linux-amd64.tar.zst"
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
 symbols.allocate_reader = function() h.readers = (h.readers or 0) + 1; error("admission controls must not allocate readers") end
 for _, name in ipairs({ "new_pipe", "fs_read", "fs_close", "write", "shutdown" }) do
  package.loaded.luv[name] = function() error("admission controls must not acquire reader I/O") end
 end
 local saved_process = package.loaded["adapters.owned_process"]
 package.loaded["adapters.owned_process"] = { start = function() error("admission controls must not spawn") end }
 local restore = h.restore
 function h.restore() restore(); package.loaded["adapters.owned_process"] = saved_process end
 h.asset = { key = "linux-amd64", version = "0.24.0", name = "ollama-linux-amd64.tar.zst",
  url = "https://github.com/ollama/ollama/releases/download/v0.24.0/ollama-linux-amd64.tar.zst", bytes = 3, sha256 = ABC_SHA256 }
 h.budget = {
  current = function() return h.master_current ~= false end,
  deadline_ms = function() return h.master_current ~= false and (h.master_deadline or 100.5) or nil end,
  on_cancel = function(callback) h.master_cancel = callback; return options.subscribe_refused ~= true end,
 }
 h.factory, h.unavailable = Output.native_ollama_artifact(h.asset)
 function h:reserve()
  self.transaction = {}
  self.brand, self.target = self.factory.reserve_ollama(self.transaction, function()
   if self.lineage_probe then self.lineage_probe() end
   return self.source
  end, function()
   if self.phase_probe then self.phase_probe() end
   return self.phase
  end, self.budget)
  return self.brand, self.target
 end
 function h:begin_delivery()
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
  self.producer, self.input = producer, input
  return sink
 end
 function h:complete()
  local sink = self:begin_delivery()
  local producer, input = self.producer, self.input
  assert(sink:consume("abc"))
  self.bytes = "abc"; self.writes[1].callback(nil, 3)
  assert(sink:eof()); input.closed = true; self.reader_ack()
  producer.settled = true; self.producer_ack()
  self.result = { ok = true }
  self.completion = assert(Target.complete(self.target, producer, self.result))
  assert(self.factory.bind_checksum(self.brand, ABC_SHA256) == false, "canonical digest bound before delivery")
 end
 function h:adopt()
  self.operation = self.factory.seal_and_adopt(self.brand, self.completion, ABC_SHA256, 50.5, function(path, error_message, receipt)
   self.callbacks[#self.callbacks + 1] = { path = path, error = error_message, receipt = receipt }
  end)
  return self.operation
 end
 return h
end

return fixture
