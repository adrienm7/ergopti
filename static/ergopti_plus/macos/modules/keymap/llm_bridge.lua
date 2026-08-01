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
local keyStroke = hs.eventtap.keyStroke

local km_utils         = require("modules.keymap.utils")
local EventTapGuard = require("adapters.event_tap_guard")
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

-- When a delay is 0 it means "never auto-dismiss the tooltip"; we substitute a
-- concrete 24h timeout so the tooltip module always receives a valid number.
local INFINITE_TOOLTIP_SEC       = 86400  -- 24h stand-in for "never auto-dismiss"
local MIN_TOOLTIP_DURATION_SEC   = 0.05   -- Shortest visible duration for any hotstring tooltip
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

-- Canonical LLM defaults, owned by modules/llm; used to seed bridge-local flags.
local LLM_DEFAULTS = core_llm.DEFAULT_STATE





-- ================================
-- ================================
-- ======= 2/ Mutable State =======
-- ================================
-- ================================

-- The most recently shown hotstring suggestion; kept for dismissal telemetry.
local last_shown_hotstring = nil

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

--- Invalidates any preview render still waiting on its deferral tick.
--- Called wherever the tooltip is hidden or the predictions reset, so a render
--- requested moments earlier cannot land afterwards.
local function invalidate_pending_preview()
	_preview_render_generation = _preview_render_generation + 1
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
-- expander.would_fire, so there is one rule and nothing left to keep in sync.

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
	local llm_on = engine.get_llm_enabled()
	if llm_on then engine.stop_timer() end

	if not buf or #buf == 0 then
		Logger.debug(LOG, "Empty buffer — predictions cleared.")
		M.reset_predictions()
		return
	end

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

	local last_word = buf:match("([^%s]+)$")
	if not last_word then
		M.reset_predictions()
		-- Buffer ends with whitespace: the user just finished a word or sentence.
		-- start_timer_word_end() bypasses the debounce when instant_on_word_end is on.
		if llm_on then engine.start_timer_word_end() end
		return
	end

	-- Collect all matching candidates: provider match first, then star, then
	-- autocorrect. Both star and autocorrect are kept when both match the same
	-- buffer so the stacked tooltip can show all options simultaneously.
	local matches = {}   -- array of { repl, plain_repl, input, type, group, is_private }

	-- Custom preview providers take precedence over the static mapping lookup.
	for _, provider in ipairs(_state.preview_providers) do
		local ok, res = pcall(provider, buf)
		if ok and res then
			matches[#matches + 1] = {
				repl       = res,
				plain_repl = provider_plain(res),
				input      = nil,
				type       = "provider",
				group      = nil,
				-- Provider output is treated as private unconditionally. Both
				-- registered providers resolve personal_info.toml content
				-- (dynamic_hotstrings personal_info and rules_engine), and the
				-- registration API carries no privacy metadata — so defaulting to
				-- "withhold" is the only choice under which a future provider
				-- cannot leak a secret into the 14-day log by omission. The cost
				-- is a less detailed DEBUG line; nothing functional depends on it.
				is_private = true,
			}
			break
		end
	end

	-- The expansion engine is hard-blocked during the rescan-suppression window
	-- that follows an expansion, so any hotstring row offered now names a trigger
	-- that CANNOT fire. The user pressed the validation key, nothing happened,
	-- and the window then wiped the buffer — the trigger was lost with no way to
	-- retry it except retyping the whole word. Read from the same CoreState field
	-- the tap tests, so the preview and the engine cannot disagree about whether
	-- a trigger is live. Custom providers above are unaffected: they do not go
	-- through the trigger engine.
	local epoch_fn = (hs and hs.timer and hs.timer.secondsSinceEpoch) or os.time
	local engine_blocked = epoch_fn() < (_state.no_rescan_until or 0)
	if engine_blocked then
		Logger.debug(LOG, "Preview: static mappings skipped — engine suppressed for %.3fs more.",
			(_state.no_rescan_until or 0) - epoch_fn())
	end

	-- Walk static mappings via the tail-char indexes.
	if #matches == 0 and not engine_blocked then
		-- Guard against malformed UTF-8: LuaJIT raises a C-level error on bad sequences
		local ok_poff, poff = pcall(utf8.offset, buf, -1)
		if not ok_poff then poff = nil end
		local buf_tail_char = poff and buf:sub(poff) or ""

		local function group_active(mapping)
			return not mapping.group
				or not _state.groups[mapping.group]
				or _state.groups[mapping.group].enabled
		end

		local repeat_enabled = _state.is_repeat_feature_enabled()
		local function is_repetition_star(mapping, star_base)
			if not repeat_enabled then return false end
			-- Guard against malformed UTF-8: LuaJIT raises a C-level error on bad sequences
			local ok_rep, offset = pcall(utf8.offset, star_base, -1)
			if not ok_rep or not offset then return false end
			return mapping.plain_repl == star_base .. star_base:sub(offset)
		end

		-- Star matches (magic-key triggers) — collect EVERY trigger whose star_base
		-- matches the buffer end. The bucket is pre-sorted longest-first by the
		-- registry, so the first collected match is the one the engine will
		-- actually fire; the rest are alternatives shown dimmed + strikethrough.
		-- The buffer the engine will actually match against once ★ is pressed. The
		-- preview must ask about THAT buffer, not the current one, or it is
		-- answering a different question than the engine will be asked.
		-- Built only when the star bucket has something to match against. This is
		-- a string concatenation on every keystroke, and the overwhelmingly common
		-- case is an empty bucket — so the allocation was pure waste on the
		-- latency-critical path for all but a handful of keys.
		local star_bucket = Registry.mappings_for_star_tail(buf_tail_char)
		local star_buf = star_bucket and (buf .. (_state.magic_key or "")) or nil
		if star_bucket then
			for _, mapping in ipairs(star_bucket) do
				if group_active(mapping) then
					local star_base = mapping.star_base
					-- Single source of truth: this is the very function
					-- try_auto_expand calls to decide whether to fire and what to
					-- emit. Re-deriving the answer here is what let the tooltip
					-- promise expansions the engine then refused — most visibly at
					-- the buffer start, where the old local check allowed any match
					-- while the engine consulted start_is_word_boundary.
					local eff_plain, _typed, eff_repl = expander.would_fire(mapping, star_buf)
					if eff_plain and star_base and star_base ~= ""
						-- Display-only filter: such a mapping expands to the base with
						-- its last letter doubled, which is byte-identical to what the
						-- repeat key produces. The row would be a duplicate of an
						-- outcome the user already understands, and suppressing it
						-- cannot make the tooltip disagree with the engine — the text
						-- that reaches the screen is the same either way.
						and not is_repetition_star(mapping, star_base)
					then
						matches[#matches + 1] = {
							repl       = eff_repl,
							plain_repl = eff_plain,
							input      = star_base,
							type       = "star",
							group      = mapping.group,
							-- Carried so the row's lifetime can be resolved through
							-- the same precedence chain the engine applies.
							section    = mapping.section,
							has_magic  = mapping.has_magic,
							-- Carried so the DEBUG sink below can honour the same
							-- privacy contract the expander applies (acc7946fc).
							is_private = mapping.is_private,
						}
					end
				end
			end
		end

		-- Autocorrect matches — same logic: collect every trigger whose body
		-- matches, sorted longest-first by the registry. The first is what
		-- fires; the rest are alternatives.
		local tail_bucket = Registry.mappings_for_tail(buf_tail_char)
		if tail_bucket then
			for _, mapping in ipairs(tail_bucket) do
				local ga = group_active(mapping)
				-- Only offer a mapping some FUTURE keystroke can still fire.
				--
				-- update_preview is reached only when no expansion fired this
				-- keystroke (keymap/init.lua). So seeing a complete `auto` trigger at
				-- the buffer end means the engine already had its one chance and
				-- declined — typically because mapping_fires' typing-speed gate
				-- rejected it. Nothing can retry it either: the auto path matches on
				-- the trigger's tail being the character just typed, and any further
				-- keystroke pushes the trigger off the end of the buffer.
				--
				-- Such a row promised an expansion no keystroke could produce. A
				-- non-auto mapping is different: it waits for a terminator, and ★
				-- validates it with the delay bypassed — so it stays offerable.
				local c2 = not mapping.auto
				if ga and c2 then
					-- Same single source of truth as the star bucket above. This
					-- replaces a second, independent reimplementation of the engine's
					-- case-conform resolution and word-boundary rules — the copy that
					-- had to be kept in sync by hand and was not.
					local matched_plain, matched_input = expander.would_fire(mapping, buf)
					-- Gated on the RESOLVED replacement, not on the typed text. A
					-- no-op mapping returns (nil, typed, nil, true) — nil expansion
					-- but a perfectly truthy second value — so gating on the input
					-- built a row whose text was nil. render_stacked then threw and
					-- took the ENTIRE preview stack down with it, so one no-op
					-- mapping silently erased every other suggestion on screen. The
					-- star bucket above already gates on the expansion, which is what
					-- "the preview treats a no-op exactly like no match" means.
					if matched_plain then
						matches[#matches + 1] = {
							repl       = matched_plain,
							plain_repl = matched_plain,
							input      = matched_input,
							type       = "autocorrect",
							group      = mapping.group,
							section    = mapping.section,
							has_magic  = mapping.has_magic,
							-- Same privacy contract as the star bucket above.
							is_private = mapping.is_private,
						}
					end
				end
			end
		end
	end

	if #matches > 0 then
		M.reset_predictions(true)

		-- Build tooltip rows (one per match). Within each kind (star / autocorrect /
		-- provider) the FIRST surviving row is the one the engine will fire — the
		-- rest are rendered dimmed + strikethrough so the user can see the
		-- alternatives without confusing them with the real outcome.
		-- The key the user actually has to press to validate a star row. Read from
		-- CoreState, which owns it and is what star_buf above is already built
		-- from: a hard-coded ★ told anyone who customised the magic key to press a
		-- character their layout no longer produces. The literal remains only as
		-- the fallback for a state that has not resolved one yet.
		local magic_key = (_state and _state.magic_key ~= nil and _state.magic_key ~= "")
			and _state.magic_key or ManifestReader.default_for("hotstrings.trigger_char")
		local rows          = {}
		local any_enabled   = false
		local min_timeout   = nil
		local primary_match = matches[1]

		-- Track whether each kind has already produced its primary row. Subsequent
		-- enabled rows of the same kind are marked dimmed.
		local primary_seen = { star = false, autocorrect = false, provider = false }
		-- Kinds whose WINNER could not be displayed. Every later row of such a kind
		-- describes an expansion the engine will not produce, so none may be shown.
		local kind_suppressed = {}
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
		append_kind("star")
		append_kind("provider")

		for _, m in ipairs(ordered) do
			local is_star = (m.type == "star")

			local tint_key
			if m.group == "personal" or m.group == "custom" or m.type == "provider" then
				tint_key = "hotstring_personal"
			elseif is_star then
				tint_key = "hotstring_star"
			else
				tint_key = "hotstring_autocorrect"
			end

			local enabled = is_star and is_star_preview_enabled
				or (not is_star and is_autocorrect_preview_enabled)
			if enabled and m.group and type(hotstrings_config.resolve) == "function" then
				-- m.section, not nil: the config window keys its per-section
				-- "hide the bubble" override by exactly this name, so resolving with
				-- nil consulted only the group level and every per-section override
				-- the user set was silently ignored by the preview.
				local ok_cfg, cfg = pcall(function() return hotstrings_config.resolve(m.group, m.section) end)
				if ok_cfg and cfg and cfg.show_tooltip == false then enabled = false end
			end

			-- Sized by the SAME precedence chain the engine uses to decide
			-- whether the trigger may still fire. The old three-way key
			-- (STAR_TRIGGER / autocorrection / dynamichotstrings) ignored
			-- per-section overrides and user-overridden group delays entirely, so
			-- the row could vanish while its trigger was still live — or linger
			-- after it had expired, offering an expansion the engine would refuse.
			-- Providers do not go through that chain and keep the group default.
			local raw_delay
			if m.type == "provider" or type(_state.resolve_mapping_delay) ~= "function" then
				raw_delay = _state.DELAYS["dynamichotstrings"] or 0
			else
				raw_delay = _state.resolve_mapping_delay(m) or 0
			end
			local row_timeout = raw_delay == 0 and INFINITE_TOOLTIP_SEC
				or math.max(MIN_TOOLTIP_DURATION_SEC, raw_delay)

			-- The ledger advances for the WINNER of each kind, displayable or not.
			-- Advancing it only for rendered rows meant that when the winning
			-- mapping's group was silenced, the next mapping of the same kind was
			-- promoted and drawn UNDIMMED — presented as what will happen, when the
			-- engine will produce the silenced winner instead.
			local is_primary = not primary_seen[m.type]
			primary_seen[m.type] = true

			-- And if that winner cannot be shown, no alternative of its kind may be
			-- shown either: every remaining row of the kind is an expansion the
			-- engine will not produce. The tooltip tells the truth or says nothing.
			if not enabled and is_primary then
				kind_suppressed[m.type] = true
			end

			if enabled and not kind_suppressed[m.type] then
				any_enabled = true
				if not min_timeout or row_timeout < min_timeout then
					min_timeout = row_timeout
				end
				rows[#rows + 1] = {
					text          = m.plain_repl,
					tint          = tooltip.tint(tint_key),
					-- Providers are validated by the magic key, exactly like a star
					-- trigger: both shipped ones fire from the interceptor on the
					-- trigger char. Labelling their row "↵" told the user to press
					-- Enter, which destroys the pending expansion instead of firing it.
					trigger_label = (is_star or m.type == "provider") and magic_key or "↵",
					dimmed        = not is_primary,
					duration      = row_timeout,
				}
			end

			-- Same privacy contract as the expander's two expansion sinks: a private
			-- mapping's replacement AND its trigger are both secrets, and DEBUG is
			-- the driver's default level, so this line would otherwise write
			-- personal_info.toml content (phone, IBAN, SSN, card) into the 14-day log
			-- on every preview keystroke. The preview TOOLTIP still renders the value
			-- — showing the user their own data on their own screen is the feature —
			-- it is only the persisted sink that must withhold it.
			if m.is_private then
				Logger.debug(LOG, "Hotstring preview: private mapping matched (content withheld) [%s].", m.type)
			else
				Logger.debug(LOG, "Hotstring '%s' → '%s' [%s].",
					tostring(m.input), m.plain_repl, m.type)
			end
		end

		local tooltip_timeout = min_timeout or INFINITE_TOOLTIP_SEC
		tooltip.set_timeout(tooltip_timeout)

		if any_enabled then
			-- Off the HID thread: see _preview_render_generation. One runloop tick
			-- is imperceptible for a preview; a blocked AX query on this thread is
			-- not — it can trip the tap-timeout that disables the keyboard tap.
			invalidate_pending_preview()
			local my_generation = _preview_render_generation
			TimerScheduler.after(0, function()
				if my_generation ~= _preview_render_generation then return end
				tooltip.show_stacked(rows, true)
			end)
		end

		-- Chain: arm the LLM timer so it fires just as the tooltip window closes.
		-- When a preview IS shown, wait for it to close (min_timeout + offset). When
		-- NO row is enabled (preview disabled, or the group's show_tooltip=false),
		-- min_timeout is nil and tooltip_timeout fell back to INFINITE_TOOLTIP_SEC —
		-- the 24 h "never auto-dismiss a VISIBLE tooltip" sentinel, which is wrong as
		-- a real LLM delay: there is no tooltip to wait for, so the chained prediction
		-- must fire promptly. Using the sentinel armed the LLM for ~24 h (it never
		-- fired) and every further matching keystroke re-armed the same 24 h timer.
		if fire_llm_after_hotstring and llm_on then
			-- Clamp against the INFINITE sentinel regardless of any_enabled: an
			-- ENABLED preview row can still carry a 0 ms ("infinite") delay, so
			-- tooltip_timeout degenerates to INFINITE_TOOLTIP_SEC even though a row is
			-- shown. Waiting ~24 h means the chained prediction never appears. When
			-- there is no FINITE auto-close to wait for, fire after the short offset.
			local chain_delay = (any_enabled and tooltip_timeout < INFINITE_TOOLTIP_SEC)
				and (tooltip_timeout + HOTSTRING_CHAIN_OFFSET_SEC)
				or HOTSTRING_CHAIN_OFFSET_SEC
			Logger.debug(LOG, "LLM chain scheduled in %.3gs.", chain_delay)
			engine.start_timer(chain_delay)
		elseif llm_on then
			-- Chain-after-hotstring is OFF but the LLM is on. update_preview stopped the
			-- inactivity timer at the top and this matches branch otherwise re-arms
			-- NOTHING, so predictions would silently stop on any keystroke whose buffer
			-- tail matches a hotstring trigger. Re-arm the inactivity timer exactly as
			-- the no-match branch does (F-L9).
			if is_word_boundary(buf) then
				engine.start_timer_word_end()
			else
				engine.start_timer()
			end
		end

		local trigger_key = primary_match.input or last_word
		local type_str    = primary_match.type == "star" and "star"
			or (primary_match.type == "autocorrect" and "autocorrect" or "personal")
		if not last_shown_hotstring or last_shown_hotstring.trigger ~= trigger_key then
			last_shown_hotstring = { trigger = trigger_key, replacement = primary_match.repl, h_type = type_str }
			-- Off the HID thread. This is pure telemetry: nothing downstream depends
			-- on it landing before the keystroke completes, and it ends in a
			-- synchronous file write on the very callback whose overrun makes macOS
			-- disable the keyboard tap. The values are captured now so a later
			-- keystroke cannot change what gets recorded.
			local t_key, t_repl, t_type = trigger_key, primary_match.repl, type_str
			TimerScheduler.after(0, function()
				pcall(keylogger.log_hotstring_suggested, nil, t_key, t_repl, t_type)
			end)
		end
	else
		-- No hotstring match — let the inactivity timer drive the LLM.
		Logger.debug(LOG, "No hotstring for '%s' — LLM timer armed.", tostring(last_word))
		M.reset_predictions()
		if llm_on then
			if is_word_boundary(buf) then
				engine.start_timer_word_end()
			else
				engine.start_timer()
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
local function arm_escape_trap()
	if _escape_trap then return end
	_escape_trap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(event)
		if EventTapGuard.handle_disabled(event, _escape_trap, "llm.escape_trap") then return false end
		if event:getKeyCode() ~= KEYCODE_ESCAPE then return false end
		-- Let Escape through when no tooltip is on screen — Raycast (or the system)
		-- should handle it normally in that case.
		if not tooltip.is_visible() then return false end
		Logger.debug(LOG, "Escape trap — Escape consumed, tooltip dismissed.")
		M.reset_predictions()
		return true
	end)
	_escape_trap:start()
	Logger.debug(LOG, "Escape trap armed (persistent).")
end



--- Clears all active predictions and optionally emits hotstring-dismissed telemetry.
--- @param keep_hotstring_log boolean When true, skips the dismiss telemetry event.
function M.reset_predictions(keep_hotstring_log)
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
		local d_trigger = last_shown_hotstring.trigger
		local d_repl    = last_shown_hotstring.replacement
		local d_type    = last_shown_hotstring.h_type
		TimerScheduler.after(0, function()
			pcall(keylogger.log_hotstring_dismissed, nil, d_trigger, d_repl, d_type)
		end)
		last_shown_hotstring = nil
	end
	engine.reset()
end

--- Applies the selected prediction: issues deletions, types the completion,
--- updates the in-memory buffer, and arms the chained LLM request.
--- @param idx number 1-based index of the prediction to apply.
--- @return boolean True when the prediction was successfully applied.
function M.apply_prediction(idx)
	if not require_state("apply_prediction") then return false end

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
	if ok_overlap and res_deletes ~= nil and res_text ~= nil then
		delete_count = res_deletes
		text_to_type = res_text
	end

	Logger.start(LOG, "Applying prediction #%d: '%s' (%d deletion(s)).",
		idx, tostring(text_to_type), delete_count)

	-- Capture the text about to be erased for telemetry.
	local deleted_text = ""
	if delete_count > 0 and type(_state.buffer) == "string" and #_state.buffer > 0 then
		local ok, offset = pcall(utf8.offset, _state.buffer, -delete_count)
		if ok and offset then deleted_text = _state.buffer:sub(offset) end
	end

	M.reset_predictions()

	-- Route through the single injection choke point so every synthetic-event
	-- tracker (expected_synthetic_deletes/chars/pastes + keylogger synth_queue) is
	-- updated atomically in one place — same path as hotstring expansion.
	-- is_final=true: suppress hotstring re-scan after LLM accept.
	-- is_ignored=true: reset_predictions() already hid the tooltip; the F16 chain
	--   signal (injected below) handles the next prediction — do not arm the LLM
	--   inactivity timer or trigger update_preview here.
	expander.perform_text_replacement(
		delete_count,
		function() return km_utils.emit_text(text_to_type) end,
		function()
			-- Sync the in-memory buffer to reflect the accepted completion.
			-- Drain paste-ops inline: take_paste_ops is called inside
			-- perform_text_replacement before this buffer_action fires, so
			-- the clipboard-paste counter is already accounted for.
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
	keylogger.log_llm_accepted(text_to_type, nil, all_preds, idx, delete_count, deleted_text)

	Logger.success(LOG, "Prediction #%d applied — buffer updated.", idx)

	-- Chain trigger: F16 is injected after all deletions and text keystrokes.
	-- The HID event queue is ordered, so by the time handle_llm_keys() sees F16,
	-- all previous keystrokes have been delivered to the target application.
	-- engine.arm_chain() sets a fallback timer in case F16 is somehow missed.
	-- F16 (not F15) so the script-control kill-switch keycode stays exclusive.
	engine.arm_chain()
	Logger.debug(LOG, "F16 signal sent — LLM chain pending.")
	hs.eventtap.keyStroke({}, Keycodes.to_name(Keycodes.F16_LLM_CHAIN_SIGNAL), 0)
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
	engine.perform_check(force_trigger, profile_name)
end

--- Re-arms the LLM inactivity timer.
--- Called by the expander after a text replacement to trigger a fresh prediction.
function M.start_timer()
	engine.start_timer()
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
	if _escape_trap then
		pcall(function() _escape_trap:stop() end)
		_escape_trap = nil
		Logger.debug(LOG, "Escape trap stopped.")
	end
end

-- Wire tooltip callbacks so the tooltip module can call back into the bridge.
-- Closures ensure the functions are resolved at call time, not at bind time.
if type(tooltip.set_accept_callback) == "function" then
	tooltip.set_accept_callback(function(idx) M.apply_prediction(idx) end)
end
if type(tooltip.set_cancel_callback) == "function" then
	tooltip.set_cancel_callback(function() M.reset_predictions() end)
end
-- Create the persistent Escape trap the first time any tooltip appears.
-- This guarantees the tap is inserted at HEAD after Raycast (or any other app) has
-- already registered its own tap, so our Escape always takes priority while a tooltip
-- is visible. The trap is never destroyed — tooltip.is_visible() drives its behaviour.
if type(tooltip.set_on_show_callback) == "function" then
	tooltip.set_on_show_callback(arm_escape_trap)
end

return M
