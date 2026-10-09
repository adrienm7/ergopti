--- static/ergopti_plus/linux/tests/support/ollama_retained_fixture.lua
--- Independent controlled receipts for the actual retained installer branch.
--- No fake child closure is claimed as native/kernel qualification.
local Installer = require("llm.ollama_archive_installer")
local serial = 0
return function()
 serial = serial + 1
 local f = { calls = {}, events = {}, source = true, completions = {}, cleanup = 0, prepares = 0,
  target = {}, brand = {}, token = {}, completion = {}, deadline = 700, current = true, cancellation = {} }
 local function launch(program, options, callback, settled_hook)
  local c = { program = program, options = options, callback = callback, listeners = {}, closed = false, signals = 0 }
  local op = { started = true }; c.operation = op; f.calls[#f.calls + 1] = c
  function op:cancel() c.signals = c.signals + 1; return false end
  function op:is_settled() return c.closed end
  function op:on_settled(fn) c.listeners[#c.listeners + 1] = fn; if c.closed then fn() end; return true end
  function c.deliver(result, completion)
   local defaults = {
    ["tar-version"] = "tar (GNU tar) 1.35", ["tar-help"] = "--zstd --no-same-owner --no-same-permissions",
    ["mv-help"] = "GNU coreutils --no-clobber --no-target-directory", ["zstd"] = "Zstandard CLI",
   }
   if program == "ADOPT" then callback("/informational/never-open/archive", f.bad_hash and "mismatch" or nil, nil)
   else
    local receipt = completion or (program == "HTTP" and f.completion or nil)
    if f.missing_completion and program == "HTTP" then receipt = nil end
    callback(result or { ok = true, exit_code = 0, status = program == "HTTP" and 200 or nil, stdout = defaults[program] or "" }, receipt)
   end
  end
  function c.retire()
   c.closed = true; if settled_hook then settled_hook() end
   for _, fn in ipairs(c.listeners) do fn() end
  end
  return op
 end
 local files = { directory = "/controlled/retained-" .. serial .. "/ollama", published = false, current = function() return f.source end }
 function files.prepare_retained() f.prepares = f.prepares + 1; return { stage = "/controlled/private-stage" } end
 function files.retained_stage(current) assert(current()); return "/controlled/private-stage" end
 function files.admit_retained_extraction(result, current) assert(current()); return result.ok == true and result.exit_code == 0, "archive_extraction_refused" end
 function files.publish_command() return "mv", { "--no-clobber", "--no-target-directory", "--", "/controlled/private-stage", files.directory } end
 function files.admit_publication(result) if f.foreign then return false, "install_publication_not_owned" end; files.published = result.ok and result.exit_code == 0; return files.published end
 function files.cleanup() f.cleanup = f.cleanup + 1; return true end
 for _, name in ipairs({ "prepare", "admit_size", "hash_command", "admit_checksum", "extract_command", "admit_extraction" }) do
  files[name] = function() error("legacy archive path may not be used by retained consumer: " .. name) end
 end
 f.files = files
 local registry = {}
 function registry.reserve_ollama(transaction, lineage, phase, budget)
  assert(transaction == f.operation and lineage() and phase())
  assert(budget.current == f.options.budget.current and budget.deadline_ms == f.options.budget.deadline_ms
   and budget.on_cancel == f.options.budget.on_cancel)
  f.reserved = true; if f.refuse_target then return f.brand, nil end; return f.brand, f.target
 end
 function registry.seal_and_adopt(brand, completion, digest, deadline, done)
  assert(brand == f.brand and completion == f.completion and deadline == 700)
  assert(digest == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  return launch("ADOPT", { deadline = deadline }, done, function() f.adopted = not f.bad_hash end)
 end
 function registry.begin_ollama_install(brand, transaction, admission, execution)
  assert(brand == f.brand and transaction == f.operation and f.adopted and admission() and execution())
  f.installing = true; return f.token
 end
 function registry.install_current(token) return token == f.token and f.current and f.source end
 function registry.install_feed(token, mode, directory, done)
  assert(token == f.token and mode == "extract" and directory == "/controlled/private-stage")
  local op = launch("EXTRACT", { directory = directory }, done); op.started = nil; return op
 end
 function registry.finish_install(token, keep, done)
  assert(token == f.token and keep == false)
  return launch("ARTIFACT_FINISH", {}, done, function() f.artifact_closed = true end)
 end
 function registry.cancel_transfer(brand) assert(brand == f.brand); f.artifact_signalled = true; return true end
 function registry.retire_artifact(brand) assert(brand == f.brand); f.artifact_closed = true; return true end
 function registry.artifact_settled(brand) assert(brand == f.brand); return f.artifact_closed == true end
 function registry.on_artifact_settled(brand, listener) assert(brand == f.brand); f.artifact_listener = listener; return true end
 f.registry = registry
 f.ports = { files = files, archive_factory = { native_ollama_artifact = function(asset)
  assert(asset.key == "linux-amd64" and asset.bytes == 3 and asset.version == "0.24.0")
  return registry
 end }, http = { get_owned = function() error("retained consumer may not use path HTTP") end,
  download_output_owned = function(url, headers, target, options, done)
   assert(url == "https://github.com/ollama/ollama/releases/download/v0.24.0/ollama-linux-amd64.tar.zst")
   assert(target == f.target and next(headers) == nil and options.output_path == nil and options.output_target == nil)
   assert(options.absolute_deadline_ms == 700 and options.max_download_bytes == 3 and options.authorized())
   return launch("HTTP", options, done)
  end }, process = { start = function(program, args, options, done)
   local label = program == "tar" and (args[1] == "--version" and "tar-version" or "tar-help")
    or program == "mv" and (args[1] == "--help" and "mv-help" or "PUBLISH") or program
   assert(program ~= "sha256sum", "same-FD digest does not dispatch a pathname checksum")
   return launch(label, options, done)
  end } }
 f.options = { explicit_consent = true, timeout_ms = 600, helper_timeout_ms = 50, authorized = function() return f.source end,
  asset = { key = "linux-amd64", version = "0.24.0", name = "ollama-linux-amd64.tar.zst", bytes = 3,
   url = "https://github.com/ollama/ollama/releases/download/v0.24.0/ollama-linux-amd64.tar.zst",
   sha256 = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" },
  budget = { current = function() return f.current end, deadline_ms = function() return f.current and f.deadline or nil end,
   remaining_ms = function() return f.current and (f.remaining or 600) or nil end,
   on_cancel = function(fn) f.cancellation[#f.cancellation + 1] = fn; return true end } }
 function f.start()
  f.operation = Installer.start(f.ports, f.options, function(result) f.completions[#f.completions + 1] = result end)
  return f.operation
 end
 function f.through(index)
  for i = #f.calls, index do local c = assert(f.calls[i]); c.deliver(); assert(#f.calls == i); c.retire() end
 end
 return f
end
