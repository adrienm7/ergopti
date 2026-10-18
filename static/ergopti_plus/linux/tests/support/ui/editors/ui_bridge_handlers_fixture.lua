--- tests/support/ui/editors/ui_bridge_handlers_fixture.lua

--- ==============================================================================
--- MODULE: Shared fixture for test_ui_bridge_handlers
--- DESCRIPTION:
--- Prelude shared by the test_ui_bridge_handlers_* test files: their modules, stubs and
--- helpers. Each part loads it fresh, so no state leaks from one file to the
--- next.
--- ==============================================================================

local helpers = require("tests.helpers")

-- ============================================================================
-- personal_toml_editor save: validate before truncating, stage atomically.
-- ============================================================================
--
-- Regression: the save handler truncated personal_info.toml with io.open(path,
-- "w") and then wrote whatever the editor sent — unchecked write/close, no
-- tmp staging, no TOML validation. One malformed save disabled every @-tag
-- shortcut on the next load, a crash mid-write left a truncated file, and a
-- fresh home with no file could never save at all (toml_path == "").
--
-- These tests sandbox the bridge (fake home, fake dynamic manager path, fake
-- shell) and drive the real on_message() save path.

--- Reads a whole file, or "" when absent.
local function read_sandbox_file(path)
  local fh = io.open(path, "r")
  if not fh then return "" end
  local content = fh:read("*a") or ""
  fh:close()
  return content
end

--- Installs sandbox doubles and returns a freshly loaded bridge plus restore info.
local function sandboxed_toml_bridge(toml_path)
  local previous = {
    config_paths = package.loaded["infra.config_paths"],
    manager = package.loaded["modules.dynamic_hotstrings.manager"],
    shell = package.loaded["adapters.shell_runner"],
  }
  package.loaded["infra.config_paths"] = {
    home = function() return "/nonexistent-test-home" end,
  }
  package.loaded["modules.dynamic_hotstrings.manager"] = {
    get_config_path = function() return toml_path end,
    reload = function() end,
  }
  package.loaded["adapters.shell_runner"] = {
    run = function() return true end,
    quote = function(s) return "'" .. tostring(s) .. "'" end,
  }
  local handler = helpers.load_module("ui.personal_info_editor.bridge_toml")
  return handler, previous
end

local function restore_sandbox(previous)
  package.loaded["infra.config_paths"] = previous.config_paths
  package.loaded["modules.dynamic_hotstrings.manager"] = previous.manager
  package.loaded["adapters.shell_runner"] = previous.shell
end

-- Real private source publication exercises the displayed model's consent boundary.
local OPENING_SOURCE = '[_meta]\nsections_order = ["english"]\n[english]\n"old" = { output = "original", is_word = true, final_result = false }\n'

local OPENING_FOREIGN = OPENING_SOURCE .. '[outside]\n"future" = { output = "independent external edit", final_result = false } # retain exact bytes\n'

local function opening_model(output)
	return { sections_order = { "english" }, sections = {
		english = { description = "English", entries = { { trigger = "old", output = output } } },
	} }
end

local function with_opening_file(callback)
	local Shell, Writer = require("adapters.shell_runner"), require("toml_codec.writer")
	local directory = os.tmpname(); assert(os.remove(directory)); directory = directory .. "-personal-view-consent"
	assert(Shell.run("mkdir -p " .. Shell.quote(directory)) == true)
	local path = directory .. "/personal.toml"
	local function put(content)
		local file = assert(io.open(path, "wb")); assert(file:write(content)); assert(file:close())
	end
	local function read()
		local file = assert(io.open(path, "rb")); local bytes = assert(file:read("*a")); assert(file:close()); return bytes
	end
	put(OPENING_SOURCE)
	local manager, previous = package.loaded["ui.webview_manager"], package.loaded["ui.hotstring_editor.bridge"]
	local writer_previous = package.loaded["toml_codec.writer"]
	local seen = { epoch = 51, deliveries = {}, alerts = {}, reloads = 0, writes = 0 }
	local publisher = {}
	for key, value in pairs(Writer) do publisher[key] = value end
	publisher.write = function(...)
		seen.writes = seen.writes + 1
		return Writer.write(...)
	end
	package.loaded["toml_codec.writer"] = publisher
	package.loaded["ui.webview_manager"] = {
		current_epoch = function() return seen.epoch end,
		eval_js = function(_, js)
			if js:find("window.initData(", 1, true) then
				seen.deliveries[#seen.deliveries + 1] = js
				if seen.delivery == "throw" then error("inert delivery refusal") end
				if seen.delivery == "false" then return false end
				if seen.delivery == "nil" then return nil end
				if seen.delivery == "number" then return 1 end
				return true
			end
			seen.alerts[#seen.alerts + 1] = js; return true
		end,
	}
	package.loaded["ui.hotstring_editor.bridge"] = nil
	local handler = require("ui.hotstring_editor.bridge")
	local context = { app_name = "hotstring_editor", epoch = 51 }
	local state = { config = { get_config_dir = function() return directory end,
		reload = function() seen.reloads = seen.reloads + 1; if seen.reload_throw then error("inert reload refusal") end; return true end } }
	local f = { path = path, handler = handler, context = context, state = state, seen = seen,
		publisher = publisher, writer = Writer, put = put, read = read }
	f.ready = function() return handler.push_init(state, context) end
	f.save = function(output, selected) return handler.on_message({ action = "save", data = opening_model(output) }, state, selected or context) end
	local ok, err = pcall(callback, f)
	package.loaded["ui.webview_manager"], package.loaded["ui.hotstring_editor.bridge"], package.loaded["toml_codec.writer"] = manager, previous, writer_previous
	assert(Shell.run("rm -rf " .. Shell.quote(directory)) == true)
	if not ok then error(err, 0) end
end

local function build_mock_state()
  return {
    engine    = { loaded = true },
    keylogger = require("tests.fakes.metrics_keylogger").synchronous({
      get_session_stats = function() return { keystrokes = 42, words = 8, duration_ms = 120000 } end,
      get_wpm           = function() return 35.5 end,
      get_app_stats     = function() return { firefox = { keystrokes = 20 }, code = { keystrokes = 22 } } end,
      get_dashboard_payload = function()
        return {
          metrics_manifest = {
            ["2026-07-18"] = {
              firefox = { chars = 20, time = 3000, app_time_ms = 120000, category = "Unknown" },
            },
          },
          app_icons = {},
          _prefetch_data = { historical = {}, today = {} },
          driver_meta = { os = "linux", heatmap_id = "sc_kb" },
        }
      end,
		get_range_payload = function(start_date, end_date, apps)
			return {
				historical = { c = { a = { c = 2, t = 0, e = 0, hs = 0, llm = 0, o = 0 } } },
				today = { firefox = { c = { b = { c = 3, t = 0, e = 0, hs = 0, llm = 0, o = 0 } } } },
			}
		end,
      is_suppressed     = function() return false end,
      suppress          = function() end,
      unsuppress        = function() end,
      reset_session     = function() return true end,
      export_json       = function() return '{"keystrokes":42}' end,
    }),
    config = {
      -- Flat functions, matching how hotstrings_config actually defines them.
      -- This mock used to take a leading `self` because the bridge called
      -- through `:` — so `is_group_enabled` received the module as its group
      -- name and answered "enabled" for everything, and `toggle_group`
      -- silently no-opped on its own string guard. The mock was shaped to the
      -- bug, which is why the bridge's own test could never see it.
      get_groups     = function() return { "accents", "math", "code" } end,
      is_group_enabled = function(g) return g ~= "code" end,
      toggle_group   = function(g) end,
      reload         = function() return 10 end,
      mapping_count  = function() return 50 end,
      parse_error_count = function() return 2 end,
      get_config_dir = function() return "/home/user/.config/ergopti/hotstrings" end,
    },
    llm = {
      is_enabled        = function() return true end,
      get_current_model = function() return "codellama" end,
      get_models        = function() return { "codellama", "mistral", "llama3" } end,
      get_triggers      = function() return { "//", ";;" } end,
      toggle            = function() end,
      set_model         = function(m) end,
      predict           = function(ctx) end,
    },
    layout = "qwerty",
  }
end

-- ==========================================================================
-- Spy reader/writer for the hotstring persistence handlers. The reader seeds
-- two sibling entries so a correct merge must preserve them; the writer
-- captures the payload and can be told to fail, so we can assert the handlers
-- propagate the real write result instead of hard-coding success.
-- ==========================================================================

local function make_spies(write_result, write_err)
  local captured = {}
  local snapshot_parser = require("toml_codec.reader").parse_text
  local classified_read = require("toml_codec.writer").read_classified
  local reader = {
    parse_text = snapshot_parser,
    parse = function(_path)
      return {
        meta = { description = "english" },
        sections_order = { "english" },
        sections = {
          english = {
            description = "english",
            entries = {
              { trigger = "omw", output = "on my way", is_word = true,
                auto_expand = false, is_case_sensitive = true, final_result = false,
                is_case_sensitive_strict = true },
              { trigger = "ty", output = "thank you", is_word = true,
                auto_expand = false, is_case_sensitive = false, final_result = false },
            },
          },
        },
      }
    end,
  }
  local writer = {
    read_classified = classified_read,
    write = function(path, data)
      captured.path = path
      captured.data = data
      return write_result, write_err
    end,
  }
  return reader, writer, captured
end

-- Injects the spies into package.loaded, loads the handler fresh so its lazy
-- _get_reader/_get_writer resolve to the spies, runs fn(handler), then restores.
local function with_spies(module_name, reader, writer, fn)
  local prev_r = package.loaded["toml_codec.reader"]
  local prev_w = package.loaded["toml_codec.writer"]
  package.loaded["toml_codec.reader"] = reader
  package.loaded["toml_codec.writer"] = writer
  local handler = helpers.load_module(module_name)
  local ok, err = pcall(fn, handler)
  package.loaded["toml_codec.reader"] = prev_r
  package.loaded["toml_codec.writer"] = prev_w
  if not ok then error(err, 0) end
end

-- Existing personal persistence tests now enter through an accepted displayed source.
local function with_opened_spies(reader, writer, state, fn)
  local RealWriter = require("toml_codec.writer")
  local Shell = require("adapters.shell_runner")
  local directory = os.tmpname(); assert(os.remove(directory)); directory = directory .. "-personal-opening"
  assert(Shell.run("mkdir -p " .. Shell.quote(directory)) == true)
  local path = directory .. "/personal.toml"
  local file = assert(io.open(path, "wb"))
  assert(file:write('[_meta]\nsections_order = ["english"]\n[english]\n"omw" = { output = "on my way", is_word = true, auto_expand = false, is_case_sensitive = true, is_case_sensitive_strict = true, final_result = false }\n"ty" = { output = "thank you", is_word = true, final_result = false }\n'))
  assert(file:close())
  local old_dir, manager, native_write = state.config.get_config_dir, package.loaded["ui.webview_manager"], writer.write
  local previous_prepare = writer.prepare_batch
  -- Preserve the actual planner capability while spying on its publication.
  writer.prepare_batch = RealWriter.prepare_batch
  state.config.get_config_dir = function() return directory end
  local context = { app_name = "hotstring_editor", epoch = 41 }
  package.loaded["ui.webview_manager"] = { current_epoch = function() return 41 end,
    eval_js = function() return true end }
  writer.write = function(...)
    local accepted, detail = native_write(...)
    if accepted ~= true then return accepted, detail end
    return RealWriter.write(...)
  end
  local ok, err = pcall(function()
    with_spies("ui.hotstring_editor.bridge", reader, writer, function(h)
      assert(h.push_init(state, context) == true, "The original save case requires an accepted opening")
      fn(h, context)
    end)
  end)
  writer.write, writer.prepare_batch, state.config.get_config_dir, package.loaded["ui.webview_manager"] = native_write, previous_prepare, old_dir, manager
  assert(Shell.run("rm -rf " .. Shell.quote(directory)) == true)
  if not ok then error(err, 0) end
end

-- ==========================================================================
-- 1. webview_manager
-- ==========================================================================

return {
	helpers = helpers,
	read_sandbox_file = read_sandbox_file,
	sandboxed_toml_bridge = sandboxed_toml_bridge,
	restore_sandbox = restore_sandbox,
	OPENING_SOURCE = OPENING_SOURCE,
	OPENING_FOREIGN = OPENING_FOREIGN,
	opening_model = opening_model,
	with_opening_file = with_opening_file,
	build_mock_state = build_mock_state,
	make_spies = make_spies,
	with_spies = with_spies,
	with_opened_spies = with_opened_spies,
}
