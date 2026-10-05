-- tools/diagnostics/native_hs_program_providers/fixture.lua
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
local owner, initial
case("actual_native_runtime", function()
    check(_VERSION == "Lua 5.4")
    check(debug.getinfo(native_fs.dir).what == "C")
    check(debug.getinfo(native_fs.attributes).what == "C")
    check(debug.getinfo(native_fs.symlinkAttributes).what == "C")
    check(debug.getinfo(native_fs.pathToAbsolute).what == "C")
    check(debug.getinfo(native_open).what == "C")
    check(hs.screen.mainScreen() ~= nil)
    check(type(hs.processInfo.processID) == "number" and hs.processInfo.processID > 0)
end)
case("exact_source_pins_before", source_pins)
case("inventory_independent_choices", function()
    owner = assert(Adapter.create()); initial = assert(owner.discover())
    local values = choices_by_name(initial)
    check(#initial.choices == 4 and initial.truncated == false)
    check(values[input.shell_name].provider == "shell")
    check(values["literal.bash"].provider == "bash")
    check(values["literal.py"].provider == "python")
    check(values["literal-tool"].provider == "executable")
    check(values["script-link.sh"] == nil and values["no-read.sh"] == nil)
    check(values["pipe.sh"] == nil and values["folder"] == nil)
end)
case("literal_v1_independent_argv", function()
    local choice = choices_by_name(initial)[input.shell_name]
    local arguments = { "", "日本", "e\204\129", "%PATH%", "'\"`", "$(touch INTERPOLATION)", "line\nnext" }
    local scalar = assert(owner.resolve(choice.key, arguments))
    -- The native JSON decoder is independent of the shared encoder/parser.
    local value = hs.json.decode(scalar)
    check(count(value) == 3 and value.version == 1 and value.executable == input.expected_sh)
    check(#value.arguments == 8 and value.arguments[1] == input.config .. "/scripts/" .. input.shell_name)
    for i, argument in ipairs(arguments) do check(value.arguments[i + 1] == argument) end
    check(native_fs.symlinkAttributes(input.config .. "/INTERPOLATION") == nil)
end)
case("real_interpreter_symlink", function()
    local value = hs.json.decode(assert(owner.resolve(choices_by_name(initial)["literal.py"].key, {})))
    check(value.executable == input.expected_python and #value.arguments == 1)
    check(value.arguments[1] == input.config .. "/scripts/literal.py")
end)
case("interpreter_link_retarget_is_stale", function()
    local key = choices_by_name(initial)["literal.py"].key
    check(os.rename(input.retarget_link, input.bin .. "/python3") == true)
    check(owner.resolve(key, {}) == nil)
    check(os.rename(input.restore_link, input.bin .. "/python3") == true)
    check(owner.invalidate() == true)
    initial = assert(owner.discover())
end)
case("replaced_script_is_stale", function()
    local key = choices_by_name(initial)[input.shell_name].key
    check(os.rename(input.replacement_script, input.config .. "/scripts/" .. input.shell_name) == true)
    check(owner.resolve(key, {}) == nil)
    check(owner.invalidate() == true)
end)
case("proven_missing_root_is_neutral", function()
    local scripts = input.config .. "/scripts"
    check(os.rename(scripts, input.absent_root) == true)
    local result = assert(owner.discover()); check(#result.choices == 0 and result.truncated == false)
    check(os.rename(input.absent_root, scripts) == true)
    check(owner.invalidate() == true)
end)
case("script_root_symlink_is_refused", function()
    local scripts = input.config .. "/scripts"
    check(os.rename(scripts, input.hidden_root) == true)
    check(os.rename(input.root_link, scripts) == true)
    check(owner.discover() == nil)
    check(os.remove(scripts) == true)
    check(os.rename(input.hidden_root, scripts) == true)
    check(owner.invalidate() == true)
end)
case("native_bounded_directory_loop", function()
    local listing = assert(Directories.collect_private(input.bounded, 256))
    check(#listing.names == 256 and listing.truncated == true)
end)
case("native_directory_close_observation", function()
    assert(Directories.collect_private(input.bounded, 256))
    local before = fd_count()
    for _ = 1, 64 do
        local listing = assert(Directories.collect_private(input.bounded, 2))
        check(#listing.names == 2 and listing.truncated == true)
    end
    check(fd_count() == before)
end)
case("native_listing_failure_is_private", function()
    local listing, reason = Directories.collect_private(input.nonexistent, 256)
    check(listing == nil and reason == "listing_refused")
end)
case("invalid_utf8_native_name_fails_closed", function()
    configured = input.invalid_config
    if input.invalid_native_name_rejected then
        check(#assert(owner.discover()).choices == 0)
    else check(owner.discover() == nil) end
    configured = input.config
    check(owner.invalidate() == true)
end)
case("configured_route_change_is_stale", function()
    initial = assert(owner.discover())
    configured = input.other_config
    check(owner.resolve(initial.choices[1].key, {}) == nil)
    configured = input.config
    check(owner.invalidate() == true)
end)
case("no_private_diagnostics_or_execution", function()
    check(logs == 0 and hs.fs == native_fs and io.open == native_open)
    check(native_fs.symlinkAttributes(input.config .. "/INTERPOLATION") == nil)
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
