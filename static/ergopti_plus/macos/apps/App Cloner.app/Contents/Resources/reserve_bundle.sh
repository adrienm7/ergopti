# apps/App Cloner.app/Contents/Resources/reserve_bundle.sh

# Reserve a new bundle before any writer can touch its contents. A prior
# existence check alone lets repeated or concurrent runs merge their bundles.
reserve_bundle_directory() {
	local requested="$1" candidate="$1" suffix=0
	while ! mkdir "$candidate" 2>/dev/null; do
		if [[ ! -e "$candidate" && ! -L "$candidate" ]]; then
			printf 'Error: cannot reserve bundle directory: %s\n' "$candidate" >&2
			return 1
		fi
		suffix=$((suffix + 1))
		candidate="${requested%.app}_${suffix}.app"
	done
	printf '%s\n' "$candidate"
}

# EXIT must be installed by the caller: zsh runs a function-local EXIT trap
# when that function ends, before its caller has finished creating the bundle.
cleanup_bundle_creation() {
	local cleanup_status=$? cleanup_failed=0 current_identity=""
	trap - EXIT
	if [[ "$CLONE_COMPLETE" != "1" && -n "$DEST" ]]; then
		if [[ ! -e "$DEST" && ! -L "$DEST" ]]; then
			: # This reservation has already retired.
		elif [[ ! -d "$DEST" || -L "$DEST" ]]; then
			echo "Error: reserved bundle ownership changed; refusing cleanup: $DEST" >&2
			cleanup_failed=1
		elif ! current_identity="$(/usr/bin/stat -f '%d:%i' "$DEST")"; then
			echo "Error: cannot inspect reserved bundle ownership; refusing cleanup: $DEST" >&2
			cleanup_failed=1
		elif [[ -z "$DEST_ID" || "$current_identity" != "$DEST_ID" ]]; then
			echo "Error: reserved bundle ownership changed; refusing cleanup: $DEST" >&2
			cleanup_failed=1
		else
			rm -rf -- "$DEST" || cleanup_failed=1
		fi
	fi
	if [[ -n "$TMPDIR_WORK" ]]; then
		rm -rf -- "$TMPDIR_WORK" || cleanup_failed=1
	fi
	if [[ "$cleanup_status" == "0" && "$cleanup_failed" != "0" ]]; then
		return 1
	fi
	return "$cleanup_status"
}

initialize_bundle_creation() {
	DEST=""
	DEST_ID=""
	TMPDIR_WORK=""
	CLONE_COMPLETE=0
	trap 'exit 129' HUP
	trap 'exit 130' INT
	trap 'exit 143' TERM
}

reserve_owned_bundle_directory() {
	DEST="$(reserve_bundle_directory "$1")"
	if [[ ! -d "$DEST" || -L "$DEST" ]]; then
		echo "Error: reserved bundle is not a directory: $DEST" >&2
		exit 1
	fi
	DEST_ID="$(/usr/bin/stat -f '%d:%i' "$DEST")" || {
		identity_status=$?
		echo "Error: cannot capture reserved bundle ownership: $DEST" >&2
		exit "$identity_status"
	}
}
