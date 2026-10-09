--- tests/unit/platform/remap/test_key_combination_copy_source.lua

--- Actual Config/SparseWriter/FileSystem composition and real disk bytes.
--- Hammerspoon filesystem primitives and the runtime deploy ACK are controlled ports.
local h = require("tests.helpers")
local with_fs = require("tests.support.file_system_transaction_fixture").with_fixture
local with_remap = require("tests.support.remap_transaction_fixture")
local Codec = require("toml_codec")
local entries = { { id = "left_shift+right_shift" } }
local actions = { { id = "none" }, { id = "escape" }, { id = "layer" }, { id = "caps_word" } }
local SOURCE = '# retained comment\n[mod_combos]\nenabled = false\nsymmetric = true\nsimultaneous_threshold_ms = 87\n[mod_combos.config."left_shift+right_shift"]\ntap = "escape" # tap source\nhold = "layer"\ncombo = "caps_word" # owned slot\nfuture = { token = "untouched" }\n[mod_combos.config.future_pair]\ntap = "unknown_future_action"\n[gesture_parameters]\nfuture_action = "opaque argv and punctuation"\n'
local function seed(path, source)
 local file = assert(io.open(path, "wb")); assert(file:write(source)); assert(file:close())
end
local function read(path)
 local file = assert(io.open(path, "rb")); local source = file:read("*a"); assert(file:close()); return source
end
local function scoped(run, lock)
 return with_fs(function(fixture)
  local path = os.tmpname():gsub("\\", "/")
  local adapter = fixture.make_adapter(nil, nil, nil, nil, lock)
  -- Controlled final-admission port: the actual FileSystem pipeline performs
  -- its disk, source, staging and cleanup work; this test port checks the
  -- captured admission at the rename effect. Native Darwin needs its own API.
  adapter.write_if_unchanged_admitted = function(target, candidate, source, on_error, admission)
   local called, admitted = pcall(admission)
   if not called or admitted ~= true then return false, "controlled admission refused" end
   local native_rename = os.rename
   os.rename = function(from, to)
    local ok, final = pcall(admission)
    if not ok or final ~= true then return nil, "controlled final admission refused" end
    return native_rename(from, to)
   end
   local result = table.pack(pcall(adapter.write_if_unchanged, target, candidate, source, on_error))
   os.rename = native_rename
   if not result[1] then error(result[2], 0) end
   return table.unpack(result, 2, result.n)
  end
  local result = table.pack(xpcall(function()
   return h.with_stub_scope({ "platform.remap.config" }, function()
    local Config = h.load_with_stubs("platform.remap.config")
    seed(path, SOURCE)
    return run(Config, adapter, path)
   end)
  end, debug.traceback))
  os.remove(path); os.remove(path .. fixture.WRITE_LOCK_SUFFIX)
  if not result[1] then error(result[2], 0) end
  return table.unpack(result, 2, result.n)
 end)
end
h.describe("chord copy actual fresh source producer", function()
 h.it("publishes only fresh chord leaves and retains an exact native inverse witness", function()
  scoped(function(Config, adapter, path)
   local plan = Config.prepare_copy_taps_to_chords(entries, actions, path)
   h.assert_eq(plan.expected_source, { status = "ok", content = SOURCE })
   h.assert_eq(plan.changes, 1); h.assert_eq(read(path), SOURCE)
   local accepted, _, receipt = Config.publish_copy_taps_to_chords(plan, path)
   h.assert_eq(accepted, true); h.assert_eq(receipt.path, path)
   h.assert_eq(receipt.source.content, SOURCE); h.assert_eq(receipt.candidate, plan.candidate)
   local published = read(path); h.assert_eq(published, plan.candidate)
   h.assert_true(published:find('# retained comment\n', 1, true) ~= nil)
   h.assert_true(published:find('tap = "escape" # tap source\n', 1, true) ~= nil)
   h.assert_true(published:find('future = { token = "untouched" }\n', 1, true) ~= nil)
   h.assert_true(published:find('future_action = "opaque argv and punctuation"\n', 1, true) ~= nil)
   local saved = Codec.decode(published).mod_combos
   h.assert_eq(saved.config[entries[1].id].combo, "escape")
   h.assert_eq(saved.config[entries[1].id].hold, "layer")
   h.assert_eq(saved.enabled, false); h.assert_eq(saved.symmetric, true); h.assert_eq(saved.simultaneous_threshold_ms, 87)
   h.assert_eq(require("config_file_inverse").restore(receipt, adapter), true)
   h.assert_eq(read(path), SOURCE)
  end)
 end)
 h.it("refuses post-preparation edits and route changes without replacing a successor", function()
  scoped(function(Config, _, path)
   local plan = Config.prepare_copy_taps_to_chords(entries, actions, path)
   local successor = SOURCE .. '# concurrent edit\n'; seed(path, successor)
   local accepted, _, receipt = Config.publish_copy_taps_to_chords(plan, path)
   h.assert_eq(accepted, false); h.assert_eq(receipt, nil); h.assert_eq(read(path), successor)
   local route_accepted, route_refusal = pcall(Config.publish_copy_taps_to_chords, plan, path .. '.other')
   h.assert_eq(route_accepted, false); h.assert_contains(route_refusal, 'chord copy route changed')
   h.assert_eq(read(path), successor)
  end)
 end)
 h.it("rejects occupied source and unknown current slots before any disk publication", function()
  scoped(function(Config, _, path)
   for _, bytes in ipairs({ '[mod_combos', 'mod_combos = []', '[mod_combos.config."left_shift+right_shift"]\ntap = "unknown_action"' }) do
    seed(path, bytes)
    local prepared, refusal = pcall(Config.prepare_copy_taps_to_chords, entries, actions, path)
    h.assert_eq(prepared, false); h.assert_type(refusal, "string"); h.assert_true(#refusal > 0)
    h.assert_eq(read(path), bytes)
   end
  end)
 end)
 h.it("a native lock refusal cannot acknowledge a copied candidate", function()
  scoped(function(Config, _, path)
   local plan = Config.prepare_copy_taps_to_chords(entries, actions, path)
   h.assert_eq(Config.publish_copy_taps_to_chords(plan, path), false)
   h.assert_eq(read(path), SOURCE)
  end, function() return false, "controlled native lock refusal" end)
 end)
 h.it("retains cleanup debt and its exact effect before an inverse can write", function()
  scoped(function(Config, adapter, path)
   local plan = Config.prepare_copy_taps_to_chords(entries, actions, path)
   local real_write = adapter.write_if_unchanged_admitted
   local released, cleanup_calls = false, 0
   adapter.write_if_unchanged_admitted = function(target, candidate, source, on_error, admission)
    h.assert_eq(real_write(target, candidate, source, on_error, admission), true)
    return false, "controlled post-publication cleanup debt", function()
     cleanup_calls = cleanup_calls + 1
     if not released then return false, "controlled cleanup still owed" end
     return true, nil, true
    end
   end
   local accepted, _, receipt = Config.publish_copy_taps_to_chords(plan, path)
   adapter.write_if_unchanged_admitted = real_write
   h.assert_eq(accepted, false); h.assert_eq(type(receipt.publication_cleanup), "function")
   h.assert_eq(read(path), plan.candidate)
   h.assert_eq(require("config_file_inverse").restore(receipt, adapter), false)
   h.assert_eq(cleanup_calls, 1); h.assert_eq(read(path), plan.candidate)
   released = true; h.assert_eq(require("config_file_inverse").restore(receipt, adapter), true)
   h.assert_eq(cleanup_calls, 2); h.assert_eq(read(path), SOURCE)
  end)
 end)
 h.it("the Mac facade copies fresh disk slots rather than cached boot slots and waits for its deploy ACK", function()
  scoped(function(Config, _, path)
   with_remap(function(fixture)
    local remap, calls = fixture.load_enabled_remap()
    local port = package.loaded["platform.remap.config"]
    port.prepare_copy_taps_to_chords = function(actual_entries, _, actual_path)
     return Config.prepare_copy_taps_to_chords(actual_entries, actions, actual_path)
    end
    port.publish_copy_taps_to_chords = Config.publish_copy_taps_to_chords
    package.loaded["infra.config_paths"].get = function() return path end
    local completed, result, changed, pending = 0, nil, nil, nil
    remap.regenerate = function(done) pending = done; return true end
    h.assert_eq(remap.get_combo_tap_action(entries[1].id), "none")
    h.assert_eq(remap.copy_tap_actions_to_combos(function(ok, _, count)
     completed, result, changed = completed + 1, ok, count
    end), true)
    h.assert_eq(completed, 0); h.assert_eq(calls.save, 0)
    h.assert_eq(remap.get_combo_combo_action(entries[1].id), "escape")
    h.assert_eq(remap.get_combo_tap_action(entries[1].id), "escape")
    h.assert_eq(remap.get_combo_hold_action(entries[1].id), "layer")
    h.assert_eq(Codec.decode(read(path)).mod_combos.config[entries[1].id].combo, "escape")
    h.assert_eq(remap.set_combo_combo_action(entries[1].id, "caps_word"), false)
    pending(true, "controlled owned generation ready")
    h.assert_eq(completed, 1); h.assert_eq(result, true); h.assert_eq(changed, 1)
    pending(true, "duplicate terminal"); h.assert_eq(completed, 1)
   end)
  end)
 end)
 h.it("owns the Mac fresh read before reentrant setters and refuses a changed publish source", function()
  with_remap(function(fixture)
   local remap, calls = fixture.load_enabled_remap()
   calls.copy_source = SOURCE
   local setter_admitted
   calls.copy_read = function() setter_admitted = remap.set_combo_tap_action(entries[1].id, "caps_word") end
   calls.copy_publish = function() calls.copy_source = SOURCE .. '# concurrent successor\n' end
   local completed, result = 0, nil
   h.assert_eq(remap.copy_tap_actions_to_combos(function(ok) completed, result = completed + 1, ok end), false)
   h.assert_eq(setter_admitted, false); h.assert_eq(calls.save, 0)
   h.assert_eq(completed, 1); h.assert_eq(result, false)
   h.assert_eq(remap.get_combo_combo_action(entries[1].id), "none")
   h.assert_eq(calls.copy_source, SOURCE .. '# concurrent successor\n')
  end)
 end)
end)

h.describe("chord copy session refusal registry", function()
 h.it("refuses a session write registration after preparation before native publication", function()
  scoped(function(Config, adapter, path)
   local plan = Config.prepare_copy_taps_to_chords(entries, actions, path)
   local Writer = require("toml_codec.writer")
   Writer.refuse_writes(path, "unsupported schema/session")
   local calls, native = 0, adapter.write_if_unchanged
   adapter.write_if_unchanged = function(...)
    calls = calls + 1; return native(...)
   end
   local accepted = Config.publish_copy_taps_to_chords(plan, path)
   adapter.write_if_unchanged = native
   h.assert_eq(accepted, false)
   h.assert_eq(calls, 0); h.assert_eq(read(path), SOURCE)
  end)
 end)
 h.it("refuses a session write registration during the publication boundary", function()
  scoped(function(Config, adapter, path)
   local plan = Config.prepare_copy_taps_to_chords(entries, actions, path)
   local Writer = require("toml_codec.writer")
   local calls, native = 0, adapter.write_if_unchanged
   adapter.write_if_unchanged = function(...)
    calls = calls + 1
    Writer.refuse_writes(path, "late unsupported schema/session")
    return native(...)
   end
   local accepted = Config.publish_copy_taps_to_chords(plan, path)
   adapter.write_if_unchanged = native
   h.assert_eq(accepted, false)
   h.assert_eq(calls, 1); h.assert_eq(read(path), SOURCE)
  end)
 end)
end)

h.describe("chord copy final logical admission", function()
 h.it("fails closed when the native admitted capability is unavailable", function()
  scoped(function(Config, adapter, path)
   local plan = Config.prepare_copy_taps_to_chords(entries, actions, path)
   adapter.write_if_unchanged_admitted = nil
   local calls, native = 0, adapter.write_if_unchanged
   adapter.write_if_unchanged = function(...) calls = calls + 1; return native(...) end
   h.assert_eq(Config.publish_copy_taps_to_chords(plan, path), false)
   adapter.write_if_unchanged = native
   h.assert_eq(calls, 0); h.assert_eq(read(path), SOURCE)
  end)
 end)
 h.it("checks registry registration during the real final native source read", function()
  scoped(function(Config, adapter, path)
   local plan = Config.prepare_copy_taps_to_chords(entries, actions, path)
   local Writer = require("toml_codec.writer")
   local native, reads = adapter.read_with_status, 0
   adapter.read_with_status = function(...)
    local bytes, status, detail = native(...); reads = reads + 1
    -- Shared publication precheck, then the ordinary native final source read.
    if reads == 2 then Writer.refuse_writes(path, "final native read session refusal") end
    return bytes, status, detail
   end
   local accepted = Config.publish_copy_taps_to_chords(plan, path)
   adapter.read_with_status = native
   h.assert_eq(reads, 2); h.assert_eq(accepted, false); h.assert_eq(read(path), SOURCE)
  end)
 end)
 h.it("accepts only literal final lifecycle admission and refuses raised criteria", function()
  scoped(function(Config, _, path)
   local plan = Config.prepare_copy_taps_to_chords(entries, actions, path)
   for _, criterion in ipairs({ function() return false end, function() return 1 end,
    function() return nil end, function() error("controlled lifecycle refusal") end }) do
    h.assert_eq(Config.publish_copy_taps_to_chords(plan, path, criterion), false)
    h.assert_eq(read(path), SOURCE)
   end
  end)
 end)
 h.it("the actual facade rechecks its routed source after the final native read", function()
  scoped(function(Config, adapter, path)
   with_remap(function(fixture)
    local remap, calls = fixture.load_enabled_remap()
    local port = package.loaded["platform.remap.config"]
    port.prepare_copy_taps_to_chords = function(actual_entries, _, actual_path)
     return Config.prepare_copy_taps_to_chords(actual_entries, actions, actual_path)
    end
    port.publish_copy_taps_to_chords = Config.publish_copy_taps_to_chords
    local route = path
    package.loaded["infra.config_paths"].get = function() return route end
    local prepared_reads, read_native = 0, adapter.read_with_status
    local final_phase = false
    adapter.read_with_status = function(...)
     local bytes, status, detail = read_native(...)
     if final_phase then
      prepared_reads = prepared_reads + 1
      if prepared_reads == 2 then route = path .. '.successor-route' end
     end
     return bytes, status, detail
    end
    port.prepare_copy_taps_to_chords = function(actual_entries, _, actual_path)
     local plan = Config.prepare_copy_taps_to_chords(actual_entries, actions, actual_path)
     final_phase = true; return plan
    end
    local completed, result, regenerations = 0, nil, 0
    remap.regenerate = function() regenerations = regenerations + 1; return true end
    local accepted = remap.copy_tap_actions_to_combos(function(ok) completed, result = completed + 1, ok end)
    adapter.read_with_status = read_native
    h.assert_eq(accepted, false); h.assert_eq(completed, 1); h.assert_eq(result, false)
    h.assert_eq(prepared_reads, 2); h.assert_eq(regenerations, 0); h.assert_eq(calls.save, 0)
    h.assert_eq(remap.get_combo_combo_action(entries[1].id), "none")
    h.assert_eq(read(path), SOURCE); h.assert_eq(route, path .. '.successor-route')
   end)
  end)
 end)
end)


h.describe("chord copy final criterion registry reentry", function()
 h.it("rechecks session refusal registered by the final caller criterion", function()
  scoped(function(Config, _, path)
   local plan = Config.prepare_copy_taps_to_chords(entries, actions, path)
   local Writer = require("toml_codec.writer")
   local criteria = 0
   local accepted = Config.publish_copy_taps_to_chords(plan, path, function()
    criteria = criteria + 1
    if criteria == 2 then Writer.refuse_writes(path, "final caller criterion session refusal") end
    return true
   end)
   h.assert_eq(criteria, 2)
   h.assert_eq(accepted, false)
   h.assert_eq(Writer.write_refusal(path), "final caller criterion session refusal")
   h.assert_eq(read(path), SOURCE)
  end)
 end)
end)
