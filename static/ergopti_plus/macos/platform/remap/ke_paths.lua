--- platform/remap/ke_paths.lua

--- ==============================================================================
--- MODULE: Karabiner-Elements Binary Paths
--- DESCRIPTION:
--- Absolute paths used either for the one supported CLI write boundary or for
--- read-only Karabiner installation checks, declared exactly once.
---
--- FEATURES & RATIONALE:
--- 1. Single Source: the `karabiner_cli` literal was written out three times —
---    in ke_lifecycle.lua, onboarding.lua and watchers.lua — with a fourth about
---    to be added by the gesture bridge. Karabiner v15.7 already renamed
---    one binary in that directory once, and a rename that reaches two of four
---    copies is a driver that reports Karabiner as installed while being unable
---    to talk to it.
--- 2. No Fallbacks: these paths are the PKG install locations and are not
---    configurable. A missing binary is reported by the caller that needs it,
---    loudly, rather than silently substituted here.
--- ==============================================================================

local M = {}

-- Shared package root. Command-line helpers remain under bin/, while v15.7+
-- moved the keyboard core executable into an app bundle so macOS can present
-- its permissions independently.
local SUPPORT_DIR = "/Library/Application Support/org.pqrs/Karabiner-Elements/"
local BIN_DIR = SUPPORT_DIR .. "bin/"

--- The CLI. Present in every version since v14 and never renamed, which makes it
--- both the IPC channel (`--set-variables`) and the most
--- reliable "is the full stack installed" probe.
M.CLI = BIN_DIR .. "karabiner_cli"

--- Shared console user server retained for version-tolerant diagnostics. It is
--- never started, stopped, signalled, or treated as Ergopti-owned state.
M.CONSOLE_USER_SERVER = BIN_DIR .. "karabiner_console_user_server"

--- The event grabber name used before v15.7.
M.GRABBER = BIN_DIR .. "karabiner_grabber"

--- The same component under its v15.7+ app-bundle location. The root daemon and
--- logged-in-user agent execute this same path, so callers must also check UID
--- when they need to distinguish the keyboard-processing daemon.
M.CORE_SERVICE = SUPPORT_DIR
	.. "Karabiner-Core-Service.app/Contents/MacOS/Karabiner-Core-Service"

--- The helper through which Karabiner-Elements registers, unregisters and asks
--- about its own user agents (`running`, `unregister-core-agents`). It is the
--- exact tool Karabiner's own « Quit Karabiner-Elements » runs, so it is the only
--- way the default-on « close other Karabiner instances » option (ADR 011) asks
--- the official application to quit. It was read at v16.0.0, the version the
--- shared runtime installs, and at the revision the owned runtime is built from.
M.NON_PRIVILEGED_AGENTS = SUPPORT_DIR
	.. "Karabiner-Elements Non-Privileged Agents v2.app/Contents/MacOS/Karabiner-Elements Non-Privileged Agents v2"





-- =========================================
-- =========================================
-- ======= 1/ Runtime-Selected Paths =======
-- =========================================
-- =========================================

--- The two Karabiner runtimes (ADR 011). Shared is the official application the
--- user installed; owned is the Ergopti background runtime. The names are the
--- values of `[karabiner] runtime` in config_karabiner.toml.
M.RUNTIME_SHARED = "shared"
M.RUNTIME_OWNED = "owned"

local OWNED_RUNTIME_DIR = "/Library/Application Support/ErgoptiPlus/Runtime"

--- Everything the owned runtime puts on disk. The runtime directory and the
--- launchd labels are the ones the Swift installer writes
--- (OwnedRuntimeCoreServiceOwner.swift); the CLI and Console names are the
--- products of tools/build/owned_runtime_product_build.py. The configuration
--- lives under the user's Library so that the runtime's Console process, started
--- with XDG_CONFIG_HOME set to CONFIG_HOME, reads a complete file Ergopti owns
--- and never the user's ~/.config/karabiner.
M.OWNED = {
	RUNTIME_DIR = OWNED_RUNTIME_DIR,
	CLI = OWNED_RUNTIME_DIR .. "/bin/ergoptiplus_remap_cli",
	CORE_SERVICE = OWNED_RUNTIME_DIR .. "/ErgoptiPlus-Remap-Core.app/Contents/MacOS/ErgoptiPlus-Remap-Core",
	CONSOLE = OWNED_RUNTIME_DIR .. "/ErgoptiPlus-Remap-Console.app/Contents/MacOS/ErgoptiPlus-Remap-Console",
	CORE_JOB_FILE = "/Library/LaunchDaemons/com.ergoptiplus.runtime.core.plist",
	CORE_LABEL = "com.ergoptiplus.runtime.core",
	VIRTUAL_HID_LABEL = "com.ergoptiplus.runtime.vhid",
	CONFIG_HOME = "~/Library/Application Support/ErgoptiPlus",
	CONFIG_FILE = "~/Library/Application Support/ErgoptiPlus/karabiner/karabiner.json",
}

--- Rejects a runtime name that is not one of the two.
--- @param runtime any Candidate runtime name.
--- @return string runtime The same name.
local function checked_runtime(runtime)
	assert(runtime == M.RUNTIME_SHARED or runtime == M.RUNTIME_OWNED,
		"unknown Karabiner runtime: " .. tostring(runtime))
	return runtime
end

local SHARED_CLI = M.CLI
local selected_runtime = M.RUNTIME_SHARED
local selection_made = false

--- The command line tool of a runtime.
--- @param runtime string `shared` or `owned`.
--- @return string path Absolute path.
function M.cli_for(runtime)
	if checked_runtime(runtime) == M.RUNTIME_OWNED then return M.OWNED.CLI end
	return SHARED_CLI
end

--- Selects, once per Lua VM, the runtime whose command line tool `M.CLI` names.
--- Every writer of Karabiner variables spells that tool `KePaths.CLI`, so the
--- selection reaches all of them without a second spelling. The shared tool
--- stays the value until a caller opts in, which is the dormant default. A
--- second call with the other runtime is refused: the lease and its variables
--- of one generation must never straddle two runtimes, so changing runtime
--- takes a reload.
--- @param runtime string `shared` or `owned`.
--- @return boolean selected Always true; an invalid or conflicting call raises.
function M.select_runtime(runtime)
	checked_runtime(runtime)
	if selection_made then
		assert(runtime == selected_runtime, "Karabiner runtime is already selected as "
			.. selected_runtime .. "; reload to switch to " .. runtime)
		return true
	end
	selection_made, selected_runtime = true, runtime
	M.CLI = M.cli_for(runtime)
	return true
end

--- The runtime `M.CLI` currently names.
--- @return string runtime `shared` until a caller selects another.
function M.selected_runtime()
	return selected_runtime
end

--- The generated configuration file of the selected runtime, as a tilde path
--- for the FileSystem port to expand.
--- @param runtime string `shared` or `owned`.
--- @return string path Tilde path.
function M.config_file_for(runtime)
	if checked_runtime(runtime) == M.RUNTIME_OWNED then return M.OWNED.CONFIG_FILE end
	return "~/.config/karabiner/karabiner.json"
end

return M
