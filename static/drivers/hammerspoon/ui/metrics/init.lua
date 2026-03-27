-- ui/metrics/init.lua

-- ===========================================================================
-- Keylogger Metrics UI Module.
--
-- Spawns a Webview to process and display detailed typing statistics
-- (Characters, Bigrams, Trigrams, Words, WPM evolution) using Chart.js.
-- ===========================================================================

local M = {}

local hs = hs
M._wv    = nil





-- =============================
-- =============================
-- ======= 1/ Public API =======
-- =============================
-- =============================

--- Opens the metrics dashboard and injects the log data.
--- @param log_dir string The directory containing the daily .log files
function M.show(log_dir)
	if not log_dir then return end

	local base_dir = hs.configdir .. "/ui/metrics/"
	
	-- Create Webview if it doesn't exist, maximizing the screen bounds with a slight padding
	if not M._wv then
		local screen_frame = hs.screen.mainScreen():frame()
		M._wv = hs.webview.new({
			x = screen_frame.x + 50,
			y = screen_frame.y + 50,
			w = screen_frame.w - 100,
			h = screen_frame.h - 100
		})
		M._wv:windowTitle("Métriques de frappe")
		M._wv:level(hs.drawing.windowLevels.normal)
		M._wv:windowStyle(1|2|4|8)
		M._wv:allowTextEntry(true) -- Required to allow typing inside HTML input elements
		
		M._wv:windowCallback(function(action)
			if action == "closing" then M._wv = nil end
		end)
	end

	-- Read local UI files
	local function read_file(path)
		local f = io.open(path, "r")
		if not f then return "" end
		local content = f:read("*a")
		f:close()
		return content
	end

	local html = read_file(base_dir .. "index.html")
	local css  = read_file(base_dir .. "style.css")
	local js   = read_file(base_dir .. "script.js")

	-- Inject CSS and JS safely without triggering Lua's '%' pattern matching
	local function inject_safely(source, tag, content)
		local start_idx, end_idx = source:find(tag, 1, true)
		if start_idx then
			return source:sub(1, start_idx - 1) .. content .. source:sub(end_idx + 1)
		end
		return source
	end

	html = inject_safely(html, "</head>", "<style>\n" .. css .. "\n</style>\n</head>")
	html = inject_safely(html, "</head>", "<script>\n" .. js .. "\n</script>\n</head>")

	M._wv:html(html)
	M._wv:show()
	M._wv:bringToFront()
	hs.focus()

	-- Gather and format log data
	local all_lines = {}
	local attrs = hs.fs.attributes(log_dir)
	if attrs then
		for f in hs.fs.dir(log_dir) do
			if f:match("%.log$") then
				local file = io.open(log_dir .. "/" .. f, "r")
				if file then
					for line in file:lines() do
						line = line:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("'", "\\'")
						table.insert(all_lines, '"' .. line .. '"')
					end
					file:close()
				end
			end
		end
	end

	-- Inject data asynchronously to avoid blocking Hammerspoon.
	local js_inject = "window.log_lines = [" .. table.concat(all_lines, ",") .. "]; window.process_logs();"
	hs.timer.doAfter(0.5, function()
		if M._wv then M._wv:evaluateJavaScript(js_inject) end
	end)
end

return M
