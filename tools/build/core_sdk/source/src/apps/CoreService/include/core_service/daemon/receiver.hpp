#pragma once

#include "hs274-stream-runtime.hpp"
#include <atomic>

// `krbn::core_service::daemon::receiver` can be used safely in a multi-threaded environment.

#include "app_icon.hpp"
#include "application_launcher.hpp"
#include "console_user_server_peer.hpp"
#include "constants.hpp"
#include "core_service/daemon/core_service_daemon_state_manager.hpp"
#include "device_grabber.hpp"
#include "OwnedRuntimeMaintenanceCoreEndpoint.hpp"
#include "filesystem_utility.hpp"
#include "process_lifecycle_manager.hpp"
#include "types.hpp"
#include "remap_runtime_auth.hpp"
#include "remap_runtime_console_control.hpp"
#include "types/core_service_daemon_state.hpp"
#include <array>
#include <exception>
#include <filesystem>
#include <functional>
#include <memory>
#include <pqrs/dispatcher.hpp>
#include <pqrs/osx/session.hpp>
#include <pqrs/osx/system_preferences.hpp>
#include <pqrs/osx/system_preferences/extra/nlohmann_json.hpp>
#include <pqrs/unix_domain_stream.hpp>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

namespace krbn::core_service::daemon {
class receiver final : public pqrs::dispatcher::extra::dispatcher_client {
  friend class ::ergoptiplus::installed_maintenance::core_endpoint;
public:
  // Signals (invoked from the shared dispatcher thread)

  nod::signal<void()> server_bound;

  // Methods

  receiver(const receiver&) = delete;

  receiver(std::optional<uid_t> current_console_user_id,
           std::weak_ptr<core_service_daemon_state_manager> weak_core_service_daemon_state_manager)
      : dispatcher_client(),
        owned_channel_(ergoptiplus::remap::auth::channel_owner::daemon_server(current_console_user_id)),
        current_console_user_id_(current_console_user_id),
        weak_core_service_daemon_state_manager_(weak_core_service_daemon_state_manager) {
    prepare_karabiner_core_service_daemon_socket_directory();

    if (auto m = weak_core_service_daemon_state_manager_.lock()) {
      core_service_daemon_state_manager_connection_ = m->core_service_daemon_state_changed.connect([this](const auto& core_service_daemon_state) {
        enqueue_to_dispatcher([this, core_service_daemon_state] {
          send_core_service_daemon_state(core_service_daemon_state);
        });
      });
    }

    //
    // Setup server_
    //

    auto socket_file_path = karabiner_core_service_daemon_socket_file_path();

    server_ = std::make_shared<pqrs::unix_domain_stream::server>(
        weak_dispatcher_,
        socket_file_path,
        constants::get_unix_domain_stream_server_options(),
        [](const auto& peer_credentials) {
          auto result = get_shared_codesign_manager()->same_team_id(peer_credentials.pid);
          if (!result) {
            // During an update, retrieving the Team ID may fail, causing an error once.
            // Since this can occur during normal use, treat it as debug rather than warn.
            logger::get_logger()->debug("receiver: peer is not code-signed with same Team ID (pid: {0})",
                                        peer_credentials.pid.value_or(-1));
          }
          return result;
        }, std::optional{owned_channel_});

    server_->bound.connect([this, socket_file_path] {
      logger::get_logger()->debug("receiver: bound");

      auto chown_uid = current_console_user_id_.value_or(uid_t(0));
      logger::get_logger()->debug("receiver: chown socket: {0}", chown_uid);
      if (!filesystem_utility::chown(socket_file_path, chown_uid, 0)) {
        return;
      }

      if (!filesystem_utility::permissions(socket_file_path,
                                           filesystem_utility::permissions_0600)) {
        return;
      }

      server_bound();
    });

    server_->bind_failed.connect([this](auto&& error_code) {
      logger::get_logger()->error("receiver: bind_failed");

      // If the socket directory is deleted for any reason,
      // bind_failed will be triggered, so recreate the directory each time.
      prepare_karabiner_core_service_daemon_socket_directory();
    });

    server_->closed.connect([] {
      logger::get_logger()->debug("receiver: closed");
    });

    if (!server_->set_owned_connected([](auto, ergoptiplus::remap::auth::frame_scope&) {})) {
      if (owned_channel_) { owned_channel_->revoke(); owned_channel_->schedule_closures(); }
    }

    server_->peer_closed.connect([this](auto peer_id) {
      handle_peer_closed(peer_id);
    });

    server_->peer_error_occurred.connect([](auto peer_id, auto&& error_code) {
      logger::get_logger()->debug("receiver: peer_error_occurred ({0}): {1}", peer_id, error_code.message());
    });

    if (!server_->set_owned_received([](auto, ergoptiplus::remap::auth::frame_scope&) {})) {
      if (owned_channel_) { owned_channel_->revoke(); owned_channel_->schedule_closures(); }
    }

    if (!server_->set_owned_request_received([this](auto peer_id, ergoptiplus::remap::auth::frame_scope& scope) {
      handle_request(peer_id, scope.view().request_id(),
                     std::make_shared<std::vector<uint8_t>>(scope.view().payload()), &scope);
    })) {
      if (owned_channel_) { owned_channel_->revoke(); owned_channel_->schedule_closures(); }
    }

    maintenance_endpoint_=ergoptiplus::installed_maintenance::core_endpoint::acquire(*this,current_console_user_id_);
    server_->async_start();

    //
    // Start device_grabber
    //


    logger::get_logger()->debug("receiver is initialized");
  }

  ~receiver() override {
    installed_receiver_alive_->store(false);
    if (owned_channel_) { owned_channel_->revoke(); owned_channel_->schedule_closures(); }
    detach_from_dispatcher([this] {
      core_service_daemon_state_manager_connection_.disconnect();
      console_user_server_peer_id_ = std::nullopt;
      console_user_server_peer_ = nullptr;
      refuse_pending_installed_prepare();
      if (installed_retirement_request_) {
        (void)hs274_capture_.expire_installed_retirement(installed_retirement_request_);
        installed_retirement_request_.reset();
      }
      if (installed_configuration_request_) {
        (void)hs274_capture_.expire_configuration_mode(installed_configuration_request_);
        installed_configuration_request_.reset();
      }
      if (installed_suspension_request_) {
        (void)hs274_capture_.expire_observation_suspension(installed_suspension_request_);
        installed_suspension_request_.reset();
      }
      stop_device_grabber();
      if (maintenance_endpoint_) maintenance_endpoint_->stop();
      server_ = nullptr;
    });

    logger::get_logger()->debug("receiver is terminated");
  }

private:
  const std::shared_ptr<ergoptiplus::remap::auth::channel_owner> owned_channel_;
  struct pending_installed_prepare final {
    pqrs::unix_domain_stream::peer_id peer;
    std::shared_ptr<ergoptiplus::installed_capture::core_peer_owner> owner;
    nlohmann::json capture;
    std::function<void(const nlohmann::json&)> reply;
    pqrs::dispatcher::time_point deadline;
  };

  void refuse_pending_installed_prepare() {
    auto pending=std::exchange(pending_installed_prepare_,nullptr);
    if (!pending || !pending->owner) return;
    auto owner=std::exchange(pending->owner,nullptr);
    pending->reply=nullptr;
    // Closing this exact original request peer never retires a foreign cohort.
    owner->deliver([&](auto&) {
      if (server_) server_->async_close_peer(pending->peer);
    });
  }

  void continue_pending_installed_prepare() {
    auto pending=pending_installed_prepare_;
    if (!pending || !pending->owner) return;
    if (when_now()>=pending->deadline || !pending->owner->current() || owned_stop_pending()) {
      refuse_pending_installed_prepare();
      return;
    }
    if (!active_owned_cohort_ || !active_owned_cohort_->current()) return;

    // Transfer the one original request out before any foreign continuation.
    pending_installed_prepare_.reset();
    auto owner=std::exchange(pending->owner,nullptr);
    auto reply=std::exchange(pending->reply,nullptr);
    std::shared_ptr<hs274_stream_protocol::runtime::capture_participant> participant;
    try {
      participant=hs274_capture_.retain_preparation(pending->peer,owner,hs274_capture_owner_);
      if (!participant) throw std::logic_error("CLI does not join the original Console constructor");
      const bool observing=hs274_capture_.observing();
      const auto response=hs274_capture_.prepare_production(participant,pending->capture);
      hs274_refresh_observation(observing);
      owner->deliver([&](auto&) { reply(response); });
    } catch (...) {
      // Only the actually joined participant can retire this constructor.
      if (participant) stop_device_grabber();
      // Delivery may already have consumed its ticket before a response error.
      // Settle any remaining original debts before closing that current peer.
      const bool current=owner->current();
      (void)owner->deliver({});
      if (current && server_) server_->async_close_peer(pending->peer);
    }
  }

  void retain_pending_installed_prepare(
      pqrs::unix_domain_stream::peer_id peer,
      const std::shared_ptr<ergoptiplus::installed_capture::core_peer_owner>& owner,
      const nlohmann::json& capture,
      std::function<void(const nlohmann::json&)> reply) {
    if (pending_installed_prepare_) {
      owner->deliver([&](auto&) { if (server_) server_->async_close_peer(peer); });
      return;
    }
    auto pending=std::make_shared<pending_installed_prepare>(pending_installed_prepare{
        peer,owner,capture,std::move(reply),
        when_now()+constants::get_unix_domain_stream_client_options().write_timeout});
    pending_installed_prepare_=pending;
    const auto alive=std::weak_ptr<std::atomic_bool>(installed_receiver_alive_);
    if (!enqueue_to_dispatcher([this,alive,pending] {
          const auto receiver=alive.lock();
          if (!receiver || !receiver->load()) return;
          if (pending_installed_prepare_.get()==pending.get()) continue_pending_installed_prepare();
        },pending->deadline)) {
      refuse_pending_installed_prepare();
      return;
    }
    continue_pending_installed_prepare();
  }

  void async_request(pqrs::unix_domain_stream::peer_id peer_id,
                     nlohmann::json json) {
    if (server_) {
      server_->async_request(
          peer_id,
          nlohmann::json::to_msgpack(json),
          [](auto&& error_code, auto&&) {
            if (error_code) {
              logger::get_logger()->debug("receiver: request failed: {0}", error_code.message());
            }
          });
    }
  }

  void async_respond(pqrs::unix_domain_stream::peer_id peer_id,
                     pqrs::unix_domain_stream::request_id request_id,
                     nlohmann::json json) {
    if (server_) {
      server_->async_respond(peer_id,
                             request_id,
                             nlohmann::json::to_msgpack(json));
    }
  }

  void async_respond_none(pqrs::unix_domain_stream::peer_id peer_id,
                          pqrs::unix_domain_stream::request_id request_id) {
    async_respond(peer_id,
                  request_id,
                  nlohmann::json{
                      {"operation_type", operation_type::none},
                  });
  }

  void handle_peer_closed(pqrs::unix_domain_stream::peer_id peer_id) {
    if (temporarily_ignored_device_ids_by_peer_.erase(peer_id) > 0) {
      update_temporarily_ignored_device_ids();
    }
    const bool installed_peer_closed = hs274_capture_.installed(peer_id);
    const auto hs274_observing = hs274_capture_.observing();
    hs274_capture_.peer_closed(peer_id);
    if (installed_peer_closed) stop_device_grabber();
    hs274_refresh_observation(hs274_observing);
    connected_devices_observer_peer_ids_.erase(peer_id);
    notification_message_observer_peer_ids_.erase(peer_id);

    if (multitouch_extension_peer_id_ == peer_id) {
      logger::get_logger()->debug("multitouch_extension is closed.");

      multitouch_extension_peer_id_ = std::nullopt;
      clear_multitouch_extension_environment_variables();
    }

    if (core_service_agent_peer_id_ == peer_id) {
      core_service_agent_peer_id_ = std::nullopt;
    }

    if (console_user_server_peer_id_ == peer_id) {
      console_user_server_peer_id_ = std::nullopt;
      console_user_server_peer_ = nullptr;

      stop_device_grabber();
    }
  }

  void handle_request(pqrs::unix_domain_stream::peer_id peer_id,
                      pqrs::unix_domain_stream::request_id request_id,
                      pqrs::not_null_shared_ptr_t<std::vector<uint8_t>> buffer,
                      ergoptiplus::remap::auth::frame_scope* owned_scope = nullptr) {
    if (buffer->empty()) {
      server_->async_close_peer(peer_id);
      return;
    }

    try {
      nlohmann::json json = nlohmann::json::from_msgpack(*buffer);
      if (owned_scope) {
        const auto operation = json.at("operation_type").get<std::string>();
        const auto decoded = json.at("operation_type").get<operation_type>();
        if (nlohmann::json(decoded) != json.at("operation_type") || !owned_scope->permit(operation)) return;
        if (!current_console_user_id_ || owned_scope->view().peer_uid() != *current_console_user_id_) return;
      }
      std::shared_ptr<ergoptiplus::remap::auth::console_control_owner::task> console_frame;
      if (owned_scope && console_control_ &&
          owned_scope->view().peer_role() == ergoptiplus::remap::identity::role::console &&
          json.at("operation_type").get<operation_type>() != operation_type::start_device_grabber) {
        if (!console_control_->matches_frame(*owned_scope) ||
            !console_control_->matches_peer(server_, peer_id)) return;
        console_frame = console_control_->retain_task();
        if (!console_frame) return;
      }
      switch (json.at("operation_type").get<operation_type>()) {
        case operation_type::core_service_bundle_permission_check_result:
          if (auto m = weak_core_service_daemon_state_manager_.lock()) {
            core_service_agent_peer_id_ = peer_id;

            // If the required permissions were missing when this process started,
            // and a newly launched process confirms that the permissions are now granted,
            // restart this process.
            // (The actual restart is handled by launchd, so this process just exits.)

            auto iohid_listen_event_allowed = json.at("iohid_listen_event_allowed").get<bool>();
            auto accessibility_process_trusted = json.at("accessibility_process_trusted").get<bool>();
            auto restart_required =
                !required_permissions_granted() &&
                iohid_listen_event_allowed &&
                accessibility_process_trusted;

            auto result = core_service_permission_check_result();
            result.set_iohid_listen_event_allowed(iohid_listen_event_allowed);
            result.set_accessibility_process_trusted(accessibility_process_trusted);

            m->set_bundle_permission_check_result(result);

            if (restart_required) {
              logger::get_logger()->info("The required permissions are granted. Restarting core daemons.");

              process_lifecycle_manager::async_request_termination();
            }
          }
          async_respond_none(peer_id,
                             request_id);
          break;

        case operation_type::system_preferences_updated:
          system_preferences_properties_ = json.at("system_preferences_properties")
                                               .get<pqrs::osx::system_preferences::properties>();
          if (device_grabber_) {
            device_grabber_->async_set_system_preferences_properties(system_preferences_properties_);
          }
          logger::get_logger()->debug("`system_preferences` is updated.");
          async_respond_none(peer_id,
                             request_id);
          break;

        case operation_type::start_device_grabber: {
          std::shared_ptr<ergoptiplus::remap::auth::console_control_owner::task> start_frame;
          if (owned_scope) {
            auto control = ergoptiplus::remap::auth::console_control_owner::acquire(
                *owned_scope, server_, peer_id, weak_dispatcher_);
            if (!control) throw std::logic_error("Console start has no original native control owner");
            stop_device_grabber();
            if (owned_stop_pending()) throw std::logic_error("Previous native cohort retirement is pending");
            auto peer = std::make_shared<console_user_server_peer>(weak_dispatcher_, server_, peer_id, control);
            start_frame = control->retain_task();
            if (!start_frame) throw std::logic_error("Console control changed before start");
            console_user_server_peer_id_ = peer_id;
            console_user_server_peer_ = std::move(peer);
            console_control_ = std::move(control);
          } else {
            console_user_server_peer_id_ = peer_id;
            console_user_server_peer_ = std::make_shared<console_user_server_peer>(weak_dispatcher_,
                                                                                   server_,
                                                                                   peer_id);

            stop_device_grabber();
          }
          start_device_grabber(json.at("user_core_configuration_file_path").get<std::string>());

          if (auto m = weak_core_service_daemon_state_manager_.lock()) {
            send_core_service_daemon_state(m->copy_state());
          }

          request_core_service_bundle_permission_check_result_refresh();

          async_respond_none(peer_id,
                             request_id);
          break;
        }

        case operation_type::frontmost_application_changed: {
          auto app = json.at("frontmost_application").get<application>();

          //
          // Synchronize frontmost_application_changed to console_user_server
          //

          if (console_user_server_peer_) {
            console_user_server_peer_->async_frontmost_application_changed(app);
          }

          //
          // Update environment_variables in device_grabber
          //

          if (app.get_bundle_identifier() != "org.pqrs.Karabiner-EventViewer") {
            frontmost_application_ = app;
            if (device_grabber_) {
              device_grabber_->async_post_frontmost_application_changed_event(app);
            }
          }
          async_respond_none(peer_id,
                             request_id);
          break;
        }

        case operation_type::focused_ui_element_changed: {
          auto element = json.at("focused_ui_element").get<focused_ui_element>();

          //
          // Synchronize focused_ui_element_changed to console_user_server
          //

          if (console_user_server_peer_) {
            console_user_server_peer_->async_focused_ui_element_changed(element);
          }

          //
          // Update accessibility.* variables
          //

          focused_ui_element_ = element;
          set_focused_ui_element_variables();
          async_respond_none(peer_id,
                             request_id);
          break;
        }

        case operation_type::input_source_changed:
          input_source_properties_ = json.at("input_source_properties")
                                         .get<pqrs::osx::input_source::properties>();
          if (device_grabber_) {
            device_grabber_->async_post_input_source_changed_event(input_source_properties_);
          }
          async_respond_none(peer_id,
                             request_id);
          break;

        case operation_type::temporarily_ignore_device: {
          const auto& device_id_json = json.at("device_id");

          // null means that EventViewer no longer requests a device to be ignored,
          // such as when capture stops or MainView captures All devices.
          if (device_id_json.is_null()) {
            temporarily_ignored_device_ids_by_peer_.erase(peer_id);
          } else {
            temporarily_ignored_device_ids_by_peer_.insert_or_assign(
                peer_id,
                device_id(device_id_json.get<uint64_t>()));
          }

          update_temporarily_ignored_device_ids();
          async_respond_none(peer_id,
                             request_id);
          break;
        }

        case operation_type::get_manipulator_environment:
          if (device_grabber_) {
            device_grabber_->async_invoke_with_manipulator_environment(
                [this, peer_id, request_id](auto&& manipulator_environment) {
                  async_respond(peer_id,
                                request_id,
                                nlohmann::json{
                                    {"operation_type", operation_type::manipulator_environment},
                                    {"manipulator_environment", manipulator_environment.to_json()},
                                });
                });
          } else {
            async_respond_none(peer_id,
                               request_id);
          }
          break;

        case operation_type::connect_multitouch_extension:
          logger::get_logger()->debug("multitouch_extension is connected.");
          multitouch_extension_peer_id_ = peer_id;
          async_respond_none(peer_id,
                             request_id);
          break;

        case operation_type::set_app_icon: {
          // `set_app_icon` requires root privileges.
          auto number = json.at("number").get<int>();

          logger::get_logger()->info("set_app_icon {0}", number);

          app_icon(number).save_to_file(constants::get_system_app_icon_configuration_file_path());


          if (console_user_server_peer_) {
            console_user_server_peer_->async_app_icon_changed(number);
          }

          async_respond_none(peer_id,
                             request_id);
          break;
        }

        case operation_type::set_variables:
          if (device_grabber_) {
            for (const auto& [k, v] : json.at("variables").items()) {
              device_grabber_->async_post_set_variable_event(
                  manipulator_environment_variable_set_variable(
                      k,
                      v.get<manipulator_environment_variable_value>(),
                      nullptr,
                      std::nullopt,
                      nullptr));
            }
          }
          async_respond_none(peer_id,
                             request_id);
          break;

        case operation_type::clear_user_variables:
          if (device_grabber_) {
            device_grabber_->async_invoke_with_manipulator_environment(
                [this, peer_id, request_id](auto&& manipulator_environment) {
                  for (const auto& name : manipulator_environment.get_variable_names()) {
                    if (name.starts_with("system.") ||
                        name.starts_with("accessibility.")) {
                      continue;
                    }

                    device_grabber_->async_post_set_variable_event(
                        manipulator_environment_variable_set_variable(
                            name,
                            std::nullopt,
                            nullptr,
                            std::nullopt,
                            nullptr,
                            manipulator_environment_variable_set_variable::type::unset));
                  }

                  async_respond_none(peer_id,
                                     request_id);
                });
          } else {
            async_respond_none(peer_id,
                               request_id);
          }
          break;

        case operation_type::hs274_capture: {
          const auto hs274_observing = hs274_capture_.observing();

          const auto action=json.at("capture").at("action").get<std::string>();
          if (action=="prepare_installed" || action=="open_installed" ||
              action=="retire_installed" || hs274_capture_.installed(peer_id)) {
            if (!owned_scope) throw std::logic_error("Installed request has no original frame owner");
            auto owner=action=="retire_installed"
                ? hs274_capture_.acquire_retirement_owner(peer_id,json.at("capture"),*owned_scope)
                : ergoptiplus::installed_capture::core_peer_owner::acquire(*owned_scope);
            if (!owner) throw std::logic_error("Installed request has no current native cohort");
            auto reply=[weak_server=std::weak_ptr<pqrs::unix_domain_stream::server>(server_),
                        weak_receiver=std::weak_ptr<std::atomic_bool>(installed_receiver_alive_),peer_id,request_id](const nlohmann::json& capture) {
              const auto receiver=weak_receiver.lock();
              auto server=weak_server.lock();
              if (!receiver || !receiver->load() || !server) return;
              const auto response=nlohmann::json{{"operation_type",operation_type::hs274_capture},{"capture",capture}};
              const auto bytes=nlohmann::json::to_msgpack(response);
              if (bytes.size()>constants::unix_domain_stream_max_message_size)
                throw std::runtime_error("Physical capture response exceeds the IPC limit");
              server->async_respond(peer_id,request_id,bytes);
            };
            if (action=="retire_installed") {
              if (installed_retirement_request_)
                throw std::logic_error("Installed terminal request is already retained");
              installed_retirement_request_=owner;
              auto runtime=hs274_capture_owner_;
              const auto alive=std::weak_ptr<std::atomic_bool>(installed_receiver_alive_);
              const auto weak_server=std::weak_ptr<pqrs::unix_domain_stream::server>(server_);
              // Deadline publication precedes any native retirement effect.
              if (!enqueue_to_dispatcher([this,alive,runtime,owner,weak_server,peer_id] {
                    const bool expired=runtime->expire_installed_retirement(owner);
                    const auto receiver=alive.lock();
                    if (receiver && receiver->load() && installed_retirement_request_==owner)
                      installed_retirement_request_.reset();
                    if (expired) {
                      if (auto server=weak_server.lock()) server->async_close_peer(peer_id);
                    }
                  },when_now()+constants::get_unix_domain_stream_client_options().write_timeout)) {
                installed_retirement_request_.reset();
                owner->deliver({}); // Original request debts settle even for a terminal-only owner.
                if (server_) server_->async_close_peer(peer_id);
                break;
              }
              try {
                hs274_capture_.retire_installed(peer_id,json.at("capture"),owner,
                    [this,alive,owner,reply=std::move(reply)](const nlohmann::json& response) {
                      const auto receiver=alive.lock();
                      if (!receiver || !receiver->load()) return;
                      if (installed_retirement_request_==owner) installed_retirement_request_.reset();
                      reply(response); // Original runtime consumed the actual frame.
                    });
              } catch (...) {
                (void)hs274_capture_.expire_installed_retirement(owner);
                if (installed_retirement_request_==owner) installed_retirement_request_.reset();
                throw;
              }
            } else if (action=="configuration_status") {
              const auto response=hs274_capture_.configuration_status(peer_id,json.at("capture"),owner);
              owner->deliver([&](auto&) { reply(response); });
            } else if (action=="configuration_mode") {
              if (installed_configuration_request_)
                throw std::logic_error("Installed configuration effect request is already pending");
              installed_configuration_request_=owner;
              const auto runtime=hs274_capture_owner_;
              const auto alive=std::weak_ptr<std::atomic_bool>(installed_receiver_alive_);
              const auto weak_server=std::weak_ptr<pqrs::unix_domain_stream::server>(server_);
              if (!enqueue_to_dispatcher([this,alive,runtime,owner,weak_server,peer_id] {
                    const bool expired=runtime->expire_configuration_mode(owner);
                    const auto receiver=alive.lock();
                    if (receiver && receiver->load() && installed_configuration_request_==owner)
                      installed_configuration_request_.reset();
                    if (expired) if (const auto server=weak_server.lock()) server->async_close_peer(peer_id);
                  },when_now()+constants::get_unix_domain_stream_client_options().write_timeout)) {
                installed_configuration_request_.reset();
                owner->deliver([&](auto&) { if (server_) server_->async_close_peer(peer_id); });
                break;
              }
              try {
                hs274_capture_.configuration_mode(peer_id,json.at("capture"),owner,
                    [this,alive,owner,reply=std::move(reply)](const nlohmann::json& response) {
                      const auto receiver=alive.lock();
                      if (!receiver || !receiver->load()) return;
                      if (installed_configuration_request_==owner) installed_configuration_request_.reset();
                      reply(response); // Only the exact native effect callback owns this projection.
                    });
              } catch (...) {
                (void)hs274_capture_.expire_configuration_mode(owner);
                if (installed_configuration_request_==owner) installed_configuration_request_.reset();
                owner->deliver({});
                throw;
              }
            } else if (action=="cancel_observation") {
              if (installed_suspension_request_)
                throw std::logic_error("Original observation suspension is already pending");
              installed_suspension_request_=owner;
              const auto runtime=hs274_capture_owner_;
              const auto alive=std::weak_ptr<std::atomic_bool>(installed_receiver_alive_);
              const auto weak_server=std::weak_ptr<pqrs::unix_domain_stream::server>(server_);
              if (!enqueue_to_dispatcher([this,alive,runtime,owner,weak_server,peer_id] {
                    const bool expired=runtime->expire_observation_suspension(owner);
                    const auto receiver=alive.lock();
                    if (receiver && receiver->load() && installed_suspension_request_==owner)
                      installed_suspension_request_.reset();
                    if (expired) if (const auto server=weak_server.lock()) server->async_close_peer(peer_id);
                  },when_now()+constants::get_unix_domain_stream_client_options().write_timeout)) {
                installed_suspension_request_.reset();
                owner->deliver([&](auto&) { if (server_) server_->async_close_peer(peer_id); });
                break;
              }
              try {
                hs274_capture_.cancel_production_observation(peer_id,json.at("capture"),owner,
                    [this,alive,owner,hs274_observing,reply=std::move(reply)](const nlohmann::json& response) {
                      const auto receiver=alive.lock();
                      if (!receiver || !receiver->load()) return;
                      if (installed_suspension_request_==owner) installed_suspension_request_.reset();
                      hs274_refresh_observation(hs274_observing);
                      reply(response); // Exact pending-baseline ring and callback closure, never baseline ACK or cohort terminal.
                    });
              } catch (...) {
                (void)hs274_capture_.expire_observation_suspension(owner);
                if (installed_suspension_request_==owner) installed_suspension_request_.reset();
                owner->deliver({});
                throw;
              }
            } else if (action=="suspend_observation") {
              if (installed_suspension_request_)
                throw std::logic_error("Original observation suspension is already pending");
              installed_suspension_request_=owner;
              const auto runtime=hs274_capture_owner_;
              const auto alive=std::weak_ptr<std::atomic_bool>(installed_receiver_alive_);
              const auto weak_server=std::weak_ptr<pqrs::unix_domain_stream::server>(server_);
              if (!enqueue_to_dispatcher([this,alive,runtime,owner,weak_server,peer_id] {
                    const bool expired=runtime->expire_observation_suspension(owner);
                    const auto receiver=alive.lock();
                    if (receiver && receiver->load() && installed_suspension_request_==owner)
                      installed_suspension_request_.reset();
                    if (expired) if (const auto server=weak_server.lock()) server->async_close_peer(peer_id);
                  },when_now()+constants::get_unix_domain_stream_client_options().write_timeout)) {
                installed_suspension_request_.reset();
                owner->deliver([&](auto&) { if (server_) server_->async_close_peer(peer_id); });
                break;
              }
              try {
                hs274_capture_.suspend_production_observation(peer_id,json.at("capture"),owner,
                    [this,alive,owner,hs274_observing,reply=std::move(reply)](const nlohmann::json& response) {
                      const auto receiver=alive.lock();
                      if (!receiver || !receiver->load()) return;
                      if (installed_suspension_request_==owner) installed_suspension_request_.reset();
                      hs274_refresh_observation(hs274_observing);
                      reply(response); // Genuine ring and callback ACK, not cohort terminal.
                    });
              } catch (...) {
                (void)hs274_capture_.expire_observation_suspension(owner);
                if (installed_suspension_request_==owner) installed_suspension_request_.reset();
                owner->deliver({});
                throw;
              }
            } else if (action=="prepare_installed") {
              retain_pending_installed_prepare(peer_id,owner,json.at("capture"),std::move(reply));
            } else if (action=="open_installed") {
              auto pending=hs274_capture_.open_production(peer_id,json.at("capture"),owner,reply);
              if (!pending) throw std::logic_error("Installed open has no original retained ring");
              if (!pending->retain_runtime(hs274_capture_owner_) || !device_grabber_ ||
                  !console_control_ || !console_control_->current() || owned_stop_pending() ||
                  !active_owned_cohort_ || !active_owned_cohort_->current()) {
                hs274_capture_.refuse_unlaunched_production(pending);
                stop_device_grabber();
              } else if (!device_grabber_->begin_owned_production_cut(pending)) {
                // The actual Device API returns false only before any cut launch.
                hs274_capture_.refuse_unlaunched_production(pending);
                stop_device_grabber();
              }
            } else if (action=="cancel") {
              hs274_capture_.cancel_production(peer_id,json.at("capture"),owner,reply);
              // Source cancellation is distinct from native aggregate terminal.
              stop_device_grabber();
              hs274_refresh_observation(hs274_observing);
            } else {
              const auto response=hs274_capture_.installed_request(peer_id,json.at("capture"),owner);
              if (action=="close") stop_device_grabber();
              hs274_refresh_observation(hs274_observing);
              owner->deliver([&](auto&) { reply(response); });
            }
            break;
          }
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

        case operation_type::observe_connected_devices:
          connected_devices_observer_peer_ids_.insert(peer_id);
          async_respond_connected_devices(peer_id,
                                          request_id);
          break;

        case operation_type::observe_notification_message:
          notification_message_observer_peer_ids_.insert(peer_id);
          async_respond_notification_message(peer_id,
                                             request_id);
          break;

        case operation_type::get_system_variables:
          if (device_grabber_) {
            device_grabber_->async_invoke_with_manipulator_environment(
                [this, peer_id, request_id](auto&& manipulator_environment) {
                  async_respond(
                      peer_id,
                      request_id,
                      nlohmann::json{
                          {"operation_type", operation_type::system_variables},
                          {
                              "system_variables",
                              {
                                  {
                                      "system.now.milliseconds",
                                      manipulator_environment.get_variable("system.now.milliseconds"),
                                  },
                                  {
                                      "system.scroll_direction_is_natural",
                                      manipulator_environment.get_variable("system.scroll_direction_is_natural"),
                                  },
                                  {
                                      "system.use_fkeys_as_standard_function_keys",
                                      manipulator_environment.get_variable("system.use_fkeys_as_standard_function_keys"),
                                  },
                              },

                              // Note:
                              // The accessibility.* variables contain information such as window titles,
                              // so they should not be exposed to other applications via the CLI
                              // and are therefore excluded from the return value.
                          }});
                });
          } else {
            async_respond_none(peer_id,
                               request_id);
          }
          break;

        case operation_type::get_multitouch_extension_variables:
          if (device_grabber_) {
            device_grabber_->async_invoke_with_manipulator_environment(
                [this, peer_id, request_id](auto&& manipulator_environment) {
                  std::unordered_map<std::string, manipulator_environment_variable_value> variables;
                  for (const auto& name : multitouch_extension_environment_variable_names) {
                    variables[name] = manipulator_environment.get_variable(name);
                  }

                  async_respond(peer_id,
                                request_id,
                                nlohmann::json{
                                    {"operation_type", operation_type::multitouch_extension_variables},
                                    {"multitouch_extension_variables", variables}});
                });
          } else {
            async_respond_none(peer_id,
                               request_id);
          }
          break;

        default:
          server_->async_close_peer(peer_id);
          break;
      }
    } catch (std::exception& e) {
      logger::get_logger()->error("received data is corrupted");
      server_->async_close_peer(peer_id);
    }
  }

  std::filesystem::path karabiner_core_service_daemon_socket_file_path() const {
    return constants::get_karabiner_core_service_daemon_socket_file_path();
  }

  void prepare_karabiner_core_service_daemon_socket_directory() const {
    filesystem_utility::prepare_system_directories(current_console_user_id_);
  }

  void start_grabbing_if_system_core_configuration_file_exists() {
    if (!required_permissions_granted()) {
      logger::get_logger()->info("device_grabber is not started because the required permissions are not granted.");
      return;
    }

    auto file_path = constants::get_system_core_configuration_file_path();
    if (filesystem_utility::exists(file_path)) {
      stop_device_grabber();
      start_device_grabber(std::nullopt);
    }
  }

  void start_device_grabber(const std::optional<std::string>& user_core_configuration_file_path) {
    if (device_grabber_ || owned_stop_pending()) {
      return;
    }

    if (!required_permissions_granted()) {
      logger::get_logger()->info("device_grabber is not started because the required permissions are not granted.");
      return;
    }

    const auto installed_location = ergoptiplus::installed_capture::local_fixed_core_location();
    if (!installed_location) throw std::logic_error("Core native location observation refused");
    std::shared_ptr<hs274_stream_protocol::runtime::capture_participant> participant;
    std::shared_ptr<device_grabber::active_cohort> storage;
    try {
      if (*installed_location) {
        if (!console_control_ || !console_control_->current())
          throw std::logic_error("Installed device start has no original Console control");
        participant = hs274_capture_.retain_constructor(hs274_capture_owner_, console_control_);
        if (!participant) throw std::logic_error("Installed Console namespace acquisition refused");
        constructing_owned_capture_ = participant;
        storage = device_grabber::preallocate_owned_cohort(console_control_, participant);
        if (!storage) throw std::logic_error("Native cohort storage allocation refused");
        if (!hs274_capture_.publish_constructor(participant))
          throw std::logic_error("Native constructor namespace publication refused");
      }

    if (auto m = weak_core_service_daemon_state_manager_.lock()) {
      m->reset_device_grabber_state();
    }

    if (participant) {
      device_grabber_ = device_grabber::construct_owned_device(console_user_server_peer_,
          weak_core_service_daemon_state_manager_, participant, storage);
      // Constructor adopted actual Device/broker before returning, even on
      // binding refusal. Shared-pointer assignments here cannot allocate.
      active_owned_cohort_ = storage;
      constructing_owned_capture_.reset();
      if (!device_grabber::bind_owned_cohort(storage, device_grabber_, participant) || !storage->current())
        throw std::logic_error("Constructed native cohort binding refused");
    } else {
    device_grabber_ = std::make_shared<device_grabber>(console_user_server_peer_,
                                                       weak_core_service_daemon_state_manager_);
    }

    connected_devices_changed_connection_ = device_grabber_->connected_devices_changed.connect([this, alive = std::weak_ptr<std::atomic_bool>(installed_receiver_alive_)] {
      const auto owner = alive.lock();
      if (!owner || !owner->load()) return;
      send_connected_devices_to_observers();
    });

    notification_message_changed_connection_ = device_grabber_->notification_message_changed.connect([this, alive = std::weak_ptr<std::atomic_bool>(installed_receiver_alive_)](const auto&) {
      const auto owner = alive.lock();
      if (!owner || !owner->load()) return;
      send_notification_message_to_observers();
    });

    device_grabber_->async_set_system_preferences_properties(system_preferences_properties_);
    device_grabber_->async_post_frontmost_application_changed_event(frontmost_application_);
    set_focused_ui_element_variables();
    device_grabber_->async_post_input_source_changed_event(input_source_properties_);
    update_temporarily_ignored_device_ids();

    device_grabber_->async_start(user_core_configuration_file_path,
                                 current_console_user_id_);

    logger::get_logger()->debug("device_grabber is started.");
    continue_pending_installed_prepare();
    } catch (...) {
      if (active_owned_cohort_) {
        stop_device_grabber();
      } else if (participant) {
        if (hs274_capture_.discard_unpublished_preparation(participant)) {
          constructing_owned_capture_.reset();
        } else {
          // Actual partial-constructor cleanup owns broker/Console/namespace
          // debt. An exception or receiver destruction is never its ACK.
          (void)hs274_capture_.request_constructor_retirement(participant, std::current_exception());
        }
      }
      throw;
    }
  }

  bool owned_stop_pending() {
    if (constructing_owned_capture_) {
      const auto status = hs274_capture_.constructor_retirement_status(constructing_owned_capture_);
      if (status != hs274_stream_protocol::runtime::constructor_failure_status::retired) return true;
      constructing_owned_capture_.reset();
    }
    if (!retiring_owned_cohort_) return false;
    if (!retiring_owned_cohort_->terminal()) return true;
    retiring_owned_cohort_.reset();
    return false;
  }

  void stop_device_grabber() {
    refuse_pending_installed_prepare();
    if (active_owned_cohort_) {
      // The genuine cohort owns itself and the SAME device until native terminal.
      // Receiver destruction or a command timeout cannot release those debts.
      active_owned_cohort_->request_retirement();
      retiring_owned_cohort_ = std::move(active_owned_cohort_);
    } else if (console_control_) {
      console_control_->request_retirement();
    }
    if (!device_grabber_) {
      return;
    }

    connected_devices_changed_connection_.disconnect();
    notification_message_changed_connection_.disconnect();
    device_grabber_ = nullptr;
    if (auto m = weak_core_service_daemon_state_manager_.lock()) {
      m->reset_device_grabber_state();
    }

    send_connected_devices_to_observers();
    send_notification_message_to_observers();

    logger::get_logger()->debug("device_grabber is stopped.");
  }

  void hs274_refresh_observation(bool previously_observing) {
    if (device_grabber_ && previously_observing != hs274_capture_.observing()) {
      // The queued grab reads current policy, including a successor preparation.
      device_grabber_->async_grab_devices();
    }
  }

  void update_temporarily_ignored_device_ids() {
    if (!device_grabber_) {
      return;
    }

    std::unordered_set<device_id> device_ids;
    for (const auto& device_id : temporarily_ignored_device_ids_by_peer_ | std::views::values) {
      device_ids.insert(device_id);
    }

    device_grabber_->async_set_temporarily_ignored_device_ids(device_ids);
  }

  [[nodiscard]] bool required_permissions_granted() const {
    if (auto m = weak_core_service_daemon_state_manager_.lock()) {
      if (auto result = m->copy_current_process_permission_check_result()) {
        return result->required_permissions_granted();
      }
    }

    return false;
  }

  void async_respond_connected_devices(pqrs::unix_domain_stream::peer_id peer_id,
                                       pqrs::unix_domain_stream::request_id request_id) {
    async_invoke_with_connected_devices_message(
        [this, peer_id, request_id](const auto& message) {
          async_respond(peer_id,
                        request_id,
                        message);
        });
  }

  void send_connected_devices_to_observers() {
    async_invoke_with_connected_devices_message(
        [this](const auto& message) {
          for (const auto& peer_id : connected_devices_observer_peer_ids_) {
            async_request(peer_id,
                          message);
          }
        });
  }

  void async_invoke_with_connected_devices_message(std::function<void(const nlohmann::json&)> function) {
    auto invoke = [function](const auto& connected_devices_json) {
      function(nlohmann::json{
          {"operation_type", operation_type::connected_devices},
          {"connected_devices", connected_devices_json},
      });
    };

    if (device_grabber_) {
      device_grabber_->async_invoke_with_connected_devices(invoke);
    } else {
      invoke(nlohmann::json::array());
    }
  }

  void async_respond_notification_message(pqrs::unix_domain_stream::peer_id peer_id,
                                          pqrs::unix_domain_stream::request_id request_id) {
    async_invoke_with_notification_message_message(
        [this, peer_id, request_id](const auto& message) {
          async_respond(peer_id,
                        request_id,
                        message);
        });
  }

  void send_notification_message_to_observers() {
    async_invoke_with_notification_message_message(
        [this](const auto& message) {
          for (const auto& peer_id : notification_message_observer_peer_ids_) {
            async_request(peer_id,
                          message);
          }
        });
  }

  void async_invoke_with_notification_message_message(std::function<void(const nlohmann::json&)> function) {
    auto invoke = [function](const auto& notification_message) {
      function(nlohmann::json{
          {"operation_type", operation_type::notification_message},
          {"notification_message", notification_message},
      });
    };

    if (device_grabber_) {
      device_grabber_->async_invoke_with_notification_message(invoke);
    } else {
      invoke("");
    }
  }

  void set_focused_ui_element_variables() {
    if (device_grabber_) {
      device_grabber_->async_post_set_variable_event(
          manipulator_environment_variable_set_variable(
              "accessibility.focused_ui_element.role_string",
              manipulator_environment_variable_value(focused_ui_element_.get_role().value_or("")),
              nullptr,
              std::nullopt,
              nullptr));

      device_grabber_->async_post_set_variable_event(
          manipulator_environment_variable_set_variable(
              "accessibility.focused_ui_element.subrole_string",
              manipulator_environment_variable_value(focused_ui_element_.get_subrole().value_or("")),
              nullptr,
              std::nullopt,
              nullptr));

      device_grabber_->async_post_set_variable_event(
          manipulator_environment_variable_set_variable(
              "accessibility.focused_ui_element.title_string",
              manipulator_environment_variable_value(focused_ui_element_.get_title().value_or("")),
              nullptr,
              std::nullopt,
              nullptr));

      device_grabber_->async_post_set_variable_event(
          manipulator_environment_variable_set_variable(
              "accessibility.focused_ui_element.window_title_string",
              manipulator_environment_variable_value(focused_ui_element_.get_window_title().value_or("")),
              nullptr,
              std::nullopt,
              nullptr));

      device_grabber_->async_post_set_variable_event(
          manipulator_environment_variable_set_variable(
              "accessibility.focused_ui_element.window_position_x",
              manipulator_environment_variable_value(
                  static_cast<int64_t>(focused_ui_element_.get_window_position_x().value_or(0))),
              nullptr,
              std::nullopt,
              nullptr));

      device_grabber_->async_post_set_variable_event(
          manipulator_environment_variable_set_variable(
              "accessibility.focused_ui_element.window_position_y",
              manipulator_environment_variable_value(
                  static_cast<int64_t>(focused_ui_element_.get_window_position_y().value_or(0))),
              nullptr,
              std::nullopt,
              nullptr));

      device_grabber_->async_post_set_variable_event(
          manipulator_environment_variable_set_variable(
              "accessibility.focused_ui_element.window_size_width",
              manipulator_environment_variable_value(
                  static_cast<int64_t>(focused_ui_element_.get_window_size_width().value_or(0))),
              nullptr,
              std::nullopt,
              nullptr));

      device_grabber_->async_post_set_variable_event(
          manipulator_environment_variable_set_variable(
              "accessibility.focused_ui_element.window_size_height",
              manipulator_environment_variable_value(
                  static_cast<int64_t>(focused_ui_element_.get_window_size_height().value_or(0))),
              nullptr,
              std::nullopt,
              nullptr));
    }
  }

  void send_core_service_daemon_state(const core_service_daemon_state& core_service_daemon_state) {
    if (console_user_server_peer_) {
      console_user_server_peer_->async_core_service_daemon_state(core_service_daemon_state);
    }
  }

  void request_core_service_bundle_permission_check_result_refresh() {
    if (!core_service_agent_peer_id_) {
      return;
    }

    async_request(
        *core_service_agent_peer_id_,
        nlohmann::json{
            {"operation_type", operation_type::refresh_core_service_bundle_permission_check_result},
        });
  }

  void clear_multitouch_extension_environment_variables() {
    if (device_grabber_) {
      for (const auto& name : multitouch_extension_environment_variable_names) {
        device_grabber_->async_post_set_variable_event(
            manipulator_environment_variable_set_variable(
                name,
                std::nullopt,
                nullptr,
                std::nullopt,
                nullptr,
                manipulator_environment_variable_set_variable::type::unset));
      }
    }
  }

  static constexpr std::array multitouch_extension_environment_variable_names{
      "multitouch_extension_finger_count_upper_quarter_area",
      "multitouch_extension_finger_count_lower_quarter_area",
      "multitouch_extension_finger_count_left_quarter_area",
      "multitouch_extension_finger_count_right_quarter_area",
      "multitouch_extension_finger_count_upper_half_area",
      "multitouch_extension_finger_count_lower_half_area",
      "multitouch_extension_finger_count_left_half_area",
      "multitouch_extension_finger_count_right_half_area",
      "multitouch_extension_finger_count_total",
      "multitouch_extension_palm_count_upper_half_area",
      "multitouch_extension_palm_count_lower_half_area",
      "multitouch_extension_palm_count_left_half_area",
      "multitouch_extension_palm_count_right_half_area",
      "multitouch_extension_palm_count_total",
  };

  std::shared_ptr<ergoptiplus::installed_maintenance::core_endpoint> maintenance_endpoint_;
  std::shared_ptr<std::atomic_bool> installed_receiver_alive_=std::make_shared<std::atomic_bool>(true);
  std::shared_ptr<pending_installed_prepare> pending_installed_prepare_;
  std::shared_ptr<ergoptiplus::installed_capture::core_peer_owner> installed_retirement_request_;
  std::shared_ptr<ergoptiplus::installed_capture::core_peer_owner> installed_suspension_request_;
  std::shared_ptr<ergoptiplus::installed_capture::core_peer_owner> installed_configuration_request_;
  const std::shared_ptr<hs274_stream_protocol::runtime> hs274_capture_owner_ =
      std::make_shared<hs274_stream_protocol::runtime>();
  hs274_stream_protocol::runtime& hs274_capture_ = *hs274_capture_owner_;

  std::optional<uid_t> current_console_user_id_;
  std::weak_ptr<core_service_daemon_state_manager> weak_core_service_daemon_state_manager_;
  nod::scoped_connection core_service_daemon_state_manager_connection_;

  std::shared_ptr<pqrs::unix_domain_stream::server> server_;
  std::shared_ptr<device_grabber> device_grabber_;
  std::shared_ptr<ergoptiplus::remap::auth::console_control_owner> console_control_;
  std::shared_ptr<hs274_stream_protocol::runtime::capture_participant> constructing_owned_capture_;
  std::shared_ptr<device_grabber::active_cohort> active_owned_cohort_;
  std::shared_ptr<device_grabber::active_cohort> retiring_owned_cohort_;
  nod::scoped_connection connected_devices_changed_connection_;
  nod::scoped_connection notification_message_changed_connection_;
  std::optional<pqrs::unix_domain_stream::peer_id> core_service_agent_peer_id_;
  std::optional<pqrs::unix_domain_stream::peer_id> console_user_server_peer_id_;
  std::shared_ptr<console_user_server_peer> console_user_server_peer_;
  std::optional<pqrs::unix_domain_stream::peer_id> multitouch_extension_peer_id_;
  std::unordered_map<pqrs::unix_domain_stream::peer_id, device_id> temporarily_ignored_device_ids_by_peer_;
  std::unordered_set<pqrs::unix_domain_stream::peer_id> connected_devices_observer_peer_ids_;
  std::unordered_set<pqrs::unix_domain_stream::peer_id> notification_message_observer_peer_ids_;

  pqrs::osx::system_preferences::properties system_preferences_properties_;
  application frontmost_application_;
  focused_ui_element focused_ui_element_;
  pqrs::osx::input_source::properties input_source_properties_;
};
} // namespace krbn::core_service::daemon

#include "OwnedRuntimeMaintenanceCoreEndpointBody.hpp"
