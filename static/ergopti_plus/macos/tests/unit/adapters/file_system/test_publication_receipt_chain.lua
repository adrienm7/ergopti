--- tests/unit/adapters/file_system/test_publication_receipt_chain.lua

local helpers = require("tests.helpers")
local with_fixture = require("tests.support.file_system_transaction_fixture").with_fixture

-- Actual file bytes, inode identities, renames and held descriptors. Only the
-- existing fixture's HS metadata/advisory-lock ports are modeled.
local function with_files(body)
	return with_fixture(function(fixture)
		local paths, handles, receipts = {}, {}, {}
		local function put(path, bytes)
			local file = assert(io.open(path, "wb"))
			assert(file:write(bytes)); assert(file:close())
		end
		local function fresh(bytes)
			local path = os.tmpname(); paths[#paths + 1] = path; put(path, bytes); return path
		end
		local function hold(path)
			local handle = assert(io.open(path, "rb")); handles[#handles + 1] = handle
			return handle
		end
		local function write(adapter, path, old, new, admission)
			local reporter = function() end
			local written, detail, receipt = adapter.write_if_unchanged_admitted(
				path, new, { status = "ok", content = old }, reporter, admission or function() return true end)
			if type(receipt) == "table" then receipts[#receipts + 1] = receipt end
			return written, detail, receipt
		end
		local function publish(adapter, path, old, new)
			local written, detail, receipt = write(adapter, path, old, new)
			helpers.assert_eq(written, true, tostring(detail))
			helpers.assert_eq(type(receipt), "table")
			helpers.assert_eq(receipt.is_settled(), true)
			helpers.assert_eq(receipt.matches_source(), true)
			return receipt
		end
		local called, failure = xpcall(function()
			body(fixture, fresh, hold, put, write, publish)
		end, debug.traceback)
		local cleanup_called, cleanup_failure = xpcall(function()
			-- Retry only through each real issuer; never discard native debt.
			for index = #receipts, 1, -1 do
				local receipt = receipts[index]
				if receipt.is_settled() ~= true then assert(receipt.retry() == true, "original native cleanup refused") end
			end
			for _, handle in ipairs(handles) do assert(handle:close()) end
			for _, path in ipairs(paths) do
				if fixture.HOST_ATTRIBUTES(path) ~= nil then assert(os.remove(path)) end
				local lock = path .. fixture.WRITE_LOCK_SUFFIX
				if fixture.HOST_ATTRIBUTES(lock) ~= nil then assert(os.remove(lock)) end
			end
		end, debug.traceback)
		if not called and not cleanup_called then error("test_failure:\n" .. failure .. "\ncleanup_failure:\n" .. cleanup_failure, 0) end
		if not called then error(failure, 0) end
		if not cleanup_called then error(cleanup_failure, 0) end
	end)
end

helpers.describe("FileSystem original publication receipt lineage", function()
	helpers.it("continues only the genuine rename inverse and rejects replay", function()
		with_files(function(fixture, fresh, hold, _, _, publish)
			local adapter = fixture.make_adapter()
			local path = fresh("initial")
			local previous = publish(adapter, path, "initial", "owned")
			hold(path) -- Prevent inode reuse from accidentally satisfying old identity.
			local forward = publish(adapter, path, "owned", "coexistence")
			hold(path)
			local inverse = publish(adapter, path, "coexistence", "owned")
			helpers.assert_eq(previous.matches_source(), false)
			helpers.assert_eq(adapter.publication_receipt_chain_restore(previous, forward, inverse), true)
			helpers.assert_eq(previous.matches_source(), true)
			helpers.assert_eq(adapter.publication_receipt_chain_restore(previous, forward, inverse), false)
			hold(path)
			local next_forward = publish(adapter, path, "owned", "next-choice")
			hold(path)
			local next_inverse = publish(adapter, path, "next-choice", "owned")
			helpers.assert_eq(adapter.publication_receipt_chain_restore(previous, forward, next_inverse), false)
			helpers.assert_eq(adapter.publication_receipt_chain_restore(previous, next_forward, next_inverse), true)
			helpers.assert_eq(previous.matches_source(), true)
		end)
	end)

	helpers.it("refuses equal-byte foreign replacement and copied capabilities", function()
		with_files(function(fixture, fresh, hold, _, _, publish)
			local adapter = fixture.make_adapter()
			local path = fresh("initial")
			local previous = publish(adapter, path, "initial", "owned"); hold(path)
			local forward = publish(adapter, path, "owned", "choice"); hold(path)
			local inverse = publish(adapter, path, "choice", "owned"); hold(path)
			local copy = { matches_source = inverse.matches_source, is_settled = inverse.is_settled, retry = inverse.retry }
			helpers.assert_eq(adapter.publication_receipt_chain_restore(previous, forward, copy), false)
			helpers.assert_eq(adapter.publication_receipt_chain_restore({}, forward, inverse), false)
			local foreign = fresh("owned"); assert(os.rename(foreign, path))
			helpers.assert_eq(inverse.matches_source(), false)
			helpers.assert_eq(adapter.publication_receipt_chain_restore(previous, forward, inverse), false)
			helpers.assert_eq(previous.matches_source(), false)
		end)
	end)

	helpers.it("refuses a wrong destination and a different original predecessor", function()
		with_files(function(fixture, fresh, hold, _, _, publish)
			local adapter = fixture.make_adapter()
			local path = fresh("initial")
			local previous = publish(adapter, path, "initial", "owned"); hold(path)
			local forward = publish(adapter, path, "owned", "choice"); hold(path)
			local inverse = publish(adapter, path, "choice", "owned")
			local other = fresh("initial")
			local unrelated = publish(adapter, other, "initial", "owned")
			helpers.assert_eq(adapter.publication_receipt_chain_restore(unrelated, forward, inverse), false)
			helpers.assert_eq(adapter.publication_receipt_chain_restore(previous, unrelated, inverse), false)
			helpers.assert_eq(unrelated.matches_source(), true)
			helpers.assert_eq(adapter.publication_receipt_chain_restore(previous, forward, inverse), true)
		end)
	end)

	helpers.it("keeps a refused original mutex release as debt before lineage transfer", function()
		with_files(function(fixture, fresh, hold, _, write, publish)
			local refuse_release = false
			local adapter = fixture.make_adapter(nil, nil, nil, nil, nil, function()
				if refuse_release then return false, "modeled native unlock refusal" end
				return true
			end)
			local path = fresh("initial")
			local previous = publish(adapter, path, "initial", "owned"); hold(path)
			local forward = publish(adapter, path, "owned", "choice"); hold(path)
			local open = io.open
			io.open = function(target, mode, ...)
				local handle, detail = open(target, mode, ...)
				if target ~= path .. fixture.WRITE_LOCK_SUFFIX or mode ~= "a+" or handle == nil then
					return handle, detail
				end
				-- Exact original mutex FD is genuinely open. This SDK close-refusal
				-- model retains it; native issuer retry alone can later close it.
				return { close = function()
					if refuse_release then return false, "modeled native close refusal" end
					return handle:close()
				end }
			end
			refuse_release = true
			local written, _, inverse = write(adapter, path, "choice", "owned")
			-- Allow only this exact issuer retry during cleanup, also on assertion failure.
			refuse_release = false
			io.open = open
			helpers.assert_eq(written, false)
			helpers.assert_eq(type(inverse), "table")
			helpers.assert_eq(inverse.is_settled(), false)
			helpers.assert_eq(adapter.publication_receipt_chain_restore(previous, forward, inverse), false)
			helpers.assert_eq(previous.matches_source(), false)
			helpers.assert_eq(inverse.retry(), true)
			helpers.assert_eq(adapter.publication_receipt_chain_restore(previous, forward, inverse), true)
		end)
	end)

	helpers.it("preserves the original no-op inode without staging or rename", function()
		with_files(function(fixture, fresh, hold, _, _, publish)
			local adapter, staging = fixture.make_adapter()
			local path = fresh("owned"); hold(path)
			local before = fixture.HOST_ATTRIBUTES(path)
			local rename, renames = os.rename, 0
			os.rename = function(...) renames = renames + 1; return rename(...) end
			local previous = publish(adapter, path, "owned", "owned")
			local forward = publish(adapter, path, "owned", "owned")
			local inverse = publish(adapter, path, "owned", "owned")
			os.rename = rename
			local after = fixture.HOST_ATTRIBUTES(path)
			helpers.assert_eq(after.dev, before.dev); helpers.assert_eq(after.ino, before.ino)
			helpers.assert_eq(renames, 0)
			helpers.assert_nil(next(staging))
			helpers.assert_eq(adapter.publication_receipt_chain_restore(previous, forward, inverse), true)
			helpers.assert_eq(previous.matches_source(), true)
		end)
	end)

	helpers.it("refuses same-byte admission replacement before rename and no-op acknowledgment", function()
		with_files(function(fixture, fresh, hold, _, write, publish)
			local adapter = fixture.make_adapter()
			for _, candidate in ipairs({ "choice", "owned" }) do
				local path = fresh("initial")
				local previous = publish(adapter, path, "initial", "owned"); hold(path)
				local foreign = fresh("owned")
				local written = write(adapter, path, "owned", candidate, function()
					assert(os.rename(foreign, path)); return true
				end)
				helpers.assert_eq(written, false)
				helpers.assert_eq(previous.matches_source(), false)
				local file = assert(io.open(path, "rb"))
				local bytes = assert(file:read("*a")); assert(file:close())
				helpers.assert_eq(bytes, "owned")
			end
		end)
	end)
end)
