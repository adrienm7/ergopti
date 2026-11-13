--- tests/unit/modules/llm/vectors/test_rs256_signer_vectors.lua

--- ==============================================================================
--- MODULE: RS256 Signer Corpus (macOS)
--- DESCRIPTION:
--- Replays _shared/tests/corpus/crypto/rs256_vectors.json through
--- _shared/core/crypto/engine/sha256.lua and _shared/core/crypto/engine/rsa_pkcs1.lua: SHA-256
--- digests, RSASSA-PKCS1-v1_5 signatures made by an independent
--- implementation under PKCS#8 and PKCS#1 test keys of 2048 and 3072 bits,
--- the sliced signature, and the keys refused with their reasons.
---
--- ROOT CAUSE ENCODED:
--- A Google service-account key needs its assertion signed RS256; with no
--- signer in the tree, Vertex AI refused every service-account key.
--- ==============================================================================

local helpers = require("tests.helpers")
local json = require("core.text.engine.json")

local shared_lua = helpers.shared("/")
package.path = shared_lua .. "?.lua;" .. shared_lua .. "?/init.lua;" .. package.path
local Rsa = require("core.crypto.engine.rsa_pkcs1")
local Sha256 = require("core.crypto.engine.sha256")

--- @param path string Shared-relative path.
--- @return string
local function shared_path(path) return helpers.shared(path) end




-- ============================================
-- ======= 1/ Fixtures ========================
-- ============================================

--- @param path string Shared-relative JSON path.
--- @return table decoded
local function read_json(path)
	local fh = assert(io.open(shared_path(path), "r"), "cannot open " .. path)
	local raw = fh:read("*a")
	fh:close()
	return assert(json.decode(raw), path .. " is not valid JSON")
end

--- Raw bytes of a hexadecimal string.
local function unhex(text)
	return (text:gsub("..", function(pair) return string.char(tonumber(pair, 16)) end))
end

--- Hexadecimal string of raw bytes.
local function hex(bytes)
	return (bytes:gsub(".", function(char) return string.format("%02x", char:byte()) end))
end

--- A PEM block from a label and its armorless Base64 body.
local function pem(label, body)
	local lines = {}
	for i = 1, #body, 64 do lines[#lines + 1] = body:sub(i, i + 63) end
	return "-----BEGIN " .. label .. "-----\n" .. table.concat(lines, "\n") .. "\n-----END " .. label .. "-----\n"
end




-- ============================================
-- ======= 2/ Corpus replay ===================
-- ============================================

helpers.describe("the RS256 signer replays the shared corpus", function()
	local corpus = read_json("tests/corpus/crypto/rs256_vectors.json")

	helpers.it("the corpus holds digests, signatures under three keys and refusals", function()
		helpers.assert_true(#corpus.sha256 >= 4 and #corpus.signatures >= 12 and #corpus.refusals >= 6)
	end)

	for index, v in ipairs(corpus.sha256) do
		helpers.it("sha256 vector " .. index .. " (" .. (#v.hex_message / 2) .. " bytes)", function()
			helpers.assert_eq(Sha256.hex(unhex(v.hex_message)), v.digest)
		end)
	end

	local keys = {}
	for _, v in ipairs(corpus.signatures) do
		helpers.it("signature under " .. v.key .. " of " .. #v.message .. " byte(s)", function()
			local spec = corpus.keys[v.key]
			keys[v.key] = keys[v.key] or assert(Rsa.read_private_key(pem(spec.label, spec.body)))
			local signature = assert(Rsa.sign_sha256(keys[v.key], v.message))
			helpers.assert_eq(hex(signature), v.signature)
		end)
	end

	helpers.it("a paused signature yields between slices and gives the same bytes", function()
		local spec = corpus.keys.rsa2048_pkcs8
		local key = assert(Rsa.read_private_key(pem(spec.label, spec.body)))
		local worker = coroutine.create(function() return Rsa.sign_sha256(key, "abc", coroutine.yield) end)
		local slices, signature = 0, nil
		repeat
			local resumed, value = coroutine.resume(worker)
			helpers.assert_true(resumed, tostring(value))
			slices, signature = slices + 1, value
		until coroutine.status(worker) == "dead"
		helpers.assert_true(slices > 10, slices .. " slice(s)")
		for _, v in ipairs(corpus.signatures) do
			if v.key == "rsa2048_pkcs8" and v.message == "abc" then helpers.assert_eq(hex(signature), v.signature) end
		end
	end)

	for _, v in ipairs(corpus.refusals) do
		helpers.it("refusal: " .. v.name, function()
			local key, reason = Rsa.read_private_key(pem(v.label, v.body))
			if v.sign_reason then
				helpers.assert_true(key ~= nil, tostring(reason))
				local signature, sign_reason = Rsa.sign_sha256(key, "abc")
				helpers.assert_nil(signature)
				helpers.assert_eq(sign_reason, v.sign_reason)
				return
			end
			helpers.assert_nil(key)
			helpers.assert_eq(reason, v.reason)
		end)
	end

	helpers.it("no refusal reason quotes the key", function()
		for _, v in ipairs(corpus.refusals) do
			local _, reason = Rsa.read_private_key(pem(v.label, v.body))
			if reason then helpers.assert_true(not reason:find(v.body:sub(1, 16), 1, true), v.name) end
		end
	end)

	helpers.it("a key without its PEM armour is refused", function()
		local key, reason = Rsa.read_private_key(corpus.keys.rsa2048_pkcs8.body)
		helpers.assert_nil(key)
		helpers.assert_eq(reason, "the private key is no PEM block")
	end)
end)
