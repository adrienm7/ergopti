--- ui/ui_builder.lua

--- ==============================================================================
--- MODULE: UI Builder Factory
--- DESCRIPTION:
--- Centralized factory and manager for all Hammerspoon webview user interfaces.
--- It provides a unified way to construct windows, inject standalone HTML/JS/CSS
--- assets, and manage window lifecycles natively.
---
--- FEATURES & RATIONALE:
--- 1. Singleton Preservation: By combining this module with early returns in UI modules, pressing a shortcut multiple times will not destroy an already open window. It simply brings the existing window to the front, preserving any text the user has already started typing, or creates a new window only if none exists.
--- 2. Active Space Teleportation: If a user opens the UI in Space 1, moves to Space 2, and triggers the shortcut again, the script momentarily hides and shows the window. This natively teleports the existing window to the active space without erasing its DOM state.
--- 3. Smart Focus Management: Brings the window to the front and gives it system focus, but deliberately uses the "normal" window level. This ensures it appears on top when triggered, but clicking on another application gracefully pushes the UI to the background.
--- 4. DRY Architecture: Removes repetitive window creation and configuration boilerplate across all UI modules.
--- ==============================================================================

local M = {}
local hs = hs
local Logger = require("lib.logger")
local LOG = "ui_builder"





-- ===================================
-- ===================================
-- ======= 1/ Asset Operations =======
-- ===================================
-- ===================================

--- Reads a file and escapes special characters for Lua string substitution.
--- @param path string Full path to the file.
--- @return string The escaped file content.
local function read_and_escape(path)
	local ok, fh = pcall(io.open, path, "r")
	if not ok or not fh then return "" end
	local content = fh:read("*a")
	fh:close()
	
	-- Double the percent signs to prevent Lua pattern matching errors during injection
	return content:gsub("%%", "%%%%")
end

--- Builds a self-contained HTML string from separate assets.
--- @param assets_dir string The directory containing the assets.
--- @param html_name string Optional name of the HTML file.
--- @param css_name string Optional name of the CSS file.
--- @param js_name string Optional name of the JS file.
--- @return string The complete HTML with injected styles and scripts.
function M.build_injected_html(assets_dir, html_name, css_name, js_name)
	Logger.debug(LOG, "Building injected HTML assets…")
	html_name = html_name or "index.html"
	css_name  = css_name  or "style.css"
	js_name   = js_name   or "script.js"

	local html_path = assets_dir .. html_name
	local ok, fh = pcall(io.open, html_path, "r")
	if not ok or not fh then 
		Logger.error(LOG, string.format("Failed to find HTML template: %s.", html_name))
		return "<html><body><h1>Erreur de construction : " .. html_name .. " introuvable</h1></body></html>" 
	end
	local html = fh:read("*a")
	fh:close()

	local css = read_and_escape(assets_dir .. css_name)
	local js  = read_and_escape(assets_dir .. js_name)

	if css ~= "" then
		html = html:gsub("(</[Hh][Ee][Aa][Dd]>)", "<style>" .. css .. "</style>%1")
	end

	if js ~= "" then
		html = html:gsub("(</[Bb][Oo][Dd][Yy]>)", "<script>" .. js .. "</script>%1")
	end

	Logger.info(LOG, "Injected HTML assets built successfully.")
	return html
end





-- ====================================
-- ====================================
-- ======= 2/ Window Management =======
-- ====================================
-- ====================================

--- Calculates a perfectly centered frame for a given width and height on the main screen.
--- @param w number The desired width of the window.
--- @param h number The desired height of the window.
--- @return table The dictionary containing x, y, w, h coordinates.
function M.get_centered_frame(w, h)
	local screen = hs.screen.mainScreen()
	local sf = screen and type(screen.frame) == "function" and screen:frame() or {x = 0, y = 0, w = 1920, h = 1080}
	return {
		x = math.floor(sf.x + (sf.w - w) / 2),
		y = math.floor(sf.y + (sf.h - h) / 2),
		w = w,
		h = h
	}
end

--- Forces a webview window to the front, teleports it to the current space natively, and gives it focus cleanly.
--- @param wv userdata The hs.webview object.
function M.force_focus(wv)
	if not wv then return end
	
	Logger.debug(LOG, "Forcing window focus and teleporting to active space…")
	-- Hiding and showing the window natively teleports it to the active macOS space
	-- without changing its behavior property, which would destroy the webview state
	pcall(function() wv:hide() end)
	pcall(function() wv:show() end)
	
	hs.timer.doAfter(0.05, function()
		if type(wv.hswindow) == "function" then
			local ok, win = pcall(function() return wv:hswindow() end)
			if ok and win then
				pcall(function() win:moveToScreen(hs.screen.mainScreen()) end)
				if type(win.raise) == "function" then
					pcall(function() win:raise() end)
					pcall(function() win:focus() end)
				end
			else
				pcall(function() wv:bringToFront() end)
			end
		else
			pcall(function() wv:bringToFront() end)
		end
		
		pcall(hs.focus)
		Logger.info(LOG, "Window focus applied.")
	end)
end

--- Centralized factory to create a webview window with consistent properties.
--- @param opts table The configuration options for the webview.
--- @return userdata|nil The configured webview instance.
function M.show_webview(opts)
	if type(opts) ~= "table" then return nil end
	Logger.debug(LOG, "Creating new webview window…")

	local wv
	if opts.usercontent then
		wv = hs.webview.new(opts.frame, { developerExtrasEnabled = false }, opts.usercontent)
	else
		wv = hs.webview.new(opts.frame, { developerExtrasEnabled = false })
	end
	
	if not wv then 
		Logger.error(LOG, "Failed to instantiate webview object.")
		return nil 
	end

	pcall(function() wv:windowTitle(opts.title or "UI") end)
	
	if opts.style_masks then 
		pcall(function() wv:windowStyle(opts.style_masks) end) 
	else
		local masks = hs.webview.windowMasks
		pcall(function() wv:windowStyle((masks["titled"] or 1) + (masks["closable"] or 2) + (masks["utility"] or 16)) end)
	end
	
	pcall(function() wv:level(opts.level or hs.drawing.windowLevels.normal) end)
	pcall(function() wv:allowTextEntry(opts.allow_text_entry ~= false) end)
	
	if opts.allow_gestures ~= nil then pcall(function() wv:allowGestures(opts.allow_gestures) end) end
	if opts.allow_new_windows ~= nil then pcall(function() wv:allowNewWindows(opts.allow_new_windows) end) end

	if type(opts.on_close) == "function" then
		pcall(function()
			wv:windowCallback(function(action)
				if action == "closing" or action == "closed" then opts.on_close() end
			end)
		end)
	end

	if type(opts.on_navigation) == "function" then
		pcall(function() wv:navigationCallback(opts.on_navigation) end)
	end

	if type(opts.html) == "string" then
		pcall(function() wv:html(opts.html) end)
	elseif type(opts.assets_dir) == "string" then
		local final_html = M.build_injected_html(opts.assets_dir)
		pcall(function() wv:html(final_html) end)
	end

	M.force_focus(wv)
	Logger.info(LOG, "Webview window created successfully.")
	return wv
end

return M
