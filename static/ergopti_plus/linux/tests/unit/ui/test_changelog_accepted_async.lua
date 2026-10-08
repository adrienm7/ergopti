--- tests/unit/ui/test_changelog_accepted_async.lua

--- Actual bridge + shared transaction + genuine controlled document handshake.
--- Native manager ports are literal controlled receipts, not real install proof.
local Json = require("json")
local tests = {}
local function test(name, body) tests[#tests + 1] = { name, body } end
local function scenario(body)
 local names = { "modules.updater.manager", "ui.changelog.bridge", "infra.installation", "manifest_reader",
  "lgi", "infra.monotonic", "infra.timings", "infra.managed_http_deadline", "adapters.event_loop",
  "adapters.notifier", "ui.webkit_host", "ui.webview_manager" }
 local saved = {}; for _, name in ipairs(names) do saved[name] = { value = package.loaded[name] } end
 local h = { backups = 0, installs = 0, restarts = 0 }
 local doc
 local ok, err = xpcall(function()
  local real_manager = require("modules.updater.manager")
  local manager = {
   CHANNELS = real_manager.CHANNELS, release_record = real_manager.release_record,
   get_channel = function() return "main" end, installation_kind = function() return "standalone" end,
   download_release = function(record, done, current)
    assert(type(current) == "function" and current() == true)
    h.record, h.download_done, h.download_current = record, done, current; return true
   end,
   install_release_archive_async = function(_, tag, done, current)
    if current() ~= true then return false end
    h.installs, h.installed_tag, h.install_done = h.installs + 1, tag, done
    return true
   end,
  }
  package.loaded["modules.updater.manager"] = manager
  package.loaded["infra.installation"] = { is_source_run = function() return false end }
  package.loaded["ui.changelog.bridge"] = nil
  h.bridge = require("ui.changelog.bridge")
  local asset = "ergopti-plus-linux.tar.gz"
  local release = { tag_name = "v1.2.3", html_url = "https://github.com/adrienm7/ergopti/releases/tag/v1.2.3",
   body = "notes", published_at = "2026-10-01T00:00:00Z", assets = {
    { name = asset, browser_download_url = "https://github.com/adrienm7/ergopti/releases/download/v1.2.3/" .. asset },
    { name = asset .. ".sha256", browser_download_url = "https://github.com/adrienm7/ergopti/releases/download/v1.2.3/" .. asset .. ".sha256" },
   } }
  h.bridge._http_get = function(_, _, _, done) done(200, Json.encode({ release }), nil) end
  h.bridge._config_backup = { owner = function() return {
   create = function() h.backups = h.backups + 1; return { path = "/owned/backup" } end,
   latest = function() return nil end,
  } end }
  doc = require("tests.support.document_fixture").new("changelog", h.bridge, {
   restart_after_update = function() h.restarts = h.restarts + 1; return true end,
  })
  h.document = doc
  doc.handshake()
  function h:accept()
   doc.send({ action = "install_release", tag = "v1.2.3", channel = "main" })
   assert(self.backups == 1 and type(self.download_done) == "function")
  end
  body(h)
 end, debug.traceback)
 local clean, cleanup_error = true, nil
 if doc then clean, cleanup_error = pcall(doc.close) end
 for _, name in ipairs(names) do package.loaded[name] = saved[name].value end
 if not ok then error(err, 0) end
 if not clean then error(cleanup_error, 0) end
end
test("accepted Versions download continues install after pause and document STARTED", function()
 scenario(function(h)
  h:accept(); h.document.paused = true; h.document.start_load()
  assert(h.download_current() == true, "original accepted script lineage, not retired page consent")
  h.download_done("information-only-display")
  assert(h.installs == 1 and h.installed_tag == "v1.2.3" and h.restarts == 0)
  h.install_done(true)
  assert(h.restarts == 1, "original accepted script restarts despite presentation retirement")
 end)
end)
test("accepted Versions download cannot publish or restart a successor script", function()
 scenario(function(h)
  h:accept()
  h.document.manager.set_daemon_state({ is_paused = function() return false end, restart_after_update = function()
   error("foreign successor restart") end })
  h.document.handshake()
  h.download_done("information-only-display")
  assert(h.installs == 0 and h.restarts == 0)
 end)
end)
test("accepted Versions completion cannot restart a replaced original hook", function()
 scenario(function(h)
  h:accept(); h.download_done("information-only-display")
  assert(h.installs == 1)
  h.document.state.restart_after_update = function() error("replacement restart") end
  h.install_done(true); assert(h.restarts == 0)
 end)
end)
test("unaccepted paused Versions page cannot begin backup or download", function()
 scenario(function(h)
  h.document.paused = true
  h.document.send({ action = "install_release", tag = "v1.2.3", channel = "main" })
  assert(h.backups == 0 and h.download_done == nil and h.installs == 0)
 end)
end)
test("accepted download cannot mutate the selected install tag", function()
 scenario(function(h)
  h:accept(); h.record.tag = "v9.9.9"; h.download_done("information-only-display")
  assert(h.installs == 0 and h.restarts == 0)
 end)
end)
test("accepted download cannot mutate the authenticated archive route", function()
 scenario(function(h)
  h:accept(); h.record.download_url = "https://foreign.invalid/archive"; h.download_done("information-only-display")
  assert(h.installs == 0 and h.restarts == 0)
 end)
end)
test("accepted download native route admission refuses selected mutation", function()
 scenario(function(h)
  h:accept(); h.record.checksum_url = "https://foreign.invalid/checksum"
  assert(h.download_current() == false)
  h.download_done(nil, "source revoked", "download")
  assert(h.installs == 0 and h.restarts == 0)
 end)
end)
test("accepted download native route cannot borrow replaced script owner", function()
 scenario(function(h)
  h:accept(); h.document.state.restart_after_update = function() error("foreign restart") end
  assert(h.download_current() == false)
  h.download_done(nil, "source revoked", "download")
  assert(h.installs == 0 and h.restarts == 0)
 end)
end)
assert(#tests == 8, "actual accepted Versions async control floor")

-- Genuine normal registration retains every independent body and oracle.
local helpers = require("tests.helpers")
helpers.describe("Accepted Versions Native Installation", function()
	assert(#tests == 8, "Independent case floor changed")
	for _, case in ipairs(tests) do
		assert(type(case[1]) == "string" and type(case[2]) == "function", "Independent registration refused")
		helpers.it(case[1], case[2])
	end
end)
return tests
