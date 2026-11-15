; modules/llm/api_token_exchange.ahk

; ==============================================================================
; MODULE: API Token Exchange
; DESCRIPTION:
; IBM watsonx wants an IAM access token exchanged from the user's API key, Google
; Vertex AI an OAuth access token refreshed from the user's credentials or signed
; for with a service-account key. Windows port of the pure
; _shared/ai/engine/api/token_exchange.lua and of the access lease of macOS and
; Linux's api_remote.lua, replaying _shared/tests/corpus/llm/api_token_exchange_vectors.json.
;
; FEATURES & RATIONALE:
; 1. One exchange at a time per provider and key: every request waiting for it is
;    a waiter of the same slot, so a keystroke's cancelled prediction neither
;    restarts nor cancels the exchange the next one needs.
; 2. A refused exchange waits LLM_TOKEN_EXCHANGE_RETRY_SECONDS, so a bad key does
;    not reach the token service on every keystroke. Its answer arrives at once.
; 3. Never on the requesting thread: the form (with its native RS256 signature,
;    rs256_signer.ahk) is built from a one-shot timer and posted by the managed
;    worker, polled like any other remote request.
; 4. The key file's own token_uri is never followed: the assertion goes to the
;    catalogue's token_url only, so a key cannot send its assertion elsewhere.
; 5. No key, assertion or token reaches a log or a refusal. Tokens live in memory.
;    A refusal is the corpus's sentence, shared by every driver, not a closed log reason.
; ==============================================================================

#Requires AutoHotkey v2.0
#Include rs256_signer.ahk





; ===============================
; ===============================
; ======= 1/ Module State =======
; ===============================
; ===============================

; Bounds of the lifetimes, in seconds: an answer outside them is brought back
; inside, so a token is never refreshed on every request.
global LLM_TOKEN_EXCHANGE_MIN_EXPIRES_SECONDS := 60
global LLM_TOKEN_EXCHANGE_MAX_EXPIRES_SECONDS := 86400
; The longest signed assertion: Google refuses one valid over an hour
global LLM_TOKEN_EXCHANGE_MAX_ASSERTION_SECONDS := 3600
; Seconds before a failed exchange is tried again
global LLM_TOKEN_EXCHANGE_RETRY_SECONDS := 60
global LLM_TOKEN_EXCHANGE_FIELD_NAME := "^[A-Za-z_][A-Za-z0-9_]*$"
global LLM_TOKEN_EXCHANGE_HTTPS := "^https://[^\s{}]+$"

; Provider and key -> Map("token", "expires_at", "pending", "waiters", "failure", "retry_at")
global _LLM_TokenExchange_Slots := Map()

; Test seam, 0 in production: (Request, OnAnswer(Map("status", "body"[, "network_report"]))).
global _LLM_TokenExchange_PostFn := 0




; ===================================
; ===================================
; ======= 2/ Catalogue Block ========
; ===================================
; ===================================

_LLM_TokenExchange_IsField(Value) {
	global LLM_TOKEN_EXCHANGE_FIELD_NAME
	return (Value is String) && RegExMatch(Value, LLM_TOKEN_EXCHANGE_FIELD_NAME)
}

_LLM_TokenExchange_IsWhole(Value) {
	return (Value is Integer) || ((Value is Float) && Value == Floor(Value))
}

; Reads a form body block.
; @param {Any} Raw The block.
; @param {String} Where Its name in the refusals.
; @param {Boolean} Signed Whether {assertion} is the placeholder it must hold.
; @param {VarRef} Refusal Why it is refused.
; @returns {Boolean}
_LLM_TokenExchange_BodyIsValid(Raw, Where, Signed, &Refusal) {
	if !(Raw is Map) || Raw.Count == 0 {
		Refusal := Where . " must be a non-empty object"
		return false
	}
	UsesKey := false
	for Name, Value in Raw {
		if !_LLM_TokenExchange_IsField(Name) || !(Value is String) {
			Refusal := Where . " fields must be names holding strings"
			return false
		}
		At := 1
		while RegExMatch(Value, "\{([^}]*)\}", &Found, At) {
			Placeholder := Found[1]
			Known := Signed ? (Placeholder == "assertion")
				: (Placeholder == "key" || (SubStr(Placeholder, 1, 4) == "key."
					&& _LLM_TokenExchange_IsField(SubStr(Placeholder, 5))))
			if !Known {
				Refusal := Where . "." . Name . " holds an unknown placeholder {" . Placeholder . "}"
				return false
			}
			UsesKey := true
			At := Found.Pos + Found.Len
		}
	}
	if !UsesKey {
		Refusal := Where . (Signed ? " never reads the assertion" : " never reads the key")
		return false
	}
	return true
}

; @returns {Boolean} Whether the signed-assertion block holds.
_LLM_TokenExchange_AssertionIsValid(Raw, &Refusal) {
	global LLM_TOKEN_EXCHANGE_MIN_EXPIRES_SECONDS, LLM_TOKEN_EXCHANGE_MAX_ASSERTION_SECONDS, LLM_TOKEN_EXCHANGE_HTTPS
	if !(Raw is Map) {
		Refusal := "auth.assertion must be an object"
		return false
	}
	if !_LLM_TokenExchange_IsField(Raw.Get("key_type", 0)) {
		Refusal := "auth.assertion.key_type must be a key type name"
		return false
	}
	if !_LLM_TokenExchange_BodyIsValid(Raw.Get("body", 0), "auth.assertion.body", true, &Refusal)
		return false
	for Field in ["issuer_field", "private_key_field"] {
		if !_LLM_TokenExchange_IsField(Raw.Get(Field, 0)) {
			Refusal := "auth.assertion." . Field . " must be a field name"
			return false
		}
	}
	if Raw.Has("key_id_field") && !_LLM_TokenExchange_IsField(Raw["key_id_field"]) {
		Refusal := "auth.assertion.key_id_field must be a field name"
		return false
	}
	Scope := Raw.Get("scope", 0)
	if !(Scope is String) || !RegExMatch(Scope, LLM_TOKEN_EXCHANGE_HTTPS) {
		Refusal := "auth.assertion.scope must be an https scope"
		return false
	}
	Lifetime := Raw.Get("lifetime_seconds", 0)
	if !_LLM_TokenExchange_IsWhole(Lifetime) || Lifetime < LLM_TOKEN_EXCHANGE_MIN_EXPIRES_SECONDS
			|| Lifetime > LLM_TOKEN_EXCHANGE_MAX_ASSERTION_SECONDS {
		Refusal := "auth.assertion.lifetime_seconds must be a whole number of seconds in bounds"
		return false
	}
	return true
}

/**
 * Reads a provider's auth block (api_providers.json).
 * @param {Any} Raw providers.<id>.auth.
 * @param {VarRef} Refusal Receives why it is refused, "" when valid.
 * @returns {Map|String} The block, "" when refused.
 */
LLM_TokenExchange_Parse(Raw, &Refusal := "") {
	global LLM_TOKEN_EXCHANGE_MIN_EXPIRES_SECONDS, LLM_TOKEN_EXCHANGE_MAX_EXPIRES_SECONDS, LLM_TOKEN_EXCHANGE_HTTPS
	Refusal := ""
	if !(Raw is Map) {
		Refusal := "auth must be an object"
		return ""
	}
	if (Raw.Get("kind", "") != "token_exchange") {
		Refusal := "auth.kind must be token_exchange"
		return ""
	}
	TokenUrl := Raw.Get("token_url", 0)
	if !(TokenUrl is String) || !RegExMatch(TokenUrl, LLM_TOKEN_EXCHANGE_HTTPS) {
		Refusal := "auth.token_url must be an https address"
		return ""
	}
	if !_LLM_TokenExchange_BodyIsValid(Raw.Get("body", 0), "auth.body", false, &Refusal)
		return ""
	for Field in ["token_field", "expires_field"] {
		if !_LLM_TokenExchange_IsField(Raw.Get(Field, 0)) {
			Refusal := "auth." . Field . " must be a field name"
			return ""
		}
	}
	Default := Raw.Get("default_expires_seconds", 0), Margin := Raw.Get("refresh_margin_seconds", -1)
	if !_LLM_TokenExchange_IsWhole(Default) || Default < LLM_TOKEN_EXCHANGE_MIN_EXPIRES_SECONDS
			|| Default > LLM_TOKEN_EXCHANGE_MAX_EXPIRES_SECONDS {
		Refusal := "auth.default_expires_seconds must be a whole number of seconds in bounds"
		return ""
	}
	if !_LLM_TokenExchange_IsWhole(Margin) || Margin < 0 || Margin >= Default / 2 {
		Refusal := "auth.refresh_margin_seconds must be a whole number below half the default lifetime"
		return ""
	}
	if Raw.Has("assertion") && !_LLM_TokenExchange_AssertionIsValid(Raw["assertion"], &Refusal)
		return ""
	return Raw
}





; ===============================
; ===============================
; ======= 3/ The Exchange =======
; ===============================
; ===============================

; The stored key read as a JSON object, 0 when it is none.
_LLM_TokenExchange_KeyFields(Key) {
	if !RegExMatch(Key, "^\s*\{")
		return 0
	try Decoded := JsonParse(Key)
	catch
		return 0
	return (Decoded is Map) ? Decoded : 0
}

; A string field of the stored key's JSON, "" when absent or empty.
_LLM_TokenExchange_KeyString(Fields, Name) {
	if !(Fields is Map)
		return ""
	Found := Fields.Get(Name, "")
	return (Found is String) ? Found : ""
}

; base64url without padding (RFC 7515 2).
_LLM_TokenExchange_Base64Url(Encoded) {
	return StrReplace(StrReplace(StrReplace(Encoded, "+", "-"), "/", "_"), "=")
}

; Fills and form-encodes a body block: the fields in ordinal order, as a Map
; enumerates its string keys, each name and value percent-encoded.
; @param {Map} Body Field -> template.
; @param {Func} Fill Fill(Placeholder) -> String, "" naming a missing value.
; @param {VarRef} Missing The first placeholder without a value.
; @returns {String} The form, "" with Missing set.
_LLM_TokenExchange_EncodeForm(Body, Fill, &Missing) {
	Missing := ""
	Form := ""
	for Name, Template in Body {
		Value := "", At := 1
		while RegExMatch(Template, "\{([^}]*)\}", &Found, At) {
			Filled := Fill.Call(Found[1])
			if (Filled == "") {
				Missing := Found[1]
				return ""
			}
			Value .= SubStr(Template, At, Found.Pos - At) . Filled
			At := Found.Pos + Found.Len
		}
		Value .= SubStr(Template, At)
		Form .= (Form == "" ? "" : "&") . UriEncode(Name) . "=" . UriEncode(Value)
	}
	return Form
}

_LLM_TokenExchange_FormRequest(Auth, Form) {
	return Map("url", Auth["token_url"], "body", Form,
		"headers", Map("Content-Type", "application/x-www-form-urlencoded", "Accept", "application/json"))
}

; A quoted JSON string, for the fixed field order of the JWT.
_LLM_TokenExchange_Quote(Text) {
	return '"' . JsonStringContents(Text) . '"'
}

; The signed form of a service-account key: header and claims in a fixed order, so
; the same key and time always give the same bytes (assertion_input in the Lua).
; @returns {Map|String} The request, "" with Refusal set.
_LLM_TokenExchange_SignedRequest(Auth, Fields, UnixNow, &Refusal) {
	Spec := Auth["assertion"]
	Pem := _LLM_TokenExchange_KeyString(Fields, Spec["private_key_field"])
	if (Pem == "") {
		Refusal := "the key holds no " . Spec["private_key_field"] . " field"
		return ""
	}
	Issuer := _LLM_TokenExchange_KeyString(Fields, Spec["issuer_field"])
	if (Issuer == "") {
		Refusal := "the key holds no " . Spec["issuer_field"] . " field"
		return ""
	}
	Header := '{"alg":"RS256","typ":"JWT"'
	KeyId := Spec.Has("key_id_field") ? _LLM_TokenExchange_KeyString(Fields, Spec["key_id_field"]) : ""
	if (KeyId != "")
		Header .= ',"kid":' . _LLM_TokenExchange_Quote(KeyId)
	Header .= "}"
	Claims := '{"iss":' . _LLM_TokenExchange_Quote(Issuer) . ',"scope":' . _LLM_TokenExchange_Quote(Spec["scope"])
		. ',"aud":' . _LLM_TokenExchange_Quote(Auth["token_url"]) . ',"iat":' . UnixNow
		. ',"exp":' . (UnixNow + Integer(Spec["lifetime_seconds"])) . "}"
	Input := _LLM_TokenExchange_Base64Url(CryptoBase64EncodeUtf8(Header)) . "."
		. _LLM_TokenExchange_Base64Url(CryptoBase64EncodeUtf8(Claims))
	Signature := LLM_Rs256_Sign(Pem, Input, &Refusal)
	if !(Signature is Buffer)
		return ""
	Jwt := Input . "." . _LLM_TokenExchange_Base64Url(CryptoBase64Encode(Signature))
	return _LLM_TokenExchange_FormRequest(Auth, _LLM_TokenExchange_EncodeForm(Spec["body"], (*) => Jwt, &Missing))
}

/**
 * The exchange request of one stored key, its signature (if any) made at once.
 * @param {Map} Auth LLM_TokenExchange_Parse's block.
 * @param {Any} Key The stored key.
 * @param {Integer} UnixNow The wall-clock time, whole seconds since 1970 (a JWT's iat).
 * @param {VarRef} Refusal Receives why the key cannot fill the form; never the key.
 * @returns {Map|String} Map("url", "headers", "body"), "" when refused.
 */
LLM_TokenExchange_Request(Auth, Key, UnixNow, &Refusal := "") {
	if !(Auth is Map)
		throw TypeError("LLM_TokenExchange_Request requires a parsed auth block.")
	if !(UnixNow is Integer) || UnixNow < 0
		throw ValueError("LLM_TokenExchange_Request requires the wall-clock time in whole seconds.")
	Refusal := ""
	if !(Key is String) || (Key == "") {
		Refusal := "the key is empty"
		return ""
	}
	Fields := _LLM_TokenExchange_KeyFields(Key)
	if Auth.Has("assertion") && (Fields is Map) && Fields.Get("type", "") == Auth["assertion"]["key_type"]
		return _LLM_TokenExchange_SignedRequest(Auth, Fields, UnixNow, &Refusal)
	Form := _LLM_TokenExchange_EncodeForm(Auth["body"], _LLM_TokenExchange_FillKey.Bind(Key, Fields), &Missing)
	if (Missing != "") {
		Refusal := "the key holds no " . SubStr(Missing, 5) . " field"
		return ""
	}
	return _LLM_TokenExchange_FormRequest(Auth, Form)
}

_LLM_TokenExchange_FillKey(Key, Fields, Placeholder) {
	return (Placeholder == "key") ? Key : _LLM_TokenExchange_KeyString(Fields, SubStr(Placeholder, 5))
}

/**
 * The message a refusing token service gives, in the field its error format
 * uses (OAuth error_description and error, IAM errorMessage, Google's
 * error.message), flattened to one line and cut on a whole character at the
 * token_exchange.max_service_message_bytes of _shared/ai/data/inference.json.
 * @param {Any} Decoded The decoded JSON body.
 * @returns {String} The message, "" when the service gives none.
 */
_LLM_TokenExchange_ServiceMessage(Decoded) {
	if !(Decoded is Map)
		return ""
	Nested := Decoded.Get("error", "")
	Nested := Nested is Map ? Nested.Get("message", "") : ""
	for Candidate in [Decoded.Get("error_description", ""), Decoded.Get("errorMessage", ""), Nested,
			Decoded.Get("message", ""), Decoded.Get("error", "")] {
		if !(Candidate is String)
			continue
		Line := Trim(RegExReplace(RegExReplace(Candidate, "[[:cntrl:]]", " "), "\s+", " "))
		if (Line == "")
			continue
		Limit := _LLM_Common_Cfg("token_exchange", "max_service_message_bytes")
		if (StrPut(Line, "UTF-8") - 1 <= Limit)
			return Line
		; The longest prefix within the bound that does not split a surrogate pair.
		Low := 0, High := StrLen(Line)
		while (Low < High) {
			Middle := (Low + High + 1) // 2
			if (StrPut(SubStr(Line, 1, Middle), "UTF-8") - 1 <= Limit)
				Low := Middle
			else
				High := Middle - 1
		}
		if (Low > 0 && Ord(SubStr(Line, Low, 1)) >= 0xD800 && Ord(SubStr(Line, Low, 1)) <= 0xDBFF)
			Low -= 1
		return SubStr(Line, 1, Low)
	}
	return ""
}

/**
 * Reads the answer of an exchange.
 * @param {Map} Auth The parsed block.
 * @param {Any} Status The HTTP status.
 * @param {Any} Decoded The decoded JSON body.
 * @param {Number} Now The current time, in seconds.
 * @param {VarRef} Refusal Receives why the answer is refused; never its content.
 * @returns {Map|String} Map("token", "expires_at"), "" when refused.
 */
LLM_TokenExchange_Read(Auth, Status, Decoded, Now, &Refusal := "") {
	global LLM_TOKEN_EXCHANGE_MIN_EXPIRES_SECONDS, LLM_TOKEN_EXCHANGE_MAX_EXPIRES_SECONDS
	Refusal := ""
	if (Status != 200) {
		; The service's own sentence explains the refusal better than its status
		; (AID-2, 2026-11-11); the Lua twin is api_token_exchange.read.
		Refusal := "the token exchange answered HTTP " . String(Status)
		Message := _LLM_TokenExchange_ServiceMessage(Decoded)
		if (Message != "")
			Refusal .= ": " . Message
		return ""
	}
	if !(Decoded is Map) {
		Refusal := "the token exchange answered no JSON object"
		return ""
	}
	Token := Decoded.Get(Auth["token_field"], "")
	if !(Token is String) || (Token == "") || RegExMatch(Token, "[[:cntrl:]\s]") {
		Refusal := "the token exchange answered no " . Auth["token_field"]
		return ""
	}
	Lifetime := Decoded.Get(Auth["expires_field"], "")
	if !_LLM_TokenExchange_IsWhole(Lifetime)
		Lifetime := Auth["default_expires_seconds"]
	Lifetime := Max(LLM_TOKEN_EXCHANGE_MIN_EXPIRES_SECONDS, Min(LLM_TOKEN_EXCHANGE_MAX_EXPIRES_SECONDS, Lifetime))
	return Map("token", Token, "expires_at", Now + Lifetime)
}

/**
 * Whether a cached token may still be sent.
 * @param {Map} Auth The parsed block.
 * @param {Any} Cached A Map holding "token" and "expires_at", or none.
 * @param {Number} Now The current time, in seconds.
 * @param {VarRef} Refresh Receives whether to exchange again (margin reached or unusable).
 * @returns {Boolean} Not yet expired.
 */
LLM_TokenExchange_State(Auth, Cached, Now, &Refresh := false) {
	if !(Cached is Map) || !(Cached.Get("expires_at", "") is Number) || Cached.Get("token", "") == "" {
		Refresh := true
		return false
	}
	Refresh := Now >= Cached["expires_at"] - Auth["refresh_margin_seconds"]
	return Now < Cached["expires_at"]
}

/**
 * The whitespace a pretty-printed key file holds between its fields, removed: a
 * pasted credentials file spans lines, which no stored field may hold. Raw line
 * breaks are invalid inside a JSON string, so its values cannot change.
 * @param {String} Key The typed key.
 * @returns {String} A JSON key on one line; any other key exactly as typed.
 */
LLM_TokenExchange_NormalizeKey(Key) {
	if !RegExMatch(Key, "^\s*\{")
		return Key
	return RegExReplace(Key, "[\r\n\t]")
}





; ===============================
; ===============================
; ======= 4/ Access Slots =======
; ===============================
; ===============================

; Monotonic seconds: the cached lifetimes survive a change of the wall clock.
_LLM_TokenExchange_Now() {
	return DllCall("Kernel32\GetTickCount64", "Int64") / 1000
}

_LLM_TokenExchange_Slot(ProviderId, Key) {
	global _LLM_TokenExchange_Slots
	SlotKey := ProviderId . "`n" . Key
	if !_LLM_TokenExchange_Slots.Has(SlotKey)
		_LLM_TokenExchange_Slots[SlotKey] := Map("waiters", [], "pending", false)
	return _LLM_TokenExchange_Slots[SlotKey]
}

/**
 * The token a request of this key may carry now, starting a refresh in the
 * background when it nears its end.
 * @param {String} ProviderId The provider.
 * @param {Map} Auth Its parsed block.
 * @param {String} Key The stored key.
 * @returns {String} The token, "" when none is usable yet.
 */
LLM_TokenExchange_Current(ProviderId, Auth, Key) {
	Slot := _LLM_TokenExchange_Slot(ProviderId, Key)
	Now := _LLM_TokenExchange_Now()
	Usable := LLM_TokenExchange_State(Auth, Slot, Now, &Refresh)
	if Refresh && !Slot["pending"] && !(Slot.Has("retry_at") && Now < Slot["retry_at"])
		_LLM_TokenExchange_Start(Slot, ProviderId, Auth, Key)
	return Usable ? Slot["token"] : ""
}

/**
 * Runs OnReady once this key's access token is usable: at once when it is fresh or
 * its refusal is still pausing, else when the exchange settles.
 * @param {String} ProviderId The provider.
 * @param {Map} Auth Its parsed block.
 * @param {String} Key The stored key.
 * @param {Func} OnReady OnReady(Ok, Failure); Failure is 0 or
 *     Map("refusal", "status", "key_refused"[, "network_report"]).
 */
LLM_TokenExchange_Prepare(ProviderId, Auth, Key, OnReady) {
	if !HasMethod(OnReady, "Call")
		throw TypeError("LLM_TokenExchange_Prepare requires a callback.")
	Slot := _LLM_TokenExchange_Slot(ProviderId, Key)
	if (LLM_TokenExchange_Current(ProviderId, Auth, Key) != "") {
		OnReady.Call(true, 0)
		return
	}
	if !Slot["pending"] && Slot.Has("retry_at") && _LLM_TokenExchange_Now() < Slot["retry_at"] {
		OnReady.Call(false, Slot["failure"])
		return
	}
	Slot["waiters"].Push(OnReady)
	if !Slot["pending"]
		_LLM_TokenExchange_Start(Slot, ProviderId, Auth, Key)
}

; Reserves the slot and moves the signature and the POST off the requesting thread.
_LLM_TokenExchange_Start(Slot, ProviderId, Auth, Key) {
	Slot["pending"] := true
	SetTimer(_LLM_TokenExchange_Begin.Bind(Slot, ProviderId, Auth, Key), -1)
}

_LLM_TokenExchange_Begin(Slot, ProviderId, Auth, Key) {
	global _LLM_TokenExchange_PostFn
	if A_IsSuspended {
		LoggerInfo("LLM.remote", "Access token of provider '{1}' not asked: the driver is paused.", ProviderId)
		_LLM_TokenExchange_Settle(Slot, Map("refusal", "the driver is paused", "status", 0, "key_refused", false), false)
		return
	}
	try Request := LLM_TokenExchange_Request(Auth, Key, _LLMRemoteEpochNow(), &Refusal)
	catch as Err {
		; A fault in the signer settles the slot as refused, so it never stays
		; pending; Err names a native call, it holds no key material
		Request := "", Refusal := "the assertion signer failed: " . Err.Message
	}
	if !(Request is Map) {
		LoggerError("LLM.remote", "Access token of provider '{1}' cannot be asked: {2}.", ProviderId, Refusal)
		_LLM_TokenExchange_Settle(Slot, Map("refusal", Refusal, "status", 0, "key_refused", true))
		return
	}
	LoggerStart("LLM.remote", "Exchanging the key of provider '{1}' for an access token…", ProviderId)
	OnAnswer := _LLM_TokenExchange_OnAnswer.Bind(Slot, ProviderId, Auth)
	try {
		if HasMethod(_LLM_TokenExchange_PostFn, "Call")
			_LLM_TokenExchange_PostFn.Call(Request, OnAnswer)
		else
			_LLM_TokenExchange_Post(Request, OnAnswer)
	} catch as Err {
		LoggerError("LLM.remote", "Access token of provider '{1}' refused: the request was not sent ({2}).",
			ProviderId, Err.Message)
		_LLM_TokenExchange_Settle(Slot, Map("refusal", "the token exchange could not be sent", "status", 0, "key_refused", false))
	}
}

; Reads the token service's answer into the slot.
; @param {Map} Answer "status", "body"[, "network_report"].
_LLM_TokenExchange_OnAnswer(Slot, ProviderId, Auth, Answer) {
	if Answer.Get("pause_revoked", false) is Integer && Answer.Get("pause_revoked", false) == true {
		LoggerInfo("LLM.remote", "Access token of provider '{1}' cancelled because the driver was paused.", ProviderId)
		_LLM_TokenExchange_Settle(Slot,
			Map("refusal", "the driver is paused", "status", 0, "key_refused", false), false)
		return
	}
	Status := Answer.Get("status", 0)
	Decoded := 0
	try Decoded := JsonParse(Answer.Get("body", ""))
	catch
		Decoded := 0
	Now := _LLM_TokenExchange_Now()
	Token := LLM_TokenExchange_Read(Auth, Status, Decoded, Now, &Refusal)
	if (Token is Map) {
		Slot["token"] := Token["token"], Slot["expires_at"] := Token["expires_at"]
		for Stale in ["retry_at", "failure"] {
			if Slot.Has(Stale)
				Slot.Delete(Stale)
		}
		LoggerSuccess("LLM.remote", "Access token of provider '{1}' received (valid {2} s).", ProviderId,
			Round(Token["expires_at"] - Now))
		_LLM_TokenExchange_Settle(Slot, 0)
		return
	}
	LoggerError("LLM.remote", "Access token of provider '{1}' refused: {2}.", ProviderId, Refusal)
	; OAuth invalid-grant responses use 400; 401/403 also deny credentials.
	; Other client statuses can describe throttling, timeouts or endpoint faults.
	Failure := Map("refusal", Refusal, "status", Status, "key_refused", Status == 400 || Status == 401 || Status == 403)
	if Answer.Has("network_report")
		Failure["network_report"] := Answer["network_report"]
	_LLM_TokenExchange_Settle(Slot, Failure)
}

; Ends the slot's exchange and hands the verdict to each waiter.
; @param {Map|Integer} Failure 0 when a token arrived.
; @param {Boolean} Pause Whether the refusal pauses the next attempt.
_LLM_TokenExchange_Settle(Slot, Failure, Pause := true) {
	global LLM_TOKEN_EXCHANGE_RETRY_SECONDS
	Slot["pending"] := false
	if (Failure is Map) && Pause {
		Slot["failure"] := Failure
		Slot["retry_at"] := _LLM_TokenExchange_Now() + LLM_TOKEN_EXCHANGE_RETRY_SECONDS
	}
	Waiters := Slot["waiters"]
	Slot["waiters"] := []
	for Waiter in Waiters {
		try Waiter.Call(!(Failure is Map), Failure)
		catch as Err
			LoggerError("LLM.remote", "Access token waiter failed: {1}.", Err.Message)
	}
}

; Posts the form through the managed worker and polls it. The exchange has no
; requester of its own: it stops only on a pause or at its deadline.
_LLM_TokenExchange_Post(Request, OnAnswer, Port := 0) {
	global LLM_REMOTE_TIMEOUT_MS, LLM_REMOTE_CONNECT_TIMEOUT_MS
	CreateHttp := _LLM_CurlArtifactPortFn(Port, "create_http", () => CurlAsyncRequest())
	Http := CreateHttp.Call()
	Http.SetManagedRouting(Port is Map ? Port.Get("managed_settings", 0) : 0, () => !A_IsSuspended)
	Http.SetDeadline(A_TickCount, LLM_REMOTE_TIMEOUT_MS)
	Http.ConnectTimeoutMs := LLM_REMOTE_CONNECT_TIMEOUT_MS
	Http.RevocationBestEffort := false
	Http.Open("POST", Request["url"], true)
	for Name, Value in Request["headers"]
		Http.SetRequestHeader(Name, Value)
	if !Http.Send(Request["body"]) {
		Http.Abort()
		throw Error("the managed transport refused dispatch")
	}
	_LLM_TokenExchange_Poll(Http, OnAnswer)
}

_LLM_TokenExchange_Poll(Http, OnAnswer) {
	global LLM_REMOTE_POLL_MS
	if !Http.WaitForResponse(0) {
		SetTimer(_LLM_TokenExchange_Poll.Bind(Http, OnAnswer), -LLM_REMOTE_POLL_MS)
		return
	}
	Answer := Map("status", Http.Status, "body", Http.ResponseEncodingValid ? Http.ResponseText : "")
	if Http.ManagedPauseRevoked
		Answer["pause_revoked"] := true
	NetworkReport := ManagedNetworkFailureWindows_FromTransport(Http, () => true)
	if NetworkReport is Map
		Answer["network_report"] := NetworkReport
	OnAnswer.Call(Answer)
}

/** Forgets every cached token and refusal (tests). */
_LLM_TokenExchange_ResetForTest() {
	global _LLM_TokenExchange_Slots
	_LLM_TokenExchange_Slots := Map()
}
