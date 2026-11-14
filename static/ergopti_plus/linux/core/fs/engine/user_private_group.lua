--- core/fs/engine/user_private_group.lua

--- ==============================================================================
--- MODULE: User Private Group (Linux)
--- DESCRIPTION:
--- Tells whether a group id is the current user's own private group: the
--- group named like the user, holding the user's primary gid, that no other
--- account shares. Debian, Ubuntu, Fedora and Arch create one per account and
--- default to umask 0002, so folders an application creates there are
--- group-writable without granting anyone else write access. The managed
--- Ollama installer admits that write bit on its ancestors and still refuses
--- every other shared group.
---
--- FEATURES & RATIONALE:
--- 1. The answer comes from the system account databases (NSS) through
---    getpwuid, getgrgid and a getpwent walk, so LDAP or systemd-homed
---    accounts count like /etc/passwd ones.
--- 2. Fail closed: any lookup that fails or any member, listed or primary,
---    other than the user makes the group shared.
--- 3. The rule itself (M.is_private) is pure, so the installer's tests can
---    drive every case without touching the real databases.
--- ==============================================================================

local M = {}

local CDEF = [[
	typedef unsigned int ergopti_upg_id_t;
	struct ergopti_upg_passwd {
		char *pw_name; char *pw_passwd; ergopti_upg_id_t pw_uid; ergopti_upg_id_t pw_gid;
		char *pw_gecos; char *pw_dir; char *pw_shell;
	};
	struct ergopti_upg_group { char *gr_name; char *gr_passwd; ergopti_upg_id_t gr_gid; char **gr_mem; };
	ergopti_upg_id_t getuid(void);
	struct ergopti_upg_passwd *getpwuid(ergopti_upg_id_t uid);
	struct ergopti_upg_group *getgrgid(ergopti_upg_id_t gid);
	void setpwent(void);
	struct ergopti_upg_passwd *getpwent(void);
	void endpwent(void);
]]

--- Applies the private-group rule to account facts.
--- @param user table { name, uid, gid } The current account.
--- @param group table { name, gid, members } The group under test.
--- @param accounts table List of { name, uid, gid }: every account the system knows.
--- @return boolean
function M.is_private(user, group, accounts)
	if type(user) ~= "table" or type(group) ~= "table" or type(accounts) ~= "table"
		or type(user.name) ~= "string" or user.name == "" or type(user.gid) ~= "number"
		or type(group.gid) ~= "number" or type(group.members) ~= "table" then return false end
	if group.name ~= user.name or group.gid ~= user.gid then return false end
	for _, member in ipairs(group.members) do
		if member ~= user.name then return false end
	end
	for _, account in ipairs(accounts) do
		if type(account) ~= "table" then return false end
		if account.gid == group.gid and (account.uid ~= user.uid or account.name ~= user.name) then return false end
	end
	return true
end

--- Reads the account facts of the current user from the system databases.
--- @param gid number The group under test.
--- @return table|nil user, table|nil group, table|nil accounts
local function system_facts(gid)
	local loaded, ffi = pcall(require, "ffi")
	if not loaded then return nil end
	-- The declarations are process-wide: another instance may own them already.
	if not pcall(ffi.typeof, "struct ergopti_upg_group") and not pcall(ffi.cdef, CDEF) then return nil end
	local read, user, group, accounts = pcall(function()
		local C = ffi.C
		local entry = C.getpwuid(C.getuid())
		if entry == nil or entry.pw_name == nil then return nil end
		local me = { name = ffi.string(entry.pw_name), uid = tonumber(entry.pw_uid), gid = tonumber(entry.pw_gid) }
		local found = C.getgrgid(gid)
		if found == nil or found.gr_name == nil then return nil end
		local members, index = {}, 0
		while found.gr_mem ~= nil and found.gr_mem[index] ~= nil do
			members[#members + 1] = ffi.string(found.gr_mem[index])
			index = index + 1
		end
		local team = { name = ffi.string(found.gr_name), gid = tonumber(found.gr_gid), members = members }
		local known = {}
		C.setpwent()
		local account = C.getpwent()
		while account ~= nil do
			known[#known + 1] = {
				name = account.pw_name ~= nil and ffi.string(account.pw_name) or "",
				uid = tonumber(account.pw_uid), gid = tonumber(account.pw_gid),
			}
			account = C.getpwent()
		end
		C.endpwent()
		return me, team, known
	end)
	if not read then return nil end
	return user, group, accounts
end

--- Whether `gid` is the current user's private group, from the system databases.
--- @param gid number
--- @return boolean
function M.is_current_user_private(gid)
	if type(gid) ~= "number" or gid < 0 or gid % 1 ~= 0 then return false end
	local user, group, accounts = system_facts(gid)
	if not user then return false end
	return M.is_private(user, group, accounts)
end

return M
