--- tests/unit/modules/hotstrings/engine/test_priority_publication.lua

--- ==============================================================================
--- MODULE: Committed Hotstring Priority Publication
--- DESCRIPTION:
--- Exercises the real source parser, persisted overrides, engine collisions and
--- settings bridge. Discovery is restricted to private files; lost-source,
--- writer and engine receipts remain independent of the priority transaction.
--- ==============================================================================

local helpers = require("tests.helpers")

--- Runs one isolated configuration with two colliding sources and a closed section.
--- @param body function body(Config, state)
--- @param no_engine boolean|nil Starts with preferences only.
local function with_priority(body, no_engine)
	local saved = {}
	for name, value in pairs(package.loaded) do saved[name] = value end
	local Shell = require("adapters.shell_runner")
	local directory = os.tmpname()
	os.remove(directory)
	assert(Shell.run("mkdir -p " .. Shell.quote(directory)))
	local function write(path, bytes)
		local handle = assert(io.open(path, "wb"))
		assert(handle:write(bytes)); assert(handle:close())
	end
	local function read(path)
		local handle = io.open(path, "rb")
		if not handle then return nil end
		local bytes = handle:read("*a"); handle:close(); return bytes
	end
	local first, second = directory .. "/first.toml", directory .. "/second.toml"
	local choices, overrides = directory .. "/config.toml", directory .. "/hotstrings_overrides.toml"
	local function source(output)
		return '[_meta]\nsections_order = ["main", "closed"]\n[[main]]\n'
			.. '"same" = { output = "' .. output .. '", auto_expand = true }\n'
			.. '"other' .. output .. '" = { output = "UNRELATED", auto_expand = true, priority = 23 }\n'
			.. '[[closed]]\n"disabled' .. output .. '" = { output = "CLOSED", auto_expand = true }\n'
	end
	write(first, source("FIRST")); write(second, source("SECOND"))
	write(choices, '[hotstrings]\ngroups = { first=true, second=true }\n'
		.. '[hotstrings.modules.first]\nmain=true\nclosed=false\n'
		.. '[hotstrings.modules.second]\nmain=true\nclosed=false\n')
	local Loader = require("modules.hotstrings.loader")
	local Writer = require("toml_codec.writer")
	local original_load, original_find, original_publish = Loader.load_catalogue, Loader.find_toml_files, Writer.publish_if_unchanged
	local state = { loads = 0, writes = 0, images = {}, pushes = {}, read = read, directory = directory,
		override_path = overrides, choice_path = choices }
	Loader.find_toml_files = function() return {} end
	Loader.load_catalogue = function(_, options, prepared)
		state.loads = state.loads + 1
		local paths = { first, second }
		-- Discovery can win a race with an unlink; the real reader must refuse.
		if state.source_disappeared then paths[#paths + 1] = directory .. "/missing.toml" end
		return original_load(paths, options, prepared)
	end
	Writer.publish_if_unchanged = function(...)
		state.writes = state.writes + 1
		if state.refuse_write == "throw" then error("independent writer refusal") end
		if state.refuse_write then return false end
		return original_publish(...)
	end
	local ok, failure = xpcall(function()
		local Config = dofile(helpers.driver_root() .. "/modules/hotstrings/hotstrings_config.lua")
		package.loaded["modules.hotstrings.hotstrings_config"] = Config
		Config.discover_extensions = function() return {} end
		Config.language_packs = function() return {} end
		assert(Config._set_config_file_for_test(choices))
		Config._set_override_config_dir_for_test(directory)
		local engine = require("modules.hotstrings.engine").new()
		local load = engine.load_mappings
		engine.load_mappings = function(self, mappings)
			if state.refuse_engine == "throw" then error("independent engine refusal") end
			if state.refuse_engine or state.refuse_inverse and #state.images >= 2 then return false end
			local committed = load(self, mappings)
			if committed then state.images[#state.images + 1] = mappings end
			return committed
		end
		state.engine = engine
		function state.winner()
			engine:reset()
			local result
			for char in ("same"):gmatch(".") do result = engine:on_char(char) end
			return result and result.replacement
		end
		state.config_dir = directory .. "/unused"
		assert(Config.init(not no_engine and engine or nil, state.config_dir))
		if not no_engine then assert(select(2, Config.load_all())) end
		package.loaded["ui.webview_manager"] = { current_epoch = function() return 1 end,
			eval_js = function(_, js) state.pushes[#state.pushes + 1] = js; return true end }
		package.loaded["ui.hotstrings_config_window.bridge"] = nil
		local Bridge = require("ui.hotstrings_config_window.bridge")
		function state.action(action, priority)
			return Bridge.on_message({ action = action, category = "second", priority = priority },
				{ config = Config, engine = engine }, { app_name = "hotstrings_config_window", epoch = 1 })
		end
		body(Config, state)
	end, debug.traceback)
	Loader.load_catalogue, Loader.find_toml_files, Writer.publish_if_unchanged = original_load, original_find, original_publish
	for name in pairs(package.loaded) do if saved[name] == nil then package.loaded[name] = nil end end
	for name, value in pairs(saved) do package.loaded[name] = value end
	for _, name in ipairs({ "first.toml", "second.toml", "config.toml", "hotstrings_overrides.toml" }) do
		os.remove(directory .. "/" .. name)
	end
	assert(Shell.run("rmdir " .. Shell.quote(directory)))
	if not ok then error(failure, 0) end
end

helpers.describe("hotstring priority: committed runtime publication", function()
	helpers.it("keeps the actual settings UI and collision winner coherent after a source disappears", function()
		with_priority(function(Config, state)
			helpers.assert_eq(state.winner(), "FIRST")
			state.source_disappeared = true
			helpers.assert_true(state.action("set_priority", 90))
			helpers.assert_eq(Config.resolve("second", "main").priority, 90)
			helpers.assert_eq(state.winner(), "SECOND", "displayed priority must govern the actual engine")
			helpers.assert_true(state.read(state.override_path):find("priority = 90", 1, true) ~= nil)
			helpers.assert_true(state.action("clear_priority"))
			helpers.assert_eq(Config.resolve("second", "main").priority, 10)
			helpers.assert_eq(state.winner(), "FIRST", "reset must publish the inherited priority")
			helpers.assert_eq(state.loads, 1, "a priority edit cannot re-read unrelated sources")
			helpers.assert_eq(#state.pushes, 2)
		end)
	end)

	for _, field in ipairs({ "priority", "all" }) do
		local reset = field
		helpers.it("clears " .. field .. " overrides through the exact committed engine image", function()
			with_priority(function(Config, state)
				helpers.assert_true(Config.set_override("second", nil, "delay", 0.2))
				helpers.assert_true(Config.set_override("second", nil, "priority", 90))
				state.source_disappeared = true
				helpers.assert_true(Config.clear_override("second", nil, reset == "priority" and "priority" or nil))
				helpers.assert_eq(state.winner(), "FIRST")
				helpers.assert_eq(Config.get_user_override("second", nil).delay, reset == "priority" and 0.2 or nil)
				helpers.assert_eq(state.loads, 1)
			end)
		end)
	end

	helpers.it("clones registered records and preserves exact unrelated fields and closed sections", function()
		with_priority(function(Config, state)
			local original = state.images[1]
			helpers.assert_true(Config.set_override("second", nil, "priority", 90))
			local candidate = state.images[2]
			helpers.assert_eq(#candidate, #original)
			for index, mapping in ipairs(original) do
				helpers.assert_true(candidate[index] ~= mapping, "old Engine records must never be reprioritized in place")
				for field, value in pairs(mapping) do
					if field ~= "priority" then helpers.assert_eq(candidate[index][field], value) end
				end
				if mapping.trigger == "same" then helpers.assert_eq(mapping.priority, 10) end
				if mapping.trigger:find("other", 1, true) then helpers.assert_eq(candidate[index].priority, 23) end
				helpers.assert_eq(mapping.section, "main", "closed sections cannot become active during a reorder")
			end
			helpers.assert_eq(Config.is_section_checked("second", "closed"), false)
		end)
	end)

	for _, refusal in ipairs({ "false", "throw" }) do
		local mode = refusal
		helpers.it("retains exact durable and cached state after Writer " .. refusal, function()
			with_priority(function(Config, state)
				helpers.assert_true(Config.set_override("second", nil, "priority", 80))
				local before, cached = state.read(state.override_path), Config.resolve("second", "main")
				state.refuse_write = mode
				helpers.assert_eq(Config.set_override("second", nil, "priority", 0), false)
				helpers.assert_eq(state.read(state.override_path), before)
				helpers.assert_true(Config.resolve("second", "main") == cached)
				helpers.assert_eq(state.winner(), "SECOND")
				local owner = {}
				helpers.assert_true(Config.acquire(owner)); helpers.assert_true(Config.release(owner))
			end)
		end)

		helpers.it("refuses Engine " .. refusal .. " before durable publication", function()
			with_priority(function(Config, state)
				local before, cached, writes = state.read(state.override_path), Config.resolve("second", "main"), state.writes
				state.refuse_engine = mode
				helpers.assert_eq(Config.set_override("second", nil, "priority", 90), false)
				helpers.assert_eq(state.read(state.override_path), before)
				helpers.assert_eq(state.writes, writes)
				helpers.assert_true(Config.resolve("second", "main") == cached)
				helpers.assert_eq(state.winner(), "FIRST")
				local owner = {}
				helpers.assert_true(Config.acquire(owner)); helpers.assert_true(Config.release(owner))
			end)
		end)
	end

	helpers.it("retains a refused inverse and its gate until the same Engine acknowledges it", function()
		with_priority(function(Config, state)
			state.refuse_write, state.refuse_inverse = true, true
			helpers.assert_eq(Config.set_override("second", nil, "priority", 90), false)
			helpers.assert_nil(state.read(state.override_path))
			helpers.assert_eq(Config.acquire({}), false, "unacknowledged inverse keeps its original lease")
			helpers.assert_eq(Config.set_override("first", nil, "delay", 0.3), false)
			helpers.assert_eq(Config.retry_personal_cleanup(), false)
			state.refuse_write, state.refuse_inverse = false, false
			helpers.assert_true(Config.retry_personal_cleanup())
			helpers.assert_eq(state.winner(), "FIRST")
			helpers.assert_eq(Config.get_user_override("second", nil).priority, nil)
			helpers.assert_true(Config.set_override("second", nil, "priority", 90))
			helpers.assert_eq(state.winner(), "SECOND")
		end)
	end)

	helpers.it("persists a priority without an initialized engine and applies it on later initialization", function()
		with_priority(function(Config, state)
			helpers.assert_true(Config.set_override("second", nil, "priority", 90))
			helpers.assert_eq(state.loads, 0)
			helpers.assert_true(Config.init(state.engine, state.config_dir))
			helpers.assert_true(select(2, Config.load_all()))
			helpers.assert_eq(state.winner(), "SECOND")
		end, true)
	end)
end)

return helpers
