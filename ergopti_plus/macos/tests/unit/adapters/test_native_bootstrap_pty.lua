--- tests/unit/adapters/test_native_bootstrap_pty.lua
--- Independent receiving vectors for source admission and physical receipts.

local helpers = require("tests.helpers")
local Json = require("json")
local Receipt = require("core.llm.native_pty_receipt")
local NONCE = "12345678-abcd-4321-abcd-123456789abc"
local SOURCE = "/Applications/ErgoptiPlus.app/Contents/Resources/static/ergopti_plus/macos/modules/llm/ensure-mlx-deps.sh"
local RECEIPT_PATH = "/private/owned-bootstrap-receipt"

local function proof(changes)
	local receipt = {
		version = 1, nonce = NONCE, state = "retired", group_retired = true,
		guardian_reaped = true, pty_eof = true, handles_closed = true, status_valid = true,
		exit_status = 0, worker_status = 0, source_admitted = true,
	}
	for key, value in pairs(changes or {}) do receipt[key] = value end
	return Json.encode(receipt)
end

helpers.describe("native bootstrap closed retirement receipt", function()
	helpers.it("accepts only actual callback equality and every physical fence", function()
		helpers.assert_eq(Receipt.retired(proof(), Json.decode, NONCE, 0), true)
		for _, field in ipairs({ "group_retired", "guardian_reaped", "pty_eof", "handles_closed", "status_valid", "source_admitted" }) do
			helpers.assert_eq(Receipt.retired(proof({ [field] = false }), Json.decode, NONCE, 0), false, field)
			helpers.assert_eq(Receipt.retired(proof({ [field] = "true" }), Json.decode, NONCE, 0), false, field)
		end
		helpers.assert_eq(Receipt.retired(proof(), Json.decode, NONCE, 1), false)
		helpers.assert_eq(Receipt.retired(proof(), Json.decode, "foreign-nonce", 0), false)
	end)
	helpers.it("allows physically retired refusal without admitting a source or installation", function()
		helpers.assert_eq(Receipt.retired(proof({ source_admitted = false, worker_status = 64, exit_status = 64 }), Json.decode, NONCE, 64), true)
		helpers.assert_eq(Receipt.retired(proof({ worker_status = 124, exit_status = 130 }), Json.decode, NONCE, 124), true)
	end)
	helpers.it("rejects duplicate, escaped, unknown, malformed and impossible scalar fields", function()
		local raw = proof()
		local invalid = {
			raw:gsub('"version":1', '"version":1,"version":1'),
			raw:gsub('"version"', '"\\u0076ersion"'),
			proof({ unknown = true }), proof({ state = "pending" }),
			proof({ exit_status = -1 }), proof({ worker_status = 256 }),
			proof({ worker_status = 0.5 }), raw .. "{}", "{", string.rep(" ", 4097),
		}
		for _, value in ipairs(invalid) do
			helpers.assert_eq(Receipt.retired(value, Json.decode, NONCE, 0), false)
		end
	end)
end)

local function receiving(body, options)
	options = options or {}
	local saved, old_hs = {}, _G.hs
	for name, value in pairs(package.loaded) do saved[name] = value end
	local native = { bytes = "", exists = true, inode = 9, removals = 0, releases = 0 }
	local ok, error_message = xpcall(function()
		_G.hs = { host = { uuid = function() return NONCE end } }
		package.loaded["infra.logger"] = helpers.make_logger_stub()
		package.loaded["platform.remap.lease_helper"] = { resolve = function()
			return "/Applications/ErgoptiPlus.app/Contents/MacOS/ErgoptiPlus"
		end }
		package.loaded["adapters.crypto"] = { sha256_bytes = function() return string.rep("b", 64) end }
		package.loaded["adapters.file_system"] = {
			create_secure_temp_file = function() return RECEIPT_PATH end,
			classify_no_follow = function(path)
				if path ~= RECEIPT_PATH or not native.exists then return nil, "absent" end
				return { mode = "file", dev = 7, ino = native.inode, size = #native.bytes }, "ok"
			end,
			read_with_status = function(path)
				if path == SOURCE then return "#!/bin/bash\nexit 0\n", "ok" end
				return native.bytes, "ok"
			end,
			remove_if_unchanged = function(path, expected, _, admitted)
				helpers.assert_eq(path, RECEIPT_PATH)
				helpers.assert_eq(expected.content, native.bytes)
				helpers.assert_eq(admitted(), true)
				native.removals = native.removals + 1
				if options.remove_throw then error("PRIVATE receipt failure") end
				if options.remove_false then return false end
				native.exists = false
				if options.release_pending then
					return false, "pending", {}, function()
						native.releases = native.releases + 1
						return native.releases >= 2
					end
				end
				return true
			end,
		}
		package.loaded["adapters.native_bootstrap_pty"] = nil
		body(require("adapters.native_bootstrap_pty"), native)
	end, debug.traceback)
	_G.hs = old_hs
	for name in pairs(package.loaded) do if saved[name] == nil then package.loaded[name] = nil end end
	for name, value in pairs(saved) do package.loaded[name] = value end
	if not ok then error(error_message, 0) end
end

helpers.describe("native bootstrap private source and receipt adapter", function()
	helpers.it("uses private stdin and an integral original timeout without URL argv", function()
		receiving(function(adapter, native)
			local owner, prepared = adapter.prepare(SOURCE, { { "PROJECT_ROOT", "/private/project" } }, 1800000.0)
			helpers.assert_eq(prepared, true)
			helpers.assert_eq(owner.arguments, { "--managed-pty-worker", "1800000" })
			local task = { setInput = function(self, input) self.input = input; return self end }
			helpers.assert_eq(owner.bind_input(task), true)
			local input = Json.decode(task.input)
			helpers.assert_eq(input.source_path, SOURCE)
			helpers.assert_eq(input.source_sha256, string.rep("b", 64))
			helpers.assert_eq(input.receipt_path, RECEIPT_PATH)
			helpers.assert_eq(input.nonce, NONCE)
			helpers.assert_eq(owner.settle(0), false)
			helpers.assert_eq(owner.rollback(), true)
			helpers.assert_eq(native.exists, false)
		end)
	end)
	helpers.it("retains the exact owner after exit until its receipt and cleanup both commit", function()
		receiving(function(adapter, native)
			local owner = adapter.prepare(SOURCE, {}, 1800000)
			helpers.assert_eq(owner.mark_start_attempted(), true)
			helpers.assert_eq(owner.mark_start_attempted(), false)
			helpers.assert_eq(owner.rollback(), false)
			helpers.assert_eq(owner.settle(0), false)
			native.bytes = proof({ pty_eof = false })
			helpers.assert_eq(owner.settle(0), false)
			native.bytes = proof()
			helpers.assert_eq(owner.settle(0), true)
			helpers.assert_eq(native.removals, 1)
		end)
	end)
	helpers.it("refuses a replacement inode even when foreign bytes contain the expected nonce", function()
		receiving(function(adapter, native)
			local owner = adapter.prepare(SOURCE, {}, 1800000)
			owner.mark_start_attempted()
			native.bytes, native.inode = proof(), 10
			helpers.assert_eq(owner.settle(0), false)
			helpers.assert_eq(native.removals, 0)
		end)
	end)
	helpers.it("does not promote false or throwing cleanup into retirement", function()
		for _, options in ipairs({ { remove_false = true }, { remove_throw = true } }) do
			receiving(function(adapter, native)
				local owner = adapter.prepare(SOURCE, {}, 1800000)
				owner.mark_start_attempted()
				native.bytes = proof()
				helpers.assert_eq(owner.settle(0), false)
				helpers.assert_eq(native.exists, true)
			end, options)
		end
	end)
	helpers.it("retries only the exact release after unlink instead of deleting a recreated path", function()
		receiving(function(adapter, native)
			local owner = adapter.prepare(SOURCE, {}, 1800000)
			owner.mark_start_attempted()
			native.bytes = proof()
			helpers.assert_eq(owner.settle(0), false)
			native.exists, native.inode, native.bytes = true, 10, "foreign"
			helpers.assert_eq(owner.settle(0), false)
			helpers.assert_eq(owner.settle(0), true)
			helpers.assert_eq(native.removals, 1)
			helpers.assert_eq(native.bytes, "foreign")
		end, { release_pending = true })
	end)
end)
