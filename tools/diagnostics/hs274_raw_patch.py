# tools/diagnostics/hs274_raw_patch.py
"""Instrument only the pinned disposable Karabiner checkout for a finite capture."""

from pathlib import Path
import subprocess
import sys

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


def main(root):
    """Preflight every owned target before writing any instrumentation."""
    root = root.resolve()
    revision = subprocess.check_output(["git", "-C", str(root), "rev-parse", "HEAD"], text=True).strip()
    if revision != REVISION:
        raise RuntimeError("Raw capture requires the inspected upstream revision")
    header = root / "src/share/hs274-raw-capture.hpp"
    if header.exists() or header.is_symlink():
        raise RuntimeError("Refusing to replace an existing capture header")
    prepared = []
    for relative, transform in (
        ("src/share/hid_device_events_monitor.hpp", instrument_monitor),
        ("src/apps/CoreService/include/core_service/main/daemon.hpp", instrument_shutdown),
    ):
        target = root / relative
        if target.resolve() != target:
            raise RuntimeError("Refusing a redirected upstream source")
        baseline = subprocess.check_output(["git", "-C", str(root), "show", "HEAD:" + relative])
        if target.read_bytes() != baseline:
            raise RuntimeError("Refusing to overwrite modified upstream source")
        prepared.append((target, transform(baseline.decode("utf-8")).encode("utf-8")))
    with header.open("xb") as handle:
        handle.write(Path(__file__).with_name("hs274-raw-capture.hpp").read_bytes())
    for target, contents in prepared:
        target.write_bytes(contents)
    print("Applied fixture-only capture before normalization; authentication and remapping unchanged.")


if __name__ == "__main__":
    main(Path(sys.argv[1]))
