--- infra/driver_control.lua

--- ==============================================================================
--- MODULE: Local Driver Control (Linux)
--- DESCRIPTION:
--- A tool run by the same user asks this daemon to reload. The policy is the
--- shared _shared/lua/control/driver_control.lua; this module owns the session
--- in $XDG_RUNTIME_DIR, the request it consumes and the result it reports.
---
--- FEATURES & RATIONALE:
--- 1. Authenticated twice. Only the same user (or root) may send SIGUSR1, the
---    signal that rings this owner, and the request must carry the token of
---    the session file in a 0700 folder only that user can read.
--- 2. The tray's reload owner decides. An admitted request goes to the same
---    daemon restart the tray item runs; nothing here starts or ends a process.
--- 3. A restart cannot name its successor beforehand (systemd or the relay
---    start it), so the request is written as a pending record: successor null
---    and a deadline. The successor claims it once ready and completes it, or
---    refuses it with the reason of its own boot; a record past its deadline
---    is reported as timeout, never as completed
---    (docs/design/driver-control-pending-record.md).
--- ==============================================================================

local M = {}

local Logger = require("logger.shim")
local Policy = require("control.driver_control")
local Json = require("json")

local LOG = "infra.driver_control"
local PRIVATE_MODE = 448 -- 0700

local Session = {}
Session.__index = Session





-- ==========================
-- ==========================
-- ======= 1/ Folder ========
-- ==========================
-- ==========================

--- Native file operations, replaceable by tests.
--- @return table ports
local function native_ports()
	local uv = require("luv")
	local FileSystem = require("adapters.file_system")
	return {
		read = FileSystem.read,
		write = FileSystem.write,
		remove = function(path)
			local ok, _, code = uv.fs_unlink(path)
			return ok ~= nil or code == "ENOENT"
		end,
		rename = function(from, to) return os.rename(from, to) == true end,
		exists = function(path) return uv.fs_stat(path) ~= nil end,
		private_dir = function(path)
			local stat = uv.fs_stat(path)
			if stat == nil and not uv.fs_mkdir(path, PRIVATE_MODE) then return false end
			stat = uv.fs_stat(path)
			if stat == nil or stat.type ~= "directory" then return false end
			-- 0700 whatever the umask, then proven, so no other user can read the token.
			if not uv.fs_chmod(path, PRIVATE_MODE) then return false end
			stat = uv.fs_stat(path)
			return stat ~= nil and stat.mode % 512 == PRIVATE_MODE
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
	}
end





-- ===========================
-- ===========================
-- ======= 2/ Session ========
-- ===========================
-- ===========================

--- Creates one session; it publishes nothing until start().
--- @param opts table { spec, folder, pid, reload, ports?, boot_outcome? };
---   `reload(trigger)` returns true once a restart is under way (or already
---   was), or false and "postponed" or "failed"; `boot_outcome()` answers
---   true, or false and "refused"/"failed", for this process's own boot.
--- @return table session
function M.new(opts)
	assert(type(opts) == "table" and type(opts.spec) == "table", "driver control needs its declaration")
	assert(type(opts.folder) == "string" and opts.folder ~= "", "driver control needs its folder")
	assert(type(opts.pid) == "number" and opts.pid > 0, "driver control needs this process id")
	assert(type(opts.reload) == "function", "driver control needs the reload owner")
	assert(opts.boot_outcome == nil or type(opts.boot_outcome) == "function", "boot_outcome must be a function")
	local ports = opts.ports or native_ports()
	ports.now = ports.now or os.time
	return setmetatable({ spec = opts.spec, folder = opts.folder, pid = opts.pid, reload = opts.reload,
		boot_outcome = opts.boot_outcome, ports = ports, token = nil, started = false, active = false }, Session)
end

function Session:path(kind)
	return self.folder .. "/" .. self.spec.files[kind]
end

-- Each file is replaced whole, so a reader never sees half a result.
function Session:publish(kind, text)
	local target = self:path(kind)
	local stage = target .. ".tmp-" .. tostring(self.pid)
	if not self.ports.write(stage, text) then error("the " .. kind .. " file could not be staged", 0) end
	if not self.ports.rename(stage, target) then
		self.ports.remove(stage)
		error("the " .. kind .. " file could not be published", 0)
	end
end

function Session:report(fields)
	fields.driver_pid = self.pid
	local ok, err = pcall(function() self:publish("result", Policy.result_text(self.spec, fields)) end)
	if not ok then Logger.error(LOG, "The reload result could not be written: %s.", tostring(err)) end
end

--- Completes a pending request naming this process, then publishes the session.
function Session:start()
	if self.started then error("the driver control session cannot be started twice", 2) end
	self.started = true
	local parent = self.folder:match("^(.*)/[^/]+$")
	if not parent or not self.ports.private_dir(parent) or not self.ports.private_dir(self.folder) then
		error("the control folder could not be made private: " .. self.folder, 0)
	end
	self:resolve_pending()
	local token = self.ports.random_hex(self.spec.token_hex_length)
	if not Policy.is_token(self.spec, token) then error("the system random generator gave no token", 0) end
	self.token = token
	self:publish("session", Policy.session_text(self.spec, "linux", self.pid, token))
	self.active = true
end

--- Settles the pending result this process owes, if any: claims a record that
--- names no successor, then completes it or refuses it with the reason of this
--- process's own boot; a record past its deadline becomes a timeout.
function Session:resolve_pending()
	local text = self.ports.read(self:path("result"))
	local kind, owed = Policy.resolve(self.spec, text, self.pid, self.ports.now(), Json.decode)
	if not kind then return end
	self:publish("result", owed)
	if kind == "timeout" then
		Logger.warn(LOG, "A pending reload request passed its deadline before this process was ready; reported as timeout.")
		return
	end
	if kind == "completed" then
		Logger.success(LOG, "Reload request completed in successor pid %d.", self.pid)
		return
	end
	-- Claimed: this process is the successor. Its own boot decides the answer.
	Logger.info(LOG, "Reload request claimed by successor pid %d.", self.pid)
	local ok, reason = true, nil
	if self.boot_outcome then
		local ran, answered, why = pcall(self.boot_outcome)
		ok = ran and answered == true
		reason = ok and nil or (ran and why or "failed")
	end
	local current = Json.decode(owed)
	if ok then
		self:publish("result", Policy.result_text(self.spec, { request_id = current.request_id, state = "completed",
			driver_pid = self.pid, successor_pid = self.pid }))
		Logger.success(LOG, "Reload request completed in successor pid %d.", self.pid)
	else
		self:publish("result", Policy.result_text(self.spec, { request_id = current.request_id, state = "refused",
			driver_pid = self.pid, reason = self.spec.reason_set[reason] and reason or "failed" }))
		Logger.warn(LOG, "Reload request refused by the successor's boot (%s).", tostring(reason))
	end
end

--- Withdraws the session file this process still owns.
--- @return boolean stopped
function Session:stop()
	self.active = false
	if self.token == nil then return true end
	local current = self.ports.read(self:path("session"))
	if type(current) == "string" and current:find('"token":"' .. self.token .. '"', 1, true)
		and not self.ports.remove(self:path("session")) then
		Logger.error(LOG, "The driver control session file could not be withdrawn.")
		return false
	end
	return true
end

--- Runs one rung request; reports its outcome in the result file.
--- @return boolean reloaded
function Session:handle()
	if not self.active then
		Logger.warn(LOG, "Reload control rang before it was ready.")
		return false
	end
	local request_path = self:path("request")
	if not self.ports.exists(request_path) then
		Logger.warn(LOG, "Reload control rang without a request file.")
		return false
	end
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
	Logger.info(LOG, "Reload request %s admitted; the reload owner decides.", id)
	-- Written before the restart: it may end this process before it returns.
	self:report({ request_id = id, state = "requested",
		deadline = self.ports.now() + self.spec.pending_ttl_seconds })
	local ran, reloaded, why = pcall(self.reload, "the local reload control")
	if ran and reloaded == true then
		Logger.info(LOG, "Reload request %s requested; the successor claims it once ready.", id)
		return true
	end
	local cause = ran and why == "postponed" and "busy" or ran and why == "failed" and "failed"
		or ran and "refused" or "failed"
	Logger.warn(LOG, "Reload request %s refused (%s): %s.", id, cause, tostring(ran and why or reloaded))
	self:report({ request_id = id, state = "refused", reason = cause })
	return false
end

M.Session = Session





-- ==========================
-- ==========================
-- ======= 3/ Owner =========
-- ==========================
-- ==========================

--- Starts the daemon's local reload control.
--- @param opts table { pid, reload, boot_outcome?, declaration? }
--- @return table|nil session, string|nil error
function M.start(opts)
	Logger.start(LOG, "Starting the local reload control…")
	local ok, session_or_err = pcall(function()
		local file = assert(io.open(opts.declaration or require("infra.paths").shared("modules/control/driver_control.json"), "rb"))
		local text = assert(file:read("*a"))
		assert(file:close())
		local spec = Policy.validate(Json.decode(text))
		local folder, why = Policy.folder(spec, "linux", os.getenv, require("app_dirs").folder_name, "/")
		if not folder then error(why, 0) end
		local session = M.new({ spec = spec, folder = folder, pid = opts.pid, reload = opts.reload,
			boot_outcome = opts.boot_outcome })
		session:start()
		return session
	end)
	if not ok then
		Logger.error(LOG, "Local reload control could not start: %s.", tostring(session_or_err))
		return nil, tostring(session_or_err)
	end
	Logger.success(LOG, "Local reload control ready.")
	return session_or_err
end

return M
