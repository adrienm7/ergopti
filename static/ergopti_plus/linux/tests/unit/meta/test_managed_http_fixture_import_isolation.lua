--- tests/unit/meta/test_managed_http_fixture_import_isolation.lua

--- ==============================================================================
--- MODULE: Test Managed Http Fixture Import Isolation
--- DESCRIPTION:
--- Preserves independent managed-network controls and actual production imports.
--- Source registration alone does not qualify native or installed behavior.
--- ==============================================================================

--- Independent fixture-loader controls; no transport or successor is dispatched.
local helpers = require("tests.helpers")
local driver = helpers.driver_root()
local fixtures = {
    { path = "tests/support/managed_http_native_ports.lua", exported = true, target = "adapters/http_client.lua", policy = true,
      names = { "luv", "adapters.http_client", "adapters.curl_http_client", "adapters.system_proxy", "infra.proxy_policy", "infra.managed_http", "infra.monotonic", "infra.managed_http_deadline", "infra.paths" } },
    { path = "tests/unit/adapters/test_managed_http_public.lua", target = "adapters/http_client.lua", policy = true,
      names = { "luv", "adapters.http_client", "adapters.curl_http_client", "adapters.system_proxy", "infra.proxy_policy", "infra.managed_http", "infra.monotonic", "infra.managed_http_deadline", "infra.paths" } },
    { path = "tests/unit/infra/test_managed_http_aggregate_cancel.lua", target = "adapters/http_client.lua", policy = true,
      names = { "luv", "adapters.http_client", "adapters.curl_http_client", "adapters.system_proxy", "infra.proxy_policy", "infra.managed_http", "infra.monotonic", "infra.managed_http_deadline", "infra.paths" } },
    { path = "tests/unit/infra/test_managed_http_deadline_arm.lua", target = "adapters/http_client.lua", policy = true,
      names = { "luv", "adapters.http_client", "adapters.curl_http_client", "adapters.system_proxy", "infra.proxy_policy", "infra.managed_http", "infra.monotonic", "infra.managed_http_deadline", "infra.paths" } },
    { path = "tests/unit/infra/test_managed_http_queued_deadline.lua", target = "adapters/http_client.lua", policy = true,
      names = { "luv", "adapters.http_client", "adapters.curl_http_client", "adapters.system_proxy", "infra.proxy_policy", "infra.managed_http", "infra.monotonic", "infra.managed_http_deadline", "infra.paths" } },
    { path = "tests/unit/adapters/test_system_proxy.lua", target = "adapters/system_proxy.lua", config = { nil_driver_root = true },
      names = { "luv", "infra.paths" } },
    { path = "tests/unit/adapters/test_system_proxy_callbacks.lua", target = "adapters/system_proxy.lua", config = { nil_driver_root = true, logs = true },
      names = { "luv", "infra.paths", "logger.shim" } },
    { path = "tests/unit/adapters/test_system_proxy_runtime_executable.lua", target = "adapters/system_proxy.lua", config = { nil_driver_root = true },
      names = { "luv", "infra.paths" } },
    { path = "tests/unit/infra/test_managed_http_deadline.lua", target = "infra/managed_http_deadline.lua",
      names = { "luv", "infra.monotonic", "logger.shim" } },
}

--- Captures the actual fixture's lexical loader without executing its tests.
local function loader(fixture)
    local registered = {}
    local recorder = {}
    for name, value in pairs(helpers) do recorder[name] = value end
    recorder.it = function(_, callback) registered[#registered + 1] = callback end
    recorder.describe = function(_, callback) callback() end
    local saved = package.loaded["tests.helpers"]
    package.loaded["tests.helpers"] = recorder
    local ok, result = pcall(dofile, driver .. "/" .. fixture.path)
    package.loaded["tests.helpers"] = saved
    if not ok then error(result, 0) end
    if fixture.exported then return assert(result.fresh_client) end
    for _, callback in ipairs(registered) do
        local index = 1
        while true do
            local name, value = debug.getupvalue(callback, index)
            if not name then break end
            if (name == "fresh_client" or name == "fresh") and type(value) == "function" then return value end
            index = index + 1
        end
    end
    error("The fixture must expose its actual lexical import loader", 0)
end

--- Restores this control's own temporary globals and modules on every outcome.
local function exercise(fixture, fresh, kind, phase)
    local before, expected = {}, {}
    for _, name in ipairs(fixture.names) do
        before[name] = package.loaded[name]
        if kind == "table" then expected[name] = { fixed_fixture_identity = name }
        elseif kind == "false" then expected[name] = false end
        package.loaded[name] = expected[name]
    end
    local native_dofile = dofile
    local marker = { fixed_fixture_import_failure = true }
    local intercepted = 0
    if phase ~= "success" then
        _G.dofile = function(path)
            local selected = phase == "policy_failure" and path:match("/lua/network/proxy_policy%.lua$")
                or phase == "import_failure" and path == driver .. "/" .. fixture.target
            if selected then intercepted = intercepted + 1; error(marker, 0) end
            return native_dofile(path)
        end
    end
    local ok, problem = pcall(function()
        local admitted, result = pcall(fresh, fixture.config or {})
        if phase == "success" then
            helpers.assert_true(admitted, "The unchanged actual fixture loader remains usable")
            helpers.assert_eq(type(result), "table")
        else
            helpers.assert_eq(admitted, false, "Actual import refusal must propagate")
            helpers.assert_eq(result, marker, "The exact failure object must survive finally restoration")
            helpers.assert_eq(intercepted, 1, "Exactly the selected import boundary must fail")
        end
        for _, name in ipairs(fixture.names) do
            helpers.assert_eq(package.loaded[name], expected[name], "Restore exact " .. kind .. " snapshot for " .. name)
        end
    end)
    _G.dofile = native_dofile
    for _, name in ipairs(fixture.names) do package.loaded[name] = before[name] end
    if not ok then error(problem, 0) end
end

helpers.describe("managed HTTP fixture import isolation", function()
    for _, kind in ipairs({ "nil", "false", "table" }) do
        helpers.it("fixture-import-finally: preserves " .. kind .. " module snapshots after success and actual import refusal", function()
            for _, fixture in ipairs(fixtures) do
                local fresh = loader(fixture)
                exercise(fixture, fresh, kind, "success")
                exercise(fixture, fresh, kind, "import_failure")
                if fixture.policy then exercise(fixture, fresh, kind, "policy_failure") end
            end
        end)
    end
end)
