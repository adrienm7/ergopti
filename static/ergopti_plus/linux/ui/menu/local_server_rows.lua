--- ui/menu/local_server_rows.lua

--- Native prompts and acknowledged local API selections for the shared menu.
local M = {}
local Servers = require("modules.llm.local_servers")
local Menu = require("llm.local_server_menu")
local Remote = require("modules.llm.api_remote")
local Entries = require("modules.llm.api_entries")
local I18n = require("infra.i18n")
local Logger = require("logger.shim")
local LOG = "ui.menu.local_server_rows"
local function format(key, ...)
	local values = { ... }
	return (I18n.get(key):gsub("{(%d+)}", function(index) return tostring(values[tonumber(index)] or "") end))
end

--- Configuration remains available while the prediction master is OFF.
function M.rows(llm, dialogs, changed, context)
	local function admit()
		return type(context) == "table" and type(context.is_paused) == "function"
			and context.paused ~= true and context.is_paused() ~= true
			and type(llm.can_configure_local_servers) == "function" and llm.can_configure_local_servers() == true
	end
	local function redraw() if type(changed) == "function" then changed() end end
	local function rescan()
		return Servers.rescan(admit, function(changed_models) if changed_models then redraw() end end)
	end
	if admit() and Servers.is_stale() then rescan() end
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
		if admit() then rescan() end
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
		if value == nil then return false end
		if address and not Remote.normalize_base_url(value) then
			dialogs.error(format("llm.local_servers.invalid_address", server.base_url), server.label)
			return false
		end
		-- The actual opaque source/view receipt and live scope/pause admission are
		-- rechecked after the blocking dialog, before the private publisher.
		return apply(id, { [key] = value })
	end
	return Menu.rows({ order = Servers.order(), servers = Servers.servers(), detected = Servers.detected(),
		result = Servers.result, sweeping = Servers.is_sweeping(), paused = not admit(),
		backend = llm.get_backend(), active = Entries.active(), tr = I18n.get, format = format,
		actions = { select = function(id, model) return apply(id, { model = model }) end,
			address = function(id) return prompt(id, "base_url") end,
			key = function(id) return prompt(id, "token") end, rescan = rescan } })
end
return M
