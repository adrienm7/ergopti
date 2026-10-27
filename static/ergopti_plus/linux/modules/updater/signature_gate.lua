--- modules/updater/signature_gate.lua

--- ==============================================================================
--- MODULE: Update Signature Gate (Linux)
--- DESCRIPTION:
--- Decides what the updater does with the detached signature of the Linux bundle
--- once the transfer has the archive's exact size and verified SHA-256. The
--- verification itself is infra/asset_signature.lua; the policy (enforcement,
--- key, record header) is the one shared file
--- _shared/modules/updater/asset_signing.json, which every verifier reads.
---
--- FEATURES & RATIONALE:
--- 1. One source for enforcement. "off" (the shipped default) installs an unsigned
---    or unverifiable release and says so in the log on every update; with a key
---    provisioned, a signature that fails is still reported although it does not
---    stop an "off" policy; "required" refuses any asset whose signature is
---    missing, malformed or wrong, with a reason a person can read.
--- 2. Fail closed on a broken policy: a policy file that cannot be read or
---    admitted refuses the update instead of silently skipping the check.
--- 3. Every dependency is injected, so the suite replays each mode without
---    OpenSSL, a network or a file system.
--- ==============================================================================

local M = {}

--- A bound on the published signature (base64 of 64 bytes is 88 characters).
M.MAX_BODY_BYTES = 4096

--- What each closed reason means, for the log and the refusal.
M.REASON_TEXT = {
	policy_off = "the signing policy is off",
	no_signature = "the release publishes no signature for the bundle",
	malformed_signature = "the published signature is malformed",
	bad_key = "the verification key of the signing policy is unusable",
	no_native = "OpenSSL is not available to verify the signature",
	mismatch = "the signature does not match the downloaded bundle",
	bad_policy = "the signing policy file is invalid",
	required_without_key = "the signing policy requires a signature but holds no key",
	bad_name = "the bundle name cannot be signed",
	bad_size = "the size of the downloaded bundle is unknown",
	bad_digest = "the digest of the downloaded bundle is unusable",
	fetch_failed = "the signature could not be downloaded",
}

--- Builds the gate.
--- @param deps table {
---   verifier = infra.asset_signature (admit_policy, evaluate),
---   read_policy = function() -> decoded asset_signing.json|nil, error,
---   asset_name = string (the bundle's file name),
---   logger = { info, warn, error }, tag = string (log tag) }
--- @return table gate { decide = function, max_body_bytes = number, signature_name = function }
function M.new(deps)
	assert(type(deps) == "table" and type(deps.verifier) == "table" and type(deps.read_policy) == "function"
		and type(deps.asset_name) == "string" and type(deps.logger) == "table", "signature_gate: bad dependencies")
	local Log, tag = deps.logger, deps.tag or "updater.signature"
	local gate = { max_body_bytes = M.MAX_BODY_BYTES }

	local function admitted_policy()
		local decoded, read_err = deps.read_policy()
		if decoded == nil then return nil, read_err or "bad_policy" end
		local policy, why = deps.verifier.admit_policy(decoded)
		if not policy then return nil, why or "bad_policy" end
		return policy
	end

	--- The file name of the detached signature, or nil when the policy is unusable.
	function gate.signature_name()
		local policy = admitted_policy()
		return policy and (deps.asset_name .. policy.signature_suffix) or nil
	end

	--- Decides one update.
	--- @param asset table { size, sha256 } of the downloaded, checksum-verified bundle.
	--- @param signature_text string|nil The downloaded signature, nil when none.
	--- @param fetch_error string|nil Why the signature download failed.
	--- @return boolean proceed
	--- @return string|nil message The refusal, in words.
	function gate.decide(asset, signature_text, fetch_error)
		local policy, why = admitted_policy()
		if not policy then
			local text = M.REASON_TEXT[why] or tostring(why)
			Log.error(tag, "Update refused: %s.", text)
			return false, "update signature policy invalid: " .. text
		end
		local subject = { name = deps.asset_name, size = asset.size, sha256 = asset.sha256 }
		local verdict, reason = deps.verifier.evaluate(policy, subject, signature_text)
		if signature_text == nil and fetch_error ~= nil and reason == "no_signature" then reason = "fetch_failed" end
		local text = M.REASON_TEXT[reason] or tostring(reason)
		if verdict == "verified" then
			Log.info(tag, "Update signature verified.")
			return true
		elseif verdict == "not_enforced" then
			Log.warn(tag, "Update signature not enforced: %s.", text)
			return true
		end
		Log.error(tag, "Update refused: %s.", text)
		return false, "update signature refused: " .. text
	end
	return gate
end

return M
