--- _shared/tests/lua/auto_click_contract.lua

--- ==============================================================================
--- MODULE: Auto-Click Contract
--- DESCRIPTION:
--- Replays the anti-sleep auto-clicker corpora through the shared matcher,
--- text targets and policy (_shared/shortcuts/engine/auto_click_*.lua and
--- text_target.lua). The macOS suite runs it
--- on Lua 5.4 and the Linux suite on LuaJIT, so an integer division, a float
--- key or a wrapped product that only one runtime tolerates fails here; the
--- Windows twin replays the same files.
---
--- FEATURES & RATIONALE:
--- 1. The scenes are recipes, not pixel dumps: a background, a deterministic
---    noise and pasted templates, so a vector reads as what it tests.
--- 2. Each vector pins the position, the size and the scale of the match, or
---    its absence and refusal reason.
--- ==============================================================================

local M = {}

local Json = require("core.text.engine.json")
local Matcher = require("shortcuts.engine.auto_click_matcher")
local Policy = require("shortcuts.engine.auto_click_policy")
local TextTarget = require("shortcuts.engine.text_target")

local PARK_MILLER_MULTIPLIER = 16807
local PARK_MILLER_MODULUS = 2147483647

--- Reads a JSON file under _shared/.
--- @param shared function The driver's helper resolving a path under _shared/.
--- @param relative string Path under _shared/.
--- @return table decoded
local function read_json(shared, relative)
	local handle = assert(io.open(shared(relative), "rb"))
	local text = handle:read("*a")
	handle:close()
	return assert(Json.decode_lossless(text))
end

--- Reads a corpus file under _shared/tests/corpus/keep_awake/.
--- @param shared function The driver's helper resolving a path under _shared/.
--- @param name string File name.
--- @return table corpus
local function load(shared, name)
	local handle = assert(io.open(shared("tests/corpus/keep_awake/" .. name), "rb"))
	local text = handle:read("*a")
	handle:close()
	return assert(Json.decode_lossless(text))
end

local function clamp(v)
	if v < 0 then return 0 end
	if v > 255 then return 255 end
	return v
end

--- A template image from its character rows.
--- @param corpus table
--- @param name string
--- @return table image
function M.template(corpus, name)
	local rows = {}
	for y, text in ipairs(corpus.templates[name]) do
		rows[y] = {}
		for x = 1, #text do rows[y][x] = assert(corpus.palette[text:sub(x, x)], "no palette entry") end
	end
	return Matcher.from_rows(rows)
end

--- Adds the corpus noise to an image in place.
local function add_noise(image, noise)
	if not noise or noise.amplitude == 0 then return end
	local state, span = noise.seed, 2 * noise.amplitude + 1
	for i = 1, image.width * image.height do
		state = (state * PARK_MILLER_MULTIPLIER) % PARK_MILLER_MODULUS
		image.pixels[i] = clamp(image.pixels[i] + state % span - noise.amplitude)
	end
end

--- Builds a scene image from its recipe.
--- @param corpus table
--- @param scene table
--- @return table image
function M.scene(corpus, scene)
	local pixels = {}
	for i = 1, scene.width * scene.height do pixels[i] = scene.background end
	local image = { width = scene.width, height = scene.height, pixels = pixels }
	add_noise(image, scene.noise)
	for _, paste in ipairs(scene.pastes) do
		local t = Matcher.scale(M.template(corpus, paste.template), paste.scale)
		for y = 0, t.height - 1 do
			for x = 0, t.width - 1 do
				image.pixels[(paste.y + y) * scene.width + paste.x + x + 1] =
					clamp(t.pixels[y * t.width + x + 1] + paste.delta)
			end
		end
	end
	add_noise(image, scene.overlay_noise)
	return image
end

--- The matcher options of a vector: the corpus options, its threshold if any.
local function options_for(corpus, vector)
	local options = {}
	for key, value in pairs(corpus.options) do options[key] = value end
	if vector.threshold then options.threshold = vector.threshold end
	return options
end

--- Registers the contract on one driver's suite.
--- @param helpers table The driver's test helpers.
--- @param options table { driver = string, shared = function(relative) -> path }
function M.register(helpers, options)
	assert(type(options) == "table" and type(options.driver) == "string" and type(options.shared) == "function",
		"the auto-click contract needs a driver name and a _shared path resolver")
	local match_corpus = load(options.shared, "auto_click_match_vectors.json")
	local policy_corpus = load(options.shared, "auto_click_policy_vectors.json")
	local text_corpus = load(options.shared, "text_target_vectors.json")
	TextTarget.set_fold(read_json(options.shared, "core/text/data/text_fold.json").fold)

	helpers.describe("auto-click matcher vectors: " .. options.driver, function()
		for _, vector in ipairs(match_corpus.vectors) do
			helpers.it(vector.id, function()
				local image = M.scene(match_corpus, vector.scene)
				local template = Matcher.scale(M.template(match_corpus, vector.template), vector.template_scale or 1)
				local match, reason = Matcher.find(image, template, options_for(match_corpus, vector))
				local expect = vector.expect
				if expect == nil or Json.is_null(expect) then
					helpers.assert_nil(match, vector.id .. " must not match")
				else
					helpers.assert_not_nil(match, vector.id .. " must match")
					for _, key in ipairs({ "x", "y", "width", "height", "scale" }) do
						helpers.assert_eq(match[key], expect[key], vector.id .. " " .. key)
					end
				end
				if vector.reason then helpers.assert_eq(reason, vector.reason, vector.id .. " reason") end
				if vector.score_near then
					local best = Matcher.find(image, template, options_for(match_corpus, { threshold = 0.01 }))
					helpers.assert_true(math.abs(best.score - vector.score_near) < 1e-6,
						vector.id .. " score " .. tostring(best.score))
				end
			end)
		end

		helpers.it("refuses a flat template at import", function()
			local ok, reason = Matcher.check_template(M.template(match_corpus, "flat"))
			helpers.assert_eq(ok, false, "flat template")
			helpers.assert_eq(reason, "template_uniform", "flat template reason")
			helpers.assert_eq(Matcher.check_template(M.template(match_corpus, "button")), true, "button template")
		end)

		helpers.it("rounds gray as every driver does", function()
			helpers.assert_eq(Matcher.gray(255, 0, 255), 105, "BT.601 gray of magenta")
		end)

		helpers.it("clicks the centre of a match in screen points", function()
			local x, y = Matcher.click_point({ x = 100, y = 50 }, 2, { x = 50, y = 30, width = 48, height = 24 })
			helpers.assert_eq(x, 137, "x")
			helpers.assert_eq(y, 71, "y")
		end)
	end)

	helpers.describe("text target vectors: " .. options.driver, function()
		for _, vector in ipairs(text_corpus.normalize) do
			helpers.it("normalize " .. vector.id, function()
				helpers.assert_eq(TextTarget.normalize(vector.text), vector.expect, vector.id)
			end)
		end
		for _, vector in ipairs(text_corpus.find) do
			helpers.it("find " .. vector.id, function()
				local hit = TextTarget.find(vector.words, vector.target)
				if Json.is_null(vector.expect) then
					helpers.assert_nil(hit, vector.id .. " must not match")
				else
					helpers.assert_not_nil(hit, vector.id .. " must match")
					for _, key in ipairs({ "x", "y", "width", "height", "distance", "variant" }) do
						helpers.assert_eq(hit[key], vector.expect[key], vector.id .. " " .. key)
					end
				end
			end)
		end
	end)

	helpers.describe("auto-click policy vectors: " .. options.driver, function()
		for _, vector in ipairs(policy_corpus.vectors) do
			helpers.it(vector.id, function()
				local state = {}
				for key, value in pairs(policy_corpus.base) do state[key] = value end
				for key, value in pairs(vector.state) do state[key] = value end
				for key, value in pairs(state) do
					if Json.is_null(value) then state[key] = nil end
				end
				local click, reason = Policy.may_click(state)
				helpers.assert_eq(click, vector.click, vector.id .. " click")
				helpers.assert_eq(reason, vector.reason, vector.id .. " reason")
				helpers.assert_true(Policy.REASONS[reason] == reason, vector.id .. " reason is in the vocabulary")
			end)
		end
	end)
end

return M
