--- _shared/tests/lua/ai/menu_layout_contract.lua

--- ==============================================================================
--- MODULE: AI Menu Layout Contract
--- DESCRIPTION:
--- The assertions on a built AI menu the macOS and Linux tests share. Each driver
--- hands over its own built rows; Windows asserts the same layout on its native
--- menu in test_llm_menu_build_submenu.ahk.
--- ==============================================================================

local M = {}

--- Whether a built row is a separator.
--- @param row table
--- @return boolean
local function is_separator(row) return row.title == "-" end

--- The position of the first row whose title holds a text.
--- @param rows table Built rows.
--- @param text string
--- @return number|nil
local function position_of(rows, text)
	for index, row in ipairs(rows) do
		if type(row.title) == "string" and row.title:find(text, 1, true) then return index end
	end
	return nil
end

--- Refuses a separator that leads, trails or follows another one.
--- @param helpers table
--- @param rows table Built rows.
--- @param state string The state under test, for the failure message.
function M.assert_clean_separators(helpers, rows, state)
	helpers.assert_true(#rows > 0, state .. ": rows are drawn")
	helpers.assert_true(not is_separator(rows[1]), state .. ": no leading separator")
	helpers.assert_true(not is_separator(rows[#rows]), state .. ": no trailing separator")
	for index = 2, #rows do
		helpers.assert_true(not (is_separator(rows[index]) and is_separator(rows[index - 1])),
			state .. ": two separators in a row at " .. index)
	end
end

--- Asserts the block of the AI menu: the test row right under the profile row,
--- one separator closing the block, then the settings section header over the
--- trigger group.
--- @param helpers table
--- @param rows table Built AI menu rows.
--- @param captions table { profile, test, trigger, settings }: texts the rows'
---   titles hold; `settings` is the settings header's exact title.
--- @param state string The state under test, for the failure message.
function M.assert_block(helpers, rows, captions, state)
	M.assert_clean_separators(helpers, rows, state)
	local profile = position_of(rows, captions.profile)
	local test = position_of(rows, captions.test)
	local trigger = position_of(rows, captions.trigger)
	helpers.assert_true(profile ~= nil and test ~= nil and trigger ~= nil, state .. ": the block is drawn")
	helpers.assert_eq(test, profile + 1, state .. ": the test row follows the profile row")
	helpers.assert_true(is_separator(rows[test + 1]), state .. ": one separator closes the block")
	local header = rows[test + 2]
	helpers.assert_eq(header and header.title, captions.settings, state .. ": the settings header follows that separator")
	helpers.assert_true(header.disabled == true and header.fn == nil, state .. ": the settings header is inert")
	helpers.assert_eq(trigger, test + 3, state .. ": the trigger group follows the settings header")
	helpers.assert_true(not is_separator(rows[profile - 1]), state .. ": no separator splits the block")
end

--- Asserts the generation rows: the prediction count and the words, one single
--- separator, then the context rows down to the last row.
--- @param helpers table
--- @param rows table Built generation rows, from the count to the last one.
--- @param captions table { count, min_words, max_words, context, clear_context }.
--- @param state string The state under test, for the failure message.
function M.assert_generation(helpers, rows, captions, state)
	M.assert_clean_separators(helpers, rows, state)
	local separators = {}
	for index, row in ipairs(rows) do
		if is_separator(row) then separators[#separators + 1] = index end
	end
	helpers.assert_eq(#separators, 1, state .. ": exactly one separator")
	local boundary = separators[1]
	local count = position_of(rows, captions.count)
	local min_words = position_of(rows, captions.min_words)
	local max_words = position_of(rows, captions.max_words)
	local context = position_of(rows, captions.context)
	local clear_context = position_of(rows, captions.clear_context)
	helpers.assert_true(count and min_words and max_words and context and clear_context, state .. ": every row is drawn")
	helpers.assert_true(count < min_words and min_words < max_words and max_words < boundary,
		state .. ": the count and the words come first, in order")
	helpers.assert_true(boundary < context and context < clear_context, state .. ": the context rows follow the separator")
	helpers.assert_eq(clear_context, #rows, state .. ": clearing the context closes the submenu")
end

return M
