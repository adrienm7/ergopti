--- tests/unit/modules/hotstrings/menu/test_category_submenu_extension_gates_one.lua

--- ==============================================================================
--- MODULE: Category Submenus
--- DESCRIPTION:
--- What a hotstring category looks like in the tray, and what its rows do.
---
--- WHY THIS IS ROUGHLY FOUR FIFTHS OF THE MENU:
--- On the other two drivers a category is a submenu: a gate, a way to open its
--- file, and a checkbox per section with the number of entries behind it. On
--- Linux it was ONE line showing the file's own stem with a tick — so the
--- sections, the counts, the localised name and the file were all unreachable,
--- and the menu's category half was the part that did not exist rather than the
--- part that was untranslated.
---
--- WHAT THE COUNTS ARE FOR:
--- A section with three entries and one with nine hundred are the same row
--- without them, and the second is the one a user disables when autocorrection
--- fights them.
---
--- WHY DISABLED AND NOT HIDDEN:
--- Sections under a switched-off category are greyed. A row that disappears
--- reads as a bug, and the user still needs to see what they get back when they
--- switch the category on.
--- ==============================================================================

package.loaded["tests.support.modules.hotstrings.menu.category_submenu_fixture"] = nil
local Fixture = require("tests.support.modules.hotstrings.menu.category_submenu_fixture")
local helpers, fake_config =
	Fixture.helpers, Fixture.fake_config




helpers.describe("extension category gates: one acknowledged batch", function()
	local function gate_action(config, enabled, changed)
		local mb = helpers.load_module("ui.menu.menu_builder")
		local label = require("infra.i18n").get(enabled and "menu.hotstrings.check_all" or "menu.hotstrings.uncheck_all")
		local extension = string.format(require("infra.i18n").get("menu.extensions.hotstrings_of"), "Ergopti")
		local found
		local function find(rows)
			for _, row in ipairs(rows or {}) do
				if row.title == extension then found = row end
				if type(row.menu) == "table" then find(row.menu) end
			end
		end
		find(mb.build({ config = config, _version = "9.9.9", on_menu_changed = changed }))
		assert(found, "the native owning extension submenu is present")
		for _, row in ipairs(found.menu or {}) do if row.title == label then return row.fn end end
		error("the native extension gate command was not rendered")
	end
	local function observe_click(action)
		local execute, modal = os.execute, require("ui.modal")
		local run, notices, releases = modal.run, {}, 0
		modal.run = function(callback) releases = releases + 1; return callback() end
		os.execute = function(command)
			if command:find("zenity", 1, true) then notices[#notices + 1] = command; return 0 end
			return execute(command)
		end
		local called, result = pcall(action)
		os.execute, modal.run = execute, run
		return called, result, notices, releases
	end
	local function with_real_gate_owner(initial, body)
		local directory = os.tmpname()
		assert(os.remove(directory))
		directory = directory .. "-ergopti-gate-batch"
		local quote = require("adapters.shell_runner").quote
		assert(require("adapters.shell_runner").run("mkdir -p " .. quote(directory)) == true)
		local path = directory .. "/config.toml"
		local state = initial and "true" or "false"
		local sections = '[hotstrings.modules.rolls]\nhc = true\nsx = false\n[hotstrings.modules.sfbsreduction]\ncomma = true\n[hotstrings.modules.foreign]\nfx = true\n'
		local foreign = '[future]\nlabel = "kept" # independent foreign comment\nnested = { flag = true, values = ["a", "b"] }\n'
		local original = '# independently written future preferences\n[hotstrings]\ngroups = { rolls = '
			.. state .. ', sfbsreduction = ' .. state .. ', foreign = true }\n' .. sections .. foreign
		local fh = assert(io.open(path, "wb"));assert(fh:write(original));assert(fh:close())
		local loaded = {}
		for name, value in pairs(package.loaded) do loaded[name] = value end
		local Terminators = require("modules.hotstrings.terminator_settings")
		local catalogue = Terminators.snapshot()
		local ok, err = pcall(function()
			package.loaded["modules.hotstrings.hotstrings_config"] = nil
			package.loaded["modules.hotstrings.loader"] = nil
			local paths = {}
			for key, value in pairs(require("infra.paths")) do paths[key] = value end
			-- The private fixture has no external installed layout roots.
			paths.extension_roots = function() return {} end
			package.loaded["infra.paths"] = paths
			local loader = require("modules.hotstrings.loader")
			local native_find = loader.find_toml_files
			package.loaded["modules.hotstrings.loader"] = {
				find_toml_files = native_find, list_subdirs = function() return {} end,
				read_file = function() return nil end,
				load_catalogue = function()
					return { committed = true, errors = 0, categories = {
						rolls = { id = "rolls", path = directory .. "/rolls.toml", count = 1,
							description = { en = "Rolls", fr = "Roulements" },
							extension = { id = "ergopti", name = "Ergopti" },
							sections_order = { "hc", "sx" }, sections = { hc = { count = 1 }, sx = { count = 0 } } },
						sfbsreduction = { id = "sfbsreduction", path = directory .. "/sfbs.toml", count = 1,
							description = { en = "SFB", fr = "SFB" }, extension = { id = "ergopti", name = "Ergopti" },
							sections_order = { "comma" }, sections = { comma = { count = 1 } } },
						foreign = { id = "foreign", path = directory .. "/foreign.toml", count = 1,
							description = { en = "Foreign", fr = "Foreign" },
							sections_order = { "fx" }, sections = { fx = { count = 1 } } },
					}, mappings = {
						{ trigger = "hq", replacement = "section-result", group = "rolls", section = "hc", auto_expand = true },
						{ trigger = "qw", replacement = "sfbs-result", group = "sfbsreduction", section = "comma", auto_expand = true },
						{ trigger = "xy", replacement = "foreign-result", group = "foreign", section = "fx", auto_expand = true },
					} }
				end,
			}
			local config, engine = require("modules.hotstrings.hotstrings_config"), require("hotstring_engine").new()
			local changed = 0
			assert(config._set_config_file_for_test(path))
			assert(config.init(engine, directory, function() changed = changed + 1 end))
			local _, loaded = config.load_all();assert(loaded)
			body({ config = config, engine = engine, path = path, original = original,
				changed = function() return changed end, sections = sections, foreign = foreign })
		end)
		local restored = Terminators.restore_configuration(catalogue)
		for name in pairs(package.loaded) do if loaded[name] == nil then package.loaded[name] = nil end end
		for name, value in pairs(loaded) do package.loaded[name] = value end
		local removed = require("adapters.shell_runner").run("rm -rf " .. quote(directory))
		assert(restored, "the exact delimiter catalogue is restored")
		assert(removed == true, "the owned private fixture is retired")
		if not ok then error(err, 0) end
	end
	local function read(path)
		local fh = assert(io.open(path, "rb"));local data = fh:read("*a");assert(fh:close());return data
	end
	local function fires(engine, trigger, replacement)
		engine:reset();engine:on_char(trigger:sub(1, 1));local result = engine:on_char(trigger:sub(2, 2))
		return result ~= nil and result.replacement == replacement
	end

	for _, outcome in ipairs({ "true", "false", "nil", "number", "text", "throw", "missing" }) do
		helpers.it("requires the exact extension gate batch receipt " .. outcome, function()
			local config = fake_config({})
			local asked, toggles, redraws = {}, 0, 0
			config.toggle_group = function() toggles = toggles + 1; return true end
			if outcome ~= "missing" then config.set_extension_sections_enabled = function(ids, bound, enabled)
				helpers.assert_eq(bound, {}, "the gate-only fixture has no bound sections")
				asked[#asked + 1] = { ids = ids, enabled = enabled }
				if outcome == "throw" then error("inert batch owner refusal") end
				if outcome == "nil" then return nil end
				if outcome == "number" then return 2 end
				if outcome == "text" then return "true" end
				return outcome == "true"
			end end
			local called, result, notices, released = observe_click(gate_action(config, false, function() redraws = redraws + 1 end))
			helpers.assert_true(called)
			helpers.assert_eq(toggles, 0, "the native command never commits one pack at a time")
			helpers.assert_eq(asked, outcome == "missing" and {} or { { ids = { "rolls" }, enabled = false } })
			helpers.assert_eq(#notices, outcome == "true" and 0 or 1)
			helpers.assert_eq(result, outcome == "true")
			helpers.assert_eq(redraws, outcome == "true" and 1 or 0)
			helpers.assert_eq(released, #notices)
		end)
	end
	for _, enabled in ipairs({ true, false }) do
		helpers.it("publishes both extension gates once with no partial second-failure state " .. tostring(enabled), function()
			with_real_gate_owner(not enabled, function(c)
				local rename, attempts, redraws = os.rename, 0, 0
				os.rename = function(from, to)
					if from == c.path .. ".tmp" and to == c.path then
						attempts = attempts + 1
						if attempts == 2 then return false, "inert second publication refusal" end
					end
					return rename(from, to)
				end
				local called, result, notices = observe_click(gate_action(c.config, enabled, function() redraws = redraws + 1 end))
				os.rename = rename
				helpers.assert_true(called)
				helpers.assert_eq(c.config.is_group_enabled("rolls"), enabled, "both captured categories must commit together; writes=" .. attempts .. ", rolls=" .. tostring(c.config.is_group_enabled("rolls")) .. ", sfbs=" .. tostring(c.config.is_group_enabled("sfbsreduction")))
				helpers.assert_eq(c.config.is_group_enabled("sfbsreduction"), enabled, "a refused second write cannot leave a mixed extension state")
				helpers.assert_eq(fires(c.engine, "hq", "section-result"), enabled)
				helpers.assert_eq(fires(c.engine, "qw", "sfbs-result"), enabled)
				helpers.assert_eq(attempts, 1, "one actual canonical publication commits the whole extension")
				helpers.assert_eq(result, true)
				helpers.assert_eq(c.changed(), 1)
				helpers.assert_eq(redraws, 1)
				helpers.assert_eq(#notices, 0)
				local source = read(c.path)
				helpers.assert_true(source:find(c.sections, 1, true) ~= nil, "every individual section choice remains byte-identical")
				helpers.assert_true(source:find(c.foreign, 1, true) ~= nil, "independent future records, comments and nested values survive")
				helpers.assert_true(c.config.is_group_enabled("foreign"))
				helpers.assert_true(fires(c.engine, "xy", "foreign-result"))
				helpers.assert_true(c.config.refresh_choices(), "the real owner reloads both gates from the committed file")
				helpers.assert_eq(c.config.is_group_enabled("rolls"), enabled)
				helpers.assert_eq(c.config.is_group_enabled("sfbsreduction"), enabled)
				helpers.assert_eq(c.config.is_section_checked("rolls", "sx"), false)
			end)
		end)
		for _, outcome in ipairs({ "false", "nil", "number", "throw" }) do
			helpers.it("compensates the actual extension gate batch refusal " .. outcome .. " " .. tostring(enabled), function()
				with_real_gate_owner(not enabled, function(c)
					local rename, attempts, redraws = os.rename, 0, 0
					os.rename = function(from, to)
						if from == c.path .. ".tmp" and to == c.path then
							attempts = attempts + 1
							if outcome == "throw" then error("inert batch publication refusal") end
							if outcome == "nil" then return nil, "inert batch publication refusal" end
							if outcome == "number" then return 2 end
							return false, "inert batch publication refusal"
						end
						return rename(from, to)
					end
					local called, result, notices, released = observe_click(gate_action(c.config, enabled, function() redraws = redraws + 1 end))
					os.rename = rename
					helpers.assert_true(called)
					helpers.assert_eq(attempts, 1)
					helpers.assert_eq(read(c.path), c.original, "the entire original source survives refused atomic publication")
					helpers.assert_eq(c.config.is_group_enabled("rolls"), not enabled)
					helpers.assert_eq(c.config.is_group_enabled("sfbsreduction"), not enabled)
					helpers.assert_eq(fires(c.engine, "hq", "section-result"), not enabled)
					helpers.assert_eq(fires(c.engine, "qw", "sfbs-result"), not enabled)
					helpers.assert_true(fires(c.engine, "xy", "foreign-result"))
					helpers.assert_eq(c.changed(), 0)
					helpers.assert_eq(redraws, 0, "refusal cannot publish an optimistic repaint")
					helpers.assert_eq(#notices, 1)
					helpers.assert_eq(released, 1)
					helpers.assert_eq(result, false)
				end)
			end)
		end
	end
	for _, request in ipairs({
		{ name = "unknown", targets = { "rolls", "absent" }, enabled = true },
		{ name = "duplicate", targets = { "rolls", "rolls" }, enabled = true },
		{ name = "sparse", targets = { [2] = "rolls" }, enabled = true },
		{ name = "empty", targets = {}, enabled = true },
		{ name = "nonboolean", targets = { "rolls" }, enabled = 2 },
	}) do
		helpers.it("refuses an invalid actual gate scope before effects " .. request.name, function()
			with_real_gate_owner(true, function(c)
				local result = c.config.set_category_gates_enabled(request.targets, request.enabled)
				helpers.assert_eq(result, false)
				helpers.assert_eq(c.changed(), 0)
				helpers.assert_eq(read(c.path), c.original)
				helpers.assert_true(fires(c.engine, "hq", "section-result"))
				helpers.assert_true(fires(c.engine, "qw", "sfbs-result"))
			end)
		end)
	end
	helpers.it("keeps a real pending configuration scope as the only mutation owner", function()
		with_real_gate_owner(true, function(c)
			local owner = {}
			helpers.assert_true(c.config.acquire(owner))
			local redraws = 0
			local called, result, notices = observe_click(gate_action(c.config, false, function() redraws = redraws + 1 end))
			local released = c.config.release(owner)
			helpers.assert_true(released)
			helpers.assert_true(called)
			helpers.assert_eq(result, false)
			helpers.assert_eq(redraws, 0)
			helpers.assert_eq(c.changed(), 0)
			helpers.assert_eq(read(c.path), c.original)
			helpers.assert_true(fires(c.engine, "hq", "section-result"))
			helpers.assert_true(fires(c.engine, "qw", "sfbs-result"))
			helpers.assert_eq(#notices, 1)
		end)
	end)

end)




helpers.describe("hotstring delay rows: durable owner acknowledgement", function()
	local function delay_action(config, kind, changed)
		local builder = helpers.load_module("ui.menu.menu_builder")
		local ctx = { config = config, _version = "9.9.9", paused = false, on_menu_changed = changed }
		local key = kind == "global" and "menu.hotstrings.tooltip_default" or "menu.hotstrings.delay_magic_key"
		local title = require("infra.i18n").get(key) .. " : "
		local found
		local function find(rows)
			for _, row in ipairs(rows or {}) do
				if type(row.title) == "string" and row.title:sub(1, #title) == title then found = row.fn end
				if row.menu then find(row.menu) end
			end
		end
		find(builder.build(ctx))
		assert(type(found) == "function", "the actual translated delay provider row is present")
		return found
	end
	local function observe(action, answer, before_return)
		local prompt, modal = require("ui.text_prompt"), require("ui.modal")
		local ask, run, execute = prompt.ask, modal.run, os.execute
		local asks, notices, releases = {}, {}, 0
		prompt.ask = function(...)
			asks[#asks + 1] = { ... }
			if before_return then before_return() end
			return answer
		end
		modal.run = function(callback) releases = releases + 1;return callback() end
		os.execute = function(command)
			if command:find("zenity", 1, true) then notices[#notices + 1] = command;return 0 end
			return execute(command)
		end
		local called, result = pcall(action)
		prompt.ask, modal.run, os.execute = ask, run, execute
		assert(prompt.ask == ask and modal.run == run and os.execute == execute, "every held modal transport is restored before assertions")
		return called, result, asks, notices, releases
	end
	local function receipt_config(kind, outcome)
		local calls = {}
		local function setter(...)
			calls[#calls + 1] = { n = select("#", ...), ... }
			if outcome == "throw" then error("inert durable delay refusal") end
			if outcome == "nil" then return nil end
			if outcome == "number" then return 2 end
			if outcome == "text" then return "true" end
			return outcome == "true"
		end
		local config = fake_config({})
		config.get_global_delay = function() return 0.4 end
		config.resolve = function() return { delay = 0.3 } end
		if outcome ~= "missing" then
			if kind == "global" then config.set_global_delay = setter else config.set_override = setter end
		end
		return config, calls
	end
	for _, kind in ipairs({ "global", "category" }) do
		for _, outcome in ipairs({ "true", "false", "nil", "number", "text", "throw", "missing" }) do
			helpers.it(kind .. " delay contains exact native setter receipt " .. outcome, function()
				local config, calls = receipt_config(kind, outcome)
				local changed = 0
				local called, result, asks, notices, releases = observe(delay_action(config, kind,
					function() changed = changed + 1 end), "900")
				helpers.assert_true(called, "the actual provider contains a native setter refusal")
				helpers.assert_eq(result, outcome == "true", "only the durable boolean true acknowledges the click")
				helpers.assert_eq(changed, outcome == "true" and 1 or 0, "refusal cannot repaint a success")
				helpers.assert_eq(#asks, 1)
				helpers.assert_eq(asks[1][3], kind == "global" and "400" or "300", "the existing milliseconds prompt remains intact")
				helpers.assert_eq(#calls, outcome == "missing" and 0 or 1)
				if #calls > 0 then
					helpers.assert_eq(calls[1].n, kind == "global" and 1 or 4)
					helpers.assert_eq(calls[1][kind == "global" and 1 or 4], 0.9)
					if kind == "category" then
						helpers.assert_eq(calls[1][1], "magickey");helpers.assert_eq(calls[1][2], nil);helpers.assert_eq(calls[1][3], "delay")
					end
				end
				helpers.assert_eq(#notices, outcome == "true" and 0 or 1)
				helpers.assert_eq(releases, #notices)
				if #notices > 0 then
					helpers.assert_true(notices[1]:find(require("adapters.shell_runner").quote(
						require("infra.i18n").get("dialog.bulk_toggle.save_failed")), 1, true) ~= nil)
				end
			end)
		end
		for _, raw in ipairs({ "cancel", "-1", "1.5", "not a delay" }) do
			helpers.it(kind .. " delay preserves cancellation and invalid input " .. raw, function()
				local config, calls = receipt_config(kind, "true")
				local changed = 0
				local answer = raw
				if raw == "cancel" then answer = nil end
				local called, result, asks, notices = observe(delay_action(config, kind,
					function() changed = changed + 1 end), answer)
				helpers.assert_true(called);helpers.assert_eq(result, nil)
				helpers.assert_eq(#calls, 0);helpers.assert_eq(changed, 0);helpers.assert_eq(#asks, 1)
				helpers.assert_eq(#notices, raw == "cancel" and 0 or 1)
			end)
		end
	end

	local function read(path)
		local file = assert(io.open(path, "rb"));local content = file:read("*a");assert(file:close());return content
	end
	local function write(path, content)
		local file = assert(io.open(path, "wb"));assert(file:write(content));assert(file:close())
	end
	local function with_native_owner(body)
		local directory = os.tmpname();assert(os.remove(directory));directory = directory .. "-ergopti-delay-ack"
		local quote = require("adapters.shell_runner").quote
		assert(require("adapters.shell_runner").run("mkdir -p " .. quote(directory)) == true)
		local path, config_path = directory .. "/hotstrings_overrides.toml", directory .. "/config.toml"
		local foreign = '[future]\nlabel = "independent" # unrelated future comment\nnested = { values = [2, 7], on = true }\n'
		local original = '# hand-written delay preferences\n[_global]\ndelay = 0.4\n[magickey]\ndelay = 0.3\n' .. foreign
		write(path, original);write(config_path, '[future]\nuser = "kept"\n')
		local loaded = {};for name, value in pairs(package.loaded) do loaded[name] = value end
		local called, err = pcall(function()
			package.loaded["modules.hotstrings.hotstrings_config"] = nil
			local config = require("modules.hotstrings.hotstrings_config")
			assert(config._set_config_file_for_test(config_path))
			assert(config._set_override_config_dir_for_test(directory))
			assert(config.init(require("hotstring_engine").new(), directory))
			config._set_categories_for_test({ magickey = { delay = 0.3 } })
			body({ config = config, path = path, config_path = config_path, original = original, foreign = foreign })
		end)
		for name in pairs(package.loaded) do if loaded[name] == nil then package.loaded[name] = nil end end
		for name, value in pairs(loaded) do package.loaded[name] = value end
		local removed = require("adapters.shell_runner").run("rm -rf " .. quote(directory))
		assert(removed == true, "only the owned private directory is retired")
		if not called then error(err, 0) end
	end
	for _, kind in ipairs({ "global", "category" }) do
		for _, outcome in ipairs({ "false", "nil", "number", "throw" }) do
			helpers.it(kind .. " delay actual override refusal preserves source and permits an acknowledged retry " .. outcome, function()
				with_native_owner(function(c)
					local changed = 0
					local action = delay_action(c.config, kind, function() changed = changed + 1 end)
					local rename, writes = os.rename, 0
					os.rename = function(from, to)
						if from == c.path .. ".tmp" and to == c.path then
							writes = writes + 1
							if outcome == "throw" then error("inert owned delay publication refusal") end
							if outcome == "nil" then return nil, "inert refusal" end
							if outcome == "number" then return 2 end
							return false, "inert refusal"
						end
						return rename(from, to)
					end
					local called, result, asks, notices, releases = observe(action, "900")
					os.rename = rename
					print(string.format("DELAY_REFUSAL kind=%s outcome=%s called=%s result=%s refresh=%d writes=%d source_same=%s",
						kind, outcome, tostring(called), tostring(result), changed, writes, tostring(read(c.path) == c.original)))
					helpers.assert_eq(changed, 0, "a refused actual override publication cannot refresh the menu")
					helpers.assert_true(called);helpers.assert_eq(result, false)
					helpers.assert_eq(writes, 1, "the actual leaf writer attempted precisely its owned publication")
					helpers.assert_eq(changed, 0);helpers.assert_eq(read(c.path), c.original)
					helpers.assert_eq(c.config.get_global_delay(), 0.4);helpers.assert_eq(c.config.resolve("magickey", nil).delay, 0.3)
					helpers.assert_eq(#asks, 1);helpers.assert_eq(#notices, 1);helpers.assert_eq(releases, 1)
					local retry, committed, _, retry_notices = observe(action, "900")
					helpers.assert_true(retry);helpers.assert_eq(committed, true);helpers.assert_eq(changed, 1);helpers.assert_eq(#retry_notices, 0)
					local disk = read(c.path)
					helpers.assert_true(disk:find(c.foreign, 1, true) ~= nil, "unknown nested data and comments retain their exact bytes")
					helpers.assert_eq(read(c.config_path), '[future]\nuser = "kept"\n', "the unrelated canonical config was never written")
					local decoded = require("toml_codec").decode(disk)
					helpers.assert_eq(decoded[kind == "global" and "_global" or "magickey"].delay, 0.9)
					assert(c.config.init(require("hotstring_engine").new(), c.path:match("^(.*)/")))
					helpers.assert_eq(kind == "global" and c.config.get_global_delay() or c.config.resolve("magickey", nil).delay, 0.9,
						"a real disk reload agrees with the acknowledged value")
				end)
			end)
		end
		helpers.it(kind .. " delay refuses a foreign source written while the prompt is held", function()
			with_native_owner(function(c)
				local changed = 0
				local action = delay_action(c.config, kind, function() changed = changed + 1 end)
				local foreign = c.original .. '# another owner changed the physical source\n'
				local called, result, _, notices = observe(action, "900", function() write(c.path, foreign) end)
				helpers.assert_true(called);helpers.assert_eq(result, false);helpers.assert_eq(changed, 0)
				helpers.assert_eq(read(c.path), foreign, "the captured canonical override source refuses a stale write")
				helpers.assert_eq(c.config.get_global_delay(), 0.4);helpers.assert_eq(c.config.resolve("magickey", nil).delay, 0.3)
				helpers.assert_eq(#notices, 1)
			end)
		end)
	end
end)




helpers.describe("category fixture process status: actual normalized owner", function()
	for _, abi in ipairs({ "numeric", "compat52" }) do
		helpers.it("keeps real directory/write/cleanup acknowledgement under " .. abi, function()
			local previous = package.loaded["adapters.shell_runner"]
			local shell = helpers.load_module("adapters.shell_runner")
			local execute = os.execute
			local directory = os.tmpname();assert(os.remove(directory));directory = directory .. "-section-abi"
			local seen = { calls = 0 }
			os.execute = function(command)
				seen.calls = seen.calls + 1
				local code, kind, status = execute(command)
				if code == 0 or (code == true and kind == "exit" and status == 0) then
					if abi == "numeric" then return 0 end
					return true, "exit", 0
				end
				return code, kind, status
			end
			local called, issue = pcall(function()
				seen.mkdir = shell.run("mkdir -p " .. shell.quote(directory))
				local file = assert(io.open(directory .. "/physical", "wb"))
				assert(file:write("independent physical bytes"));assert(file:close())
				file = assert(io.open(directory .. "/physical", "rb"))
				seen.bytes = file:read("*a");assert(file:close())
				seen.failed_process = shell.run("sh -c 'exit 1'")
				seen.cleanup = shell.run("rm -rf " .. shell.quote(directory))
				seen.absent = io.open(directory .. "/physical", "rb") == nil
			end)
			os.execute = execute
			package.loaded["adapters.shell_runner"] = previous
			-- Cleanup is physical even if an earlier candidate acknowledgement refused.
			if not seen.absent then shell.run("rm -rf " .. shell.quote(directory)) end
			helpers.assert_true(called, issue)
			helpers.assert_eq(seen.calls, 3, "the real process boundary, not a retained _test_runner, owns every command")
			helpers.assert_eq(seen.mkdir, true)
			helpers.assert_eq(seen.bytes, "independent physical bytes")
			helpers.assert_eq(seen.failed_process, false)
			helpers.assert_eq(seen.cleanup, true)
			helpers.assert_eq(seen.absent, true)
		end)
	end
	for _, outcome in ipairs({ "false", "nil", "number", "text", "throw" }) do
		helpers.it("does not acknowledge the real failed process with receipt " .. outcome, function()
			local previous = package.loaded["adapters.shell_runner"]
			local shell = helpers.load_module("adapters.shell_runner")
			local execute, seen = os.execute, {}
			os.execute = function(command)
				seen.calls = (seen.calls or 0) + 1
				seen.native = { execute(command) }
				if outcome == "nil" then return nil, "exit", 1 end
				if outcome == "number" then return 2 end
				if outcome == "text" then return "true" end
				if outcome == "throw" then error("inert process receipt refusal") end
				return false, "exit", 1
			end
			local called, result = pcall(shell.run, "sh -c 'exit 1'")
			os.execute = execute
			package.loaded["adapters.shell_runner"] = previous
			helpers.assert_true(called)
			helpers.assert_eq(seen.calls, 1, "the refusal still executed the actual independent failed child")
			helpers.assert_true(seen.native[1] ~= 0 and seen.native[1] ~= true)
			helpers.assert_eq(result, false)
		end)
	end
end)

