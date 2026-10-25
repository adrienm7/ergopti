--- tests/unit/infra/logger/test_logger_native_files.lua

--- ==============================================================================
--- MODULE: Native Logger File Admission
--- DESCRIPTION:
--- Actual special endpoints must never block startup, topical fan-out, sink
--- repointing or the final pre-sink fatal record. Regular files retain append
--- and daily topical rotation semantics through the same native owners.
--- ==============================================================================

local helpers = require("tests.helpers")
local native = require("luv")
local Shell = require("adapters.shell_runner")
local AppDirs = require("app_dirs")

--- Runs an isolated real logger operation under a native process deadline.
--- @param endpoint string Endpoint to replace with a FIFO, or "regular".
local function run_endpoint(endpoint)
	local root = os.tmpname()
	os.remove(root)
	assert(Shell.run("mkdir -p -- " .. Shell.quote(root .. "/logs") .. " " .. Shell.quote(root .. "/candidate")
		.. " " .. Shell.quote(root .. "/shared/modules/diagnostics")))
	local date = os.date("%Y-%m-%d")
	local main = root .. "/logs/" .. AppDirs.files.unified_prefix .. date .. AppDirs.files.extension
	local errors = root .. "/logs/" .. AppDirs.files.errors_prefix .. date .. AppDirs.files.extension
	local topical = root .. "/logs/ErgoptiPlus_keystats.log"
	local targets = {
		bootstrap = root .. "/logs/" .. AppDirs.files.bootstrap_log,
		main = main,
		errors = errors,
		topical = topical,
		repoint = root .. "/candidate/" .. AppDirs.files.unified_prefix .. date .. AppDirs.files.extension,
		privacy = root .. "/shared/modules/diagnostics/redaction.json",
	}
	if endpoint ~= "regular" and endpoint ~= "close" then
		assert(Shell.run("mkfifo -- " .. Shell.quote(assert(targets[endpoint]))))
	else
		for _, path in ipairs({ main, errors, topical }) do
			local file = assert(io.open(path, "w"))
			assert(file:write("2001-01-01 [INFO] [old] retained-before-append\n"))
			assert(file:close())
		end
	end
	local code = string.format([[package.path = %q
local root, endpoint = %q, %q
local Sink = require("infra.logger_sink")
local emit, installed = nil, 0
local logger = {
 set_sink = function(callback) emit = callback; installed = installed + (callback and 1 or 0) end,
 enable_repeat_collapsing = function() end, disable_repeat_collapsing = function() end,
}
if endpoint == "bootstrap" then
 assert(require("infra.bootstrap_log").append("session_lock_refused", { dir = root .. "/logs" }) == false)
 return
end
if endpoint == "privacy" then
 require("infra.paths").shared_root_from = function() return root .. "/shared" end
 local ok = pcall(Sink.install, logger, { log_dir = root .. "/logs", redaction_context = { home = "/native-private", user = "native-private" } })
 assert(ok == false, "unreadable privacy rules must refuse startup")
 assert(installed == 0, "no sink may publish before privacy admission")
 return
end
local close_refusals = 0
if endpoint == "close" then
 local uv = require("luv")
 local open, close, admitted = uv.fs_open, uv.fs_close, nil
 local main = root .. "/logs/" .. require("app_dirs").files.unified_prefix .. os.date("%%Y-%%m-%%d") .. require("app_dirs").files.extension
 uv.fs_open = function(path, ...)
  local fd, detail, code = open(path, ...)
  if path == main then admitted = fd end
  return fd, detail, code
 end
 uv.fs_close = function(fd)
  local receipt, detail, code = close(fd)
  if fd == admitted then
   admitted, close_refusals = nil, close_refusals + 1
   return nil, "controlled native close refusal", "EIO"
  end
  return receipt, detail, code
 end
end
local active = Sink.install(logger, { log_dir = root .. "/logs", redaction_context = { home = "/native-private", user = "native-private" } })
assert(active == (endpoint ~= "main" and endpoint ~= "close"), "main refusal must degrade without blocking other channels")
if endpoint == "close" then assert(close_refusals == 1, "the actual admission descriptor close must be observed") end
if endpoint == "repoint" then
 require("infra.config_paths").get_logs_dir = function() return root .. "/candidate" end
 assert(Sink.repoint() == false, "refused candidate must retain the original sink")
end
assert(type(emit) == "function")
emit(os.date("%%Y-%%m-%%d") .. " [ERROR] [keystats] native-special-file-marker", "error")
Sink.uninstall(logger)
]], package.path, root, endpoint)
	local expired, exited, exit_code, exit_signal = false, false, nil, nil
	local timer = assert(native.new_timer())
	local child
	child = assert(native.spawn(assert(arg[-1]), { args = { "-e", code } }, function(status, signal)
		exited, exit_code, exit_signal = true, status, signal
		native.timer_stop(timer)
		native.close(timer)
		native.close(child)
	end))
	assert(require("infra.native_timer").start(native, timer, 2000, 0, function()
		expired = true
		child:kill("sigkill")
	end))
	while not exited do native.run("once") end
	native.run("nowait")
	local observed = {}
	for key, path in pairs({ main = main, errors = errors, topical = topical }) do
		local attrs = native.fs_lstat(path)
		if attrs and attrs.type == "file" then
			local file = assert(io.open(path, "r"))
			observed[key] = assert(file:read("*a"))
			assert(file:close())
		end
	end
	assert(Shell.run("rm -r -- " .. Shell.quote(root)))
	helpers.assert_eq(expired, false, endpoint .. " must not wait for a FIFO peer")
	helpers.assert_eq(exit_code, 0, endpoint .. " must preserve the logger's refusal and publication contract")
	helpers.assert_eq(exit_signal, 0, "a killed or crashed logger never counts as safe degradation")
	if endpoint == "errors" or endpoint == "topical" or endpoint == "repoint" or endpoint == "regular" then
		helpers.assert_contains(observed.main or "", "native-special-file-marker", "healthy main output must survive another channel's refusal")
	end
	if endpoint == "close" then
		helpers.assert_eq(observed.main, "2001-01-01 [INFO] [old] retained-before-append\n",
			"an unacknowledged admission close must release the buffered owner before any write")
	end
	if endpoint == "regular" then
		helpers.assert_contains(observed.main or "", "retained-before-append", "main logs append existing data")
		helpers.assert_contains(observed.errors or "", "retained-before-append", "error logs append existing data")
		helpers.assert_contains(observed.errors or "", "native-special-file-marker")
		helpers.assert_contains(observed.topical or "", "native-special-file-marker")
		helpers.assert_eq((observed.topical or ""):find("retained-before-append", 1, true), nil,
			"a topical file from an earlier day is replaced only after regular-file admission")
	end
end

helpers.describe("logger-native-file-admission", function()
	for _, endpoint in ipairs({ "bootstrap", "main", "errors", "topical", "repoint", "privacy", "close", "regular" }) do
		helpers.it("(logger-native-file-admission) handles " .. endpoint .. " without blocking or losing healthy output", function()
			run_endpoint(endpoint)
		end)
	end
end)
