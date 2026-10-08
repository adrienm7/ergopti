# tools/diagnostics/native_abi_observation.py
"""TEST ONLY: validate independently pinned SDK ABI observations.

These immutable transcripts contain type/library/kernel observations only.
They cannot grant a process reservation, root namespace, signing principal,
installation authority or runtime readiness. Privileged admission is separate.
"""

from collections import namedtuple


NativeAbiObservation = namedtuple("NativeAbiObservation", "waitid filesec")

WAITID_ABI = {
    "sizeof.siginfo_t": "104",
    "alignof.siginfo_t": "8",
    "sizeof.id_t": "4",
    "sizeof.pid_t": "4",
    "sizeof.uid_t": "4",
    "sizeof.long": "8",
    "sizeof.pointer": "8",
    "offset.si_signo": "0",
    "offset.si_errno": "4",
    "offset.si_code": "8",
    "offset.si_pid": "12",
    "offset.si_uid": "16",
    "offset.si_status": "20",
    "offset.si_addr": "24",
    "offset.si_value": "32",
    "offset.si_band": "40",
    "offset.__pad": "48",
    "P_ALL": "0",
    "P_PID": "1",
    "P_PGID": "2",
    "WEXITED": "4",
    "WNOHANG": "1",
    "WNOWAIT": "32",
    "CLD_EXITED": "1",
    "CLD_KILLED": "2",
    "CLD_DUMPED": "3",
    "SIGCHLD": "20",
    "SIGTERM": "15",
    "SIGKILL": "9",
    "ACL_TYPE_EXTENDED": "256",
    "ACL_FIRST_ENTRY": "0",
    "waitid.library": "/usr/lib/system/libsystem_kernel.dylib",
    "native.direct_child_wnowait_reap": "PASS",
    "empty_acl.first_entry.result": "-1",
    "empty_acl.first_entry.errno": "22",
    "native.empty_acl_api": "PASS",
}
FILESEC_ABI = {
    "sizeof.stat": "144",
    "alignof.stat": "8",
    "sizeof.timespec": "16",
    "alignof.timespec": "8",
    "offset.st_dev": "0",
    "offset.st_mode": "4",
    "offset.st_nlink": "6",
    "offset.st_ino": "8",
    "offset.st_uid": "16",
    "offset.st_gid": "20",
    "offset.st_rdev": "24",
    "offset.st_atimespec": "32",
    "offset.st_mtimespec": "48",
    "offset.st_ctimespec": "64",
    "offset.st_birthtimespec": "80",
    "offset.st_size": "96",
    "offset.st_blocks": "104",
    "offset.st_blksize": "112",
    "offset.st_flags": "116",
    "offset.st_gen": "120",
    "offset.st_lspare": "124",
    "offset.st_qspare": "128",
    "FILESEC_ACL": "5",
    "ACL_FIRST_ENTRY": "0",
    "fstatx_np.library": "/usr/lib/system/libsystem_c.dylib",
    "native.filesec_probe": "PASS",
}


class NativeAbiRefusal(RuntimeError):
    """Malformed or unsupported observations cannot admit typed native calls."""


def _transcript(data):
    if (
        type(data) is not bytes
        or not 0 < len(data) <= 16384
        or not data.endswith(b"\n")
        or b"\r" in data
    ):
        raise NativeAbiRefusal("bounded native ABI transcript required")
    try:
        lines = data.decode("ascii").splitlines()
    except UnicodeError as error:
        raise NativeAbiRefusal("native ABI transcript must be ASCII") from error
    pairs = []
    keys = set()
    for line in lines:
        if line.count("=") != 1:
            raise NativeAbiRefusal("native ABI transcript line shape")
        name, value = line.split("=")
        if name in keys or not name or not value or "\r" in line:
            raise NativeAbiRefusal("native ABI transcript duplicate/empty field")
        keys.add(name)
        pairs.append((name, value))
    return tuple(pairs)


def parse_sdk_abi_pair(waitid_data, filesec_data):
    """Validate complete native SDK transcripts without creating any authority."""
    waitid, filesec = _transcript(waitid_data), _transcript(filesec_data)
    if dict(waitid) != WAITID_ABI:
        raise NativeAbiRefusal("native waitid SDK/kernel observation refused")
    observed = dict(filesec)
    dynamic = {
        key: observed.pop(key, None)
        for key in ("property.result", "property.errno", "property.nonnull_acl", "native.fd_acl")
    }
    if observed != FILESEC_ABI:
        raise NativeAbiRefusal("native stat/filesec SDK observation refused")
    absent = {
        "property.result": "-1",
        "property.errno": "2",
        "property.nonnull_acl": "0",
        "native.fd_acl": "ABSENT_AFTER_SUCCESSFUL_FSTATX",
    }
    empty = {
        "property.result": "0",
        "property.errno": "0",
        "property.nonnull_acl": "1",
        "native.fd_acl": "VALID_ZERO_ENTRY_ACL",
    }
    if dynamic not in (absent, empty):
        raise NativeAbiRefusal("native filesec successful-stat/ACL receipt refused")
    return NativeAbiObservation(waitid, filesec)


def encode_sdk_abi_observation(observation):
    """Encode bounded ABI data for the fixed bootstrap, never owner capabilities."""
    import base64
    import json

    if type(observation) is not NativeAbiObservation:
        raise NativeAbiRefusal("immutable native ABI observation required")
    # Revalidate even an internal tuple so caller construction cannot skip guards.
    waitid = "".join(key + "=" + value + "\n" for key, value in observation.waitid).encode("ascii")
    filesec = "".join(key + "=" + value + "\n" for key, value in observation.filesec).encode(
        "ascii"
    )
    parse_sdk_abi_pair(waitid, filesec)
    return base64.b64encode(
        json.dumps(
            [waitid.decode("ascii"), filesec.decode("ascii")],
            separators=(",", ":"),
            ensure_ascii=True,
        ).encode("ascii")
    ).decode("ascii")


def decode_sdk_abi_observation(encoded):
    """Revalidate ABI observations before typed calls; no privileged custody grant."""
    import base64
    import json

    if type(encoded) is not str or len(encoded) > 32768:
        raise NativeAbiRefusal("bounded encoded ABI observation required")
    raw = base64.b64decode(encoded, validate=True)
    pair = json.loads(raw)
    if type(pair) is not list or len(pair) != 2 or any(type(item) is not str for item in pair):
        raise NativeAbiRefusal("encoded ABI observation shape refused")
    return parse_sdk_abi_pair(pair[0].encode("ascii"), pair[1].encode("ascii"))
