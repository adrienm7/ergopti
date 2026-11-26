--- _shared/ai/engine/local_servers/menu.lua

--- _shared/ai/engine/local_servers/menu.lua

--- Catalogue-ordered local API menu rows. Drivers provide their current source,
--- translated strings and acknowledged native actions; no credential or native
--- transport is owned by this view policy. A pause greys no row (EDD-1): only
--- an inert view (the AI off, an unreadable pause, or verdicts a pause holds
--- without current evidence) shows its verdicts without actions.
local M = {}
local Discovery = require("ai.engine.local_servers.discovery")
local Labels = require("menu.engine.labels")

--- Matches the actual captured entry when supplied by a native source owner.
--- @param options table
--- @param id string
--- @return boolean
local function active_matches(options, id)
	local active = options.active
	if type(active) ~= "table" then return false end
	if type(options.entry_id) == "function" then
		local entry_id = options.entry_id(id)
		return type(entry_id) == "string" and entry_id ~= "" and active.id == entry_id
	end
	return active.provider == id
end

--- Reads a driver's live pause owner for these rows (EDD-1): paused, the rows
--- still commit and only the sweep waits; an unreadable owner refuses both.
--- @param is_paused any The driver's pause reader.
--- @return boolean|nil paused Nil when the reader is missing, throws or is untyped.
function M.pause_state(is_paused)
	if type(is_paused) ~= "function" then return nil end
	local ok, paused = pcall(is_paused)
	if not ok or type(paused) ~= "boolean" then return nil end
	return paused
end

--- The authority displayed beside a configured server address.
--- @param base_url string
--- @return string
function M.host_of(base_url)
	return tostring(base_url):match("^%a[%w+.-]*://([^/]+)") or tostring(base_url)
end

--- The name of the server a verdict answered for: the row's own label, or the
--- label of the row of the same address its response fingerprinted
--- (llm.local_server_fingerprint), so vLLM on oMLX's port is named vLLM.
--- @param servers table View id -> { label }.
--- @param id string The row.
--- @param verdict table|nil Its published verdict.
--- @return string
function M.label_of(servers, id, verdict)
	local named = type(verdict) == "table" and verdict.server or nil
	if type(named) == "string" and type(servers[named]) == "table" then return servers[named].label end
	return servers[id].label
end

--- Builds one catalogue server's model and configuration choices.
local function server_items(options, id, verdict)
	local items, disabled = {}, options.inert or nil
	local function action(name, model)
		return not options.inert and function() return options.actions[name](id, model) end or nil
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
			checked = options.backend == "api" and active_matches(options, id) and active.model == model,
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
--- @param options table { order, servers, detected, result, sweeping, inert,
--- backend, active, tr, format, actions = { select, address, key, rescan } }.
--- @return table
function M.rows(options)
	local rows = { { separator = true },
		{ label = Labels.decorate_section(options.tr("menu.llm.local_servers.header")), disabled = true } }
	local unavailable = false
	for _, id in ipairs(options.order) do
		local result = options.result(id)
		if result and result.status == Discovery.STATUS_UNAVAILABLE then unavailable = true end
	end
	if unavailable then rows[#rows + 1] = { label = options.tr("healthcheck.status.failed"), disabled = true } end
	for _, id in ipairs(options.detected) do
		local verdict = options.result(id)
		local label = M.label_of(options.servers, id, verdict) .. " 🖥️ — " .. M.host_of(verdict.base_url)
		if verdict.status == Discovery.STATUS_NEEDS_KEY then
			label = options.format("menu.llm.local_servers.needs_key", label)
		end
		rows[#rows + 1] = { label = label,
			checked = options.backend == "api" and active_matches(options, id),
			items = server_items(options, id, verdict) }
	end
	if #options.detected == 0 and not unavailable then
		-- A finished sweep says one sentence: the catalogue's server names stay in the
		-- local servers panel and the "other address" submenu, not in this row.
		if options.sweeping then
			local labels = {}
			for _, id in ipairs(options.order) do labels[#labels + 1] = options.servers[id].label end
			rows[#rows + 1] = { label = options.format("menu.llm.local_servers.searching",
				table.concat(labels, ", ")), disabled = true }
		else
			rows[#rows + 1] = { label = options.tr("menu.llm.local_servers.none_detected"), disabled = true }
		end
	end
	rows[#rows + 1] = { label = options.tr("menu.llm.local_servers.rescan"), disabled = options.inert or nil,
		action = not options.inert and options.actions.rescan or nil }
	local others = {}
	for _, id in ipairs(options.order) do
		others[#others + 1] = { label = options.servers[id].label, disabled = options.inert or nil,
			action = not options.inert and function() return options.actions.address(id) end or nil }
	end
	rows[#rows + 1] = { label = options.tr("menu.llm.local_servers.other_address"), items = others }
	return rows
end

--- Projects the same verdicts as rows of the model selector page: one row per
--- model a server serves, a server that wants its key as one greyed row, and
--- the sweep and the other addresses as tools of the API group. Each `run` is
--- the driver's own action; the driver keeps it and sends the page the rest.
--- @param options table As for M.rows.
--- @return table rows Page rows { name, runtime_name, provider, installed,
---   available, hint_key, run, actions = { { id, text, run } } }.
--- @return table tools { { id, text, run } } for the API group.
function M.page_rows(options)
	local rows, tools = {}, {}
	local live = not options.inert
	for _, id in ipairs(options.detected) do
		local verdict = options.result(id)
		local label = M.label_of(options.servers, id, verdict)
		local actions = {}
		if live then
			actions[#actions + 1] = { id = "set_key", text = options.tr("menu.llm.local_servers.api_key"),
				run = function() return options.actions.key(id) end }
			actions[#actions + 1] = { id = "address",
				text = options.format("menu.llm.local_servers.address", M.host_of(verdict.base_url)),
				run = function() return options.actions.address(id) end }
		end
		if verdict.status == Discovery.STATUS_NEEDS_KEY then
			rows[#rows + 1] = { name = label, provider = label, installed = true, available = false,
				hint_key = "model_browser.hint_api_no_key", actions = actions }
		else
			for _, model in ipairs(verdict.models) do
				rows[#rows + 1] = { name = label .. "/" .. model, runtime_name = model, provider = label,
					installed = true, actions = actions,
					run = live and function() return options.actions.select(id, model) end or nil }
			end
		end
	end
	if live then
		tools[#tools + 1] = { id = "rescan", text = options.tr("menu.llm.local_servers.rescan"),
			run = options.actions.rescan }
		for index, id in ipairs(options.order) do
			tools[#tools + 1] = { id = "address_" .. index,
				text = options.tr("menu.llm.local_servers.other_address") .. " — " .. options.servers[id].label,
				run = function() return options.actions.address(id) end }
		end
	end
	return rows, tools
end

return M
