#!/usr/bin/env bash
# static/ergopti_plus/linux/install/start_at_login.sh
#
# User-owned startup choice. Disabling affects future sessions only; the current
# daemon must remain alive while its menu reports the result.

set -euo pipefail
# Load localized user-facing messages before any mutation.
source "$(dirname -- "${BASH_SOURCE[0]}")/messages.sh"
DRIVER_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
source "$DRIVER_ROOT/install/desktop_entry.sh"
source "$DRIVER_ROOT/install/config_home.sh"
ergopti_resolve_config_home CONFIG_ROOT
ACTION="${1:-status}"
case "$ACTION" in status|enable|disable) ;; *) exit 64 ;; esac

# The arguments the entry passes its launcher; empty is the installed form.
LAUNCH_ARGUMENTS=
if [ "$DRIVER_ROOT" = /usr/lib/ergopti ]; then
	DESKTOP_NAME=ergopti.desktop
	LAUNCHER=/usr/bin/ergopti
	receipt_allowed=false
elif [[ "$DRIVER_ROOT" = */lib/ergopti/linux ]]; then
	DESKTOP_NAME=ergopti-hotstrings.desktop
	LAUNCHER="${DRIVER_ROOT%/lib/ergopti/linux}/bin/ergopti-hotstrings"
	receipt_allowed=true
elif [ -f "$DRIVER_ROOT/bin/ergopti-hotstrings" ] && [ -f "$DRIVER_ROOT/../_shared/data/locales/en.json" ]; then
	# A source run starts its own checkout by absolute path, as Windows registers
	# its source script (SAD-1). Its launcher takes the daemon's --tray alone;
	# a second start at login is refused by the session lock.
	DESKTOP_NAME=ergopti-hotstrings.desktop
	LAUNCHER="$DRIVER_ROOT/bin/ergopti-hotstrings"
	LAUNCH_ARGUMENTS=--tray
	receipt_allowed=false
else
	ergopti_msg startup.requires_installed >&2
	exit 78
fi
DESKTOP_FILE="$CONFIG_ROOT/autostart/$DESKTOP_NAME"
USER_UNIT="$CONFIG_ROOT/systemd/user/ergopti-hotstrings.service"

# systemd expands %h from the account database, not from an arbitrary HOME in
# this process. Admit the documented manual unit only when that physical prefix
# is the one this installation actually owns.
startup_manual_unit_matches() {
	"$receipt_allowed" || return 1
	local uid entry name password account_uid group_id comment account_home shell prefix
	uid="$(id -u)" || return 1
	command -v getent >/dev/null 2>&1 || return 1
	entry="$(getent passwd "$uid")" || return 1
	case "$entry" in *$'\n'*) return 1 ;; esac
	IFS=: read -r name password account_uid group_id comment account_home shell <<< "$entry"
	[ -n "$name" ] && [ "$account_uid" = "$uid" ] || return 1
	case "$account_home" in /*) ;; *) return 1 ;; esac
	IFS= read -r -d '' prefix < <(CDPATH= cd -Pe -- "$account_home/.local" && printf '%s\0' "$PWD") || return 1
	[ "$prefix/bin/ergopti-hotstrings" = "$LAUNCHER" ]
}

# A same-named user unit can belong to a second installation. Never disable it
# merely because systemd lists the name; only admit an unambiguous launcher.
startup_unit_compatible() {
	local unit_path="$1" expected line count=0
	[ -f "$unit_path" ] && [ ! -L "$unit_path" ] || return 1
	expected="$(ergopti_systemd_exec "$LAUNCHER")" || return 1
	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in
			ExecStart=*)
				count=$((count + 1))
				case "$line" in
					"$expected"|"ExecStart=$LAUNCHER --tray"|"ExecStart=$LAUNCHER --service --tray") ;;
					'ExecStart=%h/.local/bin/ergopti-hotstrings --tray') startup_manual_unit_matches || return 1 ;;
					*) return 1 ;;
				esac ;;
		esac
	done < "$unit_path"
	[ "$count" -eq 1 ]
}
if { [ -e "$USER_UNIT" ] || [ -L "$USER_UNIT" ]; } && ! startup_unit_compatible "$USER_UNIT"; then
	if [ "$ACTION" = status ]; then printf 'other\n'; exit 0; fi
	printf '[startup] code=foreign-unit path=%q\n' "$USER_UNIT" >&2
	exit 78
fi

# An entry this menu wrote whose launcher no longer exists (a moved or deleted
# checkout, a removed installation) starts nothing at login. It is reported as
# stale, and an explicit enable or disable rewrites it for this launcher. A
# standalone installation's entry is held by its removal receipt instead, which
# a rewrite here could not keep exact: there it stays another command.
startup_entry_stale() {
	local named
	! "$receipt_allowed" || return 1
	[ -f "$DESKTOP_FILE" ] && [ ! -L "$DESKTOP_FILE" ] || return 1
	named="$(ergopti_desktop_entry_launcher "$DESKTOP_FILE")" || return 1
	[ "$named" != "$LAUNCHER" ] && [ ! -e "$named" ]
}

if [ "$ACTION" = status ]; then
	if startup_entry_stale; then printf 'stale\n'; exit 0; fi
	# Report a real conflicting command without acquiring it for replacement.
	if [ -f "$DESKTOP_FILE" ] && ! ergopti_desktop_entry_owned "$DESKTOP_FILE" "$LAUNCHER" "$LAUNCH_ARGUMENTS"; then
		printf 'other\n'
		exit 0
	fi
	# A separately enabled unit starts even if the XDG entry is hidden.
	if systemctl --user is-enabled --quiet ergopti-hotstrings.service 2>/dev/null; then
		printf 'enabled\n'
	elif [ -f "$DESKTOP_FILE" ] && ergopti_desktop_entry_disabled "$DESKTOP_FILE"; then
		printf 'disabled\n'
	elif [ -f "$DESKTOP_FILE" ] || [ -f "/etc/xdg/autostart/$DESKTOP_NAME" ]; then
		printf 'enabled\n'
	else
		printf 'disabled\n'
	fi
	exit 0
fi

# Operator records remain language-independent data. The menu renders its
# existing localized failure, while an installer terminal retains code/path
# evidence without a second catalogue or a new untranslated sentence.
startup_record() {
	local record="[startup] code=$1 role=$2"
	printf '%s path=%q\n' "$record" "$3" >&2
}

# Validate the eventual Exec before allocating or publishing any setting.
desktop_exec="$(ergopti_desktop_exec "$LAUNCHER" ${LAUNCH_ARGUMENTS:+"$LAUNCH_ARGUMENTS"})" || exit 78

if { [ -e "$DESKTOP_FILE" ] || [ -L "$DESKTOP_FILE" ]; } \
	&& { [ -L "$DESKTOP_FILE" ] || [ ! -f "$DESKTOP_FILE" ]; }; then
	if [ -L "$DESKTOP_FILE" ]; then ergopti_msg startup.linked_setting >&2; fi
	startup_record invalid-source desktop "$DESKTOP_FILE"
	exit 78
fi
if [ -f "$DESKTOP_FILE" ] && ! startup_entry_stale \
	&& ! ergopti_desktop_entry_owned "$DESKTOP_FILE" "$LAUNCHER" "$LAUNCH_ARGUMENTS"; then
	ergopti_msg startup.foreign_entry >&2
	exit 78
fi

# Admit the receipt before changing startup or its service. A linked or special
# source cannot authorize publishing a preference that removal cannot own.
manifest="$DRIVER_ROOT/../.ergopti-owned-files"
receipt_present=false
if "$receipt_allowed" && { [ -e "$manifest" ] || [ -L "$manifest" ]; }; then
	[ ! -L "$manifest" ] && [ -f "$manifest" ] \
		|| {
			if [ -L "$manifest" ]; then ergopti_msg startup.linked_receipt >&2; fi
			startup_record invalid-source receipt "$manifest"; exit 78;
		}
	receipt_present=true
fi

install -d -m 700 "$CONFIG_ROOT/autostart"
desktop_tmp= receipt_tmp= desktop_previous= receipt_previous=
desktop_published=false
receipt_published=false
committed=false

# Two file renames are not a hard-kill transaction. On an observed publication
# or service failure, restore the previous owned bytes and retain recovery
# copies if restoration itself is refused.
finish_startup() {
	local status=$? rollback_failed=false temporary recovery_recorded=false
	trap - EXIT
	if ! "$committed"; then
		if "$desktop_published"; then
			if [ -n "$desktop_previous" ]; then
				if mv -f -- "$desktop_previous" "$DESKTOP_FILE"; then desktop_previous=; else rollback_failed=true; fi
			elif ! rm -f -- "$DESKTOP_FILE"; then rollback_failed=true; fi
		fi
		if "$receipt_published"; then
			if mv -f -- "$receipt_previous" "$manifest"; then receipt_previous=; else rollback_failed=true; fi
		fi
	fi
	if "$rollback_failed"; then
		for temporary in "$desktop_previous" "$receipt_previous"; do
			if [ -n "$temporary" ]; then
				startup_record rollback-failed recovery "$temporary"
				recovery_recorded=true
			fi
		done
		if ! "$recovery_recorded"; then startup_record rollback-failed desktop "$DESKTOP_FILE"; fi
		status=1
	else
		for temporary in "$desktop_tmp" "$receipt_tmp" "$desktop_previous" "$receipt_previous"; do
			if [ -n "$temporary" ] && ! rm -f -- "$temporary"; then
				startup_record cleanup-failed temporary "$temporary"
				status=1
			fi
		done
	fi
	exit "$status"
}
trap finish_startup EXIT

desktop_tmp="$(mktemp "$DESKTOP_FILE.XXXXXX")"
previous_desktop_digest=
if [ -f "$DESKTOP_FILE" ]; then
	desktop_previous="$(mktemp "$DESKTOP_FILE.previous.XXXXXX")"
	cp -p -- "$DESKTOP_FILE" "$desktop_previous"
	# Recheck the snapshot that will actually be rewritten.
	ergopti_desktop_entry_textual "$desktop_previous" || {
		startup_record invalid-source desktop "$DESKTOP_FILE"; exit 78;
	}
	previous_desktop_digest="$(sha256sum < "$desktop_previous")"
	previous_desktop_digest="${previous_desktop_digest%% *}"
	cp -p -- "$desktop_previous" "$desktop_tmp"
fi
hidden=false
if [ "$ACTION" = disable ]; then hidden=true; fi
write_desktop_choice() {
	local line normalized carriage group= inserted=false newline= last_newline=true
	while :; do
		line= newline=
		if IFS= read -r line; then newline=$'\n'; else [ -n "$line" ] || break; fi
		normalized="$line"
		[ -z "$newline" ] || normalized="${normalized%$'\r'}"
		normalized="${normalized#"${normalized%%[![:space:]]*}"}"
		case "$normalized" in
			\[*\]*)
				if [ "$group" = main ] && ! "$inserted"; then
					printf 'Hidden=%s\nX-Ergopti-Startup=true\n' "$hidden" || return 1
					inserted=true
				fi
				normalized="${normalized%"${normalized##*[![:space:]]}"}"
				if [ "$normalized" = '[Desktop Entry]' ]; then group=main; else group=other; fi ;;
			*)
				if [ "$group" = main ] && [[ "$normalized" =~ ^Exec[[:space:]]*= ]]; then
					carriage=
					if [ -n "$newline" ] && [[ "$line" = *$'\r' ]]; then carriage=$'\r'; fi
					printf '%s%s%s' "$desktop_exec" "$carriage" "$newline" || return 1
					if [ -n "$newline" ]; then last_newline=true; else last_newline=false; fi
					continue
				fi
				if [ "$group" = main ] && [[ "$normalized" =~ ^(Hidden|X-GNOME-Autostart-enabled|X-Ergopti-Startup)[[:space:]]*= ]]; then
					continue
				fi ;;
		esac
		printf '%s%s' "$line" "$newline" || return 1
		if [ -n "$newline" ]; then last_newline=true; else last_newline=false; fi
	done < "$desktop_previous" || return 1
	if [ "$group" = main ] && ! "$inserted"; then
		if ! "$last_newline"; then printf '\n' || return 1; fi
		printf 'Hidden=%s\nX-Ergopti-Startup=true\n' "$hidden" || return 1
	fi
}
if [ -n "$desktop_previous" ]; then
	write_desktop_choice > "$desktop_tmp"
else
	cat > "$desktop_tmp" <<EOF
[Desktop Entry]
Type=Application
Name=Ergopti
$desktop_exec
Terminal=false
Hidden=$hidden
X-Ergopti-Startup=true
EOF
fi
# Standalone removal follows content receipts, including startup changes made
# by this menu. Stage its exact new digest before either file is published.
if "$receipt_present"; then
	receipt_previous="$(mktemp "$manifest.previous.XXXXXX")"
	cp -p -- "$manifest" "$receipt_previous"
	receipt_tmp="$(mktemp "$manifest.XXXXXX")"
	cp -p -- "$receipt_previous" "$receipt_tmp"
	declare -A receipt_seen=()
	receipt_count=0
	update_desktop_receipt=false
	if [ -z "$desktop_previous" ]; then update_desktop_receipt=true; fi
	while IFS=$'\t' read -r digest relative || [ -n "$digest$relative" ]; do
		[[ "$digest" =~ ^[0-9a-f]{64}$ ]] || { startup_record invalid-receipt receipt "$manifest"; exit 78; }
		case "$relative" in
			linux/*|_shared/*|bin/ergopti-hotstrings|@wrapper|@unit|@autostart) ;;
			*) startup_record invalid-receipt receipt "$manifest"; exit 78 ;;
		esac
		case "/$relative/" in
			*/../*|*/./*|*//*|*\\*|*$'\r'*|*$'\t'*) startup_record invalid-receipt receipt "$manifest"; exit 78 ;;
		esac
		[ -z "${receipt_seen[$relative]:-}" ] || { startup_record invalid-receipt receipt "$manifest"; exit 78; }
		receipt_seen["$relative"]=1
		((receipt_count += 1))
		if [ "$relative" = @autostart ]; then
			if [ -z "$desktop_previous" ] || [ "$digest" = "$previous_desktop_digest" ]; then
				update_desktop_receipt=true
			else
				printf '%s\t%s\n' "$digest" "$relative"
			fi
		else
			printf '%s\t%s\n' "$digest" "$relative"
		fi
	done < "$receipt_previous" > "$receipt_tmp"
	[ "$receipt_count" -gt 0 ] || { startup_record invalid-receipt receipt "$manifest"; exit 78; }
	if "$update_desktop_receipt"; then
		digest="$(sha256sum < "$desktop_tmp")"
		printf '%s\t@autostart\n' "${digest%% *}" >> "$receipt_tmp"
	fi
	mv -f -- "$receipt_tmp" "$manifest"
	receipt_published=true
fi
mv -f -- "$desktop_tmp" "$DESKTOP_FILE"
desktop_published=true

# XDG is the session entry point on every desktop. Only a complete publication
# can authorize changing the unit; a refusal restores both file snapshots.
if command -v systemctl >/dev/null 2>&1; then
	# list-unit-files works without a user bus; a failed query remains an error.
	# A filtered query exits 1 for a missing unit on systemd 257, so select from
	# the complete successful inventory instead of filtering the native query.
	unit_files="$(SYSTEMD_COLORS=0 systemctl --user --no-pager --no-legend list-unit-files)"
	unit_present=false
	while read -r unit_name unit_state unit_metadata; do
		if [ "$unit_name" = ergopti-hotstrings.service ]; then unit_present=true; break; fi
	done <<< "$unit_files"
	if "$unit_present"; then
		if unit_properties="$(SYSTEMD_COLORS=0 systemctl --user show ergopti-hotstrings.service --all -p FragmentPath -p DropInPaths 2>/dev/null)"; then
			fragment= dropins= fragment_count=0 dropin_count=0
			while IFS='=' read -r property value; do
				case "$property" in
					FragmentPath) fragment="$value"; fragment_count=$((fragment_count + 1)) ;;
					DropInPaths) dropins="$value"; dropin_count=$((dropin_count + 1)) ;;
				esac
			done <<< "$unit_properties"
			if [ "$fragment_count" -ne 1 ] || [ "$dropin_count" -ne 1 ] || [ -n "$dropins" ] \
				|| [[ "$fragment" != /* ]] || ! startup_unit_compatible "$fragment"; then
				startup_record foreign-unit unit "$fragment"
				exit 78
			fi
			systemctl --user --no-reload disable ergopti-hotstrings.service
		elif [ "$unit_state" != disabled ] || { ! "$receipt_allowed" && [ "$ACTION" = enable ]; }; then
			startup_record unit-unverified unit ergopti-hotstrings.service
			exit 78
		fi
	fi
fi
committed=true
