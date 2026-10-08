#!/bin/bash
# modules/llm/network-retry.sh

# ============================================================================
# MODULE: Shared Bootstrap Network Policy
# DESCRIPTION:
# Owns the bounded retry and curl policy used by every macOS LLM bootstrap,
# and the network settings every download child receives on a managed
# (company) Mac: the system relay of `scutil --proxy` as HTTPS_PROXY,
# HTTP_PROXY and NO_PROXY (loopback always excluded), and the system trust
# store, where a company installs its inspection certificate. No CA file is
# ever handed to a child: uv loads the keychain's roots (UV_SYSTEM_CERTS),
# Apple's curl and Python's truststore read it already. Callers provide
# log_info() and log_error() before invoking retry_network() or
# apply_system_network().
# ============================================================================

# EX_CONFIG: the client cannot apply the configured native route. It does not
# identify a PAC evaluation failure, and callers must not infer one from it.
OPAQUE_NETWORK_REFUSAL_EXIT_CODE=78
# Capture the caller's route before the default/native-curl activation exports
# system static values. Those exports cannot later become an explicit override.
OPAQUE_NETWORK_INHERITED_HTTPS_ROUTE="${https_proxy:-${HTTPS_PROXY:-${all_proxy:-${ALL_PROXY:-}}}}"

NETWORK_MAX_RETRIES=6
NETWORK_BASE_BACKOFF_SEC=5
CURL_CONNECT_TIMEOUT_SEC=30
CURL_MAX_TIME_SEC=600
CURL_RETRY_COUNT=5
CURL_RETRY_DELAY_SEC=5
CURL_RETRY_MAX_TIME_SEC=300

# Runs an exact command with bounded exponential backoff.
retry_network() {
	local attempt=1
	local backoff="$NETWORK_BASE_BACKOFF_SEC"
	local rc=1
	while [ "$attempt" -le "$NETWORK_MAX_RETRIES" ]; do
		if "$@"; then
			return 0
		else
			rc=$?
		fi
		if [ "$attempt" -ge "$NETWORK_MAX_RETRIES" ]; then
			log_error "Network attempt $attempt/$NETWORK_MAX_RETRIES failed (code $rc) -- giving up."
			return "$rc"
		fi
		log_info "Network attempt $attempt/$NETWORK_MAX_RETRIES failed (code $rc) -- retrying in ${backoff}s."
		sleep "$backoff"
		attempt=$((attempt + 1))
		backoff=$((backoff * 2))
	done
	return 1
}

# A large archive on a slow link needs longer than CURL_MAX_TIME_SEC, and a
# restart from zero after each timeout never finishes: an attempt ends only
# when the transfer stalls below this rate for this long.
CURL_STALL_BYTES_PER_SEC=1024
CURL_STALL_SEC=60

# Applies one canonical bounded curl policy before caller-specific arguments.
curl_resilient() {
	curl -LsSf \
		--connect-timeout "$CURL_CONNECT_TIMEOUT_SEC" \
		--max-time "$CURL_MAX_TIME_SEC" \
		--retry "$CURL_RETRY_COUNT" \
		--retry-delay "$CURL_RETRY_DELAY_SEC" \
		--retry-max-time "$CURL_RETRY_MAX_TIME_SEC" \
		--retry-all-errors \
		"$@"
}

# Downloads a large archive into the file named by "-o", resuming the bytes a
# previous attempt already wrote. The caller verifies the complete file.
curl_resumable() {
	local replace_owner=0
	if [ "${1:-}" = --replace-owner ]; then replace_owner=1; shift; fi
	local command=(curl -LsSf \
		--connect-timeout "$CURL_CONNECT_TIMEOUT_SEC" \
		--speed-limit "$CURL_STALL_BYTES_PER_SEC" \
		--speed-time "$CURL_STALL_SEC" \
		--retry "$CURL_RETRY_COUNT" \
		--retry-delay "$CURL_RETRY_DELAY_SEC" \
		--retry-max-time "$CURL_RETRY_MAX_TIME_SEC" \
		--retry-all-errors \
		--continue-at - \
		"$@")
	if [ "$replace_owner" -eq 1 ]; then exec "${command[@]}"; fi
	"${command[@]}"
}

# A bundle download crosses the signed native request boundary for each full
# URL, including redirects. Explicit inherited routes keep the caller's curl
# selection; they never silently become a different system-selected route.
# The caller owns the private destination and the pinned complete asset.
managed_bootstrap_json_string() {
	local value="$1" character code escaped index
	local LC_ALL=C
	printf '"'
	for ((index=0; index<${#value}; index++)); do
		character="${value:index:1}"
		case "$character" in
			'"') printf '\\"' ;;
			'\') printf '\\\\' ;;
			*)
				printf -v code '%d' "'$character"
				if [ "$code" -lt 32 ]; then
					printf -v escaped '\\u%04x' "$code"
					printf '%s' "$escaped"
				else
					printf '%s' "$character"
				fi
				;;
		esac
	done
	printf '"'
}

# The application supplies the exact launcher's native stat identity. A
# missing Python never permits an uninspected executable from PATH instead.
managed_bootstrap_launcher_available() {
	local launcher="${ERGOPTI_LAUNCHER_EXECUTABLE:-}" identity
	case "$launcher" in */Contents/MacOS/ErgoptiPlus) ;; *) return 1 ;; esac
	[ -f "$launcher" ] && [ -x "$launcher" ] && [ ! -L "$launcher" ] || return 1
	identity="$(/usr/bin/stat -f '%d:%i' "$launcher" 2>/dev/null)" || return 1
	[ "$identity" = "${ERGOPTI_LAUNCHER_DEVICE:-}:${ERGOPTI_LAUNCHER_INODE:-}" ]
}

managed_bootstrap_download() {
	local url="$1" output="$2" digest="$3" size="${4:-}" transfer="${5:-resumable}" replace_owner="${6:-}"
	case "$transfer" in resilient|resumable) ;; *) return 64 ;; esac
	if [ -n "${ERGOPTI_LAUNCHER_EXECUTABLE:-}" ] && [ -z "$OPAQUE_NETWORK_INHERITED_HTTPS_ROUTE" ]; then
		if [ ! -x "${ERGOPTI_BOOTSTRAP_PYTHON:-}" ]; then
			if ! managed_bootstrap_launcher_available; then
				log_error "The native download input owner is unavailable. No download was started."
				return "$OPAQUE_NETWORK_REFUSAL_EXIT_CODE"
			fi
			local budget_ms=$((CURL_MAX_TIME_SEC * 1000)) payload
			payload="{\"version\":1,\"url\":$(managed_bootstrap_json_string "$url"),\"sha256\":$(managed_bootstrap_json_string "$digest"),\"output\":$(managed_bootstrap_json_string "$output"),\"timeout_ms\":$budget_ms"
			if [ -n "$size" ]; then
				case "$size" in *[!0-9]*|0) return 64 ;; esac
				payload="$payload,\"size\":$size"
			fi
			payload="$payload}"
			# The native spool reads system routes itself and interprets only
			# the canonical caller bypass entries from its environment.
			if [ "$replace_owner" = --replace-owner ]; then
				exec "$ERGOPTI_LAUNCHER_EXECUTABLE" --managed-bootstrap-download "$budget_ms" <<< "$payload"
			fi
			(
				exec "$ERGOPTI_LAUNCHER_EXECUTABLE" --managed-bootstrap-download "$budget_ms" <<< "$payload"
			)
			return $?
		fi
		if [ ! -f "$SCRIPT_DIR/managed_bootstrap_http.py" ]; then
			log_error "The native download input helper is missing. No download was started."
			return "$OPAQUE_NETWORK_REFUSAL_EXIT_CODE"
		fi
		local command=("$ERGOPTI_BOOTSTRAP_PYTHON" "$SCRIPT_DIR/managed_bootstrap_http.py" \
			--timeout "$CURL_MAX_TIME_SEC" --idle-timeout "$CURL_STALL_SEC" \
			download --url "$url" --output "$output" --sha256 "$digest")
		if [ -n "$size" ]; then command+=(--size "$size"); fi
		if [ "$replace_owner" = --replace-owner ]; then exec "${command[@]}"; fi
		"${command[@]}"
		return $?
	fi
	# A manual checkout has no signed request worker. Preserve the existing
	# direct/static/environment implementation, but never pretend it reads PAC.
	if [ -x /usr/sbin/scutil ]; then apply_system_network opaque || return $?; fi
	if [ "$transfer" = resilient ]; then curl_resilient -o "$output" "$url"; return $?; fi
	if [ "$replace_owner" = --replace-owner ]; then curl_resumable --replace-owner -o "$output" "$url"; return $?; fi
	curl_resumable -o "$output" "$url"
}

# Loopback hosts never go through a relay: a relay variable without them
# sends the local Ollama and MLX servers to the company's.
LOOPBACK_NO_PROXY="localhost,127.0.0.1,::1"

# Repeated admission checks keep the same child environment. Never append a CA
# file: uv's native trust selection is the same Boolean activation every time.
apply_client_network_environment() {
	local exclusions="${NO_PROXY:-${no_proxy:-}}" host
	local IFS=,
	for host in $LOOPBACK_NO_PROXY; do
		case ",$exclusions," in
			*",$host,"*) ;;
			*) exclusions="${exclusions:+$exclusions,}$host" ;;
		esac
	done
	export NO_PROXY="$exclusions" no_proxy="$exclusions"
	export UV_SYSTEM_CERTS=1
}

# Reads `scutil --proxy` on stdin and prints NAME=VALUE lines: HTTPS_PROXY
# and HTTP_PROXY for the enabled entries, NO_PROXY for the exceptions, and
# PAC_URL when only an automatic configuration is set, which a shell cannot
# evaluate. Pure text in, text out, so it is tested without a Mac.
system_network_from_scutil() {
	awk '
		/ExceptionsList : <array> \{/ { in_exceptions = 1; next }
		in_exceptions && /^[ \t]*\}/ { in_exceptions = 0; next }
		in_exceptions {
			entry = $0
			sub(/^[ \t]*[0-9]+ : /, "", entry)
			gsub(/[ \t]+$/, "", entry)
			sub(/^\*/, "", entry)
			if (entry != "") exceptions = exceptions (exceptions == "" ? "" : ",") entry
			next
		}
		{
			line = $0
			sub(/^[ \t]+/, "", line)
			separator = index(line, " : ")
			if (separator > 0) value[substr(line, 1, separator - 1)] = substr(line, separator + 3)
		}
		END {
			if (value["HTTPSEnable"] == "1" && value["HTTPSProxy"] != "") {
				print "HTTPS_PROXY=http://" value["HTTPSProxy"] (value["HTTPSPort"] != "" ? ":" value["HTTPSPort"] : "")
				explicit = 1
			}
			if (value["HTTPEnable"] == "1" && value["HTTPProxy"] != "") {
				print "HTTP_PROXY=http://" value["HTTPProxy"] (value["HTTPPort"] != "" ? ":" value["HTTPPort"] : "")
				explicit = 1
			}
			if (explicit && exceptions != "") print "NO_PROXY=" exceptions
			if (!explicit && value["ProxyAutoConfigEnable"] == "1" && value["ProxyAutoConfigURLString"] != "")
				print "PAC_URL=" value["ProxyAutoConfigURLString"]
			else if (!explicit && value["ProxyAutoDiscoveryEnable"] == "1")
				print "PAC_URL=auto-discovery (WPAD)"
		}
	'
}

# Reads only the native configuration. The opaque-client receiver replaces
# this function with literal snapshots; production always uses the native tool.
opaque_system_proxy_snapshot() {
	[ -x /usr/sbin/scutil ] || return 1
	/usr/sbin/scutil --proxy 2>/dev/null
}

# Automatic configuration has precedence even when static entries coexist.
# A successfully read dictionary with neither mode enabled admits its static
# routes or DIRECT. A failed/malformed getter never establishes DIRECT.
opaque_automatic_mode_from_scutil() {
	awk '
		BEGIN {
			flag_keys[++flag_count] = "HTTPEnable"
			flag_keys[++flag_count] = "HTTPSEnable"
			flag_keys[++flag_count] = "SOCKSEnable"
			flag_keys[++flag_count] = "FTPEnable"
			flag_keys[++flag_count] = "GopherEnable"
			flag_keys[++flag_count] = "RTSPEnable"
			flag_keys[++flag_count] = "ProxyAutoConfigEnable"
			flag_keys[++flag_count] = "ProxyAutoDiscoveryEnable"
			flag_keys[++flag_count] = "ExcludeSimpleHostnames"
			for (i = 1; i <= flag_count; i++) flags[flag_keys[i]] = 1
			proxy_keys["HTTPEnable"] = "HTTP"
			proxy_keys["HTTPSEnable"] = "HTTPS"
			proxy_keys["SOCKSEnable"] = "SOCKS"
			proxy_keys["FTPEnable"] = "FTP"
			proxy_keys["GopherEnable"] = "Gopher"
			proxy_keys["RTSPEnable"] = "RTSP"
		}
		function relevant(key) {
			return flags[key] || key ~ /^(HTTP|HTTPS|SOCKS|FTP|Gopher|RTSP)(Proxy|Port)$/ \
				|| key == "ProxyAutoConfigURLString"
		}
		function fingerprint(node, result, i, key, value, host, port, family) {
			for (i = 1; i <= flag_count; i++) {
				key = flag_keys[i]
				value = field[node, key] == "" ? "0" : field[node, key]
				result = result SUBSEP key "=" value
				if (value == "1" && proxy_keys[key] != "") {
					family = proxy_keys[key]
					host = field[node, family "Proxy"]
					port = field[node, family "Port"]
					if (host == "" || host ~ /[ \t]/ \
						|| (port != "" && (port !~ /^[0-9]+$/ || port + 0 < 1 || port + 0 > 65535))) bad = 1
					result = result SUBSEP host SUBSEP port
				}
			}
			if (field[node, "ProxyAutoConfigEnable"] == "1")
				result = result SUBSEP field[node, "ProxyAutoConfigURLString"]
			return result SUBSEP exceptions[node]
		}
		NF {
			line = $0
			sub(/^[ \t]+/, "", line)
			sub(/[ \t]+$/, "", line)
			if (!started) {
				if (line != "<dictionary> {" && line != "<dictionary> {}") { bad = 1; next }
				started = 1
				nodes = 1
				kind[1] = "dictionary"
				route_dictionary[1] = 1
				if (line == "<dictionary> {}") closed = 1
				else { depth = 1; stack[1] = 1 }
				next
			}
			if (closed || depth == 0) { bad = 1; next }
			if (line == "}") {
				depth--
				if (depth == 0) closed = 1
				next
			}
			separator = index(line, " :")
			if (separator == 0) { bad = 1; next }
			key = substr(line, 1, separator - 1)
			value = substr(line, separator + 2)
			if (value != "" && substr(value, 1, 1) != " ") { bad = 1; next }
			sub(/^ /, "", value)
			node = stack[depth]
			if (kind[node] == "array") {
				if (key !~ /^(0|[1-9][0-9]*)$/ || key + 0 != next_index[node]++) { bad = 1; next }
			} else if (key == "" || key ~ /[ \t:{}]/) { bad = 1; next }
			if (seen_key[node, key]++) { bad = 1; next }
			container = value == "<dictionary> {" || value == "<array> {" \
				|| value == "<dictionary> {}" || value == "<array> {}"
			if (kind[node] == "dictionary" && relevant(key)) {
				route_dictionary[node] = 1
				if (container || (flags[key] && value != "0" && value != "1")) { bad = 1; next }
				field[node, key] = value
			}
			if (kind[node] == "dictionary" && key == "ExceptionsList") {
				route_dictionary[node] = 1
				if (value != "<array> {" && value != "<array> {}") { bad = 1; next }
			}
			if ((key == "__SCOPED__" && value != "<dictionary> {" && value != "<dictionary> {}") \
				|| (key == "__SUPPLEMENTAL__" && value != "<array> {" && value != "<array> {}")) { bad = 1; next }
			if (exception_owner[node]) {
				if (container || value == "") { bad = 1; next }
				exceptions[exception_owner[node]] = exceptions[exception_owner[node]] SUBSEP value
			}
			if (container) {
				child = ++nodes
				kind[child] = substr(value, 1, 7) == "<array>" ? "array" : "dictionary"
				if (key == "ExceptionsList" && kind[node] == "dictionary") exception_owner[child] = node
				if (key == "__SCOPED__") scoped_container[child] = 1
				if (key == "__SUPPLEMENTAL__") supplemental_container[child] = 1
				if (scoped_container[node] || supplemental_container[node]) {
					if (kind[child] != "dictionary") { bad = 1; next }
					route_dictionary[child] = 1
				}
				if (substr(value, length(value) - 1) != "{}") stack[++depth] = child
			} else if (scoped_container[node] || supplemental_container[node] \
				|| value ~ /^<(dictionary|array)>/ || value == "{" || value == "}") { bad = 1; next }
		}
		END {
			if (bad || !started || !closed || depth != 0) exit 1
			global_route = fingerprint(1)
			for (node = 2; node <= nodes; node++) {
				if (route_dictionary[node] && fingerprint(node) != global_route) bad = 1
			}
			if (bad) exit 1
			if (field[1, "ProxyAutoConfigEnable"] == "1") print "pac"
			else if (field[1, "ProxyAutoDiscoveryEnable"] == "1") print "wpad"
			else if (field[1, "SOCKSEnable"] == "1" && field[1, "HTTPSEnable"] != "1") print "unsupported"
			else print "none"
		}
	'
}

# uv, HTTPX/HuggingFace and the owned Ollama Go daemon have no native,
# per-request full-URL PAC adapter. An explicit HTTPS environment route remains
# supported; a system automatic route must be refused before any child starts.
# These facts belong to this admission only, not to unstructured child stderr.
apply_opaque_system_network() {
	local relay snapshot mode settings line
	OPAQUE_NETWORK_FAILURE_PROVENANCE=""
	OPAQUE_NETWORK_PROXY_RESOLUTION_STATUS=""
	relay="$OPAQUE_NETWORK_INHERITED_HTTPS_ROUTE"
	if [ -n "$relay" ]; then
		# Go does not consume ALL_PROXY. Materialize the selected environment
		# route as HTTPS_PROXY too, with the shared lowercase-first precedence.
		export HTTPS_PROXY="$relay" https_proxy="$relay"
	else
		if ! snapshot="$(opaque_system_proxy_snapshot)"; then
			OPAQUE_NETWORK_FAILURE_PROVENANCE=unavailable
			OPAQUE_NETWORK_PROXY_RESOLUTION_STATUS=unavailable
			log_error "The system network configuration is unavailable. No download was started."
			return "$OPAQUE_NETWORK_REFUSAL_EXIT_CODE"
		fi
		if ! mode="$(printf '%s\n' "$snapshot" | opaque_automatic_mode_from_scutil)"; then
			OPAQUE_NETWORK_FAILURE_PROVENANCE=unavailable
			OPAQUE_NETWORK_PROXY_RESOLUTION_STATUS=unavailable
			log_error "The system network configuration could not be read. No download was started."
			return "$OPAQUE_NETWORK_REFUSAL_EXIT_CODE"
		fi
		if [ "$mode" != none ]; then
			OPAQUE_NETWORK_FAILURE_PROVENANCE=verified
			OPAQUE_NETWORK_PROXY_RESOLUTION_STATUS=unavailable
			log_error "The system proxy configuration cannot be used by this client. No download was started."
			return "$OPAQUE_NETWORK_REFUSAL_EXIT_CODE"
		fi
		settings="$(printf '%s\n' "$snapshot" | system_network_from_scutil)" || return "$OPAQUE_NETWORK_REFUSAL_EXIT_CODE"
		while IFS= read -r line; do
			case "$line" in
				HTTPS_PROXY=*) export HTTPS_PROXY="${line#HTTPS_PROXY=}" https_proxy="${line#HTTPS_PROXY=}" ;;
				HTTP_PROXY=*)
					if [ -z "${http_proxy:-${HTTP_PROXY:-}}" ]; then
						export HTTP_PROXY="${line#HTTP_PROXY=}" http_proxy="${line#HTTP_PROXY=}"
					fi ;;
				NO_PROXY=*)
					if [ -z "${NO_PROXY:-${no_proxy:-}}" ]; then export NO_PROXY="${line#NO_PROXY=}"; fi ;;
			esac
		done <<EOF_OPAQUE_SETTINGS
$settings
EOF_OPAQUE_SETTINGS
	fi
	apply_client_network_environment
}

# Exports the system network settings for every child of the calling script.
# An explicit relay in the environment wins: whoever started the script chose
# it. The line naming the settings avoids the words a failure classifier reads.
apply_system_network() {
	if [ "${1:-}" = opaque ]; then
		apply_opaque_system_network
		return $?
	fi
	local settings line
	if [ -z "${HTTPS_PROXY:-}${https_proxy:-}${HTTP_PROXY:-}${http_proxy:-}" ] && [ -x /usr/sbin/scutil ]; then
		settings="$(/usr/sbin/scutil --proxy 2>/dev/null | system_network_from_scutil)" || settings=""
		while IFS= read -r line; do
			case "$line" in
				HTTPS_PROXY=*) export HTTPS_PROXY="${line#HTTPS_PROXY=}" https_proxy="${line#HTTPS_PROXY=}" ;;
				HTTP_PROXY=*) export HTTP_PROXY="${line#HTTP_PROXY=}" http_proxy="${line#HTTP_PROXY=}" ;;
				NO_PROXY=*) export NO_PROXY="${line#NO_PROXY=}" ;;
				PAC_URL=*)
					log_info "The network settings use an automatic configuration (${line#PAC_URL=}) that the installer cannot read: if the download fails, enter the relay by hand in System Settings > Network."
					;;
			esac
		done <<EOF_SETTINGS
$settings
EOF_SETTINGS
		if [ -n "${HTTPS_PROXY:-}${HTTP_PROXY:-}" ]; then
			log_info "Downloads use the relay the system network settings name."
		fi
	fi
	apply_client_network_environment
}
