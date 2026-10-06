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
local cases, case_facts = {}, {}
local active_case, check_ordinal, check_failure
local interpreter_facts = {
    resolved_scalar_observed = false, interpreter_equal = false,
    argv_count_equal = false, script_argument_equal = false,
}
local function check(condition)
    if active_case then check_ordinal = check_ordinal + 1 end
    if condition ~= true then
        if active_case then check_failure = check_ordinal end
        error("case_refused", 0)
    end
end
local function case(id, callback)
    active_case, check_ordinal, check_failure = id, 0, nil
    local ok = pcall(callback)
    cases[#cases + 1] = { id = id, status = ok and "passed" or "failed" }
    case_facts[#case_facts + 1] = {
        case = id, kind = ok and "none" or (check_failure and "check" or "raised"),
        ordinal = not ok and check_failure or 0,
    }
    active_case = nil
end
local function debug_kind(value)
    if type(value) ~= "function" then return "missing" end
    local ok, info = pcall(debug.getinfo, value, "S")
    local kind = ok and type(info) == "table" and info.what or nil
    if kind == "C" or kind == "Lua" or kind == "main" then return kind end
    return "unknown"
end
local function runtime_facts()
    local version = _VERSION
    if version ~= "Lua 5.1" and version ~= "Lua 5.2" and version ~= "Lua 5.3"
        and version ~= "Lua 5.4" and version ~= "Lua 5.5" then version = "other" end
    return {
        lua_version = version, dir = debug_kind(native_fs.dir),
        attributes = debug_kind(native_fs.attributes),
        symlink_attributes = debug_kind(native_fs.symlinkAttributes),
        path_to_absolute = debug_kind(native_fs.pathToAbsolute),
        file_open = debug_kind(native_open),
    }
end
local function observe_scalar(...)
    interpreter_facts.resolved_scalar_observed = type((...)) == "string"
    return ...
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
local OfficialFsOrigin = (function()
local M = {}
local SCRIPT_SHA = "7006e6d4917d1cd9d2eefdcdfe8de99ab6ee8242d5da3b2d656b0fdede959b45"
local NATIVE_SHA = "a1e0626a5ce6f013033fdc7fe0ff74dfc242d72e98b3620bf328c82af46775f6"
-- Independent official 1.1.1 wrapper body, verified against packaged fs.lua.
-- Parent-local slots and definition bounds match the official chunk. Only this
-- pure closure constructor is evaluated; no module top-level code is repeated.
local GOLDEN = "local module, host, hs_fs_symlinkAttributes = ...\n" .. string.rep("\n", 138) .. [[return function(...)
    local args = table.pack(...)
    if args[2] == "target" then
        return module.pathToAbsolute(args[1])
    else
        local ans = table.pack(hs_fs_symlinkAttributes(...))
        if ans.n == 1 and type(ans[1]) == "table" then
            ans[1].target = module.pathToAbsolute(args[1])
        end
        return table.unpack(ans)
    end
end]]
local function exact_file(pin, expected, fs, open, hash)
    if type(pin) ~= "table" or type(pin.path) ~= "string" or type(pin.dev) ~= "number"
        or type(pin.ino) ~= "number" or pin.sha256 ~= expected then return false end
    local before = fs.attributes(pin.path)
    if type(before) ~= "table" or before.mode ~= "file" or before.dev ~= pin.dev or before.ino ~= pin.ino then return false end
    local input = open(pin.path, "rb"); if not input then return false end
    local raw = input:read(1024 * 1024 + 1); local closed = input:close()
    if closed ~= true or type(raw) ~= "string" or #raw > 1024 * 1024 or hash(raw) ~= expected then return false end
    local after = fs.attributes(pin.path)
    return type(after) == "table" and after.mode == "file" and after.dev == pin.dev and after.ino == pin.ino
end
local function same_identity(value, expected, mode)
    return type(value) == "table" and type(expected) == "table"
        and type(expected.dev) == "number" and type(expected.ino) == "number" and expected.dev >= 0 and expected.ino >= 0 and value.mode == mode
        and value.dev == expected.dev and value.ino == expected.ino
end
function M.verify(fs, captured_public, pins, witness, open, hash)
    local ok, result = pcall(function()
        if type(fs) ~= "table" or fs.symlinkAttributes ~= captured_public or type(captured_public) ~= "function"
            or type(pins) ~= "table" or type(witness) ~= "table" or type(open) ~= "function" or type(hash) ~= "function" then return false end
        if not exact_file(pins.script, SCRIPT_SHA, fs, open, hash)
            or not exact_file(pins.native, NATIVE_SHA, fs, open, hash) then return false end
        local info = debug.getinfo(captured_public, "Su")
        if info.what ~= "Lua" or info.source ~= "@" .. pins.script.path or info.linedefined ~= 140
            or info.lastlinedefined ~= 151 or info.nups ~= 3 then return false end
        local expected_names = { "_ENV", "module", "hs_fs_symlinkAttributes" }
        local up = {}
        for i, name in ipairs(expected_names) do
            local observed, value = debug.getupvalue(captured_public, i)
            if observed ~= name then return false end
            up[i] = value
        end
        if type(up[1]) ~= "table" or up[1].table ~= table or up[1].type ~= type or up[2] ~= fs or type(up[3]) ~= "function"
            or debug.getinfo(up[3], "S").what ~= "C" then return false end
        local golden = assert(load(GOLDEN, "@" .. pins.script.path, "t", up[1]))(fs, false, up[3])
        if string.dump(captured_public, true) ~= string.dump(golden, true) then return false end
        -- Runtime loader table identities supplement the verified signed archive;
        -- no claim is made that debug.getinfo alone identifies a C symbol's DSO.
        if package.loaded["hs.fs"] ~= fs or package.loaded["hs.libfs"] ~= fs
            or package.searchpath("hs.libfs", package.cpath) ~= pins.native.path then return false end
        if type(witness.link) ~= "string" or type(witness.target) ~= "string" then return false end
        local raw, error_value = up[3](witness.link)
        if error_value ~= nil or not same_identity(raw, witness.link_identity, "link") then return false end
        local target = fs.attributes(witness.link)
        if not same_identity(target, witness.target_identity, "file") then return false end
        local wrapped, wrapped_error = captured_public(witness.link)
        if wrapped_error ~= nil or not same_identity(wrapped, witness.link_identity, "link")
            or wrapped.target ~= witness.target or captured_public(witness.link, "target") ~= witness.target then return false end
        if fs.symlinkAttributes ~= captured_public then return false end
        return exact_file(pins.script, SCRIPT_SHA, fs, open, hash)
            and exact_file(pins.native, NATIVE_SHA, fs, open, hash)
    end)
    return ok and result == true
end
return M
end)()
local captured_public_symlink = native_fs.symlinkAttributes
local owner, initial
case("actual_native_runtime", function()
    check(_VERSION == "Lua 5.4")
    check(debug.getinfo(native_fs.dir).what == "C")
    check(debug.getinfo(native_fs.attributes).what == "C")
    check(OfficialFsOrigin.verify(native_fs, captured_public_symlink, input.runtime_origin, input.runtime_link_witness, native_open, function(raw)
        local context = hs.hash.new("SHA256")
        if not context or context:append(raw) ~= context or context:finish() ~= context then return "" end
        local digest = context:value()
        return type(digest) == "string" and digest:match("^[0-9a-fA-F]+$") and #digest == 64 and digest:lower() or ""
    end))
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
    local scalar = assert(observe_scalar(owner.resolve(choices_by_name(initial)["literal.py"].key, {})))
    local value = hs.json.decode(scalar)
    interpreter_facts.interpreter_equal = value.executable == input.expected_python
    interpreter_facts.argv_count_equal = type(value.arguments) == "table" and #value.arguments == 1
    interpreter_facts.script_argument_equal = type(value.arguments) == "table"
        and value.arguments[1] == input.config .. "/scripts/literal.py"
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
local facts = {
    schema = 1, contract = "macos-native-hs-program-provider-diagnostic-facts",
    source_sha = input.source_sha, nonce = input.nonce, pid = hs.processInfo.processID,
    scenario = input.scenario, source_hashes = input.diagnostic_source_hashes,
    case_facts = case_facts, runtime = runtime_facts(), interpreter = interpreter_facts,
    expected_path_equal = os.getenv("PATH") == input.expected_path,
}
-- Auxiliary IO must not suppress the original primary failure receipt.
pcall(function()
    local diagnostic = assert(native_open(input.diagnostic_facts .. ".partial", "wb"))
    check(diagnostic:write(hs.json.encode(facts)) ~= nil); check(diagnostic:close() == true)
    check(os.rename(input.diagnostic_facts .. ".partial", input.diagnostic_facts) == true)
end)
local output = assert(native_open(input.receipt .. ".partial", "wb"))
check(output:write(hs.json.encode(packet)) ~= nil); check(output:close() == true)
check(os.rename(input.receipt .. ".partial", input.receipt) == true)
hs.timer.doAfter(0.01, function() os.exit(passed == #cases and 0 or 1) end)
