--- ui/llm_progress/init.lua

--- ==============================================================================
--- MODULE: LLM Progress UI
--- DESCRIPTION:
--- Unified, persistent on-screen progress UI used for any long-running LLM
--- bootstrap or download operation: MLX engine install, Ollama engine
--- install, MLX model download, Ollama model download. Replaces the legacy
--- hs.notify + hs.alert duo with a single floating canvas window pinned to
--- the bottom-right corner that shows a title, a per-step status line, a
--- raw verbose detail line, and an optional progress bar — all updatable
--- in real time while the underlying bash / hs.task pipeline streams stdout.
---
--- FEATURES & RATIONALE:
--- 1. Single source of truth for progress UX: every install/download
---    surfaces through the same window, so the user always sees the same
---    visual language regardless of which backend or operation is running.
--- 2. Kind-driven personalisation: callers pass a "kind" identifier
---    (mlx_install / ollama_install / mlx_model / ollama_model). The module
---    derives the title, accent color and default subtitle from a single
---    PRESET table — no caller ever needs to know the styling rules.
--- 3. Real-time detail line: bash scripts emit verbose output line by line
---    on stderr (uv "Downloading torch (220 MB)…", ollama "pulling …").
---    The caller forwards each line via M.set_detail(line) so the user
---    sees concrete progress instead of a frozen banner.
--- 4. Auto-dismiss on success, sticky on error: M.set_step + M.hide is the
---    success path (auto-fade after a short delay handled by the caller).
---    M.set_error keeps the window visible with an error accent so the user
---    can read the cause before it auto-dismisses 8 seconds later.
--- 5. Canvas-based, no webview: avoids the cost and complexity of an HTML
---    asset bundle for what is fundamentally a 4-line floating banner. The
---    download_window webview is still the right fit for bytes/ETA-rich
---    model downloads; this UI is for terse step-by-step bootstraps.
--- ==============================================================================

local M = {}

local hs     = hs
local Logger = require("lib.logger")

local LOG = "llm_progress"




-- =================================
-- =================================
-- ======= 1/ Configuration ========
-- =================================
-- =================================

-- Window geometry. Pinned to the bottom-right corner with a small margin so
-- it never overlaps the dock and stays out of the way of menus/dialogs.
local WIN_WIDTH       = 460
local WIN_HEIGHT      = 150
local WIN_MARGIN      = 12

-- Canvas radii / paddings tuned to feel native on a Retina display.
local CORNER_RADIUS   = 12
local CONTENT_PADDING = 16
local TITLE_TEXT_SIZE = 14
local STEP_TEXT_SIZE  = 13
local DETAIL_TEXT_SIZE = 11
local PROGRESS_HEIGHT = 4

-- Auto-dismiss delay applied to M.set_error before the window fades. Keeps
-- the failure message readable without forcing the user to dismiss it.
local ERROR_AUTO_DISMISS_SEC = 8.0

-- Color palette. Each "kind" selects an accent so the user can tell at a
-- glance which engine is being installed without reading the title.
local COLORS = {
	background = { red = 0.07, green = 0.08, blue = 0.11, alpha = 0.96 },
	border     = { red = 0.20, green = 0.22, blue = 0.28, alpha = 1.0  },
	title      = { red = 1.00, green = 1.00, blue = 1.00, alpha = 1.0  },
	step       = { red = 0.92, green = 0.93, blue = 0.96, alpha = 1.0  },
	detail     = { red = 0.62, green = 0.66, blue = 0.74, alpha = 1.0  },
	track      = { red = 0.22, green = 0.24, blue = 0.30, alpha = 1.0  },
	error_step = { red = 1.00, green = 0.55, blue = 0.50, alpha = 1.0  },
}

-- Per-kind presets. Centralising the title / subtitle / accent color rules
-- means callers stay decoupled from the visual policy.
local PRESETS = {
	mlx_install = {
		default_title    = "Installation du moteur IA (MLX)",
		default_subtitle = "Préparation des dépendances Python locales…",
		accent           = { red = 0.30, green = 0.65, blue = 1.00, alpha = 1.0 },
	},
	ollama_install = {
		default_title    = "Installation du moteur IA (Ollama)",
		default_subtitle = "Préparation du serveur Ollama local…",
		accent           = { red = 0.45, green = 0.85, blue = 0.55, alpha = 1.0 },
	},
	mlx_model = {
		default_title    = "Téléchargement du modèle MLX",
		default_subtitle = "Récupération des poids depuis Hugging Face…",
		accent           = { red = 0.60, green = 0.45, blue = 0.95, alpha = 1.0 },
	},
	ollama_model = {
		default_title    = "Téléchargement du modèle Ollama",
		default_subtitle = "Récupération des poids depuis Ollama Hub…",
		accent           = { red = 0.95, green = 0.75, blue = 0.30, alpha = 1.0 },
	},
}

-- Maximum number of characters displayed in the verbose detail line. Long
-- uv lines like "Downloading torch (220 MB) …" easily exceed the canvas
-- width; we truncate with an ellipsis on the LEFT so the trailing
-- (most-informative) part of the line stays visible.
local DETAIL_MAX_CHARS = 70




-- ============================
-- ============================
-- ======= 2/ State ===========
-- ============================
-- ============================

-- Active canvas, or nil when the window is hidden. We never keep more than
-- one alive at a time; show() reuses the existing canvas if any.
local _canvas = nil

-- Currently selected preset (one of the keys in PRESETS), kept around so
-- mid-flight set_step / set_detail calls preserve the accent color.
local _kind = nil

-- Current text/state — cached so partial updates (set_step alone, set_detail
-- alone) can re-render the canvas without losing the other lines.
local _title    = ""
local _step     = ""
local _detail   = ""
local _progress = nil   -- nil = indeterminate, 0..100 = percentage
local _is_error = false

-- Timer handle for the auto-dismiss applied after set_error.
local _error_dismiss_timer = nil




-- ===================================
-- ===================================
-- ======= 3/ Render Helpers =========
-- ===================================
-- ===================================

--- Truncates a long detail line to DETAIL_MAX_CHARS by keeping the trailing
--- segment (which usually carries the actionable info: file name, %, MB).
--- @param s string Raw verbose line.
--- @return string Truncated representation safe to render in the canvas.
local function truncate_detail(s)
	if type(s) ~= "string" then return "" end
	-- Strip ANSI escape sequences emitted by uv / ollama in tty mode
	s = s:gsub("\27%[[%d;]*[%a]", "")
	if #s <= DETAIL_MAX_CHARS then return s end
	return "…" .. s:sub(#s - DETAIL_MAX_CHARS + 2)
end

--- Resolves a screen-relative anchor for the window. Defaulting to the main
--- screen's bottom-right keeps the UI predictable across multi-monitor
--- setups; we recompute on each show() in case the user has changed
--- displays since the last bootstrap.
--- @return table frame {x, y, w, h} suitable for hs.canvas.new.
local function compute_frame()
	local screen = hs.screen.mainScreen()
	local sf = screen and type(screen.frame) == "function"
		and screen:frame()
		or { x = 0, y = 0, w = 1920, h = 1080 }
	return {
		x = sf.x + sf.w - WIN_WIDTH  - WIN_MARGIN,
		y = sf.y + sf.h - WIN_HEIGHT - WIN_MARGIN,
		w = WIN_WIDTH,
		h = WIN_HEIGHT,
	}
end

--- Returns the accent color for the active kind, falling back to a neutral
--- blue if the kind is unknown (defensive — the validator in show() should
--- have caught this already).
local function accent_for_kind()
	local preset = PRESETS[_kind or ""]
	if preset and preset.accent then return preset.accent end
	return { red = 0.30, green = 0.55, blue = 0.95, alpha = 1.0 }
end

--- Rebuilds the entire canvas content from the cached state. Cheaper than
--- it sounds — hs.canvas reuses element memory across frames — and keeps
--- the per-setter logic dead simple: every setter just updates state and
--- calls render().
local function render()
	if not _canvas then return end

	local accent = _is_error
		and { red = 0.95, green = 0.40, blue = 0.40, alpha = 1.0 }
		or  accent_for_kind()

	-- Clear all elements before rebuilding to avoid index drift on partial
	-- redraws — hs.canvas does not auto-shrink the element list otherwise.
	pcall(function()
		while _canvas[1] do _canvas:removeElement(1) end
	end)

	-- Background pill with rounded corners
	_canvas:appendElements({
		type        = "rectangle",
		action      = "fill",
		fillColor   = COLORS.background,
		strokeColor = COLORS.border,
		strokeWidth = 1,
		roundedRectRadii = { xRadius = CORNER_RADIUS, yRadius = CORNER_RADIUS },
		frame       = { x = 0, y = 0, w = WIN_WIDTH, h = WIN_HEIGHT },
	})

	-- Accent stripe along the left edge, signalling install kind / error
	_canvas:appendElements({
		type        = "rectangle",
		action      = "fill",
		fillColor   = accent,
		roundedRectRadii = { xRadius = CORNER_RADIUS, yRadius = CORNER_RADIUS },
		frame       = { x = 0, y = 0, w = 4, h = WIN_HEIGHT },
	})

	-- Title
	_canvas:appendElements({
		type      = "text",
		text      = _title,
		textColor = COLORS.title,
		textSize  = TITLE_TEXT_SIZE,
		textFont  = ".AppleSystemUIFont",
		textStyle = { alignment = "left" },
		frame     = {
			x = CONTENT_PADDING,
			y = CONTENT_PADDING,
			w = WIN_WIDTH - 2 * CONTENT_PADDING,
			h = TITLE_TEXT_SIZE + 4,
		},
	})

	-- Step (current operation, French)
	_canvas:appendElements({
		type      = "text",
		text      = _step,
		textColor = _is_error and COLORS.error_step or COLORS.step,
		textSize  = STEP_TEXT_SIZE,
		textFont  = ".AppleSystemUIFont",
		textStyle = { alignment = "left" },
		frame     = {
			x = CONTENT_PADDING,
			y = CONTENT_PADDING + TITLE_TEXT_SIZE + 10,
			w = WIN_WIDTH - 2 * CONTENT_PADDING,
			h = STEP_TEXT_SIZE + 4,
		},
	})

	-- Verbose detail line (raw subprocess output, dimmed)
	_canvas:appendElements({
		type      = "text",
		text      = truncate_detail(_detail),
		textColor = COLORS.detail,
		textSize  = DETAIL_TEXT_SIZE,
		textFont  = "Menlo",
		textStyle = { alignment = "left" },
		frame     = {
			x = CONTENT_PADDING,
			y = CONTENT_PADDING + TITLE_TEXT_SIZE + STEP_TEXT_SIZE + 22,
			w = WIN_WIDTH - 2 * CONTENT_PADDING,
			h = DETAIL_TEXT_SIZE + 4,
		},
	})

	-- Progress bar — track first, then fill. When _progress is nil we render
	-- a thin "indeterminate" bar at 30% width to signal activity without a
	-- known percentage; the simpler alternative — animating a marquee —
	-- would require a recurring timer for marginal UX value.
	local bar_y = WIN_HEIGHT - PROGRESS_HEIGHT - CONTENT_PADDING
	_canvas:appendElements({
		type        = "rectangle",
		action      = "fill",
		fillColor   = COLORS.track,
		roundedRectRadii = { xRadius = PROGRESS_HEIGHT/2, yRadius = PROGRESS_HEIGHT/2 },
		frame       = {
			x = CONTENT_PADDING,
			y = bar_y,
			w = WIN_WIDTH - 2 * CONTENT_PADDING,
			h = PROGRESS_HEIGHT,
		},
	})
	local pct = _progress
	local indeterminate = (pct == nil)
	if indeterminate then pct = 30 end
	pct = math.max(0, math.min(100, pct))
	if pct > 0 then
		_canvas:appendElements({
			type        = "rectangle",
			action      = "fill",
			fillColor   = accent,
			roundedRectRadii = { xRadius = PROGRESS_HEIGHT/2, yRadius = PROGRESS_HEIGHT/2 },
			frame       = {
				x = CONTENT_PADDING,
				y = bar_y,
				w = (WIN_WIDTH - 2 * CONTENT_PADDING) * (pct / 100),
				h = PROGRESS_HEIGHT,
			},
		})
	end
end

--- Cancels any pending error auto-dismiss. Called whenever a fresh show()
--- or set_step() arrives so a previous error window is not abruptly hidden
--- under the user's nose.
local function cancel_error_dismiss()
	if _error_dismiss_timer then
		pcall(function() _error_dismiss_timer:stop() end)
		_error_dismiss_timer = nil
	end
end




-- ===============================
-- ===============================
-- ======= 4/ Public API =========
-- ===============================
-- ===============================

--- Shows the progress window for a given operation kind. Idempotent: when
--- a window is already on screen, the existing canvas is reused (its title
--- and accent are updated in place) so callers can re-issue show() at the
--- start of every retry without flickering.
--- @param opts table {kind, title?, subtitle?}
function M.show(opts)
	opts = type(opts) == "table" and opts or {}
	local kind = opts.kind
	if type(kind) ~= "string" or not PRESETS[kind] then
		Logger.error(LOG, "M.show(): unknown or missing kind '%s' — refusing to render.", tostring(kind))
		return
	end

	Logger.start(LOG, "Showing progress UI (kind=%s).", kind)
	cancel_error_dismiss()

	_kind     = kind
	_title    = (type(opts.title)    == "string" and opts.title    ~= "") and opts.title    or PRESETS[kind].default_title
	_step     = (type(opts.subtitle) == "string" and opts.subtitle ~= "") and opts.subtitle or PRESETS[kind].default_subtitle
	_detail   = ""
	_progress = nil
	_is_error = false

	if not _canvas then
		local ok, canvas = pcall(hs.canvas.new, compute_frame())
		if not ok or not canvas then
			Logger.error(LOG, "Failed to create hs.canvas — progress UI disabled.")
			return
		end
		_canvas = canvas
		pcall(function() _canvas:level(hs.canvas.windowLevels.floating) end)
		pcall(function() _canvas:behavior({ "canJoinAllSpaces", "stationary" }) end)
	else
		-- Existing canvas: just refresh its frame to the active screen
		pcall(function() _canvas:frame(compute_frame()) end)
	end

	render()
	pcall(function() _canvas:show() end)
	Logger.success(LOG, "Progress UI shown (title=%q).", _title)
end

--- Updates the current step label (the second, brighter line). Use this
--- on every macro-step boundary (e.g. "Installation de uv…",
--- "Synchronisation des dépendances IA…").
--- @param label string French step description.
function M.set_step(label)
	if not _canvas then return end
	if type(label) ~= "string" then return end
	_step = label
	_is_error = false
	cancel_error_dismiss()
	Logger.debug(LOG, "Step: %s", label)
	render()
end

--- Updates the verbose detail line (third, dimmed monospaced line). Use
--- this on every stdout/stderr line received from the subprocess — the
--- module truncates long lines automatically.
--- @param text string Raw verbose output.
function M.set_detail(text)
	if not _canvas then return end
	if type(text) ~= "string" then return end
	_detail = text
	render()
end

--- Updates the progress bar fill. Pass nil to switch back to the
--- indeterminate (30 %-track) display when the percentage is unknown.
--- @param pct number|nil Percentage in [0, 100], or nil for indeterminate.
function M.set_progress(pct)
	if not _canvas then return end
	if pct ~= nil and type(pct) ~= "number" then return end
	_progress = pct
	render()
end

--- Switches the UI to "error" presentation: red accent, error step color,
--- and an automatic dismiss after ERROR_AUTO_DISMISS_SEC. The caller does
--- NOT have to call M.hide() — but it may, to dismiss the error sooner.
--- @param msg string Short French error message (one line).
function M.set_error(msg)
	if not _canvas then
		-- Even if no UI is currently shown, surface the error in logs so it
		-- never goes silent (per the "fail fast / no silent failure" rule).
		Logger.error(LOG, "set_error called with no active UI: %s", tostring(msg))
		return
	end
	_step     = type(msg) == "string" and msg or "Erreur inconnue."
	_is_error = true
	_progress = nil
	render()
	Logger.warn(LOG, "Progress UI flipped to error state: %s", _step)

	cancel_error_dismiss()
	_error_dismiss_timer = hs.timer.doAfter(ERROR_AUTO_DISMISS_SEC, function()
		_error_dismiss_timer = nil
		M.hide()
	end)
end

--- Hides and destroys the canvas. Safe to call even when no UI is active.
function M.hide()
	cancel_error_dismiss()
	if not _canvas then return end
	Logger.start(LOG, "Hiding progress UI.")
	pcall(function() _canvas:hide() end)
	pcall(function() _canvas:delete() end)
	_canvas   = nil
	_kind     = nil
	_title    = ""
	_step     = ""
	_detail   = ""
	_progress = nil
	_is_error = false
	Logger.success(LOG, "Progress UI hidden.")
end

--- @return boolean True when the progress UI is currently visible.
function M.is_active()
	return _canvas ~= nil
end

return M
