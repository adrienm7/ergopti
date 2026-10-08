--- tests/unit/modules/updater/test_archive_transfer_publication.lua

--- Actual production transfer with independent literal child receipts. These
--- controlled physical ACKs do not qualify native HTTP, FD or publication.
local Transfer = require("modules.updater.archive_transfer")
local tests = {}
local function test(name, body) tests[#tests + 1] = { name, body } end
local function fixture()
 local h = { now = 0.25, active = true, children = {}, archives = 0, adoptions = 0,
  callbacks = {}, reservations = 0, bound = 0 }
 local artifact, target = {}, {}
 local function child(kind, callback)
  local work = { callback = callback, physical = false, listeners = {} }
  local operation = { started = true }
  function operation:is_settled()
   if work.probe then work.probe() end
   return work.physical
  end
  function operation:request_cancel() work.cancelled = true; return true end
  function operation:on_settled(listener) work.listeners[#work.listeners + 1] = listener; return true end
  work.operation = operation
  function work:reply(result, completion) self.callback(result, completion) end
  function work:ack()
   self.physical = true
   for _, listener in ipairs(self.listeners) do listener() end
  end
  h.children[kind] = work
  return operation
 end
 local ports = {
  clock = function() return h.now end,
  current = function()
   if h.source_probe then h.source_probe() end
   return h.active
  end,
  defaults = { archive_transfer = { schema_version = 1,
   phase_timeout_ms = { checksum = 15000, archive = 300000, hash = 15000 } } },
  headers = { Accept = "application/octet-stream" },
  parse_checksum = function(body) assert(body == "literal-checksum-record"); return string.rep("a", 64) end,
  http = {
   get_owned = function(url, _, options, done)
    assert(url == "https://release.invalid/checksum" and options.authorized() == true)
    assert(options.absolute_deadline_ms == 15000.25)
    return child("checksum", done)
   end,
   download_output_owned = function(url, _, output, options, done)
    assert(url == "https://release.invalid/archive" and rawequal(output, target) and options.authorized() == true)
    assert(options.absolute_deadline_ms == 300000.25)
    h.archives = h.archives + 1
    return child("archive", done)
   end,
  },
  artifact = {
   reserve_transfer = function(meta, txn, lineage, current, deadline)
    assert(meta.tag == "v1.2.3" and deadline == 330000.25 and lineage() == true and current() == true)
    h.transaction = txn; h.reservations = h.reservations + 1; return artifact, target
   end,
   bind_checksum = function(brand, expected)
    assert(rawequal(brand, artifact) and expected == string.rep("a", 64)); h.bound = h.bound + 1; return true
   end,
   seal_and_adopt = function(brand, completion, expected, deadline, done)
    assert(rawequal(brand, artifact) and rawequal(completion, h.completion))
    assert(expected == string.rep("a", 64) and deadline == 15000.25)
    h.adoptions = h.adoptions + 1
    return child("adoption", function(result) done(result.path, result.error, result.receipt) end)
   end,
   cancel_transfer = function(brand) assert(rawequal(brand, artifact)); h.cancelled = true; return true end,
   transfer_settled = function(brand) assert(rawequal(brand, artifact)); return h.artifact_physical == true end,
   on_transfer_settled = function(brand, listener) assert(rawequal(brand, artifact)); h.artifact_listener = listener; return true end,
  },
 }
 local factory = assert(Transfer.new(ports))
 h.operation = assert(factory:start({ tag = "v1.2.3", download_url = "https://release.invalid/archive",
  checksum_url = "https://release.invalid/checksum" }, function(...)
  h.callbacks[#h.callbacks + 1] = { ... }
 end))
 assert(h.operation.started == true and h.reservations == 1)
 function h:complete()
  assert(self.archives == 1)
  self.completion = {}; self.children.archive:reply({ ok = true }, self.completion); self.children.archive:ack()
  assert(self.adoptions == 1)
  self.artifact_physical = true
  self.children.adoption:reply({ path = "display-information-only" }); self.children.adoption:ack()
  assert(#self.callbacks == 1 and self.callbacks[1][1] == "display-information-only")
  assert(rawequal(self.callbacks[1][5], artifact) and self.operation:is_settled() == true)
  self.children.checksum.listeners[1](); self.children.archive.listeners[1](); self.children.adoption.listeners[1]()
  assert(self.archives == 1 and self.adoptions == 1 and #self.callbacks == 1)
 end
 return h
end
test("checksum source probe reentry cannot acquire archive twice", function()
 local h = fixture(); local checksum = h.children.checksum
 checksum:reply({ ok = true, body = "literal-checksum-record" })
 h.source_probe = function() h.source_probe = nil; checksum.listeners[1]() end
 checksum:ack()
 assert(h.archives == 1 and h.bound == 1)
 h:complete()
end)
test("checksum physical probe reentry cannot acquire archive twice", function()
 local h = fixture(); local checksum = h.children.checksum
 checksum:reply({ ok = true, body = "literal-checksum-record" })
 checksum.probe = function() checksum.probe = nil; checksum.listeners[1]() end
 checksum:ack()
 assert(h.archives == 1 and h.bound == 1)
 h:complete()
end)
test("adoption source probe reentry consumes one completion", function()
 local h = fixture(); h.children.checksum:reply({ ok = true, body = "literal-checksum-record" }); h.children.checksum:ack()
 h.completion = {}; h.children.archive:reply({ ok = true }, h.completion); h.children.archive:ack()
 local adoption = h.children.adoption; h.artifact_physical = true
 adoption:reply({ path = "display-information-only" })
 h.source_probe = function() h.source_probe = nil; adoption.listeners[1]() end
 adoption:ack()
 assert(h.archives == 1 and h.adoptions == 1 and #h.callbacks == 1 and h.operation:is_settled())
end)
test("physical probe source withdrawal refuses successor acquisition", function()
 local h = fixture(); local checksum = h.children.checksum
 checksum:reply({ ok = true, body = "literal-checksum-record" })
 checksum.probe = function() if checksum.physical then h.active = false end end
 checksum:ack()
 assert(h.archives == 0 and h.adoptions == 0 and h.cancelled == true)
 assert(#h.callbacks == 0 and not h.operation:is_settled())
 h.artifact_physical = true; h.artifact_listener()
 assert(h.operation:is_settled() and #h.callbacks == 0)
end)
assert(#tests == 4, "production phase publication causal-control floor")

-- Genuine normal registration retains every independent body and oracle.
local helpers = require("tests.helpers")
helpers.describe("Archive Phase Publication", function()
	assert(#tests == 4, "Independent case floor changed")
	for _, case in ipairs(tests) do
		assert(type(case[1]) == "string" and type(case[2]) == "function", "Independent registration refused")
		helpers.it(case[1], case[2])
	end
end)
return tests
