#!/usr/bin/env bash
# static/ergopti_plus/linux/tests/hardware/layouts/run_phys_vm.sh
#
# Boots a disposable Ubuntu 24.04 cloud VM under QEMU and runs
# phys_live_guest.sh in it as root, then copies its receipts back.
#
# Why a VM: the live daemon scenarios need a real kernel with /dev/uinput and
# evdev, and systemd as PID 1 with a user manager. A container shares its
# host's kernel (a cloud sandbox kernel may have no uinput) and rarely boots
# systemd. KVM is used when /dev/kvm exists; otherwise QEMU emulates the CPU
# (TCG), which is slow (the install takes tens of minutes) but faithful.
#
# Usage: run_phys_vm.sh <receipts_dir>
# Environment:
#   ERGOPTI_PHYS_VM_DIR   work folder for the image and disk (default: mktemp)
#   ERGOPTI_PHYS_IMAGE    cloud image URL (default: Ubuntu 24.04 server)
#   HTTPS_PROXY           a host proxy on 127.0.0.1 is handed to the guest as
#                         10.0.2.2; ERGOPTI_PHYS_EXTRA_CA is a CA bundle the
#                         guest trusts (a TLS-intercepting proxy).
# Needs qemu-system-x86_64, qemu-img, cloud-localds, ssh, curl.
# Exit: the guest script's (0 pass, 1 failure, 2 environment).

set -euo pipefail
RECEIPTS="${1:?usage: run_phys_vm.sh <receipts_dir>}"
IMAGE_URL="${ERGOPTI_PHYS_IMAGE:-https://cloud-images.ubuntu.com/releases/noble/release/ubuntu-24.04-server-cloudimg-amd64.img}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd -P)"
WORK="${ERGOPTI_PHYS_VM_DIR:-$(mktemp -d)}"
SSH_PORT="${ERGOPTI_PHYS_SSH_PORT:-2222}"
need() {
	command -v "$1" >/dev/null 2>&1 || { echo "ENVIRONMENT: $1 is missing" >&2; exit 2; }
}
need qemu-system-x86_64
need qemu-img
need cloud-localds
need ssh
need scp
need ssh-keygen
need curl
need tar
mkdir -p "${WORK}" "${RECEIPTS}"
cd "${WORK}"

[ -f base.img ] || curl -fsSL -o base.img "${IMAGE_URL}"
rm -f id id.pub disk.qcow2 seed.img
ssh-keygen -q -t ed25519 -N '' -f id
cat > user-data <<EOF
#cloud-config
users:
  - name: root
    ssh_authorized_keys: [$(cat id.pub)]
disable_root: false
ssh_pwauth: false
EOF
printf 'instance-id: ergopti-phys\nlocal-hostname: ergopti-phys\n' > meta-data
cloud-localds seed.img user-data meta-data
qemu-img create -q -f qcow2 -b base.img -F qcow2 disk.qcow2 16G

ACCEL=(-cpu max)
[ -w /dev/kvm ] && ACCEL=(-enable-kvm -cpu host)
qemu-system-x86_64 -machine q35 "${ACCEL[@]}" -smp "$(grep -c '^processor' /proc/cpuinfo)" -m 6144 \
	-display none -serial file:console.log -daemonize -pidfile qemu.pid \
	-drive file=disk.qcow2,if=virtio -drive file=seed.img,if=virtio,format=raw \
	-netdev "user,id=n0,hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22" -device virtio-net-pci,netdev=n0
trap 'kill "$(cat qemu.pid)" 2>/dev/null || true' EXIT

SSH_OPTS=(-q -i id -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=30)
guest() { ssh "${SSH_OPTS[@]}" -p "${SSH_PORT}" root@127.0.0.1 "$@"; }
for _ in $(seq 180); do guest true 2>/dev/null && break; sleep 5; done
guest true || { echo "ENVIRONMENT: the VM never answered on ssh" >&2; exit 2; }
guest 'cloud-init status --wait >/dev/null 2>&1 || true'

# A host proxy on loopback is the guest's 10.0.2.2 (QEMU user networking).
GUEST_PROXY=""
if [ -n "${HTTPS_PROXY:-}" ]; then
	GUEST_PROXY="$(printf '%s' "${HTTPS_PROXY}" | sed 's#//127\.0\.0\.1:#//10.0.2.2:#; s#//localhost:#//10.0.2.2:#')"
	guest "printf 'Acquire::http::Proxy \"%s\";\nAcquire::https::Proxy \"%s\";\n' '${GUEST_PROXY}' '${GUEST_PROXY}' > /etc/apt/apt.conf.d/99proxy
		sed -i 's#http://#https://#g' /etc/apt/sources.list.d/ubuntu.sources"
fi
if [ -n "${ERGOPTI_PHYS_EXTRA_CA:-}" ]; then
	scp "${SSH_OPTS[@]}" -P "${SSH_PORT}" "${ERGOPTI_PHYS_EXTRA_CA}" root@127.0.0.1:/usr/local/share/ca-certificates/ergopti-phys.crt
	guest 'update-ca-certificates >/dev/null'
fi
guest 'apt-get update -qq'

# Only what the installer and the scenarios read from a checkout.
tar -C "${REPO_ROOT}" -czf src.tgz static/ergopti_plus/linux static/ergopti_plus/_shared \
	static/layouts/registry package.json tools/build/build-linux-native-output.sh tools/control
scp "${SSH_OPTS[@]}" -P "${SSH_PORT}" src.tgz root@127.0.0.1:/root/src.tgz
guest 'rm -rf /src && mkdir /src && tar -xzf /root/src.tgz -C /src'

set +e
guest "https_proxy='${GUEST_PROXY}' HTTPS_PROXY='${GUEST_PROXY}' ERGOPTI_PHYS_RECEIPTS=/root/phys-receipts \
	bash /src/static/ergopti_plus/linux/tests/hardware/layouts/phys_live_guest.sh"
STATUS=$?
set -e
scp "${SSH_OPTS[@]}" -P "${SSH_PORT}" -r 'root@127.0.0.1:/root/phys-receipts/*' "${RECEIPTS}/" || true
guest 'poweroff' || true
exit "${STATUS}"
