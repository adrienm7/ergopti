--- tests/unit/modules/hotstrings/test_preview_colored_menu.lua

--- Exercises the declared coloured preview row through the real tray provider,
--- scalar preference lease and conditional TOML writer. Observations from native
--- callbacks are asserted after the callback has returned.
local helpers = require("tests.helpers")
local SOURCE = '# retained header\n[hotstrings]\npreview_colored_tooltips = true\nfuture = "kept" # retained\n'

--- Runs a body with the actual scalar owner routed to private independent bytes.
--- @param body function Receives owner, settings, private path and sandbox.
local function with_preferences(body)
	local Sandbox = require("test.config_unused_keys_contract").sandbox
	local loaded = {}; for name, value in pairs(package.loaded) do loaded[name] = value end
	local ok, err = pcall(function()
		Sandbox.with_config(SOURCE, function(path)
			local paths = {}; for key, value in pairs(require("infra.config_paths")) do paths[key] = value end
			paths.config = function() return path end
			package.loaded["infra.config_paths"] = paths
			package.loaded["infra.hotstring_preferences"] = nil
			package.loaded["modules.hotstrings.preview_settings"] = nil
			local Preferences = require("infra.hotstring_preferences")
			assert(Preferences.refresh())
			body(Preferences, require("modules.hotstrings.preview_settings"), path, Sandbox)
		end)
	end)
	for name in pairs(package.loaded) do if loaded[name] == nil then package.loaded[name] = nil end end
	for name, value in pairs(loaded) do package.loaded[name] = value end
	if not ok then error(err, 0) end
end

local function menu_controls(paused, relabel, magic_relabel, presence_options)
	local paths = require("infra.paths")
	local i18n = require("infra.i18n")
	local original = package.loaded["infra.manifest_menu"]
	local observations = { writes = 0, redraws = 0 }
	local renderer = assert(require("menu.renderer").new({
		platform = "linux",
		manifest_path = function() return paths.shared("modules/menu/menu_manifest.json") end,
		json_decode = function(raw)
			local value = assert(require("json").decode(raw))
			if relabel then value.preview_colored_control[1].i18n = "button.ok" end
			if magic_relabel and value.preview_magic_control then value.preview_magic_control[1].i18n = "button.ok" end
			if presence_options and value.preview_presence_controls then
				local rows = value.preview_presence_controls
				if presence_options.relabel then rows[1].i18n = "button.ok" end
				if presence_options.reverse then rows[1], rows[2] = rows[2], rows[1] end
			end
			return value
		end,
		i18n = i18n,
		logger = require("logger.shim"),
	}))
	package.loaded["infra.manifest_menu"] = setmetatable({
		build = function(section, ...)
			local rows = renderer.build(section, ...)
			if section == "word_expanders_menu" then observations.controls = rows end
			return rows
		end,
	}, { __index = renderer })
	local ctx = {
		paused = paused,
		config = {
			get_groups = function() return {} end,
			get_categories = function() return {} end,
			language_packs = function() return {} end,
			resolve = function() return { delay = 0.75, color = "#1e88e5", has_override = false } end,
			get_global_delay = function() return 0.75 end,
			has_global_delay_override = function() return false end,
		},

		on_menu_changed = function() observations.redraws = observations.redraws + 1 end,
		on_toggle_pause = function() end,
		on_quit = function() end,
	}
	ctx.is_paused = function() return ctx.paused end
	local passed, rows = pcall(function() return helpers.load_module("ui.menu.menu_builder").build(ctx) end)
	package.loaded["infra.manifest_menu"] = original
	if not passed then error(rows, 0) end
	local function find(items)
		for _, row in ipairs(items or {}) do
			if row.title == i18n.get("menu.hotstrings.preview_bubbles") then return row.menu end
			local found = find(row.menu); if found then return found end
		end
	end
	return assert(find(rows), "the real preview provider must be present"), ctx, observations
end



helpers.describe("declared coloured preview native row", function()
	helpers.it("uses the shared label and keeps the three presence rows plus separator", function()
		with_preferences(function(_, _, _, _)
			local rows = menu_controls(false, true)
			local i18n = require("infra.i18n")
			helpers.assert_eq(#rows, 5)
			for index, label in ipairs({ "tooltip_magic", "tooltip_autocorrect", "tooltip_ai" }) do
				helpers.assert_eq(rows[index].title, i18n.get("menu.hotstrings." .. label))
			end
			helpers.assert_eq(rows[4].title, "-")
			helpers.assert_eq(rows[5].title, i18n.get("button.ok"))
			helpers.assert_eq(rows[5].checked, true)
		end)
	end)
	helpers.it("does not refresh or change physical data while the durable lease refuses", function()
		with_preferences(function(Preferences, Settings, path, sandbox)
			local owner = {}; assert(Preferences.acquire(owner))
			local rows, _, observations = menu_controls(false)
			local outcome = rows[5].fn()
			assert(Preferences.release(owner))
			helpers.assert_eq(outcome, false)
			helpers.assert_eq(observations.redraws, 0)
			helpers.assert_eq(Settings.get("colored"), true)
			helpers.assert_eq(sandbox.read_bytes(path), SOURCE)
		end)
	end)
	for _, mode in ipairs({ "false", "throw" }) do
		helpers.it("retains the source and redraw posture after writer " .. mode, function()
			with_preferences(function(_, Settings, path, sandbox)
				local Writer = require("toml_codec.writer"); local original = Writer.batch_write
				Writer.batch_write = function() if mode == "throw" then error("injected refusal", 0) end; return false end
				local outcome, observed
				local ok, err = pcall(function()
					local rows, _, observations = menu_controls(false)
					local entered, result = pcall(rows[5].fn); outcome = entered and result or false; observed = observations.redraws
				end)
				Writer.batch_write = original
				if not ok then error(err, 0) end
				helpers.assert_eq(outcome, false)
				helpers.assert_eq(observed, 0)
				helpers.assert_eq(Settings.get("colored"), true)
				helpers.assert_eq(sandbox.read_bytes(path), SOURCE)
			end)
		end)
	end
	helpers.it("retains existing paused configuration access and refreshes only after actual durable ACK", function()
		with_preferences(function(Preferences, Settings, path, sandbox)
			local rows, ctx, observations = menu_controls(false)
			ctx.paused = true
			helpers.assert_eq(rows[5].fn(), true)
			helpers.assert_eq(observations.redraws, 1)
			helpers.assert_eq(Settings.get("colored"), false)
			assert(Preferences.refresh())
			helpers.assert_eq(Settings.get("colored"), false)
			helpers.assert_true(sandbox.read_bytes(path):find('future = "kept" # retained', 1, true) ~= nil)
		end)
	end)
end)


helpers.describe("coloured provider locale contract", function()
	helpers.it("uses all twenty-one actual catalogues without disturbing provider order", function()
		with_preferences(function(_, _, _, _)
			local i18n = require("infra.i18n")
			local observed = {}
			local ok, err = pcall(function()
				for _, code in ipairs({ "ar", "cs", "da", "de", "en", "es", "fr", "he", "hi", "it", "ja", "ko", "nl", "no", "pl", "pt", "ru", "sv", "tr", "uk", "zh" }) do
					local path = require("infra.paths").shared("data/locales/" .. code .. ".json")
					local file = assert(io.open(path, "rb")); local raw = file:read("*a"); file:close()
					local catalog = assert(require("json").decode(raw))
					local translated = {}; for key, value in pairs(i18n) do translated[key] = value end
					translated.get = function(key) return catalog[key] or key end
					package.loaded["infra.i18n"] = translated
					local rows = menu_controls(false)
					observed[#observed + 1] = { rows = rows, expected = catalog["menu.hotstrings.tooltip_colored"] }
				end
			end)
			package.loaded["infra.i18n"] = i18n
			if not ok then error(err, 0) end
			helpers.assert_eq(package.loaded["infra.i18n"], i18n)
			helpers.assert_eq(#observed, 21)
			for _, item in ipairs(observed) do
				helpers.assert_eq(#item.rows, 5)
				helpers.assert_eq(item.rows[4].title, "-")
				helpers.assert_eq(item.rows[5].title, item.expected)
				helpers.assert_eq(item.rows[5].checked, true)
			end
		end)
	end)
end)


helpers.describe("declared magic preview native row", function()
	helpers.it("does not redraw or acknowledge while the real scalar lease refuses", function()
		with_preferences(function(Preferences, Settings, path, sandbox)
			local lease = {}; assert(Preferences.acquire(lease))
			local rows, _, observations = menu_controls(false)
			local outcome = rows[1].fn()
			assert(Preferences.release(lease))
			helpers.assert_eq(outcome, false)
			helpers.assert_eq(observations.redraws, 0)
			helpers.assert_eq(Settings.get("star"), false)
			helpers.assert_eq(sandbox.read_bytes(path), SOURCE)
		end)
	end)
	for _, mode in ipairs({ "false", "throw" }) do
		helpers.it("retains magic physical source after actual writer " .. mode, function()
			with_preferences(function(_, Settings, path, sandbox)
				local Writer = require("toml_codec.writer"); local original = Writer.batch_write
				Writer.batch_write = function() if mode == "throw" then error("injected refusal", 0) end; return false end
				local outcome, redraws
				local passed, err = pcall(function()
					local rows, _, observations = menu_controls(false)
					local entered, result = pcall(rows[1].fn); outcome = entered and result or false; redraws = observations.redraws
				end)
				Writer.batch_write = original
				if not passed then error(err, 0) end
				helpers.assert_eq(outcome, false)
				helpers.assert_eq(redraws, 0)
				helpers.assert_eq(Settings.get("star"), false)
				helpers.assert_eq(sandbox.read_bytes(path), SOURCE)
			end)
		end)
	end
	helpers.it("returns the real ACK and reloads only its own preference while paused", function()
		with_preferences(function(Preferences, Settings, path, sandbox)
			local rows, ctx, observations = menu_controls(false)
			ctx.paused = true
			helpers.assert_eq(rows[1].fn(), true)
			helpers.assert_eq(observations.redraws, 1)
			helpers.assert_eq(Settings.get("star"), true)
			assert(Preferences.refresh())
			helpers.assert_eq(Settings.get("star"), true)
			helpers.assert_eq(Settings.get("colored"), true)
			helpers.assert_true(sandbox.read_bytes(path):find('future = "kept" # retained', 1, true) ~= nil)
		end)
	end)
end)


helpers.describe("magic provider locale contract", function()
	helpers.it("consumes the declaration label while keeping separator and colored siblings", function()
		with_preferences(function()
			local rows = menu_controls(false, false, true)
			local i18n = require("infra.i18n")
			helpers.assert_eq(#rows, 5)
			helpers.assert_eq(rows[1].title, i18n.get("button.ok"))
			helpers.assert_eq(rows[2].title, i18n.get("menu.hotstrings.tooltip_autocorrect"))
			helpers.assert_eq(rows[3].title, i18n.get("menu.hotstrings.tooltip_ai"))
			helpers.assert_eq(rows[4].title, "-")
			helpers.assert_eq(rows[5].title, i18n.get("menu.hotstrings.tooltip_colored"))
		end)
	end)
	helpers.it("uses all twenty-one real catalogues for the magic checkbox", function()
		with_preferences(function()
			local i18n = require("infra.i18n")
			local file = assert(io.open(require("infra.paths").shared("tests/corpus/menus/preview_magic_control.json"), "rb"))
			local raw = file:read("*a"); file:close()
			local corpus = assert(require("json").decode(raw))
			local observations = {}
			local passed, err = pcall(function()
				for _, code in ipairs(corpus.locales) do
					local locale = assert(io.open(require("infra.paths").shared("data/locales/" .. code .. ".json"), "rb"))
					local text = locale:read("*a"); locale:close()
					local catalog = assert(require("json").decode(text))
					local translated = {}; for key, value in pairs(i18n) do translated[key] = value end
					translated.get = function(key) return catalog[key] or key end
					package.loaded["infra.i18n"] = translated
					observations[#observations + 1] = { rows = menu_controls(false), label = catalog[corpus.row.i18n] }
				end
			end)
			package.loaded["infra.i18n"] = i18n
			if not passed then error(err, 0) end
			helpers.assert_eq(package.loaded["infra.i18n"], i18n)
			helpers.assert_eq(#observations, 21)
			for _, observation in ipairs(observations) do
				helpers.assert_eq(observation.rows[1].title, observation.label)
				helpers.assert_eq(observation.rows[4].title, "-")
				helpers.assert_eq(#observation.rows, 5)
			end
		end)
	end)
end)


helpers.describe("magic preview exact receipt boundary", function()
	helpers.it("refuses nil and truthy nonboolean callback receipts without publishing refresh", function()
		with_preferences(function(_, Settings, path, sandbox)
			local original = Settings.toggle
			local observations = {}
			local passed, err = pcall(function()
				for _, kind in ipairs({ "nil", "number" }) do
					Settings.toggle = function(name)
						if name ~= "star" then return original(name) end
						if kind == "nil" then return nil end
						return 2
					end
					local rows, _, calls = menu_controls(false)
					local entered, result = pcall(rows[1].fn)
					observations[#observations + 1] = { entered = entered, result = result, redraws = calls.redraws }
				end
			end)
			Settings.toggle = original
			if not passed then error(err, 0) end
			helpers.assert_eq(Settings.toggle, original)
			helpers.assert_eq(#observations, 2)
			for _, observation in ipairs(observations) do
				helpers.assert_eq(observation.entered, true)
				helpers.assert_eq(observation.result, false)
				helpers.assert_eq(observation.redraws, 0)
			end
			helpers.assert_eq(Settings.get("star"), false)
			helpers.assert_eq(sandbox.read_bytes(path), SOURCE)
		end)
	end)
end)


helpers.describe("declared autocorrection and AI presence receipt", function()
	for _, name in ipairs({ "autocorrect", "ai" }) do
		local position = name == "autocorrect" and 2 or 3
		helpers.it("retains the actual lease and source while " .. name .. " is refused", function()
			with_preferences(function(Preferences, Settings, path, sandbox)
				local lease = {}; assert(Preferences.acquire(lease))
				local rows, _, observations = menu_controls(false)
				local outcome = rows[position].fn()
				assert(Preferences.release(lease))
				helpers.assert_eq(outcome, false)
				helpers.assert_eq(observations.redraws, 0)
				helpers.assert_eq(Settings.get(name), false)
				helpers.assert_eq(sandbox.read_bytes(path), SOURCE)
			end)
		end)
		for _, mode in ipairs({ "false", "throw" }) do
			helpers.it("retains physical " .. name .. " after writer " .. mode, function()
				with_preferences(function(_, Settings, path, sandbox)
					local Writer = require("toml_codec.writer"); local original = Writer.batch_write
					Writer.batch_write = function() if mode == "throw" then error("injected refusal", 0) end; return false end
					local result, redraws
					local passed, err = pcall(function()
						local rows, _, observed = menu_controls(false)
						local entered, receipt = pcall(rows[position].fn); result = entered and receipt or false; redraws = observed.redraws
					end)
					Writer.batch_write = original
					if not passed then error(err, 0) end
					helpers.assert_eq(result, false)
					helpers.assert_eq(redraws, 0)
					helpers.assert_eq(Settings.get(name), false)
					helpers.assert_eq(sandbox.read_bytes(path), SOURCE)
				end)
			end)
		end
		helpers.it("requires exact true rather than nil or a truthy number for " .. name, function()
			with_preferences(function(_, Settings, path, sandbox)
				local original = Settings.toggle; local observations = {}
				local passed, err = pcall(function()
					for _, mode in ipairs({ "nil", "number" }) do
						Settings.toggle = function(candidate)
							if candidate ~= name then return original(candidate) end
							if mode == "nil" then return nil end
							return 2
						end
						local rows, _, observed = menu_controls(false)
						local entered, receipt = pcall(rows[position].fn)
						observations[#observations + 1] = { entered = entered, receipt = receipt, redraws = observed.redraws }
					end
				end)
				Settings.toggle = original
				if not passed then error(err, 0) end
				helpers.assert_eq(Settings.toggle, original)
				helpers.assert_eq(#observations, 2)
				for _, observed in ipairs(observations) do
					helpers.assert_eq(observed.entered, true)
					helpers.assert_eq(observed.receipt, false)
					helpers.assert_eq(observed.redraws, 0)
				end
				helpers.assert_eq(sandbox.read_bytes(path), SOURCE)
			end)
		end)
		helpers.it("acknowledges, redraws and reloads only " .. name .. " while configuration is paused", function()
			with_preferences(function(Preferences, Settings, path, sandbox)
				local rows, ctx, observed = menu_controls(false); ctx.paused = true
				helpers.assert_eq(rows[position].fn(), true)
				helpers.assert_eq(observed.redraws, 1)
				assert(Preferences.refresh())
				helpers.assert_eq(Settings.get(name), true)
				local neighbour = name == "ai" and "autocorrect" or "ai"
				helpers.assert_eq(Settings.get(neighbour), false)
				helpers.assert_eq(Settings.get("colored"), true)
				helpers.assert_true(sandbox.read_bytes(path):find('future = "kept" # retained', 1, true) ~= nil)
			end)
		end)
	end
end)


helpers.describe("ordered presence provider locale contract", function()
	helpers.it("uses all twenty-one actual catalogues in canonical and reversed declaration order", function()
		with_preferences(function()
			local i18n = require("infra.i18n")
			local function read_json(path)
				local file = assert(io.open(path, "rb")); local text = file:read("*a"); file:close()
				return assert(require("json").decode(text))
			end
			local Paths = require("infra.paths")
			local corpus = read_json(Paths.shared("tests/corpus/menus/preview_presence_controls.json"))
			local observations = {}
			local passed, err = pcall(function()
				for _, code in ipairs(corpus.locales) do
					local catalog = read_json(Paths.shared("data/locales/" .. code .. ".json"))
					local translated = {}; for key, value in pairs(i18n) do translated[key] = value end
					translated.get = function(key) return catalog[key] or key end
					package.loaded["infra.i18n"] = translated
					for _, reverse in ipairs({ false, true }) do
						observations[#observations + 1] = { rows = menu_controls(false, false, false, { reverse = reverse }), catalog = catalog, reverse = reverse }
					end
				end
			end)
			package.loaded["infra.i18n"] = i18n
			if not passed then error(err, 0) end
			helpers.assert_eq(package.loaded["infra.i18n"], i18n)
			helpers.assert_eq(#observations, 42)
			for _, observation in ipairs(observations) do
				helpers.assert_eq(#observation.rows, 5)
				for index, expected in ipairs(corpus.rows) do
					local position = observation.reverse and (4 - index) or (index + 1)
					helpers.assert_eq(observation.rows[position].title, observation.catalog[expected.i18n])
					helpers.assert_eq(observation.rows[position].checked, false)
				end
				helpers.assert_eq(observation.rows[4].title, "-")
				helpers.assert_eq(observation.rows[1].title, observation.catalog["menu.hotstrings.tooltip_magic"])
				helpers.assert_eq(observation.rows[5].title, observation.catalog["menu.hotstrings.tooltip_colored"])
			end
		end)
	end)
	helpers.it("consumes the current declaration label rather than a cached native caption", function()
		with_preferences(function()
			local rows = menu_controls(false, false, false, { relabel = true })
			helpers.assert_eq(rows[2].title, require("infra.i18n").get("button.ok"))
			helpers.assert_eq(rows[3].title, require("infra.i18n").get("menu.hotstrings.tooltip_ai"))
		end)
	end)
end)
