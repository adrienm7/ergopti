--- tests/hardware/run_program_provider_receipts.lua

--- Actual discovery-to-runner receipts, with flat children and private binary argv.
--- System interpreters are copied into owned tmpfs so the Cloud overlay's rounded
--- system inode numbers cannot silently become physical identity receipts.
local uv, ffi = require("luv"), require("ffi")
ffi.cdef[[ int prctl(int option, unsigned long arg2, unsigned long arg3, unsigned long arg4, unsigned long arg5); ]]
assert(ffi.C.prctl(36, 1, 0, 0, 0) == 0, "provider fixture requires owned child-subreaper support")
local Providers = require("adapters.program_providers")
local Runner = require("adapters.program_runner")
local Owner = require("modules.gestures.program_owner")
local Parameter = require("program_parameter")
local Logger = require("logger.shim")
local previous_error, messages = Logger.error, {}
Logger.error = function(_, template, ...) messages[#messages + 1] = string.format(template, ...) end
local root = assert(uv.fs_mkdtemp("/tmp/ergopti-provider-native-XXXXXX"))
local scripts, bin = root .. "/scripts", root .. "/bin"
local files, owners, handles = {}, {}, {}
local native_targets = {}
local function write(path, bytes, mode)
	local fd = assert(uv.fs_open(path, "w", mode or 384))
	assert(uv.fs_write(fd, bytes, 0)); assert(uv.fs_close(fd)); assert(uv.fs_chmod(path, mode or 384))
	files[path] = true
end
local function read(path)
	local file = io.open(path, "rb")
	if not file then return end
	local bytes = file:read("*a"); assert(file:close()); return bytes
end
local function await(predicate)
	local deadline = uv.hrtime() + 5000000000
	repeat uv.run("nowait"); if predicate() then return true end; uv.sleep(1) until uv.hrtime() >= deadline
	return false
end
local function identity(pid)
	local bytes = read("/proc/" .. tostring(pid) .. "/stat")
	if not bytes then return end
	local fields = {}
	for field in assert(bytes:match("^%d+ %(.+%) (.+)$")):gmatch("%S+") do fields[#fields + 1] = field end
	return fields[1], tonumber(fields[3]), fields[20]
end
local function discover(label)
	local owner = assert(Providers.create({ route = function() return scripts end, path = function() return bin end }))
	owners[#owners + 1] = owner
	local packet = assert(owner.discover())
	for _, choice in ipairs(packet.choices) do if choice.label == label then return owner, choice.key end end
	error("native fixture failed to discover its independently authored program")
end
local function run(scalar)
	local statuses, receipts = {}, 0
	local handle
	local owner = Owner.new(function(binding)
		assert(binding == "provider_fixture")
		return scalar, function() return true end
	end, { runner = { spawn = function(executable, arguments, completed, admitted)
		handle = Runner.spawn(executable, arguments, function(status)
			statuses[#statuses + 1] = status; completed(status)
		end, admitted)
		handles[#handles + 1] = handle
		return handle
	end } })
	owners[#owners + 1] = { invalidate = owner.stop }
	assert(owner.run("provider_fixture"), "discovered native program was refused by its actual owner")
	assert(owner.when_settled(function() receipts = receipts + 1 end))
	return owner, handle, statuses, function() return receipts end
end
local function settled(owner, handle, receipts, pid, birth)
	assert(await(function() return not owner.has_pending() end), "discovered native program did not physically retire")
	assert(handle.isSettled() and receipts() == 1, "exact discovered handle must settle once")
	if pid then
		local state, group, stamp = identity(pid)
		assert(state == nil, "original flat child must have been reaped")
		assert(group == nil and stamp == nil and birth ~= nil)
		local signalled, _, code = uv.kill(-pid, 0)
		assert(signalled == nil and code == "ESRCH", "exact original detached group must be absent")
	end
	assert(await(function() return not uv.loop_alive() end), "native provider process or timer handles leaked")
end
local literals = { "", "été 日本語", "'single' and \"double\"", "`literal`$(literal)", "%PATH%", "e\204\129", "one\ntwo" }
local expected = {}
for _, value in ipairs(literals) do expected[#expected + 1] = tostring(#value) .. ":" .. value .. "\n" end
expected = table.concat(expected)
local ok, failure = xpcall(function()
	assert(uv.fs_mkdir(scripts, 448)); assert(uv.fs_mkdir(bin, 448))
	for _, command in ipairs({ "sh", "bash", "python3" }) do
		local source = assert(uv.fs_realpath(command == "python3" and "/usr/bin/python3" or "/bin/" .. command))
		local target = bin .. "/" .. command
		write(target, assert(read(source)), 448); native_targets[command] = target
	end
	local shell = [[
LC_ALL=C
export LC_ALL
record=$1
shift
: > "$record"
for argument do printf '%s:%s\n' "${#argument}" "$argument" >> "$record"; done
exit 37
]]
	write(scripts .. "/shell été.sh", shell)
	write(scripts .. "/python 日本語.py", [[
import sys
with open(sys.argv[1], 'wb') as record:
    for value in sys.argv[2:]:
        data = value.encode('utf-8')
        record.write(str(len(data)).encode('ascii') + b':' + data + b'\n')
sys.exit(37)
]])
	write(scripts .. "/exécutable direct", "#!" .. native_targets.sh .. "\n" .. shell, 448)
	write(root .. "/independent binary preimage", expected)
	for _, label in ipairs({ "shell été.sh", "python 日本語.py", "exécutable direct" }) do
		local record = root .. "/record " .. label
		files[record] = true
		local discovery, key = discover(label)
		local arguments = { record }; for _, value in ipairs(literals) do arguments[#arguments + 1] = value end
		local scalar = assert(discovery.resolve(key, arguments))
		local parsed = assert(Parameter.parse(scalar, "linux"))
		assert(parsed.executable == (label:match("%.sh$") and native_targets.sh
			or label:match("%.py$") and native_targets.python3 or scripts .. "/" .. label))
		local owner, handle, statuses, receipts = run(scalar)
		settled(owner, handle, receipts)
		assert(#statuses == 1 and statuses[1] == 37, "actual discovery consumer must preserve exit status 37")
		assert(read(record) == expected and read(root .. "/independent binary preimage") == expected,
			"actual discovered literal argv differs from the authored binary preimage")
		assert(discovery.invalidate())
	end
	-- This flat child uses no fork, subprocess or external command. Its own
	-- deadline also bounds accidental outer-helper loss without orphaning a loop.
	write(scripts .. "/annulation.py", [[
import os
import sys
import time
with open(sys.argv[1], 'w', encoding='ascii') as record:
    record.write(str(os.getpid()))
deadline = time.monotonic() + 10
while time.monotonic() < deadline:
    time.sleep(0.001)
sys.exit(99)
]])
	local metadata = root .. "/owned leader receipt"
	files[metadata] = true
	local discovery, key = discover("annulation.py")
	local owner, handle, statuses, receipts = run(assert(discovery.resolve(key, { metadata })))
	assert(await(function() local bytes = read(metadata); return bytes ~= nil and tonumber(bytes) ~= nil end), "flat child failed to acknowledge readiness")
	local pid = tonumber(read(metadata))
	local state, group, birth = identity(pid)
	assert(state and group == pid and birth, "readiness must name this actual detached child")
	assert(owner.has_pending() and not handle.isSettled() and receipts() == 0)
	assert(owner.stop() == false, "signal acceptance cannot acknowledge physical retirement")
	settled(owner, handle, receipts, pid, birth)
	assert(#statuses == 0, "cancelled discovery must not deliver a successful completion")
	assert(discovery.invalidate())
	-- Real native target refusal: the scalar was admitted before permissions
	-- changed. The actual runner must refuse start without a process allocation.
	discovery, key = discover("exécutable direct")
	local scalar = assert(discovery.resolve(key, {}))
	assert(uv.fs_chmod(scripts .. "/exécutable direct", 384))
	assert(discovery.resolve(key, {}) == nil, "changed permissions invalidate the discovered choice")
	local parsed = assert(Parameter.parse(scalar, "linux"))
	local completed = 0
	local refused = Runner.spawn(parsed.executable, parsed.arguments, function() completed = completed + 1 end, function() return true end)
	handles[#handles + 1] = refused
	assert(refused.start() == false and refused.isSettled() and completed == 0,
		"actual native executable refusal cannot fabricate launch or terminal success")
	assert(discovery.invalidate())
	-- Mode eligibility alone cannot acknowledge exec: this actual executable
	-- names an independently absent native shebang interpreter.
	local absent = root .. "/absent interpreter"
	assert(uv.fs_lstat(absent) == nil)
	write(scripts .. "/refus direct", "#!" .. absent .. "\n", 448)
	discovery, key = discover("refus direct")
	parsed = assert(Parameter.parse(assert(discovery.resolve(key, {})), "linux"))
	assert(Runner.available(parsed.executable), "fixture must reach actual native exec after mode admission")
	local native_refused = Runner.spawn(parsed.executable, parsed.arguments,
		function() completed = completed + 1 end, function() return true end)
	handles[#handles + 1] = native_refused
	assert(native_refused.start() == false and native_refused.isSettled() and completed == 0,
		"native exec refusal cannot fabricate launch or completion")
	assert(discovery.invalidate())
	assert(await(function() return not uv.loop_alive() end))
	assert(#messages == 3, "exact native completions must produce only three closed failure statuses")
	for _, message in ipairs(messages) do
		assert(message == "Private user program exited with status 37.", "provider diagnostics must expose only numeric terminal status")
	end
end, debug.traceback)
-- Exact acquired owner/handle capabilities retire before owned files disappear.
for _, owner in ipairs(owners) do owner.invalidate() end
for _, handle in ipairs(handles) do handle.terminate(true) end
assert(await(function()
	for _, handle in ipairs(handles) do if not handle.isSettled() then return false end end
	return not uv.loop_alive()
end), "provider fixture cleanup retains physical process debt")
for _, owner in ipairs(owners) do assert(owner.invalidate()) end
for path in pairs(files) do if uv.fs_lstat(path) then assert(uv.fs_unlink(path)) end end
for _, directory in ipairs({ scripts, bin }) do if uv.fs_lstat(directory) then assert(uv.fs_rmdir(directory)) end end
assert(uv.fs_rmdir(root))
Logger.error = previous_error
if not ok then error(failure, 0) end
print("PASS native provider discovery, literal sh/python/executable argv, exit 37, refusal and cancellation retirement")
