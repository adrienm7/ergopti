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
	curl -LsSf \
		--connect-timeout "$CURL_CONNECT_TIMEOUT_SEC" \
		--speed-limit "$CURL_STALL_BYTES_PER_SEC" \
		--speed-time "$CURL_STALL_SEC" \
		--retry "$CURL_RETRY_COUNT" \
		--retry-delay "$CURL_RETRY_DELAY_SEC" \
		--retry-max-time "$CURL_RETRY_MAX_TIME_SEC" \
		--retry-all-errors \
		--continue-at - \
		"$@"
}

# Loopback hosts never go through a relay: a relay variable without them
# sends the local Ollama and MLX servers to the company's.
LOOPBACK_NO_PROXY="localhost,127.0.0.1,::1"

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

# Exports the system network settings for every child of the calling script.
# An explicit relay in the environment wins: whoever started the script chose
# it. The line naming the settings avoids the words a failure classifier reads.
apply_system_network() {
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
	local exclusions="${NO_PROXY:-${no_proxy:-}}"
	export NO_PROXY="${exclusions:+$exclusions,}$LOOPBACK_NO_PROXY"
	export no_proxy="$NO_PROXY"
	# uv trusts the keychain's roots, a company inspection certificate
	# included, instead of its bundled Mozilla list.
	export UV_SYSTEM_CERTS=1
}
