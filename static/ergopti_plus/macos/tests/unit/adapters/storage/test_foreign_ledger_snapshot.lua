--- tests/unit/adapters/storage/test_foreign_ledger_snapshot.lua

--- ==============================================================================
--- MODULE: Foreign Ledger Prefix Receipt Tests
--- DESCRIPTION:
--- Exercises complete source rewrites, byte-budget boundaries, concurrent append,
--- and cancellation through one independently stateful file-handle model.
--- ==============================================================================

local helpers = require("tests.helpers")
local ContentDigest = require("tests.support.content_digest")

local function batch(id)
	return "BEGIN TRANSACTION;\nINSERT INTO events VALUES (" .. tostring(id) .. ");\nCOMMIT;\n"
end

--- Observe the actual reader over content-exact hash and file API doubles.
--- @param bytes string Captured physical source bytes.
--- @param prefix string Previously committed source prefix.
--- @param check function Receives adapter, reader, native state and hash oracle.
--- @param options table|nil Source mutation and legacy receipt options.
local function observe(bytes, prefix, check, options)
	options = options or {}
	helpers.with_stub_scope({ "adapters.foreign_ledger_snapshot" }, function()
		local digest = ContentDigest.create()
		local state = { source = bytes, read_bytes = 0, closes = 0, seeks = 0, live = true }
		local adapter = helpers.load_with_stubs("adapters.foreign_ledger_snapshot", { hash = {
			new = function(algorithm)
				local context = digest.new(algorithm)
				if options.hash_context then options.hash_context(context) end
				return context
			end,
		} })
		local original_open = io.open
		io.open = function(path, mode)
			if path ~= "/controlled-foreign-ledger" then return original_open(path, mode) end
			helpers.assert_eq(mode, "rb", "prefix receipts describe physical bytes without newline conversion")
			local position = 0
			return {
				seek = function(_, origin, offset)
					helpers.assert_eq(origin, "set")
					state.seeks = state.seeks + 1
					if state.seeks == 2 and options.between_passes then options.between_passes(state) end
					if state.seeks == options.refused_seek then return offset + 1 end
					position = offset
					return offset
				end,
				read = function(_, count)
					helpers.assert_true(type(count) == "number", "the reader may never request an unbounded read")
					if options.read_refusal == "nil" then return nil, "private native detail" end
					if options.read_refusal == "throw" then error("private native detail") end
					local result = state.source:sub(position + 1, position + count)
					position = position + #result
					state.read_bytes = state.read_bytes + #result
					return #result > 0 and result or nil
				end,
				close = function()
					helpers.assert_true(state.live, "a native stream must close exactly once")
					state.closes = state.closes + 1
					state.live = false
					return true
				end,
			}
		end
		local ok, err = xpcall(function()
			local expected = not options.legacy and digest.for_bytes(prefix) or nil
			local reader, failure = adapter.open("/controlled-foreign-ledger", #bytes, #prefix, expected)
			helpers.assert_nil(failure)
			check(adapter, reader, state, digest)
			adapter.close(reader)
		end, debug.traceback)
		io.open = original_open
		if not ok then error(err, 0) end
	end)
end

--- Drain bounded turns and assert their actual native byte budget.
--- @param adapter table Actual snapshot adapter.
--- @param reader table Active reader.
--- @param state table Independently counted native reads.
--- @return string status
--- @return table|string receipt
--- @return integer turns
local function drain(adapter, reader, state)
	for turn = 1, 1000 do
		local before = state.read_bytes
		local status, receipt = adapter.advance(reader)
		helpers.assert_true(state.read_bytes - before <= adapter.BYTES_PER_TURN,
			"each ingest turn must enforce its native byte budget")
		if status ~= "pending" then return status, receipt, turn end
	end
	error("reader failed to settle within the controlled turn bound")
end

helpers.describe("foreign-ledger-prefix-receipt", function()
	local first, second, third = batch(1), batch(2), batch(3)
	helpers.it("foreign-ledger-prefix-receipt: malformed persisted state fails before native source access", function()
		helpers.with_stub_scope({ "adapters.foreign_ledger_snapshot" }, function()
			local adapter = helpers.load_with_stubs("adapters.foreign_ledger_snapshot", { hash = ContentDigest.create() })
			local original_open, opens = io.open, 0
			io.open = function() opens = opens + 1; error("invalid state must not access native files") end
			local ok, err = xpcall(function()
				for _, digest in ipairs({ false, 42, "", ("x"):rep(64), ("a"):rep(63), {} }) do
					local reader, failure = adapter.open("/invalid", 100, 10, digest)
					helpers.assert_nil(reader)
					helpers.assert_eq(failure, "state")
				end
				for _, offset in ipairs({ -1, math.huge, 0 / 0, 0.5, "10" }) do
					local reader, failure = adapter.open("/invalid", 100, offset, nil)
					helpers.assert_nil(reader)
					helpers.assert_eq(failure, "state")
				end
				helpers.assert_eq(opens, 0, "invalid receipts may neither replay nor acquire native readers")
			end, debug.traceback)
			io.open = original_open
			if not ok then error(err, 0) end
		end)
	end)
	for _, case in ipairs({
		{ name = "append", old = first, source = first .. second, offset = #first, tail = second },
		{ name = "shrink", old = first:rep(100), source = first .. second, offset = 0, tail = first .. second },
		{ name = "equal-size rewrite", old = first .. second, source = third .. second,
			offset = 0, tail = third .. second },
		{ name = "larger rewrite", old = first .. second, source = third .. first .. second,
			offset = 0, tail = third .. first .. second },
		{ name = "legacy receipt", old = first, source = first .. second, offset = 0,
			tail = first .. second, legacy = true },
	}) do
		helpers.it("foreign-ledger-prefix-receipt: " .. case.name .. " imports exactly the proved generation", function()
			observe(case.source, case.old, function(adapter, reader, state, digest)
				local status, receipt = drain(adapter, reader, state)
				helpers.assert_eq(status, "ready")
				helpers.assert_eq(receipt.offset, case.offset)
				helpers.assert_eq(receipt.chunk, case.tail)
				helpers.assert_eq(receipt.applied_to, #case.source)
				helpers.assert_eq(receipt.digest, digest.for_bytes(case.source))
				helpers.assert_eq(state.closes, 1)
				helpers.assert_eq(state.live, false)
			end, { legacy = case.legacy })
		end)
	end

	helpers.it("foreign-ledger-prefix-receipt: large prefixes yield before importing their small tail", function()
		local prefix = first:rep(4000)
		observe(prefix .. second, prefix, function(adapter, reader, state)
			local status = adapter.advance(reader)
			helpers.assert_eq(status, "pending")
			helpers.assert_true(state.live, "the owner must retain its exact reader across ingest turns")
			local final, receipt, turns = drain(adapter, reader, state)
			helpers.assert_eq(final, "ready")
			helpers.assert_eq(receipt.chunk, second)
			helpers.assert_true(turns > 1)
		end)
	end)

	for split = 1, 12 do
		helpers.it("foreign-ledger-prefix-receipt: lexical carry survives native reads of " .. split .. " bytes", function()
			local quoted = "BEGIN TRANSACTION;\nINSERT INTO events VALUES ('é\nCOMMIT;\nquoted '' text');\nCOMMIT;\n"
			local partial = "BEGIN TRANSACTION;\nINSERT INTO events VALUES ('torn\nCOMMIT;\n"
			observe(quoted .. partial, "", function(adapter, reader, state, digest)
				adapter.BYTES_PER_TURN = split
				local status, receipt = drain(adapter, reader, state)
				helpers.assert_eq(status, "ready")
				helpers.assert_eq(receipt.chunk, quoted)
				helpers.assert_eq(receipt.applied_to, #quoted)
				helpers.assert_eq(receipt.digest, digest.for_bytes(quoted))
			end)
		end)
	end

	helpers.it("foreign-ledger-prefix-receipt: a prefix mutation between passes refuses publication", function()
		observe(first .. second, first, function(adapter, reader, state)
			local status, failure = drain(adapter, reader, state)
			helpers.assert_eq(status, "failed")
			helpers.assert_eq(failure, "hash")
			helpers.assert_eq(state.live, false)
		end, { between_passes = function(state) state.source = third .. second end })
	end)

	helpers.it("foreign-ledger-prefix-receipt: concurrent append cannot invalidate the captured complete prefix", function()
		observe(first .. second, first, function(adapter, reader, state, digest)
			local status, receipt = drain(adapter, reader, state)
			helpers.assert_eq(status, "ready")
			helpers.assert_eq(receipt.chunk, second)
			helpers.assert_eq(receipt.applied_to, #first + #second)
			helpers.assert_eq(receipt.digest, digest.for_bytes(first .. second))
		end, { between_passes = function(state) state.source = state.source .. third end })
	end)

	helpers.it("foreign-ledger-prefix-receipt: cancellation releases a partially verified stream without a receipt", function()
		local prefix = first:rep(4000)
		observe(prefix .. second, prefix, function(adapter, reader, state)
			helpers.assert_eq(adapter.advance(reader), "pending")
			helpers.assert_true(state.live)
			helpers.assert_eq(adapter.close(reader), true)
			helpers.assert_eq(state.live, false)
			helpers.assert_eq(adapter.close(reader), true)
			helpers.assert_eq(state.closes, 1)
		end)
	end)

	for _, failure in ipairs({ "nil", "throw" }) do
		helpers.it("foreign-ledger-prefix-receipt: " .. failure .. " read refusal releases its handle without bytes", function()
			observe(first .. second, first, function(adapter, reader, state)
				local status, receipt = drain(adapter, reader, state)
				helpers.assert_eq(status, "failed")
				helpers.assert_eq(receipt, "read", "private native details must not escape as an import receipt")
				helpers.assert_eq(state.live, false)
			end, { read_refusal = failure })
		end)
	end
	for _, method in ipairs({ "append", "finish", "value" }) do
		helpers.it("foreign-ledger-prefix-receipt: hash " .. method .. " refusal preserves no readable receipt", function()
			observe(first .. second, first, function(adapter, reader, state)
				local status, receipt = drain(adapter, reader, state)
				helpers.assert_eq(status, "failed")
				helpers.assert_eq(receipt, "hash")
				helpers.assert_eq(state.live, false)
			end, { hash_context = function(context) context[method] = function() return nil end end })
		end)
	end
	helpers.it("foreign-ledger-prefix-receipt: refused rewind closes the scan without reusing an invalid position", function()
		observe(first .. second, first, function(adapter, reader, state)
			local status, receipt = drain(adapter, reader, state)
			helpers.assert_eq(status, "failed")
			helpers.assert_eq(receipt, "seek")
			helpers.assert_eq(state.live, false)
		end, { refused_seek = 2 })
	end)
end)
