--- tests/hardware/phys_smoke_deadline.lua

--- ==============================================================================
--- MODULE: Owned Smoke Deadline in a Real Standalone Installation
--- DESCRIPTION:
--- Run by phys_live_guest.sh as the installing user, with the installed LuaJIT
--- and the INSTALLED tree's modules on LUA_PATH (never the checkout). It hands
--- the installed updater's async installer (Installer.install_owned) a real
--- tar.gz of a candidate whose wrapper `--help` never returns, against the real
--- installed root that install.sh created and the systemd unit runs from.
---
--- Checks, from inside an already running libuv loop with a 10 ms heartbeat:
---   1. one terminal callback, a failure naming the smoke and the restored tree;
---   2. it arrives after the install deadline and within a bounded margin;
---   3. the hung smoke's process group is gone when the callback runs;
---   4. the heartbeat never stalled while the smoke ran (the event loop owner);
---   5. the active tree is byte-for-byte the tree before the install, and no
---      staging folder is left beside it.
---
--- The archive arrives through a tar-backed factory, not the authenticated
--- download chain (archive_transfer), which needs a published release.
--- Usage: luajit phys_smoke_deadline.lua <install_root> <checkout_install_sh> <work_dir>
--- Exit 0 = every check held.
--- ==============================================================================

local uv = require("luv")
local Installer = require("modules.updater.installer")
local Budget = require("updater.engine.install_budget")
local Shell = require("core.process.adapters.shell_runner")

local INSTALL_ROOT, INSTALL_SH, WORK = arg[1], arg[2], arg[3]
for _, program in ipairs({ "tar" }) do
	assert(Shell.exec_checked("command -v " .. program), program .. " is required")
end
assert(INSTALL_ROOT and INSTALL_SH and WORK, "usage: phys_smoke_deadline.lua <install_root> <install_sh> <work_dir>")
-- Default: calibrated below from a timed run of the ownership owner, so the
-- deadline lands in the smoke on any CPU (an emulated one is 20x slower).
local TIMEOUT_MS = tonumber(os.getenv("PHYS_INSTALL_TIMEOUT_MS") or "")
-- The smoke child is re-admitted every 50 ms and then killed; after it, the
-- rollback verifies two trees synchronously. The margin adds those
-- verifications, timed on this CPU, to the kill and the group's exit.
local KILL_MARGIN_MS = 4000
-- A heartbeat gap above this means the installer held the loop.
local HEARTBEAT_LIMIT_MS = 500
local HUNG_MARKER = "ergopti-phys-hung-smoke"

local checks, failures = 0, 0
local function check(condition, text)
	checks = checks + 1
	if not condition then failures = failures + 1 end
	print((condition and "  ok   " or "  FAIL ") .. text)
	return condition
end

local function quote(text) return "'" .. tostring(text):gsub("'", "'\\''") .. "'" end
local function capture(command)
	local handle = assert(io.popen(command, "r"))
	local text = handle:read("*a")
	handle:close()
	return text
end
local function now() return uv.hrtime() / 1e6 end

--- Pids whose command line carries the hung smoke's marker, read from /proc.
local function hung_processes()
	local found = {}
	local request = uv.fs_scandir("/proc")
	while request do
		local name = uv.fs_scandir_next(request)
		if not name then break end
		if name:match("^%d+$") then
			local handle = io.open("/proc/" .. name .. "/cmdline", "rb")
			local line = handle and handle:read("*a") or ""
			if handle then handle:close() end
			if line:find(HUNG_MARKER, 1, true) then found[#found + 1] = name end
		end
	end
	return table.concat(found, " ")
end

--- Digest of every path's type, mode, size and content under a root.
local function tree_digest(root)
	return (capture("cd " .. quote(root) .. " && find . -printf '%y %m %s %p\\n' | LC_ALL=C sort"
		.. " && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum") or "")
end

local context = Installer.resolve(INSTALL_ROOT .. "/linux/modules/updater/manager.lua")
if not check(context.kind == "standalone", "the installed tree resolves as a standalone installation: "
	.. tostring(context.kind) .. " " .. tostring(context.reason or context.install_root)) then
	os.exit(1)
end
local Snapshot = require("diagnostics.engine.snapshot")
-- A source install carries no build stamp; a release archive does, and the
-- installer admits a candidate only when its stamp names the selected release.
local version = "0.0.0-phys.1"

-- The candidate: the installed tree itself, plus install.sh, with a launcher
-- whose --help never returns, so only the smoke can refuse it.
assert(Shell.run("rm -rf " .. quote(WORK) .. " && mkdir -p " .. quote(WORK .. "/payload")))
assert(Shell.run("cp -a " .. quote(INSTALL_ROOT .. "/linux") .. " " .. quote(INSTALL_ROOT .. "/_shared") .. " "
	.. quote(INSTALL_ROOT .. "/bin") .. " " .. quote(WORK .. "/payload/") .. " && cp " .. quote(INSTALL_SH) .. " "
	.. quote(WORK .. "/payload/install.sh")), "candidate copy failed")
local stamp = assert(io.open(WORK .. "/payload/_shared/" .. Snapshot.BUILD_STAMP_FILE, "wb"))
stamp:write(Snapshot.BUILD_STAMP_COMMIT_KEY, "=", string.rep("0", 40), "\n", Snapshot.BUILD_STAMP_VERSION_KEY, "=", version, "\n")
stamp:close()
local launch = WORK .. "/payload/linux/install/launch.sh"
local original = assert(io.open(launch, "rb")):read("*a")
local shebang, rest = original:match("^(#![^\n]*\n)(.*)$")
local patched = assert(io.open(launch, "wb"))
-- The wrapper passes --service first: look at every argument.
-- It stamps when it starts, so the heartbeat is judged over the smoke itself.
local started_file = WORK .. "/smoke-started"
patched:write(shebang, "for a in \"$@\"; do [ \"$a\" = --help ] && date +%s%N > ", quote(started_file),
	" && exec -a ", HUNG_MARKER, " sleep 3600; done\n", rest)
patched:close()
if not TIMEOUT_MS then
	-- The owner writes its receipt into the root it hashes: time it on a copy.
	assert(Shell.run("cp -a " .. quote(WORK .. "/payload") .. " " .. quote(WORK .. "/calibration")))
	local before_owner = now()
	assert(Shell.run("bash " .. quote(INSTALL_ROOT .. "/linux/install/ownership.sh") .. " "
		.. quote(WORK .. "/calibration/linux") .. " " .. quote(WORK .. "/calibration/_shared") .. " "
		.. quote(WORK .. "/calibration") .. " >/dev/null"), "the ownership owner calibration failed")
	local owner_ms = now() - before_owner
	Shell.run("rm -rf " .. quote(WORK .. "/calibration"))
	-- Extraction, three receipt verifications and the moves fit in the rest.
	TIMEOUT_MS = math.floor(owner_ms * 3 + 30000)
	print(string.format("  ..   ownership owner took %.0f ms; install deadline %d ms", owner_ms, TIMEOUT_MS))
end
local archive = WORK .. "/candidate.tar.gz"
assert(Shell.run("tar -C " .. quote(WORK .. "/payload") .. " -czf " .. quote(archive)
	.. " linux _shared bin install.sh"), "candidate archive failed")

local Ownership = require("modules.updater.ownership_receipt")
local before_verify = now()
check(Ownership.verify(INSTALL_ROOT, INSTALL_ROOT) ~= nil, "the installed tree verifies against its receipt")
local verify_ms = now() - before_verify
local CALLBACK_MARGIN_MS = math.floor(KILL_MARGIN_MS + 3 * verify_ms)
print(string.format("  ..   one receipt verification took %.0f ms; callback margin %d ms", verify_ms, CALLBACK_MARGIN_MS))
local before = tree_digest(INSTALL_ROOT)
check(#before > 0, "the active tree digest was captured")

local token = assert(Budget.capture({ release_install = { install_timeout_ms = TIMEOUT_MS } }, now()))
local reservation = {}
local factory = {}
local function settled_child(done, result)
	local child = {}
	function child:is_settled() return true end
	function child:request_cancel() return true end
	function child:on_settled(fn) fn(); return true end
	done(result)
	return child
end
function factory.install_current(r) return r == reservation and Budget.admit(token, now()) end
function factory.install_feed(r, kind, dir, done, current)
	assert(r == reservation and current())
	if kind == "names" then return settled_child(done, { ok = true, stdout = capture("tar -tzf " .. quote(archive)) }) end
	if kind == "verbose" then return settled_child(done, { ok = true, stdout = capture("tar -tvzf " .. quote(archive)) }) end
	return settled_child(done, { ok = Shell.run("tar -xzf " .. quote(archive) .. " -C " .. quote(dir)) })
end
function factory.finish_install(r, _, done) assert(r == reservation); return settled_child(done, { ok = true }) end

local heartbeat, starter = assert(uv.new_timer()), assert(uv.new_timer())
local tick_times = {}
-- Wall clock and hrtime read together, to place the launcher's stamp.
local wall_ms, hr_ms = nil, nil
local started_at, callback_at, callbacks, installed, detail, hung_after = nil, nil, 0, nil, nil, nil
local function retire()
	for _, handle in ipairs({ heartbeat, starter }) do
		if not handle:is_closing() then handle:stop(); handle:close() end
	end
end
uv.update_time()
heartbeat:start(10, 10, function()
	if not callback_at then tick_times[#tick_times + 1] = now() end
end)
starter:start(50, 0, function()
	local seconds, micros = uv.gettimeofday()
	wall_ms, hr_ms = seconds * 1000 + micros / 1000, now()
	started_at = now()
	local operation = Installer.install_owned({ factory = factory, reservation = reservation, context = context,
		expected_version = version }, function(ok, why)
		callbacks = callbacks + 1
		callback_at, installed, detail = now(), ok, why
		hung_after = hung_processes()
		local closer = assert(uv.new_timer())
		closer:start(100, 0, function() closer:close(); retire() end)
	end)
	if not operation then retire() end
end)
uv.run()

local elapsed = callback_at and (callback_at - started_at) or -1
local stamp_text = capture("cat " .. quote(started_file) .. " 2>/dev/null")
local smoke_at = tonumber(stamp_text:match("%d+") or "") and (tonumber(stamp_text:match("%d+")) / 1e6 - wall_ms + hr_ms) or nil
-- The smoke window ends at the deadline, where the admission kills it; the
-- synchronous rollback verification after it is reported separately.
local deadline_at = started_at and started_at + TIMEOUT_MS
local max_gap, ticks, previous, rollback_gap = 0, 0, smoke_at, 0
for _, t in ipairs(tick_times) do
	if smoke_at and t >= smoke_at then
		if t <= deadline_at then
			max_gap, ticks = math.max(max_gap, t - previous), ticks + 1
		else
			rollback_gap = math.max(rollback_gap, t - previous)
		end
		previous = t
	end
end
if smoke_at and callback_at then rollback_gap = math.max(rollback_gap, callback_at - previous) end
check(callbacks == 1, "exactly one terminal callback: " .. callbacks)
check(installed == false and tostring(detail):find("smoke failed; previous installation restored", 1, true) ~= nil,
	"the hung smoke failed the install and restored the previous tree: " .. tostring(detail))
check(elapsed >= TIMEOUT_MS and elapsed <= TIMEOUT_MS + CALLBACK_MARGIN_MS, string.format(
	"the callback came after the %d ms deadline, within its margin: %.0f ms", TIMEOUT_MS, elapsed))
check(hung_after == "", "the hung smoke's process group was gone at the callback")
check(smoke_at ~= nil, "the candidate's hung --help smoke started")
check(smoke_at ~= nil and ticks > 0 and max_gap < HEARTBEAT_LIMIT_MS, string.format(
	"the event loop kept ticking during the smoke: max gap %.1f ms over %d ticks, smoke %.0f ms", max_gap, ticks,
	smoke_at and deadline_at - smoke_at or -1))
check(tree_digest(INSTALL_ROOT) == before, "the active tree is byte-for-byte the tree before the install")
local leftovers = capture("ls -A " .. quote(context.parent) .. " | grep -F .ergopti-update. || true")
check(leftovers == "", "no staging folder is left beside the installation")
print(string.format("RECEIPT smoke_deadline timeout_ms=%d callback_ms=%.0f smoke_max_gap_ms=%.1f ticks=%d"
	.. " rollback_max_gap_ms=%.1f verify_ms=%.0f detail=%q",
	TIMEOUT_MS, elapsed, max_gap, ticks, rollback_gap, verify_ms, tostring(detail)))
Shell.run("rm -rf " .. quote(WORK))
print(string.format("%d checks, %d failures", checks, failures))
os.exit(failures == 0 and 0 or 1)
