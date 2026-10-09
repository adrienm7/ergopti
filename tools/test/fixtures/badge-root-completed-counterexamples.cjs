// Exact predecessor expectations remain immutable; these three physical seams moved.
'use strict';
const prior = require('./badge-root-counterexamples.cjs');
const mapped = {
	'image goes into foreign list': {
		before: 'if compose({ badge = { badge }, boundary = { boundary }, body = items }) ~= true then',
		after: 'if compose({ badge = {}, boundary = { boundary }, body = items }) ~= true then',
		port: 'actual completed badge slot of the same native target'
	},
	'boundary goes into foreign list': {
		before: 'if compose({ badge = { badge }, boundary = { boundary }, body = items }) ~= true then',
		after: 'if compose({ badge = { badge }, boundary = {}, body = items }) ~= true then',
		port: 'actual completed boundary slot of the same native target'
	},
	'native canvas allocation moved before whole-frame admission': {
		before:
			'\tlocal paused = ctx and ctx.paused\n\tlocal frame = ManifestMenu.template_rows("macos_canvas_badge_frame", {}, {\n\t\t["macos_badge_is_paused"] = function() return not not paused end,\n\t\t["macos_badge_is_active"] = function() return not paused end,\n\t}, {})\n\tif type(frame) ~= "table" or #frame ~= 2 or type(frame[1].label) ~= "string"\n\t\tor frame[1].label == "" or frame[2].separator ~= true then\n\t\tLogger.error(LOG, "Declared canvas badge presentation refused.")\n\t\treturn false\n\tend\n\tlocal compose = ManifestMenu.native_composition("macos_canvas_badge_root")\n\tif type(compose) ~= "function" then\n\t\tLogger.error(LOG, "Declared canvas badge root composition refused.")\n\t\treturn false\n\tend\n\tlocal display_text = frame[1].label\n\t-- Calculate the required canvas width based on the longest root menu item\n\tlocal max_text_width = 0\n\tfor _, item in ipairs(items) do\n\t\tif type(item.title) == "string" and item.title ~= "-" then\n\t\t\tlocal ok_s, size_s = pcall(hs.drawing.getTextDrawingSize, item.title, { font = ".AppleSystemUIFont", size = 14 })\n\t\t\tif ok_s and type(size_s) == "table" and size_s.w then\n\t\t\t\tlocal extra_width = (item.menu ~= nil) and 15 or 0\n\t\t\t\tif (size_s.w + extra_width) > max_text_width then\n\t\t\t\t\tmax_text_width = size_s.w + extra_width\n\t\t\t\tend\n\t\t\tend\n\t\tend\n\tend\n\n\t-- Create a transparent canvas that spans the available menu width to force centering\n\tlocal canvas_w = math.ceil(max_text_width)\n\n\tlocal ok, size = pcall(hs.drawing.getTextDrawingSize, display_text, { font = "Helvetica-Bold", size = 14 })\n\tlocal text_w = ok and size and size.w or 80\n\n\t-- Configure perfectly balanced padding for the pill\n\tlocal pad_x = 8\n\tlocal pad_y = 10\n\tlocal pill_w = math.ceil(text_w + (pad_x * 2))\n\tlocal pill_h = 14 + (pad_y * 2)\n\n\t-- Mathematically center the pill horizontally inside the transparent canvas\n\tlocal pill_x = (canvas_w - pill_w + 2 * pad_x) / 2\n\n\tlocal is_dark = hs.host.interfaceStyle() == "Dark"\n\tlocal bg_color   = is_dark and { white = 1 } or { white = 0.15 }\n\tlocal text_color = is_dark and { white = 0.1 } or { white = 1 }\n\tlocal menu_bg    = is_dark and { white = 0 } or { white = 1 }\n\n\t-- By default the pill uses bg_color; when paused we fill with the\n\t-- menubar background and add a thin border using a contrasting text color\n\tlocal rect_fill = bg_color\n\tlocal rect_stroke = nil\n\tlocal rect_stroke_w = nil\n\tif paused then\n\t\t-- Fill with the menubar background so the pill blends in\n\t\trect_fill = menu_bg\n\t\t-- Border/text should match the visible text color: white in Dark, black in Light\n\t\trect_stroke = is_dark and { white = 1 } or { white = 0 }\n\t\ttext_color = rect_stroke\n\t\trect_stroke_w = 1\n\tend\n\n\tlocal canvas_obj = hs.canvas.new({ x = 0, y = 0, w = canvas_w, h = pill_h })',
		after:
			'\tlocal canvas_obj = hs.canvas.new({ x = 0, y = 0, w = canvas_w, h = pill_h })\n\tlocal paused = ctx and ctx.paused\n\tlocal frame = ManifestMenu.template_rows("macos_canvas_badge_frame", {}, {\n\t\t["macos_badge_is_paused"] = function() return not not paused end,\n\t\t["macos_badge_is_active"] = function() return not paused end,\n\t}, {})\n\tif type(frame) ~= "table" or #frame ~= 2 or type(frame[1].label) ~= "string"\n\t\tor frame[1].label == "" or frame[2].separator ~= true then\n\t\tLogger.error(LOG, "Declared canvas badge presentation refused.")\n\t\treturn false\n\tend\n\tlocal compose = ManifestMenu.native_composition("macos_canvas_badge_root")\n\tif type(compose) ~= "function" then\n\t\tLogger.error(LOG, "Declared canvas badge root composition refused.")\n\t\treturn false\n\tend\n\tlocal display_text = frame[1].label\n\t-- Calculate the required canvas width based on the longest root menu item\n\tlocal max_text_width = 0\n\tfor _, item in ipairs(items) do\n\t\tif type(item.title) == "string" and item.title ~= "-" then\n\t\t\tlocal ok_s, size_s = pcall(hs.drawing.getTextDrawingSize, item.title, { font = ".AppleSystemUIFont", size = 14 })\n\t\t\tif ok_s and type(size_s) == "table" and size_s.w then\n\t\t\t\tlocal extra_width = (item.menu ~= nil) and 15 or 0\n\t\t\t\tif (size_s.w + extra_width) > max_text_width then\n\t\t\t\t\tmax_text_width = size_s.w + extra_width\n\t\t\t\tend\n\t\t\tend\n\t\tend\n\tend\n\n\t-- Create a transparent canvas that spans the available menu width to force centering\n\tlocal canvas_w = math.ceil(max_text_width)\n\n\tlocal ok, size = pcall(hs.drawing.getTextDrawingSize, display_text, { font = "Helvetica-Bold", size = 14 })\n\tlocal text_w = ok and size and size.w or 80\n\n\t-- Configure perfectly balanced padding for the pill\n\tlocal pad_x = 8\n\tlocal pad_y = 10\n\tlocal pill_w = math.ceil(text_w + (pad_x * 2))\n\tlocal pill_h = 14 + (pad_y * 2)\n\n\t-- Mathematically center the pill horizontally inside the transparent canvas\n\tlocal pill_x = (canvas_w - pill_w + 2 * pad_x) / 2\n\n\tlocal is_dark = hs.host.interfaceStyle() == "Dark"\n\tlocal bg_color   = is_dark and { white = 1 } or { white = 0.15 }\n\tlocal text_color = is_dark and { white = 0.1 } or { white = 1 }\n\tlocal menu_bg    = is_dark and { white = 0 } or { white = 1 }\n\n\t-- By default the pill uses bg_color; when paused we fill with the\n\t-- menubar background and add a thin border using a contrasting text color\n\tlocal rect_fill = bg_color\n\tlocal rect_stroke = nil\n\tlocal rect_stroke_w = nil\n\tif paused then\n\t\t-- Fill with the menubar background so the pill blends in\n\t\trect_fill = menu_bg\n\t\t-- Border/text should match the visible text color: white in Dark, black in Light\n\t\trect_stroke = is_dark and { white = 1 } or { white = 0 }\n\t\ttext_color = rect_stroke\n\t\trect_stroke_w = 1\n\tend\n\n',
		port: 'actual allocation after both caption/frame and root-composition admission'
	}
};
module.exports = prior.map((control) =>
	mapped[control.reason]
		? { ...control, before: mapped[control.reason].before, after: mapped[control.reason].after }
		: { ...control }
);
module.exports.push(
	...[
		{
			path: 'macos/ui/menu/canvas_badge.lua',
			before: 'body = items }) ~= true then',
			after: 'body = {} }) ~= true then',
			reason: 'completed badge handed to a foreign native target',
			expected: false
		},
		{
			path: 'macos/ui/menu/canvas_badge.lua',
			before: 'ManifestMenu.native_composition("macos_canvas_badge_root")',
			after: 'Unrelated.native_composition("macos_canvas_badge_root")',
			reason: 'wrong shared root composition owner',
			expected: false
		},
		{
			path: 'macos/ui/menu/canvas_badge.lua',
			before: 'if type(compose) ~= "function" then',
			after: 'if false and type(compose) ~= "function" then',
			reason: 'root policy admission weakened before native allocation',
			expected: false
		},
		{
			path: 'macos/ui/menu/canvas_badge.lua',
			before: 'local boundary = { title = frame[2].separator and "-" }',
			after: 'local boundary = { title = frame[2].separator and "-" }\n\tboundary.title = "-"',
			reason: 'completed boundary overwritten before publication',
			expected: false
		},
		{
			path: 'macos/ui/menu/canvas_badge.lua',
			before: 'local boundary = { title = frame[2].separator and "-" }',
			after: 'local boundary = { title = frame[2].separator and "-" }\n\tbadge.image = nil',
			reason: 'completed image overwritten before publication',
			expected: false
		},
		{
			path: 'macos/ui/menu/builder.lua',
			before: 'body = rendered }) ~= true then',
			after: 'body = {} }) ~= true then',
			reason: 'download composition handed to foreign native target',
			expected: false
		},
		{
			path: 'macos/ui/menu/builder.lua',
			before: 'download = _dl_item and { _dl_item } or {}',
			after: 'download = {}',
			reason: 'actual finished download result disconnected',
			expected: false
		},
		{
			path: 'macos/ui/menu/builder.lua',
			before: 'local compose_download = ManifestMenu.native_composition("macos_download_root")',
			after: 'local compose_download = Unrelated.native_composition("macos_download_root")',
			reason: 'download canonical composition owner disconnected',
			expected: false
		},
		{
			path: 'macos/ui/menu/builder.lua',
			before: 'local compose_download = ManifestMenu.native_composition("macos_download_root")',
			after:
				'local compose_download = ManifestMenu.native_composition("macos_download_root")\n\t_dl_item = {}',
			reason: 'actual producer result poisoned before composition',
			expected: false
		},
		{
			path: 'macos/ui/menu/builder.lua',
			before: 'pcall(ctx.llm_handler.build_download_item)',
			after: 'pcall(Unrelated.build_download_item)',
			reason: 'actual native download producer receiver disconnected',
			expected: false
		},
		{
			path: 'macos/ui/menu/init.lua',
			before: 'llm             = safe_require("ui.menu.menu_llm",             "AI menu")',
			after: 'llm             = safe_require("ui.menu.unrelated_llm",             "AI menu")',
			reason: 'actual exported native download producer import disconnected',
			expected: false
		},
		{
			path: 'macos/ui/menu/init.lua',
			before: 'llm_handler              = llm_handler,',
			after: 'llm_handler              = {},',
			reason: 'actual native download handler disconnected from root context',
			expected: false
		},
		{
			path: 'macos/ui/menu/menu_llm/init.lua',
			before: 'return { title = row.label, fn = row.action }',
			after: 'return { title = row.label, fn = function() end }',
			reason: 'actual finished native download callback disconnected',
			expected: false
		},
		{
			path: 'macos/ui/menu/menu_llm/init.lua',
			before: 'build_download_item = build_download_item,',
			after: 'build_download_item = function() end,',
			reason: 'actual native download handler export disconnected',
			expected: false
		}
	]
);

module.exports = module.exports.concat([
	{
		path: 'macos/ui/menu/builder.lua',
		before:
			'local projected = { id = entry.id, greyed_when_paused = entry.greyed_when_paused == true }',
		after:
			'local projected = { id = "foreign", greyed_when_paused = entry.greyed_when_paused == true }',
		reason: 'current projected top-level identity replaced',
		expected: false
	},
	{
		path: 'macos/ui/menu/builder.lua',
		before: 'table.insert(result, projected)',
		after: 'table.insert(result, {})',
		reason: 'current projected top-level record disconnected',
		expected: false
	},
	{
		path: 'macos/ui/menu/builder.lua',
		before:
			'local projected = { id = entry.id, greyed_when_paused = entry.greyed_when_paused == true }\n\t\tif entry.disabled == true then',
		after:
			'local projected = { id = entry.id, greyed_when_paused = entry.greyed_when_paused == true }\n\t\tif false then',
		reason: 'current projected disabled declaration ignored',
		expected: false
	},
	{
		path: 'macos/ui/menu/builder.lua',
		before:
			'projected.disabled, projected.i18n, projected.reason_key = true, entry.i18n, entry.reason_key',
		after: 'projected.disabled, projected.i18n, projected.reason_key = true, entry.i18n, "foreign"',
		reason: 'current projected unavailable reason replaced',
		expected: false
	}
]);
