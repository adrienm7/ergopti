-- tools/diagnostics/native_notification_constructors/fixture.lua
-- Genuine construction/getters only; guarded dispatch is never delivered.
local input = hs.json.decode(__INPUT_JSON__)
local native_open, native_notify = io.open, hs.notify
local native_new = native_notify.new
local metatable = hs.getObjectMetatable("hs.notify")
local cases, receipts, owned_callbacks, owned_tags = {}, {}, {}, {}
local callback_invocations, forbidden_attempts, input_unchanged = 0, 0, true
local initial_registry = {}
for key, entry in pairs(native_notify.registry) do
    if key ~= "n" then initial_registry[key] = entry end
end
local function check(value) if value ~= true then error("constructor_case_refused", 0) end end
local function case(id, action)
    local ok = pcall(action)
    cases[#cases + 1] = { id = id, status = ok and "passed" or "failed" }
end
local forbidden = {}
local function guard(container, key)
    forbidden[#forbidden + 1] = { container = container, key = key, original = container[key] }
    container[key] = function()
        forbidden_attempts = forbidden_attempts + 1
        error("notification_dispatch_forbidden", 0)
    end
end
for _, name in ipairs({ "send", "schedule", "withdraw" }) do guard(metatable, name) end
for _, name in ipairs({ "show", "withdrawAll", "withdrawAllScheduled", "unregisterall" }) do guard(native_notify, name) end
native_notify.new = function(...)
    local note = native_new(...)
    -- Retain the exact native receipt before any getter or caller assertion.
    receipts[#receipts + 1] = note
    return note
end
local function registry_for(tag)
    local found = {}
    for key, entry in pairs(native_notify.registry) do
        if key ~= "n" and type(entry) == "table" and entry[1] == tag then found[#found + 1] = entry end
    end
    return found
end
local function capture_owned_tags()
    -- Also works after a partial constructor registered a callback then raised.
    for key, entry in pairs(native_notify.registry) do
        if key ~= "n" and initial_registry[key] == nil and type(entry) == "table"
            and owned_callbacks[entry[2]] and type(entry[1]) == "string" then
            owned_tags[entry[1]] = true
        end
    end
end
local function remaining_owned_tags()
    local count = 0
    for _, entry in pairs(native_notify.registry) do
        if type(entry) == "table" and owned_callbacks[entry[2]] then count = count + 1 end
    end
    return count
end
local function same_properties(original, before)
    local count, expected = 0, 0
    for key, value in pairs(original) do count = count + 1; if before[key] ~= value then return false end end
    for _ in pairs(before) do expected = expected + 1 end
    return count == expected
end
local function construct(callback, properties)
    local before = {}; for key, value in pairs(properties) do before[key] = value end
    local previous = #receipts
    local ok, note = pcall(require("adapters.application_notifier").new, callback, properties)
    capture_owned_tags()
    input_unchanged = input_unchanged and same_properties(properties, before)
    check(ok and #receipts == previous + 1)
    check(type(note) == "userdata" and rawequal(note, receipts[#receipts]))
    check(getmetatable(note) == metatable and note:delivered() == false)
    check(input_unchanged)
    return note
end
local function source_pins()
    for path, digest in pairs(input.source_hashes) do
        local file = assert(native_open(input.source_root .. "/" .. path, "rb"))
        local bytes = assert(file:read("*a")); check(file:close() == true)
        check(hs.hash.SHA256(bytes) == digest)
    end
end
package.path = input.source_root .. "/static/ergopti_plus/macos/?.lua;"
    .. input.source_root .. "/static/ergopti_plus/_shared/lua/?.lua;" .. package.path
local callback_note, nil_note, default_note
local callback = function() callback_invocations = callback_invocations + 1 end
owned_callbacks[callback] = true
case("authenticated_native_notify_runtime", function()
    check(_VERSION == "Lua 5.4")
    check(debug.getinfo(native_notify._new, "S").what == "C")
    check(debug.getinfo(native_new, "S").what == "Lua")
    local native_source = assert(debug.getinfo(native_new, "S").source:match("^@(.+)$"))
    check(hs.fs.pathToAbsolute(native_source) == input.native_notify_source)
    local file = assert(native_open(native_source, "rb")); local bytes = assert(file:read("*a")); check(file:close() == true)
    check(hs.hash.SHA256(bytes) == "e1559c20e0b695dfd185807575e4ecb9accce0dabdfd7a0bff87066bf10f34d1")
    for _, method in ipairs({ "title", "subTitle", "informativeText", "autoWithdraw", "alwaysPresent", "withdrawAfter", "getFunctionTag", "delivered" }) do
        check(debug.getinfo(metatable[method], "S").what == "C")
    end
end)
case("exact_source_pins_before", source_pins)
case("native_callback_caption_body_options", function()
    callback_note = construct(callback, {
        title = "通知 e\204\129", subTitle = "⚠️ Warning", informativeText = "Body 日本\n%PATH% ' ` $(literal)",
        autoWithdraw = false, alwaysPresent = false, withdrawAfter = 0,
    })
    check(callback_note:title() == "ErgoptiPlus — 通知 e\204\129")
    check(callback_note:subTitle() == "⚠️ Warning")
    check(callback_note:informativeText() == "Body 日本\n%PATH% ' ` $(literal)")
    check(callback_note:autoWithdraw() == false and callback_note:alwaysPresent() == false)
    check(callback_note:withdrawAfter() == 0)
end)
case("native_nil_callback_empty_label", function()
    nil_note = construct(nil, { title = "", informativeText = "", autoWithdraw = true, alwaysPresent = true, withdrawAfter = 11 })
    check(nil_note:title() == "ErgoptiPlus" and nil_note:informativeText() == "")
    check(nil_note:autoWithdraw() == true and nil_note:alwaysPresent() == true and nil_note:withdrawAfter() == 11)
    check(nil_note:getFunctionTag() ~= callback_note:getFunctionTag())
end)
case("native_default_label_and_payload", function()
    default_note = construct(nil, { informativeText = "Independent body", subTitle = "Independent subtitle" })
    check(default_note:title() == "ErgoptiPlus")
    check(default_note:informativeText() == "Independent body" and default_note:subTitle() == "Independent subtitle")
    check(default_note:autoWithdraw() == true and default_note:alwaysPresent() == true and default_note:withdrawAfter() == 5)
end)
case("callback_registry_preserves_exact_function", function()
    local tag = callback_note:getFunctionTag()
    local entries = registry_for(tag)
    check(#entries == 1 and rawequal(entries[1][2], callback))
    check(callback_invocations == 0)
end)
case("owned_callback_unregister_readback", function()
    capture_owned_tags()
    for tag in pairs(owned_tags) do native_notify.unregister(tag); check(#registry_for(tag) == 0) end
    check(remaining_owned_tags() == 0)
    for key, entry in pairs(initial_registry) do check(rawequal(native_notify.registry[key], entry)) end
end)
case("constructor_only_no_delivery", function()
    check(#receipts == 3 and forbidden_attempts == 0 and callback_invocations == 0)
    for _, note in ipairs(receipts) do check(note:delivered() == false) end
    check(input_unchanged)
end)
case("exact_source_pins_after", source_pins)
-- A failed earlier getter must not skip exact callback cleanup or its failure packet.
capture_owned_tags()
for tag in pairs(owned_tags) do pcall(native_notify.unregister, tag) end
native_notify.new = native_new
for _, port in ipairs(forbidden) do port.container[port.key] = port.original end
local passed = 0; for _, item in ipairs(cases) do if item.status == "passed" then passed = passed + 1 end end
local packet = {
    schema = 1, contract = "macos-native-application-notification-constructors",
    source_sha = input.source_sha, nonce = input.nonce, pid = hs.processInfo.processID,
    source_hashes = input.source_hashes, cases = cases,
    counts = { passed = passed, failed = #cases - passed, skipped = 0 },
    scope = { constructor_only = true, notification_delivery = false, callback_invocation = false,
        gc_native_destruction_verified = false, user_configuration_modified = false },
    forbidden_attempts = forbidden_attempts, callback_invocations = callback_invocations,
    owned_tags_remaining = remaining_owned_tags(), input_properties_unchanged = input_unchanged,
}
local output = assert(native_open(input.receipt .. ".partial", "wb"))
check(output:write(hs.json.encode(packet)) ~= nil); check(output:close() == true)
check(os.rename(input.receipt .. ".partial", input.receipt) == true)
hs.timer.doAfter(0.01, function() os.exit(passed == #cases and packet.owned_tags_remaining == 0 and 0 or 1) end)
