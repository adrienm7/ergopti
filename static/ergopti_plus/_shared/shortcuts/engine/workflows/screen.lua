--- _shared/shortcuts/engine/workflows/screen.lua

--- ==============================================================================
--- MODULE: Workflow Screen Steps
--- DESCRIPTION:
--- The screen steps of a user workflow (wait_for, click_target, capture, ocr and
--- the « visible » condition) on top of one driver's screen vision service
--- (docs/design/screen-vision.md). This module owns what the steps mean; the
--- driver only says how to capture, decode an embedded image, match, read and
--- click. It is the `screen` port of the workflow effects.
---
--- FEATURES & RATIONALE:
--- 1. One meaning on every driver: a target is looked for in the front window
---    (as the auto-clicker scans it), an image target is the workflow's
---    embedded PNG, a text target is the shared fuzzy text match of the OCR
---    words, and a hit is clicked at the shared matcher's click point.
--- 2. wait_for polls every [workflows] wait_for_poll_ms until its timeout_ms and
---    then fails with image_not_found or text_not_found; the runner's deadline
---    stays the outer bound.
--- 3. A refusal of the service (permission, no OCR engine, capture refused) is
---    mapped by the step catalogue's screen_reasons to a run reason with its own
---    translated notice, never shown as « not found ».
--- 4. Cancel-safe: a late answer after a cancel (Escape, deadline) is dropped.
--- ==============================================================================

local M = {}

local Base64 = require("core.lifecycle.engine.compat.base64")

-- The run reasons and the screen vision reason these steps name themselves.
local REASON = {
	step_failed = "step_failed",
	image_not_found = "image_not_found",
	text_not_found = "text_not_found",
	template_unreadable = "template_unreadable",
}

local TEXT_TARGET_ID = "workflow_text"
local IMAGE_TARGET_ID = "workflow_image"

--- The run reason of a refusal of the service.
--- @param catalogue table The step catalogue (screen_reasons, screen_reason_other).
--- @param reason string|nil A screen vision reason.
--- @return string
function M.run_reason(catalogue, reason)
	return catalogue.screen_reasons[reason] or catalogue.screen_reason_other
end

--- The text of recognised words: words of one line joined by a space, lines
--- by a newline, in the service's reading order.
--- @param words table { { text, line } }
--- @return string
function M.words_text(words)
	local lines, current, line = {}, {}, nil
	for _, word in ipairs(words) do
		if line ~= nil and word.line ~= line then
			lines[#lines + 1] = table.concat(current, " ")
			current = {}
		end
		line = word.line
		current[#current + 1] = word.text
	end
	if #current > 0 then lines[#lines + 1] = table.concat(current, " ") end
	return table.concat(lines, "\n")
end

--- Builds the screen port.
--- @param vision table The driver's adapter: {
---   window_image(done(image|nil, reason)): the front window, as the service captures it;
---   capture(mode, done(capture|nil, reason)): full, window or region, capture { image, path };
---   template(png_bytes, key, done(template|nil, reason)): a service template of a PNG,
---     key naming it for the driver's cache;
---   match(image, templates, done(hits, refused));
---   recognize(capture, done(words|nil, reason)): capture.layout "sparse" for a
---     target search, unset (a block of text) for an ocr step;
---   save(capture, done(path|nil, reason)): a PNG file of the capture;
---   click(x, y, button, done(ok));
---   click_point(frame, scale, hit) -> x, y;
---   find_text(words, targets) -> hits;
---   after(ms, fn) -> cancel; now_ms() -> number }
--- @param options table { catalogue, poll_ms, text_max_distance, threshold }
--- @return table { wait_for, click_target, capture, ocr, visible }, each
---   (effect, done(result), workflow) -> cancel function.
function M.new(vision, options)
	assert(type(vision) == "table", "workflow screen steps need a vision adapter")
	for _, name in ipairs({ "window_image", "capture", "template", "match", "recognize", "save", "click",
		"click_point", "find_text", "after", "now_ms" }) do
		assert(type(vision[name]) == "function", "workflow screen steps need vision." .. name)
	end
	assert(type(options) == "table" and type(options.catalogue) == "table", "workflow screen steps need the catalogue")
	assert(type(options.poll_ms) == "number" and options.poll_ms > 0, "workflow screen steps need a poll interval")
	local catalogue = options.catalogue
	local screen = {}

	--- A one-shot answer that a cancel silences.
	--- @param done function
	--- @return function answer, function cancel, function live, function keep
	---   keep(cancel_fn) records the pending timer the cancel also stops.
	local function guarded(done)
		local open, pending_cancel = true, nil
		local function answer(result)
			if not open then return end
			open = false
			done(result)
		end
		local function cancel()
			open = false
			if pending_cancel then pending_cancel(); pending_cancel = nil end
		end
		local function keep(fn) pending_cancel = fn end
		return answer, cancel, function() return open end, keep
	end

	local function refused(reason) return { ok = false, reason = M.run_reason(catalogue, reason) } end

	--- Looks for a target once in the front window.
	--- @param target table { type = "image", image } or { type = "text", text }.
	--- @param workflow table The running workflow (its images).
	--- @param live function Whether the step still waits.
	--- @param done function done(point|false, reason): point { x, y } when found.
	local function find(target, workflow, live, done)
		vision.window_image(function(image, reason)
			if not live() then return end
			if image == nil then return done(nil, reason) end
			if target.type == "image" then
				local data = type(workflow.images) == "table" and workflow.images[target.image] or nil
				assert(type(data) == "string", "a validated workflow names only its own images")
				local bytes = Base64.decode(data)
				if bytes == nil then return done(nil, REASON.template_unreadable) end
				vision.template(bytes, workflow.id .. "/" .. target.image, function(template, template_reason)
					if not live() then return end
					if template == nil then return done(nil, template_reason) end
					template.id = IMAGE_TARGET_ID
					template.threshold = template.threshold or options.threshold
					vision.match(image, { template }, function(hits, refusals)
						if not live() then return end
						local hit = hits and hits[1]
						if hit then
							local x, y = vision.click_point(image.frame, image.scale, hit)
							return done({ x = x, y = y })
						end
						local refusal = refusals and refusals[IMAGE_TARGET_ID]
						if refusal then return done(nil, refusal) end
						done(false)
					end)
				end)
			else
				vision.recognize({ image = image, layout = "sparse" }, function(words, ocr_reason)
					if not live() then return end
					if words == nil then return done(nil, ocr_reason) end
					local hits = vision.find_text(words, { { id = TEXT_TARGET_ID, variants = { target.text },
						max_distance = options.text_max_distance } })
					local hit = hits[1]
					if not hit then return done(false) end
					local x, y = vision.click_point(image.frame, image.scale, hit)
					done({ x = x, y = y })
				end)
			end
		end)
	end

	local function not_found(target)
		return { ok = false, reason = target.type == "image" and REASON.image_not_found or REASON.text_not_found }
	end

	--- « If visible »: one look, the answer as the condition's value.
	function screen.visible(effect, done, workflow)
		local answer, cancel, live = guarded(done)
		find(effect.condition.target, workflow, live, function(point, reason)
			if point == nil then return answer(refused(reason)) end
			answer({ ok = true, value = point ~= false })
		end)
		return cancel
	end

	--- Waits until the target shows, polling until timeout_ms.
	function screen.wait_for(effect, done, workflow)
		local answer, cancel, live, keep = guarded(done)
		local until_ms = vision.now_ms() + effect.timeout_ms
		local function look()
			find(effect.target, workflow, live, function(point, reason)
				if point == nil then return answer(refused(reason)) end
				if point then return answer({ ok = true }) end
				if vision.now_ms() + options.poll_ms > until_ms then return answer(not_found(effect.target)) end
				keep(vision.after(options.poll_ms, function() if live() then look() end end))
			end)
		end
		look()
		return cancel
	end

	--- Clicks the target where it shows now.
	function screen.click_target(effect, done, workflow)
		local answer, cancel, live = guarded(done)
		find(effect.target, workflow, live, function(point, reason)
			if point == nil then return answer(refused(reason)) end
			if not point then return answer(not_found(effect.target)) end
			vision.click(point.x, point.y, effect.button or "left", function(ok)
				if ok then answer({ ok = true }) else answer({ ok = false, reason = REASON.step_failed }) end
			end)
		end)
		return cancel
	end

	--- Captures an area; its PNG file's path is the step's value.
	function screen.capture(effect, done)
		local answer, cancel, live = guarded(done)
		vision.capture(effect.mode, function(capture, reason)
			if not live() then return end
			if capture == nil then return answer(refused(reason)) end
			vision.save(capture, function(path, save_reason)
				if not live() then return end
				if path == nil then return answer(refused(save_reason)) end
				answer({ ok = true, value = path })
			end)
		end)
		return cancel
	end

	--- Reads the text of an area; the text is the step's value.
	function screen.ocr(effect, done)
		local answer, cancel, live = guarded(done)
		vision.capture(effect.mode, function(capture, reason)
			if not live() then return end
			if capture == nil then return answer(refused(reason)) end
			vision.recognize(capture, function(words, ocr_reason)
				if not live() then return end
				if words == nil then return answer(refused(ocr_reason)) end
				answer({ ok = true, value = M.words_text(words) })
			end)
		end)
		return cancel
	end

	return screen
end

return M
