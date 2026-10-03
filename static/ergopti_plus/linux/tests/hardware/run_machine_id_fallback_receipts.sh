#!/usr/bin/env bash
# Install synthetic system identities only inside an owned private mount
# namespace, then run the production cipher as the original ordinary user.
# sudo unshare --mount --propagation private bash tests/hardware/run_machine_id_fallback_receipts.sh UID GID
set -euo pipefail

task_uid=${1:?Supply the ordinary test user UID}
task_gid=${2:?Supply the ordinary test user GID}
case "$task_uid:$task_gid" in *[!0-9:]*) exit 1;; esac
if [ "$(id -u)" != 0 ] || [ "$task_uid" = 0 ]; then
    echo 'A namespace owner and an ordinary cipher user are required.' >&2
    exit 1
fi
if [ "$(readlink /proc/self/ns/mnt)" = "$(readlink "/proc/$PPID/ns/mnt")" ]; then
    echo 'Refusing to bind synthetic identities outside an isolated mount namespace.' >&2
    exit 1
fi
if [ "$(findmnt -n -o PROPAGATION /)" != private ]; then
    echo 'The owned mount namespace must have private propagation.' >&2
    exit 1
fi
if [ ! -f /etc/machine-id ] || [ ! -d /var/lib/dbus ]; then
    echo 'The fixture requires installed primary and D-Bus mount targets.' >&2
    exit 1
fi
root=$(mktemp -d /tmp/ergopti-machine-id-XXXXXX)
primary_mounted=false
fallback_mounted=false
cleanup() {
    if "$fallback_mounted"; then umount /var/lib/dbus; fi
    if "$primary_mounted"; then umount /etc/machine-id; fi
    rm -f "$root/empty" "$root/dbus/machine-id"
    rmdir "$root/dbus" "$root"
}
trap cleanup EXIT
chmod 755 "$root"
mkdir "$root/dbus"
printf '%s' '' > "$root/empty"
printf '%s\n' '0123456789abcdef0123456789abcdef' > "$root/dbus/machine-id"
chmod 644 "$root/empty" "$root/dbus/machine-id"
mount --bind "$root/empty" /etc/machine-id
primary_mounted=true
mount -o remount,bind,ro /etc/machine-id
mount --bind "$root/dbus" /var/lib/dbus
fallback_mounted=true
mount -o remount,bind,ro /var/lib/dbus
setpriv --reuid "$task_uid" --regid "$task_gid" --clear-groups \
    env LUA_PATH='./?.lua;./?/init.lua;../_shared/lua/?.lua;../_shared/lua/?/init.lua;;' \
    luajit tests/hardware/run_machine_id_fallback_receipts.lua
