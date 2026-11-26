--- tests/unit/modules/keymap/test_hyprland_reload_watch.lua

--- ==============================================================================
--- MODULE: Hyprland Configuration Reload Watch (Linux) Tests
--- DESCRIPTION:
--- Hyprland puts its configuration file's kb_layout back on every reload and
--- says so on its event socket; the watch calls its owner once per
--- `configreloaded>>` line, whatever the chunking, and ends for the session on
--- a refused connection, a read error or a closed socket
--- (hyprland-reload-reselect). The socket is a fake libuv pipe the test feeds.
--- ==============================================================================

local helpers = require("tests.helpers")
local Watch = require("modules.keymap.hyprland_reload_watch")

local ENV = { XDG_RUNTIME_DIR = "/run/user/1000", HYPRLAND_INSTANCE_SIGNATURE = "abc_123" }
local SOCKET = "/run/user/1000/hypr/abc_123/.socket2.sock"

--- A fake libuv pipe: records the connection, lets the test answer it and feed
--- the reader.
local function fake_pipe(options)
	options = options or {}
	local pipe = { closed = false, reading = false }
	function pipe:connect(path, callback)
		if options.connect_raises then error("EBADF") end
		self.path, self.on_connect = path, callback
	end
	function pipe:read_start(callback)
		self.reading, self.on_read = true, callback
	end
	function pipe:read_stop() self.reading = false end
	function pipe:is_closing() return self.closed end
	function pipe:close() self.closed = true end
	return pipe
end

local function owner(env, options)
	local pipes = {}
	local watch = Watch.new({
		getenv = function(name) return (env or ENV)[name] end,
		new_pipe = function()
			local pipe = fake_pipe(options)
			pipes[#pipes + 1] = pipe
			return pipe
		end,
	})
	return watch, pipes
end

helpers.describe("Hyprland reload watch (Linux)", function()
	helpers.it("calls its owner once per configreloaded line, across chunks (hyprland-reload-reselect)", function()
		local watch, pipes = owner()
		local reloads = 0
		helpers.assert_true(watch.start(function() reloads = reloads + 1 end))
		helpers.assert_eq(#pipes, 1)
		helpers.assert_eq(pipes[1].path, SOCKET, "the instance's event socket")
		helpers.assert_eq(watch.status(), "connecting")
		pipes[1].on_connect(nil)
		helpers.assert_eq(watch.status(), "watching")
		helpers.assert_true(pipes[1].reading)
		pipes[1].on_read(nil, "workspace>>2\nactivewindow>>kitty,~\nconfigrel")
		helpers.assert_eq(reloads, 0, "a partial line is no event")
		pipes[1].on_read(nil, "oaded>>\nactivelayout>>keyboard,ergol\n")
		helpers.assert_eq(reloads, 1)
		pipes[1].on_read(nil, "configreloaded>>\nconfigreloaded>>\n")
		helpers.assert_eq(reloads, 3)
		pipes[1].on_read(nil, "configreloadedx>>\nwindowtitle>>configreloaded>>\n")
		helpers.assert_eq(reloads, 3, "only the configreloaded event counts")
	end)

	helpers.it("drops an overlong event line without reading a reload in it (hyprland-reload-reselect)", function()
		local watch, pipes = owner()
		local reloads = 0
		watch.start(function() reloads = reloads + 1 end)
		pipes[1].on_connect(nil)
		pipes[1].on_read(nil, "windowtitle>>" .. string.rep("x", 5000))
		pipes[1].on_read(nil, "configreloaded>>\nconfigreloaded>>\n")
		helpers.assert_eq(reloads, 1, "the tail of the long line is dropped, the next line is read")
		helpers.assert_eq(watch.status(), "watching")
	end)

	helpers.it("ends for the session when Hyprland closes the socket or a read fails (hyprland-reload-reselect)", function()
		for _, case in ipairs({ { nil, nil }, { "ECONNRESET", "x" } }) do
			local watch, pipes = owner()
			local reloads = 0
			watch.start(function() reloads = reloads + 1 end)
			pipes[1].on_connect(nil)
			pipes[1].on_read(case[1], case[2])
			helpers.assert_eq(watch.status(), "stopped")
			helpers.assert_true(pipes[1].closed, "the pipe is closed")
			pipes[1].on_read(nil, "configreloaded>>\n")
			helpers.assert_eq(reloads, 0, "no reload after the end")
		end
	end)

	helpers.it("refuses without a socket identity or a connection, and once started (hyprland-reload-reselect)", function()
		local no_signature = owner({ XDG_RUNTIME_DIR = "/run/user/1000" })
		helpers.assert_eq(no_signature.start(function() end), false)
		helpers.assert_eq(no_signature.status(), "stopped")
		local traversal = owner({ XDG_RUNTIME_DIR = "/run/user/1000", HYPRLAND_INSTANCE_SIGNATURE = "../x" })
		helpers.assert_eq(traversal.start(function() end), false)
		local refused, pipes = owner()
		helpers.assert_true(refused.start(function() end))
		pipes[1].on_connect("ENOENT")
		helpers.assert_eq(refused.status(), "stopped")
		helpers.assert_true(pipes[1].closed)
		local raising, raised_pipes = owner(nil, { connect_raises = true })
		helpers.assert_eq(raising.start(function() end), false)
		helpers.assert_true(raised_pipes[1].closed)
		local ok = pcall(refused.start, function() end)
		helpers.assert_eq(ok, false, "a second start is a programming error")
	end)

	helpers.it("shuts down cleanly and ignores a late connection (hyprland-reload-reselect)", function()
		local watch, pipes = owner()
		local reloads = 0
		watch.start(function() reloads = reloads + 1 end)
		watch.shutdown()
		helpers.assert_eq(watch.status(), "stopped")
		helpers.assert_true(pipes[1].closed)
		pipes[1].on_connect(nil)
		helpers.assert_eq(pipes[1].reading, false, "a connection after shutdown never reads")
		helpers.assert_eq(reloads, 0)
	end)

	helpers.it("keeps watching when its owner's handler raises (hyprland-reload-reselect)", function()
		local watch, pipes = owner()
		watch.start(function() error("busy") end)
		pipes[1].on_connect(nil)
		pipes[1].on_read(nil, "configreloaded>>\n")
		helpers.assert_eq(watch.status(), "watching")
	end)
end)
