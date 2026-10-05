-- tools/diagnostics/macos_tooltip_canvas.lua
-- Native macOS tooltip paint diagnostic. No keyboard watcher is started.
local directory = assert(debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$"))
local json = require("hs.json")
local config = assert(json.read(directory .. "/probe-config.json"))
local probe = { timers = {}, cases = {}, errors = {}, finished = false, storage_reads = 0, storage_writes = 0 }
_G.ERGOPTI_TOOLTIP_PIXEL_PROBE = probe
local Renderer

local function plain_frame(value)
	return { x = value.x, y = value.y, w = value.w, h = value.h }
end

local function observed_styles(styled)
	local native = styled:asTable()
	local observed = { native[1] }
	for index = 2, #native do
		local run = native[index]
		local color = {}
		for _, name in ipairs({ "white", "red", "green", "blue", "alpha" }) do
			color[name] = run.attributes.color[name]
		end
		observed[#observed + 1] = { starts = run.starts, ends = run.ends,
			attributes = { color = color, font = {
				name = run.attributes.font.name, size = run.attributes.font.size } } }
	end
	-- Native tables carry __luaSkinType tags for Cocoa round-tripping. Serialize
	-- only unchanged measured primitive values; do not coerce them back to Cocoa.
	return observed
end

local function cleanup()
	for timer in pairs(probe.timers) do timer:stop() end
	probe.timers = {}
	if Renderer and Renderer.canvas then
		assert(Renderer.hide() == true, "production canvas hide refused")
		assert(Renderer.canvas:isShowing() == false, "native canvas remains showing")
		Renderer.canvas:delete()
		Renderer.canvas = nil
	end
end
hs.shutdownCallback = cleanup

local function finish(failure)
	if probe.finished then return end
	probe.finished = true
	local ok, err = xpcall(cleanup, debug.traceback)
	local receipt = { status = failure and "error" or "ok", error = failure,
		runtime = "native Hammerspoon", version = hs.processInfo.version, pid = hs.processInfo.processID,
		cases = probe.cases, production_errors = probe.errors,
		canvas_cleanup = ok, cleanup_error = not ok and tostring(err) or nil,
		isolation = { logger = true, locale = true, input_tag_storage = "strict in-memory reservation",
			storage_reads = probe.storage_reads, storage_writes = probe.storage_writes },
		physical_input = "unmeasured", watcher_orchestration = "unmeasured",
		scope = "production assemble_blocks and Renderer.render; native styledtext/canvas/imageFromCanvas" }
	if not ok or #probe.errors > 0 then receipt.status = "error" end
	local temporary = config.output_dir .. "/result.json.tmp"
	assert(json.write(receipt, temporary, true, true), "result staging failed")
	assert(os.rename(temporary, config.output_dir .. "/result.json"), "result publication failed")
end

local function guarded(body)
	local ok, err = xpcall(body, debug.traceback)
	if not ok then finish(tostring(err)) end
end

local function later(body)
	local timer
	timer = hs.timer.doAfter(0.1, function()
		probe.timers[timer] = nil
		guarded(body)
	end)
	assert(timer, "native timer construction refused")
	probe.timers[timer] = true
end

guarded(function()
	assert(hs.processInfo.version == config.expected_version, "unexpected native runtime version")
	assert(hs.screen.mainScreen(), "no native GUI screen")
	local root = config.source_root .. "/static/ergopti_plus"
	package.path = root .. "/macos/?.lua;" .. root .. "/macos/?/init.lua;"
		.. root .. "/_shared/lua/?.lua;" .. root .. "/_shared/lua/?/init.lua;" .. package.path
	-- Logging/locale and unrelated input-tag persistence are isolated. Constants,
	-- APIs, shared line policy, anchor resolution and font metrics remain actual.
	local logger = {}
	for _, name in ipairs({ "start", "success", "info", "warn", "debug", "trace", "done" }) do
		logger[name] = function() end
	end
	logger.error = function(_, format, ...)
		probe.errors[#probe.errors + 1] = string.format(tostring(format), ...)
	end
	package.loaded["infra.logger"] = logger
	package.loaded["infra.i18n"] = { get = function(key) return key end }
	-- SyntheticInput reserves a global tag block at require-time. This probe never
	-- emits input; preserve the real user's high-water rather than rolling it back.
	local reservation
	package.loaded["adapters.storage"] = {
		get = function(key)
			assert(key == "synthetic_input.next_tag_sequence_v2", "unexpected configuration read")
			probe.storage_reads = probe.storage_reads + 1
			return reservation
		end,
		set = function(key, value)
			assert(key == "synthetic_input.next_tag_sequence_v2", "unexpected configuration write")
			assert(math.type(value) == "integer" and value >= 0, "invalid tag reservation")
			probe.storage_writes = probe.storage_writes + 1
			reservation = value
			return true
		end,
	}
	local Tooltip = require("ui.tooltip.tooltip_llm")
	assert(probe.storage_reads == 1 and probe.storage_writes == 1, "input-tag isolation was not exercised")
	Renderer = require("ui.tooltip.renderer")
	local Config = require("ui.tooltip.config")
	assert(type(Renderer.canvas) == "userdata", "actual canvas unavailable")
	local assemble
	for index = 1, 100 do
		local name, value = debug.getupvalue(Tooltip.show_predictions, index)
		if not name then break end
		if name == "assemble_blocks" then assemble = value; break end
	end
	assert(type(assemble) == "function", "production formatter upvalue missing")
	local origin = debug.getinfo(assemble, "S")
	assert(origin.source == "@" .. root .. "/macos/ui/tooltip/tooltip_llm.lua",
		"formatter did not come from the frozen production source")
	local regular = hs.styledtext.fontInfo({ name = ".AppleSystemUIFont", size = 14 })
	local bold = hs.styledtext.fontInfo({ name = ".AppleSystemUIFontBold", size = 14 })
	assert(regular.fontName ~= bold.fontName, "native regular/bold fonts are identical")
	local ordinal = 0
	local function next_case()
		ordinal = ordinal + 1
		if ordinal > 12 then finish(); return end
		local indent = ({ 0, 2, -1, -3 })[math.floor((ordinal - 1) / 3) + 1]
		local selected = (ordinal - 1) % 3 + 1
		local predictions = {}
		for row = 1, 3 do
			predictions[row] = { chunks = { { type = "equal", text = "MMMM" },
				{ type = "insert", text = "MMMM" } }, nw = " MMMM", has_corrections = true }
		end
		local state = { raw_predictions = predictions, current_index = selected,
			indent = indent, shortcut_mod = "none", nav_mod_str = "none" }
		local blocks = assemble(state, 3)
		local callback_count = 0
		assert(Renderer.render(blocks, state, function() callback_count = callback_count + 1 end) == true,
			"production render refused")
		assert(callback_count == 1, "native show callback did not run exactly once")
		later(function()
			assert(Renderer.canvas:isShowing() == true, "native canvas not showing at capture")
			local native_text = Renderer.canvas[3].text
			assert(type(native_text) == "userdata", "canvas native attributed text unavailable")
			local image = assert(Renderer.canvas:imageFromCanvas(), "native capture refused")
			local name = string.format("paint-%02d.png", ordinal)
			assert(not hs.fs.attributes(config.output_dir .. "/" .. name), "existing capture refused")
			-- Native PNG export only: no resize, crop, recolour or compositing.
			assert(image:saveToFile(config.output_dir .. "/" .. name, false, "PNG") == true,
				"native PNG export failed")
			local prefixes = {
				[0] = { "✨ ", "\226\128\137" }, [2] = { "  ✨ ", "\226\128\137" },
				[-1] = { "✨ ", " \226\128\137" }, [-3] = { "✨ ", "✨ " },
			}
			local advances = {}
			for _, text in ipairs(prefixes[indent]) do
				local measured = Renderer.canvas:minimumTextSize(3,
					hs.styledtext.new(text, { font = { name = ".AppleSystemUIFont", size = 14 } }))
				advances[#advances + 1] = measured.w
			end
			local glyph_widths = {}
			for _, font in ipairs({ ".AppleSystemUIFont", ".AppleSystemUIFontBold" }) do
				glyph_widths[#glyph_widths + 1] = Renderer.canvas:minimumTextSize(3,
					hs.styledtext.new("MMMM", { font = { name = font, size = 14 } })).w
			end
			local record = { ordinal = ordinal, indent = indent, selected = selected, image = name,
				showing = Renderer.canvas:isShowing(), frame = plain_frame(Renderer.canvas:frame()),
				predictions_frame = plain_frame(Renderer.canvas[3].frame),
				image_size = { w = image:size().w, h = image:size().h },
				styled = observed_styles(native_text), formatter_source = origin.source,
				font_names = { regular.fontName, bold.fontName },
				prefix_advances = advances, glyph_widths = glyph_widths }
			assert(Config.fonts.main == ".AppleSystemUIFont" and Config.fonts.bold == ".AppleSystemUIFontBold"
				and Config.sizes.main == 14, "independent typography expectations differ")
			assert(Renderer.hide() == true and Renderer.canvas:isShowing() == false,
				"native hide did not settle")
			record.hidden_after = true
			probe.cases[#probe.cases + 1] = record
			assert(#probe.errors == 0, "production render logged an error")
			next_case()
		end)
	end
	later(next_case)
end)
