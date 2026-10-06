--- tests/unit/ui/test_update_check_async_admission.lua

--- Actual caller with controlled collaborator receipts; no GUI/native ACK claim.
local tests = {}
local function test(name, body) tests[#tests + 1] = { name, body } end
local function scenario(dispatch, body)
 local names = { "ui.update_check.bridge", "ui.download_window.bridge", "infra.installation" }
 local saved = {}; for _, name in ipairs(names) do saved[name] = { value = package.loaded[name] } end
 local h = { completed = {}, finished = {}, installs = 0, paused = false }
 local ok, err = xpcall(function()
  package.loaded["ui.update_check.bridge"] = nil
  package.loaded["infra.installation"] = { is_source_run = function() return false end }
  package.loaded["ui.download_window.bridge"] = {
   show = function(options) h.window = options; return 7 end,
   install_admission_current = function(id) return id == 7 and not h.paused end,
   complete = function(_, installed) h.completed[#h.completed + 1] = installed end,
  }
  local release = { tag = "v1.2.3", download_url = "https://release/archive", checksum_url = "https://release/checksum" }
  local manager = {
   get_cached_release = function() return release end, get_state = function() return "idle" end,
   get_channel = function() return "main" end,
   download_update = function(_, done) done("information-only-path"); return true end,
   install_update_async = function(_, done, current)
    h.installs = h.installs + 1; h.done = done
    assert(current() == true, "actual caller must furnish its exact native admission")
    return dispatch(h, done)
   end,
  }
  h.bridge = require("ui.update_check.bridge")
  local started = h.bridge.download_offered(manager, release, {
   is_paused = function() return h.paused end,
   on_update_finished = function(installed) h.finished[#h.finished + 1] = installed end,
  })
  assert(started == true and h.installs == 1)
  body(h)
 end, debug.traceback)
 for _, name in ipairs(names) do package.loaded[name] = saved[name].value end
 if not ok then error(err, 0) end
end
test("update native success before false admission remains one failure", function()
 scenario(function(_, done) done(true); return false end, function(h)
  assert(#h.completed == 1 and h.completed[1] == false)
  assert(#h.finished == 1 and h.finished[1] == false)
  h.done(true); assert(#h.completed == 1 and #h.finished == 1)
 end)
end)
test("update native success before throwing admission remains one failure", function()
 scenario(function(_, done) done(true); error("constructor refused") end, function(h)
  assert(#h.completed == 1 and h.completed[1] == false)
  assert(#h.finished == 1 and h.finished[1] == false)
 end)
end)
test("update synchronous success after literal true admission completes once", function()
 scenario(function(_, done) done(true); done(false); return true end, function(h)
  assert(#h.completed == 1 and h.completed[1] == true)
  assert(#h.finished == 1 and h.finished[1] == true)
 end)
end)
test("update delayed accepted native completion survives later pause", function()
 scenario(function() return true end, function(h)
  assert(#h.completed == 0 and #h.finished == 0)
  h.paused = true; h.done(true); h.done(false)
  assert(#h.completed == 1 and h.completed[1] == true)
  assert(#h.finished == 1 and h.finished[1] == true)
 end)
end)
assert(#tests == 4, "actual update async admission control floor")

-- Genuine normal registration retains every independent body and oracle.
local helpers = require("tests.helpers")
helpers.describe("Native Update Caller Admission", function()
	assert(#tests == 4, "Independent case floor changed")
	for _, case in ipairs(tests) do
		assert(type(case[1]) == "string" and type(case[2]) == "function", "Independent registration refused")
		helpers.it(case[1], case[2])
	end
end)
return tests
