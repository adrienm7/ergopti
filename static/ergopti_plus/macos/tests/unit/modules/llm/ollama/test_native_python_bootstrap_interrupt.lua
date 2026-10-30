--- tests/unit/modules/llm/ollama/test_native_python_bootstrap_interrupt.lua
--- The owned native Python bootstrap releases its temporary workspace on a
--- guardian SIGTERM (bootstrap-sigterm-workspace).
---
--- The 28 October macOS audit proved that a process-group SIGTERM during the uv
--- wheel or the Python archive download left the allocated
--- ergopti-native-runtime-python.* folder and its partial bytes behind: every
--- refusal path removed it, but a signal ended bash between two statements, and
--- nothing owned the folder at that moment. These cases run the real helper in
--- real bash, with only the download port replaced, and send the real signal to
--- the real process group, in both allocation stages.

local helpers = require("tests.helpers")

local function quote(value) return "'" .. value:gsub("'", "'\\''") .. "'" end

local function command(text)
	local pipe = assert(io.popen("( " .. text .. " ) 2>&1; printf '\\n__STATUS__:%s' \"$?\"", "r"))
	local bytes = assert(pipe:read("*a"))
	assert(pipe:close())
	local status = assert(tonumber(bytes:match("__STATUS__:(%d+)%s*$")))
	return bytes:gsub("\n?__STATUS__:%d+%s*$", ""), status
end

local function write(path, bytes)
	local file = assert(io.open(path, "wb"))
	assert(file:write(bytes))
	assert(file:close())
end

local function read(path)
	local file = io.open(path, "rb")
	if not file then return nil end
	local bytes = file:read("*a")
	file:close()
	return bytes
end

-- The download port writes partial bytes, then blocks in the named stage until
-- the signal arrives; a finished uv download is a real wheel so the helper
-- reaches its second allocation stage. "refuse" fails the first download.
local CALLER = [[
set -eu
SCRIPT_DIR="$FX/src"
source "$SCRIPT_DIR/native_python_bootstrap.sh"
managed_bootstrap_download() {
	case "$2" in *uv.whl) stage=uv ;; *) stage=python ;; esac
	printf 'partial bytes' > "$2"
	[ "$MODE" != refuse ] || return 1
	if [ "$stage" = uv ] && [ "$MODE" = python ]; then
		mkdir -p "$FX/wheel/uv-$UV_RELEASE_VERSION.data/scripts"
		printf '#!/bin/sh\n' > "$FX/wheel/uv-$UV_RELEASE_VERSION.data/scripts/uv"
		rm -f "$2"
		(cd "$FX/wheel" && zip -qr "$2" .)
		return 0
	fi
	: > "$FX/blocked-$stage"
	sleep 30
}
if [ -n "${CALLER_TERM:-}" ]; then trap 'printf caller > "$FX/caller-term"; exit 143' TERM; fi
trap 'printf "%s" "$BOOTSTRAP_STAGE" > "$FX/exit-stage"' EXIT
native_bootstrap_python "$HOME/Library/Application Support/Ergopti/native-bootstrap"
]]

local DRIVER = [[
set -u
setsid /bin/bash "$FX/run.sh" 2>"$FX/stderr" &
pid=$!
if [ "$MODE" != refuse ]; then
	for _ in $(seq 200); do [ -e "$FX/blocked-$MODE" ] && break; sleep 0.05; done
	[ -e "$FX/blocked-$MODE" ] || { kill -KILL -- "-$pid"; echo "never-blocked"; exit 0; }
	kill -TERM -- "-$pid"
fi
wait "$pid"; printf 'status=%s\n' "$?"
for _ in $(seq 100); do pgrep -g "$pid" >/dev/null || break; sleep 0.05; done
pgrep -g "$pid" >/dev/null && echo "group=alive" || echo "group=gone"
printf 'left=%s\n' "$(ls -A "$FX/tmp")"
]]

--- Runs the real helper in a fresh fixture and returns its observations.
--- @param mode string "uv", "python" or "refuse".
--- @param extra string|nil Extra environment assignments for the caller.
--- @return table The parsed fields plus the fixture root.
local function run(mode, extra)
	local root = helpers.temp_dir() .. "/bootstrap-interrupt-" .. mode
	local llm = helpers.driver_root() .. "modules/llm/"
	local _, prepared = command("rm -rf " .. quote(root) .. " && mkdir -p " .. quote(root .. "/home")
		.. " " .. quote(root .. "/tmp") .. " " .. quote(root .. "/src")
		.. " && cp " .. quote(llm .. "native_python_bootstrap.sh") .. " " .. quote(llm .. "uv-release.sh")
		.. " " .. quote(llm .. "managed-python-release.sh") .. " " .. quote(root .. "/src/"))
	helpers.assert_eq(prepared, 0, "fixture copies the real bootstrap sources")
	write(root .. "/run.sh", CALLER)
	write(root .. "/driver.sh", DRIVER)
	local output = command("env -u BASH_ENV -u ENV FX=" .. quote(root) .. " MODE=" .. mode
		.. " HOME=" .. quote(root .. "/home") .. " TMPDIR=" .. quote(root .. "/tmp")
		.. " ERGOPTI_NATIVE_ARCH=arm64 " .. (extra or "") .. " /bin/bash " .. quote(root .. "/driver.sh"))
	local result = { root = root, output = output }
	for key, value in output:gmatch("(%w+)=([^\n]*)") do result[key] = value end
	result.stderr = read(root .. "/stderr") or ""
	result.exit_stage = read(root .. "/exit-stage")
	return result
end

local function cleanup(result)
	local _, removed = command("rm -rf " .. quote(result.root))
	helpers.assert_eq(removed, 0)
end

helpers.describe("native Python bootstrap workspace on interruption (bootstrap-sigterm-workspace)", function()
	for _, mode in ipairs({ "uv", "python" }) do
		helpers.it("a group SIGTERM during the " .. mode .. " download removes the workspace and keeps 143", function()
			local result = run(mode)
			helpers.assert_true(result.output:find("never-blocked", 1, true) == nil,
				"the helper reached the " .. mode .. " download: " .. result.output .. result.stderr)
			helpers.assert_eq(result.status, "143", "the signal status stays the caller's verdict")
			helpers.assert_eq(result.left, "", "no temporary workspace survives the signal")
			helpers.assert_eq(result.group, "gone", "no process of the bootstrap group survives")
			helpers.assert_eq(result.exit_stage, mode .. "_download",
				"the caller's EXIT report still names the interrupted stage")
			helpers.assert_true(result.stderr:find("interrupted by SIGTERM", 1, true) ~= nil,
				"the interruption is named on stderr: " .. result.stderr)
			cleanup(result)
		end)
	end

	helpers.it("a download refusal still returns 1 and removes the workspace", function()
		local result = run("refuse")
		helpers.assert_eq(result.status, "1", "the primary refusal status is preserved")
		helpers.assert_eq(result.left, "", "the refusal control removes its workspace")
		cleanup(result)
	end)

	helpers.it("the caller's own TERM handler is restored and still runs", function()
		local result = run("uv", "CALLER_TERM=1")
		helpers.assert_eq(read(result.root .. "/caller-term"), "caller", "the displaced handler ran after the release")
		helpers.assert_eq(result.status, "143")
		helpers.assert_eq(result.left, "", "the workspace was released before the caller's handler")
		cleanup(result)
	end)

	helpers.it("a workspace replaced by a symlink is left in place, not followed", function()
		local root = helpers.temp_dir() .. "/bootstrap-interrupt-foreign"
		local llm = helpers.driver_root() .. "modules/llm/"
		local script = "set -eu; source " .. quote(llm .. "native_python_bootstrap.sh")
			.. "; mkdir -p " .. quote(root .. "/foreign") .. "; printf keep > " .. quote(root .. "/foreign/sentinel")
			.. "; ln -s " .. quote(root .. "/foreign") .. " " .. quote(root .. "/link")
			.. "; NATIVE_BOOTSTRAP_WORK=" .. quote(root .. "/link") .. "; native_bootstrap_release_work"
		local output, status = command("rm -rf " .. quote(root) .. " && mkdir -p " .. quote(root)
			.. " && /bin/bash -c " .. quote(script))
		helpers.assert_eq(status, 0, output)
		helpers.assert_eq(read(root .. "/foreign/sentinel"), "keep", "the foreign target keeps its bytes")
		helpers.assert_true(output:find("no longer owned", 1, true) ~= nil, "the refusal to remove is named")
		local _, removed = command("rm -rf " .. quote(root))
		helpers.assert_eq(removed, 0)
	end)
end)
