--- tests/support/keystats/metrics_ignore_fixture.lua

--- Physical public-init fixture; SQLite unavailability explicitly selects JSONL-only mode.
local Helpers = require("tests.helpers")
local Lfs = require("lfs")
local Json = require("json")
local Quote = require("text_utils").shell_quote
local M = {}
local OWNERS = {
	"tests.stubs.hs", "infra.logger", "infra.fs_dir", "adapters.file_system", "adapters.ledger_append",
	"adapters.timer_scheduler", "modules.keystats.log_manager", "modules.keystats.rotation",
	"modules.keystats.sqlite_writer", "modules.keystats.aggregator", "modules.keystats.export",
	"hs.fs", "hs.timer", "hs.json", "hs.sqlite3",
}
local function write(path, body)
	local file = assert(io.open(path, "wb")); assert(file:write(body)); assert(file:close())
end
local function remove_tree(path)
	local attrs = Lfs.symlinkattributes(path)
	if not attrs then return end
	if attrs.mode == "directory" then
		for name in Lfs.dir(path) do
			if name ~= "." and name ~= ".." then remove_tree(path .. "/" .. name) end
		end
		assert(Lfs.rmdir(path))
	else assert(os.remove(path)) end
end
function M.run(callback)
	local root = os.tmpname(); assert(os.remove(root)); assert(Lfs.mkdir(root))
	local context = { root = root, metrics = root .. "/metrics", errors = {}, write = write }
	context.ignore = context.metrics .. "/.gitignore"
	local function git(...)
		local env = "env"
		-- Exclude ambient repository/config routing as well as global ignore rules.
		for _, key in ipairs({ "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR",
			"GIT_OBJECT_DIRECTORY", "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_CONFIG_PARAMETERS",
			"GIT_CONFIG_COUNT", "GIT_TEMPLATE_DIR" }) do env = env .. " -u " .. key end
		local command = env .. " GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null HOME=" .. Quote(root)
			.. " XDG_CONFIG_HOME=" .. Quote(root .. "/xdg") .. " git -C " .. Quote(root)
			.. " -c core.excludesFile=/dev/null"
		for _, arg in ipairs({...}) do command = command .. " " .. Quote(arg) end
		local pipe = assert(io.popen(command .. " 2>&1", "r")); local output = assert(pipe:read("*a"))
		local ok, _, code = pipe:close(); return ok and 0 or code, output
	end
	context.git = git
	local ok, err = xpcall(function()
		assert(Lfs.mkdir(root .. "/tmp"))
		assert(Lfs.mkdir(root .. "/empty-template"))
		local status, detail = git("init", "--template=" .. root .. "/empty-template")
		assert(status == 0, detail)
		assert(Lfs.mkdir(context.metrics)); assert(Lfs.mkdir(context.metrics .. "/by_device"))
		local device = context.metrics .. "/by_device/device"; assert(Lfs.mkdir(device))
		context.today = device .. "/today.log"
		write(device .. "/device.json", Json.encode({ device_id = "device", name = "Owned fixture", os = "darwin",
			host_signature = "owned-test-host", created_at = "2026-10-26 00:00:00.000" }))
		Helpers.with_stub_scope(OWNERS, function()
			_G.hs = require("tests.stubs.hs")
			hs.timer = require("tests.support.runloop_timers").create().api
			hs.fs.attributes = Lfs.attributes; hs.fs.symlinkAttributes = Lfs.symlinkattributes
			hs.fs.dir = Lfs.dir; hs.fs.mkdir = Lfs.mkdir
			hs.execute = function(command)
				if command:find("ioreg", 1, true) then return "owned-test-host", true, "exit", 0 end
				assert(command:sub(1, 9) == "mkdir -p ", "unexpected native command")
				local succeeded, kind, code = os.execute(command); return "", succeeded, kind, code
			end
			for _, name in ipairs({ "timer", "fs", "json", "sqlite3" }) do package.loaded["hs." .. name] = hs[name] end
			local logger = Helpers.make_logger_stub()
			logger.error = function(_, format, ...) context.errors[#context.errors + 1] = string.format(format, ...) end
			package.loaded["infra.logger"] = logger
			context.files = require("adapters.file_system")
			package.loaded["modules.keystats.sqlite_writer"] = { init = function(options)
				context.cache_path = options.paths.sqlite_path
				assert(context.cache_path:sub(1, #root + 5) == root .. "/tmp/", "cache escaped owned TMPDIR")
			end, open_db = function() return false end,
				get_db = function() return nil end, close_db = function() return true end }
			package.loaded["modules.keystats.aggregator"] = { init = function() end }
			package.loaded["modules.keystats.export"] = { init = function() end, cleanup = function() return true end }
			package.loaded["adapters.ledger_append"] = { recover = function() return true end, cleanup = function() return true end }
			local manager = require("modules.keystats.log_manager")
			context.init = function(metrics) return manager.init({ LOG_DIR = metrics or context.metrics }) end
			local actual_open, actual_getenv, opened = io.open, os.getenv, {}
			-- Bind only this process-local native port; preserve every other env
			-- lookup and restore it before leaving either success or failure.
			os.getenv = function(key)
				if key == "TMPDIR" then return root .. "/tmp" end
				return actual_getenv(key)
			end
			io.open = function(path, mode)
				local file, detail, code = actual_open(path, mode)
				if path:sub(1, #root + 1) == root .. "/" and mode == "a+" and file then opened[#opened + 1] = file end
				return file, detail, code
			end
			local ran, failure = xpcall(function() callback(context) end, debug.traceback)
			local stopped, stop_error = pcall(manager.stop, { process_exit = true })
			io.open = actual_open
			os.getenv = actual_getenv
			for _, file in ipairs(opened) do if io.type(file) == "file" then assert(file:close()) end end
			assert(stopped, stop_error)
			assert(ran, failure)
		end)
	end, debug.traceback)
	remove_tree(root)
	assert(Lfs.symlinkattributes(root) == nil, "owned fixture directory survived cleanup")
	assert(ok, err)
end
return M
