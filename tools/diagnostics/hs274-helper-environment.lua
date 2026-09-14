-- tools/diagnostics/hs274-helper-environment.lua
-- Exercise the production environment boundary through native Hammerspoon tasks.

local root = assert(debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$"))
local config = assert(hs.json.read(root .. "/helper-environment-config.json"))
local driver = config.repo .. "/static/ergopti_plus/macos"
package.path = driver .. "/?.lua;" .. driver .. "/?/init.lua;" .. package.path
local result = { kind = "native-helper-task-environment", bootstrap_verified = false }
local owner = {}
_G.hs274_helper_environment = owner

local function publish()
	assert(hs.json.write(result, config.result, true, true), "Cannot publish native environment result")
end

local function guarded(callback)
	return function(...)
		local ok, detail = xpcall(callback, debug.traceback, ...)
		if not ok then result.error = tostring(detail); publish() end
	end
end

local function run()
	assert(os.getenv("ERGOPTI_LAUNCHER_DEVICE") == nil, "Parent unexpectedly owns a launcher identity")
	assert(os.getenv("ERGOPTI_LAUNCHER_INODE") == nil, "Parent unexpectedly owns a launcher identity")
	result.parent_identity_absent = true
	-- The fixture isolates logging only; task construction and environment APIs are real.
	local logger = {}
	for _, name in ipairs({ "debug", "info", "warn", "error", "start", "success" }) do logger[name] = print end
	package.loaded["infra.logger"] = logger
	local runner = require("adapters.shell_runner")
	local function rejected_identity()
		local environment = {}
		for key, value in pairs(config.environment) do environment[key] = value end
		environment.ERGOPTI_LAUNCHER_INODE = config.wrong_inode
		owner.rejected = runner.spawn(config.helper, { "--remap-guardian-status" }, guarded(function(code, stdout)
			assert(code == 64 and stdout == "", "Wrong helper identity was admitted")
			result.wrong_identity_exit = code
			local refused = runner.spawn("/usr/bin/true", {}, nil, nil, { ERGOPTI_LOG_TOKEN = "fixture-only" })
			assert(refused.start() == false, "Launcher logger authority reached a child")
			result.forbidden_started = false
			publish()
		end), nil, environment)
		assert(owner.rejected.start(), "Identity rejection probe did not start")
	end
	owner.accepted = runner.spawn(config.helper, { "--remap-guardian-status" }, guarded(function(code, stdout, stderr)
		assert(code == 0, "Explicit native identity failed: " .. tostring(stderr))
		local status = stdout:match("^%s*(.-)%s*$")
		assert(status == "ready" or status == "requires_approval" or status == "unavailable", "Invalid native status")
		result.good_exit, result.guardian_status = code, status
		rejected_identity()
	end), nil, config.environment)
	assert(owner.accepted.start(), "Explicit native helper did not start")
end

guarded(run)()
