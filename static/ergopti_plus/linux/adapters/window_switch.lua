--- adapters/window_switch.lua

--- Scoped X11 window operations retain exact native retirement ownership.
local M = {}
local Worker = require("native_worker_owner")
local Runner = require("adapters.program_runner")
local Policy = require("cursor_window_policy")
local Display = require("infra.display_server")
local Shell = require("adapters.shell_runner")
local Paths = require("infra.paths")
local Timings = require("infra.timings")
local loaded, Native = pcall(require, "luv")
if not loaded then Native = nil end
local TOOLS = { "timeout", "xdotool", "xrandr", "xprop", "xwininfo", "sha256sum" }
local LIMIT = 65536

--- Returns a translated native capability reason, never a global fallback.
--- @return boolean available
--- @return string|nil reason Existing translation key.
--- @return string|nil tool Missing native command.
function M.available()
	if Display.kind() ~= Display.X11 then return false, "dialog.action_picker.requires_x11" end
	if not Runner.supported() or not Native then return false, "platform_reason.program_runner_unavailable" end
	for _, tool in ipairs(TOOLS) do
		if Shell.has_command(tool) ~= true then return false, "dialog.action_picker.requires_tool", tool end
	end
	return true
end

M.parse_snapshot = Policy.parse_snapshot

--- Creates a scoped native owner using a canonical binding/source admission port.
--- @param capture function Returns a fresh admission callback for the binding.
--- @param ports table|nil Native/test IO ports, never user configuration.
--- @return table owner Async dispatch and truthful physical retirement.
function M.new(capture, ports)
	ports = ports or {}
	local native, runner = ports.native or Native, ports.runner or Runner
	local constants = native and native.constants or Native and Native.constants
	local read_flags = constants and constants.O_RDONLY + constants.O_NONBLOCK
	local write_flags = constants and constants.O_RDWR + constants.O_NONBLOCK
	local source = ports.source or function() return os.getenv("DISPLAY") end
	local current, paused, generation, idle = nil, false, 0, {}
	local desired_paused = false
	local owner, process = {}, nil
	local function notify()
		if current ~= nil then return end
		local callbacks = idle; idle = {}
		for _, callback in ipairs(callbacks) do pcall(callback) end
	end
	local function live(operation)
		if current ~= operation or operation.cancelled or paused or operation.epoch ~= generation
			or Display.kind() ~= Display.X11 or source() ~= operation.source then return false end
		local ok, admitted = pcall(operation.admission)
		return ok and admitted == true
	end
	local function close_owned(file, field)
		local receipt = file[field]
		if not receipt then return true end
		local ok, stat = pcall(native.fs_fstat, receipt.fd)
		if not ok or type(stat) ~= "table" then return false end
		if receipt.dev == nil then receipt.dev, receipt.ino, receipt.type = stat.dev, stat.ino, stat.type end
		if stat.dev ~= receipt.dev or stat.ino ~= receipt.ino or (receipt.type and stat.type ~= receipt.type) then return false end
		local closed, value = pcall(native.fs_close, receipt.fd)
		if not closed or value ~= true then return false end
		file[field] = nil
		return true
	end
	local function cleanup(operation)
		if not operation.directory then return true end
		for _, file in ipairs(operation.files) do
			for _, field in ipairs({ "fd", "read_fd", "write_fd" }) do
				if not close_owned(file, field) then return false end
			end
			if not file.removed then
				local inspected, stat = pcall(native.fs_lstat, file.path)
				if not inspected or type(stat) ~= "table" or stat.dev ~= file.dev or stat.ino ~= file.ino
					or stat.type ~= "file" then return false end
				local ok, receipt = pcall(native.fs_unlink, file.path)
				if not ok or receipt ~= true then return false end
				file.removed = true
			end
		end
		local inspected, directory = pcall(native.fs_lstat, operation.directory)
		if not inspected or type(directory) ~= "table" or directory.dev ~= operation.directory_dev
			or directory.ino ~= operation.directory_ino or directory.type ~= "directory" then return false end
		local ok, receipt = pcall(native.fs_rmdir, operation.directory)
		if not ok or receipt ~= true then return false end
		operation.directory = nil
		return true
	end
	local function owned_regular(file)
		local ok, stat = pcall(native.fs_lstat, file.path)
		return ok and type(stat) == "table" and stat.type == "file" and stat.dev == file.dev and stat.ino == file.ino
	end
	local function read_bytes(file, limit)
		if not read_flags or not close_owned(file, "read_fd") or not owned_regular(file) then return nil end
		-- O_NONBLOCK prevents a same-UID replacement FIFO from stalling input.
		-- fstat below still rejects every non-owned or non-regular content source.
		local fd = native.fs_open(file.path, read_flags, 0)
		if not fd then return nil end
		file.read_fd = { fd = fd }
		local ok, packet = pcall(function()
			local stat = native.fs_fstat(fd)
			if type(stat) == "table" then file.read_fd.dev, file.read_fd.ino, file.read_fd.type = stat.dev, stat.ino, stat.type end
			if not stat or stat.dev ~= file.dev or stat.ino ~= file.ino or stat.mode % 512 ~= 384
				or stat.type ~= "file" or stat.size < 0 or stat.size > limit then return nil end
			local data = stat.size == 0 and "" or native.fs_read(fd, stat.size, 0)
			return data and #data == stat.size and data or nil
		end)
		if not close_owned(file, "read_fd") then return nil end
		return ok and packet or nil
	end
	local function read(file)
		return Policy.parse_snapshot(read_bytes(file, LIMIT))
	end
	local function write_bytes(file, content)
		if not write_flags or not file or file.removed or not close_owned(file, "write_fd") or not owned_regular(file) then return false end
		local fd = native.fs_open(file.path, write_flags, 0)
		if not fd then return false end
		file.write_fd = { fd = fd }
		local ok, accepted = pcall(function()
			local stat = native.fs_fstat(fd)
			if type(stat) == "table" then file.write_fd.dev, file.write_fd.ino, file.write_fd.type = stat.dev, stat.ino, stat.type end
			if not stat or stat.type ~= "file" or stat.dev ~= file.dev or stat.ino ~= file.ino then return false end
			return native.fs_write(fd, content, 0) == #content and native.fs_ftruncate(fd, #content) == true
		end)
		local closed = close_owned(file, "write_fd")
		return ok and accepted == true and closed
	end
	local function finish(operation, success)
		if current ~= operation or operation.acquiring or not cleanup(operation) then return false end
		success = success == true and live(operation)
		current = nil
		if desired_paused == false then paused = false end
		if type(operation.done) == "function" then pcall(operation.done, success == true) end
		notify()
		return true
	end
	local function transport_receipt(operation)
		local records = { string.format("%.0f:%.0f", operation.directory_dev, operation.directory_ino) }
		for _, file in ipairs(operation.files) do records[#records + 1] = string.format("%.0f:%.0f", file.dev, file.ino) end
		return table.concat(records, ",")
	end
	process = Worker.new(function(stage)
		if type(stage) ~= "table" or not live(stage.operation) then return nil end
		return {
			executable = native.exepath(),
			arguments = {
				"-e", "package.path = assert(table.remove(arg))",
				Paths.driver_root() .. "/platform/window_switch_worker.lua", stage.name,
				stage.operation.files[stage.name == "snapshot" and 1 or 2].path,
				stage.operation.files[1].path, stage.operation.source,
				stage.operation.files[3].path, stage.operation.files[4].path,
				stage.operation.files[5].path, stage.operation.config_path or "",
				transport_receipt(stage.operation), stage.operation.directory, package.path,
			},
		}, function() return live(stage.operation) end
	end, {
		runner = runner, native = native, parse = function(value) return value end,
		timeout_ms = Timings.ms("gestures", "aux_shell_timeout_ms"),
		retry_ms = Timings.ms("gestures", "aux_shell_cleanup_retry_ms"),
		pulse = function(stage)
			local operation = stage.operation
			if stage.name ~= "focus" then return true end
			if not live(operation) then write_bytes(operation.files[4], "REVOKED\n"); return false end
			local request = read_bytes(operation.files[3], 64)
			if request == "" then return true end
			local phase = request and tonumber(request:match("^READY ([12])\n$"))
			if not phase then return false end
			if operation.permit_phase and phase <= operation.permit_phase then return true end
			if not live(operation) or not write_bytes(operation.files[4], "PERMIT " .. phase .. "\n") then return false end
			operation.permit_phase = phase
			if not live(operation) then write_bytes(operation.files[4], "REVOKED\n"); return false end
			return true
		end,
		retire = function(stage, status, cancelled)
			local operation = stage.operation
			if stage.name == "snapshot" and status == 0 and not cancelled and live(operation) then return true end
			if stage.name == "focus" and status == 0 and not cancelled and live(operation) and not operation.ack_checked then
				local ok, final = pcall(read, operation.files[2])
				operation.ack_checked = true
				operation.acknowledged = ok and Policy.acknowledged(operation.first, final, operation.target) or false
			end
			return cleanup(operation)
		end,
		complete = function(status, stage)
			local operation = stage.operation
			if not live(operation) then return end
			if status ~= 0 then finish(operation, false); return end
			if stage.name == "focus" then finish(operation, operation.acknowledged); return end
			local ok, first = pcall(read, operation.files[1])
			local active = ok and first and first.windows[first.active]
			local target = ok and first and Policy.candidate(first)
			if not target or not first.root or not active or active.screen ~= first.pointer.screen then
				finish(operation, false); return
			end
			operation.first, operation.target = first, target
			if process.run({ operation = operation, name = "focus" }) ~= true then
				process.when_settled(function() finish(operation, false) end)
			end
		end,
	})
	function owner.when_settled(callback)
		if type(callback) ~= "function" then return false end
		if current == nil then pcall(callback) else idle[#idle + 1] = callback end
		return true
	end
	function owner.stop()
		generation = generation + 1
		desired_paused, paused = true, true
		local operation = current
		if operation then
			operation.cancelled = true
			if operation.files[4] and not operation.files[4].removed then write_bytes(operation.files[4], "REVOKED\n") end
			process.stop()
			process.when_settled(function() finish(operation, false) end)
		end
		return current == nil
	end
	function owner.set_paused(value)
		if type(value) ~= "boolean" then return false end
		if value then return owner.stop() end
		desired_paused = false
		local ready = process.set_paused(false)
		if current ~= nil or ready ~= true then return false end
		paused = false
		generation = generation + 1
		return true
	end
	function owner.invalidate()
		local wanted = desired_paused
		local settled = owner.stop()
		if wanted == false then owner.set_paused(false) end
		return settled
	end
	function owner.has_pending() return current ~= nil or process.has_pending() end
	function owner.run(binding, done)
		if paused or current ~= nil or Display.kind() ~= Display.X11 then return false end
		local operation = { epoch = generation, acquiring = true, files = {}, done = done }
		current = operation
		local captured, admission, config_path = pcall(capture, binding)
		operation.admission, operation.source, operation.config_path = admission, source(), config_path
		if not captured or type(admission) ~= "function" or type(operation.source) ~= "string"
			or operation.source == "" or operation.source:find("%z")
			or (config_path ~= nil and (type(config_path) ~= "string" or config_path:find("%z"))) or not live(operation) then
			operation.acquiring = false; finish(operation, false); return false
		end
		local acquired = pcall(function()
			local directory = native.fs_mkdtemp((os.getenv("TMPDIR") or "/tmp") .. "/ergopti-window-XXXXXX")
			operation.directory = assert(directory)
			local directory_stat = assert(native.fs_lstat(directory))
			operation.directory_dev, operation.directory_ino = directory_stat.dev, directory_stat.ino
			for _, name in ipairs(Policy.TRANSPORT_NAMES) do
				local file = { path = directory .. "/" .. name }
				local fd = assert(native.fs_open(file.path, "wx", 384))
				operation.files[#operation.files + 1] = file
				file.fd = { fd = fd }
				local stat = assert(native.fs_fstat(fd))
				file.dev, file.ino = stat.dev, stat.ino
				file.fd.dev, file.fd.ino = stat.dev, stat.ino
				assert(close_owned(file, "fd"))
			end
		end)
		operation.acquiring = false
		if not acquired or not live(operation) then finish(operation, false); return false end
		local accepted = process.run({ operation = operation, name = "snapshot" })
		process.when_settled(function() finish(operation, false) end)
		if accepted ~= true then return false end
		return true
	end
	return owner
end

return M
