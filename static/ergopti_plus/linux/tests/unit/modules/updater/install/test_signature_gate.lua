--- tests/unit/modules/updater/install/test_signature_gate.lua

--- ==============================================================================
--- MODULE: Update Signature Gate (Linux)
--- DESCRIPTION:
--- The gate the updater transfer asks before it releases a downloaded bundle,
--- replayed with the real verifier and the vectors shared with the reference tool:
--- 1. a good signature verifies in every enforcement mode;
--- 2. a bad or a missing signature is refused in words when enforcement is
---    "required", and only logged in words when it is "off" (the default);
--- 3. a policy that cannot be read or admitted refuses instead of skipping;
--- 4. the shipped policy is off, so an unsigned release still installs;
--- 5. a release read from the public feed installs only on a verified
---    signature, whatever the enforcement, and never without a key.
--- ==============================================================================

local helpers = require("tests.helpers")

local Gate = helpers.load_module("modules.updater.signature_gate")
local Signature = helpers.load_module("infra.asset_signature")
local Json = require("core.text.engine.json")

local function read_json(relative)
	local handle = assert(io.open(helpers.driver_root() .. "/../_shared/" .. relative, "rb"))
	local raw = handle:read("*a")
	handle:close()
	return Json.decode(raw)
end

local V = read_json("tests/corpus/updater/asset_signature_vectors.json")
local SHIPPED = read_json("updater/data/asset_signing.json")

local function policy(enforcement, key)
	local copy = {}
	for name, value in pairs(SHIPPED) do copy[name] = value end
	copy.enforcement = enforcement
	copy.public_key_spki_base64 = key == nil and V.public_key_spki_base64 or key
	return copy
end

local function build(decoded, read_error)
	local lines = {}
	local function record(level)
		return function(_, format, ...) lines[#lines + 1] = level .. ": " .. string.format(format, ...) end
	end
	local gate = Gate.new({
		verifier = Signature,
		read_policy = function() return decoded, read_error end,
		asset_name = V.valid.name,
		logger = { info = record("info"), warn = record("warn"), error = record("error") },
		tag = "test",
	})
	return gate, lines
end

local ASSET = { size = V.valid.size, sha256 = V.valid.sha256 }
local MOVED = { size = V.valid.size + 1, sha256 = V.valid.sha256 }

helpers.describe("update signature gate (Linux)", function()
	helpers.it("(signature-gate) the shipped policy is off, so an unsigned release installs", function()
		helpers.assert_eq(SHIPPED.enforcement, "off")
		local gate, lines = build(SHIPPED)
		helpers.assert_eq(gate.signature_name(), V.valid.name .. ".sig")
		helpers.assert_true((gate.decide(ASSET, nil, nil)))
		helpers.assert_true(lines[1]:find("not enforced: the signing policy is off", 1, true) ~= nil, lines[1])
	end)

	helpers.it("(signature-gate) a good signature verifies in every mode", function()
		for _, mode in ipairs({ "off", "required" }) do
			local gate, lines = build(policy(mode))
			helpers.assert_true((gate.decide(ASSET, V.valid.signature_base64, nil)), mode)
			helpers.assert_eq(lines[1], "info: Update signature verified.")
		end
	end)

	helpers.it("(signature-gate) accepts the LF-terminated release signature file", function()
		local gate, lines = build(policy("required"))
		helpers.assert_true(gate.decide(ASSET, V.valid.signature_base64 .. "\n"),
			"the release signer writes one terminal LF")
		helpers.assert_eq(lines[1], "info: Update signature verified.")
		local invalid = build(policy("required"))
		helpers.assert_true(not invalid.decide(ASSET, V.valid.signature_base64 .. "\nextra"))
	end)

	helpers.it("(signature-gate) required refuses a bad signature in words", function()
		local gate, lines = build(policy("required"))
		local accepted, message = gate.decide(MOVED, V.valid.signature_base64, nil)
		helpers.assert_eq(accepted, false)
		helpers.assert_eq(message, "update signature refused: the signature does not match the downloaded bundle")
		helpers.assert_true(lines[1]:find("^error: Update refused") ~= nil, lines[1])
	end)

	helpers.it("(signature-gate) required refuses a missing signature, off only logs it", function()
		local gate = build(policy("required"))
		local accepted, message = gate.decide(ASSET, nil, nil)
		helpers.assert_eq(accepted, false)
		helpers.assert_true(message:find("publishes no signature", 1, true) ~= nil, message)
		accepted, message = gate.decide(ASSET, nil, "HTTP 404")
		helpers.assert_eq(accepted, false)
		helpers.assert_true(message:find("could not be downloaded", 1, true) ~= nil, message)
		local lenient, lines = build(policy("off"))
		helpers.assert_true((lenient.decide(ASSET, nil, nil)))
		helpers.assert_true(lines[1]:find("^warn: Update signature not enforced: the release publishes no signature") ~= nil, lines[1])
	end)

	helpers.it("(signature-gate) off reports a bad signature but does not stop the update", function()
		local gate, lines = build(policy("off"))
		helpers.assert_true((gate.decide(MOVED, V.valid.signature_base64, nil)))
		helpers.assert_true(lines[1]:find("does not match the downloaded bundle", 1, true) ~= nil, lines[1])
	end)

	-- A release read from the public feed has no digest from the API: its
	-- signature is all that authenticates it, so "off" must not let it through.
	helpers.it("(feed-signature-required) a feed release needs a verified signature in every mode", function()
		for _, mode in ipairs({ "off", "required" }) do
			local gate, lines = build(policy(mode))
			helpers.assert_true(gate.has_key(), mode)
			helpers.assert_true((gate.decide(ASSET, V.valid.signature_base64, nil, true)), mode)
			helpers.assert_eq(lines[1], "info: Update signature verified.")
			local accepted, message = gate.decide(ASSET, nil, "HTTP 404", true)
			helpers.assert_eq(accepted, false, mode .. ": a missing signature")
			helpers.assert_true(message:find("could not be downloaded", 1, true) ~= nil, message)
			accepted, message = gate.decide(MOVED, V.valid.signature_base64, nil, true)
			helpers.assert_eq(accepted, false, mode .. ": a moved size")
			helpers.assert_true(message:find("does not match", 1, true) ~= nil, message)
		end
	end)

	helpers.it("(feed-signature-required) without a key a feed release is refused in words", function()
		local gate, lines = build(SHIPPED)
		helpers.assert_eq(gate.has_key(), false, "the shipped policy holds no key yet")
		local accepted, message = gate.decide(ASSET, V.valid.signature_base64, nil, true)
		helpers.assert_eq(accepted, false)
		helpers.assert_true(message:find("read from the public feed cannot be verified", 1, true) ~= nil, message)
		helpers.assert_true(lines[1]:find("^error: Update refused") ~= nil, lines[1])
		local broken = build(nil, "bad_policy")
		helpers.assert_eq(broken.has_key(), false)
	end)

	helpers.it("(signature-gate) an unusable policy refuses instead of skipping the check", function()
		local gate, lines = build(nil, "bad_policy")
		helpers.assert_nil(gate.signature_name())
		local accepted, message = gate.decide(ASSET, V.valid.signature_base64, nil)
		helpers.assert_eq(accepted, false)
		helpers.assert_true(message:find("policy invalid", 1, true) ~= nil, message)
		helpers.assert_true(lines[1]:find("^error:") ~= nil, lines[1])
		gate = build(policy("required", ""))
		accepted, message = gate.decide(ASSET, V.valid.signature_base64, nil)
		helpers.assert_eq(accepted, false)
		helpers.assert_true(message:find("holds no key", 1, true) ~= nil, message)
	end)
end)
