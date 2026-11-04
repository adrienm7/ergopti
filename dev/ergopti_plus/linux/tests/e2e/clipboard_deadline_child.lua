--- tests/e2e/clipboard_deadline_child.lua

--- ==============================================================================
--- MODULE: Clipboard Deadline E2E Child
--- DESCRIPTION:
--- Uses the real display detector, shell runner and clipboard stage with private
--- executable backends. A refused setter must emit no paste keys and must retain
--- the saved clipboard until a later compensation succeeds.
--- ==============================================================================

local source = debug.getinfo(1, "S").source:gsub("^@", "")
local driver = source:match("^(.*)/tests/e2e/clipboard_deadline_child%.lua$") or "."
package.path = driver .. "/?.lua;" .. driver .. "/?/init.lua;"
	.. driver .. "/../_shared/lua/?.lua;" .. driver .. "/../_shared/lua/?/init.lua;" .. package.path

local uv = require("luv")
local root = assert(uv.fs_mkdtemp(uv.os_tmpdir() .. "/ergopti-clipboard-e2e-XXXXXX"))

local function write(path, text)
	local file = assert(io.open(path, "wb"))
	assert(file:write(text)); assert(file:close())
end

local function read(path)
	local file = assert(io.open(path, "rb"))
	local text = assert(file:read("*a")); assert(file:close())
	return text
end

local okay, detail = xpcall(function()
	for _, name in ipairs({ "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME", "XDG_RUNTIME_DIR" }) do
		local path = root .. "/" .. name
		assert(uv.fs_mkdir(path, 448))
		assert(uv.os_setenv(name, path))
	end
	assert(uv.os_unsetenv("XDG_STATE_HOME"))
	assert(uv.os_unsetenv("DISPLAY"))
	assert(uv.os_setenv("WAYLAND_DISPLAY", "ergopti-private-fixture"))
	assert(uv.os_setenv("XDG_SESSION_TYPE", "wayland"))
	assert(uv.os_setenv("PATH", root .. ":" .. assert(os.getenv("PATH"))))
	local Shell = require("adapters.shell_runner")
	local current, delayed = Shell.quote(root .. "/current"), Shell.quote(root .. "/delayed")
	write(root .. "/wl-paste", "#!/bin/sh\nexec cat " .. current .. "\n")
	write(root .. "/wl-copy", "#!/bin/sh\nset -eu\ncat > " .. Shell.quote(root .. "/input")
		.. "\nif [ -f " .. delayed .. " ]; then exec sleep 2; fi\ncat "
		.. Shell.quote(root .. "/input") .. " > " .. current .. "\n")
	assert(uv.fs_chmod(root .. "/wl-paste", 448))
	assert(uv.fs_chmod(root .. "/wl-copy", 448))
	local Clipboard = require("adapters.clipboard")
	local paste_key = 47 -- The fixture supplies the already-resolved KEY_V kernel code.
	local saved = "saved 🌿\n\n"
	local replacement = "' $HOME $(false) `false`\n\n"
	write(root .. "/current", saved)
	local keys, target = {}, ""
	local channel = { emit = function(code, value)
		keys[#keys + 1] = { code, value }
		if code == paste_key and value == 1 then target = read(root .. "/current") end
		return true
	end }
	local stage = Clipboard.new_paste_stage(replacement, uv.sleep, paste_key)
	assert(stage.prepare() == true, "healthy clipboard preparation must succeed")
	assert(read(root .. "/input") == replacement, "the setter must receive exact bytes")
	assert(stage.paste(channel) == true and #keys == 4 and target == replacement,
		"the prepared paste must deliver the replacement through one complete chord")
	assert(stage.close() == true and read(root .. "/current") == saved,
		"a successful paste must restore the exact original selection")
	write(root .. "/delayed", "yes")
	local refused = Clipboard.new_paste_stage(replacement, uv.sleep, paste_key)
	assert(refused.prepare() == false, "a setter deadline must refuse preparation")
	assert(refused.paste(channel) == false and #keys == 4,
		"a timed-out preparation must emit no additional paste keys")
	assert(read(root .. "/current") == saved, "expired setters must not publish bytes")
	assert(os.remove(root .. "/delayed"))
	assert(refused.close() == true and read(root .. "/current") == saved,
		"the retained clipboard restoration must settle on retry")
end, debug.traceback)

-- Only files created in this private child are eligible for retirement.
for _, leaf in ipairs({ "wl-copy", "wl-paste", "current", "input", "delayed" }) do
	local path = root .. "/" .. leaf
	if uv.fs_stat(path) then assert(uv.fs_unlink(path)) end
end
for _, name in ipairs({ "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME", "XDG_RUNTIME_DIR" }) do
	local path = root .. "/" .. name
	if uv.fs_stat(path) then
		-- Runtime diagnostics can create files below the private cache.
		local Shell = require("adapters.shell_runner")
		assert(Shell.run("rm -rf " .. Shell.quote(path)))
	end
end
assert(uv.fs_rmdir(root))
if not okay then error(detail, 0) end
print("E2E_CLIPBOARD_DEADLINE_CLEAN")
