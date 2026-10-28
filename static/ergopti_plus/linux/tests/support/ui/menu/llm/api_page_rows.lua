--- tests/support/ui/menu/llm/api_page_rows.lua

--- ==============================================================================
--- MODULE: API Page Rows In Transaction-Test Shape
--- DESCRIPTION:
--- The API entries left the tray for the model selector page on 2026-10-27
--- (ui/menu/llm_backend_rows.lua api_page). The transaction suites written for
--- the tray rows read labels and actions; this adapter lays the page's real
--- closures out in that shape — each entry (chat: selectable; other: its Test
--- and Remove), the active entry's Test and Remove, and one "➕ provider" row
--- per provider — so they keep driving the very same transactions.
--- ==============================================================================

local M = {}

--- The API page of the real module, shaped as the former tray rows.
--- @param Rows table ui.menu.llm_backend_rows
--- @param llm table Engine double.
--- @param dialogs table Dialog doubles.
--- @param changed function|nil
--- @param context table|nil
--- @return table rows
function M.rows(Rows, llm, dialogs, changed, context)
	local api = Rows.api_page(llm, dialogs, changed, context)
	local rows, active = {}, nil
	for _, row in ipairs(api.rows) do
		if row.available ~= false and type(row.run) == "function" then
			rows[#rows + 1] = { label = row.name, checked = row.current == true, action = row.run }
			if row.current then active = row end
		else
			local items = {}
			for _, action in ipairs(row.actions or {}) do
				items[#items + 1] = { label = (action.id == "remove" and "🗑️ " or "") .. action.text, action = action.run }
			end
			rows[#rows + 1] = { label = row.name, items = items }
		end
	end
	local add = {}
	for _, provider in ipairs(api.providers) do
		add[#add + 1] = { label = "➕ " .. provider.label, action = provider.run }
	end
	rows[#rows + 1] = { label = "➕ menu.llm.api_add_entry", items = add }
	if active then
		for _, action in ipairs(active.actions) do
			local label = action.id == "remove" and ("🗑️ " .. action.text .. " (" .. active.name .. ")") or action.text
			rows[#rows + 1] = { label = label, action = action.run }
		end
	end
	return rows
end

return M
