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

if ! openssl enc "$direction" -aes-256-cbc -pbkdf2 -iter 600000 \
	-in "$input" -out "$output" -pass "file:$password_file"; then
	# Remove the partial output of the failed conversion
	rm -f "$output"
	exit 1
fi
