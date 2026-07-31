--- modules/ui/bridge_handlers/action_picker_bridge.lua

--- ==============================================================================
--- BRIDGE HANDLER: Action Picker
--- Handles JS→Lua messages from _shared/ui/action_picker/.
--- Bridge name: "action_picker_bridge"
---
--- THE PROTOCOL THIS SPEAKS IS THE PAGE'S, NOT AN INVENTED ONE.
--- This handler used to answer "execute" and "search" and return three
--- hardcoded French labels. The page posts neither: it sends
--- {action="confirm", id=…} on a pick, {action="cancel"} on dismiss, and
--- "ready" once. Nothing on either side matched, so the picker did nothing on
--- Linux — and it also never received init(…), so it rendered empty. A bridge
--- answering messages that are never sent looks implemented from both ends.
---
--- STILL MISSING, DELIBERATELY MARKED: the host→page push. init(data) has to be
--- evaluated IN the webview after "ready", and a bridge handler is given only
--- (payload, state) — no webview reference — so the channel does not exist yet.
--- build_init_payload() below produces exactly what init(data) expects and is
--- covered by tests, so the day the channel lands the payload is already right.
--- ==============================================================================

local M = {}
M.bridge_name = "action_picker_bridge"

local Logger = require("logger.shim")
local LOG = "bridge.action_picker"

-- Forward declarations (defined before on_message for scoping).
local _handle_json, _handle_table

--- Handles a JSON string payload (shared — no duplicated JSON parsing).
local function _handle_json(payload_str, state)
	local ok, data = pcall(function()
		local json_mod = require("json")
		return json_mod.decode(payload_str)
	end)
	if not ok or type(data) ~= "table" then
		return nil
	end
	return _handle_table(data, state)
end

--- Builds the payload the page's init(data) expects.
---
--- The shape is the page's contract, not this driver's: title/label/
--- searchPlaceholder/cancelLabel/noneLabel strings, `current` (the id already
--- bound), `allowNative`, and an ordered `items` list of
--- {type="heading",level,text} / {type="action",id,label}. Every string comes
--- from i18n — the three hardcoded French labels this handler used to return
--- were not translations of anything, they were invented here.
--- @param opts table|nil { current: string|nil, allow_native: boolean|nil }
--- @return table Payload for init(data).
function M.build_init_payload(opts)
	local o = type(opts) == "table" and opts or {}
	local i18n = require("lib.i18n")

	local items = {}
	local ok_actions, Actions = pcall(require, "modules.gestures.actions")
	if ok_actions and type(Actions.get_sg_names) == "function" then
		for _, name in ipairs(Actions.get_sg_names() or {}) do
			if name == "-" then
				-- Separator: the page has no separator entry, so it is dropped
				-- rather than rendered as an action with an empty label.
			elseif name:sub(1, 1) == "#" then
				local hashes = name:match("^#+")
				items[#items + 1] = {
					type  = "heading",
					level = #hashes,
					text  = name:sub(#hashes + 1),
				}
			else
				items[#items + 1] = {
					type  = "action",
					id    = name,
					label = (type(Actions.get_label) == "function") and Actions.get_label(name) or name,
				}
			end
		end
	end

	-- The same keys macOS uses (macos/ui/action_picker/init.lua), so the two
	-- hosts show the same words rather than two translations of one idea.
	return {
		title             = o.title or "",
		label             = o.label or i18n.get("dialog.action_picker.label"),
		current           = o.current or "none",
		allowNative       = o.allow_native == true,
		nativeLabel       = o.native_label or "",
		noneLabel         = i18n.get("dialog.action_picker.disabled"),
		searchPlaceholder = i18n.get("dialog.action_picker.search"),
		noResults         = i18n.get("dialog.action_picker.no_results"),
		cancelLabel       = i18n.get("button.cancel"),
		items             = items,
	}
end

--- Handles a structured table payload — the page's real protocol.
local function _handle_table(data, state)
	local action = data.action

	if action == "confirm" then
		-- The id is what the user picked; "none" and "__native__" are the two
		-- specials the page prepends and are passed through unchanged so the
		-- caller decides what they mean.
		Logger.info(LOG, "Action picker confirmed: %s", tostring(data.id))
		if type(M.on_confirm) == "function" then
			pcall(M.on_confirm, data.id, state)
		end
		return nil
	end

	if action == "cancel" then
		Logger.info(LOG, "Action picker cancelled.")
		if type(M.on_cancel) == "function" then
			pcall(M.on_cancel, state)
		end
		return nil
	end

	if action == "ready" then
		Logger.info(LOG, "Action picker UI ready.")
		return nil
	end

	Logger.warn(LOG, "Unknown action from the picker page: %s", tostring(action))
	return nil
end

--- Handles an incoming JS message.
--- @param payload any  String or table from host_bridge.js.
--- @param state  table Daemon state { engine, keylogger, config, llm, layout }.
--- @return any|nil  Response to send back to JS (if any).
function M.on_message(payload, state)
	if type(payload) == "string" then
		-- "ready" arrives as a bare string from the page's own post({action:…})
		-- only after JSON encoding, so the bare form is the host_bridge fallback.
		if payload == "ready" then
			Logger.info(LOG, "Action picker UI ready.")
			return nil
		end
		return _handle_json(payload, state)
	end

	if type(payload) == "table" then
		return _handle_table(payload, state)
	end

	Logger.warn(LOG, "Unknown payload type: %s", type(payload))
	return nil
end

return M
