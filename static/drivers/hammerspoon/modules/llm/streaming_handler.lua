--- modules/llm/streaming_handler.lua

--- ==============================================================================
--- MODULE: LLM Streaming Handler
--- DESCRIPTION:
--- Owns the HTTP async streaming pipeline for LLM predictions: fires the backend
--- request via core_llm.fetch_llm_prediction, handles chunked streaming responses,
--- parses streaming JSON tokens, manages the watchdog timer, and calls the tooltip
--- and keylogger APIs as predictions arrive. Extracted from prediction_engine so
--- the orchestrator can stay focused on state management and routing.
---
--- FEATURES & RATIONALE:
--- 1. Streaming multi-mode: optionally shows each streaming token batch as it
---    arrives so the user sees predictions filling in line by line rather than
---    all at once when the final batch lands.
--- 2. Watchdog timer: surfaces whatever partial results exist after
---    STREAM_WATCHDOG_SEC of stall so a slow or stuck backend does not leave the
---    tooltip frozen on the loading spinner indefinitely.
--- 3. Deduplication: merges streamed placeholders and finalized predictions by
---    content key so no duplicate slot ever appears during or after streaming.
--- 4. Consecutive failure tracking: notifies the user after N consecutive backend
---    failures so a crashed or misconfigured server does not fail silently.
--- ==============================================================================

local M = {}

local hs     = hs
local Parser = require("modules.llm.parser")
local Logger = require("lib.logger")
local i18n   = require("lib.i18n")

local LOG = "llm.streaming_handler"


-- =============================================
-- =============================================
-- ======= 1/ Module Constants =================
-- =============================================
-- =============================================

-- Surface partial results after this many seconds of stream stall
local STREAM_WATCHDOG_SEC = 12.0

-- Frames per second for the streaming progress spinner
local SPINNER_FPS = 6

-- Notify after this many consecutive failures without a success
local CONSECUTIVE_FAIL_WARN_THRESHOLD = 4


-- =============================================
-- =============================================
-- ======= 2/ Mutable State ====================
-- =============================================
-- =============================================

-- Injected dependencies
local _core_llm  = nil
local _tooltip   = nil
local _keylogger = nil

local _consecutive_llm_failures = 0  -- Reset on success; triggers notification at threshold
local _stream_watchdog_timer    = nil


-- =============================================
-- =============================================
-- ======= 3/ Private Helpers ==================
-- =============================================
-- =============================================

--- Guards public functions that require initialized dependencies.
--- @param func_name string Name of the calling function (for the error log).
--- @return boolean True if dependencies are ready, false otherwise.
local function require_state(func_name)
	if not _core_llm or not _tooltip or not _keylogger then
		Logger.error(LOG, "'%s' called before M.init() — dependencies not initialized.", func_name)
		return false
	end
	return true
end

--- Builds a deduplication key from a prediction's visual diff content.
--- Two predictions with identical keys are considered duplicates and merged.
--- @param pred table A prediction object with optional .chunks and .nw fields.
--- @return string A trimmed, whitespace-collapsed string key.
local function build_dedup_key(pred)
	local parts      = {}
	local first_done = false
	local last_char  = ""

	local function clean_leading_spaces(s)
		local str = tostring(s or "")
		if not first_done and str ~= "" then
			str = str:gsub("^%s+", "")
			if str ~= "" then first_done = true end
		end
		return str
	end

	if type(pred.chunks) == "table" then
		for _, chunk in ipairs(pred.chunks) do
			local s = clean_leading_spaces(chunk.text)
			if s ~= "" then table.insert(parts, s); last_char = s:sub(-1) end
		end
	end

	local next_words = clean_leading_spaces(pred.nw)
	if next_words ~= "" then
		-- Insert a separator space when diff and next-words regions are adjacent non-space text
		if last_char ~= "" and not last_char:match("%s") and not next_words:match("^%s") then
			next_words = " " .. next_words
		end
		table.insert(parts, next_words)
	end

	return table.concat(parts):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

--- Formats the validation modifier shortcut for tooltip display.
--- Returns "none" to suppress the hint, or a zero-width space to hide it invisibly.
--- @param mods table The normalized validation modifier array.
--- @return string Formatted shortcut string (e.g. "alt", "cmd+shift", or invisible).
local function format_validation_shortcut(mods)
	if #mods == 1 and mods[1] == "none" then return "none" end
	-- Zero-width space: renders as invisible but keeps the slot present in the layout
	if #mods == 0 then return "\226\128\139" end
	return table.concat(mods, "+")
end


-- =============================================
-- =============================================
-- ======= 4/ Callback Factory =================
-- =============================================
-- =============================================

--- Builds the three LLM response callbacks (partial, success, fail) for one request.
--- All closures share the same fetch_id and mutable prediction-pool references so they
--- stay in sync without module-level per-request variables.
--- @param ctx table Request context table (see source for full field list).
--- @return function|nil on_partial_cb Nil when streaming multi is off.
--- @return function on_success Final success callback.
--- @return function on_fail Failure callback.
function M.build_callbacks(ctx)
	if not require_state("build_callbacks") then
		-- Return no-op stubs so the caller does not crash
		local noop = function() end
		return nil, noop, noop
	end

	local buffer                  = ctx.buffer
	local my_fetch_id             = ctx.my_fetch_id
	local get_fetch_id            = ctx.get_fetch_id
	local is_streaming_multi      = ctx.is_streaming_multi_enabled
	local num_predictions         = ctx.num_predictions
	local show_info_bar           = ctx.show_info_bar
	local streaming_info_bar      = ctx.streaming_info_bar
	local prediction_indent       = ctx.prediction_indent
	local validation_mods         = ctx.validation_mods
	local navigation_mods         = ctx.navigation_mods
	local model_to_use            = ctx.model_to_use
	local llm_display_name        = ctx.llm_display_name
	local profile_name            = ctx.profile_name
	local build_info_bar_text     = ctx.build_info_bar_text
	local resolve_backend_label   = ctx.resolve_backend_label
	local is_noise_pred           = ctx.is_noise_pred
	local reset_llm_dismiss_timer = ctx.reset_llm_dismiss_timer
	local pending_ref             = ctx.pending_predictions_ref
	local visible_ref             = ctx.predictions_visible_ref


	-- ── Streaming partial callback ────────────────────────────────────────────

	-- on_partial_cb: nil when streaming multi is off (all-at-once mode suppresses interim tokens)
	local on_partial_cb = (ctx.is_streaming_enabled and is_streaming_multi) and function(partial_raw)
		if get_fetch_id() ~= my_fetch_id then return end
		if type(partial_raw) ~= "string" or partial_raw:gsub("%s", "") == "" then return end

		local stripped = Parser.strip_thinking(partial_raw)
		if not stripped or stripped:gsub("%s", "") == "" then return end

		-- Split on === separator used in batch-mode prompts; each completed block is a prediction
		-- and the last (still streaming) block may fail to parse — that's fine
		local raw_blocks = {}
		for b in (stripped .. "==="):gmatch("(.-)===") do
			local clean = b:gsub("^%s+", ""):gsub("%s+$", "")
			if clean ~= "" then table.insert(raw_blocks, clean) end
		end
		if #raw_blocks == 0 then table.insert(raw_blocks, stripped) end

		-- Parse each block; apply the same noise gate as on_success; build stream preds
		local stream_preds = {}
		for _, block_text in ipairs(raw_blocks) do
			local ok_b, pred_b = pcall(Parser.process_prediction, buffer, ctx.tail, block_text)
			if ok_b and pred_b and not is_noise_pred(pred_b.to_type) then
				local display = (type(pred_b.nw) == "string" and pred_b.nw ~= "" and pred_b.nw)
					or pred_b.to_type
				if display and display:gsub("%s", "") ~= "" then
					table.insert(stream_preds, {
						to_type              = pred_b.to_type,
						deletes              = pred_b.deletes,
						chunks               = {},
						nw                   = display,
						has_corrections      = false,
						disable_bold         = true,
						_is_stream_placeholder = true,
					})
				end
			end
		end
		if #stream_preds == 0 then return end

		local new_preds = {}  -- Keep finalized slots; discard placeholders
		for _, p in ipairs(pending_ref.value) do
			if not p._is_stream_placeholder then
				table.insert(new_preds, p)
			end
		end

		local seen_to_type = {}
		for _, fp in ipairs(new_preds) do
			if fp.to_type and fp.to_type ~= "" then seen_to_type[fp.to_type] = true end
		end
		for _, sp in ipairs(stream_preds) do
			local k = sp.to_type or ""
			if k == "" or not seen_to_type[k] then
				if k ~= "" then seen_to_type[k] = true end
				table.insert(new_preds, sp)
			end
		end

		pending_ref.value  = new_preds
		visible_ref.value  = true

		-- Reserve num_predictions slots with "…" so tooltip height stays constant during streaming
		local current     = _tooltip.get_current_index()
		local display_idx = (current and math.min(math.max(1, current), #new_preds)) or 1
		_tooltip.show_predictions(
			new_preds, display_idx, ctx.is_ai_preview_enabled, streaming_info_bar,
			nil, prediction_indent, navigation_mods,
			_tooltip.tint("ai_prediction"), "…", num_predictions
		)
	end or nil


	-- ── Success callback ──────────────────────────────────────────────────────

	local function on_success(raw_predictions, elapsed_ms, is_final, is_batch_progressive)
		_consecutive_llm_failures = 0  -- Reset on every response regardless of content
		-- Suppress intermediate batches in all-at-once mode (batch_progressive = fetch_batch reveal)
		if not is_final and not is_streaming_multi and not is_batch_progressive then return end
		if get_fetch_id() ~= my_fetch_id then
			Logger.debug(LOG, "Stale LLM callback ignored (expected %d, current %d).", my_fetch_id, get_fetch_id())
			return
		end

		if is_final and _stream_watchdog_timer then
			_stream_watchdog_timer:stop()
			_stream_watchdog_timer = nil
		end

		local front    = hs.application.frontmostApplication()
		local app_name = front and front:title() or nil
		_keylogger.log_llm(buffer, raw_predictions, app_name)

		-- ── Filter: remove noise, invalid entries, and exact duplicates ──────
		local valid_preds, seen_keys = {}, {}
		for _, raw_pred in ipairs(raw_predictions) do
			local pred = {}
			for k, v in pairs(raw_pred) do pred[k] = v end

			if pred.to_type then
				local text = pred.to_type
				if not is_noise_pred(text)
					and _tooltip.make_diff_styled(pred.chunks, pred.nw)
				then
					local key = build_dedup_key(pred)
					if key == "" or not seen_keys[key] then
						if key ~= "" then seen_keys[key] = true end
						table.insert(valid_preds, pred)
					end
				end
			end
		end

		-- Evict streaming placeholders — finalized results always supersede them
		for i = #pending_ref.value, 1, -1 do
			if pending_ref.value[i] and pending_ref.value[i]._is_stream_placeholder then
				table.remove(pending_ref.value, i)
			end
		end

		-- Merge: valid_preds leads; pending fills slots the new batch hasn't yet superseded
		if not is_final and visible_ref.value and #pending_ref.value > 0 then
			local merged, merged_keys = {}, {}
			for _, new_pred in ipairs(valid_preds) do
				local k = build_dedup_key(new_pred)
				if k == "" or not merged_keys[k] then
					if k ~= "" then merged_keys[k] = true end
					table.insert(merged, new_pred)
				end
			end
			for _, existing in ipairs(pending_ref.value) do
				local k = build_dedup_key(existing)
				if k == "" or not merged_keys[k] then
					if k ~= "" then merged_keys[k] = true end
					table.insert(merged, existing)
				end
			end
			valid_preds = merged
		end

		if #valid_preds == 0 then
			if is_final then
				Logger.warn(LOG, "No valid predictions after filtering (final batch).")
				if not visible_ref.value then _tooltip.hide() end
			end
			return
		end

		if is_final then
			Logger.success(LOG, "%d prediction(s) received in %dms from '%s'.",
				#valid_preds, elapsed_ms or 0, tostring(model_to_use))
		else
			Logger.debug(LOG, "Streaming — %d prediction(s) received (partial batch).", #valid_preds)
		end

		_keylogger.log_llm_suggested(app_name, #valid_preds)

		pending_ref.value = valid_preds
		visible_ref.value = true

		local active_profile  = _core_llm.get_active_profile()
		local display_profile = profile_name or (active_profile and active_profile.label)
		local display_model   = llm_display_name or _core_llm.get_current_model()
		local info_bar_text   = show_info_bar
			and build_info_bar_text(display_model, elapsed_ms, resolve_backend_label(), display_profile)
			or nil

		-- During streaming show a spinner in the loading slot to signal work in progress
		local loading_text = nil
		if not is_final and #valid_preds < num_predictions then
			local spinner_frames = { "◐", "◓", "◑", "◒" }
			local frame = spinner_frames[
				(math.floor(hs.timer.secondsSinceEpoch() * SPINNER_FPS) % #spinner_frames) + 1
			]
			loading_text = string.format("%s Enrichissement… %d/%d", frame, #valid_preds, num_predictions)
		end

		local val_shortcut  = format_validation_shortcut(validation_mods)
		local selected_idx  = math.min(math.max(1, math.floor(_tooltip.get_current_index() or 1)), #valid_preds)
		local slot_count    = is_final and #valid_preds or num_predictions

		_tooltip.show_predictions(valid_preds, selected_idx, ctx.is_ai_preview_enabled, info_bar_text,
			val_shortcut, prediction_indent, navigation_mods, _tooltip.tint("ai_prediction"),
			loading_text, slot_count)

		if is_final then
			reset_llm_dismiss_timer()
			pcall(_tooltip.mark_chain_complete)
		end
	end


	-- ── Failure callback ──────────────────────────────────────────────────────

	local function on_fail()
		if get_fetch_id() ~= my_fetch_id then return end

		-- Track consecutive failures to detect persistent issues (e.g. server
		-- crashed, still loading weights, or misconfigured endpoint)
		_consecutive_llm_failures = _consecutive_llm_failures + 1
		if _consecutive_llm_failures >= CONSECUTIVE_FAIL_WARN_THRESHOLD then
			_consecutive_llm_failures = 0  -- Reset so the notification is not spammed
			if _core_llm.get_backend() == "mlx" then
				Logger.warn(LOG, "Repeated MLX failures (%d consecutive) — server may be down or misconfigured.",
					CONSECUTIVE_FAIL_WARN_THRESHOLD)
				pcall(function()
					hs.notify.new(nil, {
						title           = i18n.get("notify.llm_mlx_failures_title"),
						informativeText = i18n.get("notify.llm_mlx_failures_body"),
						alwaysPresent   = false,
						autoWithdraw    = true,
					}):send()
				end)
			end
		end

		if not visible_ref.value then
			Logger.warn(LOG, "LLM request failed — loading indicator dismissed.")
			_tooltip.hide()
		else
			Logger.warn(LOG, "LLM request failed — n-gram placeholder retained, loading text cleared.")
			local val_shortcut = format_validation_shortcut(validation_mods)
			local selected_idx = math.max(1, _tooltip.get_current_index() or 1)
			_tooltip.show_predictions(pending_ref.value, selected_idx, ctx.is_ai_preview_enabled, nil,
				val_shortcut, prediction_indent, navigation_mods,
				_tooltip.tint("ai_prediction"), nil, #pending_ref.value)
			reset_llm_dismiss_timer()
			pcall(_tooltip.mark_chain_complete)
		end
	end

	return on_partial_cb, on_success, on_fail
end


-- =============================================
-- =============================================
-- ======= 5/ Watchdog Timer ===================
-- =============================================
-- =============================================

--- Arms the stream watchdog timer for a new request.
--- If the stream stalls for STREAM_WATCHDOG_SEC seconds, surfaces partial results.
--- Stops any previously armed watchdog first.
---
--- @param ctx table Context table (see source for full field list).
function M.arm_watchdog(ctx)
	if not require_state("arm_watchdog") then return end

	if _stream_watchdog_timer then _stream_watchdog_timer:stop() end

	local my_fetch_id   = ctx.my_fetch_id
	local get_fetch_id  = ctx.get_fetch_id
	local pending_ref   = ctx.pending_predictions_ref
	local visible_ref   = ctx.predictions_visible_ref

	_stream_watchdog_timer = hs.timer.doAfter(STREAM_WATCHDOG_SEC, function()
		if get_fetch_id() ~= my_fetch_id or not visible_ref.value then return end
		Logger.warn(LOG, "Watchdog triggered: stream stalled for %gs — surfacing partial results.", STREAM_WATCHDOG_SEC)
		local val_shortcut = format_validation_shortcut(ctx.validation_mods)
		local info = ctx.show_info_bar
			and ctx.build_info_bar_text(ctx.llm_display_name, nil, ctx.resolve_backend_label(), "Timeout partiel")
			or nil
		_tooltip.show_predictions(
			pending_ref.value, 1, ctx.is_ai_preview_enabled, info,
			val_shortcut, ctx.prediction_indent, ctx.navigation_mods,
			_tooltip.tint("ai_prediction"), nil, #pending_ref.value
		)
	end)
end

--- Stops the active watchdog timer if one is armed.
function M.stop_watchdog()
	if _stream_watchdog_timer then
		_stream_watchdog_timer:stop()
		_stream_watchdog_timer = nil
	end
end

--- Resets the consecutive failure counter (called when LLM is re-enabled or model changes).
function M.reset_failure_count()
	_consecutive_llm_failures = 0
end


-- =============================================
-- =============================================
-- ======= 6/ Module Lifecycle =================
-- =============================================

-- =============================================
-- =============================================

--- Initializes the streaming handler with its required dependencies.
--- Must be called exactly once before any other function.
--- @param deps table Must contain: core_llm (table), tooltip (table), keylogger (table).
function M.init(deps)
	Logger.start(LOG, "Initializing…")
	if type(deps) ~= "table" then
		Logger.error(LOG, "M.init(): deps must be a table — module non-functional.")
		return
	end
	if _core_llm then
		Logger.warn(LOG, "M.init() called more than once — ignoring duplicate call.")
		return
	end
	if type(deps.core_llm) ~= "table" then
		Logger.error(LOG, "M.init(): deps.core_llm must be a table — module non-functional.")
		return
	end
	if type(deps.tooltip) ~= "table" then
		Logger.error(LOG, "M.init(): deps.tooltip must be a table — module non-functional.")
		return
	end
	if type(deps.keylogger) ~= "table" then
		Logger.error(LOG, "M.init(): deps.keylogger must be a table — module non-functional.")
		return
	end
	_core_llm  = deps.core_llm
	_tooltip   = deps.tooltip
	_keylogger = deps.keylogger
	Logger.success(LOG, "Initialized.")
end

return M
