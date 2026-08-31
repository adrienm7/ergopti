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

local hs      = hs
local Parser  = require("modules.llm.parser")
local Logger  = require("infra.logger")
local Timings = require("infra.timings")
local i18n    = require("infra.i18n")
local TimerScheduler = require("adapters.timer_scheduler")

local LOG = "llm.streaming_handler"


-- =============================================
-- =============================================
-- ======= 1/ Module Constants =================
-- =============================================
-- =============================================

-- Surface partial results after this many seconds of stream stall.
-- Shared cross-driver value ([llm] stream_watchdog_ms).
local STREAM_WATCHDOG_SEC = Timings.sec("llm", "stream_watchdog_ms")

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

	return (table.concat(parts):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
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

--- Stops and releases the current watchdog only after native state confirms it.
--- @param reason string Diagnostic reason for the stop.
--- @return boolean stopped True when no live watchdog remains owned here.
local function stop_watchdog_timer(reason)
	local owner = _stream_watchdog_timer
	if not owner then return true end
	owner.authorized = false
	owner.committed = false
	if owner.callback_running == true then return false end
	if owner.handle == nil then
		if owner.installing == true then return false end
		if _stream_watchdog_timer == owner then _stream_watchdog_timer = nil end
		return true
	end
	if owner.native_settled == true then
		if _stream_watchdog_timer == owner then _stream_watchdog_timer = nil end
		return true
	end
	local cancel_ok, settled_or_error = xpcall(function()
		return TimerScheduler.cancel(owner.handle)
	end, debug.traceback)
	if cancel_ok ~= true or settled_or_error ~= true then
		Logger.error(LOG,
			"Cannot settle LLM watchdog for %s; exact timer retained: %s.",
			tostring(reason), tostring(settled_or_error))
		return false
	end
	owner.native_settled = true
	if _stream_watchdog_timer ~= nil and _stream_watchdog_timer ~= owner then
		Logger.error(LOG,
			"LLM watchdog cleanup was superseded during native settlement; successor preserved.")
		return false
	end
	if _stream_watchdog_timer == owner then _stream_watchdog_timer = nil end
	return true
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
		-- An inert callback set would let the backend dispatch and leave the loading
		-- surface waiting for callbacks that can never publish or dismiss it.
		return nil, nil, nil
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
	local runtime_guard           = type(ctx.runtime_available) == "function"
		and ctx.runtime_available
		or function() return true end

	-- Action-epoch invalidation can race every backend callback independently of
	-- the request generation. Treat a missing/throwing answer as closed before
	-- touching logs, telemetry, prediction pools, or UI.
	local function runtime_available()
		local ok, available = pcall(runtime_guard)
		return ok and available == true
	end

	--- Reports whether this callback still belongs to the live request.
	--- @return boolean current True while both runtime and fetch generation match.
	local function request_is_current()
		if not runtime_available() then return false end
		local ok, current_id = pcall(get_fetch_id)
		return ok and current_id == my_fetch_id
	end

	--- Propagates one failed UI commit without tearing down a newer request.
	--- @param stage string UI operation that failed.
	--- @param detail any Returned value or raised error.
	--- @return boolean handled True when the current request accepted cleanup.
	local function reject_ui_commit(stage, detail)
		Logger.error(LOG, "Tooltip %s did not commit (result: %s).", tostring(stage), tostring(detail))
		if not request_is_current() then return false end
		if type(ctx.on_ui_unavailable) ~= "function" then
			Logger.error(LOG, "Tooltip failure handler is unavailable — request state remains closed locally.")
			return false
		end
		local ok, handled = pcall(ctx.on_ui_unavailable, stage, detail)
		if not ok then
			Logger.error(LOG, "Tooltip failure handler raised for '%s': %s", tostring(stage), tostring(handled))
			return false
		end
		return handled == true
	end

	--- Renders a prediction frame and accepts only a strict successful commit.
	--- @param stage string Diagnostic stage label.
	--- @param render_fn function Builds arguments and calls tooltip.show_predictions.
	--- @return boolean committed True while this request still owns the painted frame.
	local function render_predictions(stage, render_fn)
		if not request_is_current() then return false end
		local ok, result = xpcall(render_fn, debug.traceback)
		if not ok or result ~= true then
			reject_ui_commit(stage, result)
			return false
		end
		return request_is_current()
	end

	--- Commits final-timer and timing-line updates before business state publishes.
	--- @return boolean committed True when both UI updates committed for this request.
	local function commit_final_ui()
		local reset_ok, reset_result = pcall(reset_llm_dismiss_timer)
		if not reset_ok or reset_result ~= true then
			reject_ui_commit("dismiss timer reset", reset_result)
			return false
		end
		if not request_is_current() then return false end
		local timing_ok, timing_result = pcall(_tooltip.mark_chain_complete)
		if not timing_ok or timing_result ~= true then
			reject_ui_commit("timing update", timing_result)
			return false
		end
		return request_is_current()
	end


	-- ── Streaming partial callback ────────────────────────────────────────────

	local partial_thinking_filter = (ctx.is_streaming_enabled and is_streaming_multi)
		and Parser.new_thinking_filter()
		or nil
	local partial_raw_seen = ""
	local partial_visible = ""
	local partial_stream_valid = true
	local partial_filter_settled = false

	--- Converts one cumulative backend snapshot into filtered visible text.
	--- @param partial_raw string Accumulated raw response from the backend.
	--- @return string|nil visible Filtered accumulated text, or nil when unchanged/invalid.
	local function filter_partial_snapshot(partial_raw)
		if partial_filter_settled or not partial_stream_valid then return nil end
		if partial_raw:sub(1, #partial_raw_seen) ~= partial_raw_seen then
			partial_stream_valid = false
			Logger.warn(LOG,
				"Streaming partial broke the cumulative-prefix contract — suppressing interim output.")
			return nil
		end

		local delta = partial_raw:sub(#partial_raw_seen + 1)
		partial_raw_seen = partial_raw
		if delta == "" then return nil end

		partial_visible = partial_visible .. partial_thinking_filter:feed(delta)
		return partial_visible
	end

	--- Settles the request-local filter after the canonical final path takes over.
	local function settle_partial_filter()
		if partial_filter_settled or partial_thinking_filter == nil then return end
		partial_filter_settled = true
		-- The final callback already carries the complete, independently filtered
		-- prediction set, so a withheld ordinary tail must not be rendered twice.
		partial_thinking_filter:flush()
	end

	-- on_partial_cb: nil when streaming multi is off (all-at-once mode suppresses interim tokens)
	local on_partial_cb = (ctx.is_streaming_enabled and is_streaming_multi) and function(partial_raw)
		if not runtime_available() then return end
		if not request_is_current() then return end
		if type(partial_raw) ~= "string" or partial_raw:gsub("%s", "") == "" then return end

		local stripped = filter_partial_snapshot(partial_raw)
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

		-- Reserve num_predictions slots with "…" so tooltip height stays constant during streaming
		if not render_predictions("partial render", function()
			local current     = _tooltip.get_current_index()
			local display_idx = (current and math.min(math.max(1, current), #new_preds)) or 1
			return _tooltip.show_predictions(
				new_preds, display_idx, ctx.is_ai_preview_enabled, streaming_info_bar,
				nil, prediction_indent, navigation_mods,
				_tooltip.tint("ai_prediction"), "…", num_predictions, my_fetch_id,
				request_is_current
			)
		end) then return end

		pending_ref.value = new_preds
		visible_ref.value = true
	end or nil


	-- ── Success callback ──────────────────────────────────────────────────────

	local function on_success(raw_predictions, elapsed_ms, is_final, is_batch_progressive)
		if not runtime_available() then return end
		-- Suppress intermediate batches in all-at-once mode (batch_progressive = fetch_batch reveal)
		if not is_final and not is_streaming_multi and not is_batch_progressive then return end
		if not request_is_current() then
			local _, current_id = pcall(get_fetch_id)
			Logger.debug(LOG, "Stale LLM callback ignored (expected %d, current %s).",
				my_fetch_id, tostring(current_id))
			return
		end
		if is_final and not stop_watchdog_timer("final response") then
			reject_ui_commit("watchdog cancellation", "timer did not stop")
			return
		end
		-- Native stop proof can execute arbitrary timer methods. A reset or
		-- superseding request entered from that boundary revokes this callback even
		-- when no replacement watchdog is installed, so revalidate before logging,
		-- filtering, or painting anything for the old request.
		if is_final and not request_is_current() then return end
		if is_final then settle_partial_filter() end

		-- Reset the consecutive-failure counter only for a still-current response;
		-- a stale success must not mask failures counted by its successor.
		_consecutive_llm_failures = 0

		local front    = hs.application.frontmostApplication()
		local app_name = front and front:title() or nil
		if not request_is_current() then return end
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

		-- Build a local retained pool. Mutating the live array before paint made a
		-- failed canvas update delete the only still-visible predictions.
		local retained_preds = {}
		for _, existing in ipairs(pending_ref.value) do
			if existing and not existing._is_stream_placeholder then
				retained_preds[#retained_preds + 1] = existing
			end
		end

		-- Merge: valid_preds leads; pending fills slots the new batch hasn't yet superseded
		if not is_final and visible_ref.value and #retained_preds > 0 then
			local merged, merged_keys = {}, {}
			for _, new_pred in ipairs(valid_preds) do
				local k = build_dedup_key(new_pred)
				if k == "" or not merged_keys[k] then
					if k ~= "" then merged_keys[k] = true end
					table.insert(merged, new_pred)
				end
			end
			for _, existing in ipairs(retained_preds) do
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
				if not visible_ref.value then
					local hide_ok, hide_result = pcall(
						_tooltip.hide, my_fetch_id, request_is_current)
					if not hide_ok or hide_result ~= true then
						reject_ui_commit("empty-result hide", hide_result)
					end
				end
			end
			return
		end

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

		local val_shortcut = format_validation_shortcut(validation_mods)
		local slot_count   = is_final and #valid_preds or num_predictions

		if not render_predictions(is_final and "final render" or "stream render", function()
			local selected_idx = math.min(
				math.max(1, math.floor(_tooltip.get_current_index() or 1)),
				#valid_preds
			)
			return _tooltip.show_predictions(
				valid_preds, selected_idx, ctx.is_ai_preview_enabled, info_bar_text,
				val_shortcut, prediction_indent, navigation_mods, _tooltip.tint("ai_prediction"),
				loading_text, slot_count, my_fetch_id, request_is_current
			)
		end) then return end

		if is_final and not commit_final_ui() then return end
		if not request_is_current() then return end

		pending_ref.value = valid_preds
		visible_ref.value = true
		_keylogger.log_llm_suggested(app_name, #valid_preds)

		if is_final then
			Logger.success(LOG, "%d prediction(s) received in %dms from '%s'.",
				#valid_preds, elapsed_ms or 0, tostring(model_to_use))
		else
			Logger.debug(LOG, "Streaming — %d prediction(s) received (partial batch).", #valid_preds)
		end
	end


	-- ── Failure callback ──────────────────────────────────────────────────────

	local function on_fail()
		if not runtime_available() then return end
		if not request_is_current() then return end

		-- Cancel the watchdog so a stale timer cannot fire show_predictions
		-- with empty/partial data after the request has already failed
		if not stop_watchdog_timer("request failure") then
			reject_ui_commit("watchdog cancellation", "timer did not stop")
			return
		end
		-- The native cancellation boundary may have superseded this request while
		-- proving the watchdog stopped. Do not let its stale failure update counters
		-- or mutate the successor's surface.
		if not request_is_current() then return end
		settle_partial_filter()

		-- Track consecutive failures to detect persistent issues (e.g. server
		-- crashed, still loading weights, or misconfigured endpoint)
		_consecutive_llm_failures = _consecutive_llm_failures + 1
		if _consecutive_llm_failures >= CONSECUTIVE_FAIL_WARN_THRESHOLD then
			_consecutive_llm_failures = 0  -- Reset so the notification is not spammed
			local current_backend = _core_llm.get_backend()
			if not request_is_current() then return end
			-- Warn for every backend — not just MLX — so silent failure modes are surfaced
			Logger.warn(LOG, "Repeated LLM failures (%d consecutive) on backend '%s' — server may be down or misconfigured.",
				CONSECUTIVE_FAIL_WARN_THRESHOLD, tostring(current_backend))
			if current_backend == "mlx" then
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
		-- Notification construction/send is another native boundary. If it changed
		-- request ownership, the old failure must not hide or repaint the successor.
		if not request_is_current() then return end

		if not visible_ref.value then
			Logger.warn(LOG, "LLM request failed — loading indicator dismissed.")
			local hide_ok, hide_result = pcall(
				_tooltip.hide, my_fetch_id, request_is_current)
			if not hide_ok or hide_result ~= true then
				reject_ui_commit("failure hide", hide_result)
			end
		else
			Logger.warn(LOG, "LLM request failed — n-gram placeholder retained, loading text cleared.")
			local val_shortcut = format_validation_shortcut(validation_mods)
			if not render_predictions("failure fallback render", function()
				local selected_idx = math.max(1, _tooltip.get_current_index() or 1)
				return _tooltip.show_predictions(
					pending_ref.value, selected_idx, ctx.is_ai_preview_enabled, nil,
					val_shortcut, prediction_indent, navigation_mods,
					_tooltip.tint("ai_prediction"), nil, #pending_ref.value, my_fetch_id,
					request_is_current
				)
			end) then return end
			commit_final_ui()
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
	if not require_state("arm_watchdog") then return false end

	if not stop_watchdog_timer("replacement") then return false end

	local my_fetch_id   = ctx.my_fetch_id
	local get_fetch_id  = ctx.get_fetch_id
	local pending_ref   = ctx.pending_predictions_ref
	local visible_ref   = ctx.predictions_visible_ref
	local runtime_guard = type(ctx.runtime_available) == "function"
		and ctx.runtime_available
		or function() return true end

	local function runtime_available()
		local ok, available = pcall(runtime_guard)
		return ok and available == true
	end

	--- Reports whether this watchdog still belongs to the live request.
	--- @return boolean current True while runtime and fetch generation match.
	local function request_is_current()
		if not runtime_available() then return false end
		local ok, current_id = pcall(get_fetch_id)
		return ok and current_id == my_fetch_id
	end

	--- Propagates a watchdog repaint failure only to its current owner.
	--- @param detail any Returned value or raised error.
	local function reject_watchdog_ui(detail)
		Logger.error(LOG, "Tooltip watchdog render did not commit (result: %s).", tostring(detail))
		if not request_is_current() or type(ctx.on_ui_unavailable) ~= "function" then return end
		local ok, err = pcall(ctx.on_ui_unavailable, "watchdog render", detail)
		if not ok then
			Logger.error(LOG, "Tooltip failure handler raised for watchdog render: %s", tostring(err))
		end
	end

	local owner = {
		handle = nil,
		authorized = true,
		committed = false,
		installing = true,
		native_settled = false,
		callback_pending = false,
		callback_running = false,
		callback_consumed = false,
	}
	-- Publish the logical owner before the adapter crosses native start(). A
	-- re-entrant reset can now fence this acquisition even before its exact handle
	-- is returned; the post-start path then compensates that same handle.
	_stream_watchdog_timer = owner

	--- Paints the watchdog frame only after both scheduler commit and exact native
	--- settlement. A one-shot whose self-stop refused remains cleanup debt and must
	--- not expose UI while its native capability can still redeliver.
	--- @return boolean delivered True only for the first authorized delivery.
	local function deliver_watchdog()
		if owner.callback_pending ~= true or owner.callback_consumed == true
			or owner.native_settled ~= true then
			return false
		end
		if owner.committed ~= true or owner.authorized ~= true then return false end
		owner.callback_consumed = true
		owner.callback_pending = false
		owner.callback_running = true
		local callback_ok, callback_err = xpcall(function()
			if not request_is_current() then return end
			if not visible_ref.value or #pending_ref.value == 0 then
				Logger.warn(LOG, "Watchdog triggered: stream produced no visible result for %gs.",
					STREAM_WATCHDOG_SEC)
				reject_watchdog_ui("no committed partial prediction")
				return
			end
			Logger.warn(LOG, "Watchdog triggered: stream stalled for %gs — surfacing partial results.", STREAM_WATCHDOG_SEC)
			local val_shortcut = format_validation_shortcut(ctx.validation_mods)
			local info = ctx.show_info_bar
				and ctx.build_info_bar_text(ctx.llm_display_name, nil, ctx.resolve_backend_label(), "Timeout partiel")
				or nil
			local render_result = _tooltip.show_predictions(
				pending_ref.value, 1, ctx.is_ai_preview_enabled, info,
				val_shortcut, ctx.prediction_indent, ctx.navigation_mods,
				_tooltip.tint("ai_prediction"), nil, #pending_ref.value, my_fetch_id,
				request_is_current
			)
			if render_result ~= true then reject_watchdog_ui(render_result) end
		end, debug.traceback)
		if not callback_ok then reject_watchdog_ui(callback_err) end
		owner.callback_running = false
		if _stream_watchdog_timer == owner then _stream_watchdog_timer = nil end
		return true
	end

	local function watchdog_callback()
		if owner.callback_consumed == true or owner.callback_pending == true then
			return false
		end
		owner.callback_pending = true
		if owner.installing == true then return true end
		deliver_watchdog()
		return true
	end

	local schedule_ok, handle_or_error, committed = xpcall(function()
		return TimerScheduler.after(STREAM_WATCHDOG_SEC, watchdog_callback)
	end, debug.traceback)
	owner.installing = false
	if schedule_ok == true and type(handle_or_error) == "table" then
		owner.handle = handle_or_error
		local observed_ok, observed = xpcall(function()
			return TimerScheduler.onSettled(handle_or_error, function()
				owner.native_settled = true
				deliver_watchdog()
				if owner.callback_consumed == true and owner.callback_running ~= true
					and _stream_watchdog_timer == owner then
					_stream_watchdog_timer = nil
				end
			end)
		end, debug.traceback)
		if observed_ok ~= true or observed ~= true then
			owner.authorized = false
			owner.committed = false
			local cancel_ok, settled = xpcall(function()
				return TimerScheduler.cancel(handle_or_error)
			end, debug.traceback)
			if cancel_ok == true and settled == true
				and _stream_watchdog_timer == owner then
				_stream_watchdog_timer = nil
			end
			Logger.error(LOG,
				"Cannot observe LLM stream watchdog settlement: %s.", tostring(observed))
			return false
		end
	end

	if schedule_ok ~= true or type(handle_or_error) ~= "table" or committed ~= true then
		owner.authorized = false
		owner.committed = false
		if owner.handle ~= nil then
			xpcall(function() return TimerScheduler.cancel(owner.handle) end,
				debug.traceback)
		elseif _stream_watchdog_timer == owner then
			_stream_watchdog_timer = nil
		end
		Logger.error(LOG, "Cannot arm LLM stream watchdog: %s.",
			tostring(schedule_ok and committed or handle_or_error))
		return false
	end
	if owner.authorized ~= true then
		local cancel_ok, settled = xpcall(function()
			return TimerScheduler.cancel(owner.handle)
		end, debug.traceback)
		if cancel_ok == true and settled == true
			and _stream_watchdog_timer == owner then
			_stream_watchdog_timer = nil
		end
		return false
	end
	owner.committed = true
	deliver_watchdog()
	return true
end

--- Stops the active watchdog timer if one is armed.
function M.stop_watchdog()
	if not require_state("stop_watchdog") then return false end
	return stop_watchdog_timer("explicit stop")
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
--- @return boolean committed True only when every dependency is ready.
function M.init(deps)
	Logger.start(LOG, "Initializing…")
	if type(deps) ~= "table" then
		Logger.error(LOG, "M.init(): deps must be a table — module non-functional.")
		return false
	end
	if _core_llm then
		if _core_llm == deps.core_llm and _tooltip == deps.tooltip and _keylogger == deps.keylogger then
			Logger.warn(LOG, "M.init() called more than once with the active dependencies — ignoring duplicate call.")
			return true
		end
		Logger.error(LOG, "M.init(): different dependencies are already active — replacement refused.")
		return false
	end
	if type(deps.core_llm) ~= "table" then
		Logger.error(LOG, "M.init(): deps.core_llm must be a table — module non-functional.")
		return false
	end
	if type(deps.tooltip) ~= "table" then
		Logger.error(LOG, "M.init(): deps.tooltip must be a table — module non-functional.")
		return false
	end
	if type(deps.keylogger) ~= "table" then
		Logger.error(LOG, "M.init(): deps.keylogger must be a table — module non-functional.")
		return false
	end
	_core_llm  = deps.core_llm
	_tooltip   = deps.tooltip
	_keylogger = deps.keylogger
	Logger.success(LOG, "Initialized.")
	return true
end

return M
