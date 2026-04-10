--- ui/personal_info_editor/init.lua

--- ==============================================================================
--- MODULE: Personal Information Editor UI
--- DESCRIPTION:
--- Spins up a temporary local HTTP server to display a clean web form
--- in the user’s default browser. This approach bypasses Hammerspoon’s 
--- webview limitations regarding certain keyboard event interceptions.
--- 
--- Acts as a lightweight router to serve the HTML, CSS, and JS assets 
--- from its dedicated subfolder.
--- ==============================================================================

local M = {}

local hs     = hs
local timer  = hs.timer
local Logger = require("lib.logger")

local LOG   = "personal_info_editor"





-- ====================================
-- ====================================
-- ======= 1/ Constants & State =======
-- ====================================
-- ====================================

local SERVER_PORT = 18743
local _srv        = nil

-- Field definitions for the form. Keys match the preferences table.
local FIELDS = {
	{ key = "FirstName",            label = "Prénom" },
	{ key = "LastName",             label = "Nom" },
	{ key = "DateOfBirth",          label = "Date de naissance" },
	{ key = "EmailAddress",         label = "E-mail" },
	{ key = "WorkEmailAddress",     label = "E-mail professionnel" },
	{ key = "PhoneNumber",          label = "Téléphone (chiffres seuls)" },
	{ key = "PhoneNumberFormatted", label = "Téléphone (formaté)" },
	{ key = "StreetAddress",        label = "Adresse" },
	{ key = "PostalCode",           label = "Code postal" },
	{ key = "City",                 label = "Ville" },
	{ key = "Country",              label = "Pays" },
	{ key = "IBAN",                 label = "IBAN" },
	{ key = "BIC",                  label = "BIC" },
	{ key = "CreditCard",           label = "Carte de crédit" },
	{ key = "SocialSecurityNumber", label = "Numéro de Sécurité Sociale" },
}

-- Response HTML displayed after a successful save
local HTML_OK = [[<!DOCTYPE html><html><head><meta charset="utf-8">
<style>body{font-family:-apple-system,sans-serif;padding:40px;text-align:center}
h2{color:#007AFF}</style></head>
<body><h2>✓ Enregistré</h2><p>Vous pouvez fermer cet onglet.</p>
<script>window.close()</script></body></html>]]

-- Determine absolute path to the assets directory
local _src  = debug.getinfo(1, "S").source:sub(2)
local ASSETS_DIR = _src:match("^(.*[/\\])") or "./"





-- ===================================
-- ===================================
-- ======= 2/ String Utilities =======
-- ===================================
-- ===================================

--- URL-decodes a percent-encoded string.
--- @param s string The encoded string.
--- @return string The decoded string.
local function urldecode(s)
	if type(s) ~= "string" then return s end
	return (s:gsub("+", " "):gsub("%%(%x%x)", function(h)
		return string.char(tonumber(h, 16))
	end))
end





-- ===================================
-- ===================================
-- ======= 3/ Asset Management =======
-- ===================================
-- ===================================

--- Reads the content of a file from disk safely.
--- @param filename string The name of the file inside the ASSETS_DIR.
--- @return string The file content, or empty string on failure.
local function read_asset(filename)
	if type(filename) ~= "string" then return "" end
	
	local path = ASSETS_DIR .. filename
	local ok, fh = pcall(io.open, path, "r")
	if not ok or not fh then
		Logger.error(LOG, string.format("Error loading asset from: %s.", tostring(path)))
		return ""
	end
	
	local content = fh:read("*a")
	pcall(function() fh:close() end)
	
	return content or ""
end

--- Builds the HTML form using the current information, injecting rows dynamically.
--- @param current_info table The current personal information dictionary.
--- @return string The complete HTML document ready to be served.
local function build_html(current_info)
	current_info = type(current_info) == "table" and current_info or {}
	
	-- Generate the input rows dynamically based on the FIELDS table
	local rows = {}
	for _, f in ipairs(FIELDS) do
		local val = tostring(current_info[f.key] or "")
			:gsub("&", "&amp;")
			:gsub("<", "&lt;")
			:gsub("\"", "&quot;")
			
		table.insert(rows, string.format(
			"<div class=\"row\"><label>%s</label><input name=\"%s\" value=\"%s\" autocomplete=\"off\"></div>",
			f.label, f.key, val
		))
	end
	local rows_html = table.concat(rows, "\n")

	-- Load the external HTML template
	local html_template = read_asset("index.html")

	-- Fallback if index.html is missing
	if html_template == "" then
		return "<html><body style=\"font-family:sans-serif;padding:20px;\"><h1>Error 500</h1><p>UI Template missing.</p></body></html>"
	end

	-- Inject dynamic rows using string replacement
	local final_html = html_template:gsub("{{ROWS}}", function() return rows_html end)

	return final_html
end





-- =============================
-- =============================
-- ======= 4/ Public API =======
-- =============================
-- =============================

--- Opens the editor in the system’s default web browser.
--- @param current_info table Current data used to populate form fields.
--- @param save_callback function Invoked when the user submits the form.
function M.open(current_info, save_callback)
	-- Prevent launching multiple server instances
	if _srv then
		Logger.warn(LOG, string.format("Server already running on port %d.", SERVER_PORT))
		pcall(hs.execute, string.format("open \"http://127.0.0.1:%d/\"", SERVER_PORT))
		return
	end

	local html_form = build_html(current_info)

	-- Primary HTTP request handler and router
	local function handler(method, path, headers, body)
		
		-- 1. Route for the main HTML form
		if path == "/" then
			return html_form, 200, { ["Content-Type"] = "text/html; charset=utf-8" }
			
		-- 2. Route for the CSS stylesheet
		elseif path == "/style.css" or path == "style.css" then
			local css = read_asset("style.css")
			return css, 200, { ["Content-Type"] = "text/css; charset=utf-8" }
			
		-- 3. Route for the Javascript logic
		elseif path == "/script.js" or path == "script.js" then
			local js = read_asset("script.js")
			return js, 200, { ["Content-Type"] = "application/javascript; charset=utf-8" }
			
		-- 4. Form submission handler
		elseif path == "/save" and method == "POST" then
			local new_info = {}
			for k, v in (body or ""):gmatch("([^&=]+)=([^&]*)") do
				new_info[urldecode(k)] = urldecode(v)
			end
			
			-- Persist data via the callback
			if type(save_callback) == "function" then
				pcall(save_callback, new_info)
			end
			
			-- Gracefully shut down the server after the response is sent
			timer.doAfter(0.5, function() 
				if _srv and type(_srv.stop) == "function" then 
					pcall(function() _srv:stop() end)
					_srv = nil 
				end 
			end)
			return HTML_OK, 200, { ["Content-Type"] = "text/html; charset=utf-8" }
			
		-- 5. Cancellation handler
		elseif path == "/cancel" then
			timer.doAfter(0.5, function() 
				if _srv and type(_srv.stop) == "function" then 
					pcall(function() _srv:stop() end)
					_srv = nil 
				end 
			end)
			return "", 200, {}
		end
		
		return "Not found", 404, {}
	end

	-- Initialize and start the HTTP server
	local ok, h_srv = pcall(hs.httpserver.new, false, false)
	if ok and h_srv then
		_srv = h_srv
		pcall(function() 
			_srv:setPort(SERVER_PORT)
			_srv:setCallback(handler)
			_srv:start()
		end)
		
		-- Open the browser to the local server address
		pcall(hs.execute, string.format("open \"http://127.0.0.1:%d/\"", SERVER_PORT))
		Logger.info(LOG, string.format("Editor server active on port %d.", SERVER_PORT))
	else
		Logger.error(LOG, "Failed to initialize local HTTP server.")
	end
end

return M
