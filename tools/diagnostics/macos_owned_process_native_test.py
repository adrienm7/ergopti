# tools/diagnostics/macos_owned_process_native_test.py
"""Qualify the actual Apple SDK ABI and reserved cross-UID sudo/security child.

This receiving gate requires a real Darwin host with Xcode and passwordless
sudo, as used by the native certificate fixture. Unsupported prerequisites
fail the gate; portable ownership models are not substituted for native proof.
"""

import ctypes
import errno
import json
import os
from pathlib import Path
import subprocess
import sys
from tempfile import TemporaryDirectory
import unittest

import macos_owned_process as owner


SDK_SOURCE = r"""#include <libproc.h>
#include <stddef.h>
#include <stdio.h>
#include <sys/proc_info.h>
int main(void) {
    printf("{\"size\":%zu,\"flavor\":%d,\"pid\":%zu,\"ppid\":%zu,"
           "\"pgid\":%zu,\"status\":%zu,\"comm\":%zu,\"flags\":%zu,"
           "\"uid\":%zu,\"gid\":%zu,\"ruid\":%zu,\"rgid\":%zu,"
           "\"svuid\":%zu,\"svgid\":%zu,\"reserved\":%zu}\n",
           sizeof(struct proc_bsdshortinfo), PROC_PIDT_SHORTBSDINFO,
           offsetof(struct proc_bsdshortinfo, pbsi_pid),
           offsetof(struct proc_bsdshortinfo, pbsi_ppid),
           offsetof(struct proc_bsdshortinfo, pbsi_pgid),
           offsetof(struct proc_bsdshortinfo, pbsi_status),
           offsetof(struct proc_bsdshortinfo, pbsi_comm),
           offsetof(struct proc_bsdshortinfo, pbsi_flags),
           offsetof(struct proc_bsdshortinfo, pbsi_uid),
           offsetof(struct proc_bsdshortinfo, pbsi_gid),
           offsetof(struct proc_bsdshortinfo, pbsi_ruid),
           offsetof(struct proc_bsdshortinfo, pbsi_rgid),
           offsetof(struct proc_bsdshortinfo, pbsi_svuid),
           offsetof(struct proc_bsdshortinfo, pbsi_svgid),
           offsetof(struct proc_bsdshortinfo, pbsi_rfu));
    return 0;
}
"""


class NativePrivilegedLeaderReceiving(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if sys.platform != "darwin":
            raise RuntimeError("Actual native receiving requires Darwin; no portable substitute")

    def run_owned(self, arguments, native, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL):
        registered = []
        group = owner.acquire_owned(
            arguments, native, registered.append, stdout=stdout, stderr=stderr
        )
        self.assertEqual(registered, [group])
        try:
            group.wait_for_exit(30)
            self.assertTrue(group.settle(), "Actual command group must retire before reap")
            self.assertTrue(group.reaped)
            self.assertFalse(group.reservation_lost)
            self.assertEqual(group.process.returncode, 0)
        finally:
            if not group.reaped:
                self.assertTrue(
                    group.settle(), "Native failure must retain and retire its acquired group"
                )

    def test_actual_sdk_short_record_offsets_equal_independent_frozen_layout(self):
        native = owner.NativeProcessGroups()
        with TemporaryDirectory(prefix="ergopti-short-bsd-sdk-") as temporary:
            root = Path(temporary)
            source, binary = root / "layout.c", root / "layout"
            source.write_text(SDK_SOURCE, encoding="utf-8", newline="\n")
            with (root / "compiler.stderr").open("wb") as diagnostics:
                self.run_owned(
                    [
                        "/usr/bin/xcrun",
                        "clang",
                        "-std=c11",
                        "-Wall",
                        "-Wextra",
                        "-Werror",
                        str(source),
                        "-o",
                        str(binary),
                    ],
                    native,
                    stderr=diagnostics,
                )
            with (root / "layout.json").open("wb") as output:
                self.run_owned([str(binary)], native, stdout=output)
            actual = json.loads((root / "layout.json").read_text())
        expected = {
            "size": 64,
            "flavor": 13,
            "pid": 0,
            "ppid": 4,
            "pgid": 8,
            "status": 12,
            "comm": 16,
            "flags": 32,
            "uid": 36,
            "gid": 40,
            "ruid": 44,
            "rgid": 48,
            "svuid": 52,
            "svgid": 56,
            "reserved": 60,
        }
        self.assertEqual(actual, expected)
        self.assertEqual(ctypes.sizeof(owner.ProcBSDShortInfo), expected["size"])
        for name, _kind in owner.ProcBSDShortInfo._fields_:
            self.assertEqual(getattr(owner.ProcBSDShortInfo, name).offset, expected[name])

    def test_actual_sudo_security_zombie_positive_identity_and_physical_group_retirement(self):
        self.assertNotEqual(
            os.geteuid(), 0, "Cross-UID refusal must be observed by an ordinary runner"
        )
        native = owner.NativeProcessGroups()
        registered = []
        # No certificate/keychain mutation: this is the genuine privileged
        # security executable used by the network fixture, with bounded output.
        group = owner.acquire_owned(
            ["/usr/bin/sudo", "-n", "/usr/bin/security", "list-keychains", "-d", "system"],
            native,
            registered.append,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        self.assertEqual(registered, [group])
        try:
            group.wait_for_exit(30)
            record = owner.ProcBSDInfo()
            ctypes.set_errno(0)
            received = native.library.proc_pidinfo(
                group.process.pid, 3, 1, ctypes.byref(record), ctypes.sizeof(record)
            )
            self.assertEqual((received, ctypes.get_errno()), (0, errno.EPERM))
            identity, observation = native.privileged_terminal_identity(
                group.process.pid, group.process.pid
            )
            self.assertEqual(identity.uid, 0)
            self.assertEqual(identity.pid, group.process.pid)
            self.assertEqual(identity.ppid, os.getpid())
            self.assertEqual(identity.pgid, group.process.pid)
            self.assertEqual(identity.status, 5)
            self.assertEqual(observation.si_pid, group.process.pid)
            self.assertIsNone(
                group.process.returncode, "Native observations must leave the child unreaped"
            )
            self.assertTrue(group.closed_before_reap())
            self.assertTrue(group.settle())
            self.assertTrue(group.reaped)
            self.assertEqual(group.process.returncode, 0)
            self.assertEqual(group.last_live_members, [])
            self.assertEqual(group.signals, [])
            with self.assertRaises(ChildProcessError):
                os.waitid(os.P_PID, group.process.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
        finally:
            if not group.reaped:
                self.assertTrue(
                    group.settle(), "Privileged failure must retain and retire its exact group"
                )


if __name__ == "__main__":
    unittest.main()
