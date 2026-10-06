#pragma once

// Portable policy only. Fixture observations and ALLOW results are not native
// code, current socket, parent, lifecycle, or frame authentication capabilities.
#include "remap_runtime_identity.hpp"
#include <cstdint>
#include <optional>
#include <string_view>

namespace ergoptiplus::remap::auth_policy {
using role = identity::role;
enum class route {
  daemon_client, daemon_server, session_client, session_server,
  console_client, console_server,
  daemon_server_health, session_server_health, console_server_health
};
enum class admission { denied, native_frame_required, native_owner_frame_required, health_only };

struct observation final {
  route channel;
  role local_role;
  role peer_role;
  std::uint32_t local_euid;
  std::uint32_t peer_euid;
  std::optional<std::uint32_t> receiver_uid;
};

[[nodiscard]] constexpr bool ordinary_role(role value) noexcept {
  return value == role::core || value == role::console || value == role::cli;
}

[[nodiscard]] constexpr admission qualify(const observation& value) noexcept {
  switch (value.channel) {
    case route::daemon_client:
      if (ordinary_role(value.local_role) && value.local_euid != 0 &&
          value.peer_role == role::core && value.peer_euid == 0) {
        return value.local_role == role::console ? admission::native_owner_frame_required
                                                : admission::native_frame_required;
      }
      break;
    case route::daemon_server:
      if (value.local_role == role::core && value.local_euid == 0 &&
          ordinary_role(value.peer_role) && value.peer_euid != 0 &&
          value.receiver_uid && *value.receiver_uid == value.peer_euid) {
        return value.peer_role == role::console ? admission::native_owner_frame_required
                                               : admission::native_frame_required;
      }
      break;
    case route::session_client:
      if (value.local_role == role::console && value.local_euid != 0 &&
          value.peer_role == role::core && value.peer_euid == 0) {
        return admission::native_owner_frame_required;
      }
      break;
    case route::session_server:
      if (value.local_role == role::core && value.local_euid == 0 &&
          value.peer_role == role::console && value.peer_euid != 0) {
        return admission::native_owner_frame_required;
      }
      break;
    case route::console_client:
      if (value.local_role == role::core && value.local_euid != 0 &&
          value.peer_role == role::console && value.peer_euid == value.local_euid) {
        return admission::native_owner_frame_required;
      }
      break;
    case route::console_server:
      if (value.local_role == role::console && value.local_euid != 0 &&
          value.peer_role == role::core && value.peer_euid == value.local_euid) {
        return admission::native_owner_frame_required;
      }
      break;
    case route::daemon_server_health:
    case route::session_server_health:
      if (value.local_role == role::core && value.local_euid == 0 &&
          value.peer_role == role::core && value.peer_euid == 0) {
        return admission::health_only;
      }
      break;
    case route::console_server_health:
      if (value.local_role == role::console && value.local_euid != 0 &&
          value.peer_role == role::console && value.peer_euid == value.local_euid) {
        return admission::health_only;
      }
      break;
  }
  return admission::denied;
}

[[nodiscard]] constexpr admission operation_admission(const observation& value,
                                                       std::string_view operation) noexcept {
  const auto base = qualify(value);
  if (base == admission::denied) {
    return base;
  }
  if (base == admission::health_only) {
    return operation == "health_check" || operation == "health_check_response"
               ? admission::health_only : admission::denied;
  }
  switch (value.channel) {
    case route::daemon_server:
      if (operation == "hs274_capture") {
        return value.peer_role == role::cli ? base : admission::denied;
      }
      if (operation == "start_device_grabber" || operation == "system_preferences_updated" ||
          operation == "input_source_changed") {
        return value.peer_role == role::console ? base : admission::denied;
      }
      if (operation == "core_service_bundle_permission_check_result" ||
          operation == "frontmost_application_changed" || operation == "focused_ui_element_changed") {
        return value.peer_role == role::core ? base : admission::denied;
      }
      if (operation == "set_app_icon" || operation == "set_variables" ||
          operation == "clear_user_variables" || operation == "observe_connected_devices" ||
          operation == "observe_notification_message" || operation == "get_system_variables" ||
          operation == "get_multitouch_extension_variables") {
        return base;
      }
      return admission::denied;
    case route::session_server:
      return operation == "console_user_id_changed" ? base : admission::denied;
    case route::session_client:
      return operation == "core_service_daemon_server_bound" ? base : admission::denied;
    case route::console_server:
      // Selected Core agent operations only. Root Core responses/actions use
      // the existing daemon_client socket, not this standalone user listener.
      if (operation == "frontmost_application_changed" || operation == "focused_ui_element_changed") {
        return base;
      }
      return admission::denied;
    case route::daemon_client:
      if (operation == "hs274_capture") {
        return value.local_role == role::cli ? base : admission::denied;
      }
      if (operation == "none" || operation == "connected_devices" || operation == "notification_message" ||
          operation == "system_variables" || operation == "multitouch_extension_variables") {
        return base;
      }
      if (value.local_role == role::core && operation == "refresh_core_service_bundle_permission_check_result") {
        return base;
      }
      if (value.local_role == role::console &&
          (operation == "core_service_daemon_state" || operation == "app_icon_changed" ||
           operation == "check_for_updates" || operation == "shell_command_execution" ||
           operation == "send_user_command" || operation == "select_input_source" ||
           operation == "software_function" || operation == "frontmost_application_changed" ||
           operation == "focused_ui_element_changed")) {
        return base;
      }
      return admission::denied;
    case route::console_client:
      return operation == "none" ? base : admission::denied;
    case route::daemon_server_health:
    case route::session_server_health:
    case route::console_server_health:
      break;
  }
  return admission::denied;
}

} // namespace ergoptiplus::remap::auth_policy
