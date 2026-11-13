--- tests/hardware/clipboard/run_owner.lua

--- ==============================================================================
--- MODULE: Multi-Format Clipboard Owner Receipt
--- DESCRIPTION:
--- Proves clipboard/adapters/owner_worker.lua against a real display server:
--- the owner takes the clipboard with a text, an HTML and a 300 kB binary
--- target (above one X11 request, so INCR runs), each target reads back byte
--- for byte through the session's own clipboard tool, the snapshot file is
--- gone, and the owner exits once another client copies. The unit tests cover
--- the adapter's save and restore; only a real server proves the protocols.
---
--- Run from the Linux driver root, inside a session of the backend named:
---     DISPLAY=:77 luajit tests/hardware/clipboard/run_owner.lua x11       (Xvfb, xclip)
---     WAYLAND_DISPLAY=wayland-1 luajit tests/hardware/clipboard/run_owner.lua wayland
---         (a data-control compositor such as sway --backend headless, wl-clipboard)
--- ==============================================================================

local Worker = dofile("clipboard/adapters/owner_worker.lua")

local backend = arg[1]
assert(backend == "x11" or backend == "wayland", "usage: run_owner.lua x11|wayland")
local soname = backend == "x11" and "libX11.so.6" or "libwayland-client.so.0"

local IMAGE = string.rep("\0\1\2\255PNG", 50000)
local TARGETS = {
	{ name = "UTF8_STRING", data = "héllo wörld" },
	{ name = "text/html", data = "<b>héllo</b>" },
	{ name = "image/png", data = IMAGE },
}

local function sh(command)
	local result = os.execute(command)
	return result == true or result == 0
end

local function read_target(name)
	local command = backend == "x11"
		and "timeout 3 xclip -selection clipboard -t '" .. name .. "' -o"
		or "timeout 3 wl-paste --no-newline --type '" .. name .. "'"
	local pipe = assert(io.popen(command))
	local bytes = pipe:read("*a")
	pipe:close()
	return bytes
end

-- The bracket keeps pgrep from matching the shell that runs it.
local function owner_running()
	return sh("pgrep -f '[c]lipboard_owner_worker.lua own' >/dev/null")
end

assert(not owner_running(), "another clipboard owner already runs: its exit would be counted as this one's")

local path = os.tmpname()
local file = assert(io.open(path, "wb"))
file:write(Worker.encode(TARGETS))
file:close()

local worker = "luajit clipboard/adapters/owner_worker.lua"
assert(sh(worker .. " probe " .. backend .. " " .. soname), "the probe passes on this session")
assert(sh(worker .. " own " .. backend .. " " .. soname .. " " .. path), "the owner takes the selection")
assert(io.open(path, "rb") == nil, "the owner removes the snapshot file once read")
for _, target in ipairs(TARGETS) do
	local bytes = read_target(target.name)
	assert(bytes == target.data, string.format("%s reads back exactly (%d of %d bytes)", target.name, #bytes, #target.data))
end
assert(owner_running(), "the owner keeps serving")
assert(sh(backend == "x11" and "printf other | xclip -selection clipboard -in" or "printf other | wl-copy"),
	"another client copies")
sh("sleep 0.5")
assert(not owner_running(), "the owner exits once another client owns the clipboard")
io.write("clipboard owner receipts (" .. backend .. "): ok\n")
