--- tests/unit/modules/updater/install/test_archive_transfer_signature.lua

--- The updater transfer fetches the detached signature next to the checksum and
--- asks the signature gate before the adopted archive is released. The gate is
--- replaced by a recorder here: its verdicts per enforcement mode are pinned in
--- test_signature_gate.lua with the real verifier and the shared vectors.
local Transfer = require("modules.updater.archive_transfer")
local tests = {}
local function test(name, body) tests[#tests + 1] = { name, body } end
local function fixture(signature, without_url)
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
  signature = signature,
  parse_checksum = function(body) assert(body == "literal-checksum-record"); return string.rep("a", 64) end,
  http = {
   get_owned = function(url, _, options, done)
    if url == "https://release.invalid/signature" then
     assert(options.max_body_bytes == signature.max_body_bytes and options.absolute_deadline_ms == 15000.25)
     h.signature_fetches = (h.signature_fetches or 0) + 1
     return child("signature", done)
    end
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
   sealed_size = function(brand) assert(rawequal(brand, artifact)); return 4096 end,
   cancel_transfer = function(brand) assert(rawequal(brand, artifact)); h.cancelled = true; return true end,
   transfer_settled = function(brand) assert(rawequal(brand, artifact)); return h.artifact_physical == true end,
   on_transfer_settled = function(brand, listener) assert(rawequal(brand, artifact)); h.artifact_listener = listener; return true end,
  },
 }
 local factory = assert(Transfer.new(ports))
 h.operation = assert(factory:start({ tag = "v1.2.3", download_url = "https://release.invalid/archive",
  checksum_url = "https://release.invalid/checksum",
  signature_url = signature and not without_url and "https://release.invalid/signature" or nil }, function(...)
  h.callbacks[#h.callbacks + 1] = { ... }
 end))
 assert(h.operation.started == true and h.reservations == 1)
 function h:complete()
  assert(self.archives == 1)
  self.completion = {}; self.children.archive:reply({ ok = true }, self.completion); self.children.archive:ack()
  assert(self.adoptions == 1)
  self.artifact_physical = true
  self.children.adoption:reply({ path = "display-information-only" }); self.children.adoption:ack()
  self.children.checksum.listeners[1](); self.children.archive.listeners[1](); self.children.adoption.listeners[1]()
 end
 return h
end

local function gate(verdict)
 local g = { max_body_bytes = 4096, calls = {} }
 function g.decide(asset, text, fetch_error)
  g.calls[#g.calls + 1] = { asset = asset, text = text, fetch_error = fetch_error }
  if verdict == true then return true end
  return false, "update signature refused: the signature does not match the downloaded bundle"
 end
 return g
end
local function run(g, signature_reply)
 local h = fixture(g)
 h.children.checksum:reply({ ok = true, body = "literal-checksum-record" }); h.children.checksum:ack()
 assert(h.signature_fetches == 1 and h.archives == 0, "the archive waits for the signature fetch")
 h.children.signature:reply(signature_reply); h.children.signature:ack()
 assert(h.archives == 1)
 h:complete()
 return h
end
test("a good signature releases the archive with its sealed size and digest", function()
 local g = gate(true)
 local h = run(g, { ok = true, body = "c2ln" })
 assert(#g.calls == 1 and g.calls[1].text == "c2ln" and g.calls[1].fetch_error == nil)
 assert(g.calls[1].asset.size == 4096 and g.calls[1].asset.sha256 == string.rep("a", 64))
 assert(#h.callbacks == 1 and h.callbacks[1][1] == "display-information-only" and h.cancelled ~= true)
end)
test("a bad signature refuses the archive in words", function()
 local g = gate(false)
 local h = run(g, { ok = true, body = "c2ln" })
 assert(#g.calls == 1 and h.cancelled == true)
 assert(#h.callbacks == 1 and h.callbacks[1][1] == nil)
 assert(h.callbacks[1][2]:find("signature does not match", 1, true) and h.callbacks[1][3] == "verify")
end)
test("a missing signature download reaches the gate as a fetch error", function()
 local g = gate(false)
 local h = run(g, { ok = false, error = "HTTP 404" })
 assert(#g.calls == 1 and g.calls[1].text == nil and g.calls[1].fetch_error == "HTTP 404")
 assert(h.callbacks[1][1] == nil and h.callbacks[1][3] == "verify")
end)
test("a release without a signature asset still reaches the gate", function()
 local g = gate(false)
 local h = fixture(g, true)
 h.children.checksum:reply({ ok = true, body = "literal-checksum-record" }); h.children.checksum:ack()
 assert(h.signature_fetches == nil and h.archives == 1)
 h:complete()
 assert(#g.calls == 1 and g.calls[1].text == nil and g.calls[1].fetch_error == nil)
 assert(h.callbacks[1][1] == nil and h.cancelled == true)
end)
test("without a signature port the flow is unchanged", function()
 local h = fixture(nil)
 h.children.checksum:reply({ ok = true, body = "literal-checksum-record" }); h.children.checksum:ack()
 assert(h.archives == 1 and h.signature_fetches == nil)
 h:complete()
 assert(#h.callbacks == 1 and h.callbacks[1][1] == "display-information-only")
end)
assert(#tests == 5, "signature transfer case floor")

local helpers = require("tests.helpers")
helpers.describe("Archive Transfer Signature", function()
	for _, case in ipairs(tests) do
		helpers.it(case[1], case[2])
	end
end)
return tests
