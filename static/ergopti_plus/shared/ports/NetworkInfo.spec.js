// static/ergopti_plus/shared/ports/NetworkInfo.spec.js

/**
 * ==============================================================================
 * PORT: NetworkInfo
 * DESCRIPTION:
 * Contract for reading the current network environment of the host machine.
 * Adapters implementing this port surface Wi-Fi SSID (hashed for privacy),
 * signal quality, internet reachability, and VPN presence without exposing
 * raw adapter names or IP addresses to domain logic.
 *
 * FEATURES & RATIONALE:
 * 1. Privacy-first design: getSsidHash() returns a SHA-256 hex digest of the
 *    SSID, never the raw network name, so the call-site never handles PII.
 * 2. Lightweight polling: all methods reflect cached OS state; none open
 *    sockets or spawn subprocesses. Callers may poll on a timer without
 *    risking input-thread stalls.
 * 3. Nullable returns: when information is genuinely unavailable (no Wi-Fi
 *    adapter, airplane mode, restricted process), methods return null rather
 *    than throwing. Callers MUST null-check before using the value.
 * ==============================================================================
 */

"use strict";




// ==================================================
// ==================================================
// ======= 1/ Port Contract Definition ==============
// ==================================================
// ==================================================

/**
 * The NetworkInfo port contract.
 * @type {object}
 */
const portContract = {
	name: "NetworkInfo",
	version: "1.0.0",

	/**
	 * getSsidHash() — Return a SHA-256 hex digest of the active Wi-Fi SSID.
	 *   @returns {string|null} Hex string when Wi-Fi is connected, null otherwise.
	 *   @error_behavior "return_null".
	 *
	 * getSignalStrength() — Return the Wi-Fi signal quality as a percentage (0-100).
	 *   @returns {number|null} Integer 0-100 when Wi-Fi is connected, null otherwise.
	 *   @error_behavior "return_null".
	 *
	 * isInternetReachable() — Return whether the host has a working internet connection.
	 *   @returns {boolean} true if reachable, false otherwise.
	 *   @error_behavior "return_false".
	 *
	 * isVpnActive() — Return whether at least one VPN adapter is currently up.
	 *   @returns {boolean} true if a VPN adapter is detected, false otherwise.
	 *   @error_behavior "return_false".
	 */
	methods: {
		getSsidHash:          { arity: 0, required: true },
		getSignalStrength:    { arity: 0, required: true },
		isInternetReachable:  { arity: 0, required: true },
		isVpnActive:          { arity: 0, required: true },
	},
};




// ==================================================
// ==================================================
// ======= 2/ Adapter Structural Validator ==========
// ==================================================
// ==================================================

/**
 * Checks structural compliance of a NetworkInfo adapter.
 * @param {object} adapter
 * @returns {string[]} Violations. Empty = compliant.
 */
function validateAdapter(adapter) {
	const violations = [];
	if (!adapter || typeof adapter !== "object") {
		return ["adapter must be a non-null object"];
	}
	for (const [name, spec] of Object.entries(portContract.methods)) {
		if (!spec.required) continue;
		if (typeof adapter[name] !== "function") {
			violations.push(`missing method: ${name}`);
		} else if (adapter[name].length !== spec.arity) {
			violations.push(
				`method ${name}: expected arity ${spec.arity}, got ${adapter[name].length}`
			);
		}
	}
	return violations;
}




// ==================================================
// ==================================================
// ======= 3/ Compliance Test Vectors ===============
// ==================================================
// ==================================================

/**
 * Returns test vectors for NetworkInfo compliance.
 * @returns {Array<object>}
 */
function contractTestVectors() {
	return [
		{
			id: "get_ssid_hash_returns_string_or_null",
			description: "getSsidHash() returns a hex string or null — never throws.",
			steps: [
				{ call: "getSsidHash" },
				{ assert: "return_string_or_null" },
				{ assert: "no_exception" },
			],
		},
		{
			id: "get_signal_strength_returns_number_or_null",
			description: "getSignalStrength() returns a number 0-100 or null — never throws.",
			steps: [
				{ call: "getSignalStrength" },
				{ assert: "return_number_or_null" },
				{ assert: "no_exception" },
			],
		},
		{
			id: "is_internet_reachable_returns_bool",
			description: "isInternetReachable() always returns a boolean — never throws.",
			steps: [
				{ call: "isInternetReachable" },
				{ assert: "return_boolean" },
				{ assert: "no_exception" },
			],
		},
		{
			id: "is_vpn_active_returns_bool",
			description: "isVpnActive() always returns a boolean — never throws.",
			steps: [
				{ call: "isVpnActive" },
				{ assert: "return_boolean" },
				{ assert: "no_exception" },
			],
		},
	];
}


module.exports = { portContract, validateAdapter, contractTestVectors };
