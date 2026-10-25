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
