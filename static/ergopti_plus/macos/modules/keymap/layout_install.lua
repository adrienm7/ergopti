--- modules/keymap/layout_install.lua

--- ==============================================================================
--- MODULE: Keyboard Layout Install
--- DESCRIPTION:
--- Bundle discovery and on-disk install/upgrade of the Ergopti keyboard-layout
--- bundles (user + system scope). Extracted from ui/menu/menu_keyboard_layout.lua
--- (audit F4) so the 1647-line menu module shrinks to its submenu builder and the
--- install/TIS glue lives in a focused, independently testable module.
---
--- FEATURES & RATIONALE:
--- 1. Single source of truth for bundle discovery: the highest version found in
---    the bundles directory wins, read through native directory enumeration.
--- 2. Idempotent install detection: highest_installed() reports the live on-disk
---    version so the menu can disable already-installed entries.
--- 3. Resilient, SIP-aware filesystem probes: shells out to /bin/test and osascript
---    for privileged copies; every failure path is logged, never silent.
--- 4. A bundle says what it installs: the layouts and input-source ids of its
---    Info.plist (bundle_variants), and the keyboard names every installed bundle
---    provides (bundle_keylayout_names), so no driver table repeats them.
---
--- The input-source layer (input_sources.lua) and the menu builder consume this
--- module's public functions.
--- ==============================================================================

local hs            = hs
local Logger        = require("infra.logger")
local NativePath = require("core.fs.engine.native_path")
local text_utils = require("infra.text_utils")
local i18n          = require("core.i18n.engine.i18n")
local notifications = require("infra.notifications")
local FileSystem    = require("core.fs.adapters.file_system")
local FsDir         = require("core.fs.engine.dir")
local LOG           = "menu.keyboard_layout"

-- Target install paths on macOS
local USER_LAYOUTS_DIR   = os.getenv("HOME") and (os.getenv("HOME") .. "/Library/Keyboard Layouts/") or "~/Library/Keyboard Layouts/"
local SYSTEM_LAYOUTS_DIR = "/Library/Keyboard Layouts/"

-- User and system installs rewrite both layout directories. One module-owned
-- admission bit keeps a reentrant menu callback from interleaving those writes.
local _install_in_flight = false





-- =====================================
-- =====================================
-- ======= 1/ Bundle Discovery =========
-- =====================================
-- =====================================

--- Parses a bundle directory name like "Ergopti_v2.2.1.bundle" into a
--- comparable version table {2, 2, 1}.
--- @param name string Bundle directory basename.
--- @return table|nil Numeric version components, or nil if unparseable.
local function parse_version(name)
	local v = name:match("_v([%d%.]+)%.bundle$")
	if not v then return nil end
	local parts = {}
	for n in v:gmatch("(%d+)") do parts[#parts + 1] = tonumber(n) end
	if #parts == 0 then return nil end
	return parts
end

--- Compares two version tables lexicographically.
--- @param a table
--- @param b table
--- @return boolean true if a > b.
local function version_gt(a, b)
	for i = 1, math.max(#a, #b) do
		local ai, bi = a[i] or 0, b[i] or 0
		if ai ~= bi then return ai > bi end
	end
	return false
end

--- Lists every "Ergopti_v*.bundle" inside the given directory.
--- Native directory listing with a checked shell fallback.
--- @param dir string Absolute path of the bundles directory.
--- @return table List of basenames (no trailing slash).
--- @return boolean listed Whether the listing completed successfully.
local function list_bundles(dir)
	local out = {}
	if type(FileSystem.classify_no_follow) == "function" then
		local _, status = FileSystem.classify_no_follow(NativePath.without_trailing_separators(dir))
		if status == "absent" then return out, true end
	end
	local names, listed = FsDir.try_entries(dir)
	if listed then
		for _, name in ipairs(names) do
			if name:match("^Ergopti_v[%d%.]+%.bundle$") then out[#out + 1] = name end
		end
		return out, true
	end
	-- A missing scope is a proven empty listing. Other native failures are not:
	-- retry through ls and admit output only after a successful exit.
	if type(FileSystem.classify_no_follow) == "function" then
		local _, status = FileSystem.classify_no_follow(NativePath.without_trailing_separators(dir))
		if status == "absent" then return out, true end
	end
	local cmd
	if package.config:sub(1, 1) == "\\" then
		cmd = string.format('cmd /c dir /b /a:d "%s"', dir:gsub("/", "\\"))
	else
		cmd = string.format("ls -1 %s 2>/dev/null", text_utils.shell_quote(dir))
	end
	local p = io.popen(cmd)
	if not p then return out, false end
	for raw_line in p:lines() do
		local line = raw_line:gsub("[\r\n]+$", "")
		if line:match("^Ergopti_v[%d%.]+%.bundle$") then out[#out + 1] = line end
	end
	local completed = p:close()
	if completed ~= true then return {}, false end
	return out, true
end

--- Picks the highest-version bundle inside dir.
--- @param dir string Absolute path of the bundles directory.
--- @return string|nil Basename of the latest bundle, or nil if none found.
--- @return boolean listed Whether discovery completed or the directory is absent.
local function pick_latest_bundle(dir)
	if type(dir) ~= "string" or dir == "" then return nil, false end
	local names, listed = list_bundles(dir)
	if not listed then return nil, false end
	local best, best_ver = nil, nil
	for _, name in ipairs(names) do
		local ver = parse_version(name)
		if ver and (not best_ver or version_gt(ver, best_ver)) then
			best, best_ver = name, ver
		end
	end
	return best, true
end




-- =====================================
-- =====================================
-- ======= 2/ Install Helpers ==========
-- =====================================
-- =====================================

--- Returns true if the file/dir at the given path exists (best-effort).
--- io.open(path, "r") fails on directories on macOS, and os.rename() on a
--- system-protected location like "/Library/Keyboard Layouts" can hit SIP
--- restrictions even for stat-style probes — so we shell out to /bin/test
--- which handles files, directories, and bundles uniformly.
--- @param path string Absolute path.
--- @return boolean
local function path_exists(path)
	if type(path) ~= "string" or path == "" then return false end
	if hs and hs.fs and type(hs.fs.attributes) == "function" then
		local attrs = hs.fs.attributes(path)
		if attrs then return true end
	end
	-- Shell fallback — handles SIP-protected paths that hs.fs.attributes can't stat.
	-- /bin/test -e accepts any filesystem object (file, dir, bundle symlink).
	-- shell_quote, not %q. Lua's %q escapes for a LUA literal: it leaves $,
	-- backticks and ! untouched, every one of which /bin/sh expands. This path is
	-- user-influenced (the config directory is a setting), so %q here is both
	-- wrong for ordinary paths and a shell-injection hazard.
	local cmd = string.format("/bin/test -e %s && echo OK", text_utils.shell_quote(path))
	local out = hs.execute and hs.execute(cmd) or nil
	if type(out) == "string" and out:find("OK") then return true end
	-- Pure-Lua fallback for unit-test runs where hs is unavailable.
	-- os.rename is intentionally omitted: on SIP-protected paths it returns true
	-- even when the file does not exist, which would make find_installed_bundles
	-- report a phantom installed bundle and show "Mettre à jour" instead of "Installer".
	local f = io.open(path, "r")
	if f then f:close(); return true end
	return false
end

--- Lists every Ergopti_v*.bundle currently installed in `dir`.
--- Returns the parsed version components for each so callers can compare to
--- the latest available version without having to re-parse strings.
---
--- Bundle entries are only counted when their internal Contents/Info.plist
--- exists — a stray empty .bundle directory left behind by a failed install
--- (or by macOS while moving files between locations) would otherwise be
--- picked up here, with the upstream menu builder then offering an
--- "in-place upgrade" against a non-existent install. The structural check
--- guarantees `installed` only points at bundles that the OS would itself
--- treat as a real keyboard layout.
--- @param dir string Absolute path of the Keyboard Layouts directory.
--- @return table Array of { name = string, version = table } entries.
--- @return boolean listed Whether discovery completed or the directory is absent.
local function find_installed_bundles(dir)
	local out = {}
	if type(dir) ~= "string" or dir == "" then return out, false end
	local names, listed = list_bundles(dir)
	if not listed then return out, false end
	local dir_with_slash = NativePath.with_trailing_separator(dir)
	for _, name in ipairs(names) do
		local v = parse_version(name)
		local info_plist = dir_with_slash .. name .. "/Contents/Info.plist"
		local plist_ok = v and path_exists(info_plist)
		Logger.debug(LOG, "Bundle probe — dir=%s name=%s plist_exists=%s.", dir, name, tostring(plist_ok))
		if plist_ok then out[#out + 1] = { name = name, version = v } end
	end
	return out, true
end

--- Returns the highest installed Ergopti version in the given directory.
--- @param dir string Absolute path of the Keyboard Layouts directory.
--- @return table|nil { name = string, version = table } or nil if none.
--- @return boolean listed Whether discovery completed or the directory is absent.
local function highest_installed(dir)
	if type(dir) ~= "string" or dir == "" then return nil, false end
	-- Recheck both names and plists: directory timestamps can stay unchanged
	-- across a same-second replacement, and plist changes are nested.
	local entries, listed = find_installed_bundles(dir)
	if not listed then return nil, false end
	local best
	for _, entry in ipairs(entries) do
		if not best or version_gt(entry.version, best.version) then
			best = entry
		end
	end
	return best, true
end

--- Renders a version components table back to a human-readable string.
--- @param v table Numeric version components, e.g. {2,2,1}.
--- @return string e.g. "2.2.1".
local function version_str(v)
	if type(v) ~= "table" then return "?" end
	local parts = {}
	for _, n in ipairs(v) do parts[#parts + 1] = tostring(n) end
	return table.concat(parts, ".")
end

--- Reads the version an installed bundle declares in its Info.plist
--- (CFBundleShortVersionString). The plist, not the folder name, is the
--- authority: bundles installed by hand or by an old installer can sit under a
--- folder name that carries no version at all.
--- @param bundle_path string Absolute path of the .bundle directory.
--- @return table|nil Numeric version components, or nil when unreadable.
local function read_bundle_version(bundle_path)
	if type(bundle_path) ~= "string" or bundle_path == "" then return nil end
	local plist_path = NativePath.without_trailing_separators(bundle_path) .. "/Contents/Info.plist"
	local content, status, detail = FileSystem.read_with_status(plist_path)
	if status ~= "ok" or type(content) ~= "string" then
		Logger.warn(LOG, "Bundle version unreadable — %s (%s: %s).",
			plist_path, tostring(status), tostring(detail))
		return nil
	end
	local raw = content:match("<key>%s*CFBundleShortVersionString%s*</key>%s*<string>%s*([%d%.]+)%s*</string>")
	if not raw then
		Logger.warn(LOG, "Bundle version missing — %s declares no numeric CFBundleShortVersionString.", plist_path)
		return nil
	end
	local parts = {}
	for n in raw:gmatch("(%d+)") do parts[#parts + 1] = tonumber(n) end
	if #parts == 0 then return nil end
	return parts
end

--- Maps every keylayout installed in `dir` to the bundle that ships it, so an
--- active input source can be traced back to its bundle whatever its folder name.
--- A parent directory revision cannot describe files inside Resources. Enumerate
--- those directories with native calls each time, avoiding a shell subprocess on
--- the normal Hammerspoon path and observing even same-second changes.
--- @param dir string Keyboard Layouts directory.
--- @return table|nil Map { [keylayout basename without extension] = bundle basename }, or nil on failure.
local function keylayout_index(dir)
	if type(dir) ~= "string" or dir == "" then return nil end
	local index = {}
	if type(FileSystem.classify_no_follow) == "function" then
		local _, status = FileSystem.classify_no_follow(NativePath.without_trailing_separators(dir))
		if status == "absent" then return index end
	end
	if hs and hs.fs and type(hs.fs.symlinkAttributes) == "function" then
		local function physical_directory(path)
			local attrs, status = FileSystem.classify_no_follow(path)
			if status == "error" then error("directory classification refused") end
			return status == "ok" and attrs.mode == "directory"
		end
		local function entries(path, visit)
			local names, listed = FsDir.try_entries(path)
			if not listed then return false end
			for _, name in ipairs(names) do visit(name) end
			return true
		end
		local root = NativePath.without_trailing_separators(dir)
		local read_ok, ok = pcall(entries, root, function(bundle)
			if not bundle:match("%.bundle$") then return end
			local bundle_path = root .. "/" .. bundle
			local contents = bundle_path .. "/Contents"
			local resources = contents .. "/Resources"
			-- find does not follow directory symlinks: retain that boundary.
			if not physical_directory(bundle_path) or not physical_directory(contents)
				or not physical_directory(resources) then return end
			local resources_listed = entries(resources, function(filename)
				local layout = filename:match("^(.*)%.keylayout$")
				if layout and index[layout] == nil then index[layout] = bundle end
			end)
			if not resources_listed then error("resource enumeration refused") end
		end)
		if read_ok and ok then return index end
		index = {}
	end
	-- Narrow test doubles and hosts without native enumeration still get fresh
	-- results, never a memo keyed only to the outer directory.
	local cmd = string.format(
		"find %s -maxdepth 4 -path '*.bundle/Contents/Resources/*.keylayout' 2>/dev/null",
		text_utils.shell_quote(dir))
	local p = io.popen(cmd)
	if not p then
		Logger.warn(LOG, "Keylayout scan could not start in %s.", dir)
		return nil
	end
	for raw_line in p:lines() do
		local line = raw_line:gsub("[\r\n]+$", "")
		local bundle, layout = line:match("([^/]+%.bundle)/Contents/Resources/([^/]+)%.keylayout$")
		if bundle and index[layout] == nil then index[layout] = bundle end
	end
	if p:close() ~= true then return nil end
	return index
end

--- Lists the keyboard layouts an installed bundle declares: each KLInfo_<name>
--- entry of its Info.plist with the TISInputSourceID it registers, kept only
--- when the bundle ships <name>.keylayout. The bundle itself says what it
--- installs, so no list of variants is written anywhere.
--- @param bundle_path string Absolute path of the .bundle directory.
--- @return table Array of { name, tis_id, keylayout } in Info.plist order.
local function bundle_variants(bundle_path)
	if type(bundle_path) ~= "string" or bundle_path == "" then return {} end
	local root = NativePath.without_trailing_separators(bundle_path)
	local content, status, detail = FileSystem.read_with_status(root .. "/Contents/Info.plist")
	if status ~= "ok" or type(content) ~= "string" then
		Logger.warn(LOG, "Bundle Info.plist unreadable — %s (%s: %s).", root, tostring(status), tostring(detail))
		return {}
	end
	local variants = {}
	for name, body in content:gmatch("<key>%s*KLInfo_([^<]-)%s*</key>%s*<dict>(.-)</dict>") do
		local tis_id = body:match("<key>%s*TISInputSourceID%s*</key>%s*<string>%s*([^<]-)%s*</string>")
		local keylayout = root .. "/Contents/Resources/" .. name .. ".keylayout"
		-- A name is a file basename here; anything else would read outside the bundle.
		if tis_id and name:match("^[%w_.%-]+$") then
			local file_status, mode = FileSystem.followed_mode(keylayout)
			if file_status == "present" and mode == "file" then
				variants[#variants + 1] = { name = name, tis_id = tis_id, keylayout = keylayout }
			end
		end
	end
	if #variants == 0 then
		Logger.warn(LOG, "Bundle %s declares no installable keyboard layout.", root)
	end
	return variants
end

--- Keyboard-layout names the installed bundles provide, in both scopes, so the
--- layout manager never installs a second input source under one of them.
--- @return table|nil Set { [name] = true }, or nil when a scope cannot be listed.
local function bundle_keylayout_names()
	local names = {}
	for _, dir in ipairs({ SYSTEM_LAYOUTS_DIR, USER_LAYOUTS_DIR }) do
		local index = keylayout_index(dir)
		if not index then return nil end
		for name in pairs(index) do names[name] = true end
	end
	return names
end

--- Resolves the version of an active KeyboardLayout Name. A versioned name
--- ("Ergopti_v2_1_0_plus") carries it; an unversioned one is traced to the
--- installed bundle shipping that keylayout and read from its Info.plist.
--- @param kl_name string KeyboardLayout Name from HIToolbox.
--- @return table|nil Numeric version components, or nil when truly unknown.
local function layout_version(kl_name)
	if type(kl_name) ~= "string" or kl_name == "" then return nil end
	local maj, min, pat = kl_name:match("_v(%d+)[_.](%d+)[_.](%d+)")
	if maj then return { tonumber(maj), tonumber(min), tonumber(pat) } end
	-- A name is matched against file basenames only; a separator could never match.
	if NativePath.has_separator(kl_name) then return nil end
	for _, dir in ipairs({ SYSTEM_LAYOUTS_DIR, USER_LAYOUTS_DIR }) do
		local index = keylayout_index(dir)
		local bundle = index and index[kl_name]
		if bundle then
			local layouts_dir = NativePath.without_trailing_separators(dir)
			return read_bundle_version(layouts_dir .. "/" .. bundle)
		end
	end
	return nil
end

--- Builds a same-filesystem replacement transaction for one bundle scope.
--- The source is copied and structurally verified before installed bundles move
--- into a rollback directory. The exit trap restores every moved bundle unless
--- the staged bundle reaches its final name.
--- @param target_dir string Keyboard Layouts directory receiving the bundle.
--- @param bundles_dir string Directory containing the source bundle.
--- @param bundle_name string Basename of the source bundle.
--- @return string|nil command POSIX shell command, or nil on invalid input.
--- @return string|nil detail Validation failure detail.
local function build_install_transaction(target_dir, bundles_dir, bundle_name)
	if type(target_dir) ~= "string" or target_dir == "" then
		return nil, "target directory is missing"
	end
	if type(bundles_dir) ~= "string" or bundles_dir == "" then
		return nil, "source directory is missing"
	end
	if type(bundle_name) ~= "string"
		or not bundle_name:match("^Ergopti_v[%d%.]+%.bundle$") then
		return nil, "bundle name is invalid"
	end
	-- The path will also run under administrator privileges for a system
	-- install. Admit only the executable bound to this running app and its
	-- exported device/inode, not an arbitrary environment-supplied program.
	local resolver = require("platform.remap.lease_helper")
	local resolved, launcher = pcall(resolver.resolve)
	if not resolved or type(launcher) ~= "string" or launcher:sub(1, 1) ~= "/" then
		return nil, "native exclusive rename unavailable; launch ErgoptiPlus to install keyboard layouts", "launcher_unavailable"
	end

	local target = target_dir:gsub("/+$", "")
	local source_dir = bundles_dir:match("/$") and bundles_dir or (bundles_dir .. "/")
	local sq = text_utils.shell_quote
	return table.concat({
		"target=" .. sq(target) .. ";",
		"source=" .. sq(source_dir .. bundle_name) .. ";",
		"name=" .. sq(bundle_name) .. ";",
		"launcher=" .. sq(launcher) .. ";",
		'case "$launcher" in /*) ;; *) echo "Native rename role unavailable."; exit 1 ;; esac;',
		'receipt=$("$launcher" --release-rename probe && printf .) || exit 1;',
		'[ "$receipt" = "$(printf \'%s\\n.\' --release-rename)" ] || exit 1;',
		'mkdir -p "$target" || exit 1;',
		'work="$(mktemp -d "$target/.ergopti-install.XXXXXX")" || exit 1;',
		'stage="$work/$name";',
		'backup="$work/backup";',
		'mkdir "$backup" || { rm -rf "$work"; exit 1; };',
		'cp -R "$source" "$stage" || { rm -rf "$work"; exit 1; };',
		'test -f "$stage/Contents/Info.plist" || { rm -rf "$work"; exit 1; };',
		'has_layout=0;',
		'for layout in "$stage"/Contents/Resources/*.keylayout; do',
			'if [ -f "$layout" ]; then has_layout=1; break; fi;',
		'done;',
		'[ "$has_layout" -eq 1 ] || { echo "Staged bundle contains no regular keyboard layout."; rm -rf "$work"; exit 1; };',
		'committed=0;',
		'restore_install() {',
			'if [ "$committed" -eq 0 ]; then',
				'restore_ok=1;',
				'for prior in "$backup"/Ergopti_v*.bundle; do',
					'[ -e "$prior" ] || [ -L "$prior" ] || continue;',
					'"$launcher" --release-rename move "$prior" "$target/${prior##*/}" || restore_ok=0;',
				'done;',
				'if [ "$restore_ok" -eq 1 ]; then',
					'rm -rf "$work";',
				'else',
					'echo "Keyboard layout backups retained at $backup.";',
					'echo "Keyboard layout backups retained at $backup." >&2;',
				'fi;',
				'return;',
			'fi;',
			'rm -rf "$work";',
		'};',
		'trap restore_install 0;',
		"trap 'exit 1' 1 2 15;",
		'for prior in "$target"/Ergopti_v*.bundle; do',
			'[ -e "$prior" ] || [ -L "$prior" ] || continue;',
			'prior_name=${prior##*/}; prior_version=${prior_name#Ergopti_v}; prior_version=${prior_version%.bundle};',
			'case "$prior_version" in ""|*[!0-9.]*) continue ;; esac;',
			'"$launcher" --release-rename move "$prior" "$backup/${prior##*/}" || exit 1;',
		'done;',
		'"$launcher" --release-rename move "$stage" "$target/$name" || exit 1;',
		'committed=1;',
		'trap - 0 1 2 15;',
		'if ! rm -rf "$work"; then',
			'echo "Keyboard layout installation cleanup failed; retained at $work.";',
			'echo "Keyboard layout installation cleanup failed; retained at $work." >&2;',
		'fi;',
		'exit 0;',
	}, " ")
end

--- Executes one user-owned shell replacement.
--- @param target_dir string Keyboard Layouts directory receiving the bundle.
--- @param bundles_dir string Directory containing the source bundle.
--- @param bundle_name string Basename of the source bundle.
--- @return boolean committed Whether the replacement committed.
--- @return any detail Native output or validation/exception detail.
local function execute_install_transaction(target_dir, bundles_dir, bundle_name)
	local command, detail, reason = build_install_transaction(target_dir, bundles_dir, bundle_name)
	if not command then return false, detail, reason end
	local call_ok, output, native_ok = pcall(hs.execute, command)
	if not call_ok then return false, output end
	if native_ok ~= true then return false, output end
	return true, output
end

--- Reports other-scope entries without deleting a concurrently created bundle.
--- @param dir string Other Keyboard Layouts directory.
--- @return boolean|nil occupied Nil when neither enumeration nor absence is proved.
local function other_scope_occupied(dir)
	local names, listed = list_bundles(dir)
	if not listed then return nil end
	return #names > 0
end

--- Checks the other scope after publication before allowing input-source changes.
--- @param dir string Other Keyboard Layouts directory.
--- @return boolean clear Whether the other scope is known empty.
--- @return string|nil reason Closed failure reason for the menu.
local function warn_other_scope(dir)
	local occupied = other_scope_occupied(dir)
	if occupied == false then return true end
	if occupied == nil then
		Logger.warn(LOG, "The other keyboard layout scope could not be checked: %s.", dir)
		return false, "other_scope_unverified"
	end
	Logger.warn(LOG, "Another keyboard layout bundle remains in %s; it was not removed.", dir)
	return false, "other_scope_occupied"
end

--- The Ergopti bundles installed in both the user and the system folders.
--- macOS loads both copies: it logs "duplicate keyboard layout identifier" and
--- renumbers the ids of the copy it reads second. On the maintainer's Mac (probe
--- v5, P8 b) new content written to the user copy did not apply even after a
--- re-register while a loose user layout's did (P8 a): the system copy is the
--- one macOS types with. A second copy is therefore never written.
--- @return table names Bundle names present in both folders.
local function duplicate_bundles()
	local system = {}
	for _, entry in ipairs(find_installed_bundles(SYSTEM_LAYOUTS_DIR)) do system[entry.name] = true end
	local both = {}
	for _, entry in ipairs(find_installed_bundles(USER_LAYOUTS_DIR)) do
		if system[entry.name] then both[#both + 1] = entry.name end
	end
	table.sort(both)
	return both
end

--- Logs each Ergopti bundle installed in both folders, naming the copy macOS uses.
--- @return table names Bundle names present in both folders.
local function report_duplicate_bundles()
	local both = duplicate_bundles()
	for _, name in ipairs(both) do
		Logger.warn(LOG, "%s is installed both in %s and in %s: macOS loads both and renumbers the second copy's layout ids; the system copy is the one it types with (probe v5, P8 b). Remove one copy (the user copy needs no password).",
			name, USER_LAYOUTS_DIR, SYSTEM_LAYOUTS_DIR)
	end
	return both
end

--- Copies the latest bundle to the user's Keyboard Layouts directory.
--- A bundle in the system scope must be removed manually before replacement.
--- The same bundle already in the system folder is not copied a second time.
--- @param bundles_dir string Absolute path of the source bundles directory.
--- @param bundle_name string Basename of the bundle to install.
--- @return boolean true on success.
local function install_user_unlocked(bundles_dir, bundle_name)
	local in_system = false
	for _, entry in ipairs(find_installed_bundles(SYSTEM_LAYOUTS_DIR)) do
		if entry.name == bundle_name then in_system = true end
	end
	if in_system then
		local user_occupied = other_scope_occupied(USER_LAYOUTS_DIR)
		if user_occupied == nil then
			Logger.error(LOG, "User install refused: the user layout directory could not be checked.")
			return false, "other_scope_unverified"
		end
		if user_occupied then
			Logger.warn(LOG, "User install refused: a keyboard bundle remains in the user scope.")
			return false, "other_scope_occupied"
		end
		Logger.info(LOG, "%s is already installed in %s: no second copy is written to the user folder.",
			bundle_name, SYSTEM_LAYOUTS_DIR)
		return true
	end
	local occupied = other_scope_occupied(SYSTEM_LAYOUTS_DIR)
	if occupied == nil then
		Logger.error(LOG, "User install refused: the system layout directory could not be checked.")
		return false, "other_scope_unverified"
	end
	if occupied then
		Logger.warn(LOG, "User install refused: another keyboard bundle remains in the system scope.")
		return false, "other_scope_occupied"
	end
	Logger.start(LOG, "Installing %s into the user Keyboard Layouts folder…", bundle_name)
	local committed, detail, reason = execute_install_transaction(
		USER_LAYOUTS_DIR, bundles_dir, bundle_name)
	if committed then
		if type(detail) == "string" and detail:find("Keyboard layout installation cleanup failed; retained at ", 1, true) then
			Logger.warn(LOG, "%s", (detail:gsub("%s+$", "")))
		end
		local clear, check_reason = warn_other_scope(SYSTEM_LAYOUTS_DIR)
		if not clear then
			Logger.warn(LOG, "User bundle was installed, but input-source changes are deferred.")
			return false, check_reason
		end
		Logger.success(LOG, "User install done — %s.", bundle_name)
		pcall(notifications.notify, i18n.get("menu.layout.installed_user"), nil, "success")
		return true
	end
	Logger.error(LOG, "User install failed: %s.", tostring(detail))
	return false, reason
end

--- Refuses privileged installation until a native owner can bind execution to
--- the already verified launcher across the authorization boundary.
--- @return boolean committed Always false while this operation is unavailable.
--- @return string reason Closed reason shown by the menu.
local function install_system_unlocked()
	Logger.warn(LOG, "System keyboard layout installation is unavailable; use the user scope.")
	return false, "system_install_unavailable"
end

--- Runs one bundle install while owning both destination scopes exclusively.
--- Native authorization can re-enter the Hammerspoon run loop, so the owner is
--- acquired before any prompt or filesystem command and released on every exit.
--- @param scope_label string Developer-facing scope name.
--- @param install_fn function Unlocked install implementation.
--- @param bundles_dir string Absolute path of the source bundles directory.
--- @param bundle_name string Basename of the bundle to install.
--- @return boolean committed Whether the install committed.
local function run_exclusive_install(scope_label, install_fn, bundles_dir, bundle_name)
	if _install_in_flight then
		Logger.warn(LOG, "%s keyboard-layout install refused — another install is still in progress.",
			scope_label)
		return false
	end
	_install_in_flight = true
	local call_ok, committed_or_err, reason = xpcall(function()
		return install_fn(bundles_dir, bundle_name)
	end, debug.traceback)
	_install_in_flight = false
	if not call_ok then
		Logger.error(LOG, "%s keyboard-layout install raised: %s.",
			scope_label, tostring(committed_or_err))
		return false
	end
	return committed_or_err == true, reason
end

local function install_user(bundles_dir, bundle_name)
	return run_exclusive_install(
		"User", install_user_unlocked, bundles_dir, bundle_name)
end

local function install_system(bundles_dir, bundle_name)
	return run_exclusive_install(
		"System", install_system_unlocked, bundles_dir, bundle_name)
end



return {
	USER_LAYOUTS_DIR       = USER_LAYOUTS_DIR,
	SYSTEM_LAYOUTS_DIR     = SYSTEM_LAYOUTS_DIR,
	parse_version          = parse_version,
	version_gt             = version_gt,
	version_str            = version_str,
	pick_latest_bundle     = pick_latest_bundle,
	path_exists            = path_exists,
	highest_installed      = highest_installed,
	read_bundle_version    = read_bundle_version,
	layout_version         = layout_version,
	bundle_variants        = bundle_variants,
	bundle_keylayout_names = bundle_keylayout_names,
	install_user          = install_user,
	duplicate_bundles     = duplicate_bundles,
	report_duplicate_bundles = report_duplicate_bundles,
	install_system         = install_system,
}
