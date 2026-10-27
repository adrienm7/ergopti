# static/ergopti_plus/linux/install/messages.sh

# ==============================================================================
# MODULE: Shell Messages
# DESCRIPTION:
# Prints the localized sentences of the Linux shell scripts (install.sh,
# uninstall.sh, the launcher and the install/ helpers). Sourced, never run.
#
# FEATURES & RATIONALE:
# 1. One catalogue. The sentences are `linux_shell.*` keys of the shared locale
#    files, translated in every locale; tools/codegen/codegen-linux-shell-messages.cjs
#    projects them to linux/_generated/shell_messages/<code>.msg, because these
#    scripts run before LuaJIT, jq or Python can be assumed.
# 2. The language follows the POSIX precedence LC_ALL, then LC_MESSAGES, then
#    LANG. C, POSIX and an unset environment select English, the source
#    language. A language Ergopti does not ship also selects English: that is
#    the declared source catalogue, chosen by name, not a per-message fallback.
# 3. Fail fast. The catalogue is loaded when this file is sourced, so a missing
#    one stops the script there. A key the selected catalogue does not hold is
#    a broken install, and so is a placeholder with no argument: ergopti_msg
#    reports it on stderr and returns 2 instead of printing an empty or
#    English line.
#
# USAGE:
#   source "<driver>/install/messages.sh"
#   ergopti_msg launcher.missing_dependencies "luajit" >&2
#   ergopti_msg_with "  ✔  " install.step_done "luajit"
# ==============================================================================

ERGOPTI_MESSAGES_DIR="$(dirname "${BASH_SOURCE[0]}")/../_generated/shell_messages"
ERGOPTI_MESSAGES_SOURCE_LOCALE="en"
declare -gA _ERGOPTI_MESSAGES=()
_ERGOPTI_MESSAGES_LOADED=""

# Prints the catalogue code the environment selects.
ergopti_messages_locale() {
	local value="${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}"
	local language="${value%%[_.@]*}"
	language="${language,,}"
	case "$language" in
		"" | c | posix) language="$ERGOPTI_MESSAGES_SOURCE_LOCALE" ;;
		nb | nn) language="no" ;;
	esac
	if [ ! -f "${ERGOPTI_MESSAGES_DIR}/${language}.msg" ]; then
		language="$ERGOPTI_MESSAGES_SOURCE_LOCALE"
	fi
	printf '%s\n' "$language"
}

# Loads the selected catalogue once.
_ergopti_messages_load() {
	[ -n "$_ERGOPTI_MESSAGES_LOADED" ] && return 0
	local file line
	file="${ERGOPTI_MESSAGES_DIR}/$(ergopti_messages_locale).msg"
	if [ ! -f "$file" ]; then
		printf 'ergopti: message catalogue missing: %s\n' "$file" >&2
		return 2
	fi
	while IFS= read -r line || [ -n "$line" ]; do
		case "$line" in "" | "#"*) continue ;; esac
		_ERGOPTI_MESSAGES["${line%%=*}"]="${line#*=}"
	done < "$file"
	_ERGOPTI_MESSAGES_LOADED="$file"
}

# Prints one message without a newline, its {1}..{9} filled from the arguments.
# One left-to-right pass: an argument that itself holds "{2}" is printed as is,
# never filled again.
# @param $1 Message name (the key without its linux_shell. prefix).
ergopti_text() {
	_ergopti_messages_load || return 2
	local name="$1" rest before digit out=""
	shift
	local -a arguments=("$@")
	if [ -z "${_ERGOPTI_MESSAGES[$name]+set}" ]; then
		printf 'ergopti: message %s is not in %s\n' "$name" "$_ERGOPTI_MESSAGES_LOADED" >&2
		return 2
	fi
	rest="${_ERGOPTI_MESSAGES[$name]}"
	while [[ "$rest" == *"{"[1-9]"}"* ]]; do
		before="${rest%%\{[1-9]\}*}"
		digit="${rest:${#before}+1:1}"
		if [ "$digit" -gt "${#arguments[@]}" ]; then
			printf 'ergopti: message %s needs argument %s\n' "$name" "$digit" >&2
			return 2
		fi
		out+="${before}${arguments[digit - 1]}"
		rest="${rest:${#before}+3}"
	done
	printf '%s' "${out}${rest}"
}

# Prints one message and a newline.
ergopti_msg() {
	_ergopti_messages_load || return 2
	ergopti_text "$@" || return 2
	printf '\n'
}

# Prints one message after a fixed prefix (indentation, a status mark), then a
# newline. The prefix is layout, never words: words belong in the catalogue.
# @param $1 Prefix printed as is.
# @param $2 Message name, then its arguments.
ergopti_msg_with() {
	local prefix="$1" text
	shift
	text="$(ergopti_text "$@")" || return 2
	printf '%s%s\n' "$prefix" "$text"
}

_ergopti_messages_load
