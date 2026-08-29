--- tests/unit/modules/keymap/test_synthetic_reset_guard.lua

--- ==============================================================================
--- MODULE: Explicit Synthetic Transaction Producer Coverage Guard
--- DESCRIPTION:
--- Enumerates every production call to SyntheticInput.begin(). A new explicit
--- producer makes the inventory fail until its lifecycle is reviewed. Each known
--- family is required to keep its construction scope and terminal seal/cancel
--- paths, preventing a partially built transaction from leaking across actions.
--- ==============================================================================

local helpers = require("tests.helpers")


--- Removes line comments before counting executable call sites.
--- @param source string
--- @return string code
local function strip_line_comments(source)
	local lines = {}
	for line in source:gmatch("[^\n]*") do
		lines[#lines + 1] = line:gsub("%-%-.*$", "")
	end
	return table.concat(lines, "\n")
end


--- Counts literal occurrences.
--- @param source string
--- @param literal string
--- @return integer count
local function count_literal(source, literal)
	local count = 0
	local cursor = 1
	while true do
		local found = source:find(literal, cursor, true)
		if not found then return count end
		count = count + 1
		cursor = found + #literal
	end
end


--- Reads one production unit selected by a unique symbol.
--- @param selector string
--- @return string source
local function read_unit(selector)
	local source, err = helpers.read_driver_unit(selector)
	helpers.assert_not_nil(source, err)
	return strip_line_comments(source)
end


helpers.describe("SyntheticInput explicit producer inventory", function()
	local producers = {
		clipboard_restore = 'SyntheticInput.begin("clipboard_restore", "replacement")',
		expander_replacement =
			'SyntheticInput.begin(source_variant or source_type or "replacement", "replacement")',
		external_replacement = 'SyntheticInput.begin("external_replacement", "replacement")',
		keep_awake = 'SyntheticInput.begin("shortcuts.keep_awake", "replacement")',
		text_reselect = 'SyntheticInput.begin("shortcuts.text.reselect", "action")',
		text_surround = 'SyntheticInput.begin("shortcuts.text.surround", "action")',
	}

	helpers.it("enumerates the complete non-vacuous class", function()
		local all = strip_line_comments(helpers.read_driver_source())
		local producer_names = {}
		for name in pairs(producers) do producer_names[#producer_names + 1] = name end
		table.sort(producer_names)
		helpers.assert_eq(#producer_names, 6,
			"the explicit producer inventory must name all six reviewed owners")
		helpers.assert_eq(count_literal(all, "SyntheticInput.begin("), #producer_names,
			"a new explicit producer needs a lifecycle assertion in this inventory")
		for _, name in ipairs(producer_names) do
			local call = producers[name]
			helpers.assert_eq(count_literal(all, call), 1,
				"each reviewed producer declaration must occur exactly once: " .. name)
		end
	end)

	helpers.it("keeps raw keyboard injection behind the tagged adapter", function()
		local all = strip_line_comments(helpers.read_driver_source())
		helpers.assert_eq(count_literal(all, "eventtap.keyStroke("), 0,
			"production code must not bypass SyntheticInput with eventtap.keyStroke")
		helpers.assert_eq(count_literal(all, "eventtap.keyStrokes("), 0,
			"production code must not bypass SyntheticInput with eventtap.keyStrokes")
		local compact = all:gsub("%s+", "")
		helpers.assert_eq(count_literal(compact, ".newKeyEvent("), 0,
			"production code must not call the raw Quartz key-event constructor")
		helpers.assert_eq(count_literal(all, "System Events\\\" to key code"), 0,
			"AppleScript keyboard injection bypasses immutable SyntheticInput provenance")

		local adapter = read_unit("M.MAGIC = \"ERGOPTI_SYNTHETIC_V1\"")
		helpers.assert_eq(count_literal(adapter,
			"local new_key_event = assert(event_api.newKeyEvent"), 1,
			"the tagged adapter must remain the sole raw key-event constructor owner")
		helpers.assert_true(
			count_literal(adapter, "setProperty(USER_DATA_PROPERTY") >= 2,
			"both payload key events and the broker control event need immutable tags")
	end)

	helpers.it("external replacement exposes begin, scoped build, and seal as one API", function()
		local source = read_unit("local function invalidate_observed_context")
		local begin_pos = source:find(producers.external_replacement, 1, true)
		local scope_pos = source:find("SyntheticInput.with_transaction(transaction, fn", 1, true)
		local seal_pos = source:find("SyntheticInput.seal(transaction)", 1, true)
		helpers.assert_true(begin_pos and scope_pos and seal_pos,
			"external callers need all three lifecycle operations")
		helpers.assert_true(begin_pos < scope_pos and scope_pos < seal_pos)
	end)

	helpers.it("expander has one replacement producer and repeat delegates to it", function()
		local source = read_unit("function M.try_terminator_expand")
		helpers.assert_eq(count_literal(source, "SyntheticInput.begin("), 1,
			"all expander output must use one replacement producer")
		helpers.assert_true(count_literal(source, "SyntheticInput.with_transaction") >= 1)
		helpers.assert_true(count_literal(source, "SyntheticInput.seal") >= 1)
		helpers.assert_true(count_literal(source, "SyntheticInput.cancel") >= 1)

		local repeat_start = source:find("function M.try_repeat_feature", 1, true)
		helpers.assert_not_nil(repeat_start)
		local repeat_tail = source:sub(repeat_start)
		helpers.assert_true(repeat_tail:find(
			"local replaced = M.perform_text_replacement", 1, true) ~= nil,
			"repeat must inherit the common output/telemetry/preview transaction")
		helpers.assert_eq(count_literal(repeat_tail, "SyntheticInput.begin("), 0,
			"repeat must never reopen a second synthetic producer")
	end)

	helpers.it("terminator replay publishes only a committed reserved successor", function()
		local source = read_unit("function M.prepare(spec)")
		local prepare_pos = source:find("SyntheticInput.prepare_reserved_successor", 1, true)
		local authorize_pos = source:find("SyntheticInput.authorize_reserved_successor", 1, true)
		local commit_pos = source:find("SyntheticInput.commit_reserved_successor", 1, true)
		local enqueue_pos = commit_pos
			and source:find("enqueue_pending(pending)", commit_pos, true) or nil
		local cancel_pos = source:find("SyntheticInput.cancel_reserved_successor", 1, true)
		helpers.assert_true(prepare_pos and authorize_pos and commit_pos and enqueue_pos and cancel_pos,
			"terminator replay needs preparation, authorization, commit, queue publication, and rollback")
		helpers.assert_true(prepare_pos < authorize_pos and authorize_pos < commit_pos
			and commit_pos < enqueue_pos,
			"the reserved terminator must commit before entering the logical replay queue")
		helpers.assert_eq(count_literal(source,
			'SyntheticInput.begin("terminator_replay", "replacement")'), 0,
			"reserved successors must not reopen an independent replacement transaction")
	end)

	helpers.it("clipboard restore is a sealed retained drain owner", function()
		local source = read_unit("local function acquire_paste_debt")
		local begin_pos = source:find(producers.clipboard_restore, 1, true)
		local retain_pos = source:find("SyntheticInput.retain(tx)", begin_pos, true)
		local seal_pos = source:find("SyntheticInput.seal(tx)", begin_pos, true)
		local release_pos = source:find("SyntheticInput.release, tx, token", begin_pos, true)
		helpers.assert_true(begin_pos and retain_pos and seal_pos and release_pos,
			"clipboard mutation needs explicit begin/retain/seal/exact-release ownership")
		helpers.assert_true(begin_pos < retain_pos and retain_pos < seal_pos
			and seal_pos < release_pos)
	end)

	helpers.it("deferred text reselection owns dispatch through terminal cleanup", function()
		local source = read_unit("local TRANSFORM_LOCK_TIMEOUT_SEC")
		local begin_pos = source:find(producers.text_reselect, 1, true)
		local batch_pos = source:find("SyntheticInput.begin_batch(tx)", begin_pos, true)
		local dispatch_pos = source:find("SyntheticInput.dispatch(batch)", begin_pos, true)
		local seal_pos = source:find("SyntheticInput.seal(tx)", begin_pos, true)
		local cancel_pos = source:find("SyntheticInput.cancel, tx", begin_pos, true)
		helpers.assert_true(begin_pos and batch_pos and dispatch_pos and seal_pos and cancel_pos,
			"deferred action must retain batch, dispatch, seal, and rollback sites")
		helpers.assert_true(begin_pos < batch_pos and batch_pos < dispatch_pos and dispatch_pos < seal_pos)
	end)

	helpers.it("parenthesis surround retains one transaction through every terminal path", function()
		local source = read_unit("function M.surround_with_parens")
		local begin_pos = source:find(producers.text_surround, 1, true)
		helpers.assert_not_nil(begin_pos,
			"parenthesis surround must open its named synthetic transaction")
		local next_public_function = source:find("\nfunction M%.[%w_]+%(", begin_pos)
		local surround = source:sub(begin_pos,
			next_public_function and next_public_function - 1 or #source)
		local retain_pos = surround:find("SyntheticInput.retain(tx)", 1, true)
		local completion_pos = surround:find("SyntheticInput.on_complete(tx", 1, true)
		local release_pos = surround:find("SyntheticInput.release, tx, retain", 1, true)
		local seal_pos = surround:find("SyntheticInput.seal(tx)", 1, true)
		local cancel_pos = surround:find("SyntheticInput.cancel, tx", 1, true)
		helpers.assert_true(retain_pos and completion_pos and release_pos and seal_pos and cancel_pos,
			"surround needs exact retain, completion, release, seal, and cancel ownership")
		helpers.assert_true(retain_pos < completion_pos,
			"surround must retain the closing sibling before observing transaction completion")
		helpers.assert_true(completion_pos < release_pos and completion_pos < seal_pos
			and completion_pos < cancel_pos,
			"the completion observer must precede every surround terminal route")
	end)

	helpers.it("keep-awake heartbeat is an explicit non-observable transaction with rollback", function()
		local source = read_unit("local function emit_activity_keystroke")
		local begin_pos = source:find(producers.keep_awake, 1, true)
		local emit_pos = source:find("SyntheticInput.emit_key_stroke", begin_pos, true)
		local seal_pos = source:find("SyntheticInput.seal", begin_pos, true)
		local cancel_pos = source:find("SyntheticInput.cancel, transaction", begin_pos, true)
		helpers.assert_true(begin_pos and emit_pos and seal_pos and cancel_pos,
			"the keep-awake transaction needs tagged emission, commit, and rollback sites")
		helpers.assert_true(begin_pos < emit_pos and emit_pos < seal_pos,
			"F18 must be built before its replacement transaction is sealed")
	end)
end)
