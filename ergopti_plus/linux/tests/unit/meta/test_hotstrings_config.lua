--- tests/unit/meta/test_hotstrings_config.lua
---
--- Tier 1.3 — Integration tests for hotstrings_config module.
--- Tests: init, load_all, reload, group enable/disable, duplicate detection,
--- config path resolution, edge cases.

local helpers = require("tests.helpers")
local config  = helpers.load_module("modules.hotstrings.hotstrings_config")
local engine_mod = helpers.load_module("modules.hotstrings.engine")

helpers.describe("hotstrings_config", function()

  -- Create a minimal engine stub for testing.
  local function make_engine()
    local e = engine_mod.new()
    -- Track what was loaded for assertions.
    e._loaded = {}
    local orig = e.load_mappings
    e.load_mappings = function(self, mappings)
      e._loaded = mappings
      if orig then return orig(self, mappings) end
    end
    return e
  end

  -- ==========================================================================
  -- 1. Module structure
  -- ==========================================================================

  helpers.describe("module structure", function()
    helpers.it("exports init", function()
      helpers.assert_true(type(config.init) == "function", "init is a function")
    end)
    helpers.it("exports load_all", function()
      helpers.assert_true(type(config.load_all) == "function", "load_all is a function")
    end)
    helpers.it("exports reload", function()
      helpers.assert_true(type(config.reload) == "function", "reload is a function")
    end)
    helpers.it("exports disable_group", function()
      helpers.assert_true(type(config.disable_group) == "function", "disable_group is a function")
    end)
    helpers.it("exports enable_group", function()
      helpers.assert_true(type(config.enable_group) == "function", "enable_group is a function")
    end)
    helpers.it("exports toggle_group", function()
      helpers.assert_true(type(config.toggle_group) == "function", "toggle_group is a function")
    end)
    helpers.it("exports get_groups", function()
      helpers.assert_true(type(config.get_groups) == "function", "get_groups is a function")
    end)
    helpers.it("exports mapping_count", function()
      helpers.assert_true(type(config.mapping_count) == "function", "mapping_count is a function")
    end)
  end)

  -- ==========================================================================
  -- 2. init()
  -- ==========================================================================

  helpers.describe("init()", function()
    -- Called directly, not through pcall: a raise fails the case with the real
    -- error, which says more than a boolean. What each case asserts instead is
    -- what init LEFT BEHIND — a config module that swallowed its engine and
    -- initialised nothing passes "does not crash" and expands nothing at runtime.
    helpers.it("init with a valid engine leaves the module usable", function()
      local engine = make_engine()
      config.init(engine)
      helpers.assert_eq(type(config.is_group_enabled("anything")), "boolean",
        "after init the group reader must answer")
    end)

    helpers.it("init with an explicit config directory leaves the module usable", function()
      local engine = make_engine()
      config.init(engine, "/tmp")
      helpers.assert_eq(type(config.is_group_enabled("anything")), "boolean",
        "an explicit directory must not change whether the module answers")
    end)

    helpers.it("init with a nil config dir falls back to XDG and still answers", function()
      local engine = make_engine()
      config.init(engine, nil)
      helpers.assert_eq(type(config.is_group_enabled("anything")), "boolean",
        "the XDG fallback is the default path — if it left the module mute, every "
          .. "install with no explicit directory would silently expand nothing")
    end)
  end)

  -- ==========================================================================
  -- 3. load_all() — no TOML files case (tests robustness, not correctness)
  -- ==========================================================================

  helpers.describe("load_all()", function()
    helpers.it("load_all without init returns 0 gracefully", function()
      -- Reset module state by re-requiring.
      local cfg = helpers.load_module("modules.hotstrings.hotstrings_config")
      local count = cfg.load_all()
      helpers.assert_eq(count, 0, "returns 0 without init")
    end)

    helpers.it("a user directory that does not exist still loads the bundled packs", function()
      -- Discovery is independent of opt-in. Isolate the canonical choices so
      -- explicit activation cannot leak into other cases or depend on their state.
      local previous_config = package.loaded["modules.hotstrings.hotstrings_config"]
      local ok, err = pcall(function()
        local cfg = helpers.load_module("modules.hotstrings.hotstrings_config")
        require("tests.support.hotstring_choices").with_file(cfg, nil, function()
          local engine = make_engine()
          cfg.init(engine, os.tmpname() .. "_absent_hotstring_directory")
          cfg.load_all()

          local Loader = require("modules.hotstrings.loader")
          local Paths = require("infra.paths")
          local bundled = Loader.find_toml_files(Paths.shared("modules/hotstrings"))
          helpers.assert_true(#bundled > 0, "fixture requires the actual bundled TOML inventory")
          helpers.assert_true(cfg.mapping_count() > 0,
            "an absent personal directory must not hide discovered bundled mappings")

          helpers.assert_true(cfg.disable_all() ~= false, "explicit group disable must commit")
          helpers.assert_eq(#engine._loaded, 0, "disabled groups must leave no effective engine mappings")
          helpers.assert_true(cfg.mapping_count() > 0,
            "the discovered inventory must remain available while its groups are disabled")
          helpers.assert_true(cfg.enable_all() ~= false, "explicit group and section activation must commit")
          helpers.assert_true(#engine._loaded > 0,
            "explicit activation must hand the discovered mappings to the real engine")

          -- Replay an actual bundled trigger through the real matcher: recording a
          -- non-empty argument alone would miss an engine that ignores publication.
          local matched = false
          for _, mapping in ipairs(engine._loaded) do
            if mapping.auto_expand then
              engine:reset()
              local result
              for char in mapping.trigger:gmatch("[%z\1-\127\194-\244][\128-\191]*") do
                result = engine:on_char(char)
              end
              if result and result.trigger == mapping.trigger and result.group == mapping.group then
                matched = true
                break
              end
            end
          end
          helpers.assert_true(matched, "the real engine must execute an explicitly activated bundled trigger")
        end)
      end)
      package.loaded["modules.hotstrings.hotstrings_config"] = previous_config
      if not ok then error(err, 0) end
    end)
  end)

  -- ==========================================================================
  -- 4. Group enable/disable
  -- ==========================================================================

  helpers.describe("group management", function()
    local Choices = require("tests.support.hotstring_choices")
    local Codec = require("toml_codec")

    --- A config manager over one real catalogue group and a private config.toml.
    --- @param source string|table|nil Initial choices.
    --- @param body function body(cfg, engine, path)
    local function with_groups(source, body)
      local saved_loader = package.loaded["modules.hotstrings.loader"]
      package.loaded["modules.hotstrings.loader"] = {
        find_toml_files = function() return {} end,
        list_subdirs = function() return {} end,
        read_file = function() return nil end,
        load_catalogue = function()
          return { committed = true, errors = 0,
            categories = { probe = { id = "probe", sections = {}, sections_order = {} },
              ["ext:demo:pack"] = { id = "ext:demo:pack", sections = { main = { count = 1 } }, sections_order = { "main" } } },
            mappings = { { trigger = "pq", replacement = "probe-result", group = "probe", auto_expand = true },
              { trigger = "xq", replacement = "pack-result", group = "ext:demo:pack", section = "main", auto_expand = true } } }
        end,
      }
      local ok, err = pcall(function()
        local cfg = helpers.load_module("modules.hotstrings.hotstrings_config")
        Choices.with_file(cfg, source, function(path)
          local engine = make_engine()
          helpers.assert_true(cfg.init(engine, "virtual.toml"), "the private choices must be readable")
          local _, committed = cfg.load_all()
          helpers.assert_true(committed, "the fixture catalogue must publish")
          body(cfg, engine, path)
        end)
      end)
      package.loaded["modules.hotstrings.loader"] = saved_loader
      package.loaded["modules.hotstrings.hotstrings_config"] = nil
      if not ok then error(err, 0) end
    end

    local function fires(engine, trigger, replacement)
      engine:reset()
      local result
      for char in (trigger or "pq"):gmatch(".") do result = engine:on_char(char) end
      return result ~= nil and result.replacement == (replacement or "probe-result")
    end

    helpers.it("an empty configuration leaves every category off and unwritten", function()
      with_groups(nil, function(cfg, engine, path)
        helpers.assert_eq(cfg.is_group_enabled("probe"), false)
        helpers.assert_eq(fires(engine), false, "a neutral category must not expand")
        helpers.assert_nil(Choices.read(path), "reading choices never writes")
      end)
    end)

    helpers.it("enable_group publishes the category to the engine and config.toml", function()
      with_groups("[hotstrings]\nunknown = \"kept\"\n[other]\nvalue = 1\n", function(cfg, engine, path)
        helpers.assert_true(cfg.enable_group("probe"))
        helpers.assert_eq(cfg.is_group_enabled("probe"), true)
        helpers.assert_true(fires(engine), "the enabled category must reach the real engine")
        local decoded = Codec.decode(Choices.read(path))
        helpers.assert_eq(decoded.hotstrings.groups.probe, true)
        helpers.assert_eq(decoded.hotstrings.unknown, "kept", "unknown neighbours survive")
        helpers.assert_eq(decoded.other.value, 1, "unknown tables survive")
      end)
    end)

    helpers.it("disable_group returns the category to its neutral absence", function()
      with_groups({ probe = true, foreign = true }, function(cfg, engine, path)
        helpers.assert_true(fires(engine))
        helpers.assert_true(cfg.disable_group("probe"))
        helpers.assert_eq(cfg.is_group_enabled("probe"), false)
        helpers.assert_eq(fires(engine), false, "a disabled category must leave the engine")
        local decoded = Codec.decode(Choices.read(path))
        helpers.assert_nil(decoded.hotstrings.groups.probe, "the neutral value is removed, not repeated")
        helpers.assert_eq(decoded.hotstrings.groups.foreign, true, "an unknown category choice survives")
      end)
    end)

    helpers.it("toggle_group inverts the state it found and survives a restart", function()
      with_groups(nil, function(cfg, engine, path)
        helpers.assert_true(cfg.toggle_group("probe"))
        helpers.assert_eq(cfg.is_group_enabled("probe"), true,
          "a toggle that lands on the same state is a menu row that does nothing")
        helpers.assert_true(cfg.init(make_engine(), "virtual.toml"), "a restart rereads the choices")
        helpers.assert_eq(cfg.is_group_enabled("probe"), true, "the choice is durable")
        helpers.assert_eq(Codec.decode(Choices.read(path)).hotstrings.groups.probe, true)
        helpers.assert_true(fires(engine))
      end)
    end)

    helpers.it("disable_group(nil) changes nothing", function()
      with_groups({ probe = true }, function(cfg, _, path)
        local before = Choices.read(path)
        helpers.assert_eq(cfg.disable_group(nil), false, "a nil group name must be refused")
        helpers.assert_eq(cfg.is_group_enabled("probe"), true,
          "a nil group name must not be applied to whatever was last touched")
        helpers.assert_eq(Choices.read(path), before)
      end)
    end)

    helpers.it("is_group_enabled returns boolean", function()
      local result = config.is_group_enabled("any_group")
      helpers.assert_true(type(result) == "boolean", "returns boolean")
    end)

    helpers.it("republishes the previous catalogue when the write is refused", function()
      with_groups({ probe = true }, function(cfg, engine, path)
        local Writer = require("toml_codec.writer")
        local original = Writer.batch_write
        Writer.batch_write = function() return false, "injected refusal" end
        local ok, changed = pcall(cfg.disable_group, "probe")
        Writer.batch_write = original
        helpers.assert_true(ok, tostring(changed))
        helpers.assert_eq(changed, false, "a failed write must be reported")
        helpers.assert_eq(cfg.is_group_enabled("probe"), true,
          "a failed write must not publish a disabled group only for this session")
        helpers.assert_true(fires(engine), "the engine must be back on the previous catalogue")
        helpers.assert_eq(Codec.decode(Choices.read(path)).hotstrings.groups.probe, true)
      end)
    end)

    helpers.it("refuses a write that an external editor raced", function()
      with_groups({ probe = true }, function(cfg, engine, path)
        local Writer = require("toml_codec.writer")
        local original = Writer.batch_write
        local external = "[hotstrings]\ngroups = { probe = true }\nexternal = 9\n"
        Writer.batch_write = function(...)
          local handle = assert(io.open(path, "w"))
          handle:write(external)
          handle:close()
          return original(...)
        end
        local ok, changed = pcall(cfg.disable_group, "probe")
        Writer.batch_write = original
        helpers.assert_true(ok, tostring(changed))
        helpers.assert_eq(changed, false, "a lost race must be refused")
        helpers.assert_eq(Choices.read(path), external, "the external edit wins")
        helpers.assert_true(fires(engine), "the runtime keeps the published choice")
      end)
    end)

    -- A bundled toggle writes the [hotstrings.groups] header; the extension pack
    -- used to be refused under it for good, and enable_all with it.
    helpers.it("switches an extension pack after a bundled toggle created the groups header", function()
      with_groups(nil, function(cfg, engine, path)
        helpers.assert_true(cfg.enable_group("probe"))
        helpers.assert_true(Choices.read(path):find("[hotstrings.groups]", 1, true) ~= nil, "the header exists")
        helpers.assert_true(cfg.enable_group("ext:demo:pack"), "the extension pack is switchable under it")
        helpers.assert_true(cfg.disable_group("ext:demo:pack"))
        helpers.assert_eq(cfg.enable_all(), 2, "enable_all covers the extension gate and section")
        helpers.assert_true(fires(engine, "xq", "pack-result"))
        helpers.assert_true(fires(engine))
        local decoded = Codec.decode(Choices.read(path))
        helpers.assert_eq(decoded.hotstrings.groups["ext:demo:pack"], true)
        helpers.assert_eq(decoded.hotstrings.groups.probe, true)
      end)
    end)

    helpers.it("persists an extension identity as a quoted key and reads it back", function()
      with_groups(nil, function(cfg, engine, path)
        helpers.assert_true(cfg.set_all_sections("ext:demo:pack", true))
        helpers.assert_true(fires(engine, "xq", "pack-result"), "the extension section must reach the engine")
        local bytes = Choices.read(path)
        helpers.assert_true(bytes:find('"ext:demo:pack" = true', 1, true) ~= nil, "the identity is a quoted key")
        local decoded = Codec.decode(bytes)
        helpers.assert_eq(decoded.hotstrings.groups["ext:demo:pack"], true)
        helpers.assert_eq(decoded.hotstrings.modules["ext:demo:pack"].main, true)
        helpers.assert_true(cfg.init(make_engine(), "virtual.toml"))
        helpers.assert_eq(cfg.is_section_enabled("ext:demo:pack", "main"), true, "the choice survives a restart")
      end)
    end)

    helpers.it("never gates provider mappings a second time", function()
      with_groups(nil, function(cfg, engine)
        helpers.assert_true(cfg.set_extra_mappings_provider(function()
          return { { trigger = "dq", replacement = "dynamic-result", group = "dynamichotstrings",
            section = "phoneprefixes", auto_expand = true } }
        end))
        local _, committed = cfg.load_all()
        helpers.assert_true(committed)
        helpers.assert_eq(cfg.is_group_enabled("dynamichotstrings"), false, "no catalogue choice enables it")
        helpers.assert_true(fires(engine, "dq", "dynamic-result"),
          "the provider already applied its own switches; its mappings reach the engine")
        helpers.assert_eq(fires(engine), false, "catalogue mappings stay behind their neutral gate")
      end)
    end)

    helpers.it("marks only the choices of loaded categories as consumed", function()
      with_groups(nil, function(cfg)
        local marked = {}
        cfg.mark_config_reads(Codec.decode('[hotstrings]\ngroups = { probe = true, gone = true }\n'
          .. '[hotstrings.modules.probe]\nmissing = true\n[hotstrings.modules."ext:demo:pack"]\nmain = false\n'),
          function(...) marked[#marked + 1] = table.concat({ ... }, ".") end)
        table.sort(marked)
        helpers.assert_eq(marked, { "hotstrings.groups.probe", "hotstrings.modules.ext:demo:pack.main" })
      end)
    end)

    --- Runs the cleanup marker of a manager whose catalogue loads `categories`,
    --- recording every outdated-entry warning.
    --- @param opts table { categories, config_dir, publish }.
    --- @param source string config.toml bytes to scan.
    --- @return table offered Sorted dotted paths the cleanup offers.
    --- @return table warnings Outdated-entry warnings logged.
    local function cleanup_offers(opts, source)
      local saved_loader, saved_logger = package.loaded["modules.hotstrings.loader"], package.loaded["logger.shim"]
      local warnings = {}
      local logger = helpers.make_logger_stub()
      logger.warn = function(_, fmt, ...) warnings[#warnings + 1] = string.format(fmt, ...) end
      package.loaded["logger.shim"] = logger
      package.loaded["modules.hotstrings.loader"] = {
        find_toml_files = function() return {} end,
        list_subdirs = function() return {} end,
        read_file = function() return nil end,
        load_catalogue = function()
          return { committed = true, errors = 0, categories = opts.categories, mappings = {} }
        end,
      }
      local offered = {}
      local ok, err = pcall(function()
        require("config_outdated").reset_for_tests()
        local cfg = helpers.load_module("modules.hotstrings.hotstrings_config")
        Choices.with_file(cfg, source, function()
          local engine = make_engine()
          if not opts.publish then engine.load_mappings = function() return false end end
          helpers.assert_true(cfg.init(engine, opts.config_dir), "the private choices must be readable")
          local _, committed, reason = cfg.load_all()
          helpers.assert_eq(committed, opts.publish == true, tostring(reason))
          for _, key in ipairs(require("config_unused_keys").find_in_source(source, cfg.mark_config_reads).keys) do
            offered[#offered + 1] = key.section .. "." .. key.key
          end
        end)
      end)
      package.loaded["modules.hotstrings.loader"] = saved_loader
      package.loaded["logger.shim"] = saved_logger
      package.loaded["modules.hotstrings.hotstrings_config"] = nil
      if not ok then error(err, 0) end
      table.sort(offered)
      return offered, warnings
    end

    helpers.it("offers no choice when the catalogue publication was refused (config-outdated-unpublished)", function()
      -- A refused publication leaves no catalogue: judging choices against it
      -- offered every real setting for deletion and warned it as outdated.
      local source = "[hotstrings.groups]\nprobe = false\nrolls = true\n\n[hotstrings.modules.rolls]\nhc = false\n"
      local offered, warnings = cleanup_offers({ config_dir = "virtual.toml", publish = false,
        categories = { probe = { id = "probe", sections = {}, sections_order = {} } } }, source)
      helpers.assert_eq(offered, {})
      helpers.assert_eq(warnings, {})
    end)

    helpers.it("judges a same-stem override's sections against the build (config-outdated-override)", function()
      -- The user's rolls.toml holds only its own section; the bundled hc
      -- section still ships, so its choice is kept. A bundled category that
      -- really lost a section still has that choice offered.
      local dir = (os.getenv("TMPDIR") or "/tmp"):gsub("/+$", "") .. "/ergopti_override_probe"
      local source = "[hotstrings.modules.rolls]\nhc = false\nown = true\n\n[hotstrings.modules.probe]\ngone = true\n"
      local offered, warnings = cleanup_offers({ config_dir = dir, publish = true, categories = {
        rolls = { id = "rolls", path = dir .. "/rolls.toml", sections = { own = { count = 1 } }, sections_order = { "own" } },
        probe = { id = "probe", path = "/bundled/probe.toml", sections = {}, sections_order = {} },
      } }, source)
      helpers.assert_eq(offered, { "hotstrings.modules.probe.gone" })
      helpers.assert_eq(#warnings, 1, table.concat(warnings, " | "))
      helpers.assert_true(warnings[1]:find("'hotstrings.modules.probe.gone'", 1, true) ~= nil, warnings[1])
    end)

    helpers.it("ignores an old-shape choice without guessing it or refusing the catalogue (config-outdated-hotstrings)", function()
      -- An old-shape choice is outdated configuration: never guessed ("yes" is
      -- not a switch), never a refusal that turns every hotstring off. The
      -- fixture asserts that init reads the choices and the catalogue publishes.
      local source = "[hotstrings]\ngroups = { probe = \"yes\" }\n"
      with_groups(source, function(cfg, engine, path)
        helpers.assert_eq(cfg.is_group_enabled("probe"), false, "the outdated choice is not guessed")
        helpers.assert_eq(fires(engine, "pq", "probe-result"), false, "the category keeps its neutral gate")
        helpers.assert_eq(Choices.read(path), source, "the file is left for the config cleanup")
      end)
    end)

    helpers.it("an empty category key is outdated, not a refused initialisation (config-outdated-empty-key)", function()
      -- Reporting "" raised from the choice decoder: init failed and every
      -- hotstring stayed off, the very failure the outdated rule removes.
      local source = "[hotstrings.groups]\n\"\" = \"on\"\nprobe = true\n"
      with_groups(source, function(cfg, engine)
        helpers.assert_eq(cfg.is_group_enabled("probe"), true, "the valid neighbour still applies")
        helpers.assert_true(fires(engine), "the valid neighbour reaches the engine")
      end)
    end)

    helpers.it("names once the override entries of a retired category or section (config-outdated-overrides)", function()
      -- They were kept and ignored in silence for good: no reset rewrites
      -- them, and the config cleanup never reads this file.
      local dir = (os.getenv("TMPDIR") or "/tmp"):gsub("/+$", "") .. "/ergopti_overrides_probe"
      os.execute("mkdir -p '" .. dir .. "'")
      local fh = assert(io.open(dir .. "/hotstrings_overrides.toml", "w"))
      fh:write("[_global]\ndelay = 0.3\n[probe]\ndelay = 0.2\n[probe.main]\ndelay = 0.1\n"
        .. "[probe.gone_section]\ndelay = 0.1\n[retired_category]\ndelay = 0.5\n")
      fh:close()
      local saved_loader, saved_logger = package.loaded["modules.hotstrings.loader"], package.loaded["logger.shim"]
      local warnings = {}
      local logger = helpers.make_logger_stub()
      logger.warn = function(_, fmt, ...) warnings[#warnings + 1] = string.format(fmt, ...) end
      package.loaded["logger.shim"] = logger
      package.loaded["modules.hotstrings.loader"] = {
        find_toml_files = function() return {} end,
        list_subdirs = function() return {} end,
        read_file = function() return nil end,
        load_catalogue = function()
          return { committed = true, errors = 0, mappings = {}, categories = {
            probe = { id = "probe", path = "/bundled/probe.toml", sections = { main = { count = 1 } }, sections_order = { "main" } },
          } }
        end,
      }
      local ok, err = pcall(function()
        require("config_outdated").reset_for_tests()
        local cfg = helpers.load_module("modules.hotstrings.hotstrings_config")
        cfg._set_override_config_dir_for_test(dir)
        Choices.with_file(cfg, nil, function()
          helpers.assert_true(cfg.init(make_engine(), dir .. "/hotstrings"))
          local _, committed = cfg.load_all()
          helpers.assert_true(committed)
          local text = table.concat(warnings, "\n")
          helpers.assert_eq(#warnings, 2, text)
          helpers.assert_contains(text, "'retired_category' in '" .. dir .. "/hotstrings_overrides.toml'")
          helpers.assert_contains(text, "'probe.gone_section' in '" .. dir .. "/hotstrings_overrides.toml'")
          cfg.load_all()
          helpers.assert_eq(#warnings, 2, "a reload does not name them again")
        end)
        cfg._set_override_config_dir_for_test(nil)
      end)
      package.loaded["modules.hotstrings.loader"] = saved_loader
      package.loaded["logger.shim"] = saved_logger
      package.loaded["modules.hotstrings.hotstrings_config"] = nil
      os.execute("rm -rf '" .. dir .. "'")
      if not ok then error(err, 0) end
    end)
  end)

  -- ==========================================================================
  -- 5. Queries
  -- ==========================================================================

  helpers.describe("queries", function()
    helpers.it("mapping_count returns number", function()
      local n = config.mapping_count()
      helpers.assert_true(type(n) == "number", "returns number")
    end)

    helpers.it("parse_error_count returns number", function()
      local n = config.parse_error_count()
      helpers.assert_true(type(n) == "number", "returns number")
    end)

    helpers.it("get_config_dir returns string or nil", function()
      local d = config.get_config_dir()
      helpers.assert_true(d == nil or type(d) == "string", "returns string or nil")
    end)

    helpers.it("get_groups returns table", function()
      local groups = config.get_groups()
      helpers.assert_true(type(groups) == "table", "returns table")
    end)
  end)

  -- ==========================================================================
  -- 6. reload()
  -- ==========================================================================

  helpers.describe("reload()", function()
    helpers.it("reload leaves the module answering", function()
      config.reload()
      helpers.assert_eq(type(config.is_group_enabled("anything")), "boolean",
        "reload runs on every config-file change; one that left the module mute would "
          .. "stop every expansion until the next restart")
    end)
  end)

end)
