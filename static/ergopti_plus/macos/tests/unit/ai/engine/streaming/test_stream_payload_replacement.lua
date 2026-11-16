--- tests/unit/ai/engine/streaming/test_stream_payload_replacement.lua

--- A deferred cleanup must never delete an already-replaced file.
local helpers = require("tests.helpers")
local Cleanup = require("ai.engine.api.stream_payload_cleanup")
local lfs = require("lfs")

helpers.describe("stream payload replacement", function()
	for _, replacement in ipairs({ "original private request", "replacement from another owner" }) do
		helpers.it("preserves a replacement " .. (replacement == "original private request" and "with identical bytes" or "with different bytes"), function()
			local path = os.tmpname()
			local old_path = path .. ".old"
			local function write(value)
				local file = assert(io.open(path, "wb"))
				assert(file:write(value))
				assert(file:close())
			end
			write("original private request")
			local original = assert(lfs.symlinkattributes(path))
			local saved = package.loaded["core.fs.adapters.file_system"]
			local refusal = true
			package.loaded["core.fs.adapters.file_system"] = {
				remove_exact = function(target)
					if refusal then return false end
					return os.remove(target)
				end,
				classify_no_follow = function(target)
					local attrs = lfs.symlinkattributes(target)
					if not attrs then return nil, "absent" end
					return attrs, "ok"
				end,
				remove_if_unchanged = function(target, expected, _, admission)
					if refusal then return false end
					local file = assert(io.open(target, "rb"))
					local bytes = assert(file:read("*a"))
					assert(file:close())
					if bytes ~= expected.content or not admission() then return false end
					return os.remove(target)
				end,
			}
			local ok, failure = xpcall(function()
				local logger = { error = function() end, debug = function() end }
				local owner = Cleanup.new(logger, "fixture")
				local retire = owner.capture(path, function() return nil end,
					{ dev = original.dev, ino = original.ino }, "original private request")
				helpers.assert_eq(retire(), false)
				assert(os.rename(path, old_path))
				write(replacement)
				refusal = false
				helpers.assert_eq(owner.settle_pending(), false)
				local file = assert(io.open(path, "rb"), "replacement must remain present")
				helpers.assert_eq(file:read("*a"), replacement)
				assert(file:close())
			end, debug.traceback)
			package.loaded["core.fs.adapters.file_system"] = saved
			os.remove(path)
			os.remove(old_path)
			if not ok then error(failure, 0) end
		end)
	end
end)
