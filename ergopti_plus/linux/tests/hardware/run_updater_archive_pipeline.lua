--- static/ergopti_plus/linux/tests/hardware/run_updater_archive_pipeline.lua

--- Real installed Manager/Transfer/HTTP/C/EVP/tar/DEFAULT_OPS first-chain probe.
--- No production I/O, registry, digest, timer or installer port is substituted.
local prefix, base, mode, tag, config = assert(arg[1]), assert(arg[2]), assert(arg[3]), assert(arg[4]), assert(arg[5])
assert(prefix:sub(1, 1) == "/" and (mode == "happy" or mode == "wrong_digest" or mode == "smoke_rollback"))
assert(base:match("^https://127%.0%.0%.1:%d+$") and tag:match("^v%d+%.%d+%.%d+"))
local root = prefix .. "/lib/ergopti"
local driver = root .. "/linux"
package.path = driver .. "/?.lua;" .. driver .. "/?/init.lua;"
 .. root .. "/_shared/lua/?.lua;" .. root .. "/_shared/lua/?/init.lua;" .. package.path
assert(type(jit) == "table" and jit.os == "Linux", "Actual Linux LuaJIT required")
local compat = require("compat.utf8"); compat.install()
local uv = require("luv")
local Manager = require("modules.updater.manager")
local Installer = require("modules.updater.installer")
local checked, passed = 0, 0
local function check(value, name)
 checked = checked + 1
 assert(value == true, name)
 passed = passed + 1
 print("PIPELINE_PASS " .. mode .. " " .. name)
end
local function await(predicate)
 local deadline = uv.hrtime() + 30000000000
 repeat
  uv.run("nowait")
  if predicate() then return true end
  uv.sleep(1)
 until uv.hrtime() >= deadline
 return false
end
local function namespace_descriptors()
 local owned = assert(os.getenv("TMPDIR"))
 local scan = assert(uv.fs_scandir("/proc/self/fd"))
 local count = 0
 while true do
  local name = uv.fs_scandir_next(scan)
  if name == nil then break end
  local alias = uv.fs_readlink("/proc/self/fd/" .. name)
  -- Observational only: never closes a discovered integer or invents ownership
  -- from a before/after set difference. The exact private namespace is given.
  if type(alias) == "string" and (alias == owned or alias:find(owned .. "/", 1, true) == 1) then count = count + 1 end
 end
 return count
end
local paused, installing, original_intent = false, false, {}
local download, installed, downloads, installations
local function admission()
 return not paused and not installing and original_intent ~= nil
end
local function install_diagnostic(result, callbacks)
 -- Fixed diagnostic codes only: never emit the callback detail/receipt contents.
 local reasons = {
  ["installation is not standalone"] = "not_standalone",
  ["standalone installation paths are unsafe"] = "unsafe_installation_paths",
  ["archive path is absent"] = "archive_path_absent",
  ["selected release version is absent"] = "selected_version_absent",
  ["local install admission expired"] = "admission_expired",
  ["local install admission expired or refused"] = "admission_refused",
  ["local install deadline expired"] = "deadline_expired",
  ["archive listing failed"] = "archive_listing_failed",
  ["archive links and special files are not accepted"] = "archive_special_files",
  ["could not allocate same-filesystem staging"] = "staging_allocation_failed",
  ["archive extraction failed"] = "archive_extraction_failed",
  ["staged archive is missing the shared Lua tree"] = "shared_lua_tree_missing",
  ["staged driver version does not match the selected release"] = "staged_version_mismatch",
  ["could not assemble the complete candidate root"] = "candidate_assembly_failed",
  ["could not record the new installation's file ownership"] = "candidate_ownership_failed",
  ["backup path escaped the installation parent"] = "unsafe_backup_path",
  ["previous backup could not be retired"] = "backup_retirement_failed",
  ["current installation could not be moved to backup"] = "backup_move_failed",
  ["candidate activation failed; previous installation restored"] = "activation_failed_restored",
  ["updated wrapper smoke failed; previous installation restored"] = "smoke_failed_restored",
  ["update installed but temporary cleanup was incomplete"] = "installed_cleanup_incomplete",
 }
 local detail_type = type(result.detail)
 local detail_code = result.detail == nil and "none"
  or (detail_type == "string" and (reasons[result.detail] or "unrecognized") or "nonstring")
 local ok = result.ok == true and "true" or (result.ok == false and "false" or "nonboolean")
 local callback_count = callbacks == 0 and "zero" or (callbacks == 1 and "one" or "multiple")
 -- stderr is the original retained private native sink; nothing is added to public output.
 io.stderr:write("PIPELINE_INSTALL_DIAGNOSTIC ok=", ok,
  " detail_type=", detail_type, " detail_code=", detail_code,
  " receipt_present=", result.receipt ~= nil and "true" or "false",
  " callback_count=", callback_count, "\n")
end
local primary, error_message = xpcall(function()
 local manager_source = assert(debug.getinfo(Manager.download_release, "S").source):gsub("^@", "")
 local actual = Installer.resolve(manager_source)
 check(actual.kind == "standalone" and actual.install_root == root and actual.wrapper == prefix .. "/bin/ergopti-hotstrings",
  "actual source resolves genuine standalone installation")
 Manager.init({ config_path = config, is_paused = function() return paused end })
 Manager.stop_background_checks() -- Actual public lifecycle, not a substituted timer.
 downloads, installations = 0, 0
 local release = { tag = tag, checksum_url = base .. "/" .. mode .. "/checksum",
  download_url = base .. "/" .. mode .. "/archive" }
 check(Manager.download_release(release, function(path, failure, stage, receipt)
  downloads = downloads + 1
  if download ~= nil then error("duplicate actual terminal") end
  download = { path = path, failure = failure, stage = stage, receipt = receipt }
 end) == true, "selected checksum dispatch has actual owned admission")
 assert(await(function() return download ~= nil end), "actual archive terminal did not settle")
 check(downloads == 1 and Manager.get_state() ~= "downloading", "one actual archive receipt waits retained physical owners")
 if mode == "happy" or mode == "smoke_rollback" then
  assert(type(download.path) == "string" and download.failure == nil and download.receipt == nil,
   "actual verified artifact absent")
  -- The display string is passed to the existing Manager receiving API; the
  -- registry supplies tar readers from its private FD/brand, never this path.
  check(Manager.install_release_archive_async(download.path, tag, function(ok, detail, receipt)
   installations = installations + 1
   installed = { ok = ok, detail = detail, receipt = receipt }
  end, admission) == true, "actual verified brand enters native tar installation")
  installing = true -- Accepted private installation continues its original intent.
  assert(await(function() return installed ~= nil end), "actual tar/installation terminal did not settle")
  if mode == "smoke_rollback" then
   if not (installed.ok == false and installed.detail == "updated wrapper smoke failed; previous installation restored"
    and installed.receipt == nil and installations == 1) then
    pcall(install_diagnostic, installed, installations) -- Preserve primary refusal on diagnostic sink debt.
   end
   assert(installed.ok == false and installed.detail == "updated wrapper smoke failed; previous installation restored"
    and installed.receipt == nil and installations == 1, "actual smoke failure did not restore previous installation")
  else
  if not (installed.ok == true and installed.detail == nil and installed.receipt == nil and installations == 1) then
   pcall(install_diagnostic, installed, installations) -- Optional sink refusal must not replace the original assertion.
  end
  assert(installed.ok == true and installed.detail == nil and installed.receipt == nil and installations == 1,
   "actual DEFAULT_OPS install/smoke/cleanup failed")
  end
 else
  check(download.path == nil and download.stage == "verify" and type(download.failure) == "string"
   and download.failure ~= ""
   and Manager.install_release_archive_async("unverified-display", tag, function() installations = installations + 1 end, admission) == false
   and installations == 0, "wrong digest exposes zero verified installation authority")
 end
 Manager.stop_background_checks()
 if mode ~= "happy" then assert(Manager.cancel_update() == true, "actual cancelled namespace retirement refused") end
 assert(await(function() return uv.loop_alive() == false end), "actual native loop debt remained")
 check(uv.loop_alive() == false and namespace_descriptors() == 0,
  "actual loop and exact namespace descriptor owners physically drain")
 assert(checked == 5 and passed == 5, "Independent first-chain case floor changed")
 print("PIPELINE_RESULT " .. mode .. " passed=5 failed=0 skipped=0")
end, debug.traceback)
if not primary then
 -- Request the existing producer's cleanup, without replacing its original
 -- primary failure or treating logical cancellation as physical settlement.
 pcall(Manager.stop_background_checks)
 pcall(Manager.cancel_update)
 local drained = await(function() return uv.loop_alive() == false end)
 io.stderr:write("PIPELINE_FAILURE ", mode, "\n", tostring(error_message), "\n")
 if not drained or namespace_descriptors() ~= 0 then io.stderr:write("PIPELINE_DEBT unresolved native owners\n") end
 os.exit(1)
end
