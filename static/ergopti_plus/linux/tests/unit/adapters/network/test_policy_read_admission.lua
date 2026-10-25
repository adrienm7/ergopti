--- tests/unit/adapters/network/test_policy_read_admission.lua

--- ==============================================================================
--- MODULE: Native Network Policy Source Admission
--- DESCRIPTION:
--- Exercise public policy entrypoints against an actual installed child layout.
--- A valid locale sentinel cannot certify unrelated policy file types or reads.
--- ==============================================================================

local helpers = require("tests.helpers")
local native = require("luv")
local Shell = require("adapters.shell_runner")
local Paths = require("infra.paths")

local policies = {
	{ module = "infra.proxy_policy", path = "modules/network/proxy_policy.json", call = ".load()" },
	{ module = "infra.route_origins", path = "modules/network/route_origins.json", call = '.client("uv")' },
	{ module = "infra.http_header_policy", path = "data/http/header_policy.json", call = '.validate("Accept", "text/plain")' },
	{ module = "infra.http_transport_policy", path = "data/http/transport_policy.json", call = '.resolve("https://example.test")' },
	{ module = "infra.http_redirect_policy", path = "data/http/redirect_policy.json", call = ".allows_native_follow({})" },
	{ module = "infra.managed_redirect_policy", path = "data/http/redirect_policy.json", call = ".load()" },
}

local function copy(source, target)
	local input = assert(io.open(source, "rb"))
	local bytes = assert(input:read("*a")); assert(input:close())
	assert(Shell.run("mkdir -p -- " .. Shell.quote(assert(target:match("^(.*)/[^/]+$")))))
	local output = assert(io.open(target, "wb"))
	assert(output:write(bytes)); assert(output:close())
end

helpers.describe("network-policy-source", function()
	for _, policy in ipairs(policies) do
		for _, kind in ipairs({ "fifo", "symlink", "unreadable", "close-failure" }) do
			helpers.it("(network-policy-source) " .. policy.module .. " admits " .. kind .. " explicitly", function()
				local base = os.tmpname(); os.remove(base)
				local driver = base .. "/driver"
				copy(helpers.driver_root() .. "/infra/paths.lua", driver .. "/infra/paths.lua")
				copy(Paths.shared("data/locales/en.json"), driver .. "/_shared/data/locales/en.json")
				for _, declaration in ipairs(policies) do
					copy(Paths.shared(declaration.path), driver .. "/_shared/" .. declaration.path)
				end
				local target = driver .. "/_shared/" .. policy.path
				if kind == "fifo" then
					assert(os.remove(target)); assert(Shell.run("mkfifo -- " .. Shell.quote(target)))
				elseif kind == "symlink" then
					assert(os.rename(target, target .. ".regular")); assert(native.fs_symlink(target .. ".regular", target))
				elseif kind == "unreadable" then assert(native.fs_chmod(target, 0)) end
				local code = string.format([[package.path = %q
package.loaded["infra.paths"] = dofile(%q)
assert(require("infra.paths").shared_root(), "the installed locale sentinel must be admitted")
if %q == "close-failure" then
    local original = io.open
    io.open = function(path, ...)
        local file, detail, status = original(path, ...)
        if not file then return file, detail, status end
        return { read = function(_, ...) return file:read(...) end,
            close = function() assert(file:close()); return false, "EIO" end }
    end
end
local value, refusal = require(%q)%s
if %q == "symlink" then
    assert(value ~= nil and refusal == nil, "a regular symlink must retain the valid policy")
else
    assert(value == nil and type(refusal) == "string", "unadmitted policy must refuse explicitly")
end
]], package.path, driver .. "/infra/paths.lua", kind, policy.module, policy.call, kind)
				local expired, exited, exit_code, exit_signal = false, false, nil, nil
				local timer_closed, child_closed = false, false
				local timer = assert(native.new_timer())
				local child
				child = assert(native.spawn(assert(arg[-1]), { args = { "-e", code } }, function(status, signal)
					exited, exit_code, exit_signal = true, status, signal
					native.timer_stop(timer)
					native.close(timer, function() timer_closed = true end)
					native.close(child, function() child_closed = true end)
				end))
				assert(require("infra.native_timer").start(native, timer, 2000, 0, function()
					expired = true; child:kill("sigkill")
				end))
				while not exited or not timer_closed or not child_closed do native.run("once") end
				native.run("nowait")
				assert(Shell.run("rm -r -- " .. Shell.quote(base)))
				helpers.assert_eq(expired, false, "the public policy entrypoint must not wait for a FIFO writer")
				helpers.assert_eq(exit_code, 0, "the native source receipt must determine policy admission")
				helpers.assert_eq(exit_signal, 0, "a killed reader cannot certify refusal")
			end)
		end
	end
end)
