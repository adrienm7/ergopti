--- modules/llm/network_env.lua

--- ==============================================================================
--- MODULE: Download Child Network Prelude
--- DESCRIPTION:
--- Names the shell lines that give a download child the system network
--- settings of a managed (company) Mac: the relay `scutil --proxy` names as
--- HTTPS_PROXY, HTTP_PROXY and NO_PROXY, loopback always excluded, and the
--- system trust store (apply_system_network in modules/llm/network-retry.sh,
--- the policy the installer scripts source too).
---
--- FEATURES & RATIONALE:
--- 1. A child of Hammerspoon has none of a login shell's relay variables, and
---    neither uv, Python nor Ollama's Go client reads the macOS settings: the
---    MLX installer, the MLX model download and the Ollama service (which pulls
---    the models) failed on a network that only lets its relay out.
--- 2. One policy: the prelude sources the same file the installer scripts do,
---    so every macOS download child reads the settings the same way.
--- 3. Fail fast: without the shared policy file the prelude is nil and the
---    caller refuses to start a download that would fail for an unnamed cause.
--- ==============================================================================

local M = {}

local text_utils = require("infra.text_utils")
local FileSystem = require("adapters.file_system")
local Admission = require("modules.llm.opaque_network_admission")

-- The shared policy, relative to the driver root.
local POLICY_RELATIVE = "modules/llm/network-retry.sh"

--- The driver root this module was loaded from.
--- @return string|nil root
local function driver_root()
	local source = debug.getinfo(1, "S").source or ""
	source = source:sub(1, 1) == "@" and source:sub(2) or source
	return source:match("^(.*)/modules/llm/network_env%.lua$")
end

--- Locates the shared network policy file.
--- @return string|nil path Absolute path, nil when it is missing.
local function locate_policy()
	local root = driver_root()
	if not root then return nil end
	local path = root .. "/" .. POLICY_RELATIVE
	if not FileSystem.exists(path) then return nil end
	return path
end

-- Located once, when the module loads: the file ships beside it in the bundle.
local _policy_path = locate_policy()

--- The shared network policy file.
--- @return string|nil path Absolute path, nil when it is missing.
function M.policy_path()
	return _policy_path
end

--- The shell lines, ending in "; ", that export the system network settings
--- for the command that follows them.
--- @param tag string Log prefix of the child, e.g. "MLX".
--- @return string|nil prelude
--- @return string|nil err Why it cannot be built.
local function build_prelude(tag, opaque)
	local policy = M.policy_path()
	if not policy then return nil, "the shared network policy " .. POLICY_RELATIVE .. " is missing" end
	local activation = opaque and "apply_system_network opaque" or "apply_system_network"
	local status = "_ergopti_network_status=$?; [ \"$_ergopti_network_status\" -eq 0 ] || exit \"$_ergopti_network_status\"; "
	if opaque then
		status = "_ergopti_network_status=$?; if [ \"$_ergopti_network_status\" -eq 0 ]; then printf '%s\\n' "
			.. text_utils.shell_quote(Admission.accepted_line) .. " >&2; else "
			.. "if [ \"$_ergopti_network_status\" -eq " .. tostring(Admission.refusal_exit_code) .. " ]; then "
			.. "case \"${OPAQUE_NETWORK_FAILURE_PROVENANCE:-}:${OPAQUE_NETWORK_PROXY_RESOLUTION_STATUS:-}\" in "
			.. "verified:unavailable|unavailable:unavailable) printf "
			.. text_utils.shell_quote(Admission.refusal_prefix .. "%s:%s\n")
			.. " \"$OPAQUE_NETWORK_FAILURE_PROVENANCE\" \"$OPAQUE_NETWORK_PROXY_RESOLUTION_STATUS\" >&2 ;; esac; fi; "
			.. "exit \"$_ergopti_network_status\"; fi; "
	end
	local label = text_utils.shell_quote("[" .. tostring(tag) .. "] %s\n")
	return "log_info() { printf " .. label .. " \"$1\" >&2; }; "
		.. "log_error() { printf " .. label .. " \"$1\" >&2; }; "
		.. ". " .. text_utils.shell_quote(policy) .. " && " .. activation .. "; "
		.. status, nil
end

--- Exports static settings for local serving and native-aware commands.
--- @param tag string Child log prefix.
--- @return string|nil prelude
--- @return string|nil err
function M.prelude(tag)
	return build_prelude(tag, false)
end

--- Admits an actual outgoing fetch by an opaque client before child dispatch.
--- Cached/local serving uses prelude() and does not require this capability.
--- @param tag string Child log prefix.
--- @return string|nil prelude
--- @return string|nil err
function M.opaque_prelude(tag)
	return build_prelude(tag, true)
end

return M
