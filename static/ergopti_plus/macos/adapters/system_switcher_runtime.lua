--- adapters/system_switcher_runtime.lua

--- Resolves the signed native runtime's read-only switcher helper, never PATH.
local M = {}

--- Freezes the packaged digest and exact native file identity for admission.
--- The normal authenticated launcher owns this executable path and signed digest.
--- @return table|nil descriptor Missing source-only prerequisites refuse input.
function M.descriptor()
	local executable = os.getenv("ERGOPTI_LAUNCHER_EXECUTABLE")
	if type(executable) ~= "string" or executable:sub(1, 1) ~= "/" then return nil end
	local directory = executable:match("^(.*)/[^/]+$")
	if not directory or directory:sub(-15) ~= "/Contents/MacOS" then return nil end
	local helper = directory .. "/SystemSwitcherState"
	local attrs = hs.fs.symlinkAttributes(helper)
	if not attrs or attrs.mode ~= "file" then return nil end
	local input = io.open(directory .. "/../Resources/system-switcher-state.sha256", "rb")
	if not input then return nil end
	local bytes, closed = input:read(66), input:close()
	if closed ~= true or type(bytes) ~= "string" or #bytes ~= 65
		or bytes:sub(-1) ~= "\n" or not bytes:sub(1, 64):match("^[0-9a-f]+$") then return nil end
	return { path = helper, sha256 = bytes:sub(1, 64), dev = attrs.dev, ino = attrs.ino }
end

return M
