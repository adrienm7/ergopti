--- tests/support/pause_transaction_assertions.lua

--- ==============================================================================
--- MODULE: Pause Transaction Assertions
--- DESCRIPTION:
--- Shares observable lifecycle and diagnostic checks across transaction scenarios.
--- ==============================================================================

local helpers = require("tests.helpers")

local function count_notifications(ctx, title, kind)
	local count = 0
	for _, item in ipairs(ctx.notifications) do
		if item.title == title and item.kind == kind then count = count + 1 end
	end
	return count
end

local function has_error_containing(ctx, needle)
	for _, message in ipairs(ctx.errors) do
		if message:find(needle, 1, true) then return true end
	end
	return false
end

local function has_warning_containing(ctx, needle)
	for _, message in ipairs(ctx.warnings) do
		if message:find(needle, 1, true) then return true end
	end
	return false
end

local function assert_reversible_modules_running(ctx, context)
	for _, name in ipairs({
		"keymap", "shortcuts", "gestures", "mlx_warmup", "warmup_controller",
	}) do
		helpers.assert_eq(ctx.states[name], true,
			string.format("%s: reversible module '%s' must be restored", context, name))
	end
end

return {
	count_notifications = count_notifications,
	has_error_containing = has_error_containing,
	has_warning_containing = has_warning_containing,
	assert_reversible_modules_running = assert_reversible_modules_running,
}
