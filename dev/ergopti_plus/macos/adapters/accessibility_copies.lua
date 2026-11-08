--- adapters/accessibility_copies.lua

--- ==============================================================================
--- MODULE: Accessibility Copies Adapter
--- DESCRIPTION:
--- Finds the other registered copies of this app whose code signature differs
--- from the running one: each can hold the one Accessibility switch macOS
--- files under the shared bundle identifier.
---
--- FEATURES & RATIONALE:
--- 1. Two copies, one switch: a local build (local self-signed certificate)
---    and the installed prerelease (CI certificate) share the runtime bundle
---    identifier. The switch the user turns on can then be the other copy's,
---    the running copy is not trusted, and resetting the entry at every boot
---    erased the switch in a loop (field report 2026-11-05).
--- 2. Both registries: LaunchServices lists every registered copy, Spotlight
---    the ones it indexed; either alone missed copies in the field.
--- 3. Same requirement, same grant: TCC matches a client by its designated
---    requirement, so only a copy whose requirement differs is reported.
--- 4. Asynchronous: the probe runs through the shell runner and reports its
---    exact exit; a refused probe is an error, never an empty list.
--- ==============================================================================

local M = {}

local LSREGISTER = "/System/Library/Frameworks/CoreServices.framework/Frameworks/"
	.. "LaunchServices.framework/Support/lsregister"

-- The runtime lives inside the launcher; the dialog names the app the user sees.
local EMBEDDED_SUFFIX = "/Contents/Frameworks/Hammerspoon.app"

-- An awk program over `lsregister -dump`: prints the path of every record whose
-- identifier is the awk variable id. A separate argument rather than inline
-- script text, so the shell script holds no awk statements.
M.REGISTERED_PATHS_AWK = [[
/^-----/ { if (ident == id && path != "") print path; path = ""; ident = "" }
/^path:/ { sub(/^path: */, ""); sub(/ \(0x[0-9a-f]+\)$/, ""); path = $0 }
/^identifier:/ { sub(/^identifier: */, ""); ident = $0 }
END { if (ident == id && path != "") print path }
]]

-- $1 bundle identifier, $2 this copy's path, $3 lsregister, $4 the awk program.
-- Prints one line per other copy whose designated requirement differs; exits 3
-- when this copy has no readable requirement, since nothing could then be compared.
M.SCRIPT = table.concat({
	'id="$1"; own="$2"; lsr="$3"; registered_paths="$4"',
	'requirement() { /usr/bin/codesign -d -r- "$1" 2>/dev/null | /usr/bin/sed -n "s/^designated => //p"; }',
	'canonical() { (cd "$1" 2>/dev/null && /bin/pwd -P); }',
	'own_path=$(canonical "$own"); own_req=$(requirement "$own")',
	'[ -n "$own_path" ] && [ -n "$own_req" ] || exit 3',
	'{ /usr/bin/mdfind "kMDItemCFBundleIdentifier == \'$id\'" 2>/dev/null',
	'  "$lsr" -dump 2>/dev/null | /usr/bin/awk -v id="$id" "$registered_paths"',
	'} | /usr/bin/grep \'\\.app$\' | /usr/bin/sort -u | while IFS= read -r copy; do',
	'  path=$(canonical "$copy"); [ -n "$path" ] && [ "$path" != "$own_path" ] || continue',
	'  [ "$(requirement "$path")" = "$own_req" ] || printf "%s\\n" "$path"',
	'done',
	'exit 0',
}, "\n")

--- Turns the probe's lines into the apps to name, launcher paths first.
--- @param stdout string Probe output, one runtime path per line.
--- @return table paths Distinct app paths, sorted.
function M.parse(stdout)
	local seen, paths = {}, {}
	for line in tostring(stdout or ""):gmatch("[^\n]+") do
		local path = line
		if path:sub(-#EMBEDDED_SUFFIX) == EMBEDDED_SUFFIX then
			path = path:sub(1, #path - #EMBEDDED_SUFFIX)
		end
		if path ~= "" and not seen[path] then
			seen[path] = true
			paths[#paths + 1] = path
		end
	end
	table.sort(paths)
	return paths
end

--- Starts the probe for the other copies of this app.
--- @param bundle_id string Runtime bundle identifier (letters, digits, dots, hyphens).
--- @param own_path string Path of the running runtime bundle.
--- @param on_done function fn(paths|nil, detail) once the probe has exited.
--- @return boolean started True when the probe was started.
function M.find(bundle_id, own_path, on_done)
	if type(bundle_id) ~= "string" or not bundle_id:match("^[%w%.%-]+$") then
		error("accessibility_copies.find: bundle_id must be a plain bundle identifier", 2)
	end
	if type(own_path) ~= "string" or own_path:sub(1, 1) ~= "/" then
		error("accessibility_copies.find: own_path must be an absolute path", 2)
	end
	if type(on_done) ~= "function" then error("accessibility_copies.find: on_done must be a function", 2) end
	local ShellRunner = require("adapters.shell_runner")
	local handle = ShellRunner.spawn("/bin/sh", { "-c", M.SCRIPT, "accessibility_copies", bundle_id, own_path,
		LSREGISTER, M.REGISTERED_PATHS_AWK }, function(exit_code, stdout, stderr)
		if exit_code == 0 then
			on_done(M.parse(stdout))
		elseif exit_code == 3 then
			on_done(nil, "this copy has no readable designated requirement")
		else
			on_done(nil, string.format("the copy probe exited with %s: %s", tostring(exit_code),
				tostring(stderr ~= "" and stderr or stdout)))
		end
	end)
	return handle.start() == true
end

return M
