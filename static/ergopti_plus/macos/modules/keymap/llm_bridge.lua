--- modules/keymap/llm_bridge.lua

--- ==============================================================================
--- MODULE: Keymap LLM Bridge
--- DESCRIPTION:
--- Thin orchestrator that connects the keymap core to the LLM prediction engine.
--- Handles the keymap-specific concerns that do not belong in modules/llm/:
--- hotstring detection and preview, keystroke routing for prediction acceptance,
--- and buffer management on navigation or escape events.
---
--- RESPONSIBILITIES:
--- 1. Hotstring preview: each keystroke calls update_preview(), which decides
---    whether to show a hotstring tooltip or arm the inactivity debounce timer.
--- 2. Prediction acceptance: apply_prediction() types the selected completion,
---    updates the in-memory buffer, and delegates chain arming to the engine.
--- 3. Keystroke routing: intercepts arrow keys, Enter, and modifier+digit combos
---    to navigate, accept, or dismiss predictions without disturbing the buffer.
--- 4. Configuration forwarding: all LLM settings flow through here so the
---    menu's public API surface on keymap/init.lua does not need to change.
---
--- NOTE: The actual LLM request, streaming, deduplication, app exclusion, and
--- state management all live in modules/llm/prediction_engine.lua.
--- ==============================================================================

local M = {}

local hs        = hs
local km_utils         = require("modules.keymap.utils")
local EventProvenance  = require("adapters.event_provenance")
local SyntheticInput   = require("adapters.synthetic_input")
local text_utils       = require("infra.text_utils")
local core_llm         = require("modules.llm")
local Logger           = require("infra.logger")
local Keycodes         = require("infra.keycodes")
local keylogger        = require("modules.keylogger")
local tooltip          = require("ui.tooltip")
local engine           = require("modules.llm.prediction_engine")
local Registry         = require("modules.keymap.registry")
local hotstrings_config = require("modules.hotstrings.hotstrings_config")
local expander         = require("modules.keymap.expander")
local TimerScheduler   = require("adapters.timer_scheduler")
local ManifestReader = require("infra.manifest_reader")

local LOG    = "keymap.llm_bridge"
local _state = nil  -- Shared CoreState, injected via M.init().
-- A failed action-epoch reset must not let stale prediction state consume user
-- input. This gate is intentionally bridge-wide: keymap, expander, tooltip and
-- menu callbacks all enter the prediction engine through this module.
local _runtime_quarantined = false
local _safe_action_epoch = SyntheticInput.current_action_epoch()
local _quarantine_hide_pending = false





-- ===================================
-- ===================================
-- ======= 1/ Module Constants =======
-- ===================================
-- ===================================

-- ── macOS key codes ──────────────────────────────────────────────────────────

-- Digit row 1–0 mapped to prediction slot indices 1–10.
local KEYCODE_DIGITS = {
	[18] = 1, [19] = 2, [20] = 3, [21] = 4, [23] = 5,
	[22] = 6, [26] = 7, [28] = 8, [25] = 9, [29] = 10,
}

local KEYCODE_ESCAPE    = Keycodes.ESCAPE   -- Escape key consumed by the dynamic escape trap
local KEYCODE_RETURN    = Keycodes.RETURN   -- Main Return key (accepts the active prediction)
local KEYCODE_ENTER     = 76   -- Numpad Enter (same behaviour as Return)
local KEYCODE_TAB       = 48   -- Tab: fast-accepts prediction #1 and stops all streaming
local KEYCODE_ARROW_MIN = 123  -- Lowest arrow keycode (left arrow)
local KEYCODE_ARROW_MAX = 126  -- Highest arrow keycode (up arrow); range covers all four

-- ── UI / display parameters ──────────────────────────────────────────────────

-- Fallback sentinel used when no row contributes a timeout. A committed
-- infinite row itself carries duration 0, which TooltipConfig treats as the
-- canonical "never auto-dismiss" value.
local INFINITE_TOOLTIP_SEC       = 86400  -- 24h stand-in for "never auto-dismiss"
-- Tiny offset added on top of the tooltip timeout when chaining LLM after a hotstring,
-- so the LLM fires just after the tooltip would normally close.
local HOTSTRING_CHAIN_OFFSET_SEC = 0.05

-- Upper bound on the raw→plain cache populated by provider callbacks. Previews
-- run on every keystroke and each provider returns a raw replacement that
-- needs tokens_from_repl() + plain_text() before it can be compared against
-- the buffer. In practice providers emit a small handful of distinct raw
-- strings, so a cache makes the per-keystroke work a single table lookup.
-- The cap exists purely as a safety net: a pathological provider returning
-- an unbounded set of unique strings would otherwise grow the table
-- forever. When the cap is hit we reset the table — simpler than LRU
-- bookkeeping and fine for a rare overflow.
local PROVIDER_CACHE_MAX = 1024

-- Width of the placeholder a row falls back to when the personal-info field
-- classification cannot be reached at all. Fixed rather than the value's own
-- length: how long a secret is, is itself a hint about which one it is.
local UNCLASSIFIED_PREVIEW_BULLETS = 8

-- Canonical LLM defaults, owned by modules/llm; used to seed bridge-local flags.
local LLM_DEFAULTS = core_llm.DEFAULT_STATE





-- ================================
-- ================================
-- ======= 2/ Mutable State =======
-- ================================
-- ================================

-- The most recently shown hotstring suggestion; kept for dismissal telemetry.
local last_shown_hotstring = nil

--- Whether a previewed match may be written to the PERSISTED telemetry.
---
--- A named predicate rather than an inline `not m.is_private` at each of the two
--- call sites, because those two sites are 100 lines apart, one of them fires
--- from a different function entirely (reset_predictions, on dismissal), and the
--- last time this rule was applied per-site rather than at the decision it was
--- applied to one of them and missed the other for months.
---
--- The rule: both columns are secret. The replacement IS the IBAN and the
--- trigger is a fragment of it, so redacting one and keeping the other still
--- leaks — the row is withheld whole.
---
--- This is NOT the same rule as the tooltip's. The screen shows a declared
--- secret partially masked (last four characters, so the user can still confirm
--- WHICH value is about to be typed); the persisted row shows nothing at all,
--- because a log outlives the moment and is read by tools, not by the person who
--- owns the value. Neither rule touches what gets TYPED.
--- @param match table|nil A preview match, or the last_shown_hotstring record.
--- @return boolean True when the row may be persisted.
local function may_persist_preview(match)
	if type(match) ~= "table" then return false end
	return not match.is_private
end

--- Exposed for tests. The two call sites are deferred through a timer and land
--- in a module the harness cannot substitute reliably, so the decision is
--- asserted here directly rather than through a preview that never reaches it.
M._may_persist_preview = may_persist_preview

-- Persistent Escape trap, created lazily on first tooltip show.
-- Inserting a new eventtap at HEAD ensures it fires before any pre-existing tap (e.g. Raycast).
-- The trap checks tooltip.is_visible() at runtime so it never needs to be disarmed.
local _escape_trap = nil

-- Identity of the most recently REQUESTED preview render.
--
-- The hotstring preview used to render synchronously inside the HID callback,
-- and rendering is not cheap: resolving the anchor performs cross-process
-- accessibility IPC and creates and destroys eventtaps, on EVERY preview
-- keystroke. Against a beach-balling front app that IPC blocks until the AX
-- timeout, which is long enough for macOS to disable the whole keyboard tap for
-- being unresponsive — taking the driver down with it. The render is therefore
-- deferred by one runloop tick, exactly as the LLM tooltip already defers its
-- own re-renders.
--
-- Deferring introduces a gap in which the preview can be superseded or
-- dismissed, so each request is stamped: a pending render that is no longer the
-- newest drops itself rather than resurrecting a tooltip the user has already
-- dismissed or replaced. Declared above every closure that reads it — a local
-- declared below one binds a nil global instead.
local _preview_render_generation = 0

-- A finite-delay literal auto can outlive its nominal gate on screen if a native
-- tooltip timer fires late. While that exact committed row is still visible, the
-- eventtap honours the promise instead of falling through to a different action.
-- This is a UI lease, not registry ownership: key changes still use has_magic.
local _visible_magic_lease = nil

--- Invalidates any preview render still waiting on its deferral tick.
--- Called wherever the tooltip is hidden or the predictions reset, so a render
--- requested moments earlier cannot land afterwards.
local function invalidate_pending_preview(keep_visible_lease)
	_preview_render_generation = _preview_render_generation + 1
	if not keep_visible_lease then _visible_magic_lease = nil end
end

--- Returns whether a visibly committed row leases this exact magic action.
--- O(1) and safe on the eventtap path; TooltipHotstring.is_visible is local state.
--- @param action_token any Exact mapping/provider action identity.
--- @param buffer string Buffer before the magic key.
--- @return boolean
function M.owns_visible_magic_action(action_token, buffer)
	local lease = _visible_magic_lease
	if not lease or lease.action_token ~= action_token or lease.buffer ~= buffer then return false end
	if type(tooltip.has_visible_hotstring_lease) ~= "function" then return false end
	local ok, visible = pcall(tooltip.has_visible_hotstring_lease, action_token)
	return ok and visible == true
end


--- Enables/disables the explicit fail-closed runtime interaction latch.
--- This function is intentionally O(1) and performs no timer, canvas, logger or
--- engine calls; it is safe to call from an eventtap callback.
--- @param value boolean True to quarantine runtime LLM interactions.
function M.set_runtime_quarantined(value)
	local quarantined = value == true
	if quarantined == _runtime_quarantined then return end
	_runtime_quarantined = quarantined
	if quarantined then invalidate_pending_preview() end
end


--- Reports whether prediction/preview interactions are currently safe.
--- @return boolean True when runtime calls may reach the prediction engine.
function M.is_runtime_available()
	return not _runtime_quarantined
		and _safe_action_epoch == SyntheticInput.current_action_epoch()
end


--- Observes a new action epoch without doing any external work.
--- The live-token comparison in is_runtime_available already closes the gate
--- before this callback runs; the explicit latch also invalidates a pending
--- hotstring render in constant time.
--- @param epoch table Opaque SyntheticInput action token.
--- @return boolean current True when epoch is still the current token.
function M.observe_action_epoch(epoch)
	if epoch ~= SyntheticInput.current_action_epoch() then return false end
	if epoch ~= _safe_action_epoch then M.set_runtime_quarantined(true) end
	return true
end

-- ── Preview visibility toggles ────────────────────────────────────────────────
-- Initial values are set in M.init() from the keymap defaults passed by keymap/init.lua.
-- The menu overrides them at startup via set_preview_*_enabled().

local is_star_preview_enabled        = nil  -- Set in M.init()
local is_autocorrect_preview_enabled = nil  -- Set in M.init()

-- ── Behavioral flags ──────────────────────────────────────────────────────────
-- Sourced from LLM_DEFAULTS so both this module and menu_llm share the same value.

-- Chain LLM immediately after a hotstring tooltip closes.
-- Guard against nil LLM_DEFAULTS so modules.llm stub omitting DEFAULT_STATE
-- does not crash the load-time expression (adapters-input-2 pattern).
local fire_llm_after_hotstring   = LLM_DEFAULTS and LLM_DEFAULTS.llm_after_hotstring
-- Clear the buffer when the user presses an arrow key or Escape outside prediction mode.
local reset_buffer_on_navigation = LLM_DEFAULTS and LLM_DEFAULTS.llm_reset_on_nav

-- Memoization of plain-text projections for strings returned by preview
-- providers. Each keystroke used to call tokens_from_repl() + plain_text()
-- on the provider result, both of which scan the whole string; now we pay
-- that cost exactly once per distinct raw value. See PROVIDER_CACHE_MAX
-- for the overflow policy.
local _provider_plain_cache      = {}
local _provider_plain_cache_size = 0

--- Returns the plain-text projection of a raw provider replacement, using a
--- module-local memoization table so the per-keystroke preview path does no
--- tokenization work for previously-seen strings.
--- @param raw string Raw replacement returned by a provider callback.
--- @return string Plain text with tokens resolved.
local function provider_plain(raw)
	-- Defensive: providers are external callbacks, so nothing guarantees they
	-- return a string. A non-string key in the cache would crash downstream
	-- concatenation in plain_text; bail out early and return empty.
	if type(raw) ~= "string" then return "" end
	local cached = _provider_plain_cache[raw]
	if cached ~= nil then return cached end
	if _provider_plain_cache_size >= PROVIDER_CACHE_MAX then
		_provider_plain_cache      = {}
		_provider_plain_cache_size = 0
	end
	local plain = km_utils.plain_text(km_utils.tokens_from_repl(raw))
	_provider_plain_cache[raw] = plain
	_provider_plain_cache_size = _provider_plain_cache_size + 1
	return plain
end


--- Guard: verifies that M.init() was called before any public function that
--- depends on _state. Logs an error and returns false on failure.
--- @param func_name string Name of the calling function.
--- @return boolean
local function require_state(func_name)
	if not _state then
		Logger.error(LOG, "'%s' called before M.init() — shared state not initialized.", func_name)
		return false
	end
	return true
end

--- Returns true when buf ends with the trigger (with optional word-boundary check).
--- Defined at module level so it is not re-allocated as a closure on every keystroke.
--- @param buffer string The current typed buffer.
--- @param trigger string The hotstring trigger to match.
--- @param is_word boolean When true, rejects matches preceded by a letter or "@".
--- @return boolean
-- The preview's own copy of the word-boundary rule used to live here. It has been
-- deleted rather than kept as a helper: it disagreed with the engine's
-- word_boundary_blocks at the buffer start (this version allowed any match when
-- nothing preceded the trigger; the engine consults start_is_word_boundary and
-- refuses), and for separator-prefixed triggers. Both sides now call
-- expander.resolve_magic_action, so there is one arbitration result and nothing
-- left to keep in sync.

--- Returns true when the buffer ends with a word-boundary character that signals the
--- user has completed a word: punctuation or whitespace (whitespace is already handled
--- separately by the last_word == nil branch, but punctuation reaches this path).
--- @param buf string The current typed buffer.
--- @return boolean
local function is_word_boundary(buf)
	if type(buf) ~= "string" or buf == "" then return false end
	-- Extract the last UTF-8 codepoint rather than the last byte, so that
	-- multi-byte separators like NBSP (U+00A0, "\194\160") and NNBSP
	-- (U+202F, "\226\128\175") — produced by French typography hotstrings —
	-- are recognised as word boundaries instead of looking like stray
	-- continuation bytes that never match any of the ASCII comparisons.
	local ok, poff = pcall(utf8.offset, buf, -1)
	local last = (ok and poff) and buf:sub(poff) or buf:sub(-1)
	return last == " " or last == "," or last == "." or last == "!"
		or last == "?" or last == ";" or last == ":" or last == ")"
		or last == "}" or last == "]" or last == "\n"
		or last == "\194\160" or last == "\226\128\175"
end




-- ==========================================
-- ==========================================
-- ======= 3/ Configuration Setters =========
-- ==========================================
-- ==========================================



-- ================================
-- ===== 3.1) Preview Toggles =====
-- ================================

--- Enables or disables the ★ hotstring preview tooltip.
--- @param v boolean
function M.set_preview_star_enabled(v)
	is_star_preview_enabled = (v == true)
	Logger.debug(LOG, "Star preview: %s.", is_star_preview_enabled and "on" or "off")
	if not v then
		-- hide_forced, not hide: a dequeue cycle in progress makes tooltip.hide()
		-- a no-op so multi-row previews survive the first row's expiry — which
		-- means turning the preview OFF left the rows the user just disabled
		-- sitting on screen until they timed out on their own.
		invalidate_pending_preview()
		tooltip.hide_forced()
	end
end

--- Enables or disables the autocorrect hotstring preview tooltip.
--- @param v boolean
function M.set_preview_autocorrect_enabled(v)
	is_autocorrect_preview_enabled = (v == true)
	Logger.debug(LOG, "Autocorrect preview: %s.", is_autocorrect_preview_enabled and "on" or "off")
	if not v then
		-- hide_forced, not hide: a dequeue cycle in progress makes tooltip.hide()
		-- a no-op so multi-row previews survive the first row's expiry — which
		-- means turning the preview OFF left the rows the user just disabled
		-- sitting on screen until they timed out on their own.
		invalidate_pending_preview()
		tooltip.hide_forced()
	end
end

--- Enables or disables the AI prediction tooltip.
--- Delegates to the prediction engine which owns this flag.
--- @param v boolean
function M.set_preview_ai_enabled(v)
	engine.set_preview_ai_enabled(v)
end

--- Enables or disables all non-LLM preview tooltips simultaneously.
--- @param enabled boolean
function M.set_preview_enabled(enabled)
	is_star_preview_enabled        = (enabled == true)
	is_autocorrect_preview_enabled = (enabled == true)
	Logger.debug(LOG, "All hotstring tooltips: %s.", enabled and "on" or "off")
	if not enabled then
		-- hide_forced for the same reason as the per-kind setters above.
		invalidate_pending_preview()
		tooltip.hide_forced()
	end
end

--- Enables or disables background tinting for all tooltip types.
--- Delegates to the tooltip module, which is the single owner of colorization state.
--- @param v boolean
function M.set_preview_colored_tooltips(v)
	tooltip.set_colorization_enabled(v == true)
	Logger.debug(LOG, "Colored tooltips: %s.", v and "on" or "off")
	-- The hide clears the surface so the new tint applies to the next render; a
	-- render still waiting on its tick would repaint it with the old one.
	invalidate_pending_preview()
	tooltip.hide()
end

--- Overrides the accent tint for ★ hotstring tooltips.
--- @param color table|nil RGBA table, or nil to restore the default.
function M.set_preview_star_color(color)
	tooltip.set_accent_color("hotstring_star", color)
end

--- Overrides the accent tint for autocorrect hotstring tooltips.
--- @param color table|nil RGBA table, or nil to restore the default.
function M.set_preview_autocorrect_color(color)
	tooltip.set_accent_color("hotstring_autocorrect", color)
end

--- Overrides the accent tint for AI prediction tooltips.
--- @param color table|nil RGBA table, or nil to restore the default.
function M.set_preview_ai_color(color)
	engine.set_preview_ai_color(color)
end


-- =============================================
-- ===== 3.2) LLM Settings Forwarding ==========
-- =============================================
-- All LLM configuration is owned by the prediction engine; the bridge
-- forwards these calls so the menu's public API surface does not change.

function M.set_llm_enabled(v)               engine.set_llm_enabled(v)               end
function M.get_llm_enabled()                return engine.get_llm_enabled()          end
function M.set_llm_model(name)              engine.set_llm_model(name)              end
function M.set_llm_display_model_name(name) engine.set_llm_display_model_name(name) end
function M.set_llm_backend_name(label)      engine.set_llm_backend_name(label)      end
function M.set_llm_context_length(l)        engine.set_llm_context_length(l)        end
function M.set_llm_temperature(t)           engine.set_llm_temperature(t)           end
function M.set_llm_num_predictions(n)       engine.set_llm_num_predictions(n)       end
function M.set_llm_pred_indent(v)           engine.set_llm_pred_indent(v)           end
function M.set_llm_show_info_bar(v)         engine.set_llm_show_info_bar(v)         end
function M.set_llm_sequential_mode(v)       engine.set_llm_sequential_mode(v)       end
function M.set_llm_auto_raise_temp(v)       engine.set_llm_auto_raise_temp(v)       end
function M.set_llm_disabled_apps(apps)           engine.set_llm_disabled_apps(apps)           end
function M.set_llm_url_bar_filter_enabled(v)      engine.set_llm_url_bar_filter_enabled(v)      end
function M.set_llm_secure_field_filter_enabled(v) engine.set_llm_secure_field_filter_enabled(v) end
function M.set_llm_instant_on_word_end(v)         engine.set_llm_instant_on_word_end(v)         end
function M.set_llm_val_modifiers(mods)      engine.set_llm_val_modifiers(mods)      end
function M.set_llm_nav_modifiers(mods)      engine.set_llm_nav_modifiers(mods)      end
function M.set_llm_min_words(w)             engine.set_llm_min_words(w)             end
function M.set_llm_max_words(w)             engine.set_llm_max_words(w)             end
function M.set_llm_debounce(seconds)        engine.set_llm_debounce(seconds)        end
function M.set_llm_streaming(v)             engine.set_llm_streaming(v)             end
function M.set_llm_streaming_multi(v)       engine.set_llm_streaming_multi(v)       end

--- Sets the "chain LLM after hotstring" flag, owned here because
--- update_preview() consumes it directly.
--- @param v boolean
function M.set_llm_after_hotstring(v)
	fire_llm_after_hotstring = (v == true)
	Logger.debug(LOG, "LLM chain after hotstring: %s.", fire_llm_after_hotstring and "on" or "off")
end

--- Sets the "reset buffer on navigation" flag, owned here because
--- check_escape_reset() and check_nav_reset() consume it directly.
--- @param v boolean
function M.set_llm_reset_on_nav(v)
	reset_buffer_on_navigation = (v == true)
	Logger.debug(LOG, "Buffer reset on nav: %s.", reset_buffer_on_navigation and "yes" or "no")
end





-- ====================================
-- ====================================
-- ======= 4/ Hotstring Preview =======
-- ====================================
-- ====================================

--- What a preview ROW may show for a match's replacement.
---
--- Only values built from personal_info.toml carry a `field`, and only those are
--- ever masked: an ordinary hotstring has no field, is not in the declaration,
--- and passes through untouched. Note that this candidate-level gate is the
--- OPPOSITE default from the shared masker, which masks a nil field — deliberately
--- so, because there "no field" means provenance was lost on the way to the
--- bubble, while here it means the row was never personal-info to begin with.
---
--- DISPLAY ONLY. `m.repl` and `m.plain_repl` stay in clear and the expander reads
--- the registry entry through an entirely different call, so a masked row cannot
--- change what gets typed — which is the failure that matters most, because
--- typing a row of bullets into a bank form is silent, corrupts real data, and
--- looks exactly like the feature working.
--- @param m table A preview match record.
--- @return string What the row may render.
local function masked_for_preview(m)
	local value = m.plain_repl
	if type(value) ~= "string" or m.field == nil then return value end

	local ok, Fields = pcall(require, "infra.personal_info_fields")
	if not ok or type(Fields) ~= "table" or type(Fields.for_preview) ~= "function" then
		-- Fail closed. A match that declared itself a personal-info value and a
		-- classifier that cannot be reached is the one combination where showing
		-- the value is the wrong guess.
		Logger.error(LOG, "Field classification unavailable — withholding a personal-info preview.")
		return ("•"):rep(UNCLASSIFIED_PREVIEW_BULLETS)
	end
	return Fields.for_preview(value, m.field)
end


--- Arms one prediction-engine timer through its strict native ownership contract.
--- @param label string Diagnostic label.
--- @param fn function Engine timer method.
--- @param delay number|nil Optional delay override.
--- @return boolean committed True only when the delayed timer is running.
local function arm_llm_timer(label, fn, delay)
	local ok, result = xpcall(function()
		if delay ~= nil then return fn(delay) end
		return fn()
	end, debug.traceback)
	if not ok or result ~= true then
		Logger.error(LOG, "%s did not commit (result: %s).", tostring(label), tostring(result))
		return false
	end
	return true
end

--- Refreshes the preview tooltip from the current buffer content.
---
--- Decision tree:
---   1. Custom preview providers take precedence (registered externally).
---   2. Walk the static mappings looking for a trigger or star-trigger match.
---   3. If a match is found → show the hotstring tooltip (and optionally chain LLM).
---   4. Otherwise → reset predictions and arm the inactivity timer.
---
--- @param buf string The current typed buffer.
function M.update_preview(buf)
	if not require_state("update_preview") then return end

	-- Skip timer ops entirely when LLM is off: stop_timer()/start_timer() involve
	-- ObjC dispatch calls that add up on every keystroke even when the engine is idle
	local llm_on = M.is_runtime_available() and engine.get_llm_enabled()
	if llm_on then
		local stop_ok, stop_result = xpcall(engine.stop_timer, debug.traceback)
		if not stop_ok or stop_result ~= true then
			Logger.error(LOG, "LLM timer/stream cancellation did not commit (result: %s).", tostring(stop_result))
			-- Keep hotstring previews available, but never queue new LLM work behind a
			-- stream whose native capability could not be terminated. The next physical
			-- key retries this exact cancellation path.
			llm_on = false
		end
	end

	if not buf then
		Logger.debug(LOG, "Empty buffer — predictions cleared.")
		M.reset_predictions()
		return
	end
	local empty_buffer = #buf == 0

	-- When LLM is off and both preview toggles are off, no tooltip can ever be
	-- shown and no inactivity timer needs arming. The remaining work -- provider
	-- iteration, star/tail bucket scans, row building -- is pure per-keystroke
	-- waste on the latency-critical keymap tap. Providers are themselves gated
	-- by is_autocorrect_preview_enabled, so they can't surface a tooltip either.
	-- Reset predictions (clean up stale state) and return immediately.
	if not llm_on and not is_star_preview_enabled and not is_autocorrect_preview_enabled then
		M.reset_predictions()
		return
	end

	-- Empty and whitespace-ended buffers are both real prospective states: a bare
	-- magic mapping or a custom `" ★"` mapping can fire now. Do not run the LLM
	-- word-end branch until providers and the shared resolver have declined the
	-- buffer; returning here made the engine fire whitespace-base mappings that the
	-- tooltip could never advertise.
	local last_word = empty_buffer and "" or buf:match("([^%s]+)$")

	-- The expansion engine is hard-blocked during the rescan-suppression window
	-- that follows an expansion, so any hotstring row offered now names a trigger
	-- that CANNOT fire. The user pressed the validation key, nothing happened,
	-- and the window then wiped the buffer — the trigger was lost with no way to
	-- retry it except retyping the whole word. Read from the same CoreState field
	-- the tap tests, so the preview and the engine cannot disagree about whether
	-- a trigger is live. Custom providers above are unaffected: they do not go
	-- through the trigger engine.
	local epoch_fn = (hs and hs.timer and hs.timer.secondsSinceEpoch) or os.time
	local preview_now = epoch_fn()
	local engine_blocked = preview_now < (_state.no_rescan_until or 0)
	if engine_blocked then
		Logger.debug(LOG, "Preview: static mappings skipped — engine suppressed for %.3fs more.",
			(_state.no_rescan_until or 0) - epoch_fn())
	end

	-- Interceptor-backed providers run before the static engine on the real
	-- eventtap, so ask them first here too. Each provider owns the same prospective
	-- gate as its interceptor (including static-claim checks where applicable).
	-- When none claims the key, the static engine owns selection and the bridge
	-- consumes its records without scanning registry buckets or re-arbitrating.
	local matches = {}
	local winner_match = nil
	for _, provider in ipairs(_state.preview_providers) do
		-- The optional second result is an opaque action identity. It lets a
		-- side-effectful provider bind the successfully rendered row to the exact
		-- result its interceptor must later consume without changing the long-lived
		-- provider API's first (string) return value.
		local ok, res, provider_action_token = pcall(provider, buf)
		if ok and res then
			local provider_text = type(res) == "table" and res.text or res
			local action_token = provider_action_token
				or (type(res) == "table" and res.action_token or nil)
			if type(provider_text) ~= "string" or provider_text == "" then
				Logger.error(LOG, "Preview provider returned an invalid payload (%s).", type(provider_text))
				goto continue_provider
			end
			winner_match = {
				repl       = provider_text,
				plain_repl = provider_plain(provider_text),
				input      = nil,
				type       = "provider",
				group      = nil,
				-- Provider output is treated as private unconditionally. Both
				-- shipped providers resolve personal_info.toml content.
				is_private = true,
				is_winner  = true,
				validation_key = "magic",
				action_token = action_token,
			}
			matches[#matches + 1] = winner_match
			break
		end
		::continue_provider::
	end

	-- Literal autos created by a magic-key collision keep the ordinary timing
	-- gate. Resolve their remaining lifetime from the same CoreState function as
	-- the eventtap, and carry an absolute deadline through the deferred renderer
	-- so a 10 ms mapping cannot be advertised for the 50 ms UI minimum.
	local function literal_preview_allowed(mapping)
		if type(_state.mapping_delay_remaining) ~= "function" then return true, nil end
		local elapsed = math.max(0, preview_now - (_state.last_key_time or preview_now))
		-- The next magic-key event can itself be Shift/Alt-complex. Use the
		-- eventtap's maximum accepted window here; while the row is visibly
		-- committed its exact lease is the action-path authority. Without this,
		-- Shift+magic could still expand after the row had disappeared.
		return _state.mapping_delay_remaining(
			mapping, elapsed, tonumber(_state.COMPLEX_DELAY_MULT) or 1)
	end
	local resolution = #matches == 0 and not engine_blocked
		and expander.resolve_magic_action(buf, literal_preview_allowed) or nil
	if resolution and resolution.winner then
		for _, action in ipairs(resolution.candidates) do
			local mapping = action.mapping
			local match = {
				repl       = action.eff_repl,
				plain_repl = action.eff_plain,
				input      = action.kind == "star" and mapping.star_base or action.typed,
				type       = action.kind,
				group      = mapping.group,
				section    = mapping.section,
				has_magic  = mapping.has_magic,
				is_private = mapping.is_private,
				field      = mapping.field,
				mapping    = mapping,
				is_winner  = action == resolution.winner,
				-- Every action in this ledger was resolved for the question "what
				-- happens if magic is pressed now?", including end-char mappings.
				validation_key = "magic",
				expires_at = action.remaining_delay and (preview_now + action.remaining_delay) or nil,
			}
			matches[#matches + 1] = match
			if match.is_winner then winner_match = match end
		end
	end

	if #matches > 0 then
		if M.reset_predictions(true) ~= true then llm_on = false end

		-- Build tooltip rows (one per match). Exactly one record carries
		-- `is_winner`: the prospective resolver's engine winner. Every alternative
		-- is dimmed regardless of kind, so cross-kind collisions cannot create two
		-- simultaneously active promises.
		-- The key the user actually has to press to validate a star row. Read from
		-- CoreState, which also owns the prospective resolver's input: a hard-coded
		-- ★ told anyone who customised the magic key to press a
		-- character their layout no longer produces. The literal remains only as
		-- the fallback for a state that has not resolved one yet.
		local magic_key = (_state and _state.magic_key ~= nil and _state.magic_key ~= "")
			and _state.magic_key or ManifestReader.default_for("hotstrings.trigger_char")
		local rows          = {}
		local any_enabled   = false
		local min_timeout   = nil
		local primary_match = winner_match or matches[1]
		-- Re-order matches so end-char (↵) rows come first, then star (★) rows,
		-- then providers. End-char triggers usually have a shorter delay (the
		-- user types space/tab quickly) so they need maximum visibility on top.
		-- Preserves intra-group order, which is priority order from the registry.
		local ordered = {}
		local function append_kind(kind)
			for _, m in ipairs(matches) do
				if m.type == kind then ordered[#ordered + 1] = m end
			end
		end
		append_kind("autocorrect")
		append_kind("literal_auto")
		append_kind("star")
		append_kind("provider")

		local enabled_cache = {}
		local function preview_enabled(m)
			if enabled_cache[m] ~= nil then return enabled_cache[m] end
			local is_star = (m.type == "star")
			local enabled = is_star and is_star_preview_enabled
				or (not is_star and is_autocorrect_preview_enabled)
			if enabled and m.group and type(hotstrings_config.resolve) == "function" then
				local ok_cfg, cfg = pcall(function()
					return hotstrings_config.resolve(m.group, m.section)
				end)
				if ok_cfg and cfg and cfg.show_tooltip == false then enabled = false end
			end
			enabled_cache[m] = enabled == true
			return enabled_cache[m]
		end

		-- If the real winner is hidden, every remaining row is an action the engine
		-- will not choose. In that state the truthful surface is no surface at all.
		local winner_enabled = preview_enabled(primary_match)

		for _, m in ipairs(ordered) do
			local is_star = (m.type == "star")
			local validates_magic = m.validation_key == "magic"

			local tint_key
			if m.group == "personal" or m.group == "custom" or m.type == "provider" then
				tint_key = "hotstring_personal"
			elseif is_star then
				tint_key = "hotstring_star"
			else
				tint_key = "hotstring_autocorrect"
			end

			local enabled = winner_enabled and preview_enabled(m)

			-- Sized by the SAME precedence chain the engine uses to decide
			-- whether the trigger may still fire. The old three-way key
			-- (STAR_TRIGGER / autocorrection / dynamichotstrings) ignored
			-- per-section overrides and user-overridden group delays entirely, so
			-- the row could vanish while its trigger was still live — or linger
			-- after it had expired, offering an expansion the engine would refuse.
			-- Providers do not go through that chain and keep the group default.
			-- Resolver-owned star/end/provider actions are explicit magic-key
			-- actions: the engine does not expire them while the buffer is intact,
			-- so their truthful UI lifetime is infinite too. Only an ordinary
			-- literal auto that collides with a custom magic key retains a finite
			-- typing-speed deadline. A nil literal deadline means configured delay
			-- 0 (always active), not "already expired".
			local row_timeout = 0
			if m.type == "literal_auto" and m.expires_at then
				row_timeout = math.max(0, m.expires_at - epoch_fn())
				if row_timeout <= 0 then enabled = false end
			end

			if enabled then
				any_enabled = true
				if not min_timeout or row_timeout < min_timeout then
					min_timeout = row_timeout
				end
				rows[#rows + 1] = {
					-- Masked when the value is a declared secret, in full otherwise.
					-- Which fields are secrets, and how much of one stays visible, is
					-- _shared/modules/personal_info/fields.toml — read at runtime, so
					-- this driver holds no opinion of its own about it.
					text          = masked_for_preview(m),
					tint          = tooltip.tint(tint_key),
					-- This candidate came from resolve_magic_action (or a provider
					-- interceptor that runs on the same key). An autocorrection may also
					-- accept Enter, but advertising Enter is false whenever that
					-- terminator is disabled; magic is the action actually resolved.
					trigger_label = validates_magic and magic_key or "↵",
					dimmed        = not m.is_winner,
					duration      = row_timeout,
					expires_at    = m.expires_at,
					-- TooltipHotstring's canonical dequeue field is singular. Keep the
					-- bridge-local plural deadline above for pre-render validation, and
					-- hand the same absolute timestamp to the real dequeue so it neither
					-- applies the 50 ms floor nor treats a single row as non-dequeue.
					expire_at     = m.expires_at,
					lease_token   = m.is_winner and (m.action_token
						or (m.type == "literal_auto" and m.mapping)) or nil,
					on_expire     = m.type == "literal_auto" and m.is_winner and m.expires_at
						and function()
							_visible_magic_lease = nil
							if _state.buffer == buf then
								M.update_preview(buf)
							else
								M.reset_predictions(false)
							end
						end or nil,
				}
			end

			-- Same privacy contract as the expander's two expansion sinks: a private
			-- mapping's replacement AND its trigger are both secrets, and DEBUG is
			-- the driver's default level, so this line would otherwise write
			-- personal_info.toml content (phone, IBAN, SSN, card) into the 14-day log
			-- on every preview keystroke.
			--
			-- This used to add that the TOOLTIP still renders the value in full,
			-- because the user is looking at their own screen. That stopped being
			-- true on 2026-08-05: shoulder-surfing and screen sharing mean the screen
			-- is not only theirs, and the bubble's job — confirming WHICH value is
			-- about to be typed — needs the last four characters, not all of them. So
			-- the row above is masked for a declared secret. The two decisions are
			-- separate and both stand: the LOG withholds the row whole (trigger
			-- included, since a private trigger is a fragment of the secret), while
			-- the SCREEN shows a partial reveal. What is TYPED is unaffected by
			-- either.
			if m.is_private then
				Logger.debug(LOG, "Hotstring preview: private mapping matched (content withheld) [%s].", m.type)
			else
				Logger.debug(LOG, "Hotstring '%s' → '%s' [%s].",
					tostring(m.input), m.plain_repl, m.type)
			end
		end

		local tooltip_timeout = min_timeout or INFINITE_TOOLTIP_SEC
		tooltip.set_timeout(tooltip_timeout)

		local trigger_key = primary_match.input or last_word or buf
		local type_str    = primary_match.type == "star" and "star"
			or ((primary_match.type == "autocorrect" or primary_match.type == "literal_auto")
				and "autocorrect" or "personal")

		--- Arms the LLM timer appropriate for this match after its UI decision.
		local function arm_match_timer()
			-- Chain: arm the LLM timer so it fires just as the tooltip window closes.
			-- An intentionally hidden row has no finite surface to wait for, so it keeps
			-- the short offset without fabricating a visible suggestion record.
			if fire_llm_after_hotstring and llm_on then
				local chain_delay = (any_enabled and tooltip_timeout < INFINITE_TOOLTIP_SEC)
					and (tooltip_timeout + HOTSTRING_CHAIN_OFFSET_SEC)
					or HOTSTRING_CHAIN_OFFSET_SEC
				if arm_llm_timer("Hotstring-chain LLM timer", engine.start_timer, chain_delay) then
					Logger.debug(LOG, "LLM chain scheduled in %.3gs.", chain_delay)
					return true
				end
				return false
			elseif llm_on then
				-- update_preview stopped the inactivity timer at entry, so a matching
				-- trigger must re-arm it when chain-after-hotstring is disabled.
				if is_word_boundary(buf) then
					return arm_llm_timer("Matched word-end LLM timer", engine.start_timer_word_end)
				else
					return arm_llm_timer("Matched inactivity LLM timer", engine.start_timer)
				end
			end
			return true
		end

		--- Publishes state and telemetry for a physically committed preview.
		local function publish_visible_match()
			arm_match_timer()
			local action_token = primary_match.action_token or primary_match.mapping
			if primary_match.validation_key == "magic" and action_token then
				_visible_magic_lease = { action_token = action_token, buffer = buf }
			else
				_visible_magic_lease = nil
			end
			if last_shown_hotstring and last_shown_hotstring.trigger == trigger_key then return end
			-- is_private travels with the record because the DISMISS telemetry fires
			-- from reset_predictions, long after `matches` is gone — so the flag has
			-- to be carried, not looked up again.
			last_shown_hotstring = {
				trigger     = trigger_key,
				replacement = primary_match.repl,
				h_type      = type_str,
				is_private  = primary_match.is_private,
			}
			-- Off the HID thread. This is pure telemetry: nothing downstream depends
			-- on it landing before the keystroke completes, and it ends in a
			-- synchronous file write on the very callback whose overrun makes macOS
			-- disable the keyboard tap. The values are captured now so a later
			-- keystroke cannot change what gets recorded.
			--
			-- Withheld entirely for a private mapping, exactly as expander.lua
			-- withholds log_hotstring: both columns are secret — the replacement IS
			-- the IBAN and the trigger is a fragment of it — so redacting one and
			-- keeping the other still leaks. The DEBUG line sixty lines above names
			-- the persisted sink that must withhold the row whole; these two ARE
			-- that sink, and they were writing the value verbatim.
			-- docs/PROJECT_MEMORY.md records the same class shipping once before.
			if may_persist_preview(primary_match) then
				local t_key, t_repl, t_type = trigger_key, primary_match.repl, type_str
				local schedule_ok, telemetry_handle, telemetry_committed = xpcall(function()
					return TimerScheduler.after(0, function()
						pcall(keylogger.log_hotstring_suggested, nil, t_key, t_repl, t_type)
					end)
				end, debug.traceback)
				if not schedule_ok or telemetry_committed ~= true then
					Logger.error(LOG, "Hotstring suggestion telemetry could not be scheduled (result: %s).",
						tostring(telemetry_handle))
				end
			end
		end

		if any_enabled then
			-- Off the HID thread: see _preview_render_generation. One runloop tick
			-- is imperceptible for a preview; a blocked AX query on this thread is
			-- not — it can trip the tap-timeout that disables the keyboard tap.
			invalidate_pending_preview(true)
			local my_generation = _preview_render_generation
			local function render_preview()
				local callback_ok, callback_err = xpcall(function()
					if my_generation ~= _preview_render_generation then return end
					local render_now = epoch_fn()
					local live_rows = {}
					local live_timeout = nil
					local winner_expired = false
					for _, row in ipairs(rows) do
						local remaining = row.expires_at and (row.expires_at - render_now) or row.duration
						if row.expires_at and remaining <= 0 then
							if row.dimmed == false then winner_expired = true end
						else
							if row.expires_at then row.duration = remaining end
							live_rows[#live_rows + 1] = row
							if not live_timeout or row.duration < live_timeout then live_timeout = row.duration end
						end
					end
					if winner_expired then
						-- Re-resolve off the HID thread: a lower-priority star/end action may
						-- have become the winner exactly when the timed literal expired.
						if _state.buffer == buf then M.update_preview(buf) else M.reset_predictions(false) end
						return
					end
					if #live_rows == 0 then M.reset_predictions(false); return end
					tooltip_timeout = live_timeout or tooltip_timeout
					tooltip.set_timeout(tooltip_timeout)
					local render_result = tooltip.show_stacked(live_rows, true)
					if render_result ~= true then
						Logger.error(LOG, "Hotstring preview did not commit (result: %s).", tostring(render_result))
						if my_generation == _preview_render_generation then M.reset_predictions(false) end
						return
					end
					if my_generation ~= _preview_render_generation then return end
					publish_visible_match()
				end, debug.traceback)
				if not callback_ok then
					Logger.error(LOG, "Hotstring preview callback raised — visible surface revoked: %s",
						tostring(callback_err))
					if my_generation == _preview_render_generation then
						local cleanup_ok, cleanup_err = xpcall(function()
							M.reset_predictions(false)
						end, debug.traceback)
						if not cleanup_ok then
							Logger.error(LOG, "Hotstring preview failure cleanup raised: %s", tostring(cleanup_err))
						end
					end
				end
			end
			local schedule_ok, handle_or_err, render_committed = xpcall(function()
				return TimerScheduler.after(0, render_preview)
			end, debug.traceback)
			if not schedule_ok or render_committed ~= true then
				Logger.error(LOG, "Hotstring preview render could not be scheduled (result: %s).",
					tostring(handle_or_err))
				if my_generation == _preview_render_generation then
					local cleanup_ok, cleanup_err = xpcall(function()
						M.reset_predictions(false)
					end, debug.traceback)
					if not cleanup_ok then
						Logger.error(LOG, "Hotstring preview schedule-failure cleanup raised: %s",
							tostring(cleanup_err))
					end
				end
			end
		else
			-- No-row is deliberate (preview toggle or per-section show_tooltip=false).
			-- Preserve LLM scheduling, but do not claim a suggestion was displayed.
			if arm_match_timer() ~= true then
				M.reset_predictions(true)
			end
		end
	else
		-- No hotstring match — let the inactivity timer drive the LLM.
		if empty_buffer then
			Logger.debug(LOG, "Empty buffer — predictions cleared.")
			M.reset_predictions()
			return
		end
		local reset_committed = M.reset_predictions() == true
		if llm_on and reset_committed then
			local timer_committed
			if is_word_boundary(buf) then
				timer_committed = arm_llm_timer("No-match word-end LLM timer", engine.start_timer_word_end)
			else
				timer_committed = arm_llm_timer("No-match inactivity LLM timer", engine.start_timer)
			end
			if timer_committed then
				Logger.debug(LOG, "No hotstring for '%s' — LLM timer armed.", tostring(last_word))
			end
		end
	end
end




-- ================================================
-- ================================================
-- ======= 5/ Buffer & Keystroke Handlers ==========
-- ================================================
-- ================================================



-- ============================
-- ===== 5.1) Escape Trap =====
-- ============================

--- Arms a single persistent eventtap that intercepts Escape before it reaches the
--- underlying application, but only when a tooltip is actually visible.
--- Creating the tap on first use inserts it at the head of the macOS event tap chain
--- (kCGHeadInsertEventTap), so it fires before any pre-existing tap registered by apps
--- such as Raycast. Once armed, the trap runs permanently — no disarm needed.
--- The runtime check on tooltip.is_visible() handles all state transitions safely
--- without any lifecycle coupling to the tooltip show/hide flow.
---
--- WHY not recreate on every tooltip show: creating an eventtap is synchronous and
--- non-trivial. Doing so on every preview keystroke blows the macOS 50 ms HID-callback
--- budget on the NEXT keystroke, causing the triggering key to leak through to the
--- app (e.g. "hs★" → "hsammerspoon" because ★ reached the screen before our deletes).
local function escape_trap_enabled(trap)
	local trap_type = type(trap)
	if (trap_type ~= "table" and trap_type ~= "userdata")
		or type(trap.isEnabled) ~= "function" then
		return nil, "eventtap isEnabled() is unavailable"
	end
	local ok, enabled_or_err = xpcall(function()
		return trap:isEnabled()
	end, debug.traceback)
	if not ok then return nil, enabled_or_err end
	if type(enabled_or_err) ~= "boolean" then
		return nil, "eventtap isEnabled() returned " .. tostring(enabled_or_err)
	end
	return enabled_or_err, nil
end


--- Starts a candidate trap and verifies the native capability, not merely the Lua call.
--- @param trap table|userdata Candidate eventtap.
--- @return boolean committed True only when Quartz reports the tap enabled.
--- @return string|nil err Failure detail.
local function start_escape_trap(trap)
	local trap_type = type(trap)
	if (trap_type ~= "table" and trap_type ~= "userdata")
		or type(trap.start) ~= "function" then
		return false, "eventtap start() is unavailable"
	end
	local ok, start_err = xpcall(function()
		trap:start()
	end, debug.traceback)
	if not ok then return false, start_err end
	local enabled, enabled_err = escape_trap_enabled(trap)
	if enabled ~= true then return false, enabled_err or "eventtap remained disabled" end
	return true, nil
end


--- Best-effort cleanup for a candidate that never committed ownership.
--- @param trap table|userdata Candidate eventtap.
--- @return boolean stopped True only when the tap is verified disabled.
local function stop_escape_trap_candidate(trap)
	local trap_type = type(trap)
	if (trap_type ~= "table" and trap_type ~= "userdata")
		or type(trap.stop) ~= "function" then return false end
	local stop_ok = xpcall(function()
		trap:stop()
	end, debug.traceback)
	if not stop_ok then return false end
	local enabled = escape_trap_enabled(trap)
	return enabled == false
end


local function arm_escape_trap()
	if _escape_trap then
		local enabled, enabled_err = escape_trap_enabled(_escape_trap)
		if enabled == true then return true end
		if enabled == nil then
			Logger.error(LOG, "Escape trap state is unreadable; ownership not published: %s",
				tostring(enabled_err))
			return false
		end
		local restarted, restart_err = start_escape_trap(_escape_trap)
		if restarted then
			Logger.debug(LOG, "Escape trap re-armed after a disabled state.")
			return true
		end
		Logger.error(LOG, "Escape trap restart did not commit: %s", tostring(restart_err))
		return false
	end

	local create_ok, candidate_or_err = xpcall(function()
		return hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(event)
		local fence_events = nil
		local callback_ok, consume_or_err, returned_events = xpcall(function()
			local provenance, status, fence = EventProvenance.classify_with_fence(
				event, "llm.escape_trap")
			fence_events = fence and fence.events or nil
			local function finish(consume) return consume == true, fence_events end
			if provenance ~= nil or status == EventProvenance.STATUS_UNREADABLE then
				return finish(false)
			end
			local key_ok, keycode = pcall(event.getKeyCode, event)
			if not key_ok or keycode ~= KEYCODE_ESCAPE then return finish(false) end
			if not M.is_runtime_available() then
				-- Hotstring previews remain a valid non-LLM feature during quarantine.
				-- Dismiss only that surface; stale LLM state is logically invisible and
				-- must never make Escape consume an application keystroke.
				if type(tooltip.is_hotstring_visible) == "function"
					and tooltip.is_hotstring_visible() then
					local scheduled = SyntheticInput.defer_after_callback(
						"hotstring Escape dismissal", function()
							invalidate_pending_preview()
							local hide = tooltip.hide_forced_silent or tooltip.hide_forced
							if type(hide) == "function" then hide() end
						end)
					return finish(scheduled)
				end
				return finish(false)
			end
			-- Let Escape through when no tooltip is on screen — Raycast (or the system)
			-- should handle it normally in that case.
			if not tooltip.is_visible() then return finish(false) end
			local scheduled = SyntheticInput.defer_after_callback(
				"LLM Escape dismissal", function()
					if not M.is_runtime_available() or not tooltip.is_visible() then return end
					Logger.debug(LOG, "Escape trap — Escape consumed, tooltip dismissed.")
					M.reset_predictions()
				end)
			return finish(scheduled)
		end, debug.traceback)
		if not callback_ok then
			Logger.error(LOG, "Escape trap callback raised; event passed through: %s", tostring(consume_or_err))
			return false, fence_events
		end
		return consume_or_err == true, returned_events
		end)
	end, debug.traceback)
	local candidate_type = type(candidate_or_err)
	if not create_ok or (candidate_type ~= "table" and candidate_type ~= "userdata") then
		Logger.error(LOG, "Escape trap creation did not commit: %s", tostring(candidate_or_err))
		return false
	end

	local candidate = candidate_or_err
	local started, start_err = start_escape_trap(candidate)
	if not started then
		local stopped = stop_escape_trap_candidate(candidate)
		if not stopped then
			-- Never lose the only handle to a candidate whose native state could not
			-- be proven disabled. M.stop() and the next show can retry its teardown.
			_escape_trap = candidate
		end
		Logger.error(LOG, "Escape trap start did not commit: %s", tostring(start_err))
		return false
	end

	_escape_trap = candidate
	Logger.debug(LOG, "Escape trap armed (persistent).")
	return true
end



--- Schedules one coalesced surface hide while the full LLM runtime is closed.
--- Canvas work stays off the eventtap; a later hotstring preview scheduled on the
--- same run-loop tick renders after this hide and remains fully available.
local function schedule_quarantine_surface_hide()
	if _quarantine_hide_pending then return end
	_quarantine_hide_pending = true
	local ok, handle_or_err, committed = pcall(TimerScheduler.after, 0, function()
		_quarantine_hide_pending = false
		if not M.is_runtime_available() then
			local hide = tooltip.hide_forced_silent or tooltip.hide_forced
			if type(hide) == "function" then pcall(hide) end
		end
	end)
	if not ok or committed ~= true then
		_quarantine_hide_pending = false
	end
end


--- Clears prediction state, optionally bypassing the action-epoch runtime gate.
--- @param keep_hotstring_log boolean When true, skips dismiss telemetry.
--- @param force_full boolean True only for the async action-epoch reconciler.
--- @return boolean full_reset True when engine.reset ran.
local function reset_predictions_impl(keep_hotstring_log, force_full)
	-- A preview render requested a tick ago must not land after this reset and
	-- put the tooltip back on screen.
	invalidate_pending_preview()
	if not keep_hotstring_log and last_shown_hotstring then
		-- Deferred and pcall'd, exactly like the log_hotstring_suggested sibling a
		-- few hundred lines up. That one was moved off the HID thread and this one
		-- was not, because the deferral was applied per call site instead of at the
		-- sink — so the telemetry writer still ran an open/write/flush inside the
		-- keyDown tap on every dismissal.
		--
		-- The pcall matters for a second reason, and it is not about the throw being
		-- silent: on the keyDown and mouse paths it is logged. It is about STATE. A
		-- throw here skipped both `last_shown_hotstring = nil` below and
		-- `engine.reset()`, leaving the tooltip state and the engine live, so every
		-- later reset re-emitted the same stale dismiss event. The Escape trap path
		-- has no pcall of its own, so there it was silent as well.
		--
		-- The values are captured NOW: a later keystroke must not change what gets
		-- recorded, and the field is cleared immediately below.
		local dismissed = last_shown_hotstring
		local d_trigger = dismissed.trigger
		local d_repl    = dismissed.replacement
		local d_type    = dismissed.h_type
		-- Relinquish the record before crossing the fallible scheduler boundary.
		-- Telemetry is best-effort; engine teardown is the user-visible contract.
		last_shown_hotstring = nil
		-- Withheld for a private mapping, like its suggested sibling. This one is
		-- the easier of the two to miss: the value was captured on a keystroke that
		-- has already happened, and the record outlives the match it came from.
		if may_persist_preview(dismissed) then
			local schedule_ok, handle_or_err, telemetry_committed = xpcall(function()
				return TimerScheduler.after(0, function()
					pcall(keylogger.log_hotstring_dismissed, nil, d_trigger, d_repl, d_type)
				end)
			end, debug.traceback)
			if not schedule_ok or telemetry_committed ~= true then
				Logger.error(LOG, "Hotstring dismissal telemetry could not be scheduled (result: %s).",
					tostring(handle_or_err))
			end
		end
	end
	if not force_full and not M.is_runtime_available() then
		schedule_quarantine_surface_hide()
		return false
	end
	local reset_ok, reset_result = xpcall(engine.reset, debug.traceback)
	if not reset_ok or reset_result ~= true then
		Logger.error(LOG, "Prediction-engine reset did not commit (result: %s).", tostring(reset_result))
		return false
	end
	return true
end


--- Reconciles an observation gap after the key event callback has returned.
--- The HID path first closes the O(1) runtime latch with
--- set_runtime_quarantined(true); this function performs canvas/timer/task work
--- later and reopens only that explicit latch. A newer action epoch remains
--- independently closed by the exact _safe_action_epoch comparison.
--- @return boolean True after the full reset completed.
function M.reconcile_observation_gap()
	if reset_predictions_impl(false, true) ~= true then return false end
	M.set_runtime_quarantined(false)
	return true
end


--- Performs the off-eventtap surface/engine cleanup for a context that must
--- remain quarantined (for example an ignored or not-yet-classified window).
--- Unlike reconcile_observation_gap(), this never reopens runtime interaction.
--- @return boolean True after the full reset committed.
function M.reset_quarantined_context()
	return reset_predictions_impl(false, true)
end


--- Clears all active predictions and optionally emits hotstring-dismissed telemetry.
--- During an action-epoch quarantine this only invalidates hotstring/surface state;
--- the throwing full engine reset is reserved for the async reconciler.
--- @param keep_hotstring_log boolean When true, skips the dismiss telemetry event.
--- @return boolean full_reset True when engine.reset ran.
function M.reset_predictions(keep_hotstring_log)
	return reset_predictions_impl(keep_hotstring_log, false)
end


--- Performs a force-full reset for module teardown without reopening runtime gates.
--- Unlike an ordinary user reset, this must work while an action epoch is
--- quarantined; the listener that could reconcile that epoch is being removed.
--- @return boolean committed True when engine teardown completed.
function M.reset_for_teardown()
	return reset_predictions_impl(false, true)
end


--- Performs the full reset for one exact action token outside the eventtap.
--- Success opens the runtime only if no newer action arrived while reset ran.
--- @param epoch table Opaque SyntheticInput action token.
--- @return boolean current True when this exact epoch became safe.
function M.reset_for_action_epoch(epoch)
	M.observe_action_epoch(epoch)
	if epoch ~= SyntheticInput.current_action_epoch() then return false end
	if reset_predictions_impl(false, true) ~= true then return false end
	if epoch ~= SyntheticInput.current_action_epoch() then return false end
	_safe_action_epoch = epoch
	_runtime_quarantined = false
	return true
end

--- Applies the selected prediction: issues deletions, types the completion,
--- updates the in-memory buffer, and arms the chained LLM request.
--- @param idx number 1-based index of the prediction to apply.
--- @return boolean True when the prediction was successfully applied.
function M.apply_prediction(idx)
	if not require_state("apply_prediction") then return false end
	if not M.is_runtime_available() then return false end

	local pred, all_preds = engine.consume(idx)
	if not pred then return false end

	local delete_count = pred.deletes or 0
	local text_to_type = pred.to_type or ""

	-- Resolve overlap between the buffer tail and the prediction to prevent ghost-text
	-- duplication when the user is mid-word (e.g. typed "tex", prediction starts with "texte").
	-- Also enforces correct spacing at the join point as a safety net for cases the
	-- parser may not have handled (e.g. raw-mode output with no leading space).
	-- This call was accidentally dropped during the 183effff refactor.
	local ok_overlap, res_deletes, res_text = pcall(
		km_utils.resolve_prediction_overlap, _state.buffer, delete_count, text_to_type)
	if not ok_overlap or res_deletes == nil or res_text == nil then
		Logger.error(LOG, "Prediction overlap resolution failed; output rejected before injection: %s",
			tostring(ok_overlap and "invalid nil result" or res_deletes))
		local cleanup_ok, cleanup_result = xpcall(M.reset_predictions, debug.traceback)
		if not cleanup_ok or cleanup_result ~= true then
			Logger.error(LOG, "Prediction overlap failure cleanup did not commit (result: %s).",
				tostring(cleanup_result))
		end
		return false
	end
	delete_count = res_deletes
	text_to_type = res_text

	Logger.start(LOG, "Applying prediction #%d: '%s' (%d deletion(s)).",
		idx, tostring(text_to_type), delete_count)

	-- Capture the text about to be erased for telemetry.
	local deleted_text = ""
	if delete_count > 0 and type(_state.buffer) == "string" and #_state.buffer > 0 then
		local ok, offset = pcall(utf8.offset, _state.buffer, -delete_count)
		if ok and offset then deleted_text = _state.buffer:sub(offset) end
	end

	local reset_ok, reset_result = xpcall(function()
		return M.reset_predictions()
	end, debug.traceback)
	if not reset_ok then
		Logger.error(LOG, "Prediction acceptance reset raised before output: %s", tostring(reset_result))
		return false
	end
	local cleanup_committed = reset_result == true
	if not cleanup_committed then
		-- engine.consume() already fenced the accepted generation, so preserving the
		-- user's requested text is safe. Do not chain another request behind native
		-- work that failed to terminate; retry cleanup after this callback instead.
		Logger.error(LOG, "Prediction acceptance cleanup remains incomplete; text will apply without chaining.")
	end

	-- Route through the single injection choke point so deletion, text and paste
	-- events share one immutable generation and owner — the same transaction path
	-- used by hotstring expansion.
	-- is_final=true: suppress hotstring re-scan after LLM accept.
	-- is_ignored=true: reset_predictions() already hid the tooltip; the F16 chain
	--   signal (injected below) handles the next prediction — do not arm the LLM
	--   inactivity timer or trigger update_preview here.
	local replaced = expander.perform_text_replacement(
		delete_count,
		function() return km_utils.emit_text(text_to_type) end,
		function()
			-- Sync the in-memory buffer to reflect the accepted completion. Tagged
			-- transaction events already carry their provenance independently of
			-- whether the text path used direct key pairs or Cmd+V.
			if delete_count == 0 then
				_state.buffer = _state.buffer .. text_to_type
			else
				local ok, start_pos = pcall(utf8.offset, _state.buffer, -delete_count)
				if not ok or not start_pos or delete_count >= #_state.buffer then
					start_pos = 1
				end
				_state.buffer = (_state.buffer:sub(1, start_pos - 1) or "") .. text_to_type
			end
		end,
		true,   -- is_final
		true,   -- is_ignored
		"llm"
	)
	if not replaced then
		Logger.error(LOG, "Prediction #%d could not be injected; action was not accepted.", idx)
		return false
	end
	local telemetry_ok, telemetry_err = xpcall(function()
		keylogger.log_llm_accepted(text_to_type, nil, all_preds, idx, delete_count, deleted_text)
	end, debug.traceback)
	if not telemetry_ok then
		Logger.error(LOG, "Prediction acceptance telemetry raised after text commit: %s", tostring(telemetry_err))
	end

	Logger.success(LOG, "Prediction #%d applied — buffer updated.", idx)

	-- Chain trigger: F16 is injected after all deletions and text keystrokes.
	-- The HID event queue is ordered, so by the time handle_llm_keys() sees F16,
	-- all previous keystrokes have been delivered to the target application.
	-- engine.arm_chain() sets a fallback timer in case F16 is somehow missed.
	-- F16 (not F15) so the script-control kill-switch keycode stays exclusive.
	if not cleanup_committed then
		local retry_ok, retry_handle, retry_committed = xpcall(function()
			return TimerScheduler.after(0, function()
				local callback_ok, callback_result = xpcall(function()
					return M.reset_predictions(true)
				end, debug.traceback)
				if not callback_ok or callback_result ~= true then
					Logger.error(LOG, "Deferred post-accept cleanup did not commit (result: %s).",
						tostring(callback_result))
				end
			end)
		end, debug.traceback)
		if not retry_ok or retry_committed ~= true then
			Logger.error(LOG, "Post-accept cleanup retry could not be scheduled (result: %s).",
				tostring(retry_handle))
		end
		return true
	end

	local arm_ok, arm_result = xpcall(engine.arm_chain, debug.traceback)
	if not arm_ok or arm_result ~= true then
		Logger.error(LOG, "Prediction applied, but LLM chain ownership did not commit (result: %s).",
			tostring(arm_result))
		return true
	end
	local signal_ok, signal_result = xpcall(function()
		return SyntheticInput.emit_loopback_key_stroke(
			{}, Keycodes.to_name(Keycodes.F16_LLM_CHAIN_SIGNAL), 0)
	end, debug.traceback)
	if not signal_ok or signal_result ~= true then
		Logger.error(LOG, "Prediction applied; F16 signal failed, so the owned fallback remains active (result: %s).",
			tostring(signal_result))
		return true
	end
	Logger.debug(LOG, "F16 signal sent — LLM chain pending.")
	return true
end

--- Routes keystrokes that interact with the prediction pipeline.
--- Called from the main eventtap before any buffer logic runs.
--- Returns true to consume the event and prevent it from reaching the buffer.
--- @param keyCode number The macOS key code of the pressed key.
--- @param flags table The active modifier flags.
--- @param is_ignored boolean True when the current app is on the keymap ignore list.
--- @return boolean True when the event was consumed by the prediction pipeline.
function M.handle_llm_keys(keyCode, flags, is_ignored)
	if not M.is_runtime_available() then return false end
	-- F16: precise "typing complete" signal sent by apply_prediction().
	if engine.handle_chain_signal(keyCode) then return true end

	-- Always handle navigation when predictions are on screen, even in keymap-ignored apps
	-- (e.g. Raycast): the user must be able to navigate/dismiss the tooltip regardless of context.
	-- The is_ignored flag only suppresses hotstring expansion and buffer tracking, not LLM interaction.
	if not engine.is_visible() then return false end

	local preds = engine.get_predictions()

	-- Arrow keys navigate through the prediction list.
	-- We must consume the event so the main eventtap does not call check_nav_reset()
	-- which would clear the buffer and dismiss the tooltip.
	if keyCode >= KEYCODE_ARROW_MIN and keyCode <= KEYCODE_ARROW_MAX and #preds > 1 then
		if core_llm.check_modifiers(flags, engine.get_navigation_mods()) then
			local delta = (keyCode == KEYCODE_ARROW_MIN or keyCode == KEYCODE_ARROW_MAX - 1) and -1 or 1
			Logger.debug(LOG, "Prediction navigation: %+d.", delta)
			engine.navigate(delta)
			return true
		end
	end

	-- Tab immediately accepts prediction #1, cancelling any in-flight streaming for
	-- the other slots. This lets the user grab the first result as soon as it appears
	-- without waiting for all parallel predictions to complete.
	if keyCode == KEYCODE_TAB then
		Logger.debug(LOG, "Tab — fast-accepting prediction #1.")
		if not M.apply_prediction(1) then M.reset_predictions() end
		return true
	end

	-- Return / Enter accepts the currently highlighted prediction.
	if keyCode == KEYCODE_RETURN or keyCode == KEYCODE_ENTER then
		local idx = engine.get_current_index() or 1
		Logger.debug(LOG, "Return — accepting prediction #%d.", idx)
		if not M.apply_prediction(idx) then M.reset_predictions() end
		return true
	end

	-- Modifier+digit selects a prediction by position (e.g., alt+2 → second prediction).
	if #preds > 1 and core_llm.check_modifiers(flags, engine.get_validation_mods()) then
		local n = KEYCODE_DIGITS[keyCode]
		if n and n <= #preds then
			Logger.debug(LOG, "Direct selection — prediction #%d.", n)
			return M.apply_prediction(n)
		end
	end

	return false
end

--- Handles Escape: dismisses any visible tooltip (hotstring, LLM loading indicator, or
--- AI predictions), consuming the event so it never reaches the underlying application.
--- Without this, apps like Raycast receive the Escape and reset their own state.
--- @return boolean True when a tooltip was visible and the event was consumed.
function M.check_escape_reset()
	if not require_state("check_escape_reset") then return false end
	if not M.is_runtime_available() then
		if reset_buffer_on_navigation then _state.buffer = "" end
		if type(tooltip.is_hotstring_visible) == "function"
			and tooltip.is_hotstring_visible() then
			invalidate_pending_preview()
			local hide = tooltip.hide_forced_silent or tooltip.hide_forced
			if type(hide) == "function" then pcall(hide) end
			return true
		end
		return false
	end

	-- Use tooltip.is_visible() rather than engine.is_visible() so we also catch
	-- the LLM loading spinner and hotstring previews, which are shown through the
	-- tooltip module but do not set the prediction-engine "visible" flag.
	if tooltip.is_visible() then
		Logger.debug(LOG, "Escape — tooltip dismissed.")
		M.reset_predictions()
		return true
	end
	if reset_buffer_on_navigation then
		Logger.debug(LOG, "Escape — buffer cleared.")
		_state.buffer = ""
	end
	M.reset_predictions()
	return false
end

--- Handles navigation keys (arrows, Enter, mouse) outside prediction mode.
--- Optionally clears the buffer depending on the reset_buffer_on_navigation flag.
function M.check_nav_reset()
	if not require_state("check_nav_reset") then return end

	if reset_buffer_on_navigation and _state.buffer ~= "" then
		Logger.debug(LOG, "Buffer cleared on navigation.")
		_state.buffer = ""
	end
	M.reset_predictions()
end





-- =============================
-- =============================
-- ======= 6/ Module API =======
-- =============================
-- =============================

--- Delegates to the prediction engine for callers that reference _perform_llm_check.
--- @param force_trigger boolean When true, bypasses freshness and word-count guards.
--- @param profile_name string|nil Optional profile label shown in the info bar.
function M._perform_llm_check(force_trigger, profile_name)
	if not M.is_runtime_available() then return end
	engine.perform_check(force_trigger, profile_name)
end

--- Re-arms the LLM inactivity timer.
--- Called by the expander after a text replacement to trigger a fresh prediction.
function M.start_timer()
	if not M.is_runtime_available() then return false end
	return arm_llm_timer("Public inactivity LLM timer", engine.start_timer)
end

--- Initializes the bridge with the shared CoreState and keymap defaults.
--- Must be called exactly once before any other public function in this module.
--- @param core_state table The shared state object from keymap/init.lua.
--- @param keymap_defaults table The DEFAULT_STATE table from keymap/init.lua.
function M.init(core_state, keymap_defaults)
	Logger.start(LOG, "Initializing LLM bridge…")

	if type(core_state) ~= "table" then
		Logger.error(LOG, "M.init(): core_state must be a table (got %s) — bridge non-functional.", type(core_state))
		return
	end
	if type(keymap_defaults) ~= "table" then
		Logger.error(LOG, "M.init(): keymap_defaults must be a table (got %s) — bridge non-functional.", type(keymap_defaults))
		return
	end

	if _state then
		Logger.warn(LOG, "M.init() called more than once — ignoring duplicate call.")
		return
	end

	_state = core_state
	if type(engine.set_runtime_guard) == "function" then
		engine.set_runtime_guard(M.is_runtime_available)
	end
	if type(tooltip.set_runtime_guard) == "function" then
		tooltip.set_runtime_guard(M.is_runtime_available)
	end
	engine.init(core_state)

	-- Seed preview toggles from the canonical keymap defaults.
	-- The menu will override these values at startup via set_preview_*_enabled().
	is_star_preview_enabled        = (keymap_defaults.preview_star_enabled        ~= false)
	is_autocorrect_preview_enabled = (keymap_defaults.preview_autocorrect_enabled ~= false)

	Logger.success(LOG, "LLM bridge initialized (buffer: '%s', %d mapping(s)).",
		tostring(_state.buffer or ""), #(_state.mappings or {}))
end

--- Stops the persistent Escape trap event tap and releases the reference.
--- Must be called from keymap/init.lua M.stop() so that Escape is not
--- intercepted after the module is unloaded (escape-trap-ghost-tap).
function M.stop()
	if not _escape_trap then return true end
	local trap = _escape_trap
	local trap_type = type(trap)
	if (trap_type ~= "table" and trap_type ~= "userdata") or type(trap.stop) ~= "function" then
		Logger.error(LOG, "Escape trap stop() is unavailable; handle retained for retry.")
		return false
	end
	local stop_ok, stop_err = xpcall(function()
		trap:stop()
	end, debug.traceback)
	if not stop_ok then
		Logger.error(LOG, "Escape trap stop raised; handle retained for retry: %s", tostring(stop_err))
		return false
	end
	local enabled, enabled_err = escape_trap_enabled(trap)
	if enabled ~= false then
		Logger.error(LOG, "Escape trap stop did not commit; handle retained for retry: %s",
			tostring(enabled_err or ("isEnabled=" .. tostring(enabled))))
		return false
	end
	_escape_trap = nil
	Logger.debug(LOG, "Escape trap stopped.")
	return true
end

-- Wire tooltip callbacks so the tooltip module can call back into the bridge.
-- Closures ensure the functions are resolved at call time, not at bind time.
if type(tooltip.set_accept_callback) == "function" then
	tooltip.set_accept_callback(function(idx) return M.apply_prediction(idx) end)
end
if type(tooltip.set_cancel_callback) == "function" then
	tooltip.set_cancel_callback(function() return M.reset_predictions() end)
end
-- Create the persistent Escape trap the first time any tooltip appears.
-- This guarantees the tap is inserted at HEAD after Raycast (or any other app) has
-- already registered its own tap, so our Escape always takes priority while a tooltip
-- is visible. The trap is never destroyed — tooltip.is_visible() drives its behaviour.
if type(tooltip.set_on_show_callback) == "function" then
	tooltip.set_on_show_callback(arm_escape_trap)
end

return M
