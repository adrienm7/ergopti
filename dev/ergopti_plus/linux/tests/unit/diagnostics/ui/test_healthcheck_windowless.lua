--- tests/unit/diagnostics/ui/test_healthcheck_windowless.lua

--- ==============================================================================
--- MODULE: Diagnostics Without A Native Window (Linux)
--- DESCRIPTION:
--- Field report (Arch, KDE Plasma 6 Wayland, AppImage, lgi missing): the tray's
--- « Diagnostic » only raised the error notice « show(): native window
--- acquisition refused for 'healthcheck'. ». The diagnostics must never depend
--- on the component they diagnose: with no native window the report is written
--- as a self-contained HTML file in the logs' diagnostics folder, opened in the
--- browser and named in a translated notice (healthcheck-windowless). Every other
--- window without a fallback is explained by a notice naming the missing
--- component, never by the raw refusal (window-missing-component).
--- Driven through the real webview manager, bridge, report writer and desktop
--- opener; only the native window creator, the component probe and the
--- opener's process start are replaced.
--- ==============================================================================

local helpers = require("tests.helpers")

local LGI = require("core.ui.engine.gui_stack").LGI_COMPONENT
local RAW_REFUSAL = "native window acquisition refused"

--- Runs body with no native window and records what the user and the log get.
--- @param missing string|nil The component the probe reports missing.
--- @param body function Receives the manager and the record { opened, errors }.
local function without_window(missing, body)
	local manager = require("core.ui.ui.webview_manager")
	local Opener = require("apps.adapters.desktop_opener")
	local Logger = require("core.logger.engine.shim")
	local record = { opened = {}, errors = {} }
	local real_create, real_error = manager._create_gtk_window, Logger.error
	manager._create_gtk_window = function() return false, "GTK/WebKit unavailable" end
	manager._set_missing_component_probe_for_test(function() return missing end)
	Logger.error = function(_, fmt, ...)
		local ok, text = pcall(string.format, fmt, ...)
		record.errors[#record.errors + 1] = ok and text or tostring(fmt)
	end
	Opener._set_deps_for_test({
		exepath = function() return "/usr/bin/luajit" end,
		worker = function() return "/opt/ergopti/desktop_opener_worker.lua" end,
		update_time = function() return true end,
		start = function(_, args, _, done)
			record.opened[#record.opened + 1] = args[2]
			done({ ok = true, exit_code = 0 })
			return { cancel = function() return true end, is_settled = function() return true end,
				on_settled = function() return true end }
		end,
	})
	local ok, err = pcall(body, manager, record)
	Logger.error = real_error
	manager._create_gtk_window = real_create
	manager._set_missing_component_probe_for_test(nil)
	Opener._set_deps_for_test(nil)
	for _, path in ipairs(record.opened) do os.remove(path) end
	if not ok then error(err, 0) end
end

--- Reads a whole file, nil when absent.
--- @param path string
--- @return string|nil
local function read(path)
	local fh = io.open(path, "rb")
	if not fh then return nil end
	local text = fh:read("*a")
	fh:close()
	return text
end

--- Fails when the raw refusal reached the log's errors or a notice.
--- @param record table
local function assert_no_raw_refusal(record)
	for _, line in ipairs(record.errors) do
		helpers.assert_true(not line:find(RAW_REFUSAL, 1, true), "the raw refusal was logged as an error: " .. line)
	end
	for _, notice in ipairs(helpers.recorded_notices()) do
		helpers.assert_true(not tostring(notice.message):find(RAW_REFUSAL, 1, true),
			"the raw refusal reached a notice: " .. tostring(notice.message))
	end
end

--- The one recorded notice whose message contains text.
--- @param text string
--- @return table|nil
local function notice_containing(text)
	for _, notice in ipairs(helpers.recorded_notices()) do
		if tostring(notice.message):find(text, 1, true) then return notice end
	end
	return nil
end

helpers.describe("diagnostics without a native window (Linux)", function()
	helpers.it("writes the report as HTML, opens it and names it when lgi is missing (healthcheck-windowless)", function()
		without_window(LGI, function(manager, record)
			helpers.assert_eq(require("diagnostics.ui.healthcheck.bridge").open(), false, "no window was opened")
			helpers.assert_eq(manager.current_epoch("healthcheck"), nil, "no page is left in the pool")
			helpers.assert_eq(#record.opened, 1, "the report file is handed to the desktop opener once")
			local path = record.opened[1]
			local folder = require("core.logger.engine.sink").log_dir() .. "/diagnostics/"
			helpers.assert_eq(path:sub(1, #folder), folder, "the report is written in the logs' diagnostics folder")
			helpers.assert_eq(path:sub(-5), ".html", "the browser opens an HTML file")
			local html = read(path)
			helpers.assert_true(html ~= nil, "the report file exists: " .. path)
			helpers.assert_eq(html:sub(1, 15), "<!doctype html>", "a self-contained page")
			helpers.assert_true(not html:find("<script", 1, true), "the page runs no script")
			helpers.assert_true(html:find("<pre>", 1, true) ~= nil, "the page carries the report")
			local notice = notice_containing(path)
			helpers.assert_true(notice ~= nil, "a notice names the file")
			helpers.assert_contains(notice.message, LGI, "the notice names the missing component")
			assert_no_raw_refusal(record)
		end)
	end)

	helpers.it("still delivers the report when the window is refused with the toolkit present (healthcheck-windowless)", function()
		without_window(nil, function(_, record)
			require("diagnostics.ui.healthcheck.bridge").open()
			helpers.assert_eq(#record.opened, 1, "the report file is handed to the desktop opener")
			helpers.assert_true(read(record.opened[1]) ~= nil, "the report file exists")
			helpers.assert_true(notice_containing(record.opened[1]) ~= nil, "a notice names the file")
			assert_no_raw_refusal(record)
		end)
	end)

	helpers.it("renders and delivers through the shared report page, as macOS does (healthcheck-windowless)", function()
		-- A second renderer here drifted from the shared one macOS uses
		helpers.assert_eq(require("diagnostics.ui.healthcheck.report").render_html, nil,
			"the Linux report module keeps no HTML renderer of its own")
		local ReportPage = require("diagnostics.engine.healthcheck.report_page")
		local ok, err = pcall(ReportPage.deliver, { logger = {}, log = "test" })
		helpers.assert_true(not ok and tostring(err):find("port", 1, true) ~= nil,
			"a delivery without its ports fails fast: " .. tostring(err))
		without_window(LGI, function(_, record)
			require("diagnostics.ui.healthcheck.bridge").open()
			local html = read(record.opened[1])
			helpers.assert_true(html ~= nil, "the report file exists")
			local title = html:match("<title>(.-)</title>")
			local lead = html:match("<p>(.-)</p>")
			local text = html:match("<pre>(.-)</pre>")
			local locale = html:match('<html lang="(.-)">')
			local unescape = function(s)
				return (s:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&#39;", "'"):gsub("&amp;", "&"))
			end
			helpers.assert_eq(html, ReportPage.render_html(unescape(title), unescape(lead), unescape(text), unescape(locale)),
				"the file is exactly the shared renderer's page")
		end)
	end)

	helpers.it("explains a window without a fallback by the missing component (window-missing-component)", function()
		without_window(LGI, function(manager, record)
			helpers.assert_eq(manager.show("metrics_typing"), false)
			helpers.assert_eq(#record.opened, 0, "nothing is opened in its place")
			helpers.assert_true(notice_containing(LGI) ~= nil, "a notice names the missing component")
			assert_no_raw_refusal(record)
		end)
	end)

	-- Settings, metrics, Studio and every other page answered a refused window
	-- with the raw English error « show(): native window acquisition refused »
	-- (field report, Arch KDE Plasma 6 Wayland): every registered page now
	-- either delivers itself without a window or is explained in words.
	local function registered_pages()
		local pages = {}
		for page in pairs(require("core.ui.ui.webkit_host").APP_BRIDGES) do pages[#pages + 1] = page end
		table.sort(pages)
		return pages
	end

	--- Whether a page's bridge delivers it without a window.
	--- @param page string
	--- @return boolean
	local function delivers_without_window(page)
		local manager = require("core.ui.ui.webview_manager")
		local reason_without = manager.page_unavailable_reason(page)
		require("core.ui.engine.gui_stack").record_windows_missing(LGI)
		local reason_with = manager.page_unavailable_reason(page)
		require("core.ui.engine.gui_stack")._reset_recorded_windows_missing_for_test()
		helpers.assert_eq(reason_without, nil, "no reason while windows can open: " .. page)
		return reason_with == nil
	end

	helpers.it("(window-unavailable-every-page) answers every registered page in words without lgi", function()
		local pages = registered_pages()
		helpers.assert_true(#pages >= 20, "the page registry is read: " .. #pages)
		-- The error window is its caller's notice (below); the physical
		-- shortcuts page opens only through its bridge's session, whose refusal
		-- says physical_shortcuts.window_unavailable; the bridges that deliver
		-- without a window have their own tests.
		local own_answer = { error_dialog = true, physical_shortcuts = true }
		for _, page in ipairs(pages) do
			if not own_answer[page] and not delivers_without_window(page) then
				without_window(LGI, function(manager, record)
					local before = #helpers.recorded_notices()
					manager.show(page)
					local notices = helpers.recorded_notices()
					local named = false
					for index = before + 1, #notices do
						if tostring(notices[index].message):find(LGI, 1, true) then named = true end
					end
					helpers.assert_true(named, "a notice names lgi for " .. page)
					helpers.assert_eq(record.errors, {}, "no ERROR is logged for " .. page)
					assert_no_raw_refusal(record)
				end)
			end
		end
	end)

	helpers.it("(window-unavailable-every-page) explains a refusal in words with the toolkit present", function()
		without_window(nil, function(manager, record)
			helpers.assert_eq(manager.show("metrics_typing"), false)
			local title = manager._app_title("metrics_typing")
			local notice = notice_containing(title)
			helpers.assert_true(notice ~= nil, "a notice names the window")
			helpers.assert_true(notice.message ~= "notify.window_failed", "the notice is translated")
			helpers.assert_eq(record.errors, {}, "the refusal is a warning, not the error window's ERROR")
			assert_no_raw_refusal(record)
		end)
	end)

	helpers.it("(window-unavailable-every-page) greys a page's tray row only when it cannot deliver it", function()
		local manager = require("core.ui.ui.webview_manager")
		local Host = require("core.ui.ui.webkit_host")
		for command, page in pairs(manager.TRAY_COMMAND_PAGES) do
			helpers.assert_true(Host.bridge_for_app(page) ~= nil, command .. " opens a registered page")
		end
		helpers.assert_eq(manager.command_unavailable_reason("show_typing"), nil)
		require("core.ui.engine.gui_stack").record_windows_missing(LGI)
		local ok, err = pcall(function()
			helpers.assert_eq(manager.command_unavailable_reason("show_typing"), "platform_reason.windows_need_lgi")
			helpers.assert_eq(manager.command_unavailable_reason("layout_manager"), nil,
				"the layout manager offers its install in a native question")
			helpers.assert_eq(manager.command_unavailable_reason("about_releases_page"), nil, "a browser page is not a window")
			helpers.assert_true(not pcall(require("core.ui.engine.gui_stack").record_windows_missing, LGI), "the component is recorded once")
		end)
		require("core.ui.engine.gui_stack")._reset_recorded_windows_missing_for_test()
		if not ok then error(err, 0) end
		helpers.assert_true(not pcall(require("core.ui.engine.gui_stack").record_windows_missing, "lgi"), "an unknown component is refused")
	end)

	helpers.it("leaves the error window's own notice alone (window-missing-component)", function()
		without_window(LGI, function(manager, record)
			helpers.assert_eq(manager.show("error_dialog"), false)
			helpers.assert_true(notice_containing(LGI) == nil, "its caller announces the error, not the manager")
			assert_no_raw_refusal(record)
		end)
	end)
end)
