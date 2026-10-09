--- tests/unit/meta/test_bridge_persistence.lua

--- ==============================================================================
--- MODULE: Bridge Handler TOML Persistence Spies
--- DESCRIPTION:
--- Characterization tests for the five UI bridge handlers that persist user
--- choices through the shared toml_codec.writer. Each test injects a capturing
--- fake writer into package.loaded BEFORE the handler is loaded, drives the
--- persisting action, and asserts the exact payload handed to the writer.
---
--- ROOT CAUSE ENCODED:
--- The existing ui.bridge_handlers suite only asserts each on_message return
--- value (result.saved == true, result.accepted == true, ...). A handler could
--- silently stop writing to disk, or write the wrong section/key/value, and
--- those tests would stay green. These spies lock the persistence contract: the
--- writer must be called, at the right path, with the right section/key/value.
--- Neutralise any writer.batch_write / writer.write call in a handler and the
--- matching assert_not_nil / assert_eq below turns red.
--- ==============================================================================

local helpers = require("tests.helpers")


--- The existing persistence action now starts from a manager-owned displayed model.
--- @param handler table Actual personal editor bridge.
--- @param state table Test's configured personal source.
--- @return table context Trusted recorded native epoch.
local function open_personal_view(handler, state)
	local context = { app_name = "hotstring_editor", epoch = 73 }
	local pushed = handler.push_init(state, context)
	assert(pushed == true, "The persistence payload test requires an accepted personal opening")
	return context
end





-- ====================================
-- ====================================
-- ======= 1/ Writer spy helper =======
-- ====================================
-- ====================================

--- Installs a capturing fake toml_codec.writer into package.loaded, loads the
--- handler fresh (so its lazy _writer cache resolves to the fake), runs the
--- caller's invocation, then restores the real writer. Returns the captured
--- call, or nil when the handler never persisted.
--- @param module_name string Dotted handler module to load under the spy.
--- @param invoke function Callback receiving the freshly loaded handler.
--- @return table|nil Captured { method, path, updates|data } or nil.
local function with_writer_spy(module_name, invoke)
	local captured = nil
	-- One fake fits every handler: batch_write (config.toml handlers) and write
	-- (hotstring group-file handlers) both capture their arguments.
	local classified_read = require("toml_codec.writer").read_classified
	local fake = {
		read_classified = classified_read,
		batch_write = function(path, updates)
			captured = { method = "batch_write", path = path, updates = updates }
			return true
		end,
		write = function(path, data)
			captured = { method = "write", path = path, data = data }
			return true
		end,
	}
	local saved = package.loaded["toml_codec.writer"]
	local previous_manager = package.loaded["ui.webview_manager"]
	if module_name == "ui.hotstring_editor.bridge" then
		package.loaded["ui.webview_manager"] = { current_epoch = function() return 73 end, eval_js = function() return true end }
	end
	package.loaded["toml_codec.writer"] = fake
	local ok, err = pcall(function()
		local handler = helpers.load_module(module_name)
		invoke(handler)
	end)
	-- Restore the real cache before asserting so a failure cannot leak the fake.
	package.loaded["toml_codec.writer"] = saved
	package.loaded["ui.webview_manager"] = previous_manager
	if not ok then error(err, 0) end
	return captured
end





-- ====================================
-- ====================================
-- ======= 2/ Persistence spies =======
-- ====================================
-- ====================================

helpers.describe("bridge handler TOML persistence", function()

	helpers.it("paths_editor_bridge makes the selected config directory authoritative", function()
		local saved_storage = package.loaded["adapters.storage"]
		local saved_paths = package.loaded["infra.config_paths"]
		local values = {}
		package.loaded["adapters.storage"] = {
			get = function(key, fallback)
				local value = values[key]
				if value == nil then return fallback end
				return value
			end,
			set = function(key, value) values[key] = value; return true end,
			delete = function(key) values[key] = nil; return true end,
		}
		package.loaded["infra.config_paths"] = nil
		local ok, err = pcall(function()
			local handler = helpers.load_module("ui.paths_editor.bridge")
			local pushed = {}
			local state = {
				config = { get_config_dir = function() return "/wrong/hotstrings-pack-dir" end },
				webview_manager = {
					eval_js = function(app, code)
						pushed[#pushed + 1] = { app = app, code = code }
						return true
					end,
					hide = function() return true end,
				},
				on_reload = function() return true end,
			}
			local initial = handler.on_message({ action = "ready" }, state)
			local ConfigPaths = require("infra.config_paths")
			helpers.assert_true(initial.pushed)
			helpers.assert_eq(initial.data.configDir, ConfigPaths.default_config_dir(),
				"the hotstring catalogue directory must not masquerade as the config root")
			helpers.assert_contains(pushed[1].code, "window.initData")
			local result = handler.on_message({
				action = "save", configDir = "/tmp/ergopti-custom/",
			}, state)
			helpers.assert_true(result.saved, "the bridge must report the storage acknowledgement")
			helpers.assert_eq(values["paths.config_dir"], "/tmp/ergopti-custom")
			helpers.assert_eq(ConfigPaths.config("config.toml"),
				"/tmp/ergopti-custom/config.toml",
				"the runtime resolver must consume the exact setting the bridge wrote")

			local reset = handler.on_message({ action = "save", configDir = "" }, state)
			helpers.assert_true(reset.saved, "an empty choice must restore the XDG default")
			helpers.assert_eq(values["paths.config_dir"], nil)
			helpers.assert_eq(ConfigPaths.get_config_dir(), ConfigPaths.default_config_dir())
		end)
		package.loaded["adapters.storage"] = saved_storage
		package.loaded["infra.config_paths"] = saved_paths
		package.loaded["ui.paths_editor.bridge"] = nil
		if not ok then error(err, 0) end
	end)

	-- The `add_hotstring` case that stood here was removed on 2026-08-05: the
	-- shared settings window has never sent that action, so it asserted a write
	-- path nothing could reach. Writing hotstrings is the editor's job, below.
	helpers.it("hotstring_editor_bridge.save writes the personal file, named by its stem", function()
		local state = { config = { get_config_dir = function() return "/home/user/.config/ergopti/hotstrings" end } }
		local captured = with_writer_spy(
			"ui.hotstring_editor.bridge",
			function(handler)
				local context = open_personal_view(handler, state)
				handler.on_message({
					action = "save",
					data = {
						sections_order = { "english" },
						sections = { english = { description = "English", entries = {
							{ trigger = "btw", output = "by the way" },
						} } },
					},
				}, state, context)
			end)
		helpers.assert_not_nil(captured, "save must reach the writer")
		helpers.assert_eq(captured.method, "write")
		-- personal.toml, not <section>.toml. The loader groups by FILE STEM, so the
		-- filename decides which category these entries join; writing english.toml
		-- would invent a category the menu, the priority table and the settings
		-- window all know nothing about.
		helpers.assert_eq(captured.path, "/home/user/.config/ergopti/hotstrings/personal.toml")
		helpers.assert_eq(captured.data.sections_order, { "english" })
		local entry = captured.data.sections.english.entries[1]
    helpers.assert_eq(entry.trigger, "btw")
    helpers.assert_eq(entry.output, "by the way")
  end)

  helpers.it("hotstring_editor_bridge.save preserves the file-level tuning the UI does not carry", function()
    -- Regression: save_all() rebuilt the file from the UI model alone, so a
    -- hand-tuned [_meta] (priority, delay, color, tooltip, section delays)
    -- was wiped by adding one hotstring from the editor.
    local dir = os.tmpname()
    os.remove(dir)
    -- os.tmpname() names a file; the bridge needs a directory.
    local ok_mkdir = os.execute('mkdir "' .. dir .. '"')
    helpers.assert_true(ok_mkdir == true or ok_mkdir == 0, "sandbox directory must exist")
    local path = dir .. "/personal.toml"
    local seed = assert(io.open(path, "w"))
    seed:write('[_meta]\n'
      .. 'description = "Personal"\n'
      .. 'priority = 80\n'
      .. 'delay = 0.5\n'
      .. 'show_tooltip = false\n'
      .. 'color = "red"\n'
      .. 'sections_order = ["english"]\n'
      .. '\n'
      .. '[_meta.section_delays]\n'
      .. 'english = 0.3\n'
      .. '\n'
      .. '[[english]]\n'
      .. '"btw" = { output = "by the way", is_word = false, auto_expand = true, is_case_sensitive = false, final_result = false }\n')
    seed:close()
    local state = { config = { get_config_dir = function() return dir end } }
    local captured = with_writer_spy(
      "ui.hotstring_editor.bridge",
      function(handler)
        local context = open_personal_view(handler, state)
        handler.on_message({
          action = "save",
          data = {
            sections_order = { "english" },
            sections = { english = { description = "English", entries = {
              { trigger = "btw", output = "by the way" },
              { trigger = "hi", output = "hello" },
            } } } },
        }, state, context)
      end)
    os.remove(path)
    os.execute('rmdir "' .. dir .. '"')
    helpers.assert_not_nil(captured, "save must reach the writer")
    local meta = captured.data.meta or {}
    helpers.assert_eq(meta.priority, 80,
      "the file-level priority must survive an editor save")
    helpers.assert_eq(meta.delay, 0.5,
      "and the file-level delay")
    helpers.assert_eq(meta.show_tooltip, false,
      "and the tooltip setting")
    helpers.assert_eq(meta.color, "red",
      "and the color")
    helpers.assert_eq(type(meta.section_delays) == "table" and meta.section_delays.english, 0.3,
      "and the per-section delays")
    helpers.assert_eq(#captured.data.sections.english.entries, 2,
      "while the UI edit itself still lands")
  end)

end)




-- ============================================================================
-- ============================================================================
-- ======= 3/ Shared writer file-level tuning round-trip =====================
-- ============================================================================
-- ============================================================================

helpers.describe("shared toml writer preserves file-level tuning (meta-tuning)", function()

  --- Reads a whole file, or "" when absent.
  local function read_written(path)
    local fh = io.open(path, "r")
    if not fh then return "" end
    local content = fh:read("*a") or ""
    fh:close()
    return content
  end

  helpers.it("meta-tuning: write then parse round-trips the tuning the loader consumes", function()
    -- The Linux loader resolves meta.delay/color/show_tooltip/priority and
    -- meta.section_delays, but the shared writer never emitted them: any
    -- write through it silently reset that tuning to the shipped defaults.
    local writer = helpers.load_module("toml_codec.writer")
    local reader = helpers.load_module("toml_codec.reader")
    local path = os.tmpname()
    local data = {
      meta = {
        description = "Personal",
        delay = 0.5,
        color = "red",
        show_tooltip = false,
        priority = 80,
        section_delays = { english = 0.3 },
      },
      sections_order = { "english" },
      sections = { english = { description = "English", entries = {
        { trigger = "btw", output = "by the way" },
      } } },
    }
    local ok, err = writer.write(path, data)
    helpers.assert_true(ok == true, "write must succeed: " .. tostring(err))
    local parse_ok, parsed = pcall(reader.parse, path)
    os.remove(path)
    helpers.assert_true(parse_ok and type(parsed) == "table",
      "the written file must parse back")
    local meta = parsed.meta or {}
    helpers.assert_eq(meta.delay, 0.5, "delay must round-trip")
    helpers.assert_eq(meta.color, "red", "color must round-trip")
    helpers.assert_eq(meta.show_tooltip, false, "show_tooltip = false must round-trip as false, not vanish")
    helpers.assert_eq(meta.priority, 80, "priority must round-trip")
    helpers.assert_eq(type(meta.section_delays) == "table" and meta.section_delays.english, 0.3,
      "section delays must round-trip")
    helpers.assert_eq(parsed.sections.english.entries[1].trigger, "btw",
      "entries must survive alongside the tuning")
  end)

  helpers.it("meta-tuning: callers without tuning get byte-identical output", function()
    -- Additive emission only: the onboarding/config-window bridges never set
    -- tuning, so their files must not gain lines they never had.
    local writer = helpers.load_module("toml_codec.writer")
    local path = os.tmpname()
    local ok = writer.write(path, {
      meta = { description = "Personal" },
      sections_order = { "english" },
      sections = { english = { description = "English", entries = {
        { trigger = "btw", output = "by the way" },
      } } },
    })
    local content = read_written(path)
    os.remove(path)
    helpers.assert_true(ok == true, "write must succeed")
    helpers.assert_true(content:find("delay", 1, true) == nil,
      "no delay line without a delay value")
    helpers.assert_true(content:find("priority", 1, true) == nil,
      "no priority line without a priority value")
    helpers.assert_true(content:find("section_delays", 1, true) == nil,
      "no section_delays block without section delays")
  end)

end)

-- A source read/refusal must not be converted into a new empty personal file.
-- These cases run the actual bridge, codec, staged writer and native files.
helpers.describe("hotstring editor classified source admission", function()
	local seed = '# independent file tuning\n[_meta]\ndescription = "Personal"\npriority = 80\ndelay = 0.5\nshow_tooltip = false\nsections_order = ["english"]\n\n[[english]]\n"old" = { output = "previous", is_word = false }\n'
	local foreign = '# external writer\n[_meta]\ndescription = "Foreign"\nsections_order = []\n'
	local function observe(mode, initial)
		local root = os.tmpname()
		os.remove(root)
		local made = os.execute('mkdir "' .. root .. '"')
		assert(made == true or made == 0)
		local path = root .. "/personal.toml"
		local native_open, native_rename = io.open, os.rename
		local old_bridge = package.loaded["ui.hotstring_editor.bridge"]
		local old_manager = package.loaded["ui.webview_manager"]
		local writer = require("toml_codec.writer")
		local reader = require("toml_codec.reader")
		local old_writer, old_reader = package.loaded["toml_codec.writer"], package.loaded["toml_codec.reader"]
		local obs = { stages = 0, renames = 0, reloads = 0, source = initial, faults = 0, source_reads = 0, epochs = 0 }
		local function put(content)
			local fh = assert(native_open(path, "w")); assert(fh:write(content)); assert(fh:close())
		end
		if initial then put(initial) end
		local context = { app_name = "hotstring_editor", epoch = 73 }
		local state = { config = { get_config_dir = function() return root end, reload = function() obs.reloads = obs.reloads + 1; return 10 end } }
		package.loaded["ui.webview_manager"] = { current_epoch = function() obs.epochs = obs.epochs + 1; return 73 end, eval_js = function() return true end }
		local ok, problem = pcall(function()
			io.open = function(target, access)
				if target == path and access == "r" then
					obs.source_reads = obs.source_reads + 1
					if mode == "open_false" then obs.faults = obs.faults + 1; return nil, "controlled unreadable", 13 end
					if mode == "open_throw" then obs.faults = obs.faults + 1; error("controlled source open refusal") end
					local fh, err, code = native_open(target, access)
					if fh and (mode == "read_nil" or mode == "close_nil" or mode == "close_false") then
						return {
							read = function(_, ...) if mode == "read_nil" then obs.faults = obs.faults + 1; return nil end; return fh:read(...) end,
							lines = function() return fh:lines() end,
							close = function() local closed = fh:close(); if mode == "close_nil" then obs.faults = obs.faults + 1; return nil end; if mode == "close_false" then obs.faults = obs.faults + 1; return false end; return closed end,
						}
					end
					return fh, err, code
				end
				if target == path .. ".tmp" and access == "w" then
					obs.stages = obs.stages + 1
					if mode == "stale" or mode == "appeared" then obs.faults = obs.faults + 1; put(foreign); obs.source = foreign end
				end
				return native_open(target, access)
			end
			os.rename = function(from, to)
				if to == path then
					obs.renames = obs.renames + 1
					if mode == "rename_false" then obs.faults = obs.faults + 1; return false, "controlled publish refusal" end
					if mode == "rename_nil" then obs.faults = obs.faults + 1; return nil, "controlled publish refusal" end
					if mode == "rename_throw" then obs.faults = obs.faults + 1; error("controlled publish refusal") end
				end
				return native_rename(from, to)
			end
			if mode == "parse_false" or mode == "parse_nil" or mode == "parse_truthy" or mode == "parse_throw" or mode == "missing_parse" then
				local port = {}; for key, value in pairs(reader) do port[key] = value end
				port.parse_text = function(content)
					obs.faults = obs.faults + 1
					if mode == "parse_throw" then error("controlled parse refusal") end
					local data = reader.parse_text(content)
					if mode == "parse_false" then return data, false end
					if mode == "parse_truthy" then return data, 2 end
					return data
				end
				if mode == "missing_parse" then port.parse_text = nil end
				package.loaded["toml_codec.reader"] = port
			end
			if mode == "missing_classified" or mode == "write_truthy" then
				local port = {}; for key, value in pairs(writer) do port[key] = value end
				if mode == "missing_classified" then port.read_classified = nil else port.write = function() obs.faults = obs.faults + 1; return 2 end end
				package.loaded["toml_codec.writer"] = port
			end
			local bridge = helpers.load_module("ui.hotstring_editor.bridge")
			obs.opened = bridge.push_init(state, context)
			obs.result = bridge.on_message({ action = "save", data = {
				sections_order = { "english" }, sections = { english = { entries = { { trigger = "new", output = "next" } } } },
			} }, state, context)
		end)
		io.open, os.rename = native_open, native_rename
		package.loaded["ui.hotstring_editor.bridge"] = old_bridge
		package.loaded["ui.webview_manager"] = old_manager
		package.loaded["toml_codec.writer"], package.loaded["toml_codec.reader"] = old_writer, old_reader
		local fh = native_open(path, "r"); obs.bytes = fh and fh:read("*a") or nil; if fh then fh:close() end
		local stage = native_open(path .. ".tmp", "r"); obs.stage_left = stage ~= nil; if stage then stage:close() end
		os.remove(path); os.remove(path .. ".tmp"); os.remove(root)
		obs.ok, obs.problem = ok, problem
		obs.restored = io.open == native_open and os.rename == native_rename
			and package.loaded["ui.hotstring_editor.bridge"] == old_bridge
			and package.loaded["toml_codec.writer"] == old_writer and package.loaded["toml_codec.reader"] == old_reader
			and package.loaded["ui.webview_manager"] == old_manager
		return obs
	end
	for _, mode in ipairs({ "malformed", "open_false", "open_throw", "read_nil", "close_nil", "close_false", "parse_false", "parse_nil", "parse_truthy", "parse_throw", "missing_parse", "missing_classified", "stale", "appeared", "rename_false", "rename_nil", "rename_throw", "write_truthy" }) do
		helpers.it("personal source refusal retains native bytes: " .. mode, function()
			local initial = mode == "malformed" and '[info\nbroken' or seed
			if mode == "appeared" then initial = nil end
			local obs = observe(mode, initial)
			helpers.assert_true(obs.restored, "every native and module port must be restored before assertions")
			helpers.assert_true(obs.ok, "source refusal must return a receipt without escaping the handler")
			helpers.assert_eq(obs.result.saved, false, "a refused source or publication cannot acknowledge saved")
			if mode == "stale" or mode == "appeared" or mode:match("^rename_") or mode == "write_truthy" then
				helpers.assert_eq(obs.opened, true, "the publication fault must occur after a real admitted view")
			elseif mode == "missing_parse" or mode == "missing_classified" then
				helpers.assert_eq(obs.opened, false, "the missing required opening owner must refuse")
			elseif mode == "malformed" then
				helpers.assert_eq(obs.opened, false)
				helpers.assert_true(obs.source_reads > 0, "the actual malformed source must be read")
				helpers.assert_true(obs.epochs > 0, "a real current epoch must precede source refusal")
			else
				helpers.assert_eq(obs.opened, false, "the source/parse fault must refuse opening itself")
			end
			if mode ~= "malformed" and mode ~= "missing_parse" and mode ~= "missing_classified" then
				helpers.assert_true(obs.faults > 0, "the selected source/publication refusal port must actually execute")
			end
			helpers.assert_eq(obs.bytes, obs.source, "the exact original or concurrent source must remain on disk")
			helpers.assert_eq(obs.reloads, 0, "refused publication must not reload the catalogue")
			helpers.assert_eq(obs.stage_left, false, "the owned stage must be retired on refusal")
			if mode ~= "stale" and mode ~= "appeared" and not mode:match("^rename_") then
				helpers.assert_eq(obs.stages, 0, "source admission must refuse before opening the owned stage")
			end
		end)
	end
	for _, mode in ipairs({ "present", "absent" }) do
		helpers.it("personal classified source preserves successful replacement: " .. mode, function()
			local obs = observe(mode, mode == "present" and seed or nil)
			helpers.assert_true(obs.restored)
			helpers.assert_true(obs.ok)
			helpers.assert_eq(obs.result.saved, true)
			helpers.assert_eq(obs.opened, true, "successful replacement needs a genuinely displayed source")
			helpers.assert_eq(obs.renames, 1, "one native atomic publication must acknowledge replacement")
			helpers.assert_eq(obs.reloads, 1)
			helpers.assert_eq(obs.stage_left, false)
			local parsed, committed = require("toml_codec.reader").parse_text(obs.bytes)
			helpers.assert_eq(committed, true)
			helpers.assert_eq(parsed.sections.english.entries[1].trigger, "new", "the requested whole-model edit must persist")
			helpers.assert_eq(#parsed.sections.english.entries, 1, "deleted old entries must stay deleted")
			if mode == "present" then
				helpers.assert_eq(parsed.meta.priority, 80)
				helpers.assert_eq(parsed.meta.delay, 0.5)
				helpers.assert_eq(parsed.meta.show_tooltip, false)
			end
		end)
	end
end)
