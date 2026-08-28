#!/bin/bash
# modules/llm/network-retry.sh

# ============================================================================
# MODULE: Shared Bootstrap Network Policy
# DESCRIPTION:
# Owns the bounded retry and curl policy used by every macOS LLM bootstrap.
# Callers provide log_info() and log_error() before invoking retry_network().
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
