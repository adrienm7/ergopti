# tools/diagnostics/hs274_stream_patch.py
"""Prepare exact-source experimental stream hooks; not a standalone installer."""

from hs274_raw_patch import instrument_monitor, replace_once


def require_pristine(source):
    """Reject an already instrumented source before any anchor replacements."""
    if "hs274_" in source:
        raise RuntimeError("Source already contains HS274 instrumentation")


def stream_socket_ops(source):
    """Keep Darwin accepted-peer shutdown from being reported as listener failure."""
    require_pristine(source)
    return replace_once(source, """  int result = ::setsockopt(new_s, SOL_SOCKET,
      SO_NOSIGPIPE, &optval, sizeof(optval));
  get_last_error(ec, result != 0);
  if (result != 0)
  {
    ::close(new_s);
    return invalid_socket;
  }""", """  int result = ::setsockopt(new_s, SOL_SOCKET,
      SO_NOSIGPIPE, &optval, sizeof(optval));
  get_last_error(ec, result != 0);
  if (result != 0)
  {
    ::close(new_s);
#if defined(__MACH__) && defined(__APPLE__)
    // hs274_accepted_peer: Darwin rejects options on a fully shut-down peer.
    // Preserve real accept errors; only this already accepted socket aborted.
    if (ec == asio::error::invalid_argument)
      ec = asio::error::connection_aborted;
#endif
    return invalid_socket;
  }""")


def stream_server(source):
    """Expose listener failure causes without changing transport recovery."""
    require_pristine(source)
    source = replace_once(source, "#pragma once\n", "#pragma once\n\n#include <cstdio>\n")
    source = replace_once(source, "              self->close_acceptor();", """              std::fprintf(stderr, "hs274_transport_failure phase=accept code=%d category=%s\\n",
                           error_code.value(), error_code.category().name());
              self->close_acceptor();""")
    source = replace_once(source, "void handle_socket_path_health_check_failed(const asio::error_code&,",
                          "void handle_socket_path_health_check_failed(const asio::error_code& error_code,")
    return replace_once(source, "    close_socket_path_health_check_peer();\n\n    close_acceptor();", """    std::fprintf(stderr, "hs274_transport_failure phase=health code=%d category=%s\\n",
                 error_code.value(), error_code.category().name());
    close_socket_path_health_check_peer();

    close_acceptor();""")


def stream_monitor(source):
    """Observe keyboard interfaces while retaining a separate owned fixture reference."""
    require_pristine(source)
    source = instrument_monitor(source)
    source = replace_once(source, '#include "hs274-raw-capture.hpp"',
                          '#include "hs274-stream-runtime.hpp"\n#include "hs274-stream-baseline-probe.hpp"')
    source = replace_once(source, "hs274_raw_capture::fixture.append({", "hs274_stream_protocol::runtime::append(hs274_monitor_, hs274_probe_owned_, {")
    source = replace_once(source, "    if (hs274_probe_owned_) {", "    if (hs274_stream_selected_) {")
    source = replace_once(source, "        last_time_stamp_(0) {", """        hs274_stream_selected_(!device_properties.get_device_identifiers().get_is_virtual_device() &&
                               (device_properties.get_device_identifiers().get_is_keyboard() ||
                                device_properties.get_device_identifiers().get_is_consumer())),
        hs274_monitor_(hs274_stream_selected_ ? hs274_stream_protocol::runtime::attach(hs274_probe_device_id_)
                                         : hs274_stream_protocol::runtime::monitor{}),
        last_time_stamp_(0) {""")
    source = replace_once(source, "device_events_monitor_->started.connect([this] {",
                          "device_events_monitor_->started.connect([this, device] {")
    source = replace_once(source, "      started();",
                          "      if (hs274_probe_owned_) hs274_baseline_probe::capture(device, hs274_probe_device_id_);\n"
                          "      hs274_monitor_.started();\n      started();")
    source = replace_once(source, "      stopped();", "      hs274_monitor_.stopped();\n      stopped();")
    source = replace_once(source, "      error_occurred(message, result);",
                          "      hs274_monitor_.stopped();\n      error_occurred(message, result);")
    source = replace_once(source, "      device_events_monitor_ = nullptr;",
                          "      hs274_monitor_.retire();\n      device_events_monitor_ = nullptr;")
    return replace_once(source, "  pqrs::osx::chrono::absolute_time_point last_time_stamp_;",
                        "  bool hs274_stream_selected_;\n"
                        "  hs274_stream_protocol::runtime::monitor hs274_monitor_;\n"
                        "  pqrs::osx::chrono::absolute_time_point last_time_stamp_;")


def stream_operations(source):
    """Append the experimental operation without renumbering existing operations."""
    require_pristine(source)
    source = replace_once(source, "  end_,", "  hs274_capture,\n  end_,")
    return replace_once(source, '        {operation_type::end_, "end_"},',
                        '        {operation_type::hs274_capture, "hs274_capture"},\n'
                        '        {operation_type::end_, "end_"},')


def stream_receiver(source):
    """Own capture through the authenticated receiver and its peer lifecycle."""
    require_pristine(source)
    source = replace_once(source, "#pragma once\n", '#pragma once\n\n#include "hs274-stream-runtime.hpp"\n')
    source = replace_once(source, "    connected_devices_observer_peer_ids_.erase(peer_id);",
                          "    const auto hs274_observing = hs274_capture_.observing();\n"
                          "    hs274_capture_.peer_closed(peer_id);\n"
                          "    hs274_refresh_observation(hs274_observing);\n"
                          "    connected_devices_observer_peer_ids_.erase(peer_id);")
    source = replace_once(source, "        case operation_type::observe_connected_devices:", """        case operation_type::hs274_capture: {
          const auto hs274_observing = hs274_capture_.observing();
          auto response = nlohmann::json{
              {"operation_type", operation_type::hs274_capture},
              {"capture", hs274_capture_.request(peer_id, json.at("capture"))},
          };
          hs274_refresh_observation(hs274_observing);
          auto bytes = nlohmann::json::to_msgpack(response);
          if (bytes.size() > constants::unix_domain_stream_max_message_size) {
            throw std::runtime_error("Physical capture response exceeds the IPC limit");
          }
          server_->async_respond(peer_id, request_id, bytes);
          break;
        }

        case operation_type::observe_connected_devices:""")
    source = replace_once(source, "  std::optional<uid_t> current_console_user_id_;",
                        "  hs274_stream_protocol::runtime hs274_capture_;\n\n"
                        "  std::optional<uid_t> current_console_user_id_;")
    return replace_once(source, "  void update_temporarily_ignored_device_ids() {", """  void hs274_refresh_observation(bool previously_observing) {
    if (device_grabber_ && previously_observing != hs274_capture_.observing()) {
      // The queued grab reads current policy, including a successor preparation.
      device_grabber_->async_grab_devices();
    }
  }

  void update_temporarily_ignored_device_ids() {""")


def stream_entry(source):
    """Observe only reserved ignored fixtures without weakening seizure readiness."""
    require_pristine(source)
    source = replace_once(source, "#pragma once\n", '#pragma once\n\n#include "hs274-stream-runtime.hpp"\n')
    return replace_once(source, """    return false;
  }

  // Return whether the device is a target for modifying input events.""", """    return hs274_stream_protocol::runtime::observes(
        type_safe::get(get_device_id()), needs_to_seize_device(), temporarily_ignore_);
  }

  // Return whether the device is a target for modifying input events.""")


def stream_client(source):
    """Serialize caller requests on the existing client dispatcher."""
    require_pristine(source)
    return replace_once(source, "  void async_stop() {", """  void async_hs274_capture(nlohmann::json capture,
                           std::function<void(const asio::error_code&)> completion) const {
    enqueue_to_dispatcher([this, capture = std::move(capture), completion = std::move(completion)] {
      async_request(nlohmann::json{
          {"operation_type", operation_type::hs274_capture},
          {"capture", capture},
      }, completion);
    });
  }

  void async_stop() {""")


def stream_cli(source):
    """Expose a dedicated mode whose output runs outside the IPC dispatcher."""
    require_pristine(source)
    source = replace_once(source, '#include "watch_multitouch_extension_variables.hpp"',
                          '#include "watch_multitouch_extension_variables.hpp"\n#include "hs274-stream-cli.hpp"')
    source = replace_once(source, '  options.add_options()("select-profile",',
                          '  options.add_options()("hs274-capture",\n'
                          '                        "Observe the experimental physical fixture stream",\n'
                          '                        cxxopts::value<int>(), "polling-interval-in-milliseconds");\n\n'
                          '  options.add_options()("select-profile",')
    return replace_once(source, '    bool silent = parse_result["silent"].as<bool>();',
                        '    bool silent = parse_result["silent"].as<bool>();\n\n'
                        '    if (parse_result.count("hs274-capture")) {\n'
                        '      exit_code = krbn::cli::hs274_capture::run(parse_result["hs274-capture"].as<int>());\n'
                        '      goto finish;\n'
                        '    }')
