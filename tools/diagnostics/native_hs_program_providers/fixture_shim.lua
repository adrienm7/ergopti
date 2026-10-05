-- tools/diagnostics/native_hs_program_providers/fixture_shim.lua
-- Owned native Hammerspoon fixture: inventory and metadata only, never execution.
local input = hs.json.decode(__INPUT_JSON__)
local native_fs, native_open = hs.fs, io.open
local source = input.source_root
package.path = source .. "/static/ergopti_plus/macos/?.lua;" .. source .. "/static/ergopti_plus/macos/?/init.lua;"
    .. source .. "/static/ergopti_plus/_shared/lua/?.lua;" .. source .. "/static/ergopti_plus/_shared/lua/?/init.lua;" .. package.path
local configured = input.config
local logs = 0
local logger = setmetatable({}, { __index = function() return function() logs = logs + 1 end end })
package.loaded["infra.logger"] = logger
package.loaded["infra.config_paths"] = { get_config_dir = function() return configured end }
package.loaded["infra.paths"] = { shared = function(relative)
    return source .. "/static/ergopti_plus/_shared/" .. relative
end }
local Adapter = require("adapters.program_providers")
local Directories = require("infra.fs_dir")
local cases = {}
local function check(condition) if condition ~= true then error("case_refused", 0) end end
local function case(id, callback)
    local ok = pcall(callback)
    cases[#cases + 1] = { id = id, status = ok and "passed" or "failed" }
end
local function source_pins()
    for path, digest in pairs(input.source_hashes) do
        local handle = assert(native_open(source .. "/" .. path, "rb"))
        local raw = assert(handle:read("*a")); check(handle:close() == true)
        check(hs.hash.SHA256(raw) == digest)
    end
end
local function count(table_value)
    local result = 0; for _ in pairs(table_value) do result = result + 1 end; return result
end
local function choices_by_name(result)
    local values = {}; for _, choice in ipairs(result.choices) do
        check(values[choice.label] == nil); values[choice.label] = choice
    end; return values
end
local function fd_count()
    local result = 0
    for name in native_fs.dir("/dev/fd") do if name ~= "." and name ~= ".." then result = result + 1 end end
    return result
end
case("actual_native_runtime", function()
    check(_VERSION == "Lua 5.4" and debug.getinfo(native_fs.attributes).what == "C")
    check(hs.screen.mainScreen() ~= nil and io.open == native_open)
end)
case("exact_source_pins_before", source_pins)
case("real_system_shim_present", function()
    local attributes = assert(native_fs.attributes("/usr/bin/python3"))
    check(attributes.mode == "file" and attributes.permissions:find("x", 1, true) ~= nil)
    check(os.getenv("PATH") == "/usr/bin:/bin")
end)
case("fixed_system_python_shim_is_not_installed_provider", function()
    local owner = assert(Adapter.create()); local result = assert(owner.discover())
    local found = false
    for _, provider in ipairs(result.providers) do
        if provider.id == "python" then found = true; check(provider.available == false) end
    end
    check(found and #result.choices == 3)
    check(choices_by_name(result)["literal.py"] == nil and logs == 0)
    check(owner.invalidate() == true)
end)
case("exact_source_pins_after", source_pins)
local passed = 0; for _, result in ipairs(cases) do if result.status == "passed" then passed = passed + 1 end end
local packet = {
    schema = 1, contract = "macos-native-hs-program-providers", source_sha = input.source_sha,
    nonce = input.nonce, pid = hs.processInfo.processID, scenario = input.scenario,
    source_hashes = input.source_hashes, cases = cases,
    counts = { passed = passed, failed = #cases - passed, skipped = 0 },
    scope = { inventory = true, program_execution = false, effective_acl_verified = false,
        closedir_errno_observed = false, atomic_execution_lease = false },
}
local output = assert(native_open(input.receipt .. ".partial", "wb"))
check(output:write(hs.json.encode(packet)) ~= nil); check(output:close() == true)
check(os.rename(input.receipt .. ".partial", input.receipt) == true)
hs.timer.doAfter(0.01, function() os.exit(passed == #cases and 0 or 1) end)
