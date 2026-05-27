// static/ergopti_plus/shared/ports/HttpClient.spec.js

/**
 * ==============================================================================
 * PORT: HttpClient
 * DESCRIPTION:
 * Contract for the OS-level HTTP request port. Every driver adapter that
 * makes outbound HTTP calls (primarily for LLM API access) MUST satisfy this
 * interface. The port is deliberately minimal: POST only, JSON body, JSON or
 * text response. Streaming SSE is out of scope for this version.
 *
 * FEATURES & RATIONALE:
 * 1. Callback-based completion: both synchronous (AHK WinHttp COM object) and
 *    asynchronous (HS hs.http.asyncPost) adapters expose an identical surface.
 *    On AHK the callback is called inline before post() returns; on HS it is
 *    deferred to the next runloop cycle. Callers must never assume which.
 * 2. Timeout enforcement: every request is bound by a per-adapter timeout
 *    constant (default 30 s). Adapters MUST call the callback with an error
 *    result on timeout — never hang indefinitely.
 * 3. Provider catalogue: the adapter holds connection profiles (base URL,
 *    API key, format selector). The domain layer passes a profile id; the
 *    adapter resolves the endpoint and auth header.
 * 4. No retry logic: retries are a domain concern. The adapter fires once and
 *    reports success or failure.
 * ==============================================================================
 */

"use strict";




// ==================================================
// ==================================================
// ======= 1/ Port Contract Definition =======
// ==================================================
// ==================================================

/**
 * The HttpClient port contract.
 * @type {object}
 */
const portContract = {
	name: "HttpClient",
	version: "1.0.0",

	/**
	 * post(url, headers, body, callback) — Send an HTTP POST request.
	 *   @param {string}   url       Absolute HTTPS URL.
	 *   @param {object}   headers   Key→value header map (e.g. Authorization, Content-Type).
	 *   @param {string}   body      JSON-encoded request body.
	 *   @param {Function} callback  Called with (result) on completion:
	 *     result.ok      {boolean}  true = HTTP 2xx, false = any error
	 *     result.status  {number}   HTTP status code (0 on network error / timeout)
	 *     result.body    {string}   Raw response body (empty string on error)
	 *     result.error   {string|null} Human-readable error message, or null on success
	 *   @returns {void}  The caller must not rely on a return value.
	 *   @error_behavior "log_and_return" — network errors call callback({ok:false, …}).
	 *
	 * cancel() — Abort any in-flight request immediately.
	 *   The callback is NOT called after cancel().
	 *   @returns {void}
	 *   @error_behavior "ignore" — safe to call when no request is in flight.
	 *
	 * isActive() — Returns true if a request is currently in flight.
	 *   @returns {boolean}
	 */
	methods: {
		post:     { arity: 4, required: true },
		cancel:   { arity: 0, required: true },
		isActive: { arity: 0, required: true },
	},

	/** Default request timeout in milliseconds. Adapters MUST enforce this. */
	DEFAULT_TIMEOUT_MS: 30_000,
};




// ==================================================
// ==================================================
// ======= 2/ Adapter Structural Validator =======
// ==================================================
// ==================================================

/**
 * Checks structural compliance of an HttpClient adapter.
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
// ======= 3/ Compliance Test Vectors =======
// ==================================================
// ==================================================

/**
 * Returns test vectors for HttpClient compliance.
 * Test harnesses MUST intercept outbound HTTP and stub responses.
 * @returns {Array<object>}
 */
function contractTestVectors() {
	return [
		{
			id: "post_success_200",
			description: "Successful 200 response calls callback with ok=true.",
			stub: { status: 200, body: '{"choices":[{"message":{"content":"hello"}}]}' },
			input: {
				url:     "https://api.example.com/v1/chat/completions",
				headers: { "Content-Type": "application/json", "Authorization": "Bearer sk-test" },
				body:    '{"model":"gpt-4o","messages":[]}',
			},
			assert: { ok: true, status: 200, error: null },
		},
		{
			id: "post_auth_error_401",
			description: "HTTP 401 calls callback with ok=false and status=401.",
			stub: { status: 401, body: '{"error":"invalid api key"}' },
			input: {
				url: "https://api.example.com/v1/chat/completions",
				headers: { "Authorization": "Bearer bad-key" },
				body: "{}",
			},
			assert: { ok: false, status: 401 },
		},
		{
			id: "post_network_error",
			description: "Network failure calls callback with ok=false and status=0.",
			stub: { network_error: true },
			input: {
				url: "https://unreachable.invalid/v1/endpoint",
				headers: {},
				body: "{}",
			},
			assert: { ok: false, status: 0, error_not_null: true },
		},
		{
			id: "post_timeout",
			description: "Request exceeding DEFAULT_TIMEOUT_MS calls callback with ok=false.",
			stub: { delay_ms: 31_000 },   // longer than the 30 s timeout
			input: { url: "https://slow.example.com/api", headers: {}, body: "{}" },
			assert: { ok: false, status: 0 },
		},
		{
			id: "cancel_stops_callback",
			description: "cancel() before response means callback is never called.",
			stub: { delay_ms: 500 },
			input: { url: "https://api.example.com/v1/chat", headers: {}, body: "{}" },
			steps: [
				{ call: "post", async: true },
				{ advance_clock_ms: 100 },
				{ call: "cancel" },
				{ advance_clock_ms: 500 },
				{ assert: "callback_not_called" },
			],
		},
		{
			id: "is_active_during_request",
			description: "isActive() returns true while a request is in flight.",
			stub: { delay_ms: 200 },
			steps: [
				{ call: "post", async: true },
				{ assert: "isActive", expected: true },
				{ advance_clock_ms: 200 },
				{ assert: "isActive", expected: false },
			],
		},
	];
}


module.exports = { portContract, validateAdapter, contractTestVectors };
