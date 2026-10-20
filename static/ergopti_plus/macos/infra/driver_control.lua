--- infra/driver_control.lua

--- ==============================================================================
--- MODULE: Local Driver Control (macOS)
--- DESCRIPTION:
--- A tool run by the same user asks this Hammerspoon driver to reload. The
--- policy is the shared _shared/lua/control/driver_control.lua; this module owns
--- the session in ~/Library/Application Support, the request it consumes and
--- the result it reports.
---
--- FEATURES & RATIONALE:
--- 1. Authenticated by a private token. The session file sits in a 0700 folder
---    under the user's own Library; a request must carry its token.
--- 2. The termination coordinator decides. An admitted request goes to the
---    same controlled reload as the menu (lease fence, input drain, teardown);
---    nothing here starts or ends a process.
--- 3. Three separate outcomes. hs.reload keeps this process, so it is its own
---    successor: "requested" names it, a refusal names its reason, and the
---    reloaded Lua state writes "completed" once its boot is complete.
--- 4. Rung by the folder itself. A pathwatcher on the private folder notices
---    the request file; the work runs on a later timer, never in the callback.
--- ==============================================================================

local M = {}

local Logger = require("infra.logger")
local Policy = require("control.driver_control")
local Json = require("json")

local LOG = "driver_control"

local Session = {}
Session.__index = Session

local _session = nil





-- ==========================
-- ==========================
-- ======= 1/ Ports =========
-- ==========================
-- ==========================

local function quote(path)
	return "'" .. path:gsub("'", "'\\''") .. "'"
end

--- Native operations, replaceable by tests.
--- @return table ports
local function native_ports()
	local FileSystem = require("adapters.file_system")
	local ShellRunner = require("adapters.shell_runner")
	return {
		read = FileSystem.read,
		write = function(path, text) return FileSystem.write(path, text) == true end,
		remove = FileSystem.delete,
		exists = FileSystem.exists,
		private_dir = function(path)
			-- Once at start: mkdir -m sets the mode on the last component only, so
			-- chmod also fixes a folder an older session left with another mode.
			ShellRunner.exec("/bin/mkdir -p " .. quote(path) .. " && /bin/chmod 700 " .. quote(path))
			local attributes = hs.fs.attributes(path)
			return type(attributes) == "table" and attributes.mode == "directory"
				and attributes.permissions == "rwx------"
		end,
		random_hex = function(digits)
			local file = io.open("/dev/urandom", "rb")
			if not file then return nil end
			local count = math.floor(digits / 2)
			local bytes = file:read(count)
			file:close()
			if type(bytes) ~= "string" or #bytes ~= count then return nil end
			return (bytes:gsub(".", function(c) return string.format("%02x", c:byte()) end))
		end,
		watch = function(path, callback)
			local watcher = hs.pathwatcher.new(path, callback)
			if watcher == nil or watcher:start() ~= watcher then error("the control folder watcher did not start", 0) end
			return watcher
		end,
		defer = function(callback) return require("adapters.timer_scheduler").after(0, callback) end,
	}
end





-- ===========================
-- ===========================
-- ======= 2/ Session ========
-- ===========================
-- ===========================

--- Creates one session; it publishes nothing until start().
--- @param opts table { spec, folder, pid, request_reload, ports? };
---   `request_reload(reason, on_aborted)` is TerminationCoordinator.request_reload_owned.
--- @return table session
function M.new(opts)
	assert(type(opts) == "table" and type(opts.spec) == "table", "driver control needs its declaration")
	assert(type(opts.folder) == "string" and opts.folder ~= "", "driver control needs its folder")
	assert(type(opts.pid) == "number" and opts.pid > 0, "driver control needs this process id")
	assert(type(opts.request_reload) == "function", "driver control needs the termination coordinator")
	return setmetatable({ spec = opts.spec, folder = opts.folder, pid = opts.pid,
		request_reload = opts.request_reload, ports = opts.ports or native_ports(),
		token = nil, started = false, active = false, watcher = nil, pending = false }, Session)
end

function Session:path(kind)
	return self.folder .. "/" .. self.spec.files[kind]
end

function Session:report(fields)
	fields.driver_pid = self.pid
	local ok, err = pcall(function()
		if not self.ports.write(self:path("result"), Policy.result_text(self.spec, fields)) then
			error("the result file could not be written", 0)
		end
	end)
	if not ok then Logger.error(LOG, "The reload result could not be written: %s.", tostring(err)) end
end

--- Completes a pending request naming this process, publishes the session,
--- then watches the folder.
function Session:start()
	if self.started then error("the driver control session cannot be started twice", 2) end
	self.started = true
	if not self.ports.private_dir(self.folder) then
		error("the control folder could not be made private: " .. self.folder, 0)
	end
	local completed = Policy.completion(self.spec, self.ports.read(self:path("result")), self.pid, Json.decode)
	if completed then
		if not self.ports.write(self:path("result"), completed) then error("the completion could not be written", 0) end
		Logger.success(LOG, "Reload request completed after the controlled reload of pid %d.", self.pid)
	end
	local token = self.ports.random_hex(self.spec.token_hex_length)
	if not Policy.is_token(self.spec, token) then error("the system random generator gave no token", 0) end
	self.token = token
	if not self.ports.write(self:path("session"), Policy.session_text(self.spec, "macos", self.pid, token)) then
		error("the session file could not be written", 0)
	end
	self.active = true
	local request_name = self.spec.files.request
	self.watcher = self.ports.watch(self.folder, function(paths)
		if not self.active or self.pending then return end
		for _, changed in ipairs(type(paths) == "table" and paths or {}) do
			if type(changed) == "string" and changed:sub(-#request_name - 1) == "/" .. request_name then
				self.pending = true
				self.ports.defer(function()
					self.pending = false
					self:handle()
				end)
				return
			end
		end
	end)
end

--- Stops watching and withdraws the session file this process still owns.
--- @return boolean stopped
function Session:stop()
	self.active = false
	if self.watcher then
		local watcher = self.watcher
		self.watcher = nil
		watcher:stop()
	end
	if self.token == nil then return true end
	local current = self.ports.read(self:path("session"))
	if type(current) == "string" and current:find('"token":"' .. self.token .. '"', 1, true)
		and not self.ports.remove(self:path("session")) then
		Logger.error(LOG, "The driver control session file could not be withdrawn.")
		return false
	end
	return true
end

--- Runs one request; reports its outcome in the result file.
--- @return boolean requested
function Session:handle()
	if not self.active then return false end
	local request_path = self:path("request")
	if not self.ports.exists(request_path) then return false end
	local text = self.ports.read(request_path)
	-- Consumed before it acts, so one request never runs twice.
	if not self.ports.remove(request_path) then
		Logger.error(LOG, "The reload request file could not be consumed; request refused.")
		self:report({ state = "refused", reason = "failed" })
		return false
	end
	local id, reason, echoed = Policy.parse_request(self.spec, text or "", self.token, Json.decode)
	if not id then
		Logger.warn(LOG, "Reload request refused: %s.", reason)
		self:report({ request_id = echoed, state = "refused", reason = reason })
		return false
	end
	Logger.info(LOG, "Reload request %s admitted; the termination coordinator decides.", id)
	-- Written first: the reload may finalize this Lua state before it returns.
	self:report({ request_id = id, state = "requested", successor_pid = self.pid })
	local aborted = false
	local ran, accepted = pcall(self.request_reload, "driver_control", function()
		aborted = true
		Logger.warn(LOG, "Reload request %s aborted by the termination coordinator.", id)
		self:report({ request_id = id, state = "refused", reason = "refused" })
	end)
	if ran and accepted == true then return not aborted end
	Logger.warn(LOG, "Reload request %s refused: %s.", id, ran and "another termination owns the driver"
		or tostring(accepted))
	self:report({ request_id = id, state = "refused", reason = ran and "busy" or "failed" })
	return false
end

M.Session = Session





-- ==========================
-- ==========================
-- ======= 3/ Owner =========
-- ==========================
-- ==========================

--- Starts the driver's local reload control once boot is complete.
--- @param opts table { pid, request_reload, declaration? }
--- @return boolean started
function M.start(opts)
	if _session ~= nil then error("the local reload control already has an owner", 2) end
	Logger.start(LOG, "Starting the local reload control…")
	local ok, session_or_err = pcall(function()
		local declaration = opts.declaration
			or require("infra.paths").shared("modules/control/driver_control.json")
		local text = require("adapters.file_system").read(declaration)
		if type(text) ~= "string" then error("the declaration could not be read: " .. tostring(declaration), 0) end
		local spec = Policy.validate(Json.decode(text))
		local folder, why = Policy.folder(spec, "macos", os.getenv, require("app_dirs").folder_name, "/")
		if not folder then error(why, 0) end
		local session = M.new({ spec = spec, folder = folder, pid = opts.pid, request_reload = opts.request_reload })
		_session = session
		session:start()
		return session
	end)
	if not ok then
		if _session then pcall(function() _session:stop() end) end
		_session = nil
		Logger.error(LOG, "Local reload control could not start: %s.", tostring(session_or_err))
		return false
	end
	Logger.success(LOG, "Local reload control ready.")
	return true
end

--- Retires the local reload control.
--- @return boolean stopped
function M.stop()
	if _session == nil then return true end
	local stopped = _session:stop()
	_session = nil
	Logger.info(LOG, "Local reload control retired.")
	return stopped
end

return M
