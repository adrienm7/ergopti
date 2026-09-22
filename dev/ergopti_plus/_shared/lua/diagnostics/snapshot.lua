--- _shared/lua/diagnostics/snapshot.lua

--- ==============================================================================
--- MODULE: Diagnostic Snapshot (shared)
--- DESCRIPTION:
--- Formats the one-line environment summary every driver logs once its boot has
--- completed. The field list and the rendering rules are the cross-driver
--- contract in _shared/modules/logger/diagnostic_snapshot.json; this module is
--- the Lua implementation used by both the macOS and the Linux drivers, and
--- windows/infra/diagnostic_snapshot.ahk is the AutoHotkey one.
---
--- FEATURES & RATIONALE:
--- 1. One line, identical field names everywhere: a user log from any of the
---    three drivers can be triaged with the same grep, and a missing field is a
---    visible "unknown" instead of an absent column.
--- 2. Pure Lua: every OS read is injected by the driver, so the formatter, the
---    build-stamp read and the git HEAD resolution run unchanged under
---    Hammerspoon, LuaJIT and the tests.
--- 3. Privacy: the snapshot carries environment facts only. Paths under the
---    user's home are rendered relative to "~" so the account name stays out of
---    shared logs.
--- ==============================================================================

local M = {}

local reload_gate = require("reload_gate")





-- =====================================
-- =====================================
-- ======= 1/ Contract constants =======
-- =====================================
-- =====================================

-- Log tag of the snapshot line. Pinned to diagnostic_snapshot.json by the
-- cross-driver parity test.
M.MODULE = "Diagnostics"

-- Token rendered for a missing or empty value, so a field never disappears.
M.UNKNOWN = "unknown"

-- Ordered field names. Pinned to diagnostic_snapshot.json by the parity test;
-- adding a field means adding it there and to every driver collector.
M.FIELDS = {
	"driver",
	"version",
	"commit",
	"os",
	"os_version",
	"arch",
	"runtime",
	"elevated",
	"locale",
	"keyboard_layout",
	"monitors",
	"dpi",
	"display",
	"config_dir",
	"log_level",
	"features_enabled",
	"boot_ms",
}

-- Number of hexadecimal digits kept from a commit id, matching `git log --oneline`.
local SHORT_SHA_LENGTH = 9




-- ==============================
-- ==============================
-- ======= 2/ Formatting ========
-- ==============================
-- ==============================

--- Renders one value under the shared quoting rules.
--- @param value any Raw value; nil and "" become the unknown token.
--- @return string
function M.render_value(value)
	if value == nil then return M.UNKNOWN end
	local text = tostring(value)
	text = text:gsub("[\r\n\t]", " "):gsub('"', "'")
	if text == "" then return M.UNKNOWN end
	if text:find(" ", 1, true) then return '"' .. text .. '"' end
	return text
end

--- Builds the snapshot message body (without timestamp, level or tag).
--- @param values table Map of field name to raw value.
--- @return string
function M.format(values)
	local parts = {}
	local source = type(values) == "table" and values or {}
	for _, name in ipairs(M.FIELDS) do
		parts[#parts + 1] = name .. "=" .. M.render_value(source[name])
	end
	return "Diagnostic snapshot (" .. table.concat(parts, " ") .. ")."
end

--- Formats an enabled/total feature pair as "N/M".
--- @param enabled number|nil
--- @param total number|nil
--- @return string|nil nil when either count is unknown.
function M.features_ratio(enabled, total)
	if type(enabled) ~= "number" or type(total) ~= "number" then return nil end
	return string.format("%d/%d", enabled, total)
end

--- Renders a path relative to the user's home as "~/…" so the account name is
--- not written into a log a user may share.
--- @param path string|nil
--- @param home string|nil
--- @return string|nil
function M.redact_home(path, home)
	if type(path) ~= "string" or path == "" then return nil end
	if type(home) ~= "string" or home == "" then return path end
	local trimmed = home:gsub("[/\\]+$", "")
	if trimmed ~= "" and path:sub(1, #trimmed) == trimmed then
		local rest = path:sub(#trimmed + 1)
		if rest == "" or rest:match("^[/\\]") then return "~" .. rest end
	end
	return path
end




-- =================================
-- =================================
-- ======= 3/ Commit lookup ========
-- =================================
-- =================================

--- Reads a file through the injected reader and trims it.
--- @param fs table
--- @param path string
--- @return string|nil
local function read_trimmed(fs, path)
	local content = fs.read(path)
	if type(content) ~= "string" then return nil end
	content = content:match("^%s*(.-)%s*$")
	if content == "" then return nil end
	return content
end

--- Looks a ref up in packed-refs, the store git moves loose refs into.
--- @param fs table
--- @param common_dir string
--- @param ref string
--- @return string|nil
local function packed_ref(fs, common_dir, ref)
	local packed = fs.read(common_dir .. "/packed-refs")
	if type(packed) ~= "string" then return nil end
	for line in packed:gmatch("[^\r\n]+") do
		local sha, name = line:match("^(%x+)%s+(%S+)$")
		if sha and name == ref then return sha end
	end
	return nil
end

--- Resolves the commit checked out in the repository that contains `start_dir`.
--- A source checkout has no build stamp, and "which commit was running" is the
--- first question of every bug report, so the snapshot reads HEAD directly
--- instead of shelling out to git on the boot path.
--- @param fs table { exists = fun(path):boolean, read = fun(path):string|nil }
--- @param start_dir string
--- @return string|nil Abbreviated commit id, or nil outside a repository.
function M.git_commit(fs, start_dir)
	if type(fs) ~= "table" or type(fs.read) ~= "function" then return nil end
	local git_dir = reload_gate.git_dir(fs, start_dir)
	if not git_dir then return nil end
	local head = read_trimmed(fs, git_dir .. "/HEAD")
	if not head then return nil end
	if head:match("^%x+$") and #head >= SHORT_SHA_LENGTH then
		return head:sub(1, SHORT_SHA_LENGTH)
	end
	local ref = head:match("^ref:%s*(%S+)$")
	if not ref then return nil end
	-- A linked worktree keeps HEAD in its own directory and every ref in the
	-- shared one that its `commondir` file points to.
	local common_dir = git_dir
	local pointer = read_trimmed(fs, git_dir .. "/commondir")
	if pointer then
		common_dir = pointer:match("^/") and pointer or (git_dir .. "/" .. pointer)
	end
	local sha = read_trimmed(fs, git_dir .. "/" .. ref)
		or read_trimmed(fs, common_dir .. "/" .. ref)
		or packed_ref(fs, common_dir, ref)
	if not sha or not sha:match("^%x+$") then return nil end
	return sha:sub(1, SHORT_SHA_LENGTH)
end




-- =================================
-- =================================
-- ======= 4/ Build stamp ==========
-- =================================
-- =================================

-- File a package build writes at the root of the shared tree it ships. A
-- packaged macOS app or Linux package carries no .git, so without it every
-- report from an installed build read "unknown". tools/build/write_build_stamp.sh
-- is the only writer; the JS guard tools/test/test-package-builds-stamp-commit.cjs
-- pins its file name and key to these constants.
M.BUILD_STAMP_FILE = "build_stamp.txt"
M.BUILD_STAMP_COMMIT_KEY = "commit"

-- Where a resolved commit came from, reported next to it so a reader can tell
-- a release build from a source run of the same commit.
M.COMMIT_SOURCE_BUILD = "build"
M.COMMIT_SOURCE_GIT = "git"
M.COMMIT_SOURCE_UNKNOWN = "unknown"

-- Length of a full commit id, the only form the writer stamps.
local FULL_SHA_LENGTH = 40

--- Parses the content of a build stamp.
--- @param text string Raw file content, one `key=value` per line.
--- @return string|nil Abbreviated commit id.
--- @return string|nil Why the stamp is invalid, when it is.
function M.parse_build_stamp(text)
	if type(text) ~= "string" then return nil, "the build stamp is not text" end
	for line in text:gmatch("[^\r\n]+") do
		local key, value = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
		if key == M.BUILD_STAMP_COMMIT_KEY then
			if #value ~= FULL_SHA_LENGTH or not value:match("^%x+$") then
				return nil, string.format("the build stamp commit '%s' is not a full commit id", value)
			end
			return value:lower():sub(1, SHORT_SHA_LENGTH)
		end
	end
	return nil, "the build stamp has no " .. M.BUILD_STAMP_COMMIT_KEY .. " entry"
end

--- Reads the commit a package build stamped into the shared tree.
--- @param fs table { read = fun(path):string|nil }
--- @param shared_root string|nil Absolute path of the shared tree.
--- @return string|nil Abbreviated commit id, nil when there is no valid stamp.
--- @return string|nil Why a present stamp was rejected; nil when it is absent.
function M.build_commit(fs, shared_root)
	if type(fs) ~= "table" or type(fs.read) ~= "function" then return nil, "no file reader" end
	if type(shared_root) ~= "string" or shared_root == "" then return nil end
	local text = fs.read(shared_root:gsub("[/\\]+$", "") .. "/" .. M.BUILD_STAMP_FILE)
	if text == nil then return nil end
	return M.parse_build_stamp(text)
end

--- Resolves the commit the running driver was built from. A package build is
--- identified by its stamp, a source run by its git checkout; anything else is
--- reported as unknown with the reason, never guessed.
--- @param fs table { exists = fun(path):boolean, read = fun(path):string|nil }
--- @param shared_root string|nil Absolute path of the shared tree.
--- @param source_dir string|nil Directory the git lookup starts from.
--- @return string Abbreviated commit id, or M.UNKNOWN.
--- @return string One of the M.COMMIT_SOURCE_* values.
--- @return string|nil Why the commit is unknown, when it is.
function M.resolve_commit(fs, shared_root, source_dir)
	local stamped, stamp_error = M.build_commit(fs, shared_root)
	if stamped then return stamped, M.COMMIT_SOURCE_BUILD end
	-- A stamp that exists but cannot be read is a broken package, not a source
	-- run: falling through to git would hide the defect behind a plausible id.
	if stamp_error then return M.UNKNOWN, M.COMMIT_SOURCE_UNKNOWN, stamp_error end
	local checked_out = M.git_commit(fs, source_dir)
	if checked_out then return checked_out, M.COMMIT_SOURCE_GIT end
	return M.UNKNOWN, M.COMMIT_SOURCE_UNKNOWN, string.format(
		"no %s in the shared tree '%s' and '%s' is not inside a git checkout",
		M.BUILD_STAMP_FILE, tostring(shared_root), tostring(source_dir))
end

return M
