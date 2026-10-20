--- tests/support/evdev_capabilities_fixture.lua

--- ==============================================================================
--- MODULE: Controlled Evdev Capabilities
--- DESCRIPTION:
--- Explicit KEY/MSC/LED/REP descriptor model for syscall fixtures. The policy
--- remains the real Finder implementation, with its exact cache restored.
--- ==============================================================================

local name = "modules.hotstrings.device_finder"
local saved = package.loaded[name]
package.loaded[name] = nil
local finder = require(name)
package.loaded[name] = saved

local M = {}

--- Applies the original event-mask policy, never a fixture admission boolean.
--- @param mask number Descriptor event types.
--- @return boolean ok, string|nil reason
function M.policy(mask)
	return finder.is_interceptable_event_mask(mask)
end

--- Models EVIOCGBIT(0, 4) for controlled KEY/MSC/LED/REP keyboard descriptors.
--- @param fd any The fixture's acquired descriptor.
--- @param request number ioctl request.
--- @param count integer Bitmap length.
--- @return string bytes
function M.key_bits(fd, request, count)
	assert(fd ~= nil and request == 0x80044520 and count == 4)
	return string.char(19, 0, 18, 0)
end

return M
