--- modules/shortcuts/actions/system_pixel.lua

--- ==============================================================================
--- MODULE: Shortcuts — System Actions — Pixel Color & Screenshots
--- DESCRIPTION:
--- Pixel color copy and screenshot helpers extracted from system.lua.
--- Merged back into the system module table at load time.
---
--- FEATURES & RATIONALE:
--- 1. Pixel Sampling: Uses an inline Python PNG decoder to read per-pixel color
---    via screencapture, since Hammerspoon exposes no native pixel color API.
--- 2. Screenshot Wrapper: Spawns the native screencapture tool asynchronously
---    so the main thread is never blocked during a user-driven screenshot.
--- ==============================================================================

local M = {}

local hs            = hs
local pasteboard    = hs.pasteboard
local notifications = require("infra.notifications")
local Logger        = require("infra.logger")
local i18n          = require("infra.i18n")
local ShellRunner   = require("adapters.shell_runner")

local LOG = "shortcuts.actions.system"

-- Absolute paths: the interactive layer must not inherit its binaries from PATH,
-- which differs between a login shell and the Hammerspoon process.
local SCREENCAPTURE_BIN = "/usr/sbin/screencapture"
local PYTHON_BIN        = "/usr/bin/python3"

-- GC root for live hs.task objects. A task not referenced from a GC root can be
-- collected mid-run, which kills the subprocess so its completion callback never
-- fires. Canonical spelling recognised by tests/unit/meta/test_gc_retention.lua;
-- entries are released when the callback runs or the launch is refused.
local _active_tasks = {}






-- =============================================
-- =============================================
-- ======= 1/ Pixel Color Implementation =======
-- =============================================
-- =============================================

--- Reads the hex color of the pixel at (x, y) via a minimal inline Python PNG decoder.
--- Captures a 3×3-pixel region and samples the center pixel.
--- Python is used because Hammerspoon has no native per-pixel color API.
---
--- The result arrives through a callback instead of a return value. This needs a
--- screencapture round trip AND a Python interpreter start — together well over a
--- tenth of a second — and it is triggered by a shortcut, so doing it
--- synchronously held the single Hammerspoon runloop for that whole window: no
--- keystroke was delivered, and a keyboard tap that misses its deadline is
--- disabled outright by macOS. The neighbouring interactive_screenshot in this
--- same file was already async for exactly this reason.
--- @param x number X screen coordinate.
--- @param y number Y screen coordinate.
--- @param on_hex function Called as on_hex(hex_or_nil) with "#a1b2c3" or nil.
local function pixel_hex_at(x, y, on_hex)
	Logger.trace(LOG, "Pixel color read started…")
	local tmpfile = "/tmp/_hs_pixel_cap.png"
	local safe_x  = math.floor(tonumber(x) or 0) - 1
	local safe_y  = math.floor(tonumber(y) or 0) - 1

	-- argv, not a shell string: the region and the temp path are passed as
	-- separate arguments, so neither can be re-interpreted by /bin/sh.
	local region = string.format("%d,%d,3,3", safe_x, safe_y)

	-- Bare Python source: with argv there is no shell, so the `python3 -c "…"`
	-- wrapper and its quoting are gone and the interpreter receives the program
	-- exactly as written here.
	local py_src = string.format([[
import struct,zlib
try:
  data=open('%s','rb').read()
  w,h=struct.unpack('>II',data[16:24])
  ct=data[25];bpp=4 if ct==6 else 3
  i,chunks=8,b''
  while i<len(data)-12:
    l=struct.unpack('>I',data[i:i+4])[0];t=data[i+4:i+8]
    if t==b'IDAT':chunks+=data[i+8:i+8+l]
    elif t==b'IEND':break
    i+=l+12
  raw=zlib.decompress(chunks)
  cx=w//2;cy=h//2;off=cy*(1+w*bpp)+1+cx*bpp
  r,g,b=raw[off],raw[off+1],raw[off+2]
  print('#%%02x%%02x%%02x' %% (r,g,b))
except Exception:
  pass
]], tmpfile)

	ShellRunner.spawn(SCREENCAPTURE_BIN, { "-x", "-R", region, tmpfile }, function(cap_code)
		if cap_code ~= 0 then
			Logger.error(LOG, "screencapture exited with code %s — pixel read aborted.",
				tostring(cap_code))
			on_hex(nil)
			return
		end
		ShellRunner.spawn(PYTHON_BIN, { "-c", py_src }, function(py_code, stdout)
			local hex = (py_code == 0) and type(stdout) == "string"
				and stdout:match("(#%x%x%x%x%x%x)") or nil
			if hex then
				Logger.done(LOG, "Pixel color read — %s.", hex)
				on_hex(hex)
				return
			end
			Logger.warn(LOG, "Python pixel extractor returned no valid hex code (exit %s).",
				tostring(py_code))
			on_hex(nil)
		end).start()
	end).start()
end

--- Reads the color of the pixel currently under the mouse cursor and copies it to the clipboard.
function M.copy_pixel_color()
	local ok, pos = pcall(hs.mouse.absolutePosition)
	if not ok or not pos then
		Logger.error(LOG, "copy_pixel_color: failed to read mouse position.")
		return
	end

	pixel_hex_at(math.floor(pos.x), math.floor(pos.y), function(hex)
		if not hex then
			notifications.notify(i18n.get("shortcuts.pixel_read_error"), nil, "error")
			return
		end

		pcall(pasteboard.setContents, hex)
		notifications.notify(string.format(i18n.get("shortcuts.color_copied"), hex), nil, "success")
	end)
end

--- Launches the native macOS interactive screenshot tool and copies the result to the clipboard.
function M.interactive_screenshot()
	Logger.trace(LOG, "Interactive screenshot started…")
	local task
	local ok
	ok, task = pcall(hs.task.new,
		"/usr/sbin/screencapture",
		function(exit_code, _, _)
			if task then _active_tasks[task] = nil end
			if exit_code == 0 then
				notifications.notify(i18n.get("shortcuts.screenshot_copied"), nil, "success")
				Logger.done(LOG, "Interactive screenshot completed.")
			else
				Logger.warn(LOG, "Interactive screenshot failed or was cancelled.")
			end
		end,
		{"-i", "-c"}
	)
	if ok and task then
		-- Interactive screencapture waits for the user to drag a selection, so this
		-- is the longest-lived subprocess in the driver — precisely the one the GC
		-- is most likely to collect before its callback fires.
		_active_tasks[task] = true
		if not task:start() then
			_active_tasks[task] = nil
			Logger.error(LOG, "Screenshot task failed to start.")
		end
	else
		Logger.error(LOG, "Failed to create screenshot task.")
	end
end

return M
