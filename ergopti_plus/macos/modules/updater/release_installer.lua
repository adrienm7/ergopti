--- modules/updater/release_installer.lua

--- ==============================================================================
--- MODULE: Chosen Release Installer (macOS)
--- DESCRIPTION:
--- Installs a release the user chose in the Versions window, older or newer
--- than the running build. The launcher's Sparkle installer cannot do it:
--- Sparkle 2.9 refuses any bundle whose CFBundleVersion is lower than the
--- installed one (SUPlainInstaller.m, "updates that downgrade version of the
--- application are not allowed"), and every older release has a lower build
--- number. The update path itself is unchanged: new releases still arrive
--- through Sparkle.
---
--- FEATURES & RATIONALE:
--- 1. Every check, nothing skipped: the archive is the release's exact
---    repository asset, its SHA-256 must equal the digest GitHub's release API
---    publishes for it, the extracted app must carry the chosen version, and
---    its code signature must satisfy the designated requirement of the
---    running ErgoptiPlus (the same signing identity). Any failure stops the
---    install before anything is replaced.
--- 2. Staged off the hot path: download, digest, extraction and signature
---    checks run in one child shell through the ShellRunner adapter.
--- 3. Replaced only after the app quits: a detached child waits for the
---    launcher to exit, moves the installed app aside (kept as
---    ErgoptiPlus.app.previous), moves the verified one in and opens it; when
---    the move fails the previous app is put back and opened.
--- 4. No shell interpolation of release data: every value reaches the scripts
---    as an argument, never inside the script text.
--- ==============================================================================

local M = {}

local Logger      = require("infra.logger")
local Paths       = require("infra.paths")
local FileSystem  = require("adapters.file_system")
local JsonCodec   = require("adapters.json_codec")
local ShellRunner = require("adapters.shell_runner")
local Archives    = require("updater.release_assets")

local LOG = "updater.release_installer"

-- The executable inside the app bundle the launcher runs from.
local EXECUTABLE_SUFFIX = "/Contents/MacOS/ErgoptiPlus"
-- The app folder name inside the release archive.
local APP_NAME = "ErgoptiPlus.app"

-- Test seams.
M._run = function(...) return ShellRunner.run(...) end
M._spawn = function(...) return ShellRunner.spawn(...) end
M._getenv = os.getenv





-- ================================
-- ================================
-- ======= 1/ Child Scripts =======
-- ================================
-- ================================

-- Exit codes of the staging script: 10 is the download, 20 and up a check.
M.EXIT_DOWNLOAD = 10
M.EXIT_VERIFY_FIRST = 20

--- The native extraction owner, captured once through the source-layout resolver.
local stage_path = Paths.shared("../macos/adapters/release_stage.sh")
M.STAGE_SCRIPT = type(stage_path) == "string" and FileSystem.read(stage_path) or nil
assert(type(M.STAGE_SCRIPT) == "string" and M.STAGE_SCRIPT ~= "", "The native release staging script is unavailable")

--- Replaces the installed app once the launcher has quit.
--- Arguments: launcher pid, installed app, verified app, previous-app path.
M.SWAP_SCRIPT = table.concat({
	"set -u",
	'pid=$1; app=$2; staged=$3; previous=$4',
	"waited=0",
	'while /bin/kill -0 "$pid" 2>/dev/null; do',
	'	waited=$((waited + 1))',
	'	if [ "$waited" -gt 1200 ]; then echo "ErgoptiPlus did not quit: nothing was replaced."; exit 3; fi',
	"	/bin/sleep 0.1",
	"done",
	'/bin/rm -rf -- "$previous" || { echo "The previous backup app could not be removed."; /usr/bin/open -- "$app"; exit 4; }',
	'/bin/mv -- "$app" "$previous" || { echo "The installed app could not be moved aside."; /usr/bin/open -- "$app"; exit 5; }',
	'if /bin/mv -- "$staged" "$app"; then',
	'	echo "Installed."',
	'	/usr/bin/open -- "$app"',
	"	exit 0",
	"fi",
	'/bin/mv -- "$previous" "$app"',
	'echo "The verified app could not be moved in: the previous one is back."',
	'/usr/bin/open -- "$app"',
	"exit 6",
}, "\n")

-- Starts the swap script detached from this process, with its output in a log.
local DETACH_SCRIPT = 'nohup /bin/sh -c "$1" swap "$2" "$3" "$4" "$5" >>"$6" 2>&1 </dev/null &'





-- ====================================
-- ====================================
-- ======= 2/ The Release Asset =======
-- ====================================
-- ====================================

--- Resolves the ordered native archive bindings from the shared updater defaults.
--- @return table|nil identity Result of Archives.resolve().
local function identity()
	local path = Paths.shared("modules/updater/defaults.json")
	local raw = type(path) == "string" and FileSystem.read(path) or nil
	local decoded = type(raw) == "string" and JsonCodec.decode(raw) or nil
	local resolved, reason = Archives.resolve(decoded)
	if not resolved then Logger.error(LOG, "The shared release archive policy refused: %s.", reason) end
	return resolved
end

--- Selects the first declared present archive without bypassing a failed integrity check.
--- @param release table One decoded GitHub release.
--- @param ids table|nil Archives.resolve() result; the actual defaults when omitted.
--- @return table|nil asset { tag, version, url, digest, format }
function M.find_asset(release, ids)
	local asset, reason = Archives.select(release, ids or identity())
	if not asset and reason ~= "absent-archive" then Logger.error(LOG, "The release archive selection refused: %s.", reason) end
	return asset
end





-- ====================================
-- ====================================
-- ======= 3/ The Installed App =======
-- ====================================
-- ====================================

--- The app bundle the launcher runs from, or nil outside a packaged launch.
--- @return string|nil path
function M.app_bundle()
	local executable = M._getenv("ERGOPTI_LAUNCHER_EXECUTABLE")
	if type(executable) ~= "string" or executable:sub(1, 1) ~= "/" then return nil end
	if executable:sub(-#EXECUTABLE_SUFFIX) ~= EXECUTABLE_SUFFIX then return nil end
	local app = executable:sub(1, -#EXECUTABLE_SUFFIX - 1)
	if not app:match("%.app$") then return nil end
	return app
end

--- The launcher's process id, or nil outside a packaged launch.
--- @return string|nil pid
function M.launcher_pid()
	local pid = M._getenv("ERGOPTI_LAUNCHER_PID")
	if type(pid) ~= "string" or not pid:match("^[1-9]%d*$") then return nil end
	return pid
end





-- =================================
-- =================================
-- ======= 4/ Stage and Swap =======
-- =================================
-- =================================

--- Downloads and verifies one release into a fresh staging folder.
--- @param asset table M.find_asset() result.
--- @param done function fn(staged_app|nil, stage "download"|"verify", detail).
--- @return boolean dispatched
function M.stage(asset, done)
	local app = M.app_bundle()
	local tmp = M._getenv("TMPDIR")
	if not app or type(tmp) ~= "string" or tmp:sub(1, 1) ~= "/" then
		Logger.error(LOG, "Cannot stage %s: this is not a packaged ErgoptiPlus.", tostring(asset and asset.tag))
		return false
	end
	if type(asset) ~= "table" or not Archives.supports(asset.format) then
		Logger.error(LOG, "Cannot stage a release without its declared native archive format.")
		return false
	end
	local stage_dir = (tmp:gsub("/+$", "")) .. "/ergopti-release-install-" .. os.date("!%Y%m%d-%H%M%S")
	Logger.start(LOG, "Downloading and verifying %s into %s…", asset.tag, stage_dir)
	local handle = M._spawn("/bin/sh", { "-c", M.STAGE_SCRIPT, "stage", asset.url, asset.digest,
		stage_dir, asset.version, app, asset.format, APP_NAME }, function(exit_code, stdout, stderr)
		local staged = exit_code == 0 and type(stdout) == "string"
			and stdout:gsub("%s+$", ""):match("^READY (/.+)$") or nil
		if staged then
			Logger.success(LOG, "Release %s downloaded and verified.", asset.tag)
			done(staged, nil, nil)
			return
		end
		local code = tonumber(exit_code)
		local stage = (code and code >= M.EXIT_VERIFY_FIRST) and "verify" or "download"
		local detail = string.format("exit %s: %s", tostring(exit_code), (tostring(stderr or ""):gsub("%s+$", "")))
		Logger.error(LOG, "Release %s refused at the %s (%s).", asset.tag, stage, detail)
		done(nil, stage, detail)
	end)
	return type(handle) == "table" and handle.start() == true
end

--- Arms the replacement of the installed app by the verified one, to run once
--- the launcher quits.
--- @param staged_app string Verified app path from M.stage().
--- @return boolean armed
--- @return string|nil error
function M.arm_swap(staged_app)
	local app, pid = M.app_bundle(), M.launcher_pid()
	if not app or not pid then return false, "not a packaged launch" end
	if type(staged_app) ~= "string" or not staged_app:match("/" .. APP_NAME:gsub("%.", "%%.") .. "$") then
		return false, "no verified app"
	end
	local log = staged_app:gsub("/app/" .. APP_NAME:gsub("%.", "%%.") .. "$", "") .. "/swap.log"
	local started = M._run("/bin/sh", { "-c", DETACH_SCRIPT, "detach", M.SWAP_SCRIPT, pid, app, staged_app,
		app .. ".previous", log }, function(ok, _, stderr)
		if not ok then Logger.error(LOG, "The app replacement could not be armed: %s.", tostring(stderr)) end
	end)
	if started ~= true then return false, "the replacement could not start" end
	Logger.info(LOG, "App replacement armed: %s replaces %s once ErgoptiPlus quits (log: %s).",
		staged_app, app, log)
	return true
end

M._identity = identity

return M
