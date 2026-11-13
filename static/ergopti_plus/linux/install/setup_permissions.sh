#!/usr/bin/env bash
# static/ergopti_plus/linux/install/setup_permissions.sh
#
# Privileged permission owner shared by packages and the standalone installer.
# Package hooks enroll only users of local graphical sessions, never every
# account in passwd. A graphical launcher may explicitly enroll its own UID.

set -euo pipefail
# The sentences this script prints, in the user's language (install/messages.sh).
source "$(dirname -- "${BASH_SOURCE[0]}")/messages.sh"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
[ "$(id -u)" = 0 ] || { ergopti_msg permissions.requires_admin >&2; exit 77; }
# Accounts and groups resolve through NSS (LDAP, sssd), so through getent;
# without it nothing is changed (EX_UNAVAILABLE). The stderr line is a
# machine-readable token, not a sentence: the Lua caller localizes it
# (platform/input/access.lua) and a terminal reader sees the program's name.
command -v getent >/dev/null 2>&1 || { printf '%s %s\n' missing-program getent >&2; exit 69; }
MODE="${1:-}"
case "$MODE" in
	--active-sessions) [ "$#" -eq 1 ] || exit 64 ;;
	--user) [ "$#" -eq 2 ] || exit 64 ;;
	*) echo 'Expected --active-sessions or --user UID.' >&2; exit 64 ;;
esac

resolve_user() {
	local uid="$1" entry name password resolved_uid rest
	[[ "$uid" =~ ^[0-9]+$ ]] && [ "$uid" -ge 1000 ] && [ "$uid" -ne 65534 ] \
		|| { ergopti_msg permissions.non_desktop_account >&2; return 1; }
	entry="$(getent passwd "$uid")" || return 1
	case "$entry" in *$'\n'*) ergopti_msg permissions.identity_mismatch >&2; return 1 ;; esac
	IFS=: read -r name password resolved_uid rest <<< "$entry"
	[ "$resolved_uid" = "$uid" ] && [ -n "$name" ] || { ergopti_msg permissions.identity_mismatch >&2; return 1; }
	printf '%s\n' "$name"
}

enroll_user() {
	local name
	name="$(resolve_user "$1")" || return 1
	if command -v usermod >/dev/null 2>&1; then
		usermod -aG input,uinput "$name"
	else
		addgroup "$name" input || return 1
		addgroup "$name" uinput
	fi
}

if [ "$MODE" = --user ]; then resolve_user "$2" >/dev/null; fi

# A dangling administrator-owned link is not usable configuration. Preserve it
# and report the conflict before creating groups or changing system files.
for config in /etc/udev/rules.d/99-ergopti-uinput.rules /etc/modules-load.d/ergopti-uinput.conf; do
	if [ -L "$config" ] && [ ! -e "$config" ]; then
		printf '[permissions] code=dangling-configuration path=%q\n' "$config" >&2
		exit 78
	fi
	# Existing administrator files, including links to /dev/null used to mask
	# rules, remain theirs. A directory or FIFO cannot serve as configuration.
	if [ -e "$config" ] && [ ! -f "$config" ] && [ ! "$config" -ef /dev/null ]; then
		printf '[permissions] code=invalid-configuration path=%q\n' "$config" >&2
		exit 78
	fi
done

missing_groups=()
for group in input uinput; do
	if getent group "$group" >/dev/null; then
		:
	else
		lookup_status=$?
		# getent reports an absent key as 2. Other errors cannot authorize
		# creating a local group, which could shadow an unavailable NSS entry.
		if [ "$lookup_status" -ne 2 ]; then
			printf '[permissions] code=group-lookup-failed group=%s status=%s\n' "$group" "$lookup_status" >&2
			exit "$lookup_status"
		fi
		missing_groups+=("$group")
	fi
done
for group in "${missing_groups[@]}"; do
	if command -v groupadd >/dev/null 2>&1; then groupadd --system "$group"
	else addgroup -S "$group"; fi
done
install -d /etc/udev/rules.d /etc/modules-load.d
if [ ! -e /etc/udev/rules.d/99-ergopti-uinput.rules ] && [ ! -L /etc/udev/rules.d/99-ergopti-uinput.rules ]; then
	install -m 644 "$SCRIPT_DIR/99-ergopti-uinput.rules" /etc/udev/rules.d/99-ergopti-uinput.rules
fi
if [ ! -e /etc/modules-load.d/ergopti-uinput.conf ] && [ ! -L /etc/modules-load.d/ergopti-uinput.conf ]; then
	install -m 644 "$SCRIPT_DIR/ergopti-uinput.conf" /etc/modules-load.d/ergopti-uinput.conf
fi

enrollment_failed=false
if [ "$MODE" = --user ]; then
	enroll_user "$2"
elif command -v loginctl >/dev/null 2>&1; then
	# A missing session bus is normal in a package build container. The launcher
	# handles first login; no unrelated account receives keyboard access here.
	if sessions="$(loginctl list-sessions --no-legend 2>/dev/null)"; then
		while read -r session rest; do
			[ -n "$session" ] || continue
			# A user can log out between enumeration and inspection. Read one
			# snapshot; the launcher owns enrollment if this session disappears.
			if ! properties="$(loginctl show-session "$session" -p Type -p Remote -p Class -p Active -p User)"; then
				ergopti_msg permissions.session_uninspectable "$session" >&2
				continue
			fi
			type= remote= class= active= uid=
			while IFS='=' read -r key value; do
				case "$key" in
					Type) type="$value" ;; Remote) remote="$value" ;;
					Class) class="$value" ;; Active) active="$value" ;; User) uid="$value" ;;
				esac
			done <<< "$properties"
			case "$type:$remote:$class:$active" in
				x11:no:user:yes|wayland:no:user:yes)
					# Incomplete sessions and system accounts are not candidates for
					# keyboard access and must not abort setup for other users.
					if [[ "$uid" =~ ^[0-9]+$ ]]; then
						if [ "$uid" -ge 1000 ] && [ "$uid" -ne 65534 ]; then
							if ! enroll_user "$uid"; then
								printf '[permissions] code=session-enrollment-failed session=%q uid=%s\n' "$session" "$uid" >&2
								enrollment_failed=true
							fi
						else
							ergopti_msg permissions.non_desktop_account >&2
						fi
					else
						ergopti_msg permissions.session_uninspectable "$session" >&2
					fi ;;
			esac
		done <<< "$sessions"
	else
		ergopti_msg permissions.no_login_manager >&2
	fi
fi

if ! modprobe uinput; then
	ergopti_msg permissions.uinput_next_boot >&2
fi
if [ -S /run/udev/control ]; then
	udevadm control --reload-rules
	udevadm trigger --subsystem-match=misc --sysname-match=uinput
else
	ergopti_msg permissions.udev_not_running >&2
fi

# One session disappearing or failing enrollment must not skip later sessions,
# but callers still need to know that setup did not complete for every user.
[ "$enrollment_failed" = false ]
