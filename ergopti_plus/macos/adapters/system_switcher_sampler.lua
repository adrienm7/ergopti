--- adapters/system_switcher_sampler.lua

--- Runs the finite read-only helper with exact task ownership and pinned identity.
--- Native HID and combined-session receipts remain distinct from Quartz tap ACKs.
local M = {}
local Environment = require("infra.launcher_environment")
local KEYS = { [54] = true, [55] = true, [56] = true, [60] = true,
	[58] = true, [61] = true, [59] = true, [62] = true, [48] = true }
local MASK = 0x9E0000

local function plain(value) return type(value) == "table" and getmetatable(value) == nil end
local function integer(value)
	return type(value) == "number" and value == value and value % 1 == 0
		and value >= 0 and value <= 9007199254740991
end
local function held_clear(value)
	if not plain(value) then return nil end
	local seen, count = {}, 0
	for index, key in pairs(value) do
		if not integer(index) or index < 1 or index > #value or not KEYS[key]
			or seen[key] then return nil end
		seen[key], count = true, count + 1
	end
	if count ~= #value or count > 9 then return nil end
	return count == 0
end
local function fields(value, expected)
	if not plain(value) then return false end
	local count = 0
	for name in pairs(value) do if not expected[name] then return false end; count = count + 1 end
	local wanted = 0
	for name in pairs(expected) do if rawget(value, name) == nil then return false end; wanted = wanted + 1 end
	return count == wanted
end
local FRAME = { version = true, request = true, source = true, held = true,
	flags = true, listen_access = true, post_access = true, ax_trusted = true, session = true }
local SESSION = { version = true, request = true, source = true, held = true, flags = true }

--- Validates immutable native helper identity; no access prompt is requested.
--- @param config table {path, sha256, dev, ino}.
--- @return table|nil sampler
function M.new(config)
	if not plain(config) or type(config.path) ~= "string" or config.path:sub(1, 1) ~= "/"
		or config.path:find("%z") or type(config.sha256) ~= "string"
		or not config.sha256:match("^[0-9a-f]+$") or #config.sha256 ~= 64
		or not integer(config.dev) or not integer(config.ino) then return nil end
	local path, digest, dev, ino = config.path, config.sha256, config.dev, config.ino
	local native = hs
	local current, counter, busy = nil, 0, false
	local owner = {}
	local function pinned()
		local ok, valid = pcall(function()
			local before = native.fs.symlinkAttributes(path)
			if not before or before.mode ~= "file" or before.dev ~= dev or before.ino ~= ino then return false end
			local input = io.open(path, "rb")
			if not input then return false end
			local bytes = input:read(2 * 1024 * 1024 + 1)
			local closed = input:close()
			if closed ~= true or type(bytes) ~= "string" or #bytes > 2 * 1024 * 1024 then return false end
			local after = native.fs.symlinkAttributes(path)
			local hash = native.hash.SHA256(bytes)
			return after ~= nil and after.mode == "file" and after.dev == dev and after.ino == ino
				and type(hash) == "string" and hash:lower() == digest
		end)
		return ok and valid == true
	end
	local function stopped(entry)
		if not entry.task then return not entry.unknown end
		local ok, running = pcall(entry.task.isRunning, entry.task)
		return ok and running == false
	end
	function owner.current() return pinned() end

	--- Reserves before task construction/start; refused starts retain exact task debt.
	function owner.request(cap)
		if busy or current ~= nil or type(cap) ~= "table" then return false end
		counter = counter % 9999 + 1
		local entry = { cap = cap, request = counter, acquiring = true }
		current = entry
		if not pinned() then entry.failed, entry.acquiring = true, false; return false end
		local constructed, task = pcall(native.task.new, path, function(code, stdout, stderr)
			if rawequal(current, entry) then entry.receipt = { code, stdout, stderr } end
		end, { tostring(counter) })
		entry.task = task
		if not constructed or task == nil or task == false then
			entry.task = nil
			entry.acquiring = false
			entry.failed = true
			return false
		end
		local started, receipt = false, nil
		local configured = pcall(function()
			local env = Environment.child_copy(task:environment())
			if not env or not rawequal(task:setEnvironment(env), task)
				or not Environment.verify_child_copy(env, task:environment()) then return end
			if pinned() then started, receipt = pcall(task.start, task) end
		end)
		entry.admitted = configured and started and rawequal(receipt, task)
		entry.acquiring = false
		return entry.admitted
	end

	--- Delivers only same-request, admitted, physically stopped native observations.
	function owner.take(cap)
		local entry = current
		if busy or not entry or not rawequal(entry.cap, cap) or entry.acquiring then return nil end
		busy = true
		if not stopped(entry) then busy = false; return nil end
		local ok, frame = pcall(function()
			if entry.admitted ~= true or not entry.receipt or not pinned() then return nil end
			local receipt = entry.receipt
			if receipt[1] ~= 0 or type(receipt[2]) ~= "string" or #receipt[2] > 512
				or receipt[3] ~= "" then return nil end
			local raw = native.json.decode(receipt[2])
			if not fields(raw, FRAME) or raw.version ~= 1 or raw.request ~= entry.request
				or raw.source ~= "hid_system" or not integer(raw.flags)
				or raw.listen_access ~= true or raw.post_access ~= true or raw.ax_trusted ~= true
				or not fields(raw.session, SESSION) or raw.session.version ~= 1
				or raw.session.request ~= entry.request or raw.session.source ~= "combined_session"
				or not integer(raw.session.flags) then return nil end
			local hid, session = held_clear(raw.held), held_clear(raw.session.held)
			if hid == nil or session == nil then return nil end
			local held = {}
			for _, key in ipairs(raw.session.held) do held[key] = true end
			return { hid_clear = hid and (raw.flags & MASK) == 0,
				session_clear = session and (raw.session.flags & MASK) == 0,
				session_held = held, session_flags = raw.session.flags & MASK }
		end)
		busy = false
		if not rawequal(current, entry) then return false end
		current = nil
		if not ok or frame == nil then return false end
		return true, frame
	end

	--- Stops only the retained exact helper task and observes physical retirement.
	function owner.retire(cap)
		local entry = current
		if not entry then return true end
		if busy or not rawequal(entry.cap, cap) or entry.acquiring then return false end
		busy = true
		local ok, settled = pcall(function()
			if stopped(entry) then return true end
			pcall(entry.task.terminate, entry.task)
			return stopped(entry)
		end)
		busy = false
		if not ok or not settled or not rawequal(current, entry) then return false end
		current = nil
		return true
	end
	return owner
end

return M
