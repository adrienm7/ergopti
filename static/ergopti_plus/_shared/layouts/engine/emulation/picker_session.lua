--- _shared/layouts/engine/emulation/picker_session.lua

--- ==============================================================================
--- MODULE: Emulation Picker Session (Shared)
--- DESCRIPTION:
--- The page contract of the emulation picker window (_shared/ui/emulation_picker),
--- « Layout to emulate › Others… », for the macOS and Linux hosts; the Windows
--- host (ui/emulation_picker/init.ahk) answers the same messages. The host
--- supplies the catalogue and the write the menu uses; the session admits only
--- a choice it offered, for its own token, so a page cannot write a layout id
--- of its own making.
--- ==============================================================================

local M = {}

-- The page's identity, read by every host: its folder under _shared/ui/ and
-- apps.manifest.json key, and the bridge it posts to (host_bridge.js).
M.APP_ID = "emulation_picker"
M.BRIDGE_NAME = "emulation_picker_bridge"

local Session = {}
Session.__index = Session

-- One token per window: a message from a page the host replaced is refused.
local _serial = 0

--- Opens one session.
--- @param opts table { choices = function() -> array of { id, label, current },
---   choose = function(id) -> boolean committed }
--- @return table session
function M.new(opts)
	if type(opts) ~= "table" or type(opts.choices) ~= "function" or type(opts.choose) ~= "function" then
		error("The emulation picker needs its choices and choose ports.")
	end
	_serial = _serial + 1
	return setmetatable({ token = "emulation-picker-" .. _serial, choices = opts.choices, choose = opts.choose,
		closed = false, offered = nil, busy = false }, Session)
end

--- The state the page receives.
--- @param refused boolean Whether the host refused the last choice.
--- @return table state { session, choices, refused? }
function Session:state(refused)
	return { session = self.token, choices = self.offered, refused = refused == true or nil }
end

--- Handles one page message.
--- @param payload any "ready", or { action = "choose", session, id } or { action = "cancel", session }.
--- @return table|nil reply The state to push to the page.
--- @return boolean close Whether the host closes the window.
function Session:handle(payload)
	if self.closed or self.busy then return nil, false end
	if payload == "ready" then
		self.offered = self.choices()
		return self:state(false), false
	end
	if type(payload) ~= "table" then return nil, false end
	-- The page may close before its catalogue arrived: it has no token yet.
	if payload.action == "cancel" and (payload.session == self.token or payload.session == "") then
		self.closed = true
		return nil, true
	end
	if payload.action ~= "choose" or payload.session ~= self.token or type(self.offered) ~= "table" then
		return nil, false
	end
	local offered = false
	for _, choice in ipairs(self.offered) do offered = offered or choice.id == payload.id end
	if not offered then return nil, false end
	self.busy = true
	local called, committed = pcall(self.choose, payload.id)
	self.busy = false
	-- The host reports a failed write; a raised one is a defect it must see.
	if not called then error(committed, 0) end
	if committed == true then
		self.closed = true
		return nil, true
	end
	return self:state(true), false
end

--- Ends the session: later messages are refused.
function Session:close()
	self.closed = true
end

return M
