--- tests/unit/infra/test_curl_identity_exact.lua

--- ==============================================================================
--- MODULE: Test Curl Identity Exact
--- DESCRIPTION:
--- Preserves independent managed-network controls and actual production imports.
--- Source registration alone does not qualify native or installed behavior.
--- ==============================================================================

local helpers = require("tests.helpers")
local Exact = require("infra.curl_identity")
local Ports = require("tests.support.exact_identity_ports")

helpers.describe("exact native uint64 inode representation", function()
	for _, value in ipairs({ "0", "1", "9007199254740991", "9223372036855093009", "9223372036855093010", "18446744073709551615" }) do
		local literal = value
		helpers.it("accepts the independent exact decimal literal " .. literal, function()
			helpers.assert_true(Exact.is_uint64(literal))
			helpers.assert_eq(Exact.copy(Ports.identity(literal)).inode_decimal, literal)
		end)
	end
	for _, value in ipairs({ "", "01", "-1", "+1", "1.0", "1e3", " 1", "1\n", "18446744073709551616", "111111111111111111111", "１２", "1\0" }) do
		local literal = value
		helpers.it("refuses one independently malformed decimal representation", function()
			helpers.assert_eq(Exact.is_uint64(literal), false)
			helpers.assert_nil(Exact.copy(Ports.identity(literal)))
		end)
	end
	helpers.it("keeps adjacent high uint64 literals different without a Lua number", function()
		helpers.assert_eq(Exact.equal(Ports.identity("9223372036855093009"), Ports.identity("9223372036855093010")), false)
	end)
	helpers.it("snapshots scalar fields and rejects mixed representation or extra fields", function()
		local input = Ports.identity()
		local copied = Exact.copy(input)
		input.inode_decimal, input.size = "9223372036855093010", 72
		helpers.assert_eq(copied.inode_decimal, "9223372036855093009")
		helpers.assert_eq(copied.size, 71)
		input.inode = 123
		helpers.assert_nil(Exact.copy(input))
	end)
	for _, vector in ipairs({ { key = "device", value = 9007199254740992 }, { key = "mtime_nsec", value = 1000000000 },
		{ key = "size", value = -1 }, { key = "ctime_sec", value = 0 / 0 }, { key = "ctime_nsec", value = math.huge } }) do
		local fixed = vector
		helpers.it("retains the original safe scalar and nanosecond bounds", function()
			local input = Ports.identity(); input[fixed.key] = fixed.value
			helpers.assert_nil(Exact.copy(input))
		end)
	end
	for _, bytes in ipairs({ "ino:\t01\n", "ino:\t18446744073709551616\n", "ino:\t1\nino:\t1\n", "ino:\t1", "ino:\t1\r\n",
		"ino: 1\n", "inode:\t1\n", "ino:\t1\0\n", "ino:\t1\n" .. string.rep("x", 4096) .. "\n" }) do
		local fixed = bytes
		helpers.it("refuses malformed, duplicate, incomplete or oversized fdinfo", function()
			helpers.assert_nil(Exact.parse_fdinfo(fixed))
		end)
	end
end)

helpers.describe("owned exact native descriptor observation", function()
	helpers.it("pairs the existing owned image with the planned native file and retires all four descriptors", function()
		local native, state = Ports.new()
		local owner = Exact.new(native)
		local identity, path = owner:observe_owned_child(73)
		helpers.assert_eq(path, "/independent/bin/curl")
		helpers.assert_eq(identity.inode_decimal, "9223372036855093009")
		helpers.assert_eq(#state.opens, 4)
		helpers.assert_eq(#state.closes, 4)
		helpers.assert_true(owner:is_settled())
		for _, opened in ipairs(state.opens) do helpers.assert_eq(opened.flags, 2048) end
	end)
	helpers.it("independently observes the planned descriptor without requiring an unused readlink port", function()
		local native, state = Ports.new({ missing_port = "fs_readlink" })
		local owner = Exact.new(native)
		local identity = owner:observe_planned("/independent/bin/curl")
		helpers.assert_eq(identity.inode_decimal, "9223372036855093009")
		helpers.assert_eq(#state.opens, 2)
		helpers.assert_eq(#state.closes, 2)
		helpers.assert_true(owner:is_settled())
	end)
	for _, config in ipairs({ { planned_inode = "9223372036855093010" }, { changed_size = true }, { unsafe_device = true },
		{ invalid_nsec = true }, { nonregular = true }, { no_eof = true }, { image_path = "/independent/bin/curl (deleted)" },
		{ image_path = "/independent/bin/sh" }, { missing_constants = true } }) do
		local fixed = config
		helpers.it("withholds feature admission for a mismatched or unavailable bounded native receipt", function()
			local native, state = Ports.new(fixed)
			local owner = Exact.new(native)
			helpers.assert_nil(owner:observe_owned_child(73))
			helpers.assert_true(owner:is_settled())
			helpers.assert_eq(#state.opens, #state.closes)
		end)
	end
	for _, method in ipairs({ "fs_open", "fs_fstat", "fs_readlink", "fs_read", "fs_close" }) do
		for _, shape in ipairs({ "refusal", "error", "status", "throw" }) do
			local fixed_method, fixed_shape = method, shape
			helpers.it("captures every native error/status of " .. method .. " (" .. shape .. ")", function()
				local native, state = Ports.new({ fail_method = fixed_method, fail_shape = fixed_shape })
				local owner = Exact.new(native)
				helpers.assert_nil(owner:observe_owned_child(73))
				local uncertain = fixed_method == "fs_close" or (fixed_method == "fs_open" and (fixed_shape == "error" or fixed_shape == "status" or fixed_shape == "throw"))
				helpers.assert_eq(owner:is_settled(), not uncertain)
				local closes = #state.closes
				owner:cancel(); owner:cancel()
				helpers.assert_eq(#state.closes, closes, "Never retry a bare descriptor after ambiguous acquisition or close")
			end)
		end
	end
	for _, ordinal in ipairs({ 2, 3, 4 }) do
		local fixed = ordinal
		helpers.it("retains an ambiguous descriptor returned by owned acquisition " .. ordinal, function()
			local native, state = Ports.new({ fail_method = "fs_open", fail_shape = "status", fail_call = fixed })
			local owner = Exact.new(native)
			helpers.assert_nil(owner:observe_owned_child(73))
			helpers.assert_eq(owner:is_settled(), false)
			local uncertain
			for _, record in ipairs(owner._records) do
				if record.state == "uncertain-acquisition" then uncertain = record.fd end
			end
			helpers.assert_true(uncertain ~= nil)
			local closes = #state.closes
			owner:cancel()
			helpers.assert_eq(#state.closes, closes)
			for _, fd in ipairs(state.closes) do helpers.assert_true(fd ~= uncertain) end
		end)
	end
	for _, shape in ipairs({ "error", "status", "refusal", "throw" }) do
		local fixed = shape
		helpers.it("requires exact EOF-read native acknowledgement (" .. shape .. ")", function()
			local native, state = Ports.new({ fail_method = "fs_read", fail_shape = fixed, fail_call = 2 })
			local owner = Exact.new(native)
			helpers.assert_nil(owner:observe_planned("/independent/bin/curl"))
			helpers.assert_true(owner:is_settled())
			helpers.assert_eq(#state.opens, #state.closes)
		end)
	end
	helpers.it("cancellation during open captures and retires the returned descriptor before any follow-up call", function()
		local owner, captured_before_return, inside_settled
		local native, state = Ports.new({ hook = function(method)
			if method == "fs_open" then
				captured_before_return = #owner._records
				owner:cancel(); inside_settled = owner:is_settled()
			end
		end })
		owner = Exact.new(native)
		helpers.assert_nil(owner:observe_planned("/independent/bin/curl"))
		helpers.assert_eq(captured_before_return, 0)
		helpers.assert_eq(inside_settled, false)
		helpers.assert_true(owner:is_settled())
		helpers.assert_eq(#state.opens, 1)
		helpers.assert_eq(#state.closes, 1)
		helpers.assert_nil(state.method_calls.fs_fstat)
	end)
	helpers.it("registers the acquired descriptor before fstat can reenter cancellation", function()
		local owner, registered, inside_settled
		local native, state = Ports.new({ hook = function(method)
			if method == "fs_fstat" then
				registered = #owner._records == 1
				owner:cancel()
				inside_settled = owner:is_settled()
			end
		end })
		owner = Exact.new(native)
		helpers.assert_nil(owner:observe_planned("/independent/bin/curl"))
		helpers.assert_true(registered)
		helpers.assert_eq(inside_settled, false)
		helpers.assert_true(owner:is_settled())
		helpers.assert_eq(#state.opens, 1)
		helpers.assert_eq(#state.closes, 1)
	end)
	helpers.it("fences cancellation reentry while the native close operation is already in flight", function()
		local owner, inside_settled, closing_seen, hooks = nil, nil, nil, 0
		local native, state = Ports.new({ hook = function(method, fd)
			if method == "fs_close" then
				hooks = hooks + 1
				if hooks == 1 then
					for _, record in ipairs(owner._records) do if record.fd == fd then closing_seen = record.state == "closing" end end
					owner:cancel(); inside_settled = owner:is_settled()
				end
			end
		end })
		owner = Exact.new(native)
		helpers.assert_nil(owner:observe_planned("/independent/bin/curl"))
		helpers.assert_true(closing_seen)
		helpers.assert_eq(inside_settled, false)
		helpers.assert_true(owner:is_settled())
		helpers.assert_eq(#state.closes, 2)
	end)
	for _, receipt in ipairs({ { value = false }, { value = "101" }, { value = -1 },
		{ value = 9007199254740992 }, { absent = true } }) do
		local fixed = receipt
		helpers.it("retains malformed acquisition receipt uncertainty without guessing a descriptor", function()
			local native, state = Ports.new()
			native.fs_open = function() return fixed.value end
			local owner = Exact.new(native)
			helpers.assert_nil(owner:observe_planned("/independent/bin/curl"))
			helpers.assert_eq(owner:is_settled(), false)
			helpers.assert_eq(#owner._records, 0)
			helpers.assert_eq(owner:cancel(), false)
			helpers.assert_eq(#state.closes, 0)
		end)
	end
	helpers.it("refuses synchronous observation reentry without allocating or sealing the existing ledger", function()
		local owner, reentered, inside_settled, calls = nil, nil, nil, 0
		local native, state = Ports.new({ hook = function(method)
			if method == "fs_fstat" then
				calls = calls + 1
				if calls == 1 then
					reentered = owner:observe_planned("/independent/other/curl")
					inside_settled = owner:is_settled()
				end
			end
		end })
		owner = Exact.new(native)
		local identity = owner:observe_planned("/independent/bin/curl")
		helpers.assert_nil(reentered)
		helpers.assert_eq(inside_settled, false)
		helpers.assert_eq(identity.inode_decimal, "9223372036855093009")
		helpers.assert_eq(calls, 1)
		helpers.assert_eq(#state.opens, 2)
		helpers.assert_eq(#state.closes, 2)
		helpers.assert_true(owner:is_settled())
	end)
	helpers.it("cancellation before observation settles without acquiring any native descriptor", function()
		local native, state = Ports.new()
		local owner = Exact.new(native)
		helpers.assert_true(owner:cancel())
		helpers.assert_nil(owner:observe_planned("/independent/bin/curl"))
		helpers.assert_eq(#state.opens, 0)
	end)
end)
