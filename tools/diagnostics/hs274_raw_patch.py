# tools/diagnostics/hs274_raw_patch.py
"""Instrument only the pinned disposable Karabiner checkout for a finite capture."""

from pathlib import Path
import argparse
import subprocess

REVISION = "9312593e1a3bf72b94c63c524ebabe2637442e8a"


def replace_once(source, before, after):
    """Refuse upstream drift or duplicate anchors before producing a patch."""
    if source.count(before) != 1:
        raise RuntimeError(f"Expected one upstream anchor: {before!r}")
    return source.replace(before, after, 1)


def instrument_monitor(source):
    """Capture only the renamed owned device before timestamp normalization."""
    source = replace_once(source, "#pragma once\n", '#pragma once\n\n#include "hs274-raw-capture.hpp"\n')
    source = replace_once(source, "        last_time_stamp_(0) {", """        hs274_probe_device_id_(type_safe::get(device_properties.get_device_id())),
        hs274_probe_owned_(type_safe::get(device_properties.get_product()) == "HS274 CI Keyboard"),
        last_time_stamp_(0) {""")
    source = replace_once(source, "    normalize_time_stamps(*hid_values);", """    if (hs274_probe_owned_) {
      for (const auto& value : *hid_values) {
        const auto page = value.get_usage_page();
        const auto usage = value.get_usage();
        hs274_raw_capture::fixture.append({
            hs274_probe_device_id_, type_safe::get(value.get_time_stamp()),
            value.get_integer_value(), page.has_value(), usage.has_value(),
            page ? static_cast<std::int32_t>(type_safe::get(*page)) : 0,
            usage ? static_cast<std::int32_t>(type_safe::get(*usage)) : 0});
      }
    }
    normalize_time_stamps(*hid_values);""")
    return replace_once(source, "  pqrs::osx::chrono::absolute_time_point last_time_stamp_;", """  std::uint64_t hs274_probe_device_id_;
  bool hs274_probe_owned_;
  pqrs::osx::chrono::absolute_time_point last_time_stamp_;""")


def instrument_shutdown(source):
    """Publish a finite committed-prefix snapshot outside input callbacks."""
    source = replace_once(source, "#pragma once\n", '#pragma once\n\n#include "hs274-raw-capture.hpp"\n')
    return replace_once(source, "  return 0;", "  return hs274_raw_capture::finish() ? 0 : 1;")


def main(root, stream=False):
    """Preflight every owned target before writing any instrumentation."""
    root = root.resolve()
    revision = subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip()
    if revision != REVISION:
        raise RuntimeError("Raw capture requires the inspected upstream revision")
    headers = ["hs274-raw-capture.hpp"]
    transforms = [
        ("src/share/hid_device_events_monitor.hpp", instrument_monitor),
        ("src/apps/CoreService/include/core_service/main/daemon.hpp", instrument_shutdown),
    ]
    if stream:
        from hs274_stream_patch import stream_monitor, stream_operations, stream_receiver, stream_client, stream_cli, stream_server, stream_entry, stream_socket_ops
        headers += ["hs274-stream-session.hpp", "hs274-stream-protocol.hpp",
                    "hs274-stream-source.hpp", "hs274-stream-input.hpp", "hs274-stream-readiness.hpp", "hs274-stream-runtime.hpp", "hs274-stream-cli.hpp"]
        transforms[0] = ("src/share/hid_device_events_monitor.hpp", stream_monitor)
        transforms += [
            ("vendor/vendor/include/asio/detail/impl/socket_ops.ipp", stream_socket_ops),
            ("vendor/vendor/include/pqrs/unix_domain_stream/server.hpp", stream_server),
            ("src/share/types/operation_type.hpp", stream_operations),
            ("src/apps/CoreService/include/core_service/daemon/receiver.hpp", stream_receiver),
            ("src/apps/CoreService/include/core_service/daemon/device_grabber_details/entry.hpp", stream_entry),
            ("src/share/core_service_daemon_client.hpp", stream_client),
            ("src/bin/cli/src/main.cpp", stream_cli),
        ]
    prepared_headers = []
    for name in headers:
        header = root / "src/share" / name
        if header.exists() or header.is_symlink() or header.resolve() != header:
            raise RuntimeError("Refusing to replace or redirect a capture header")
        prepared_headers.append((header, Path(__file__).with_name(name).read_bytes()))
    prepared = []
    for relative, transform in transforms:
        target = root / relative
        if target.resolve() != target:
            raise RuntimeError("Refusing a redirected upstream source")
        baseline = subprocess.check_output(["git", "-C", str(root), "show", "HEAD:" + relative])
        if target.read_bytes() != baseline:
            raise RuntimeError("Refusing to overwrite modified upstream source")
        prepared.append((target, transform(baseline.decode("utf-8")).encode("utf-8")))
    for header, contents in prepared_headers:
        with header.open("xb") as handle:
            handle.write(contents)
    for target, contents in prepared:
        target.write_bytes(contents)
    print("Applied fixture-only capture before normalization; stream=" + str(stream))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("--stream", action="store_true")
    arguments = parser.parse_args()
    main(arguments.root, arguments.stream)
