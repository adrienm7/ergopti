--- tests/unit/ui/menu/test_runtime_recovery_constructor_ports.lua

--- ==============================================================================
--- MODULE: Original Native Recovery Constructor Ports
--- DESCRIPTION:
--- Ordinary native constructors retain publisher and owned reload roles despite
--- pre-use public export substitution. The existing parser tuple stays ordered.
--- ==============================================================================

local helpers = require("tests.helpers")
local fixture = require("tests.support.runtime_recovery_fixture")
local OWNED = '[karabiner]\nruntime = "owned"\nintegration_enabled = true\n[future]\nrevision = 29\n'

helpers.describe("Original native recovery constructor tuples", function()
 helpers.it("Config extends first six original parser roles with original save and pure admission",function()
  fixture.with_source(OWNED,function()
  local config=require("platform.remap.config")
  local ports=table.pack(config.parser_refusal_factory())
  helpers.assert_eq(ports.n,8);helpers.assert_eq(ports[1],config)
  helpers.assert_eq(ports[2],config.load_user_config);helpers.assert_eq(ports[3],config._load_toml_file)
  helpers.assert_eq(ports[4],require("infra.toml.codec").decode_with_shapes)
  helpers.assert_eq(ports[7],config.save_runtime);helpers.assert_eq(type(ports[8]),"function")
  helpers.assert_eq(ports[8](),true)
  local original=config.save_runtime;config.save_runtime=config.load_user_config
  local again=table.pack(config.parser_refusal_factory())
  local called, failure=pcall(function()
   for index=1,8 do helpers.assert_eq(again[index],ports[index]) end
   helpers.assert_eq(again[8](),false)
  end)
  config.save_runtime=original
  if not called then error(failure,0) end
  end)
 end)
 helpers.it("terminal constructor retains actual owned reload and pending roles",function()
  local terminal=require("infra.termination_coordinator")
  local owner,reload,pending=terminal.owned_reload_ports()
  helpers.assert_eq(owner,terminal);helpers.assert_eq(reload,terminal.request_reload_owned);helpers.assert_eq(pending,terminal.is_pending)
  local original=terminal.request_reload_owned;terminal.request_reload_owned=terminal.request_reload
  local again,original_reload,original_pending=terminal.owned_reload_ports()
  terminal.request_reload_owned=original
  helpers.assert_eq(again,owner);helpers.assert_eq(original_reload,reload);helpers.assert_eq(original_pending,pending)
 end)
end)
