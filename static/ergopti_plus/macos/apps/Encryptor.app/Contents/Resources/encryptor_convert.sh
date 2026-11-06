#!/bin/sh
# apps/Encryptor.app/Contents/Resources/encryptor_convert.sh
#
# Runs one Encryptor conversion with OpenSSL AES-256-CBC (PBKDF2, 600000 iterations).
#
# Usage: encryptor_convert.sh encrypt|decrypt INPUT OUTPUT PASSWORD_FILE
#
# The password is read by OpenSSL from PASSWORD_FILE (first line, "-pass file:"),
# never from a command argument: arguments are readable by any local process
# through the process table, so main.applescript writes the password into a
# private folder and passes only its path here.
#
# OpenSSL writes into a stage next to OUTPUT, which replaces OUTPUT only once
# the conversion succeeded. A wrong password or a corrupted file therefore
# leaves an existing OUTPUT (whose overwrite the user approved) byte for byte,
# and a failure removes only the stage this run created.
set -u

if [ "$#" -ne 4 ]; then
	echo "usage: encryptor_convert.sh encrypt|decrypt INPUT OUTPUT PASSWORD_FILE" >&2
	exit 64
fi
mode=$1
input=$2
output=$3
password_file=$4

case "$mode" in
	encrypt) direction="-e" ;;
	decrypt) direction="-d" ;;
	*)
		echo "encryptor_convert.sh: unknown mode '$mode'" >&2
		exit 64
		;;
esac
if [ ! -f "$password_file" ]; then
	echo "encryptor_convert.sh: password file not found" >&2
	exit 66
fi

stage=$(mktemp "$(dirname "$output")/.$(basename "$output").XXXXXX") || {
	echo "encryptor_convert.sh: cannot create a stage next to the output" >&2
	exit 73
}
if ! openssl enc "$direction" -aes-256-cbc -pbkdf2 -iter 600000 \
	-in "$input" -out "$stage" -pass "file:$password_file"; then
	rm -f "$stage"
	exit 1
fi
# mktemp creates the stage 0600; give the output the mode a new file gets
mode_bits=$(printf '%o' $((0666 & ~$(umask))))
if ! chmod "$mode_bits" "$stage" || ! mv -f "$stage" "$output"; then
	rm -f "$stage"
	echo "encryptor_convert.sh: cannot publish the converted file" >&2
	exit 74
fi
