--- tests/unit/infra/network/test_network_proxy_override_contract.lua

--- ==============================================================================
--- MODULE: Test Network Proxy Override Contract
--- DESCRIPTION:
--- Registers the shared proxy override controls through the actual Linux path
--- owner: the Linux proxy policy binding hands the stored override to every
--- managed download and to the managed Ollama daemon.
--- ==============================================================================

--- Register the exact shared proxy override controls.
local helpers = require("tests.helpers")
local Paths = require("infra.paths")
local Contract = require("tests.lua.core.network_proxy_override_contract")
local function read(relative)
    local file = assert(io.open(assert(Paths.shared(relative)), "rb"))
    local bytes = file:read("*a")
    assert(file:close())
    return bytes
end
Contract.register(read, helpers)

helpers.it("proxy dialog refuses an externally changed proxy and preserves other settings", function()
    local fixture = require("tests.support.adapters.storage.storage_adapter_fixture")
    fixture.storage_cohort_fixture('{"network.proxy_override":"direct","other":1}', function(storage, _, path, _, write, read_file)
        local names = { "ui.proxy_override", "ui.menu.menu_dialogs", "infra.i18n" }
        local previous = {}; for _, name in ipairs(names) do previous[name] = package.loaded[name] end
        local shown = {}
        local ok, err = pcall(function()
            package.loaded["ui.proxy_override"] = nil
            package.loaded["infra.i18n"] = { get = function(key) return key end }
            package.loaded["ui.menu.menu_dialogs"] = {
                prompt_text = function(_, _, initial)
                    helpers.assert_eq(initial, "direct")
                    write(path, '{"network.proxy_override":"http://external.invalid:8080","other":2}')
                    return "http://dialog.invalid:8080"
                end,
                show_error = function(text) shown[#shown + 1] = text end,
                show_info = function(_, text) shown[#shown + 1] = text end,
            }
            helpers.assert_eq(require("ui.proxy_override").run(), false)
            helpers.assert_eq(read_file(path), '{"network.proxy_override":"http://external.invalid:8080","other":2}')
            helpers.assert_eq(shown[1], "proxy_override.not_saved")
        end)
        for _, name in ipairs(names) do package.loaded[name] = previous[name] end
        if not ok then error(err, 0) end
    end)
end)

helpers.it("proxy edit refuses a source changed during staged publication", function()
    if _VERSION ~= "Lua 5.1" then return end -- The Linux LuaJIT port uses the intercepted stdio descriptor.
    local fixture = require("tests.support.adapters.storage.storage_adapter_fixture")
    fixture.storage_cohort_fixture('{"network.proxy_override":"direct","other":1}', function(storage, _, path, _, write, read_file)
        local _, receipt = storage.capture_string_edit("network.proxy_override")
        helpers.assert_not_nil(receipt)
        local original, replaced = io.open, false
        io.open = function(name, mode)
            local handle, err = original(name, mode)
            if name ~= helpers.stage_path(path) or mode ~= "wx" or not handle then return handle, err end
            return {
                write = function(_, bytes) return handle:write(bytes) end,
                close = function()
                    local closed = handle:close()
                    write(path, '{"network.proxy_override":"http://external.invalid:8080","other":2}')
                    replaced = true
                    return closed
                end,
            }
        end
        -- The adapter stages through libuv wherever it loads (CFL-003): the
        -- intervening write lands at that staging file's close the same way.
        local has_uv, uv = pcall(require, "luv")
        local uv_open, uv_close, staged_fd = has_uv and uv.fs_open, has_uv and uv.fs_close, nil
        if has_uv then
            uv.fs_open = function(name, mode, permissions)
                local fd, err = uv_open(name, mode, permissions)
                if name == helpers.stage_path(path) and mode == "wx" then staged_fd = fd end
                return fd, err
            end
            uv.fs_close = function(fd)
                local closed, err = uv_close(fd)
                if fd == staged_fd then
                    write(path, '{"network.proxy_override":"http://external.invalid:8080","other":2}')
                    replaced = true
                end
                return closed, err
            end
        end
        local ok, result = pcall(storage.commit_string_edit, receipt, "http://dialog.invalid:8080")
        io.open = original
        if has_uv then uv.fs_open, uv.fs_close = uv_open, uv_close end
        helpers.assert_true(ok); helpers.assert_true(replaced); helpers.assert_eq(result, false)
        helpers.assert_eq(read_file(path), '{"network.proxy_override":"http://external.invalid:8080","other":2}')
    end)
end)

helpers.it("proxy edit receipt refuses a same-value intervening write and publication errors", function()
    local fixture = require("tests.support.adapters.storage.storage_adapter_fixture")
    fixture.storage_cohort_fixture('{"network.proxy_override":"direct","other":1}', function(storage, files, path, _, _, read_file)
        local key = "network.proxy_override"
        local value, receipt = storage.capture_string_edit(key)
        helpers.assert_eq(value, "direct"); helpers.assert_not_nil(receipt)
        helpers.assert_true(storage.set(key, "direct"))
        helpers.assert_eq(storage.commit_string_edit(receipt, "http://dialog.invalid:8080"), false)
        helpers.assert_eq(require("core.text.engine.json").decode(read_file(path))[key], "direct")
        value, receipt = storage.capture_string_edit(key)
        helpers.assert_eq(value, "direct"); helpers.assert_not_nil(receipt)
        local original = os.rename
        os.rename = function() return nil, "controlled publication refusal" end
        local ok, result = pcall(storage.commit_string_edit, receipt, "http://dialog.invalid:8080")
        os.rename = original
        helpers.assert_true(ok); helpers.assert_eq(result, false)
        helpers.assert_eq(require("core.text.engine.json").decode(read_file(path))[key], "direct")
        helpers.assert_eq(storage.commit_string_edit(receipt, "direct"), false, "a refused receipt is one-shot")
    end)
end)

helpers.it("proxy dialog preserves unrelated external changes and refuses unreadable storage", function()
    local fixture = require("tests.support.adapters.storage.storage_adapter_fixture")
    for _, mode in ipairs({ "other", "wrong_type", "invalid_before", "invalid_during" }) do
        local source = mode == "invalid_before" and '{invalid'
            or mode == "wrong_type" and '{"network.proxy_override":false,"other":1}'
            or '{"network.proxy_override":"direct","other":1}'
        fixture.storage_cohort_fixture(source, function(_, _, path, _, write, read_file)
            local names = { "ui.proxy_override", "ui.menu.menu_dialogs", "infra.i18n" }
            local previous = {}; for _, name in ipairs(names) do previous[name] = package.loaded[name] end
            local prompted, shown = false, {}
            local ok, err = pcall(function()
                package.loaded["ui.proxy_override"] = nil
                package.loaded["infra.i18n"] = { get = function(key) return key end }
                package.loaded["ui.menu.menu_dialogs"] = {
                    prompt_text = function(_, _, initial)
                        prompted = true
                        if mode == "wrong_type" then helpers.assert_eq(initial, "") end
                        write(path, mode == "invalid_during" and '{invalid'
                            or mode == "wrong_type" and '{"network.proxy_override":false,"other":2}'
                            or '{"network.proxy_override":"direct","other":2}')
                        return "http://dialog.invalid:8080"
                    end,
                    show_error = function(text) shown[#shown + 1] = text end,
                    show_info = function(_, text) shown[#shown + 1] = text end,
                }
                local saved = require("ui.proxy_override").run()
                if mode == "invalid_before" or mode == "invalid_during" then
                    helpers.assert_eq(saved, false); helpers.assert_eq(prompted, mode == "invalid_during")
                    helpers.assert_eq(read_file(path), '{invalid')
                    helpers.assert_eq(shown[1], "proxy_override.not_saved")
                else
                    helpers.assert_eq(saved, true); helpers.assert_true(prompted)
                    local parsed = require("core.text.engine.json").decode(read_file(path))
                    helpers.assert_eq(parsed["network.proxy_override"], "http://dialog.invalid:8080")
                    helpers.assert_eq(parsed.other, 2)
                end
            end)
            for _, name in ipairs(names) do package.loaded[name] = previous[name] end
            if not ok then error(err, 0) end
        end)
    end
end)

helpers.it("external process writes during the open proxy dialog", function()
    if package.config:sub(1, 1) == "\\" then return end
    local fixture = require("tests.support.adapters.storage.storage_adapter_fixture")
    local shell = require("adapters.shell_runner")
    for _, mode in ipairs({ "conflict", "other" }) do
        fixture.storage_cohort_fixture('{"network.proxy_override":"direct","other":1}', function(_, _, path, _, _, read_file)
            local names = { "ui.proxy_override", "ui.menu.menu_dialogs", "infra.i18n" }
            local previous = {}; for _, name in ipairs(names) do previous[name] = package.loaded[name] end
            local shown = {}
            local ok, err = xpcall(function()
                package.loaded["ui.proxy_override"] = nil
                package.loaded["infra.i18n"] = { get = function(key) return key end }
                package.loaded["ui.menu.menu_dialogs"] = {
                    prompt_text = function(_, _, initial)
                        helpers.assert_eq(initial, "direct")
                        local external = mode == "conflict" and '{"network.proxy_override":"http://external.invalid:8080","other":2}'
                            or '{"network.proxy_override":"direct","other":2}'
                        local result = os.execute("printf %s " .. shell.quote(external) .. " > " .. shell.quote(path))
                        helpers.assert_true(result == 0 or result == true, "external process must complete while dialog is open")
                        return "http://dialog.invalid:8080"
                    end,
                    show_error = function(text) shown[#shown + 1] = text end,
                    show_info = function(_, text) shown[#shown + 1] = text end,
                }
                local committed = require("ui.proxy_override").run()
                local parsed = require("core.text.engine.json").decode(read_file(path))
                helpers.assert_eq(committed, mode == "other")
                helpers.assert_eq(parsed.other, 2)
                helpers.assert_eq(parsed["network.proxy_override"], mode == "other" and "http://dialog.invalid:8080" or "http://external.invalid:8080")
                if mode == "conflict" then helpers.assert_eq(shown[1], "proxy_override.not_saved") end
            end, debug.traceback)
            for _, name in ipairs(names) do package.loaded[name] = previous[name] end
            if not ok then error(err, 0) end
        end)
    end
end)

helpers.it("existing storage API retains the historical number of results", function()
    local fixture = require("tests.support.adapters.storage.storage_adapter_fixture")
    fixture.storage_cohort_fixture('{"network.proxy_override":"direct","other":1}', function(storage)
        helpers.assert_eq(select("#", storage.get("other")), 1)
        helpers.assert_eq(select("#", storage.set("other", 2)), 1)
        helpers.assert_eq(select("#", storage.set_many({ other = 3 })), 1)
        helpers.assert_eq(select("#", storage.delete("other")), 1)
        helpers.assert_eq(select("#", storage.clear()), 1)
    end)
end)

helpers.it("proxy dialog refuses a real unreadable source before or during editing", function()
    if package.config:sub(1, 1) == "\\" then return end
    local fixture = require("tests.support.adapters.storage.storage_adapter_fixture")
    local uv = require("luv")
    if uv.getuid() == 0 then return end
    for _, mode in ipairs({ "before", "during" }) do
        fixture.storage_cohort_fixture('{"network.proxy_override":"direct","other":1}', function(_, _, path, _, _, read_file)
            local names = { "ui.proxy_override", "ui.menu.menu_dialogs", "infra.i18n" }
            local previous = {}; for _, name in ipairs(names) do previous[name] = package.loaded[name] end
            local shown, prompted = {}, false
            local ok, err = xpcall(function()
                package.loaded["ui.proxy_override"] = nil
                package.loaded["infra.i18n"] = { get = function(key) return key end }
                package.loaded["ui.menu.menu_dialogs"] = {
                    prompt_text = function()
                        prompted = true
                        assert(uv.fs_chmod(path, 0))
                        return "http://dialog.invalid:8080"
                    end,
                    show_error = function(text) shown[#shown + 1] = text end,
                    show_info = function(_, text) shown[#shown + 1] = text end,
                }
                if mode == "before" then assert(uv.fs_chmod(path, 0)) end
                local file = mode == "before" and uv.fs_open(path, "r", 0) or nil
                if file then uv.fs_close(file); error("the test user must not bypass file permissions") end
                helpers.assert_eq(require("ui.proxy_override").run(), false)
                helpers.assert_eq(prompted, mode == "during")
                helpers.assert_eq(shown[1], "proxy_override.not_saved")
            end, debug.traceback)
            assert(uv.fs_chmod(path, 384))
            for _, name in ipairs(names) do package.loaded[name] = previous[name] end
            helpers.assert_eq(read_file(path), '{"network.proxy_override":"direct","other":1}')
            if not ok then error(err, 0) end
        end)
    end
end)
