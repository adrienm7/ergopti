--- adapters/screen_capture.lua

--- ==============================================================================
--- MODULE: Screen Capture Adapter
--- DESCRIPTION:
--- Reads and requests the macOS Screen Recording permission, and owns the
--- pasteboard image boundary used to prove that a screenshot reached the
--- clipboard.
---
--- FEATURES & RATIONALE:
--- 1. Distinct identity: the packaged runtime is its own application
---    (com.ergoptiplus.app.hammerspoon). A Screen Recording grant held by a
---    stock Hammerspoon does not carry over, and /usr/sbin/screencapture is
---    attributed to this runtime, so without the grant a capture fails after
---    the selection or silently omits every window.
--- 2. Exact results: a failed native query is reported as nil plus its detail,
---    never as a refusal or a grant, so callers can fail visibly.
--- 3. Verified clipboard: a written image counts only when the pasteboard
---    change count advanced and an image can be read back.
--- 4. No captured `hs` upvalue: the global is read at call time, so a cached
---    adapter never keeps a stale native table.
--- ==============================================================================

local M = {}

M.SETTINGS_URL =
	"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"





-- ===================================
-- ===================================
-- ======= 1/ Native Boundary ========
-- ===================================
-- ===================================

--- Resolves one native function at call time.
--- @param namespace string|nil Field of the native root, or nil for the root.
--- @param name string Function name.
--- @return function|nil fn Native function.
--- @return string|nil detail Why it is unavailable.
local function native(namespace, name)
	local root = rawget(_G, "hs")
	if type(root) ~= "table" then return nil, "hs is unavailable" end
	local owner = root
	local label = name
	if namespace then
		owner = root[namespace]
		label = namespace .. "." .. name
		if type(owner) ~= "table" then return nil, "hs." .. namespace .. " is unavailable" end
	end
	if type(owner[name]) ~= "function" then return nil, "hs." .. label .. " is unavailable" end
	return owner[name]
end





-- =====================================
-- =====================================
-- ======= 2/ Screen Recording =========
-- =====================================
-- =====================================

--- Reports whether this process may record the screen, without prompting.
--- @return boolean|nil granted Nil when the native query itself failed.
--- @return string|nil detail Exact failure when granted is nil.
function M.permission_state()
	local fn, missing = native(nil, "screenRecordingState")
	if not fn then return nil, missing end
	local ok, state = pcall(fn, false)
	if not ok then return nil, tostring(state) end
	return state == true
end

--- Asks macOS to register this process and show its Screen Recording prompt.
--- @return boolean requested True when the native request returned.
--- @return string|nil detail Exact failure when the request raised.
function M.request_permission()
	local fn, missing = native(nil, "screenRecordingState")
	if not fn then return false, missing end
	local ok, err = pcall(fn, true)
	if not ok then return false, tostring(err) end
	return true
end

--- Opens System Settings on the Screen Recording privacy pane.
--- @return boolean opened True only when macOS accepted the URL.
--- @return string|nil detail Exact failure otherwise.
function M.open_permission_settings()
	local fn, missing = native("urlevent", "openURL")
	if not fn then return false, missing end
	local ok, accepted = pcall(fn, M.SETTINGS_URL)
	if not ok then return false, tostring(accepted) end
	if accepted ~= true then return false, "openURL returned " .. tostring(accepted) end
	return true
end





-- =====================================
-- =====================================
-- ======= 3/ Clipboard Images =========
-- =====================================
-- =====================================

--- Reads the pasteboard change count, which advances on every write.
--- @return number|nil count Nil when the native query failed.
--- @return string|nil detail Exact failure.
function M.clipboard_change_count()
	local fn, missing = native("pasteboard", "changeCount")
	if not fn then return nil, missing end
	local ok, count = pcall(fn)
	if not ok then return nil, tostring(count) end
	if type(count) ~= "number" then return nil, "changeCount returned " .. tostring(count) end
	return count
end

--- Reports whether the pasteboard currently holds a readable image.
--- @return boolean|nil present Nil when the native read failed.
--- @return string|nil detail Exact failure.
function M.clipboard_has_image()
	local fn, missing = native("pasteboard", "readImage")
	if not fn then return nil, missing end
	local ok, image = pcall(fn)
	if not ok then return nil, tostring(image) end
	return image ~= nil and image ~= false
end

--- Places the image stored at path on the pasteboard and verifies the write.
--- @param path string Absolute path of a PNG produced by screencapture.
--- @return boolean copied True only when the image is readable back.
--- @return string|nil detail Exact failure otherwise.
function M.copy_image_file_to_clipboard(path)
	if type(path) ~= "string" or path == "" then return false, "path must be a non-empty string" end
	local load, load_missing = native("image", "imageFromPath")
	if not load then return false, load_missing end
	local write, write_missing = native("pasteboard", "writeObjects")
	if not write then return false, write_missing end

	local load_ok, image = pcall(load, path)
	if not load_ok then return false, "image load raised: " .. tostring(image) end
	if image == nil or image == false then return false, "the capture file holds no readable image" end

	local before, count_err = M.clipboard_change_count()
	if before == nil then return false, count_err end
	local write_ok, written = pcall(write, image)
	if not write_ok then return false, "writeObjects raised: " .. tostring(written) end
	if written ~= true then return false, "writeObjects returned " .. tostring(written) end

	local after, after_err = M.clipboard_change_count()
	if after == nil then return false, after_err end
	if after == before then return false, "the pasteboard change count did not advance" end
	local present, read_err = M.clipboard_has_image()
	if present ~= true then
		return false, present == nil and read_err or "the pasteboard holds no image after the write"
	end
	return true
end

return M
