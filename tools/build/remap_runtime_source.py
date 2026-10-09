"""Prepare a detached fixed owned source projection; no writes or native authority."""

from dataclasses import dataclass
import hashlib
import importlib.util
import os
from pathlib import Path
import stat
import sys
import time

# The final successor freezes all of these concrete reviewed dependencies.
# An incomplete preparation must refuse; it never loads mutable author drafts.
DEPENDENCIES = (
    (
        "tools/build/remap_runtime_auth.hpp",
        "f6b921d8ce74938463b6d28dc50bda457755da1602f62c9e52e8bba760604a75",
    ),
    (
        "tools/build/remap_runtime_auth_policy.hpp",
        "ae249e28e16805ca8502d4f11eccbbab972394f1a776b120442f200593698ff6",
    ),
    (
        "tools/build/remap_runtime_auth_transport.py",
        "1942feef1492cb2e9524964e614561590cb41fd4c664ff2c74fde235238ee6fb",
    ),
    (
        "tools/build/remap_runtime_identity.hpp",
        "6640d31e02d80497af63df1287b03f31415f57c81af7892aec1cd2457675613e",
    ),
    (
        "tools/build/remap_runtime_inventory.hpp",
        "5a033ca40c506b654f62fd3e1a0b9eee7a74396c8fd68f2319aba38173e92515",
    ),
    (
        "tools/build/remap_runtime_parent.hpp",
        "04bd8cc05fa0eeb104a45ace09743d83f7acb2fe61485a31551187d9f82e4d61",
    ),
    (
        "tools/build/remap_runtime_parent_policy.hpp",
        "813a111b62a1b96d05fc084f9977ae4a7e0d532563dc2ccf09111a743f94cd49",
    ),
    (
        "tools/build/remap_runtime_patch.py",
        "c29ceb96e73655cadea7763805b9468c32744033c2f177bae492e4ce9fe4100a",
    ),
    (
        "tools/build/remap_runtime_producer.py",
        "8b132f2e26351104c39c2461b156671df5cda0cb96ab8aa720326765a5a9c413",
    ),
    (
        "tools/diagnostics/hs274-key-element.hpp",
        "ef68fa1f4298e083db35a25fecfddee111ea1ffc2a1ba3da7d9774daf36c50fa",
    ),
    (
        "tools/diagnostics/hs274-key-state.hpp",
        "9133395b8d53ad75f2bb8d3af28b848d95541c5988571273a772168b9efd5196",
    ),
    (
        "tools/diagnostics/hs274-keyboard-type-observation.hpp",
        "b3b33d36bc5d5be0c49c15dd2a0a5ca64408fdcf2977239bde18414f1b898b72",
    ),
    (
        "tools/diagnostics/hs274-observation-control.hpp",
        "d87b01502239b91e295c62ad91b6f762018fe2e67622331d403fcea7445dde9f",
    ),
    (
        "tools/diagnostics/hs274-raw-capture.hpp",
        "b90e7624b41073781484e64424522d44453e3c5dde8b8509243c052da9ff2fe3",
    ),
    (
        "tools/diagnostics/hs274-stream-ack.hpp",
        "d663ed8fe8f0ee287677de0df56d848974b0c82d6e8d7db08107b68c5d61b657",
    ),
    (
        "tools/diagnostics/hs274-stream-baseline-client.hpp",
        "f9a113d1e51198af55be58e27d771e8709130ae7f59491e4f83c79a11e0b851f",
    ),
    (
        "tools/diagnostics/hs274-stream-baseline-pages.hpp",
        "5da218872769de7b1a340e091c4c2997cd06f085d499e43cf6f1469f5a8c6e60",
    ),
    (
        "tools/diagnostics/hs274-stream-baseline-probe.hpp",
        "971afe7cec94acbf7aec951a6cbe0cc12feb0cdced4b4843553702c222d38e4f",
    ),
    (
        "tools/diagnostics/hs274-stream-cli.hpp",
        "674aae5284c7d4d1c6ea65dae898741a63922d595caeb5cc8559ce47eee47c67",
    ),
    (
        "tools/diagnostics/hs274-stream-clock.hpp",
        "87932db6521a4ff1d021ea54cb8272bed821e594bd46cdfc13f8e73cd24ac612",
    ),
    (
        "tools/diagnostics/hs274-stream-input.hpp",
        "6c5ce472ba51dda797474a9516a8066bcca75a3f1dd4ed71dbeba26b3a0025d0",
    ),
    (
        "tools/diagnostics/hs274-stream-inventory.hpp",
        "367e61a0ddf3099af06e86dd426446d7812d397b565eb4a6da9d7e06592e1e18",
    ),
    (
        "tools/diagnostics/hs274-stream-key-policy.hpp",
        "2e759f31407f32f9faa25ce4223ce6c14a7b146744fe314cfb8c3c66627d3192",
    ),
    (
        "tools/diagnostics/hs274-stream-native-binding.hpp",
        "a429505ab76e6b712a5b562d116f5118fae8e6f1d41e9c96f2cf40d258b95a56",
    ),
    (
        "tools/diagnostics/hs274-stream-native-boundary.hpp",
        "a3f4e3188c454aeb316669c0bf665b16869e93a15cb970a278847ce28e1f5d21",
    ),
    (
        "tools/diagnostics/hs274-stream-native-control.hpp",
        "4c01f9abe35570908bdcd5c1ce3e9a3ed4eed663ad2bcfdc9fb77ee2f637af29",
    ),
    (
        "tools/diagnostics/hs274-stream-native-fault.hpp",
        "00854bd67fa166570b32752e75e5fe4b1d2099bb9a7f6ee98c70f7f2da313e9e",
    ),
    (
        "tools/diagnostics/hs274-stream-protocol.hpp",
        "f9b501bc7604e7c698a96a8e8c58acd10f65ebb1552c7aef9bfee1142bf01f12",
    ),
    (
        "tools/diagnostics/hs274-stream-readiness.hpp",
        "6c6cac21b54538e421c6a25dfbe9f31c3a552432eed6a98a28ab02f1727604d8",
    ),
    (
        "tools/diagnostics/hs274-stream-runtime.hpp",
        "c80d280df04dacd1143556ced7d0b2ab1498a3c61df3aaf90736b6c523e78c2b",
    ),
    (
        "tools/diagnostics/hs274-stream-session.hpp",
        "3bda2fb54ee5a6833c7672a36f41e1822a29e7d77ccbad39c99f8c95abddeefd",
    ),
    (
        "tools/diagnostics/hs274-stream-source.hpp",
        "67b144f1604fe53649162210805d19641663974f74e643812a74e0fc51fb71a1",
    ),
    (
        "tools/diagnostics/hs274_raw_patch.py",
        "52202e991ad12e0aae5806ecb093c4018318517c8f07d774ef3d4e730f218423",
    ),
    (
        "tools/diagnostics/hs274_stream_patch.py",
        "7df485fc0cbcb6bb16b3e8d3d67ebacebc0da9b0840abe7b308bb45fb809011b",
    ),
)
STREAM_HEADERS = (
    "hs274-stream-baseline-client.hpp",
    "hs274-keyboard-type-observation.hpp",
    "hs274-observation-control.hpp",
    "hs274-stream-cli.hpp",
    "hs274-key-state.hpp",
    "hs274-stream-readiness.hpp",
    "hs274-stream-baseline-probe.hpp",
    "hs274-stream-ack.hpp",
    "hs274-stream-source.hpp",
    "hs274-stream-baseline-pages.hpp",
    "hs274-stream-native-boundary.hpp",
    "hs274-stream-session.hpp",
    "hs274-stream-native-binding.hpp",
    "hs274-stream-clock.hpp",
    "hs274-stream-protocol.hpp",
    "hs274-stream-runtime.hpp",
    "hs274-stream-inventory.hpp",
    "hs274-raw-capture.hpp",
    "hs274-stream-key-policy.hpp",
    "hs274-key-element.hpp",
    "hs274-stream-input.hpp",
    "hs274-stream-native-control.hpp",
    "hs274-stream-native-fault.hpp",
)
STREAM_INPUTS = (
    (
        "src/share/hid_device_events_monitor.hpp",
        "3ae0e95865894b55016dd58ef8a61e5fc40875c2a39bc3a6e0bf8ea1d5460873",
    ),
    (
        "src/apps/CoreService/include/core_service/main/daemon.hpp",
        "192288ef32b69095f128cbc3f42c6d508b4639c0ef90eec960e650c42a32bd70",
    ),
    (
        "vendor/vendor/include/asio/detail/impl/socket_ops.ipp",
        "50ad71f4af2924c2bf0e951e63a8dacb795307d9bb38e0154c69069eae6a578e",
    ),
    (
        "vendor/vendor/include/pqrs/unix_domain_stream/server.hpp",
        "048b635d6e3563ebf643ec77acd1eadd90b0005b824b24e74768a71b19e6f568",
    ),
    (
        "src/share/types/operation_type.hpp",
        "5fa6f28a5abee73f97f7dffad9f459543c6d93ad8ead70f2bdea0462569e766b",
    ),
    (
        "src/apps/CoreService/include/core_service/daemon/receiver.hpp",
        "575c7122a9a2448b81637bbfb50925cd3ff07f0613fcc09abbf1143d19de766d",
    ),
    (
        "src/apps/CoreService/include/core_service/daemon/device_grabber_details/entry.hpp",
        "ebbdaecb186f668a1da143791cb2c86a405bb244ebb014205d73a8b9a691f512",
    ),
    (
        "src/share/core_service_daemon_client.hpp",
        "a56443dd59876bfc05be9b221db1313abd0682d64acd4b1d523910f3da551f33",
    ),
    (
        "src/bin/cli/src/main.cpp",
        "b4e2ed11067107c6097ea2ca37bbdd50ec146954eef95dc8340cd5a082be8a53",
    ),
)
OWNED_INVENTORY_INPUTS = (
    (
        "vendor/vendor/include/pqrs/osx/iokit_service_monitor.hpp",
        "be44570d9a122d48dfe76ff784188989a7c6c6aae708638ab21237594fbcaa44",
    ),
    (
        "vendor/vendor/include/pqrs/osx/iokit_hid_manager.hpp",
        "18249036caf2ccf25e21023fa929a49687f45d333a671c2aa337c12d44aabc6b",
    ),
    (
        "vendor/vendor/include/pqrs/osx/iokit_hid_device_events_monitor.hpp",
        "f0071627fb9a38747ae5a9ac911dc3251cb7c39f095719920b26622f0f193ff7",
    ),
)

AUTH_VENDOR_ORIGINAL_PREIMAGES = (
    (
        "vendor/vendor/include/pqrs/unix_domain_stream/impl/peer.hpp",
        "bfe02a077e4804c99b8fabb5364da1cce9faadb1613b571ff8a81375f40f475a",
    ),
    (
        "vendor/vendor/include/pqrs/unix_domain_stream/client.hpp",
        "d6120091e024aa29228fb83378ba94cbbf2778218d8d429a9311ea4150080a4d",
    ),
    (
        "vendor/vendor/include/pqrs/unix_domain_stream/server.hpp",
        "048b635d6e3563ebf643ec77acd1eadd90b0005b824b24e74768a71b19e6f568",
    ),
    (
        "vendor/vendor/include/pqrs/unix_domain_stream/impl/request_manager.hpp",
        "84d5c5606e5eb87e0da0d9e427ddc4720bb79b53e5f5bd8b35b04409770eb4ba",
    ),
    (
        "vendor/vendor/include/pqrs/unix_domain_stream/types.hpp",
        "061ec3512ec605f4d7d2ecf5113d1e47ba6ef3109754f3a2276842b5be679242",
    ),
    (
        "src/apps/CoreService/include/core_service/daemon/receiver.hpp",
        "575c7122a9a2448b81637bbfb50925cd3ff07f0613fcc09abbf1143d19de766d",
    ),
    (
        "src/apps/CoreService/include/core_service/daemon/console_user_id_changed_receiver.hpp",
        "9bdd743310a881c948fc0f57e1d1b55e68654b55f64f7a2e085586520529a75e",
    ),
    (
        "src/apps/ConsoleUserServer/include/console_user_server/receiver.hpp",
        "07f57a8a1073551344cb555bf342e1b51fc861d6cce7e9f26b87eba01597f28a",
    ),
    (
        "src/apps/ConsoleUserServer/include/console_user_server/console_user_id_changed_client.hpp",
        "e58eac3f9f8a39c6e56ef22c8ac5f83c066bdfb96e6325d2ba71586b90ee4b74",
    ),
    (
        "src/share/core_service_daemon_client.hpp",
        "a56443dd59876bfc05be9b221db1313abd0682d64acd4b1d523910f3da551f33",
    ),
    (
        "src/share/console_user_server_client.hpp",
        "13ce02c4f966bf647b62b020834326a903064b25469d52a8e9a9ef79472cefc6",
    ),
)


class SourceRefusal(RuntimeError):
    def __init__(self, code, message):
        self.code = code
        super().__init__(message)


def require(condition, code, message):
    if not condition:
        raise SourceRefusal(code, message)


def deadline(value):
    require(
        type(value) in (int, float) and 0 < value < 10**20 and time.monotonic() < value,
        "deadline",
        "The original absolute source deadline expired",
    )


def identity(info):
    return (
        info.st_dev,
        info.st_ino,
        info.st_uid,
        info.st_mode,
        info.st_nlink,
        info.st_size,
        info.st_mtime_ns,
        info.st_ctime_ns,
    )


def root_identity(root):
    try:
        require(
            isinstance(root, Path) and root.is_absolute() and root.resolve(strict=True) == root,
            "unsafe_path",
            "Source root redirects or is relative",
        )
        info = root.lstat()
        require(
            stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid(),
            "unsafe_path",
            "Source root is not an owned directory",
        )
    except OSError as error:
        raise SourceRefusal("unsafe_path", "Actual source root is unavailable") from error
    return (info.st_dev, info.st_ino, info.st_uid, info.st_mode)


@dataclass(frozen=True, slots=True)
class SealedInput:
    path: str
    identity: tuple
    data: bytes


@dataclass(frozen=True, slots=True)
class PreparedSource:
    repository: Path
    repository_identity: tuple
    upstream: Path
    upstream_identity: tuple
    pins: tuple
    inventory: tuple
    source_inputs: tuple[SealedInput, ...]
    dependencies: tuple[SealedInput, ...]
    replacements: tuple[tuple[str, bytes], ...]


def read_input(root, relative, limit, absolute_deadline):
    deadline(absolute_deadline)
    require(
        type(relative) is str
        and relative
        and str(Path(relative)) == relative
        and not Path(relative).is_absolute()
        and ".." not in Path(relative).parts,
        "unsafe_path",
        "Relative source path expands or aliases its owner",
    )
    path = root / relative
    try:
        before = path.lstat()
        require(
            path.resolve(strict=True) == path and path.parent.resolve(strict=True) == path.parent,
            "unsafe_path",
            "Source input redirects",
        )
        require(
            stat.S_ISREG(before.st_mode) and before.st_nlink == 1 and before.st_uid == os.getuid(),
            "unsafe_path",
            "Source input is not an ordinary singly linked owned file",
        )
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, "rb") as stream:
            opened = os.fstat(stream.fileno())
            require(
                identity(opened) == identity(before) and opened.st_size <= limit,
                "source_changed",
                "Retained source descriptor differs or exceeds its bound",
            )
            data = stream.read(limit + 1)
            final = os.fstat(stream.fileno())
            after = path.lstat()
            require(
                len(data) == opened.st_size
                and identity(opened) == identity(final) == identity(after)
                and path.resolve(strict=True) == path,
                "source_changed",
                "Source descriptor or selected path changed during read",
            )
    except OSError as error:
        raise SourceRefusal("unsafe_path", "Actual source input is unavailable") from error
    deadline(absolute_deadline)
    return SealedInput(relative, identity(opened), data)


def load_fixed(name, input_file):
    # Execute exactly the retained verified bytes, not a second path read.
    spec = importlib.util.spec_from_loader(name, loader=None)
    module = importlib.util.module_from_spec(spec)
    module.__file__ = input_file.path
    sys.modules[name] = module
    exec(compile(input_file.data, input_file.path, "exec"), module.__dict__)
    return module


def capture_dependencies(repository, absolute_deadline):
    require(
        type(DEPENDENCIES) is tuple
        and len(DEPENDENCIES) == 34
        and tuple(path for path, _ in DEPENDENCIES)
        == tuple(
            sorted(
                (
                    "tools/build/remap_runtime_patch.py",
                    "tools/build/remap_runtime_producer.py",
                    "tools/build/remap_runtime_auth_transport.py",
                    "tools/diagnostics/hs274_raw_patch.py",
                    "tools/diagnostics/hs274_stream_patch.py",
                    "tools/build/remap_runtime_parent.hpp",
                    "tools/build/remap_runtime_identity.hpp",
                    "tools/build/remap_runtime_inventory.hpp",
                    "tools/build/remap_runtime_parent_policy.hpp",
                    "tools/build/remap_runtime_auth.hpp",
                    "tools/build/remap_runtime_auth_policy.hpp",
                )
                + tuple("tools/diagnostics/" + name for name in STREAM_HEADERS)
            )
        ),
        "dependency_unreleased",
        "Actual reviewed parent/auth composition is incomplete",
    )
    rows = []
    for relative, expected in DEPENDENCIES:
        row = read_input(repository, relative, 8 * 1024 * 1024, absolute_deadline)
        require(
            hashlib.sha256(row.data).hexdigest() == expected,
            "dependency_changed",
            "Actual fixed executable source dependency changed",
        )
        rows.append(row)
    return tuple(rows)


def _assemble_outputs(originals, dependencies, absolute_deadline):
    """Recompute fixed pure source bytes; caller replacement metadata is never authority."""
    require(
        tuple((row.path, hashlib.sha256(row.data).hexdigest()) for row in dependencies)
        == DEPENDENCIES,
        "dependency_changed",
        "Retained dependency inventory differs from the closed factory",
    )
    by_path = {row.path: row for row in dependencies}
    provider = load_fixed(
        "fixed_owned_source_provider", by_path["tools/build/remap_runtime_patch.py"]
    )
    raw = load_fixed("hs274_raw_patch", by_path["tools/diagnostics/hs274_raw_patch.py"])
    producer = load_fixed("fixed_owned_producer", by_path["tools/build/remap_runtime_producer.py"])
    stream = load_fixed(
        "fixed_owned_source_stream", by_path["tools/diagnostics/hs274_stream_patch.py"]
    )
    transport = load_fixed(
        "fixed_owned_source_transport",
        by_path["tools/build/remap_runtime_auth_transport.py"],
    )
    wanted = dict(provider.PARENT_PREIMAGES)
    wanted[provider.PARENT_LIFECYCLE_PREIMAGE[0]] = provider.PARENT_LIFECYCLE_PREIMAGE[1]
    for path, expected in AUTH_VENDOR_ORIGINAL_PREIMAGES:
        require(
            path not in wanted or wanted[path] == expected,
            "preimage",
            "Source scopes disagree on genuine bytes",
        )
        wanted[path] = expected
    for path, expected in (*STREAM_INPUTS, *OWNED_INVENTORY_INPUTS):
        require(
            path not in wanted or wanted[path] == expected,
            "preimage",
            "Stream original overlaps disagree",
        )
        wanted[path] = expected
    require(set(originals) == set(wanted), "inventory", "Original source inventory differs")
    for path, expected in wanted.items():
        require(
            type(originals[path]) is bytes
            and hashlib.sha256(originals[path]).hexdigest() == expected,
            "preimage",
            "Retained actual upstream byte preimage differs",
        )
    parent_inputs = {
        path: originals[path]
        for path, _ in (*provider.PARENT_PREIMAGES, provider.PARENT_LIFECYCLE_PREIMAGE)
    }
    headers = {
        path: by_path["tools/build/" + Path(path).name].data
        for path, _ in provider.PARENT_HEADER_PREIMAGES
    }
    prepared = provider.assemble_parent_lifecycle_namespace(
        parent_inputs, headers, absolute_deadline
    )
    prepared["src/apps/ConsoleUserServer/src/runtime.cpp"] = provider.assemble_auth_runtime_binding(
        prepared["src/apps/ConsoleUserServer/src/runtime.cpp"], absolute_deadline
    )
    prepared.update(
        provider.assemble_authenticated_framework_retirement(
            {path: prepared[path] for path, _ in provider.AUTH_FRAMEWORK_PREIMAGES},
            absolute_deadline,
        )
    )
    prepared.update(
        provider.assemble_current_framework_retirement(
            {path: prepared[path] for path, _ in provider.AUTH_CLEANUP_TRANSPORT_PREIMAGES},
            absolute_deadline,
        )
    )
    vendor_inputs = {
        path: prepared.get(path, originals[path]) for path, _ in AUTH_VENDOR_ORIGINAL_PREIMAGES
    }
    prepared.update(
        transport.assemble_owned_auth_transport(
            vendor_inputs,
            by_path["tools/build/remap_runtime_auth.hpp"].data,
            absolute_deadline,
        )
    )
    prepared.update(
        provider.assemble_auth_link_dependencies(
            {path: prepared[path] for path, _ in provider.AUTH_RECIPE_PREIMAGES},
            absolute_deadline,
        )
    )
    prepared["src/share/remap_runtime_auth.hpp"] = by_path[
        "tools/build/remap_runtime_auth.hpp"
    ].data
    prepared["src/share/remap_runtime_auth_policy.hpp"] = by_path[
        "tools/build/remap_runtime_auth_policy.hpp"
    ].data
    functions = (
        lambda source: producer.owned_stream_monitor(stream.stream_monitor(source)),
        producer.owned_stream_shutdown,
        stream.stream_socket_ops,
        stream.stream_server,
        stream.stream_operations,
        stream.stream_receiver,
        stream.stream_entry,
        stream.stream_client,
        stream.stream_cli,
    )
    for (path, _), transform in zip(STREAM_INPUTS, functions, strict=True):
        deadline(absolute_deadline)
        prepared[path] = transform(prepared.get(path, originals[path]).decode("utf-8")).encode(
            "utf-8"
        )
    for (path, _), transform in zip(
        OWNED_INVENTORY_INPUTS,
        (
            producer.owned_inventory_service_monitor,
            producer.owned_inventory_hid_manager,
            producer.owned_input_values_queue_acquisition,
        ),
        strict=True,
    ):
        deadline(absolute_deadline)
        prepared[path] = transform(originals[path].decode("utf-8")).encode("utf-8")
    prepared["src/share/ergopti-owned-native-inventory.hpp"] = by_path[
        "tools/build/remap_runtime_inventory.hpp"
    ].data
    for name in STREAM_HEADERS:
        path = "src/share/" + name
        source = by_path["tools/diagnostics/" + name].data
        owned_projection = {
            "hs274-stream-runtime.hpp": producer.owned_stream_runtime,
            "hs274-stream-source.hpp": producer.owned_inventory_source,
            "hs274-stream-baseline-probe.hpp": producer.owned_stream_baseline_probe,
            "hs274-raw-capture.hpp": producer.owned_stream_record,
        }.get(name)
        prepared[path] = (
            owned_projection(source.decode("utf-8")).encode("utf-8")
            if owned_projection is not None
            else source
        )
    expected_outputs = (
        set(wanted)
        | set(headers)
        | {
            "src/share/remap_runtime_auth.hpp",
            "src/share/remap_runtime_auth_policy.hpp",
        }
        | {"src/share/" + name for name in STREAM_HEADERS}
        | {"src/share/ergopti-owned-native-inventory.hpp"}
    )
    require(
        set(prepared) == expected_outputs
        and len(prepared) == 61
        and all(type(data) is bytes for data in prepared.values()),
        "inventory",
        "Complete actual owned output inventory differs from the fixed 61 leaves",
    )
    deadline(absolute_deadline)
    return tuple(sorted(prepared.items()))


# The retained official-broker prerequisite is a following, separately closed
# projection. The original 32-input/57-output auth renderer remains intact.
VHD_DEPENDENCIES = (
    (
        "tools/build/remap_runtime_vhd.hpp",
        "ca6d4cf40c726ab7c844fdae2bb7ff5dcee476cc2c061944ee76eab385aa1b65",
    ),
    (
        "tools/build/remap_runtime_vhd_transport.py",
        "ffad87a2bad7f75a6b0b6d43b8cd1790d0f413f277d53709fbe8fcd7696e7e97",
    ),
)
VHD_ORIGINAL_INPUTS = (
    (
        "src/apps/CoreService/include/core_service/daemon/device_grabber.hpp",
        "9aa96f3ce8e2cc8c07a08f4c0d4630d6a70f82d7959030289b7b0e21c6e7a43a",
    ),
    (
        "vendor/Karabiner-DriverKit-VirtualHIDDevice/include/pqrs/karabiner/driverkit/virtual_hid_device_service/client.hpp",
        "0e590ff9f652a92dd40fb9c47dd0d61e98f4eb14f0983918a29b223f9c27a8c7",
    ),
)
VHD_NATIVE_HEADER = "src/share/remap_runtime_vhd.hpp"


def capture_vhd_dependencies(repository, absolute_deadline):
    require(
        type(VHD_DEPENDENCIES) is tuple
        and tuple(path for path, _ in VHD_DEPENDENCIES)
        == (
            "tools/build/remap_runtime_vhd.hpp",
            "tools/build/remap_runtime_vhd_transport.py",
        ),
        "dependency_unreleased",
        "Official broker dependency scope differs",
    )
    rows = []
    for relative, expected in VHD_DEPENDENCIES:
        row = read_input(repository, relative, 8 * 1024 * 1024, absolute_deadline)
        require(
            hashlib.sha256(row.data).hexdigest() == expected,
            "dependency_changed",
            "Actual official broker source dependency changed",
        )
        rows.append(row)
    return tuple(rows)


def _assemble_vhd_outputs(originals, dependencies, absolute_deadline):
    require(
        type(originals) is dict
        and type(dependencies) is tuple
        and tuple((row.path, hashlib.sha256(row.data).hexdigest()) for row in dependencies)
        == DEPENDENCIES + VHD_DEPENDENCIES,
        "dependency_changed",
        "Complete official broker source inventory differs",
    )
    base_originals = dict(originals)
    for path, expected in VHD_ORIGINAL_INPUTS:
        require(
            path in base_originals
            and type(base_originals[path]) is bytes
            and hashlib.sha256(base_originals[path]).hexdigest() == expected,
            "preimage",
            "Actual official broker caller preimage differs",
        )
        del base_originals[path]
    base = dict(_assemble_outputs(base_originals, dependencies[:34], absolute_deadline))
    require(len(base) == 61, "inventory", "Original auth projection scope differs")
    by_path = {row.path: row for row in dependencies}
    transport = load_fixed(
        "fixed_official_vhd_source_transport",
        by_path["tools/build/remap_runtime_vhd_transport.py"],
    )
    require(
        tuple(path for path, _ in transport.PREIMAGES)
        == (
            "vendor/vendor/include/pqrs/unix_domain_stream/client.hpp",
            "vendor/vendor/include/pqrs/unix_domain_stream/impl/peer.hpp",
            "vendor/vendor/include/pqrs/unix_domain_stream/impl/request_manager.hpp",
            *tuple(path for path, _ in VHD_ORIGINAL_INPUTS),
        ),
        "inventory",
        "Official broker following projection scope differs",
    )
    selected = {
        path: base[path] if path in base else originals[path] for path, _ in transport.PREIMAGES
    }
    changed = transport.assemble_vhd_transport(
        selected, by_path["tools/build/remap_runtime_vhd.hpp"].data, absolute_deadline
    )
    require(
        set(changed) == set(selected),
        "inventory",
        "Official broker output scope differs",
    )
    old_unchanged = {path: data for path, data in base.items() if path not in changed}
    require(len(old_unchanged) == 58, "inventory", "Original auth conserved scope differs")
    base.update(changed)
    grabber = "src/apps/CoreService/include/core_service/daemon/device_grabber.hpp"
    producer = load_fixed(
        "fixed_owned_inventory_producer",
        by_path["tools/build/remap_runtime_producer.py"],
    )
    base[grabber] = producer.owned_inventory_grabber(base[grabber].decode("utf-8")).encode("utf-8")
    require(
        VHD_NATIVE_HEADER not in base,
        "inventory",
        "Official broker header already owned",
    )
    base[VHD_NATIVE_HEADER] = by_path["tools/build/remap_runtime_vhd.hpp"].data
    require(
        len(base) == 64 and all(base[path] == data for path, data in old_unchanged.items()),
        "inventory",
        "Complete following projection or conserved auth bytes differ",
    )
    return tuple(sorted(base.items()))


def prepare_owned_source(repository, upstream, absolute_deadline):
    """Return immutable exact changes only after all real pins/preimages revalidate."""
    deadline(absolute_deadline)
    repository, upstream = Path(repository), Path(upstream)
    repo_id, source_id = root_identity(repository), root_identity(upstream)
    dependencies = capture_dependencies(repository, absolute_deadline) + capture_vhd_dependencies(
        repository, absolute_deadline
    )
    by_path = {row.path: row for row in dependencies}
    provider = load_fixed(
        "fixed_owned_source_provider", by_path["tools/build/remap_runtime_patch.py"]
    )
    inventory = tuple(
        (row.path, row.mode, row.git_oid, row.sha256)
        for row in provider._inventory(upstream, Path(), provider.UPSTREAM, absolute_deadline)
    )
    wanted = dict(provider.PARENT_PREIMAGES)
    wanted[provider.PARENT_LIFECYCLE_PREIMAGE[0]] = provider.PARENT_LIFECYCLE_PREIMAGE[1]
    for path, expected in AUTH_VENDOR_ORIGINAL_PREIMAGES:
        require(
            path not in wanted or wanted[path] == expected,
            "preimage",
            "Source scopes disagree on genuine bytes",
        )
        wanted[path] = expected
    for path, expected in (*STREAM_INPUTS, *OWNED_INVENTORY_INPUTS):
        require(
            path not in wanted or wanted[path] == expected,
            "preimage",
            "Stream original overlaps disagree",
        )
        wanted[path] = expected
    for path, expected in VHD_ORIGINAL_INPUTS:
        require(path not in wanted, "inventory", "Official broker original scope overlaps")
        wanted[path] = expected
    original_rows = []
    for path, expected in wanted.items():
        row = read_input(upstream, path, provider.MAX_SOURCE_BYTES, absolute_deadline)
        require(
            hashlib.sha256(row.data).hexdigest() == expected,
            "preimage",
            "Genuine upstream preimage drifted",
        )
        original_rows.append(row)
    originals = {row.path: row.data for row in original_rows}
    replacements = _assemble_vhd_outputs(originals, dependencies, absolute_deadline)
    for path, _ in replacements:
        if path not in wanted:
            require(
                not (upstream / path).exists() and not (upstream / path).is_symlink(),
                "inventory",
                "Generated source header already exists",
            )
    projection = PreparedSource(
        repository,
        repo_id,
        upstream,
        source_id,
        (("upstream", provider.UPSTREAM), ("cpm", provider.CPM), ("vhd", provider.VHD)),
        inventory,
        tuple(original_rows),
        dependencies,
        replacements,
    )
    revalidate_owned_source(projection, absolute_deadline)
    return projection


def revalidate_owned_source(projection, absolute_deadline):
    """Recheck exact descriptor incarnations and full Git inventory before staging."""
    require(
        type(projection) is PreparedSource,
        "source_changed",
        "Projection is not the actual immutable source type",
    )
    deadline(absolute_deadline)
    require(
        root_identity(projection.repository) == projection.repository_identity
        and root_identity(projection.upstream) == projection.upstream_identity,
        "source_changed",
        "Actual source/dependency owner changed",
    )
    for root, rows in (
        (projection.repository, projection.dependencies),
        (projection.upstream, projection.source_inputs),
    ):
        for old in rows:
            require(
                read_input(root, old.path, 8 * 1024 * 1024, absolute_deadline) == old,
                "source_changed",
                "Retained source input changed before publication",
            )
    require(
        capture_dependencies(projection.repository, absolute_deadline)
        + capture_vhd_dependencies(projection.repository, absolute_deadline)
        == projection.dependencies,
        "dependency_changed",
        "Retained executable dependencies differ from the closed factory",
    )
    provider_row = next(
        row for row in projection.dependencies if row.path == "tools/build/remap_runtime_patch.py"
    )
    provider = load_fixed("fixed_owned_source_revalidation_provider", provider_row)
    require(
        tuple(
            (row.path, row.mode, row.git_oid, row.sha256)
            for row in provider._inventory(
                projection.upstream, Path(), provider.UPSTREAM, absolute_deadline
            )
        )
        == projection.inventory,
        "inventory",
        "Complete pinned source changed before publication",
    )
    require(
        projection.pins
        == (
            ("upstream", provider.UPSTREAM),
            ("cpm", provider.CPM),
            ("vhd", provider.VHD),
        ),
        "pin",
        "Retained source projection pins differ",
    )
    require(
        _assemble_vhd_outputs(
            {row.path: row.data for row in projection.source_inputs},
            projection.dependencies,
            absolute_deadline,
        )
        == projection.replacements,
        "source_changed",
        "Caller replacement bytes differ from the actual fixed source generator",
    )
    deadline(absolute_deadline)


@dataclass(frozen=True, slots=True)
class SealedLink:
    path: str
    identity: tuple
    data: bytes


@dataclass(frozen=True, slots=True)
class StagedSource:
    """Retain the actual full staged tree; no native/signing/activation authority."""

    projection: PreparedSource
    root: Path
    root_identity: tuple
    files: tuple[SealedInput, ...]
    links: tuple[SealedLink, ...]


def _staged_expectations(projection):
    rows = {
        path: (mode, digest) for path, mode, _, digest in projection.inventory if mode != "160000"
    }
    for path, data in projection.replacements:
        if path == VHD_NATIVE_HEADER:
            continue
        rows[path] = (
            rows.get(path, ("100644", ""))[0],
            hashlib.sha256(data).hexdigest(),
        )
    require(len(rows) == 4531, "inventory", "Actual full staged source inventory differs")
    header = next(
        (row for row in projection.dependencies if row.path == "tools/build/remap_runtime_vhd.hpp"),
        None,
    )
    require(
        header is not None
        and dict(projection.replacements).get(VHD_NATIVE_HEADER) == header.data
        and VHD_NATIVE_HEADER not in rows,
        "inventory",
        "Actual official broker header ownership differs",
    )
    rows[VHD_NATIVE_HEADER] = ("100644", hashlib.sha256(header.data).hexdigest())
    require(
        len(rows) == 4532,
        "inventory",
        "Actual official broker full staged source inventory differs",
    )
    return rows


def _staged_link(root, relative, absolute_deadline):
    deadline(absolute_deadline)
    path = root / relative
    try:
        require(
            path.parent.resolve(strict=True) == path.parent,
            "unsafe_path",
            "Source link ancestor redirects",
        )
        before = path.lstat()
        require(
            stat.S_ISLNK(before.st_mode) and before.st_uid == os.getuid() and before.st_nlink == 1,
            "unsafe_path",
            "Actual source link is not singly linked and owned",
        )
        data = os.fsencode(os.readlink(path))
        after = path.lstat()
        require(
            identity(before) == identity(after)
            and len(data) <= 4096
            and os.fsencode(os.readlink(path)) == data,
            "source_changed",
            "Actual staged link changed during observation",
        )
    except OSError as error:
        raise SourceRefusal("unsafe_path", "Actual staged source link is unavailable") from error
    deadline(absolute_deadline)
    return SealedLink(relative, identity(before), data)


def _staged_inventory(root, absolute_deadline, output_directories=()):
    leaves = set()
    pending = [root]
    while pending:
        deadline(absolute_deadline)
        directory = pending.pop()
        try:
            require(
                directory.resolve(strict=True) == directory,
                "unsafe_path",
                "Staged directory redirects",
            )
            with os.scandir(directory) as entries:
                for entry in entries:
                    deadline(absolute_deadline)
                    info = entry.stat(follow_symlinks=False)
                    require(
                        info.st_uid == os.getuid(),
                        "unsafe_path",
                        "Staged source belongs to another owner",
                    )
                    path = Path(entry.path)
                    if stat.S_ISDIR(info.st_mode):
                        if str(path.relative_to(root)) not in output_directories:
                            pending.append(path)
                    else:
                        leaves.add(str(path.relative_to(root)))
        except OSError as error:
            raise SourceRefusal("unsafe_path", "Actual staged tree is unavailable") from error
    return leaves


def validate_staged_source(projection, staging_root, absolute_deadline):
    """Validate actual complete pinned materialization before version generation."""
    revalidate_owned_source(projection, absolute_deadline)
    root = Path(staging_root)
    root_id = root_identity(root)
    require(
        root != projection.upstream and not root.is_relative_to(projection.upstream),
        "unsafe_path",
        "Staging must preserve the separate pristine upstream",
    )
    expected = _staged_expectations(projection)
    require(
        _staged_inventory(root, absolute_deadline) == set(expected),
        "inventory",
        "Staged tree contains missing or extra leaves",
    )
    files, links = [], []
    for path, (mode, wanted) in sorted(expected.items()):
        if mode == "120000":
            row = _staged_link(root, path, absolute_deadline)
            links.append(row)
        else:
            require(mode in ("100644", "100755"), "inventory", "Unknown staged source mode")
            row = read_input(root, path, 8 * 1024 * 1024, absolute_deadline)
            require(
                bool(row.identity[3] & 0o111) == (mode == "100755"),
                "source_changed",
                "Actual executable source mode differs",
            )
            files.append(row)
        require(
            hashlib.sha256(row.data).hexdigest() == wanted,
            "source_changed",
            "Actual full staged source bytes differ",
        )
    image = StagedSource(projection, root, root_id, tuple(files), tuple(links))
    current_staged_source(image, absolute_deadline)
    return image


def current_staged_source(image, absolute_deadline):
    """Recheck every retained staged physical leaf; generated output needs its owner."""
    require(
        type(image) is StagedSource,
        "source_changed",
        "Actual staged image type differs",
    )
    revalidate_owned_source(image.projection, absolute_deadline)
    require(
        root_identity(image.root) == image.root_identity,
        "source_changed",
        "Actual staged source root changed",
    )
    expected = _staged_expectations(image.projection)
    require(
        len(image.files) == 4527
        and len(image.links) == 4
        and {row.path for row in image.files}
        == {path for path, (mode, _) in expected.items() if mode != "120000"}
        and {row.path for row in image.links}
        == {path for path, (mode, _) in expected.items() if mode == "120000"},
        "inventory",
        "Caller staged image inventory differs from genuine source",
    )
    for old in image.files:
        wanted = expected[old.path]
        require(
            hashlib.sha256(old.data).hexdigest() == wanted[1]
            and bool(old.identity[3] & 0o111) == (wanted[0] == "100755")
            and read_input(image.root, old.path, 8 * 1024 * 1024, absolute_deadline) == old,
            "source_changed",
            "Retained staged descriptor or source bytes changed",
        )
    for old in image.links:
        require(
            hashlib.sha256(old.data).hexdigest() == expected[old.path][1]
            and _staged_link(image.root, old.path, absolute_deadline) == old,
            "source_changed",
            "Retained staged source link changed",
        )
    require(
        root_identity(image.root) == image.root_identity,
        "source_changed",
        "Staged owner changed during currentness check",
    )
    output_directories, generated = _staged_generator_outputs(image)
    actual_paths = _staged_inventory(image.root, absolute_deadline, output_directories)
    require(
        set(expected) <= actual_paths and actual_paths <= set(expected) | set(generated),
        "inventory",
        "Actual staged tree gained an unowned source leaf",
    )
    for path in actual_paths - set(expected):
        row = read_input(image.root, path, 8 * 1024 * 1024, absolute_deadline)
        require(
            row.data == generated[path],
            "source_changed",
            "Actual version-generated source differs",
        )
    deadline(absolute_deadline)


def _staged_generator_outputs(image):
    # Derive the output namespace from the already verified real recipes and
    # templates; this introduces no second product/role identity mapping.
    files = {row.path: row for row in image.files}
    recipe_paths = {
        path for path, _ in image.projection.replacements if path.endswith("/project.yml")
    } | {"vendor/duktape-src/project.yml"}
    require(len(recipe_paths) == 4, "inventory", "Actual native recipe inventory differs")
    directories = set()
    for path in recipe_paths:
        lines = files[path].data.decode("utf-8").splitlines()
        require(
            lines and lines[0].startswith("name: "),
            "inventory",
            "Actual native recipe name is missing",
        )
        name = lines[0][6:]
        require(
            name and all(c.isascii() and (c.isalnum() or c in "._-") for c in name),
            "inventory",
            "Actual native recipe name is malformed",
        )
        parent = Path(path).parent
        directories.add(str(parent / "build"))
        directories.add(str(parent / (name + ".xcodeproj")))
    version = files["version"].data.decode("utf-8").splitlines()[0].strip()
    generated = {}
    for path, row in files.items():
        if "vendor" not in Path(path).parts and path.endswith(
            (".hpp.in", ".h.in", ".plist.in", ".xml.in")
        ):
            generated[path[:-3]] = (
                row.data.decode("utf-8").replace("@VERSION@", version).encode("utf-8")
            )
    require(len(generated) == 12, "inventory", "Actual version template inventory differs")
    return directories, generated


def expected_generated_outputs(image):
    """Return pure template bytes; the builder owns output FD/currentness checks."""
    require(
        type(image) is StagedSource,
        "source_changed",
        "Actual staged image type differs",
    )
    _, generated = _staged_generator_outputs(image)
    return tuple(sorted(generated.items()))
