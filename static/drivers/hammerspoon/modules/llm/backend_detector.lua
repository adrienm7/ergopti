--- modules/llm/backend_detector.lua

--- ==============================================================================
--- MODULE: LLM Backend Detector
--- DESCRIPTION:
--- Decides which LLM backend ("mlx" or "ollama") should be the default on
--- the current host. The rule is straightforward and deterministic:
---   - macOS on Apple Silicon (arm64) ≥ 13.0  → "mlx"  (native MLX runtime)
---   - everything else                         → "ollama" (portable fallback)
---
--- A user-saved preference (hs.settings: "llm_backend") always wins over the
--- auto-detected default — switching backends in the menu must persist.
---
--- FEATURES & RATIONALE:
--- 1. Single source of truth: every caller asking "which backend?" goes
---    through this module so the policy is consistent across boot, menu
---    opening, and backend-switch flows.
--- 2. Defensive detection: each underlying probe (uname, sw_vers, hs.host)
---    is wrapped in pcall and falls back to a sane default — a probe
---    failure must never leave the user with no usable backend.
--- 3. Pure read-only: this module never installs, downloads, or spawns
---    anything; it only reports a decision. Bootstrapping is the
---    responsibility of *_deps_checker modules which consult this one.
--- ==============================================================================

local M = {}
local hs     = hs
local Logger = require("lib.logger")

local LOG = "backend_detector"




-- =====================================
-- =====================================
-- ======= 1/ Constants ================
-- =====================================
-- =====================================

-- Backend identifiers. Kept here as constants so a typo in any caller is
-- immediately visible at lint time rather than at runtime.
M.BACKEND_MLX    = "mlx"
M.BACKEND_OLLAMA = "ollama"

-- macOS minimum version required for the MLX backend. MLX itself supports
-- 13.5+ in practice; we accept ≥ 13.0 as a permissive floor and let the
-- pip install fail loudly if the OS is too old (the deps checker surfaces
-- the failure through the unified progress UI).
local MLX_MIN_MACOS_MAJOR = 13

-- Hammerspoon-settings key under which the user's explicit choice is
-- persisted. Picking the same key as menu_llm.DEFAULT_STATE keeps the two
-- in sync.
local SETTING_KEY = "llm_backend"




-- ==============================
-- ==============================
-- ======= 2/ Probes ============
-- ==============================
-- ==============================

--- Returns true on Apple Silicon (arm64). Falls back to a heuristic on the
--- /opt/homebrew prefix when uname is unavailable for any reason.
--- @return boolean True when the host CPU is arm64.
local function is_apple_silicon()
	local ok, out = pcall(hs.execute, "/usr/bin/uname -m")
	if ok and type(out) == "string" then
		if out:match("arm64") then return true end
		if out:match("x86_64") then return false end
	end
	-- Heuristic fallback: Homebrew on Apple Silicon installs to /opt/homebrew,
	-- on Intel to /usr/local. Not 100 % bullet-proof, but catches every
	-- realistic case on a Mac shipped after late-2020.
	return hs.fs.attributes("/opt/homebrew", "mode") == "directory"
end

--- Returns the macOS major version as an integer (13, 14, 15, …) or nil
--- when the probe fails. We treat "unknown" as "too old to be safe" → MLX
--- not selected.
--- @return integer|nil major Major macOS version, or nil if unknown.
local function macos_major_version()
	local ok, out = pcall(hs.execute, "/usr/bin/sw_vers -productVersion")
	if not ok or type(out) ~= "string" then return nil end
	local major = out:match("^(%d+)")
	return major and tonumber(major) or nil
end




-- =======================================
-- =======================================
-- ======= 3/ Public Detection API =======
-- =======================================
-- =======================================

--- Computes the auto-detected default backend ignoring any user preference.
--- Useful for diagnostics and for the menu's "reset to default" action.
--- @return string One of M.BACKEND_MLX / M.BACKEND_OLLAMA.
function M.auto_default()
	local arm = is_apple_silicon()
	local major = macos_major_version()
	local ok_macos = (major ~= nil) and (major >= MLX_MIN_MACOS_MAJOR)

	if arm and ok_macos then
		Logger.debug(LOG, "Auto-default = mlx (arm64, macOS major=%s).", tostring(major))
		return M.BACKEND_MLX
	end
	Logger.debug(LOG, "Auto-default = ollama (arm=%s, macOS major=%s).",
		tostring(arm), tostring(major))
	return M.BACKEND_OLLAMA
end

--- Returns the effective backend the rest of the stack should use. Honours
--- a user-saved preference when present; otherwise falls back to
--- M.auto_default().
--- @return string One of M.BACKEND_MLX / M.BACKEND_OLLAMA.
function M.effective_backend()
	local saved = nil
	local ok = pcall(function()
		saved = hs.settings.get(SETTING_KEY)
	end)
	if ok and (saved == M.BACKEND_MLX or saved == M.BACKEND_OLLAMA) then
		Logger.debug(LOG, "Effective backend = %s (user-saved).", saved)
		return saved
	end
	return M.auto_default()
end

--- Persists an explicit backend choice. Validates the value to keep callers
--- honest — a typo would otherwise silently corrupt hs.settings.
--- @param backend string Must equal M.BACKEND_MLX or M.BACKEND_OLLAMA.
function M.set_backend(backend)
	if backend ~= M.BACKEND_MLX and backend ~= M.BACKEND_OLLAMA then
		Logger.error(LOG, "set_backend: invalid backend '%s' — refusing to persist.", tostring(backend))
		return
	end
	pcall(function() hs.settings.set(SETTING_KEY, backend) end)
	Logger.debug(LOG, "Backend preference saved: %s.", backend)
end

return M
