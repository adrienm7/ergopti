#!/usr/bin/env bash
# static/ergopti_plus/linux/uninstall.sh
#
# Removes an explicitly confirmed standalone installation. Native packages are
# removed by their package manager so its ownership database stays consistent.
# Personal configuration, credentials, metrics and dependencies are retained.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/install/desktop_entry.sh"
PREFIX="${HOME}/.local"
source "$SCRIPT_DIR/install/config_home.sh"
ergopti_resolve_config_home CONFIG_ROOT
PACKAGE_NAME=ergopti
CONFIRMED=false
CHECK_ONLY=false
WAIT_OWNER=
GUI_TITLE=
GUI_ERROR=
GUI_MISSING=
MISSING_PROGRAM=
UNINSTALL_RECOVERY=
UNINSTALL_REMOVAL_STARTED=false
UNINSTALL_REMOVAL_COMMITTED=false
UNINSTALL_FINALIZED=false
SNAPSHOT_SOURCES=()
SNAPSHOT_DIGESTS=()
SOURCE_PRESENT=false
declare -A DIRECTORY_CATALOGS=()
declare -A DIRECTORY_ENTRIES=()

while [ "$#" -gt 0 ]; do
	case "$1" in
		--yes) CONFIRMED=true; shift ;;
		--check) CHECK_ONLY=true; shift ;;
		--wait-owner)
			[ "$#" -ge 2 ] || exit 64
			WAIT_OWNER="$2"; shift 2 ;;
		--gui)
			[ "$#" -ge 4 ] || exit 64
			GUI_TITLE="$2"; GUI_ERROR="$3"; GUI_MISSING="$4"; shift 4 ;;
		--prefix)
			[ "$#" -ge 2 ] || { echo 'Missing --prefix value.' >&2; exit 64; }
			PREFIX="$2"; shift 2 ;;
		*) echo "Unsupported uninstall argument: $1" >&2; exit 64 ;;
	esac
done

# Desktops differ in the dialog tool they ship: GNOME has zenity, KDE has
# kdialog. When neither works the failure must still reach the user, so the
# last resort is stderr plus a desktop notification when one is available.
show_failure_dialog() {
	if command -v zenity >/dev/null 2>&1; then
		if zenity --error --no-markup --title="$GUI_TITLE" --text="$GUI_ERROR"; then
			return 0
		fi
	fi
	if command -v kdialog >/dev/null 2>&1; then
		if kdialog --title "$GUI_TITLE" --error "$GUI_ERROR"; then
			return 0
		fi
	fi
	echo "$GUI_TITLE: $GUI_ERROR" >&2
	if command -v notify-send >/dev/null 2>&1; then
		notify-send --urgency=critical -- "$GUI_TITLE" "$GUI_ERROR" || echo 'The uninstall failure notification could not be displayed.' >&2
	else
		echo 'No dialog tool (zenity, kdialog) or notify-send is available.' >&2
	fi
}

# Recovery is for observed unlink failures only. Snapshot every admitted file
# before mutation so losing this script or its helpers cannot prevent retry.
# These copies do not claim hard-kill or concurrent-writer transaction safety.
uninstall_record() {
	local record="[uninstall] code=$1 role=$2"
	printf '%s path=%q\n' "$record" "$3" >&2
}

# A source refusal keeps the existing startup diagnostic shape on every path.
uninstall_invalid_source() {
	local record="[uninstall] code=invalid-source"
	printf '%s path=%q\n' "$record" "$1" >&2
}

# Cache only complete native directory catalogs during pre-mutation admission.
# A failed stat cannot authorize absence, including below an external XDG root.
catalog_directory() {
	local directory="$1" entry scan_pid loop_status read_status
	local completed=false invalid=false
	local -a entries=()
	if [ -n "${DIRECTORY_CATALOGS["$directory"]:-}" ]; then return 0; fi
	if [ -L "$directory" ] || [ ! -d "$directory" ] || [ ! -x "$directory" ] \
		|| ! (CDPATH= cd -Pe -- "$directory" && [ "$PWD" = "$directory" ]); then
		return 1
	fi
	while :; do
		entry=
		if IFS= read -r -d '' entry; then
			if "$completed"; then invalid=true
			elif [ -z "$entry" ]; then completed=true
			else entries+=("$entry")
			fi
		else
			read_status=$?
			if [ "$read_status" -ne 1 ] || [ -n "$entry" ]; then invalid=true; fi
			break
		fi
	done < <(
		if find "$directory" -mindepth 1 -maxdepth 1 -print0; then
			# Empty paths are impossible: this final NUL proves successful completion.
			printf '\0'
		else
			exit "$?"
		fi
	)
	loop_status=$?
	scan_pid="${!:-}"
	# Consume the entire pipe and reap its exact producer before publishing data.
	# Completion is mandatory even if process-substitution allocation was refused.
	if [ -z "$scan_pid" ]; then return 1; fi
	if wait "$scan_pid"; then :; else return "$?"; fi
	if [ "$loop_status" -ne 0 ] || ! "$completed" || "$invalid"; then return 1; fi
	for entry in "${entries[@]}"; do DIRECTORY_ENTRIES["$entry"]=true; done
	DIRECTORY_CATALOGS["$directory"]=true
}

# Walk exact components from a known root. Only a successful complete catalog
# may prove an optional component absent; aliases are never absence witnesses.
admit_source_path() {
	local source="$1" remaining directory=/ component child
	SOURCE_PRESENT=false
	case "$source" in /*) remaining="${source#/}" ;; *) return 1 ;; esac
	# Reject aliases before any optional component can be declared absent.
	while [ -n "$remaining" ]; do
		case "$remaining" in
			*/*) component="${remaining%%/*}"; remaining="${remaining#*/}" ;;
			*) component="$remaining"; remaining= ;;
		esac
		case "$component" in ''|.|..) return 1 ;; esac
	done
	if [ -e "$source" ] || [ -L "$source" ]; then SOURCE_PRESENT=true; return 0; fi
	# Failed probes choose only where to query, never whether a path is absent.
	# Start at the nearest observable ancestor rather than cataloging unrelated
	# root or temporary directories for every ordinary optional startup path.
	directory="${source%/*}"
	while [ -n "$directory" ] && [ ! -e "$directory" ] && [ ! -L "$directory" ]; do
		directory="${directory%/*}"
	done
	if [ -z "$directory" ]; then directory=/; remaining="${source#/}"
	else remaining="${source#"$directory"/}"
	fi
	while [ -n "$remaining" ]; do
		case "$remaining" in
			*/*) component="${remaining%%/*}"; remaining="${remaining#*/}" ;;
			*) component="$remaining"; remaining= ;;
		esac
		case "$component" in ''|.|..) return 1 ;; esac
		if catalog_directory "$directory"; then :; else return "$?"; fi
		child="${directory%/}/$component"
		if [ -z "${DIRECTORY_ENTRIES["$child"]:-}" ]; then return 0; fi
		if [ -z "$remaining" ]; then SOURCE_PRESENT=true; return 0; fi
		if [ -L "$child" ] || [ ! -d "$child" ] || [ ! -x "$child" ]; then return 1; fi
		directory="$child"
	done
	return 1
}

finish_uninstall() {
	local failed=false index original snapshot parent temporary actual original_mode snapshot_mode
	[ -n "$UNINSTALL_RECOVERY" ] || return 0
	if "$UNINSTALL_FINALIZED"; then return 0; fi
	UNINSTALL_FINALIZED=true
	if "$UNINSTALL_REMOVAL_STARTED" && ! "$UNINSTALL_REMOVAL_COMMITTED"; then
		for index in "${!SNAPSHOT_SOURCES[@]}"; do
			original="${SNAPSHOT_SOURCES[$index]}"
			snapshot="$UNINSTALL_RECOVERY/$index"
			# An incumbent, including a replacement link, is never overwritten.
			parent="$(dirname -- "$original")"
			if [ -e "$original" ] || [ -L "$original" ]; then
				if [ -L "$original" ] || [ ! -f "$original" ] \
					|| [ "$(cd -- "$parent" && pwd -P)" != "$parent" ] \
					|| ! actual="$(sha256sum < "$original")" \
					|| [ "${actual%% *}" != "${SNAPSHOT_DIGESTS[$index]}" ] \
					|| ! original_mode="$(stat -c %a -- "$original")" \
					|| ! snapshot_mode="$(stat -c %a -- "$snapshot")" \
					|| [ "$original_mode" != "$snapshot_mode" ]; then
					uninstall_record rollback-failed original "$original"
					failed=true
				fi
				continue
			fi
			if [ ! -d "$parent" ] \
				|| [ "$(cd -- "$parent" && pwd -P)" != "$parent" ]; then
				uninstall_record rollback-failed original "$original"
				failed=true
				continue
			fi
			# Publish by a same-parent hard link, which refuses every incumbent.
			# Staging in that parent also supports external XDG filesystems.
			if ! temporary="$(mktemp "$parent/.ergopti-restore.XXXXXX")"; then
				uninstall_record rollback-failed original "$original"
				failed=true
				continue
			fi
			if ! cp -p -- "$snapshot" "$temporary" \
				|| ! actual="$(sha256sum < "$temporary")" \
				|| [ "${actual%% *}" != "${SNAPSHOT_DIGESTS[$index]}" ] \
				|| ! ln -T -- "$temporary" "$original"; then
				uninstall_record rollback-failed original "$original"
				failed=true
			fi
			if ! rm -f -- "$temporary"; then
				uninstall_record cleanup-failed temporary "$temporary"
				failed=true
			fi
		done
	fi
	if "$failed"; then
		uninstall_record recovery-retained snapshot "$UNINSTALL_RECOVERY"
		return 1
	fi
	# Once payload and receipt removal committed, cleanup cannot roll back it.
	if ! rm -rf -- "$UNINSTALL_RECOVERY"; then
		uninstall_record cleanup-failed snapshot "$UNINSTALL_RECOVERY"
		return 1
	fi
	UNINSTALL_RECOVERY=
}

prepare_uninstall_snapshots() {
	local index original actual candidate
	# Refused allocation output cannot grant ownership of a recovery directory.
	if ! candidate="$(mktemp -d "$LIBRARY/.ergopti-uninstall.XXXXXX")"; then return 1; fi
	UNINSTALL_RECOVERY="$candidate"
	# NUL-framed paths and ordered digests make retained copies recoverable
	# without evaluating filenames as shell text or relying on vanished files.
	printf '%s\0' "${SNAPSHOT_SOURCES[@]}" > "$UNINSTALL_RECOVERY/paths"
	printf '%s\n' "${SNAPSHOT_DIGESTS[@]}" > "$UNINSTALL_RECOVERY/digests"
	for index in "${!SNAPSHOT_SOURCES[@]}"; do
		original="${SNAPSHOT_SOURCES[$index]}"
		cp -p -- "$original" "$UNINSTALL_RECOVERY/$index"
		actual="$(sha256sum < "$UNINSTALL_RECOVERY/$index")"
		if [ "${actual%% *}" != "${SNAPSHOT_DIGESTS[$index]}" ]; then
			uninstall_record snapshot-refused original "$original"
			exit 1
		fi
	done
}

# EX_UNAVAILABLE names a missing program: the menu passes a localized message
# whose {1} is that program, so the dialog says what to install.
report_exit() {
	local status=$?
	trap - EXIT
	if ! finish_uninstall; then status=1; fi
	if [ "$status" -eq 69 ] && [ -n "$MISSING_PROGRAM" ] && [ -n "$GUI_MISSING" ]; then
		GUI_ERROR="${GUI_MISSING//\{1\}/$MISSING_PROGRAM}"
	fi
	if [ "$status" -ne 0 ] && [ -n "$GUI_TITLE" ]; then
		show_failure_dialog
	fi
	exit "$status"
}
trap report_exit EXIT

if ! "$CONFIRMED" && ! "$CHECK_ONLY"; then
	echo 'Explicit --yes confirmation is required; personal data will be retained.' >&2
	exit 64
fi

# A menu worker runs outside the daemon's systemd control group. It may only
# remove files after the exact requesting process has finished its cleanup.
if [ -n "$WAIT_OWNER" ]; then
	[[ "$WAIT_OWNER" =~ ^([0-9]+):([0-9]+)$ ]] || exit 64
	owner_pid="${BASH_REMATCH[1]}"
	owner_start="${BASH_REMATCH[2]}"
	for ((attempt = 0; attempt < 300; attempt++)); do
		if [ ! -e "/proc/$owner_pid/stat" ]; then break; fi
		if ! stat="$(cat "/proc/$owner_pid/stat")"; then continue; fi
		read -ra fields <<< "${stat##*) }"
		if [ "${fields[19]:-}" != "$owner_start" ]; then break; fi
		# A zombie has finished cleanup; only its parent can reap the proc entry.
		if [ "${fields[0]:-}" = Z ]; then break; fi
		sleep 0.1
	done
	[ "$attempt" -lt 300 ] || { echo 'The application did not finish shutting down.' >&2; exit 1; }
fi

remove_native_startup() {
	local entry="${CONFIG_ROOT}/autostart/ergopti.desktop"
	if [ -f "$entry" ] && [ ! -L "$entry" ] \
		&& grep -Fxq "$(ergopti_desktop_exec /usr/bin/ergopti)" "$entry"; then
		rm -- "$entry"
	fi
}

if [ "$SCRIPT_DIR" = /usr/lib/ergopti ]; then
	# Never remove package files ourselves, even if authorization is refused.
	if command -v dpkg-query >/dev/null 2>&1 && dpkg-query -S "$SCRIPT_DIR/uninstall.sh" | grep -Fxq "${PACKAGE_NAME}: $SCRIPT_DIR/uninstall.sh"; then
		if "$CHECK_ONLY"; then exit 0; fi
		# EX_UNAVAILABLE: the package manager that owns the package is missing.
		# The stderr line is a machine-readable token, not a sentence.
		command -v apt-get >/dev/null 2>&1 || { MISSING_PROGRAM=apt-get; printf '%s %s\n' missing-program apt-get >&2; exit 69; }
		pkexec /usr/bin/apt-get remove -y "$PACKAGE_NAME"
		remove_native_startup
		exit 0
	elif command -v rpm >/dev/null 2>&1 \
		&& rpm_owner="$(rpm -qf --qf '%{NAME}' "$SCRIPT_DIR/uninstall.sh")" \
		&& [ "$rpm_owner" = "$PACKAGE_NAME" ]; then
		if "$CHECK_ONLY"; then exit 0; fi
		pkexec /usr/bin/rpm -e "$PACKAGE_NAME"
		remove_native_startup
		exit 0
	elif command -v pacman >/dev/null 2>&1 \
		&& pacman_owner="$(pacman -Qoq -- "$SCRIPT_DIR/uninstall.sh")" \
		&& [ "$pacman_owner" = "$PACKAGE_NAME" ]; then
		if "$CHECK_ONLY"; then exit 0; fi
		pkexec /usr/bin/pacman -R --noconfirm "$PACKAGE_NAME"
		remove_native_startup
		exit 0
	fi
	echo 'The system installation has no verified package owner.' >&2
	exit 1
fi

# Resolve before deleting and reject system roots and link aliases. The only
# removable standalone tree is the layout created by install.sh.
[ -d "$PREFIX" ] || { echo 'Installation prefix does not exist.' >&2; exit 1; }
IFS= read -r -d '' PREFIX < <(CDPATH= cd -Pe -- "$PREFIX" && printf '%s\0' "$PWD")
case "$PREFIX" in
	/|/usr|/usr/local|/app|/nix|/nix/*) echo 'Refusing a system installation prefix.' >&2; exit 1 ;;
esac
LIBRARY="$PREFIX/lib/ergopti"
WRAPPER="$PREFIX/bin/ergopti-hotstrings"
if [ -L "$LIBRARY" ] || [ -L "$WRAPPER" ] || [ ! -f "$LIBRARY/linux/ergopti_hotstrings.lua" ] \
	|| [ ! -f "$LIBRARY/_shared/data/locales/en.json" ] || [ ! -f "$WRAPPER" ]; then
	echo 'The prefix is not a complete owned standalone installation.' >&2
	exit 1
fi
[ "$(cd -- "$LIBRARY" && pwd -P)" = "$LIBRARY" ] || { echo 'Installation path crosses a symbolic link.' >&2; exit 1; }
if { grep -Fqx "INSTALL_ROOT=$(printf '%q' "$LIBRARY")" "$WRAPPER" \
	&& grep -Fqx 'exec bash "${INSTALL_ROOT}/bin/ergopti-hotstrings" "$@"' "$WRAPPER"; }; then
	:
elif ! { grep -Fqx "DRIVER_ROOT=\"$LIBRARY/linux\"" "$WRAPPER" \
		|| grep -Fqx "DRIVER_ROOT=$(printf '%q' "$LIBRARY/linux")" "$WRAPPER"; } \
	|| ! { grep -Fqx 'exec bash "${DRIVER_ROOT}/install/launch.sh" --service "$@"' "$WRAPPER" \
		|| grep -Fqx 'exec luajit "${DRIVER_ROOT}/ergopti_hotstrings.lua" "$@"' "$WRAPPER"; }; then
	echo 'The launcher belongs to a different installation.' >&2
	exit 1
fi
# Use a match only as a nonempty marker; never parse filenames as lines.
# A refused walk cannot prove either absence of a checkout or complete access.
if ! checkout_marker="$(find "$LIBRARY" -name .git -print -quit)"; then
	uninstall_record scan-refused library "$LIBRARY"
	exit 1
fi
if [ -n "$checkout_marker" ]; then
	echo 'Refusing to remove a source checkout.' >&2
	exit 1
fi
ancestor="$LIBRARY"
while [ "$ancestor" != / ]; do
	if [ -e "$ancestor/.git" ]; then
		echo 'Refusing to remove files inside a source checkout.' >&2
		exit 1
	fi
	ancestor="$(dirname -- "$ancestor")"
done
MANIFEST="$LIBRARY/.ergopti-owned-files"
UNIT="$CONFIG_ROOT/systemd/user/ergopti-hotstrings.service"
AUTOSTART="$CONFIG_ROOT/autostart/ergopti-hotstrings.desktop"
[ -f "$MANIFEST" ] && [ ! -L "$MANIFEST" ] && [ -s "$MANIFEST" ] || { echo 'Installation ownership manifest is missing.' >&2; exit 1; }
OWNED=()
OWNED_DIGESTS=()
REMOVE_UNIT=false
declare -A SEEN=()
while IFS=$'\t' read -r digest relative || [ -n "$digest$relative" ]; do
	[[ "$digest" =~ ^[0-9a-f]{64}$ ]] || { echo 'Invalid ownership digest.' >&2; exit 1; }
	case "$relative" in
		linux/*|_shared/*|bin/ergopti-hotstrings) owned="$LIBRARY/$relative" ;;
		@wrapper) owned="$WRAPPER" ;;
		@unit) owned="$UNIT" ;;
		@autostart) owned="$AUTOSTART" ;;
		*) echo 'Invalid ownership path.' >&2; exit 1 ;;
	esac
	case "/$relative/" in
		*/../*|*/./*|*//*|*\\*) echo 'Unsafe ownership path.' >&2; exit 1 ;;
	esac
	[ -z "${SEEN[$owned]:-}" ] || { echo 'Duplicate ownership path.' >&2; exit 1; }
	SEEN[$owned]=1
	if admit_source_path "$owned"; then :
	else
		admission_status=$?
		uninstall_invalid_source "$owned"
		exit "$admission_status"
	fi
	if "$SOURCE_PRESENT"; then
		[ ! -L "$owned" ] && [ -f "$owned" ] \
			&& [ "$(cd -- "$(dirname -- "$owned")" && pwd -P)" = "$(dirname -- "$owned")" ] \
			|| { echo 'Owned file was replaced by a link or another file type.' >&2; exit 1; }
		actual="$(sha256sum < "$owned")"
		# A modified shipped file might contain personal data. Keep it, just as
		# we keep files absent from the installer's payload manifest.
		if [ "${actual%% *}" = "$digest" ]; then
			OWNED+=("$owned")
			OWNED_DIGESTS+=("$digest")
			if [ "$owned" = "$UNIT" ]; then REMOVE_UNIT=true; fi
		fi
	fi
done < "$MANIFEST"

for entry in "$UNIT" "$AUTOSTART"; do
	if admit_source_path "$entry"; then :
	else
		admission_status=$?
		uninstall_invalid_source "$entry"
		exit "$admission_status"
	fi
	if ! "$SOURCE_PRESENT"; then continue; fi
	# Unlisted startup entries bypass the payload receipt loop. Admit the same
	# regular, direct source before grep can follow an alias or wait on a FIFO.
	if [ -L "$entry" ] || [ ! -f "$entry" ] \
		|| [ "$(cd -- "$(dirname -- "$entry")" && pwd -P)" != "$(dirname -- "$entry")" ]; then
		uninstall_invalid_source "$entry"
		exit 1
	fi
	if ! grep -Fq "$WRAPPER --tray" "$entry" \
		&& ! grep -Fxq "$(ergopti_desktop_exec "$WRAPPER")" "$entry" \
		&& ! grep -Fxq "$(ergopti_systemd_exec "$WRAPPER")" "$entry"; then
		echo "Startup entry belongs to a different installation: $entry" >&2
		exit 1
	fi
done
if [ -f "$UNIT" ] && ! "$REMOVE_UNIT"; then
	echo 'The service was modified or has no ownership record; uninstall was refused.' >&2
	exit 1
fi
if "$CHECK_ONLY"; then exit 0; fi
SNAPSHOT_SOURCES=("${OWNED[@]}" "$MANIFEST")
manifest_digest="$(sha256sum < "$MANIFEST")"
SNAPSHOT_DIGESTS=("${OWNED_DIGESTS[@]}" "${manifest_digest%% *}")
prepare_uninstall_snapshots
if [ -f "$UNIT" ] && command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
	systemctl --user disable --now ergopti-hotstrings.service
fi
UNINSTALL_REMOVAL_STARTED=true
for owned in "${OWNED[@]}"; do rm -- "$owned"; done
rm -- "$MANIFEST"
UNINSTALL_REMOVAL_COMMITTED=true
finish_uninstall
find "$LIBRARY" -depth -type d -empty -delete
if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
	systemctl --user daemon-reload
fi
