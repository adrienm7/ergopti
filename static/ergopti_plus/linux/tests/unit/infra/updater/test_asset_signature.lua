--- tests/unit/infra/updater/test_asset_signature.lua

--- ==============================================================================
--- MODULE: Update Asset Signature Verification (Linux)
--- DESCRIPTION:
--- The Linux bundle's detached signature (infra/asset_signature.lua) replays the
--- vectors shared with the reference tool and the Windows verifier:
--- 1. the valid record verifies through OpenSSL, and each tampered record
---    (size, name, digest) is refused with the same signature;
--- 2. a missing, malformed or truncated signature and an unusable key are closed
---    refusals, never a pass or a raised error;
--- 3. the policy decides: off logs "not enforced", required refuses everything
---    that does not verify, and a policy that requires a key without one is
---    refused at admission.
--- ==============================================================================

local helpers = require("tests.helpers")

local Signature = helpers.load_module("infra.asset_signature")
local Json = require("json")

local function read_vectors()
	local path = helpers.driver_root() .. "/../_shared/tests/corpus/updater/asset_signature_vectors.json"
	local handle = assert(io.open(path, "rb"), "the shared signature vectors must be readable")
	local raw = handle:read("*a")
	handle:close()
	return Json.decode(raw)
end

local V = read_vectors()

local function valid_record()
	return assert(Signature.record(V.record_header, V.valid.name, V.valid.size, V.valid.sha256))
end

local POLICY = {
	schema_version = 1, algorithm = "ecdsa-p256-sha256", signature_bytes = 64,
	record_header = V.record_header, signature_suffix = ".sig",
	public_key_spki_base64 = V.public_key_spki_base64, enforcement = "required",
}

local function policy(overrides)
	local copy = {}
	for key, value in pairs(POLICY) do copy[key] = value end
	for key, value in pairs(overrides or {}) do copy[key] = value end
	return copy
end

helpers.describe("update asset signature (Linux)", function()
	helpers.it("(linux-asset-signature) the record is the canonical text the reference tool signs", function()
		helpers.assert_eq(valid_record(), V.record_header .. "\n" .. V.valid.name .. "\n"
			.. string.format("%d", V.valid.size) .. "\n" .. V.valid.sha256 .. "\n")
		helpers.assert_nil((Signature.record(V.record_header, "../x", 1, V.valid.sha256)))
		helpers.assert_nil((Signature.record(V.record_header, "x", -1, V.valid.sha256)))
		helpers.assert_nil((Signature.record(V.record_header, "x", 1, string.rep("A", 64))))
	end)

	helpers.it("(linux-asset-signature) the valid vector verifies through OpenSSL", function()
		local ok, reason = Signature.verify(V.public_key_spki_base64, valid_record(), V.valid.signature_base64)
		helpers.assert_true(ok, "refused: " .. tostring(reason))
	end)

	helpers.it("(linux-asset-signature) every tampered record is refused with the valid signature", function()
		helpers.assert_true(#V.tampered >= 3)
		for _, entry in ipairs(V.tampered) do
			local record = assert(Signature.record(V.record_header, entry.name, entry.size, entry.sha256))
			local ok, reason = Signature.verify(V.public_key_spki_base64, record, V.valid.signature_base64)
			helpers.assert_true(not ok, entry.why)
			helpers.assert_eq(reason, "mismatch", entry.why)
		end
	end)

	helpers.it("(linux-asset-signature) a missing, malformed or truncated signature is a closed refusal", function()
		local record = valid_record()
		local cases = {
			{ nil, "no_signature" }, { "", "no_signature" }, { "not base64!", "malformed_signature" },
			{ "AAAA", "malformed_signature" }, { V.valid.signature_base64:sub(1, -5), "malformed_signature" },
			{ V.valid.signature_base64 .. "AA==", "malformed_signature" },
		}
		for _, case in ipairs(cases) do
			local ok, reason = Signature.verify(V.public_key_spki_base64, record, case[1])
			helpers.assert_true(not ok)
			helpers.assert_eq(reason, case[2])
		end
		local ok, reason = Signature.verify("", record, V.valid.signature_base64)
		helpers.assert_true(not ok)
		helpers.assert_eq(reason, "bad_key")
		ok, reason = Signature.verify("AAAA", record, V.valid.signature_base64)
		helpers.assert_true(not ok)
		helpers.assert_eq(reason, "bad_key", "bytes that are not a public key")
	end)

	helpers.it("(linux-asset-signature) the raw signature is wrapped as the DER sequence OpenSSL verifies", function()
		local raw = string.rep("\1", 32) .. "\128" .. string.rep("\0", 31)
		local der = Signature.raw_to_der(raw)
		helpers.assert_eq(der:byte(1), 0x30)
		helpers.assert_eq(der:byte(2), #der - 2)
		helpers.assert_eq(der:byte(3), 0x02)
		helpers.assert_eq(der:byte(37), 0x02)
		helpers.assert_eq(der:byte(38), 33, "a high bit gets a leading zero")
		helpers.assert_nil(Signature.raw_to_der("short"))
	end)

	helpers.it("(linux-asset-signature) the policy admits only what it can honour", function()
		helpers.assert_true(Signature.admit_policy(policy()) ~= nil)
		helpers.assert_true(Signature.admit_policy(policy({ enforcement = "off", public_key_spki_base64 = "" })) ~= nil)
		local refused, reason = Signature.admit_policy(policy({ public_key_spki_base64 = "" }))
		helpers.assert_nil(refused)
		helpers.assert_eq(reason, "required_without_key")
		helpers.assert_nil((Signature.admit_policy(policy({ enforcement = "maybe" }))))
		helpers.assert_nil((Signature.admit_policy(policy({ algorithm = "rsa" }))))
		helpers.assert_nil((Signature.admit_policy(nil)))
	end)

	helpers.it("(linux-asset-signature) required refuses what does not verify, off only reports it", function()
		local asset = { name = V.valid.name, size = V.valid.size, sha256 = V.valid.sha256 }
		helpers.assert_eq((Signature.evaluate(policy(), asset, V.valid.signature_base64)), "verified")
		local verdict, reason = Signature.evaluate(policy(), asset, nil)
		helpers.assert_eq(verdict, "refused")
		helpers.assert_eq(reason, "no_signature")
		local moved = { name = V.valid.name, size = V.valid.size + 1, sha256 = V.valid.sha256 }
		verdict, reason = Signature.evaluate(policy(), moved, V.valid.signature_base64)
		helpers.assert_eq(verdict, "refused")
		helpers.assert_eq(reason, "mismatch")
		local off = policy({ enforcement = "off" })
		verdict, reason = Signature.evaluate(off, asset, nil)
		helpers.assert_eq(verdict, "not_enforced")
		helpers.assert_eq(reason, "no_signature")
		helpers.assert_eq((Signature.evaluate(off, asset, V.valid.signature_base64)), "verified")
		verdict, reason = Signature.evaluate(off, moved, V.valid.signature_base64)
		helpers.assert_eq(verdict, "not_enforced")
		helpers.assert_eq(reason, "mismatch", "a bad signature is reported even while the policy is off")
		verdict, reason = Signature.evaluate(policy({ enforcement = "off", public_key_spki_base64 = "" }), asset, nil)
		helpers.assert_eq(verdict, "not_enforced")
		helpers.assert_eq(reason, "policy_off")
	end)
end)
