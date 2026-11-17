--- ai/ui/menu/local_server_rows.lua

--- Native prompts and acknowledged local API selections for the shared menu.
local M = {}
local Servers = require("ai.engine.local_servers.local_servers")
local Menu = require("ai.engine.local_servers.menu")
local Remote = require("ai.engine.api.api_remote")
local Entries = require("ai.engine.settings.api_entries")
local I18n = require("core.i18n.engine.i18n")
local Logger = require("core.logger.engine.shim")
local LOG = "ai.ui.menu.local_server_rows"
local function format(key, ...)
	local values = { ... }
	return (I18n.get(key):gsub("{(%d+)}", function(index) return tostring(values[tonumber(index)] or "") end))
end

--- The rows are inert and no sweep probes a server while the AI is off, as on
--- Windows and macOS (issue #97); switching the AI on rebuilds and sweeps them.
--- A pause stops typing, not configuration (EDD-1): a model choice, an address
--- and a key commit while paused, from the verdicts the pause kept; only the
--- sweep, which talks to the servers, waits for the resume, and a rescan asked
--- while paused says so with the paused notice, as on Windows and macOS.
--- The options of the shared local-server projection, with this driver's actions.
--- @return table options For llm.local_server_menu rows or page_rows.
local function server_options(llm, dialogs, changed, context)
	--- The actual pause owner's state, nil when it is missing or unreadable.
	local function pause_state()
		if type(context) ~= "table" then return nil end
		return Menu.pause_state(context.is_paused)
	end
	local function page_owned()
		if context.page_current == nil then return true end
		local ok, current = pcall(context.page_current)
		return ok and current == true
	end
	-- Views, receipts and writes: a readable pause owner, paused or not.
	local function admit()
		if type(context) ~= "table" or not page_owned() then return false end
		if pause_state() == nil or not page_owned()
			or type(llm.can_configure_local_servers) ~= "function" then return false end
		local scope_ok, allowed = pcall(llm.can_configure_local_servers)
		return scope_ok and allowed == true and page_owned()
	end
	-- Sweeps and probes: only while not paused.
	local function network_admit() return admit() and pause_state() == false end
	local function ai_on()
		if type(llm.is_enabled) ~= "function" then return false end
		local ok, enabled = pcall(llm.is_enabled)
		return ok and enabled == true
	end
	-- The sweep's own fences recheck the switch: one switched off mid-sweep publishes nothing.
	local function sweep_admit() return network_admit() and ai_on() and network_admit() end
	local function redraw() if type(changed) == "function" then changed() end end
	local function rescan()
		return Servers.rescan(sweep_admit, function(changed_models) if changed_models then redraw() end end)
	end
	-- The rescan the user asks for waits for the resume and says so.
	local function rescan_asked()
		if pause_state() ~= true then return rescan() end
		Logger.warn(LOG, "The local server rescan was refused while paused.")
		-- A notification caption, not a menu row: it never reaches the renderer.
		local caption = I18n.get("menu.llm.local_servers.header")
		local ok, sent = pcall(function()
			return require("platform.focus.application_notifier").send(I18n.get("notify.paused_refused"),
				{ title = caption, level = "warning" })
		end)
		if not ok or sent ~= true then Logger.warn(LOG, "The paused rescan notice was not delivered.") end
		return false
	end
	if sweep_admit() and Servers.is_stale() then rescan() end
	local receipts = {}
	for _, id in ipairs(Servers.order()) do receipts[id] = Servers.capture(id) end
	local function apply(id, fields)
		local result = Servers.apply(receipts[id], fields, admit)
		if not result then return false end
		if fields.model ~= nil then
			-- JSON and the backend preference have independent publication owners.
			-- A refusal after the first ACK leaves the saved entry visible and the
			-- previous backend selected; it never pretends to roll back both files.
			local source = Entries.capture_source()
			local function selection_current()
				local active = Entries.active()
				return admit() and source ~= nil and Entries.source_is_current(source)
					and active ~= nil and active.id == result.entry.id and active.model == fields.model
				end
			result.selected = selection_current() and llm.set_backend("api", selection_current) == true
			if not result.selected then
				Logger.warn(LOG, "The local API entry was saved; its backend selection was refused.")
			end
		end
		redraw()
		-- Paused, the new address or key is swept by the resume's menu.
		if network_admit() then rescan() end
		return result
	end
	local function prompt(id, key)
		if not admit() or not Servers.is_current(receipts[id]) then return false end
		local target, server = Servers.target(id), Servers.servers()[id]
		local address = key == "base_url"
		local text = format(address and "dialog.local_servers.address_prompt" or "dialog.local_servers.key_prompt",
			server.label, server.base_url)
		local value = dialogs.prompt(I18n.get("menu.llm.local_servers.header"), text,
			address and target.base_url or "", not address)
		if value == nil or not admit() then return false end
		if address and not Remote.normalize_base_url(value) then
			dialogs.error(format("llm.local_servers.invalid_address", server.base_url), server.label)
			return false
		end
		-- The actual opaque source/view receipt and live scope/pause admission are
		-- rechecked after the blocking dialog, before the private publisher.
		return apply(id, { [key] = value })
	end
	return { order = Servers.order(), servers = Servers.servers(), detected = Servers.detected(),
		result = Servers.result, sweeping = Servers.is_sweeping(),
		-- A pause greys nothing: only the AI off, an unreadable pause or the
		-- verdicts a pause holds without current evidence leave the rows inert.
		inert = not (admit() and ai_on()) or Servers.is_held(),
		entry_id = function(id) local target = Servers.target(id); return target and target.entry_id end,
		backend = llm.get_backend(), active = Entries.active(), tr = I18n.get, format = format,
		actions = { select = function(id, model) return apply(id, { model = model }) end,
			address = function(id) return prompt(id, "base_url") end,
			key = function(id) return prompt(id, "token") end, rescan = rescan_asked } }
end

--- The local servers as shared menu rows, with this driver's actions: the
--- projection the behaviour suite drives (the page reads page_rows below).
--- @return table rows
function M.rows(llm, dialogs, changed, context)
	return Menu.rows(server_options(llm, dialogs, changed, context))
end

--- The local servers' rows of the model selector page, and the API group's tools.
--- @return table rows, table tools As llm.local_server_menu.page_rows.
function M.page_rows(llm, dialogs, changed, context)
	return Menu.page_rows(server_options(llm, dialogs, changed, context))
end

return M
