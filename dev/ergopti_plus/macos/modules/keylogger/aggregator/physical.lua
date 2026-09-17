--- modules/keylogger/aggregator/physical.lua

--- Aggregates already validated physical presses independently of logical text.
--- Capture ownership must be established by the producer's consumer before logging.
local M = {}

--- Returns the common ergonomic row for either input channel.
---@param date string Captured calendar date.
---@param app string Captured application.
---@param C table Aggregator operations owned by the caller.
---@param S table Aggregator state owned by the caller.
---@return table
function M.ergo_row(date, app, C, S)
	return C.gc(S.agg_batch.ergo, date .. "\1" .. app, {
		date = date, app = app, same_finger_streak_max = 0,
		same_hand_streak_max = 0, auto_repeat_count = 0,
		focus_to_first_key_sum_ms = 0, focus_to_first_key_count = 0,
	})
end

--- Advances streaks without coupling physical and logical event order.
---@param ergo table Aggregate maxima.
---@param ctx table Context owned by the selected input channel.
---@param finger string|nil Mapped finger, or nil to break continuity.
function M.advance_streak(ergo, ctx, finger)
	if not finger then
		ctx.last_finger, ctx.same_finger_run, ctx.same_hand_run = nil, 0, 0
		return
	end
	ctx.same_finger_run = ctx.last_finger == finger and (ctx.same_finger_run or 1) + 1 or 1
	ctx.same_hand_run = ctx.last_finger and ctx.last_finger:sub(1, 1) == finger:sub(1, 1)
		and (ctx.same_hand_run or 1) + 1 or 1
	ctx.last_finger = finger
	ergo.same_finger_streak_max = math.max(ergo.same_finger_streak_max, ctx.same_finger_run)
	ergo.same_hand_streak_max = math.max(ergo.same_hand_streak_max, ctx.same_hand_run)
end

--- Credits one physical press and advances its independent ergonomic context.
--- This is an ingest boundary, not validation of native stream coverage or delivery.
---@param entry table Physical press with capture, device, keycode, app and timestamp.
---@param C table Aggregator operations owned by the caller.
---@param S table Aggregator state owned by the caller.
function M.walk_press(entry, C, S)
	assert(type(entry.capture) == "string" and entry.capture ~= "",
		"Physical press requires capture ownership")
	assert(type(entry.device) == "string" and entry.device:match("^[1-9]%d*$"),
		"Physical press requires an exact device identifier")
	assert(type(entry.keycode) == "number" and entry.keycode >= 0
		and entry.keycode % 1 == 0, "Physical press requires an integer keycode")
	assert(type(entry.app) == "string" and entry.app ~= "",
		"Physical press requires its captured application")
	assert(type(entry.timestamp) == "string" and entry.timestamp:match("^%d%d%d%d%-%d%d%-%d%d "),
		"Physical press requires its captured timestamp")

	local date = entry.timestamp:sub(1, 10)
	local key = date .. "\1" .. entry.app
	local kc_key = key .. "\1" .. tostring(entry.keycode)
	local row = C.gc(S.agg_batch.kc_ngram, kc_key,
		{ date = date, app = entry.app, keycode = entry.keycode, count = 0 })
	row.count = row.count + 1
	local ergo = M.ergo_row(date, entry.app, C, S)
	local ctx = C.get_app_ctx(entry.app)
	local physical = ctx.physical
	if not physical or physical.capture ~= entry.capture or physical.device ~= entry.device
		or physical.date ~= date then
		physical = { capture = entry.capture, device = entry.device, date = date }
		ctx.physical = physical
	end
	M.advance_streak(ergo, physical, C.KC_TO_FINGER[entry.keycode])
end

return M
