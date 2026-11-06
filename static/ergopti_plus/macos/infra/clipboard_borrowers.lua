--- infra/clipboard_borrowers.lua

--- ==============================================================================
--- MODULE: Clipboard Borrowing Admission
--- DESCRIPTION:
--- The pasteboard is process-global, but each family that snapshots it and
--- publishes a temporary payload (Text actions, Apps copy capture, Search, the
--- TextSender fast paste, keymap output) keeps its own lifecycle. Each family
--- registers whether it currently holds a borrowed clipboard, and asks here
--- before taking a snapshot, so it never saves another family's temporary
--- payload as the user's clipboard.
---
--- FEATURES & RATIONALE:
--- 1. No second lifecycle: a family's own in-flight state (including retained
---    restore debt) is the receipt, so a borrow is released exactly when that
---    family releases the clipboard, with no extra release path to forget.
--- 2. Fails closed: a predicate that raises counts as holding the clipboard.
--- 3. Pure Lua with no native dependency, so it loads in every unit test.
--- ==============================================================================

local M = {}

-- Family name -> predicate returning true while that family holds a borrow
local _borrowers = {}





-- ==============================
-- ==============================
-- ======= 1/ Public API ========
-- ==============================
-- ==============================

--- Registers one borrowing family. Registering the same family again replaces
--- its predicate (a reloaded module instance).
--- @param family string Stable family name.
--- @param holds function Returns true while the family holds a borrowed clipboard.
function M.register(family, holds)
	assert(type(family) == "string" and family ~= "", "a clipboard borrower needs a family name")
	assert(type(holds) == "function", "a clipboard borrower needs a holds predicate")
	_borrowers[family] = holds
end

--- Names another family that holds a borrowed clipboard, or nil when none does.
--- @param family string The asking family.
--- @return string|nil holder
function M.foreign_holder(family)
	for name, holds in pairs(_borrowers) do
		if name ~= family then
			local ok, held = pcall(holds)
			if not ok or held == true then return name end
		end
	end
	return nil
end

return M
