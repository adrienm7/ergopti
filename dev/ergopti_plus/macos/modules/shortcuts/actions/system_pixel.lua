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
local notifications = require("lib.notifications")
local Logger        = require("lib.logger")
local i18n          = require("lib.i18n")

local LOG = "shortcuts.actions.system"

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
--- @param x number X screen coordinate.
--- @param y number Y screen coordinate.
--- @return string|nil Hex color string like "#a1b2c3", or nil on failure.
local function pixel_hex_at(x, y)
	Logger.trace(LOG, "Pixel color read started…")
	local tmpfile = "/tmp/_hs_pixel_cap.png"
	local safe_x  = math.floor(tonumber(x) or 0) - 1
	local safe_y  = math.floor(tonumber(y) or 0) - 1

	local cap_cmd = string.format("screencapture -x -R \"%d,%d,3,3\" \"%s\"", safe_x, safe_y, tmpfile)
	local ok_cap  = pcall(hs.execute, cap_cmd)
	if not ok_cap then
		Logger.error(LOG, "screencapture failed — pixel read aborted.")
		return nil
	end

	local py = string.format([[python3 -c "
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
"
]], tmpfile)

	local ok_py, out = pcall(hs.execute, py)
	if ok_py and out then
		local hex = out:match("(#%x%x%x%x%x%x)")
		if hex then
			Logger.done(LOG, "Pixel color read — %s.", hex)
			return hex
		end
	end

	Logger.warn(LOG, "Python pixel extractor returned no valid hex code.")
	return nil
end

--- Reads the color of the pixel currently under the mouse cursor and copies it to the clipboard.
function M.copy_pixel_color()
	local ok, pos = pcall(hs.mouse.absolutePosition)
	if not ok or not pos then
		Logger.error(LOG, "copy_pixel_color: failed to read mouse position.")
		return
	end

	local hex = pixel_hex_at(math.floor(pos.x), math.floor(pos.y))
	if not hex then
		notifications.notify(i18n.get("shortcuts.pixel_read_error"), nil, "error")
		return
	end

	pcall(pasteboard.setContents, hex)
	notifications.notify(string.format(i18n.get("shortcuts.color_copied"), hex), nil, "success")
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
