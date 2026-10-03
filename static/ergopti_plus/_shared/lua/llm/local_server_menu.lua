--- _shared/lua/llm/local_server_menu.lua

--- _shared/lua/llm/local_server_menu.lua

--- Catalogue-ordered local API menu rows. Drivers provide their current source,
--- translated strings and acknowledged native actions; no credential or native
--- transport is owned by this view policy.
local M = {}
local Discovery = require("llm.local_server_discovery")

--- The authority displayed beside a configured server address.
--- @param base_url string
--- @return string
function M.host_of(base_url)
	return tostring(base_url):match("^%a[%w+.-]*://([^/]+)") or tostring(base_url)
end

--- Builds one catalogue server's model and configuration choices.
local function server_items(options, id, verdict)
	local items, disabled = {}, options.paused or nil
	local function action(name, model)
		return not options.paused and function() return options.actions[name](id, model) end or nil
	end
	if verdict.status == Discovery.STATUS_NEEDS_KEY then
		items[#items + 1] = { label = options.tr("menu.llm.local_servers.api_key"), disabled = disabled,
			action = action("key") }
	elseif #verdict.models == 0 then
		items[#items + 1] = { label = options.tr("menu.llm.local_servers.no_models"), disabled = true }
	end
	for _, model in ipairs(verdict.models) do
		local active = options.active
		items[#items + 1] = { label = model,
			checked = options.backend == "api" and active ~= nil and active.provider == id and active.model == model,
			disabled = disabled, action = action("select", model) }
	end
	items[#items + 1] = { separator = true }
	items[#items + 1] = { label = options.format("menu.llm.local_servers.address", M.host_of(verdict.base_url)),
		disabled = disabled, action = action("address") }
	if verdict.status == Discovery.STATUS_UP then
		items[#items + 1] = { label = options.tr("menu.llm.local_servers.api_key"), disabled = disabled,
			action = action("key") }
	end
	return items
end

--- Returns rows from the current jointly published catalogue verdicts.
--- @param options table { order, servers, detected, result, sweeping, paused,
--- backend, active, tr, format, actions = { select, address, key, rescan } }.
--- @return table
function M.rows(options)
	local rows = { { separator = true }, { label = options.tr("menu.llm.local_servers.header"), disabled = true } }
	for _, id in ipairs(options.detected) do
		local verdict = options.result(id)
		local label = options.servers[id].label .. " 🖥️ — " .. M.host_of(verdict.base_url)
		if verdict.status == Discovery.STATUS_NEEDS_KEY then
			label = options.format("menu.llm.local_servers.needs_key", label)
		end
		rows[#rows + 1] = { label = label,
			checked = options.backend == "api" and options.active ~= nil and options.active.provider == id,
			items = server_items(options, id, verdict) }
	end
	if #options.detected == 0 then
		local labels = {}
		for _, id in ipairs(options.order) do labels[#labels + 1] = options.servers[id].label end
		local key = options.sweeping and "menu.llm.local_servers.searching" or "menu.llm.local_servers.none"
		rows[#rows + 1] = { label = options.format(key, table.concat(labels, ", ")), disabled = true }
	end
	rows[#rows + 1] = { label = options.tr("menu.llm.local_servers.rescan"), disabled = options.paused or nil,
		action = not options.paused and options.actions.rescan or nil }
	local others = {}
	for _, id in ipairs(options.order) do
		others[#others + 1] = { label = options.servers[id].label, disabled = options.paused or nil,
			action = not options.paused and function() return options.actions.address(id) end or nil }
	end
	rows[#rows + 1] = { label = options.tr("menu.llm.local_servers.other_address"), items = others }
	return rows
end

return M
