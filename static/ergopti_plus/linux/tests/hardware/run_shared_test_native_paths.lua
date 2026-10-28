--- tests/hardware/run_shared_test_native_paths.lua
--- ==============================================================================
--- MODULE: Native Shared Test Path Consumer
--- DESCRIPTION:
--- Runs real shared contracts under physical POSIX prefixes, without LuaFileSystem.
--- No replacement module exports or synthetic filesystem receipts admit a path.
--- ==============================================================================

local repository, mode = assert(arg[1]), assert(arg[2])
local driver = repository .. "/static/ergopti_plus/linux"
local shared = repository .. "/static/ergopti_plus/_shared/lua"
package.path = table.concat({ driver .. "/?.lua", driver .. "/?/init.lua",
    shared .. "/?.lua", shared .. "/?/init.lua", driver .. "/tests/?.lua",
    driver .. "/tests/?/init.lua", package.path }, ";")
require("compat.utf8").install()
local uv = require("luv")
assert(not pcall(require, "lfs"), "the actual child provider must not contain LuaFileSystem")
local helpers = require("tests.helpers")
local ok, failure = xpcall(function()
    if mode == "outdated" then
        helpers.set_only_filter("replays the independent process-lifetime file warning sequence")
        require("test.config_outdated_contract").register(helpers)
    elseif mode == "chords" then
        require("test.key_combination_chords_contract").register(helpers)
    elseif mode == "override_parser" then
        require("test.hotstring_override_parser_contract")(helpers)
    elseif mode == "terminators" then
        helpers.set_only_filter("replays independent personal preservation vectors")
        require("test.terminator_scope_contract")(helpers,
            require("modules.hotstrings.terminator_settings").builtin_state_leaves)
    elseif mode == "migration_records" then
        helpers.set_only_filter("occupied: lf")
        require("test.config_migrate_records_contract").register(helpers, { driver = "linux" })
    elseif mode == "scope_overrides" then
        require("test.hotstrings_scope_overrides_contract")(helpers)
    elseif mode == "unused_sandbox" then
        helpers.it("native shared sandbox retains its actual temporary directory", function()
            local sandbox = require("test.config_unused_keys_contract").sandbox
            sandbox.with_config("owned-canary", function(path)
                helpers.assert_eq(sandbox.read_bytes(path), "owned-canary")
                helpers.assert_eq(require("native_path").dirname(path), os.getenv("TMPDIR"))
            end)
        end)
    elseif mode == "onboarding_sandbox" then
        helpers.set_only_filter("writes one versioned batch and never writes a refused one")
        require("test.onboarding_answers_contract").register(helpers, { driver = "linux" })
    elseif mode == "home_classifier" then
        helpers.it("native outside home is not accepted through a rewritten scratch root", function()
            local home, temporary = assert(os.getenv("HOME")), assert(os.getenv("TMPDIR"))
            local real_home, real_temporary = assert(uv.fs_realpath(home)), assert(uv.fs_realpath(temporary))
            helpers.assert_true(real_home ~= real_temporary
                and real_home:sub(1, #real_temporary + 1) ~= real_temporary .. "/",
                "the actual private directories must not share native containment")
            helpers.assert_eq(require("test.runner_home").is_scratch(home, os.getenv), false)
        end)
    elseif mode == "windows_model" then
        helpers.it("scratch containment retains modeled Windows separator behavior", function()
            local original = package.config
            local ran, detail = xpcall(function()
                package.config = "\\\n;\n?\n!\n-\n"
                local home = require("test.runner_home")
                local function environment(name)
                    if name == "TMPDIR" then return "C:\\Scratch\\" end
                end
                helpers.assert_eq(home.is_scratch("C:\\Scratch\\account", environment), true)
                helpers.assert_eq(home.is_scratch("C:/Scratch/account", environment), true)
                helpers.assert_eq(home.is_scratch("C:/Scratchpad/account", environment), false)
                helpers.assert_eq(home.is_scratch("C:\\Outside\\account", environment), false)
                helpers.assert_eq(require("native_path").without_trailing_separators("C:\\Scratch\\"), "C:\\Scratch")
            end, debug.traceback)
            package.config = original
            assert(ran, detail)
        end)
    else error("Unknown native shared test path case: " .. mode) end
end, debug.traceback)
local result = helpers.get_results()
assert(ok, failure)
assert(result.failed == 0 and result.passed > 0,
    "the actual shared contract must execute positive assertions and complete without failure")
print("Native shared test path case: " .. mode .. "; " .. result.passed .. " passed; 0 failed; genuine luv; no lfs")
