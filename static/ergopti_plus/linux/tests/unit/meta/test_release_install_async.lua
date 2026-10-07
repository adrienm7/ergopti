--- tests/unit/meta/test_release_install_async.lua

--- Independent literal admission/completion ordering against the shared caller.
local ReleaseInstall = require("updater.release_install")
local tests = {}
local function test(name, body) tests[#tests + 1] = { name, body } end
local function fixture(options)
 options = options or {}
 local h = { reports = {}, restarts = 0, legacy = 0, dispatches = 0 }
 local logger = { start = function() end, success = function() end, error = function() end }
 local ports = {
  blocked = function() return nil end,
  find_release = function(tag) return { tag = tag } end,
  backup = function() return { path = "/owned/backup" } end,
  resolve_asset = function() return { url = "https://release/archive" } end,
  download = function(_, _, done) done("information-only-display"); return true end,
  install = function() h.legacy = h.legacy + 1; return options.legacy_result ~= false end,
  restart = function(release) h.restarts = h.restarts + 1; h.restarted_tag = release.tag; return true end,
  report = function(message)
   h.reports[#h.reports + 1] = message
   if h.report_probe then h.report_probe(message) end
  end,
  logger = logger,
 }
 if options.async ~= false then
  ports.install_async = function(_, _, _, done)
   h.dispatches = h.dispatches + 1; h.done = done
   if options.dispatch then return options.dispatch(h, done) end
   return true
  end
 end
 h.ports, h.session = ports, ReleaseInstall.new(ports)
 function h:count(phase)
  local count = 0
  for _, report in ipairs(self.reports) do if report.phase == phase then count = count + 1 end end
  return count
 end
 return h
end
test("legacy sibling literal success retains immediate completed behavior", function()
 local h = fixture({ async = false }); assert(h.session.install("1.2.3", "stable"))
 assert(h.legacy == 1 and h.dispatches == 0 and h.restarts == 1 and h:count("restarting") == 1)
end)
test("legacy sibling failure never starts a restart", function()
 local h = fixture({ async = false, legacy_result = false }); assert(h.session.install("1.2.3", "stable"))
 assert(h.restarts == 0 and h:count("failed") == 1 and not h.session.busy())
end)
test("async admission holds running state without completed publication", function()
 local h = fixture(); assert(h.session.install("1.2.3", "stable"))
 assert(h.dispatches == 1 and h.legacy == 0 and h.session.busy())
 assert(h.restarts == 0 and h:count("restarting") == 0 and h:count("installing") == 1)
 h.done(true); assert(h.restarts == 1 and h:count("restarting") == 1)
end)
test("actual async failure keeps backup and never restarts", function()
 local h = fixture(); h.session.install("1.2.3", "stable")
 h.done(false, ReleaseInstall.REASON.install, "physical tar failure")
 assert(h.restarts == 0 and h:count("failed") == 1 and not h.session.busy())
 assert(h.reports[#h.reports].backup_path == "/owned/backup")
end)
test("async false admission is one failure without waiting for callback", function()
 local h = fixture({ dispatch = function() return false end }); h.session.install("1.2.3", "stable")
 assert(h.restarts == 0 and h:count("failed") == 1)
 h.done(true); assert(h.restarts == 0 and h:count("failed") == 1)
end)
test("async truthy admission cannot manufacture completed installation", function()
 local h = fixture({ dispatch = function() return "true" end }); h.session.install("1.2.3", "stable")
 assert(h.restarts == 0 and h:count("failed") == 1)
end)
test("async callback truthy string refuses actual success", function()
 local h = fixture(); h.session.install("1.2.3", "stable"); h.done("true")
 assert(h.restarts == 0 and h:count("failed") == 1)
end)
test("synchronous success before refused admission cannot authorize restart", function()
 local h = fixture({ dispatch = function(_, done) done(true); return false end })
 h.session.install("1.2.3", "stable")
 assert(h.restarts == 0 and h:count("restarting") == 0 and h:count("failed") == 1)
end)
test("synchronous success before throwing admission cannot authorize restart", function()
 local h = fixture({ dispatch = function(_, done) done(true); error("post-completion dispatch error") end })
 h.session.install("1.2.3", "stable")
 assert(h.restarts == 0 and h:count("restarting") == 0 and h:count("failed") == 1)
end)
test("duplicate completion cannot restart twice", function()
 local h = fixture(); h.session.install("1.2.3", "stable")
 h.done(true); h.done(true); h.done(false)
 assert(h.restarts == 1 and h:count("restarting") == 1 and h:count("failed") == 0)
end)
test("old failure callback cannot complete a successor release", function()
 local h = fixture(); h.session.install("1.2.3", "stable")
 local previous = h.done; previous(false, ReleaseInstall.REASON.install)
 assert(h.session.install("2.0.0", "stable")); previous(true)
 assert(h.restarts == 0 and h.session.busy())
 h.done(true); assert(h.restarts == 1 and h.restarted_tag == "2.0.0")
end)
test("captured async port cannot borrow a later mutable replacement", function()
 local h = fixture()
 h.ports.install_async = function() error("foreign later port") end
 h.session.install("1.2.3", "stable")
 assert(h.dispatches == 1 and h:count("failed") == 0)
 h.done(true); assert(h.restarts == 1)
end)
test("invalid optional async capability refuses constructor", function()
 local h = fixture({ async = false }); h.ports.install_async = "true"
 local called, refusal = pcall(ReleaseInstall.new, h.ports)
 assert(called == false)
 assert(type(refusal) == "string" and refusal:find("release_install async install port is invalid", 1, true) ~= nil)
 assert(h.dispatches == 0 and h.legacy == 0 and h.restarts == 0 and #h.reports == 0)
end)
test("presentation retirement preserves already accepted installation completion", function()
 local h = fixture(); h.session.install("1.2.3", "stable")
 h.session.retire(); h.done(true)
 assert(h.restarts == 1 and h:count("restarting") == 0 and h:count("failed") == 0)
 assert(h.restarted_tag == "1.2.3") -- Original native intent; no successor document selected.
end)
test("synchronous success with literal admitted return restarts exactly once", function()
 local h = fixture({ dispatch = function(_, done) done(true); return true end })
 h.session.install("1.2.3", "stable")
 assert(h.restarts == 1 and h:count("restarting") == 1 and h:count("failed") == 0)
end)
assert(#tests == 15, "async install independent control floor")

-- Genuine normal registration retains every independent body and oracle.
local helpers = require("tests.helpers")
helpers.describe("Shared Async Release Installation", function()
	assert(#tests == 15, "Independent case floor changed")
	for _, case in ipairs(tests) do
		assert(type(case[1]) == "string" and type(case[2]) == "function", "Independent registration refused")
		helpers.it(case[1], case[2])
	end
end)
return tests
