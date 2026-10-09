// tools/test/fixtures/badge-root-counterexamples.cjs

'use strict';

module.exports = [
	{
		path: 'macos/ui/menu/init.lua',
		before: 'local Builder       = require("ui.menu.builder")',
		after: 'local Builder       = require("ui.menu.unrelated_builder")',
		expected: false,
		reason: 'wrong imported producer'
	},
	{
		path: 'macos/ui/menu/init.lua',
		before: 'pcall(Builder.generate, ctx, menu_mods, actions)',
		after: 'pcall(Unrelated.generate, ctx, menu_mods, actions)',
		expected: false,
		reason: 'wrong producer receiver'
	},
	{
		path: 'macos/ui/menu/builder.lua',
		before: 'local CanvasBadge = require("ui.menu.canvas_badge")',
		after: 'local CanvasBadge = require("ui.menu.unrelated_badge")',
		expected: false,
		reason: 'wrong imported consumer'
	},
	{
		path: 'macos/ui/menu/builder.lua',
		before: 'pcall(CanvasBadge.prepend_to, rendered, ctx, function()',
		after: 'pcall(CanvasBadge.prepend_to, {}, ctx, function()',
		expected: false,
		reason: 'different native output list'
	},
	{
		path: 'macos/ui/menu/builder.lua',
		before: 'pcall(CanvasBadge.prepend_to, rendered, ctx, function()',
		after: 'pcall(Unrelated.prepend_to, rendered, ctx, function()',
		expected: false,
		reason: 'wrong consumer receiver'
	},
	{
		path: 'macos/ui/menu/builder.lua',
		before: '\treturn rendered\nend\n\nreturn M',
		after: '\treturn {}\nend\n\nreturn M',
		expected: false,
		reason: 'native decorated list not returned'
	},
	{
		path: 'macos/ui/menu/canvas_badge.lua',
		before: 'function M.prepend_to(items, ctx, on_click)',
		after: 'local function decoy_prepend_to(items, ctx, on_click)',
		expected: false,
		reason: 'actual exported consumer withdrawn'
	},
	{
		path: 'macos/ui/menu/canvas_badge.lua',
		before: 'local ManifestMenu = require("infra.manifest_menu")',
		after: 'local ManifestMenu = require("infra.unrelated_manifest")',
		expected: false,
		reason: 'wrong frame owner import'
	},
	{
		path: 'macos/ui/menu/canvas_badge.lua',
		before: 'ManifestMenu.template_rows("macos_canvas_badge_frame"',
		after: 'ManifestMenu.template_rows("unrelated_badge_frame"',
		expected: false,
		reason: 'wrong actual frame'
	},
	{
		path: 'macos/ui/menu/canvas_badge.lua',
		before: '["macos_badge_is_paused"] = function() return not not paused end',
		after: '["macos_badge_is_paused"] = nil',
		expected: false,
		reason: 'withdrawn actual paused getter'
	},
	{
		path: 'macos/ui/menu/canvas_badge.lua',
		before: '["macos_badge_is_active"] = function() return not paused end',
		after: '["macos_badge_is_active"] = {}',
		expected: false,
		reason: 'noncallable actual active getter'
	},
	{
		path: 'macos/ui/menu/canvas_badge.lua',
		before: 'local display_text = frame[1].label',
		after: 'local display_text = "Unrelated caption"',
		expected: false,
		reason: 'shared caption output disconnected'
	},
	{
		path: 'macos/ui/menu/canvas_badge.lua',
		before: 'text          = display_text',
		after: 'text          = "Unrelated caption"',
		expected: false,
		reason: 'native text disconnected from shared caption'
	},
	{
		path: 'macos/ui/menu/canvas_badge.lua',
		before: 'image = img',
		after: 'image = nil',
		expected: false,
		reason: 'actual native badge image output withdrawn'
	},
	{
		path: 'macos/ui/menu/canvas_badge.lua',
		before: 'fn    = on_click',
		after: 'fn    = function() end',
		expected: false,
		reason: 'actual native badge callback disconnected'
	},
	{
		path: 'macos/ui/menu/canvas_badge.lua',
		before: 'title = frame[2].separator and "-"',
		after: 'title = "-"',
		expected: false,
		reason: 'declared boundary output disconnected'
	},
	{
		path: 'macos/ui/menu/builder.lua',
		before: 'local ok_badge, badge_err = pcall(CanvasBadge.prepend_to, rendered, ctx, function()',
		after:
			'local CanvasBadge = { prepend_to = function() end }\n\tlocal ok_badge, badge_err = pcall(CanvasBadge.prepend_to, rendered, ctx, function()',
		expected: false,
		reason: 'local receiver shadow'
	},
	{
		path: 'macos/ui/menu/builder.lua',
		before: 'local ok_badge, badge_err = pcall(CanvasBadge.prepend_to, rendered, ctx, function()',
		after:
			'CanvasBadge = { prepend_to = function() end }\n\tlocal ok_badge, badge_err = pcall(CanvasBadge.prepend_to, rendered, ctx, function()',
		expected: false,
		reason: 'imported receiver reassignment'
	},
	{
		path: 'macos/ui/menu/builder.lua',
		before: 'local ok_badge, badge_err = pcall(CanvasBadge.prepend_to, rendered, ctx, function()',
		after:
			'local ignored, CanvasBadge\n\tlocal ok_badge, badge_err = pcall(CanvasBadge.prepend_to, rendered, ctx, function()',
		expected: false,
		reason: 'second uninitialized local receiver shadow'
	},
	{
		path: 'macos/ui/menu/init.lua',
		before: 'local ok_b, items = pcall(Builder.generate, ctx, menu_mods, actions)',
		after:
			'local function decoy() return pcall(Builder.generate, ctx, menu_mods, actions) end\n\t\tlocal ok_b, items = false, {}',
		expected: false,
		reason: 'actual producer moved into uncalled decoy'
	},
	{
		path: 'macos/ui/menu/init.lua',
		before: 'local ok_b, items = pcall(Builder.generate, ctx, menu_mods, actions)',
		after:
			'local quote = "pcall(Builder.generate, ctx, menu_mods, actions)"\n\t\tlocal ok_b, items = false, {}',
		expected: false,
		reason: 'actual producer replaced by quote'
	},
	{
		path: 'macos/ui/menu/init.lua',
		before: '_cached_menu_items = items',
		after: '_cached_menu_items = {}',
		expected: false,
		reason: 'actual dynamic cache output disconnected'
	},
	{
		path: 'macos/ui/menu/init.lua',
		before: 'push_static_menu(items)',
		after: 'push_static_menu({})',
		expected: false,
		reason: 'actual static output disconnected'
	},
	{
		path: 'macos/ui/menu/init.lua',
		before: 'return TrayMenu.setMenu(candidate) == true',
		after: 'return true',
		expected: false,
		reason: 'actual static native publication withdrawn'
	},
	{
		path: 'macos/ui/menu/builder.lua',
		before: 'function M.generate(ctx, menu_mods, actions)',
		after: 'local function decoy_generate(ctx, menu_mods, actions)',
		expected: false,
		reason: 'exported producer withdrawn'
	},
	{
		path: 'macos/ui/menu/builder.lua',
		before: 'return rendered\nend\n\nreturn M',
		after: 'return rendered\nend\n\nM.generate = function() return {} end\nreturn M',
		expected: false,
		reason: 'actual exported producer replaced after declaration'
	},
	{
		path: 'macos/ui/menu/builder.lua',
		before: 'return rendered\nend\n\nreturn M',
		after: 'return rendered\nend\n\nM["generate"] = function() return {} end\nreturn M',
		expected: false,
		reason: 'actual exported producer replaced by bracket assignment'
	},
	{
		path: 'macos/ui/menu/builder.lua',
		before: 'local rendered = ManifestMenu.render_rows(items, "top_level")',
		after: 'local rendered = ManifestMenu.render_rows(items, "unrelated_root")',
		expected: false,
		reason: 'actual canonical root renderer withdrawn'
	},
	{
		path: 'macos/ui/menu/canvas_badge.lua',
		before: 'local display_text = frame[1].label',
		after: 'frame[1].label = "Unrelated"\n\tlocal display_text = frame[1].label',
		expected: false,
		reason: 'declared caption overwritten before consumption'
	},
	{
		path: 'macos/ui/menu/canvas_badge.lua',
		before: 'local display_text = frame[1].label',
		after: 'local display_text = frame[1].label\n\tdisplay_text = "Unrelated"',
		expected: false,
		reason: 'native caption binding reassigned'
	},
	{
		path: 'macos/ui/menu/canvas_badge.lua',
		before: 'local canvas_obj = hs.canvas.new(',
		after: 'local canvas_obj = Unrelated.canvas.new(',
		expected: false,
		reason: 'native image allocator disconnected'
	},
	{
		path: 'macos/ui/menu/canvas_badge.lua',
		before: 'canvas_obj:appendElements(',
		after: 'Unrelated:appendElements(',
		expected: false,
		reason: 'native drawing output disconnected'
	},
	{
		path: 'macos/ui/menu/canvas_badge.lua',
		before: 'canvas_obj:delete()',
		after: '-- canvas_obj:delete()',
		expected: false,
		reason: 'native image lifecycle deletion withdrawn'
	},
	{
		path: 'macos/ui/menu/canvas_badge.lua',
		before: 'local paused = ctx and ctx.paused',
		after: 'local paused = false',
		expected: false,
		reason: 'actual native paused input disconnected'
	},
	{
		path: 'macos/ui/menu/canvas_badge.lua',
		before: 'table.insert(items, 1, {',
		after: 'table.insert({}, 1, {',
		expected: false,
		reason: 'image goes into foreign list'
	},
	{
		path: 'macos/ui/menu/canvas_badge.lua',
		before: 'table.insert(items, 2, { title = frame[2].separator and "-" })',
		after: 'table.insert({}, 2, { title = frame[2].separator and "-" })',
		expected: false,
		reason: 'boundary goes into foreign list'
	},
	{
		path: 'macos/ui/menu/builder.lua',
		before: 'local CanvasBadge = require("ui.menu.canvas_badge")',
		after: '-- local CanvasBadge = require("ui.menu.canvas_badge")',
		expected: false,
		reason: 'actual import commented out'
	},
	{
		path: 'macos/ui/menu/builder.lua',
		before: 'return ManifestMenu.get_root()',
		after: 'return Unrelated.get_root()',
		expected: false,
		reason: 'actual canonical root loader disconnected'
	},
	{
		path: 'macos/ui/menu/builder.lua',
		before: 'for _, entry in ipairs(data.top_level) do',
		after: 'for _, entry in ipairs(data.unrelated_root) do',
		expected: false,
		reason: 'native source root inventory disconnected'
	},
	{
		path: 'macos/ui/menu/builder.lua',
		before: 'local function load_top_level()',
		after: 'local function decoy_load_top_level()',
		expected: false,
		reason: 'actual canonical root producer withdrawn'
	},
	{
		path: 'macos/ui/menu/canvas_badge.lua',
		before: 'if type(frame) ~= "table" or #frame ~= 2',
		after: 'if false and type(frame) ~= "table" or #frame ~= 2',
		expected: false,
		reason: 'native whole-frame refusal predicate weakened'
	},
	{
		path: 'macos/ui/menu/builder.lua',
		before:
			'\tlocal ok_badge, badge_err = pcall(CanvasBadge.prepend_to, rendered, ctx, function()\n\t\tif ctx and ctx.script_control then\n\t\t\tif type(ctx.script_control.toggle_script_control) == "function" then pcall(ctx.script_control.toggle_script_control) end\n\t\t\tif type(ctx.script_control.toggle) == "function" then pcall(ctx.script_control.toggle) end\n\t\tend\n\tend)',
		after:
			'\tlocal function decoy_badge()\n\tlocal ok_badge, badge_err = pcall(CanvasBadge.prepend_to, rendered, ctx, function()\n\t\tif ctx and ctx.script_control then\n\t\t\tif type(ctx.script_control.toggle_script_control) == "function" then pcall(ctx.script_control.toggle_script_control) end\n\t\t\tif type(ctx.script_control.toggle) == "function" then pcall(ctx.script_control.toggle) end\n\t\tend\n\tend)\n\tend\n\tlocal ok_badge, badge_err = true, nil',
		expected: false,
		reason: 'genuine consumer call moved into uncalled decoy'
	},
	{
		path: 'macos/ui/menu/builder.lua',
		before: 'local data = load_manifest()',
		after: 'local data = load_manifest()\n\tdata = { top_level = {} }',
		expected: false,
		reason: 'canonical root data binding replaced'
	},
	{
		path: 'macos/ui/menu/builder.lua',
		before: 'local data = load_manifest()',
		after: 'local data = load_manifest()\n\tdata, ignored = { top_level = {} }, nil',
		expected: false,
		reason: 'canonical root first multi-assignment binding replaced'
	},
	{
		path: 'macos/ui/menu/builder.lua',
		before: '\t_top_level_cache = result\n\treturn _top_level_cache',
		after: '\tresult = {}\n\t_top_level_cache = result\n\treturn _top_level_cache',
		expected: false,
		reason: 'canonical filtered root result replaced'
	},
	{
		path: 'macos/ui/menu/builder.lua',
		before: '\t_top_level_cache = result\n\treturn _top_level_cache',
		after: '\t_top_level_cache = result\n\t_top_level_cache = {}\n\treturn _top_level_cache',
		expected: false,
		reason: 'published canonical root cache replaced'
	},
	{
		path: 'macos/ui/menu/builder.lua',
		before: 'local function load_top_level()',
		after:
			'load_manifest = function() return { top_level = {} } end\nlocal function load_top_level()',
		expected: false,
		reason: 'canonical root loader rebound before consumer'
	},
	{
		path: 'macos/ui/menu/builder.lua',
		before: 'function M.generate(ctx, menu_mods, actions)',
		after:
			'load_top_level = function() return {} end\nfunction M.generate(ctx, menu_mods, actions)',
		expected: false,
		reason: 'canonical root enumeration owner rebound'
	},
	{
		path: 'macos/ui/menu/builder.lua',
		before: '\tlocal rendered = ManifestMenu.render_rows(items, "top_level")',
		after: '\titems = {}\n\tlocal rendered = ManifestMenu.render_rows(items, "top_level")',
		expected: false,
		reason: 'native generated root list replaced before renderer'
	},
	{
		path: 'macos/ui/menu/init.lua',
		before: 'local ok_b, items = pcall(Builder.generate, ctx, menu_mods, actions)',
		after: 'local ok_b, items = pcall(Builder.generate, ctx, menu_mods, actions)\n\t\titems = {}',
		expected: false,
		reason: 'actual generated native list replaced before publication'
	},
	{
		path: 'macos/ui/menu/init.lua',
		before: 'local ok_b, items = pcall(Builder.generate, ctx, menu_mods, actions)',
		after: 'local ok_b, items = pcall(Builder.generate, ctx, menu_mods, actions)\n\t\tok_b = false',
		expected: false,
		reason: 'actual generated native acknowledgment overwritten'
	},
	{
		path: 'macos/ui/menu/init.lua',
		before: 'local candidate = items or _cached_menu_items',
		after: 'local candidate = items or _cached_menu_items\n\t\tcandidate = {}',
		expected: false,
		reason: 'static native candidate replaced'
	},
	{
		path: 'macos/ui/menu/init.lua',
		before: 'local TrayMenu      = require("adapters.tray_menu")',
		after: 'local TrayMenu      = require("adapters.unrelated_menu")',
		expected: false,
		reason: 'static native publication adapter import changed'
	},
	{
		path: 'macos/ui/menu/init.lua',
		before: 'return TrayMenu.setMenu(candidate) == true',
		after:
			'local TrayMenu = { setMenu = function() return true end }\n\t\treturn TrayMenu.setMenu(candidate) == true',
		expected: false,
		reason: 'static native publication adapter shadowed'
	},
	{
		path: 'macos/ui/menu/canvas_badge.lua',
		before: 'local hs     = hs',
		after: 'local hs     = Unrelated',
		expected: false,
		reason: 'native canvas receiver alias replaced'
	},
	{
		path: 'macos/ui/menu/canvas_badge.lua',
		before: 'local paused = ctx and ctx.paused',
		after: 'local hs = Unrelated\n\tlocal paused = ctx and ctx.paused',
		expected: false,
		reason: 'native canvas receiver shadowed inside consumer'
	},
	{
		path: 'macos/ui/menu/canvas_badge.lua',
		before:
			'canvas_obj:appendElements(\n\t\trect_elem,\n\t\t{\n\t\t\ttype          = "text",\n\t\t\ttext          = display_text,',
		after:
			'local inert_text = { text = display_text }\n\tcanvas_obj:appendElements(\n\t\trect_elem,\n\t\t{\n\t\t\ttype          = "text",\n\t\t\ttext          = "Unrelated native caption",',
		expected: false,
		reason: 'shared caption appears only in disconnected drawing data'
	},
	{
		path: 'macos/ui/menu/canvas_badge.lua',
		before:
			'\tlocal paused = ctx and ctx.paused\n\tlocal frame = ManifestMenu.template_rows("macos_canvas_badge_frame", {}, {\n\t\t["macos_badge_is_paused"] = function() return not not paused end,\n\t\t["macos_badge_is_active"] = function() return not paused end,\n\t}, {})\n\tif type(frame) ~= "table" or #frame ~= 2 or type(frame[1].label) ~= "string"\n\t\tor frame[1].label == "" or frame[2].separator ~= true then\n\t\tLogger.error(LOG, "Declared canvas badge presentation refused.")\n\t\treturn false\n\tend\n\tlocal display_text = frame[1].label\n\t-- Calculate the required canvas width based on the longest root menu item\n\tlocal max_text_width = 0\n\tfor _, item in ipairs(items) do\n\t\tif type(item.title) == "string" and item.title ~= "-" then\n\t\t\tlocal ok_s, size_s = pcall(hs.drawing.getTextDrawingSize, item.title, { font = ".AppleSystemUIFont", size = 14 })\n\t\t\tif ok_s and type(size_s) == "table" and size_s.w then\n\t\t\t\tlocal extra_width = (item.menu ~= nil) and 15 or 0\n\t\t\t\tif (size_s.w + extra_width) > max_text_width then\n\t\t\t\t\tmax_text_width = size_s.w + extra_width\n\t\t\t\tend\n\t\t\tend\n\t\tend\n\tend\n\n\t-- Create a transparent canvas that spans the available menu width to force centering\n\tlocal canvas_w = math.ceil(max_text_width)\n\n\tlocal ok, size = pcall(hs.drawing.getTextDrawingSize, display_text, { font = "Helvetica-Bold", size = 14 })\n\tlocal text_w = ok and size and size.w or 80\n\n\t-- Configure perfectly balanced padding for the pill\n\tlocal pad_x = 8\n\tlocal pad_y = 10\n\tlocal pill_w = math.ceil(text_w + (pad_x * 2))\n\tlocal pill_h = 14 + (pad_y * 2)\n\n\t-- Mathematically center the pill horizontally inside the transparent canvas\n\tlocal pill_x = (canvas_w - pill_w + 2 * pad_x) / 2\n\n\tlocal is_dark = hs.host.interfaceStyle() == "Dark"\n\tlocal bg_color   = is_dark and { white = 1 } or { white = 0.15 }\n\tlocal text_color = is_dark and { white = 0.1 } or { white = 1 }\n\tlocal menu_bg    = is_dark and { white = 0 } or { white = 1 }\n\n\t-- By default the pill uses bg_color; when paused we fill with the\n\t-- menubar background and add a thin border using a contrasting text color\n\tlocal rect_fill = bg_color\n\tlocal rect_stroke = nil\n\tlocal rect_stroke_w = nil\n\tif paused then\n\t\t-- Fill with the menubar background so the pill blends in\n\t\trect_fill = menu_bg\n\t\t-- Border/text should match the visible text color: white in Dark, black in Light\n\t\trect_stroke = is_dark and { white = 1 } or { white = 0 }\n\t\ttext_color = rect_stroke\n\t\trect_stroke_w = 1\n\tend\n\n\tlocal canvas_obj = hs.canvas.new({ x = 0, y = 0, w = canvas_w, h = pill_h })',
		after:
			'\tlocal canvas_obj = hs.canvas.new({ x = 0, y = 0, w = canvas_w, h = pill_h })\n\tlocal paused = ctx and ctx.paused\n\tlocal frame = ManifestMenu.template_rows("macos_canvas_badge_frame", {}, {\n\t\t["macos_badge_is_paused"] = function() return not not paused end,\n\t\t["macos_badge_is_active"] = function() return not paused end,\n\t}, {})\n\tif type(frame) ~= "table" or #frame ~= 2 or type(frame[1].label) ~= "string"\n\t\tor frame[1].label == "" or frame[2].separator ~= true then\n\t\tLogger.error(LOG, "Declared canvas badge presentation refused.")\n\t\treturn false\n\tend\n\tlocal display_text = frame[1].label\n\t-- Calculate the required canvas width based on the longest root menu item\n\tlocal max_text_width = 0\n\tfor _, item in ipairs(items) do\n\t\tif type(item.title) == "string" and item.title ~= "-" then\n\t\t\tlocal ok_s, size_s = pcall(hs.drawing.getTextDrawingSize, item.title, { font = ".AppleSystemUIFont", size = 14 })\n\t\t\tif ok_s and type(size_s) == "table" and size_s.w then\n\t\t\t\tlocal extra_width = (item.menu ~= nil) and 15 or 0\n\t\t\t\tif (size_s.w + extra_width) > max_text_width then\n\t\t\t\t\tmax_text_width = size_s.w + extra_width\n\t\t\t\tend\n\t\t\tend\n\t\tend\n\tend\n\n\t-- Create a transparent canvas that spans the available menu width to force centering\n\tlocal canvas_w = math.ceil(max_text_width)\n\n\tlocal ok, size = pcall(hs.drawing.getTextDrawingSize, display_text, { font = "Helvetica-Bold", size = 14 })\n\tlocal text_w = ok and size and size.w or 80\n\n\t-- Configure perfectly balanced padding for the pill\n\tlocal pad_x = 8\n\tlocal pad_y = 10\n\tlocal pill_w = math.ceil(text_w + (pad_x * 2))\n\tlocal pill_h = 14 + (pad_y * 2)\n\n\t-- Mathematically center the pill horizontally inside the transparent canvas\n\tlocal pill_x = (canvas_w - pill_w + 2 * pad_x) / 2\n\n\tlocal is_dark = hs.host.interfaceStyle() == "Dark"\n\tlocal bg_color   = is_dark and { white = 1 } or { white = 0.15 }\n\tlocal text_color = is_dark and { white = 0.1 } or { white = 1 }\n\tlocal menu_bg    = is_dark and { white = 0 } or { white = 1 }\n\n\t-- By default the pill uses bg_color; when paused we fill with the\n\t-- menubar background and add a thin border using a contrasting text color\n\tlocal rect_fill = bg_color\n\tlocal rect_stroke = nil\n\tlocal rect_stroke_w = nil\n\tif paused then\n\t\t-- Fill with the menubar background so the pill blends in\n\t\trect_fill = menu_bg\n\t\t-- Border/text should match the visible text color: white in Dark, black in Light\n\t\trect_stroke = is_dark and { white = 1 } or { white = 0 }\n\t\ttext_color = rect_stroke\n\t\trect_stroke_w = 1\n\tend\n\n',
		expected: false,
		reason: 'native canvas allocation moved before whole-frame admission'
	},
	{
		path: 'macos/ui/menu/builder.lua',
		before: 'local rendered = ManifestMenu.render_rows(items, "top_level")',
		after:
			'local rendered = ManifestMenu.render_rows(items, "top_level")\n\tlocal function captured_root_poison() rendered = {} end',
		expected: false,
		reason: 'child function writes captured returned native root binding'
	},
	{
		path: 'macos/ui/menu/builder.lua',
		before: 'local rendered = ManifestMenu.render_rows(items, "top_level")',
		after:
			'local rendered = ManifestMenu.render_rows(items, "top_level")\n\tlocal function captured_root_poison() do local rendered = {} end; rendered = {} end',
		expected: false,
		reason: 'expired child-local shadow does not hide captured outer root write'
	}
];
