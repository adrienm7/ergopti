"""Fixed owned producer projections; no profile or native-readiness authority.

The owned source factory supplies exact frozen experimental intermediate bytes.
The original experimental source, independent fixtures and oracle stay unchanged.
"""


def replace_once(source, before, after):
    if type(source) is not str or source.count(before) != 1:
        raise RuntimeError("Expected one fixed owned producer anchor")
    return source.replace(before, after, 1)


# The closed owned source factory selects these projections directly. The
# experimental functions and header bytes stay whole in their original files.
def owned_stream_monitor(source):
    """Keep genuine native capture hooks without the named finite fixture role."""
    source = replace_once(
        source,
        '        hs274_probe_owned_(type_safe::get(device_properties.get_product()) == "HS274 CI Keyboard"),\n',
        "",
    )
    source = replace_once(source, "  bool hs274_probe_owned_;\n", "")
    source = replace_once(
        source,
        "      if (hs274_probe_owned_) hs274_stream_protocol::runtime::reference(hs274_monitor_, device, hs274_probe_device_id_);\n",
        "",
    )
    source = replace_once(
        source,
        "hs274_stream_protocol::runtime::append(hs274_monitor_, hs274_probe_owned_, {",
        "hs274_stream_protocol::runtime::append(hs274_monitor_, {",
    )
    return source.replace("hs274_probe_device_id_", "hs274_capture_device_id_")


def owned_stream_shutdown(source):
    """Preserve the actual daemon's native lifetime and final return unchanged."""
    # Validate the same unique final return the experimental hook instruments,
    # then leave all native startup/cleanup bytes to their existing owner.
    return replace_once(source, "  return 0;", "  return 0;")


def owned_stream_runtime(source):
    """Project the closed native bridge without finite mirror/reference work."""
    source = replace_once(source, '#include "hs274-stream-input.hpp"\n', "")
    source = replace_once(
        source,
        "  static bool reference(monitor& owner, IOHIDDeviceRef device, std::uint64_t identity) {\n    const auto fence = owner.capture_fence();\n    if (!current(fence) || !owner.active()) return false;\n    if (fence.fault() != native_fault::none) { fence.stopped(); return false; }\n    return diagnostic_acquisition(owner, [fence](native_fault reason) { fence.fail(reason); }, [&] {\n      hs274_baseline_probe::capture(device, identity);\n      return current(fence);\n    }, current);\n  }\n\n",
        "",
    )
    source = replace_once(
        source,
        "  static void append(monitor& owner, bool is_reference, const value& input) noexcept {\n    // Retain the finite independent receipt during this fixture experiment.\n    append_input(owner, hs274_raw_capture::fixture, is_reference, input);\n  }\n",
        "  static void append(monitor& owner, const value& input) noexcept {\n"
        "    owner.append(input);\n"
        "  }\n",
    )
    source = replace_once(
        source,
        "hs274_baseline_probe::capture_inventory(device, captured.device())",
        "hs274_baseline_probe::capture_inventory(device)",
    )
    source = replace_once(
        source,
        "// Disposable native bridge; all access belongs to the shared dispatcher.",
        "// Owned native bridge; all access belongs to the shared dispatcher.",
    )
    return replace_once(
        source,
        "  // The finite fixture has 20 values. Bound both backlog and per-response work;\n",
        "  // Bound producer backlog and per-response work independently of diagnostic fixtures;\n",
    )


def owned_stream_baseline_probe(source):
    """Retain per-element baseline-v2 acquisition without raw diagnostic I/O."""
    source = replace_once(
        source,
        '\ninline void capture(IOHIDDeviceRef device, std::uint64_t identity) {\n  elements_owner elements{IOHIDDeviceCopyMatchingElements(device, nullptr, kIOHIDOptionsTypeNone)};\n  json result{{"device", std::to_string(identity)}, {"coverage", "fixture_only"},\n              {"enumerated", elements.value != nullptr}, {"exhausted", false}, {"elements", json::array()}};\n  if (elements.value) {\n    for (CFIndex i = 0; i < CFArrayGetCount(elements.value); ++i) {\n      auto element = static_cast<IOHIDElementRef>(const_cast<void*>(CFArrayGetValueAtIndex(elements.value, i)));\n      const auto page = IOHIDElementGetUsagePage(element);\n      const auto usage = IOHIDElementGetUsage(element);\n      const auto type = IOHIDElementGetType(element);\n      // The independent fixture uses Escape and Space. This deliberately does\n      // not pretend that two sampled usages inventory an arbitrary keyboard.\n      if (page != 7 || (usage != 41 && usage != 44) ||\n          type < kIOHIDElementTypeInput_Misc || type > kIOHIDElementTypeInput_ScanCodes) continue;\n      if (result["elements"].size() == 2) {\n        result["exhausted"] = true;\n        break;\n      }\n      result["elements"].push_back({\n          {"page", page}, {"usage", usage}, {"cookie", static_cast<std::uint32_t>(IOHIDElementGetCookie(element))},\n          {"cached", read(device, element, kIOHIDDeviceGetValueWithoutUpdate)},\n          {"updated", read(device, element, kIOHIDDeviceGetValueWithUpdate)}});\n    }\n  }\n  const auto encoded = result.dump();\n  if (std::fprintf(stderr, "HS274_BASELINE_PROBE %s\\n", encoded.c_str()) < 0 || std::fflush(stderr) != 0) {\n    throw hs274_stream_protocol::native_acquisition_error(hs274_stream_protocol::native_fault::reference_receipt_write_failed);\n  }\n}',
        "",
    )
    source = replace_once(
        source,
        "capture_inventory(IOHIDDeviceRef device, std::uint64_t identity)",
        "capture_inventory(IOHIDDeviceRef device)",
    )
    source = replace_once(
        source,
        '  json result{{"version", 2u}, {"device", std::to_string(identity)}, {"coverage", "fixture_only"},\n              {"capacity", hs274_stream_protocol::keyboard_inventory_capacity},\n              {"enumerated", elements.value != nullptr}, {"exhausted", false}, {"elements", json::array()}};\n',
        "  observation.enumerated = elements.value != nullptr;\n",
    )
    source = replace_once(
        source,
        'if (inventory.full()) { result["exhausted"] = true; break; }',
        "if (inventory.full()) { observation.exhausted = true; break; }",
    )
    source = replace_once(
        source,
        '      result["elements"].push_back({{"page", page}, {"usage", usage}, {"cookie", cookie}, {"sample", sample},\n          {"relative", descriptor.relative}, {"array", descriptor.array}, {"bits", descriptor.bits},\n          {"count", descriptor.count}, {"minimum", descriptor.minimum}, {"maximum", descriptor.maximum}});\n',
        "",
    )
    source = replace_once(
        source,
        '  result["readable"] = inventory.finish(result.at("enumerated").get<bool>(), result.at("exhausted").get<bool>());\n  const auto encoded = result.dump();\n  if (std::fprintf(stderr, "HS274_KEY_INVENTORY %s\\n", encoded.c_str()) < 0 || std::fflush(stderr) != 0) {\n    throw hs274_stream_protocol::native_acquisition_error(hs274_stream_protocol::native_fault::inventory_receipt_write_failed);\n  }\n  observation.enumerated = result.at("enumerated").get<bool>();\n  observation.exhausted = result.at("exhausted").get<bool>();\n',
        "  inventory.finish(observation.enumerated, observation.exhausted);\n",
    )
    return replace_once(
        source,
        "// Disposable fixture acquisition probe, never a complete-coverage declaration.",
        "// Owned per-element acquisition, never a native queue fence or complete-coverage declaration.",
    )


def owned_stream_record(source):
    """Retain the shared raw value and finite capture type, without a global sink."""
    return replace_once(
        source,
        '// Bound only this short fixture observation. Any exhaustion invalidates coverage.\ninline capture<4096> fixture;\n\ninline bool finish() {\n  const auto state = fixture.read();\n  std::printf("HS274_RAW_CAPTURE {\\"coverage\\":\\"fixture_only\\",\\"seen\\":%" PRIu64\n              ",\\"overflow\\":%" PRIu64 ",\\"contention\\":%" PRIu64 ",\\"records\\":[",\n              state.seen, state.overflow, state.contention);\n  for (std::size_t i = 0; i < state.count; ++i) {\n    const auto& r = state.records[i];\n    std::printf("%s{\\"device\\":%" PRIu64 ",\\"timestamp\\":%" PRIu64 ",\\"value\\":%" PRId64\n                ",\\"has_page\\":%s,\\"has_usage\\":%s,\\"page\\":%" PRId32\n                ",\\"usage\\":%" PRId32 ",\\"sequence\\":%" PRIu64\n                ",\\"has_cookie\\":%s,\\"cookie\\":%" PRIu32 "}",\n                i ? "," : "", r.device, r.timestamp, r.value,\n                r.has_page ? "true" : "false", r.has_usage ? "true" : "false",\n                r.page, r.usage, r.sequence, r.has_cookie ? "true" : "false", r.cookie);\n  }\n  std::printf("]}\\n");\n  return std::fflush(stdout) == 0 && !std::ferror(stdout);\n}\n',
        "",
    )
