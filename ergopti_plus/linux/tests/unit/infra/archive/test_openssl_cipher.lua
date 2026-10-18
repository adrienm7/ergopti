--- tests/unit/infra/archive/test_openssl_cipher.lua
--- EVP acknowledgement and resource ownership tests use an explicit ABI port.
--- Actual cipher/legacy OpenSSL byte equivalence belongs to the native fixture.
local helpers = require("tests.helpers")
local KEY, IV = string.rep("ab", 32), string.rep("cd", 16)

local function with_native(options, body)
	local calls = { freed = 0, cleansed = 0, strings = 0, contexts = 0 }
	local ffi, library = {}, {}
	local pointer = { __add = function(buffer, offset) return { base = buffer, offset = offset } end }
	function ffi.cdef() if options.declaration then error("controlled declaration refusal") end end
	function ffi.new(kind, size)
		return setmetatable({ kind = kind, size = size, [0] = 0 }, pointer)
	end
	function ffi.string(buffer, length)
		calls.strings = calls.strings + 1
		return buffer.text:sub(1, length)
	end
	function library.EVP_aes_256_cbc() if not options.no_cipher then return {} end end
	function library.EVP_CIPHER_CTX_new()
		calls.contexts = calls.contexts + 1
		if options.no_context then return nil end
		return {}
	end
	function library.EVP_CIPHER_CTX_free() calls.freed = calls.freed + 1 end
	function library.OPENSSL_cleanse(buffer)
		buffer.cleansed = true
		calls.cleansed = calls.cleansed + 1
	end
	local function status(stage)
		if options.throw == stage then error("PRIVATE controlled ABI exception") end
		return options.stage == stage and options.status or 1
	end
	function library.EVP_CipherInit_ex(_, _, _, key, iv, encrypt)
		calls.key, calls.iv, calls.encrypt = key, iv, encrypt
		return status("init")
	end
	function library.EVP_CipherUpdate(_, output, length, input, input_length)
		calls.input, calls.input_length = input, input_length
		output.text = "PRIVATE intermediate"
		length[0] = options.update_length or #output.text
		return status("update")
	end
	function library.EVP_CipherFinal_ex(_, output, length)
		output.base.text = output.base.text .. "TAIL"
		length[0] = options.final_length or 4
		return status("final")
	end
	function library.EVP_EncodeBlock(output, input, length)
		local value = type(input) == "string" and input or input.text
		output.text = require("compat.base64").encode(value:sub(1, length))
		return options.encode_status or #output.text
	end
	function library.EVP_DecodeBlock(output, input, length)
		local value = require("compat.base64").decode(input:sub(1, length))
		if not value then return -1 end
		output.text = value
		return options.decode_status or #input / 4 * 3
	end
	if options.missing_symbol then library[options.missing_symbol] = nil end
	local old_library, old_cipher = package.loaded["infra.openssl_library"], package.loaded["infra.openssl_cipher"]
	package.loaded["infra.openssl_library"] = options.no_ffi and {} or { ffi = ffi, library = library }
	package.loaded["infra.openssl_cipher"] = nil
	local ok, err = xpcall(function() body(require("infra.openssl_cipher"), calls) end, debug.traceback)
	package.loaded["infra.openssl_library"], package.loaded["infra.openssl_cipher"] = old_library, old_cipher
	if not ok then error(err, 0) end
end

helpers.describe("native AES acknowledgement ownership", function()
	for _, options in ipairs({ { no_ffi = true }, { declaration = true }, { no_cipher = true }, { missing_symbol = "EVP_CipherFinal_ex" }, { missing_symbol = "EVP_DecodeBlock" } }) do
		helpers.it("refuses missing native capability without acquisition " .. tostring(next(options)), function()
			with_native(options, function(cipher, calls)
				helpers.assert_eq(cipher.available, false)
				helpers.assert_nil(cipher.encrypt(KEY, IV, "text"))
				helpers.assert_nil(cipher.decrypt(KEY, IV, string.rep("a", 32)))
				helpers.assert_eq(calls.contexts, 0)
			end)
		end)
	end
	for _, encrypt in ipairs({ true, false }) do
		local operation = encrypt and "encrypt" or "decrypt"
		helpers.it("releases checked " .. operation .. " context and every transient byte buffer", function()
			with_native({}, function(cipher, calls)
				local input = string.rep("a", 31) .. "\0"
				helpers.assert_eq(cipher[operation](KEY, IV, input), "PRIVATE intermediateTAIL")
				helpers.assert_eq(calls.encrypt, encrypt and 1 or 0)
				helpers.assert_eq(calls.input, input)
				helpers.assert_eq(calls.input_length, 32)
				helpers.assert_eq(calls.freed, 1)
				helpers.assert_eq(calls.cleansed, 3)
				helpers.assert_true(calls.key.cleansed and calls.iv.cleansed)
				helpers.assert_eq(calls.strings, 1)
			end)
		end)
		for _, stage in ipairs({ "init", "update", "final" }) do
			for _, code in ipairs({ 0, -1, 2 }) do
				helpers.it("refuses " .. operation .. " useful partial bytes after " .. stage .. " status " .. code, function()
					with_native({ stage = stage, status = code }, function(cipher, calls)
						local result, reason = cipher[operation](KEY, IV, string.rep("x", 32))
						helpers.assert_nil(result)
						helpers.assert_eq(reason, "native AES operation refused")
						helpers.assert_eq(calls.strings, 0, "partial plaintext must not cross into a Lua string")
						helpers.assert_eq(calls.freed, 1)
						helpers.assert_eq(calls.cleansed, 3)
					end)
				end)
			end
			helpers.it("cleans up " .. operation .. " after an exception from " .. stage, function()
				with_native({ throw = stage }, function(cipher, calls)
					local result, reason = cipher[operation](KEY, IV, string.rep("x", 32))
					helpers.assert_nil(result)
					helpers.assert_true(not reason:find("PRIVATE", 1, true))
					helpers.assert_eq(calls.freed, 1)
					helpers.assert_eq(calls.cleansed, 3)
				end)
			end)
		end
	end
	for index, options in ipairs({ { update_length = -1 }, { update_length = 33 }, { final_length = -1 }, { final_length = 17 } }) do
		helpers.it("refuses invalid native output length " .. index, function()
			with_native(options, function(cipher, calls)
				helpers.assert_nil(cipher.decrypt(KEY, IV, string.rep("a", 32)))
				helpers.assert_eq(calls.strings, 0)
				helpers.assert_eq(calls.freed, 1)
				helpers.assert_eq(calls.cleansed, 3)
			end)
		end)
	end
	helpers.it("refuses absent context and malformed key/IV/ciphertext without admitting bytes", function()
		with_native({ no_context = true }, function(cipher, calls)
			helpers.assert_nil(cipher.encrypt(KEY, IV, "input"))
			helpers.assert_eq(calls.freed, 0)
			helpers.assert_eq(calls.cleansed, 2)
		end)
		with_native({}, function(cipher, calls)
			for _, values in ipairs({ { "short", IV, "input" }, { KEY, "short", "input" },
				{ string.rep("z", 64), IV, "input" }, { KEY, IV, false } }) do
				helpers.assert_nil(cipher.encrypt(values[1], values[2], values[3]))
			end
			for _, data in ipairs({ "", "x", string.rep("a", 17) }) do helpers.assert_nil(cipher.decrypt(KEY, IV, data)) end
			helpers.assert_eq(calls.contexts, 0)
		end)
	end)
end)

helpers.describe("native canonical Base64 ownership", function()
	for _, pair in ipairs({ { "", "" }, { "f", "Zg==" }, { "fo", "Zm8=" }, { "foo", "Zm9v" },
		{ "foob", "Zm9vYg==" }, { "fooba", "Zm9vYmE=" }, { "foobar", "Zm9vYmFy" }, { "a\0b", "YQBi" } }) do
		helpers.it("matches independent RFC 4648 bytes " .. pair[2], function()
			with_native({}, function(cipher)
				helpers.assert_eq(cipher.encode_base64(pair[1]), pair[2])
				helpers.assert_eq(cipher.decode_base64(pair[2]), pair[1])
			end)
		end)
	end
	for _, value in ipairs({ "Zg=", "Zg===", "Zg==\n", " Zg==", "!!!!", "=AAA", "A=AA", "AA=A", "====", "Zh==", "Zm9=" }) do
		helpers.it("rejects malformed or noncanonical Base64 " .. value:gsub("\n", "LF"), function()
			with_native({}, function(cipher) helpers.assert_nil(cipher.decode_base64(value)) end)
		end)
	end
	for _, decode in ipairs({ true, false }) do
		helpers.it("does not admit useful Base64 bytes after a refused " .. tostring(decode) .. " length ACK", function()
			with_native(decode and { decode_status = -1 } or { encode_status = -1 }, function(cipher, calls)
				local result
				if decode then result = cipher.decode_base64("Zg==") else result = cipher.encode_base64("f") end
				helpers.assert_nil(result)
				helpers.assert_eq(calls.strings, 0)
				helpers.assert_eq(calls.cleansed, 1)
			end)
		end)
	end
end)
