--- infra/account_name.lua

--- ==============================================================================
--- MODULE: Linux Account Name
--- DESCRIPTION:
--- The name of the account the daemon runs as, for the log privacy redactor,
--- which scrubs it from every line. $USER, then $LOGNAME, then the passwd entry
--- of the effective user.
---
--- WHY THE PASSWD ENTRY:
--- A start with neither variable (`env -i`, a container entry point, a cron job, a
--- build sandbox) used to refuse the whole daemon with "Privacy initialization
--- refused", although the account has a name the system knows. Asking the system
--- is the same answer the shell would have exported, so the redactor still knows
--- the name it has to hide. When even that fails the caller refuses and says why.
--- ==============================================================================

local M = {}

--- The effective user's name from the passwd database, or nil (no luajit FFI, no
--- entry, an empty name).
--- @return string|nil
local function passwd_name()
	local ok_ffi, ffi = pcall(require, "ffi")
	if not ok_ffi then return nil end
	-- A second load of this module re-declares the same names; that error only
	-- means they are already there.
	pcall(ffi.cdef, [[
		typedef unsigned int ergopti_uid_t;
		struct ergopti_passwd_head { char *pw_name; };
		ergopti_uid_t geteuid(void);
		struct ergopti_passwd_head *getpwuid(ergopti_uid_t uid);
	]])
	local ok, name = pcall(function()
		local entry = ffi.C.getpwuid(ffi.C.geteuid())
		if entry == nil or entry.pw_name == nil then return nil end
		return ffi.string(entry.pw_name)
	end)
	if ok and type(name) == "string" and name ~= "" then return name end
	return nil
end

--- The account name.
--- @param getenv function|nil getenv(name) -> string|nil (default os.getenv).
--- @param lookup function|nil lookup() -> string|nil, the passwd lookup (default the FFI one).
--- @return string|nil name nil when no source knows it.
function M.resolve(getenv, lookup)
	getenv = getenv or os.getenv
	for _, variable in ipairs({ "USER", "LOGNAME" }) do
		local value = getenv(variable)
		if type(value) == "string" and value ~= "" then return value end
	end
	return (lookup or passwd_name)()
end

return M
