# tools/build/remap_runtime_auth_transport.py
"""Pure, fixed owned-profile vendor composition; no acquisition or authority."""

import hashlib
import math
import re
import time
from pathlib import PurePosixPath as Path

INPUT_PATHS = (
    "vendor/vendor/include/pqrs/unix_domain_stream/impl/peer.hpp",
    "vendor/vendor/include/pqrs/unix_domain_stream/client.hpp",
    "vendor/vendor/include/pqrs/unix_domain_stream/impl/request_manager.hpp",
    "vendor/vendor/include/pqrs/unix_domain_stream/server.hpp",
    "vendor/vendor/include/pqrs/unix_domain_stream/types.hpp",
    "src/apps/CoreService/include/core_service/daemon/receiver.hpp",
    "src/apps/ConsoleUserServer/include/console_user_server/receiver.hpp",
    "src/share/core_service_daemon_client.hpp",
    "src/share/console_user_server_client.hpp",
    "src/apps/CoreService/include/core_service/daemon/console_user_id_changed_receiver.hpp",
    "src/apps/ConsoleUserServer/include/console_user_server/console_user_id_changed_client.hpp",
)
AUTH_HEADER_SHA256 = "6ecee6a85daf61005b67b58bff527fef0d3d54a88156407792698817003f150d"


class AuthTransportRefusal(RuntimeError):
    """The fixed source composition cannot be admitted."""


def _deadline(absolute_deadline: float) -> None:
    if type(absolute_deadline) not in (int, float) or not math.isfinite(absolute_deadline):
        raise AuthTransportRefusal("auth_transport_deadline_refused")
    if time.monotonic() >= absolute_deadline:
        raise AuthTransportRefusal("auth_transport_deadline_expired")


def _peer(source):

    def one(old, new):
        nonlocal source
        if source.count(old) != 1:
            raise RuntimeError(f"anchor count {source.count(old)}: {old[:70]}")
        source = source.replace(old, new)

    one('#include "../options.hpp"', '#include "../options.hpp"\n#include "remap_runtime_auth.hpp"')
    one(
        "const common_options& options)\n",
        "const common_options& options,\n       std::optional<std::shared_ptr<ergoptiplus::remap::auth::socket_lifetime>> owned = std::nullopt)\n",
    )
    one(
        "options_(options),\n",
        "options_(options),\n        owned_executor_(socket_.get_executor()),\n        owned_selected_(owned.has_value()),\n        owned_socket_(owned.value_or(nullptr)),\n",
    )
    one(
        "          self->start_ready_deadline();",
        "          self->ensure_owned_ports();\n          if (self->owned_selected_ && (!self->owned_socket_ || !self->owned_socket_->current())) {\n            self->close();\n            return;\n          }\n          if (self->owned_selected_ && self->owned_socket_->health_only_.value_or(false)) {\n            self->read_header();\n            return;\n          }\n          self->start_ready_deadline();",
    )
    one(
        "  void async_close(std::function<void()> completion = nullptr) {\n    asio::post(",
        "  void async_close(std::function<void()> completion = nullptr) {\n    if (owned_socket_) owned_socket_->revoke();\n    asio::post(",
    )
    one(
        "          self->close();\n          if (completion) {",
        "          if (self->owned_selected_ && self->owned_socket_) {\n            self->ensure_owned_ports();\n            // A repeated caller may observe a genuinely completed old socket;\n            // this cannot reopen its channel, FD, identity or positive ports.\n            if (self->owned_socket_->completed()) {\n              if (completion) completion();\n              return;\n            }\n            if (completion) self->owned_close_observers_.push_back(std::move(completion));\n            self->close();\n            return;\n          }\n          self->close();\n          if (completion) {",
    )
    one(
        "private:\n  void async_push_frame",
        "private:\n  friend class client_state;\n  friend class server_state;\n  using owned_scope = ergoptiplus::remap::auth::frame_scope;\n  using owned_ticket = ergoptiplus::remap::auth::delivery_ticket;\n  using owned_handler = std::function<void(owned_scope&)>;\n  owned_handler owned_ready_;\n  owned_handler owned_received_;\n  owned_handler owned_request_received_;\n  owned_handler owned_response_received_;\n  owned_handler owned_health_response_;\n  bool owned_ports_installed_ = false;\n  bool owned_closed_notification_ = false;\n  std::vector<std::function<void()>> owned_close_observers_;\n\n  template<class F> auto owned_native(F function) {\n    auto debt = owned_socket_ ? owned_socket_->retain_task(\n        ergoptiplus::remap::auth::socket_lifetime::task_kind::native) : nullptr;\n    return [function = std::move(function), debt = std::move(debt)](auto&&... arguments) mutable {\n      function(std::forward<decltype(arguments)>(arguments)...);\n    };\n  }\n  bool enqueue_owned(const std::shared_ptr<owned_ticket>& ticket, owned_handler handler) {\n    if (!owned_socket_ || !ticket || !handler) {\n      if (owned_socket_) owned_socket_->revoke();\n      return false;\n    }\n    auto debt = owned_socket_->retain_task(\n        ergoptiplus::remap::auth::socket_lifetime::task_kind::dispatch);\n    if (!debt) { owned_socket_->revoke(); return false; }\n    try {\n      if (!enqueue_to_dispatcher([ticket, handler = std::move(handler), debt = std::move(debt)] {\n            ticket->consume(handler);\n          })) { owned_socket_->revoke(); return false; }\n    } catch (...) { owned_socket_->revoke(); throw; }\n    return true;\n  }\n  void ensure_owned_ports() {\n    if (!owned_socket_ || owned_ports_installed_) return;\n    owned_ports_installed_ = true;\n    auto self = shared_from_this();\n    if (owned_socket_->has_staged_ports()) {\n      if (!owned_socket_->transfer_close_ports(socket_,\n          [self] { self->owned_close_on_executor(); },\n          [self] { self->owned_completed_on_executor(); })) return;\n    } else {\n      owned_socket_->set_close_ports(\n          [self] { asio::post(self->owned_executor_, [self] { self->owned_close_on_executor(); }); },\n          [self] { self->owned_completed_on_executor(); });\n    }\n    owned_socket_->request_close();\n  }\n  void owned_completed_on_executor() {\n    closed_on_executor_ = true;\n    auto observers = std::exchange(owned_close_observers_, {});\n    for (auto& observer : observers) observer();\n    if (owned_closed_notification_) return;\n    owned_closed_notification_ = true;\n    auto debt = owned_socket_->retain_task(\n        ergoptiplus::remap::auth::socket_lifetime::task_kind::dispatch);\n    if (!debt || !enqueue_to_dispatcher([self = shared_from_this(), debt = std::move(debt)] { self->closed(); }))\n      owned_socket_->fail_cleanup();\n  }\n  void owned_close_on_executor() {\n    ready_deadline_.cancel();\n    heartbeat_timer_.cancel();\n    heartbeat_deadline_.cancel();\n    read_deadline_.cancel();\n    write_deadline_.cancel();\n    if (owned_socket_->close_native(socket_)) owned_socket_->finish_close();\n  }\n  void async_push_frame",
    )
    one(
        "    asio::post(\n        socket_.get_executor(),\n        [self = shared_from_this(), frame = std::move(frame)]() mutable {\n          self->push_frame",
        "    if (owned_selected_ && (!owned_socket_ || !owned_socket_->current())) {\n      if (owned_socket_) owned_socket_->revoke();\n      return;\n    }\n    asio::post(\n        socket_.get_executor(),\n        [self = shared_from_this(), frame = std::move(frame)]() mutable {\n          self->ensure_owned_ports();\n          self->push_frame",
    )
    one(
        "  void ensure_ready() {\n    if (ready_) {",
        "  void ensure_ready() {\n    if (owned_selected_) {\n      if (!owned_socket_ || !owned_socket_->current()) { close(); return; }\n      if (owned_socket_->health_only_.value_or(false)) return;\n    }\n    if (ready_) {",
    )
    one(
        "    enqueue_to_dispatcher([this] {\n      ready();\n    });",
        "    if (owned_selected_) {\n      enqueue_owned(owned_socket_->ticket(ergoptiplus::remap::auth::frame_kind::connected, 0, {}), owned_ready_);\n    } else {\n      enqueue_to_dispatcher([this] {\n        ready();\n      });\n    }",
    )
    for anchor in [
        "  void read_header() {",
        "  void read_body() {",
        "  void push_frame(std::vector<uint8_t> frame) {",
        "  void write() {",
    ]:
        one(
            anchor,
            anchor
            + "\n    if (owned_selected_ && (!owned_socket_ || !owned_socket_->current())) { close(); return; }",
        )
    one(
        "          self->refresh_heartbeat_deadline();\n\n          auto type",
        "          if (self->owned_selected_ && (!self->owned_socket_ || !self->owned_socket_->current())) {\n            self->close();\n            return;\n          }\n          self->refresh_heartbeat_deadline();\n\n          auto type",
    )
    one(
        "              self->enqueue_to_dispatcher([p = self.get(), v] {\n                p->received(v);\n              });",
        "              if (self->owned_selected_) {\n                self->enqueue_owned(self->owned_socket_->ticket(\n                    ergoptiplus::remap::auth::frame_kind::user_data, 0, *v), self->owned_received_);\n              } else {\n                self->enqueue_to_dispatcher([p = self.get(), v] {\n                  p->received(v);\n                });\n              }",
    )
    one(
        "              if (type == protocol::message_type::request) {\n                self->enqueue_to_dispatcher",
        "              if (self->owned_selected_) {\n                const auto kind = type == protocol::message_type::request\n                    ? ergoptiplus::remap::auth::frame_kind::request\n                    : ergoptiplus::remap::auth::frame_kind::response;\n                self->enqueue_owned(self->owned_socket_->ticket(kind, request_id, *v),\n                    type == protocol::message_type::request ? self->owned_request_received_\n                                                           : self->owned_response_received_);\n              } else if (type == protocol::message_type::request) {\n                self->enqueue_to_dispatcher",
    )
    one(
        "          auto type = static_cast<protocol::message_type>(self->read_body_[0]);\n          switch (type) {",
        "          auto type = static_cast<protocol::message_type>(self->read_body_[0]);\n          if (self->owned_selected_ && self->owned_socket_->health_only_.value_or(false) &&\n              type != protocol::message_type::health_check && type != protocol::message_type::health_check_response) {\n            self->handle_error(asio::error::operation_not_supported);\n            return;\n          }\n          switch (type) {",
    )
    one(
        "            case protocol::message_type::health_check:\n              if (self->ready_) {",
        "            case protocol::message_type::health_check:\n              if (self->owned_selected_ &&\n                  (!self->owned_socket_->health_only_.value_or(false) || self->read_body_.size() != protocol::type_size)) {\n                self->handle_error(asio::error::operation_not_supported);\n                return;\n              }\n              if (self->ready_) {",
    )
    one(
        "            case protocol::message_type::health_check_response:\n              self->enqueue_to_dispatcher([p = self.get()] {\n                p->health_check_response_received();\n              });",
        "            case protocol::message_type::health_check_response:\n              if (self->owned_selected_) {\n                if (!self->owned_socket_->health_only_.value_or(false) || self->read_body_.size() != protocol::type_size) {\n                  self->handle_error(asio::error::operation_not_supported);\n                  return;\n                }\n                self->enqueue_owned(self->owned_socket_->ticket(\n                    ergoptiplus::remap::auth::frame_kind::health_check_response, 0, {}), self->owned_health_response_);\n              } else {\n                self->enqueue_to_dispatcher([p = self.get()] {\n                  p->health_check_response_received();\n                });\n              }",
    )
    one(
        "    if (!valid_outgoing_frame(frame) ||",
        "    if (owned_selected_ && owned_socket_->health_only_.value_or(false)) {\n      if (frame.size() != protocol::header_size + protocol::type_size ||\n          (static_cast<protocol::message_type>(frame[protocol::header_size]) != protocol::message_type::health_check &&\n           static_cast<protocol::message_type>(frame[protocol::header_size]) != protocol::message_type::health_check_response)) {\n        handle_error(asio::error::operation_not_supported);\n        return;\n      }\n    }\n    if (!valid_outgoing_frame(frame) ||",
    )
    one(
        "          self->write_queue_.pop_front();",
        "          if (self->owned_selected_ && (!self->owned_socket_ || !self->owned_socket_->current())) {\n            self->close();\n            return;\n          }\n          self->write_queue_.pop_front();",
    )
    one(
        "  void close() {\n    const auto socket_was_open",
        "  void close() {\n    if (owned_selected_ && owned_socket_) {\n      ensure_owned_ports();\n      owned_socket_->revoke();\n      return;\n    }\n    const auto socket_was_open",
    )
    one(
        "  common_options options_;\n",
        "  common_options options_;\n  const asio::any_io_executor owned_executor_;\n  const bool owned_selected_;\n  const std::shared_ptr<ergoptiplus::remap::auth::socket_lifetime> owned_socket_;\n",
    )
    for call in [".async_wait(", "asio::async_read(", "asio::async_write("]:
        start = 0
        while True:
            at = source.find(call, start)
            if at < 0:
                break
            begin = source.find("[self = shared_from_this()]", at)
            if begin < 0:
                raise RuntimeError("missing native handler")
            brace = source.find("{", begin)
            depth = 1
            j = brace + 1
            while depth:
                if source[j] == "{":
                    depth += 1
                if source[j] == "}":
                    depth -= 1
                j += 1
            handler = source[begin:j]
            source = source[:begin] + "owned_native(" + handler + ")" + source[j:]
            start = j + len("owned_native()")
    return source


def _client(source):

    def one(old, new):
        nonlocal source
        if source.count(old) != 1:
            raise RuntimeError(f"anchor count {source.count(old)} {old[:60]}")
        source = source.replace(old, new)

    one(
        "std::function<bool(const peer_credentials&)> verify_peer)\n",
        "std::function<bool(const peer_credentials&)> verify_peer,\n               std::optional<std::shared_ptr<ergoptiplus::remap::auth::channel_owner>> owned = std::nullopt)\n",
    )
    one(
        "        verify_peer_(verify_peer),",
        "        verify_peer_(verify_peer),\n        owned_selected_(owned.has_value()),\n        owned_channel_(owned.value_or(nullptr)),",
    )
    one(
        "                         *this) {",
        "                         *this,\n                         owned_channel_) {",
    )
    one(
        "  void async_shutdown() {\n",
        "  void async_shutdown() {\n    if (owned_channel_) { owned_channel_->revoke(); owned_channel_->schedule_closures(); }\n",
    )
    one(
        "  void async_stop() {\n",
        "  void async_stop() {\n    if (owned_channel_) { owned_channel_->revoke(); owned_channel_->schedule_closures(); }\n",
    )
    one(
        "  void connect() {\n    auto weak_self",
        "  void connect() {\n    if (owned_selected_ && (!owned_channel_ || !owned_channel_->current_gate())) return;\n    auto owned_constructor = owned_channel_ ? owned_channel_->retain_construction() : nullptr;\n    if (owned_selected_ && !owned_constructor) return;\n    auto weak_self",
    )
    one(
        "[weak_self, notification_token] {\n          auto self = weak_self.lock();\n          if (!self ||",
        "[weak_self, notification_token, owned_constructor] {\n          auto self = weak_self.lock();\n          if (!self ||\n              (self->owned_selected_ && (!self->owned_channel_ || !self->owned_channel_->current_gate())) ||",
    )
    one(
        "[self, socket, notification_token](auto&& error_code) mutable {",
        "[self, socket, notification_token, owned_constructor](auto&& error_code) mutable {",
    )
    one(
        "                auto credentials = impl::make_peer_credentials(*socket);\n",
        "                std::shared_ptr<ergoptiplus::remap::auth::socket_lifetime> owned;\n                if (self->owned_selected_) {\n                  owned = ergoptiplus::remap::auth::socket_lifetime::bind(self->owned_channel_, socket->native_handle());\n                  if (!owned) {\n                    self->owned_channel_->revoke();\n                    self->owned_channel_->schedule_closures();\n                    asio::error_code refused;\n                    socket->close(refused);\n                    self->connecting_socket_.reset();\n                    return;\n                  }\n                  owned->set_staged_ports(socket.get());\n                  self->connecting_owned_ = owned;\n                }\n                auto owned_dispatch = owned ? owned->retain_task(\n                    ergoptiplus::remap::auth::socket_lifetime::task_kind::dispatch) : nullptr;\n                auto credentials = impl::make_peer_credentials(*socket);\n",
    )
    one(
        "[self, socket, credentials, notification_token] {\n                          auto verified = self->verify_peer_(credentials);",
        "[self, socket, credentials, notification_token, owned, owned_dispatch, owned_constructor] {\n                          auto verified = self->owned_selected_ ? owned && owned->current()\n                                                               : self->verify_peer_(credentials);",
    )
    one(
        "[self, socket, credentials, verified, notification_token] {",
        "[self, socket, credentials, verified, notification_token, owned, owned_dispatch, owned_constructor] {",
    )
    one(
        "                                                              notification_token);\n",
        "                                                              notification_token,\n                                                              owned);\n",
    )
    one(
        "                  self->connecting_socket_.reset();\n\n                  asio::error_code close_error_code;\n                  socket->close(close_error_code);\n                }\n",
        "                  self->connecting_socket_.reset();\n                  if (owned) owned->revoke();\n                  else {\n                    asio::error_code close_error_code;\n                    socket->close(close_error_code);\n                  }\n                }\n",
    )
    one(
        "    if (connecting_socket_) {\n      asio::error_code close_error_code;\n      connecting_socket_->close(close_error_code);",
        "    if (connecting_socket_) {\n      if (connecting_owned_) {\n        connecting_owned_->revoke();\n        connecting_owned_.reset();\n      } else {\n        asio::error_code close_error_code;\n        connecting_socket_->close(close_error_code);\n      }",
    )
    one(
        "                               notification_scope::token notification_token) {\n",
        "                               notification_scope::token notification_token,\n                               std::shared_ptr<ergoptiplus::remap::auth::socket_lifetime> owned = nullptr) {\n",
    )
    a = source.index("  void handle_connected_socket(")
    b = source.index("    not_null_shared_ptr_t<impl::peer> p(", a)
    head = source[a:b]
    head = head.replace(
        "      asio::error_code close_error_code;\n      socket->close(close_error_code);",
        "      if (owned) owned->revoke();\n      else {\n        asio::error_code close_error_code;\n        socket->close(close_error_code);\n      }",
    )
    head = head.replace(
        "    connecting_socket_.reset();",
        "    connecting_socket_.reset();\n    connecting_owned_.reset();",
    )
    head = head.replace(
        "    if (!verified) {",
        "    if (!verified || (owned_selected_ && (!owned || !owned->current()))) {",
    )
    source = source[:a] + head + source[b:]
    one(
        "                                                                     options_));",
        "                                                                     options_,\n                                                                     owned_selected_ ? std::optional{owned} : std::nullopt));",
    )
    one(
        "    p->async_start();\n\n    asio::post(",
        "    if (owned_selected_) {\n      p->ensure_owned_ports();\n      p->owned_ready_ = [](ergoptiplus::remap::auth::frame_scope&) {};\n      p->owned_received_ = [weak_self, weak_p, notification_token](ergoptiplus::remap::auth::frame_scope& scope) {\n        if (auto self = weak_self.lock()) self->forward_owned(scope, weak_p, notification_token, false);\n      };\n      p->owned_request_received_ = [weak_self, weak_p, notification_token](ergoptiplus::remap::auth::frame_scope& scope) {\n        if (auto self = weak_self.lock()) self->forward_owned(scope, weak_p, notification_token, true);\n      };\n      p->owned_response_received_ = [weak_self, weak_p](ergoptiplus::remap::auth::frame_scope& scope) {\n        auto ticket = scope.handoff();\n        const auto id = scope.view().request_id();\n        if (auto self = weak_self.lock(); self && ticket) {\n          asio::post(self->io_ctx_, [self, weak_p, id, ticket] {\n            auto p = weak_p.lock();\n            if (p && self->peer_ == p) self->request_manager_.complete_owned(id, ticket);\n          });\n        }\n      };\n    }\n    p->async_start();\n\n    asio::post(",
    )
    one(
        "            self->notification_scope_.enqueue(\n                notification_token,\n                [self, credentials] {\n                  self->connected(credentials);\n                });",
        "            if (self->owned_selected_) {\n              auto ticket = p->owned_socket_->ticket(ergoptiplus::remap::auth::frame_kind::connected, 0, {});\n              if (!ticket || !self->notification_scope_.enqueue(notification_token, [self, p, ticket] {\n                    if (self->peer_ == p) ticket->consume(self->owned_connected_);\n                  })) {\n                self->owned_channel_->revoke();\n                self->owned_channel_->schedule_closures();\n              }\n            } else {\n              self->notification_scope_.enqueue(\n                  notification_token,\n                  [self, credentials] {\n                    self->connected(credentials);\n                  });\n            }",
    )
    one(
        "private:\n  friend class client_test_access;",
        "private:\n  friend class client_test_access;\n  friend class ::pqrs::unix_domain_stream::client;\n  using owned_scope = ergoptiplus::remap::auth::frame_scope;\n  using owned_handler = std::function<void(owned_scope&)>;\n  owned_handler owned_connected_;\n  owned_handler owned_received_;\n  owned_handler owned_request_received_;\n  bool bind_owned(owned_handler& slot, owned_handler handler) {\n    if (!owned_selected_ || !owned_channel_ || !handler || slot) {\n      if (owned_channel_) { owned_channel_->revoke(); owned_channel_->schedule_closures(); }\n      return false;\n    }\n    slot = std::move(handler);\n    return true;\n  }\n  void forward_owned(owned_scope& scope, std::weak_ptr<peer> weak_p,\n                     notification_scope::token token, bool request) {\n    auto ticket = scope.handoff();\n    if (!ticket) return;\n    auto self = shared_from_this();\n    asio::post(io_ctx_, [self, weak_p, ticket, token, request] {\n      auto p = weak_p.lock();\n      if (!p || self->peer_ != p) return;\n      if (!self->notification_scope_.enqueue(token, [self, ticket, request] {\n            ticket->consume(request ? self->owned_request_received_ : self->owned_received_);\n          })) {\n        self->owned_channel_->revoke();\n        self->owned_channel_->schedule_closures();\n      }\n    });\n  }",
    )
    one(
        "  std::function<bool(const peer_credentials&)> verify_peer_;\n",
        "  std::function<bool(const peer_credentials&)> verify_peer_;\n  const bool owned_selected_;\n  const std::shared_ptr<ergoptiplus::remap::auth::channel_owner> owned_channel_;\n  std::shared_ptr<ergoptiplus::remap::auth::socket_lifetime> connecting_owned_;\n",
    )
    one(
        "  bool close_peer(const asio::error_code& pending_request_error_code) {\n    if (peer_) {",
        "  bool close_peer(const asio::error_code& pending_request_error_code) {\n    if (peer_) {",
    )
    one(
        "std::function<bool(const peer_credentials&)> verify_peer = default_client_verify_peer)",
        "std::function<bool(const peer_credentials&)> verify_peer = default_client_verify_peer,\n         std::optional<std::shared_ptr<ergoptiplus::remap::auth::channel_owner>> owned = std::nullopt)",
    )
    one(
        "                                                    std::move(verify_peer))),",
        "                                                    std::move(verify_peer),\n                                                    std::move(owned))),",
    )
    one(
        "  ~client() override {",
        "  // Fixed selected wrapper consumers. Registration ACK is not authentication.\n  bool set_owned_connected(std::function<void(ergoptiplus::remap::auth::frame_scope&)> handler) {\n    return state_->bind_owned(state_->owned_connected_, std::move(handler));\n  }\n  bool set_owned_received(std::function<void(ergoptiplus::remap::auth::frame_scope&)> handler) {\n    return state_->bind_owned(state_->owned_received_, std::move(handler));\n  }\n  bool set_owned_request_received(std::function<void(ergoptiplus::remap::auth::frame_scope&)> handler) {\n    return state_->bind_owned(state_->owned_request_received_, std::move(handler));\n  }\n  ~client() override {",
    )
    one(
        "                     async_request_callback callback) {\n    auto weak_self = weak_from_this();",
        "                     async_request_callback callback,\n                     owned_async_request_callback owned_callback = nullptr) {\n    auto weak_self = weak_from_this();",
    )
    one(
        "                     owned_async_request_callback owned_callback = nullptr) {\n    auto weak_self",
        "                     owned_async_request_callback owned_callback = nullptr) {\n    auto owned_request = owned_channel_ ? owned_channel_->retain_construction() : nullptr;\n    if (owned_selected_ && !owned_request) return;\n    auto weak_self",
    )
    one(
        "[weak_self, data, timeout, callback] {",
        "[weak_self, data, timeout, callback, owned_callback, owned_request] {",
    )
    one(
        "                             callback);\n        });",
        "                             callback,\n                             owned_callback, owned_request);\n        });",
    )
    one(
        "                    async_request_callback callback) {\n    if (!peer_) {",
        "                    async_request_callback callback,\n                    owned_async_request_callback owned_callback = nullptr,\n                    std::shared_ptr<ergoptiplus::remap::auth::channel_owner::construction_marker> owned_request = nullptr) {\n    if (!peer_) {",
    )
    one(
        "      enqueue_to_dispatcher([callback] {\n        callback(asio::error::not_connected,\n                 nullptr);\n      });",
        "      enqueue_to_dispatcher([callback, owned_callback, owned_request] {\n        if (owned_callback) owned_callback(asio::error::not_connected, nullptr);\n        else callback(asio::error::not_connected, nullptr);\n      });",
    )
    one(
        "    auto id = request_manager_.add(std::nullopt,",
        '    std::optional<std::string> request_operation;\n    if (owned_selected_) {\n      try {\n        const auto parsed = nlohmann::json::from_msgpack(data);\n        if (!parsed.is_object() || !parsed.contains("operation_type") || !parsed.at("operation_type").is_string()) {\n          owned_channel_->revoke(); owned_channel_->schedule_closures(); return;\n        }\n        request_operation = parsed.at("operation_type").get<std::string>();\n      } catch (...) { owned_channel_->revoke(); owned_channel_->schedule_closures(); return; }\n    }\n    auto id = request_manager_.add(std::nullopt,',
    )
    one(
        "                                   });\n\n    peer_->async_send_request",
        "                                   }, owned_callback, request_operation, owned_request);\n\n    if (owned_selected_ && id == 0) return;\n    peer_->async_send_request",
    )
    one(
        "  void async_request(const std::vector<uint8_t>& data,\n                     async_request_callback callback) const {",
        "  void async_request_owned(const std::vector<uint8_t>& data,\n                           owned_async_request_callback callback) const {\n    state_->async_request(data, state_->options_.read_timeout, nullptr, std::move(callback));\n  }\n\n  void async_request(const std::vector<uint8_t>& data,\n                     async_request_callback callback) const {",
    )
    return source


def _request(source):

    def one(old, new):
        nonlocal source
        if source.count(old) != 1:
            raise RuntimeError(f"anchor {source.count(old)} {old[:60]}")
        source = source.replace(old, new)

    one(
        '#include "../types.hpp"',
        '#include "../types.hpp"\n#include "remap_runtime_auth.hpp"\n#include <limits>',
    )
    one(
        "dispatcher::extra::dispatcher_client& dispatcher_client)\n",
        "dispatcher::extra::dispatcher_client& dispatcher_client,\n                  std::shared_ptr<ergoptiplus::remap::auth::channel_owner> owned = nullptr)\n",
    )
    one(
        "        dispatcher_client_(dispatcher_client) {",
        "        dispatcher_client_(dispatcher_client), owned_channel_(std::move(owned)) {",
    )
    one(
        "                 std::function<void()> timeout_callback = nullptr) {",
        "                 std::function<void()> timeout_callback = nullptr,\n                 owned_async_request_callback owned_callback = nullptr,\n                 std::optional<std::string> request_operation = std::nullopt,\n                 std::shared_ptr<ergoptiplus::remap::auth::channel_owner::construction_marker> inherited_debt = nullptr) {",
    )
    one(
        "    auto id = ++next_request_id_;",
        "    if (owned_channel_ && next_request_id_ == std::numeric_limits<request_id>::max()) {\n      owned_channel_->revoke();\n      owned_channel_->schedule_closures();\n      callback_error(std::move(request_callback), asio::error::no_buffer_space, std::move(owned_callback));\n      return 0;\n    }\n    auto id = ++next_request_id_;",
    )
    one(
        "    if (owned_channel_ && next_request_id_",
        "    auto owned_debt = inherited_debt ? std::move(inherited_debt) :\n                      owned_channel_ ? owned_channel_->retain_construction() : nullptr;\n    if (owned_channel_ && (!owned_debt || !owned_channel_->current_gate())) {\n      if (owned_debt) callback_error(std::move(request_callback), asio::error::operation_aborted,\n                                     std::move(owned_callback), owned_debt);\n      return 0;\n    }\n    if (owned_channel_ && next_request_id_",
    )
    one(
        "std::move(owned_callback));\n      return 0;",
        "std::move(owned_callback), owned_debt);\n      return 0;",
    )
    one(
        "[this, id, timeout_callback](const auto& error_code) {",
        "[this, id, timeout_callback, owned_debt](const auto& error_code) {",
    )
    one(
        "                                  .callback = request_callback,",
        "                                  .callback = request_callback,\n                                  .owned_callback = std::move(owned_callback),\n                                  .request_operation = std::move(request_operation),\n                                  .owned_debt = owned_debt,",
    )
    one(
        "private:\n  struct pending_request",
        '  // The exact response ticket survives pending extraction and dispatcher queue.\n  // Error/cancellation continues to use the unchanged no-payload error path.\n  void complete_owned(request_id id,\n                      std::shared_ptr<ergoptiplus::remap::auth::delivery_ticket> ticket) {\n    if (auto node = pending_requests_.extract(id); !node.empty()) {\n      auto request = std::move(node.mapped());\n      request.timer->cancel();\n      auto owner = owned_channel_;\n      if (!ticket || !dispatcher_client_.enqueue_to_dispatcher([request = std::move(request), ticket, id, owner] {\n            ticket->consume([&](ergoptiplus::remap::auth::frame_scope& scope) {\n              if (scope.view().kind() != ergoptiplus::remap::auth::frame_kind::response ||\n                  scope.view().request_id() != id ||\n                  (scope.view().payload().empty() && request.request_operation != "console_user_id_changed")) {\n                if (owner) { owner->revoke(); owner->schedule_closures(); }\n                return;\n              }\n              if (request.owned_callback) request.owned_callback(asio::error_code(), &scope);\n              else request.callback(asio::error_code(),\n                  std::make_shared<std::vector<std::uint8_t>>(scope.view().payload()));\n            });\n          })) {\n        if (owned_channel_) { owned_channel_->revoke(); owned_channel_->schedule_closures(); }\n      }\n    }\n  }\n  void complete_owned(peer_id peer, request_id id,\n                      std::shared_ptr<ergoptiplus::remap::auth::delivery_ticket> ticket) {\n    if (auto it = pending_requests_.find(id); it == pending_requests_.end() || it->second.peer_id_value != peer) return;\n    complete_owned(id, std::move(ticket));\n  }\nprivate:\n  void callback_error(async_request_callback callback, const asio::error_code& error,\n                      owned_async_request_callback owned_callback = nullptr,\n                      std::shared_ptr<ergoptiplus::remap::auth::channel_owner::construction_marker> debt = nullptr) {\n    dispatcher_client_.enqueue_to_dispatcher([callback = std::move(callback), error, owned_callback = std::move(owned_callback), debt] {\n      if (owned_callback) owned_callback(error, nullptr);\n      else callback(error, nullptr);\n    });\n  }\n  struct pending_request',
    )
    one(
        "    async_request_callback callback;",
        "    async_request_callback callback;\n    owned_async_request_callback owned_callback;\n    std::optional<std::string> request_operation;\n    std::shared_ptr<ergoptiplus::remap::auth::channel_owner::construction_marker> owned_debt;",
    )
    one(
        "          request.callback(error_code, data);",
        "          if (request.owned_callback) request.owned_callback(error_code, nullptr);\n          else request.callback(error_code, data);",
    )
    one(
        "  request_id next_request_id_ = 0;",
        "  request_id next_request_id_ = 0;\n  const std::shared_ptr<ergoptiplus::remap::auth::channel_owner> owned_channel_;",
    )
    return source


def _server(source):

    def one(old, new):
        nonlocal source
        if source.count(old) != 1:
            raise RuntimeError(f"anchor count {source.count(old)}: {old[:80]}")
        source = source.replace(old, new)

    one("#include <atomic>", "#include <atomic>\n#include <limits>")
    one(
        "               std::function<bool(const peer_credentials&)> verify_peer)",
        "               std::function<bool(const peer_credentials&)> verify_peer,\n               std::optional<std::shared_ptr<ergoptiplus::remap::auth::channel_owner>> owned = std::nullopt)",
    )
    one(
        "        verify_peer_(verify_peer),",
        "        verify_peer_(verify_peer),\n        owned_selected_(owned.has_value()),\n        owned_channel_(owned.value_or(nullptr)),",
    )
    one("                         *this) {", "                         *this, owned_channel_) {")
    for name in ["async_shutdown", "async_stop"]:
        one(
            f"  void {name}() {{\n",
            f"  void {name}() {{\n    if (owned_channel_) {{ owned_channel_->revoke(); owned_channel_->schedule_closures(); }}\n",
        )
    one(
        "  friend class server_test_access;",
        "  friend class server_test_access;\n  friend class ::pqrs::unix_domain_stream::server;\n  using owned_scope = ergoptiplus::remap::auth::frame_scope;\n  using owned_ticket = ergoptiplus::remap::auth::delivery_ticket;\n  using owned_handler = std::function<void(peer_id, owned_scope&)>;\n  owned_handler owned_connected_, owned_received_, owned_request_received_;\n  bool bind_owned(owned_handler& slot, owned_handler handler) {\n    if (!owned_selected_ || !owned_channel_ || !handler || slot) {\n      if (owned_channel_) { owned_channel_->revoke(); owned_channel_->schedule_closures(); }\n      return false;\n    }\n    slot = std::move(handler);\n    return true;\n  }\n  void forward_owned(peer_id id, owned_scope& scope,\n                     notification_scope::token token, owned_handler handler, bool connected) {\n    auto ticket = scope.handoff();\n    if (!ticket || !handler) {\n      if (owned_channel_) { owned_channel_->revoke(); owned_channel_->schedule_closures(); }\n      return;\n    }\n    if (!notification_scope_.enqueue(token,\n        [self=shared_from_this(), id, ticket, handler=std::move(handler), connected] {\n          ticket->consume([&](owned_scope& current) {\n            if (connected) self->exposed_peer_ids_.insert(id);\n            if (self->exposed_peer_ids_.contains(id)) handler(id, current);\n          });\n        })) {\n      owned_channel_->revoke(); owned_channel_->schedule_closures();\n    }\n  }",
    )
    one(
        "  void bind() {\n    auto weak_self",
        "  void bind() {\n    if (owned_selected_ && (!owned_channel_ || !owned_channel_->current_gate())) return;\n    auto debt = owned_channel_ ? owned_channel_->retain_construction() : nullptr;\n    if (owned_selected_ && !debt) return;\n    auto weak_self",
    )
    one(
        "[weak_self, notification_token] {\n          auto self = weak_self.lock();\n          if (!self ||\n              !self->notification_scope_.is_current(notification_token) ||\n              self->acceptor_) {",
        "[weak_self, notification_token, debt] {\n          auto self = weak_self.lock();\n          if (!self ||\n              (self->owned_selected_ && (!self->owned_channel_ || !self->owned_channel_->current_gate())) ||\n              !self->notification_scope_.is_current(notification_token) ||\n              self->acceptor_) {",
    )
    one(
        "          runtime::remove_socket_file_path(self->socket_file_path_);",
        "          // The selected route never unlinks an unproved foreign listener.\n          // Binding a raced existing path fails without takeover or health waiver.\n          if (!self->owned_selected_) runtime::remove_socket_file_path(self->socket_file_path_);",
    )
    one(
        "          self->acceptor_ = std::make_unique<asio::local::stream_protocol::acceptor>(self->io_ctx_);",
        "          self->owned_acceptor_debt_ = self->owned_channel_ ? self->owned_channel_->retain_construction() : nullptr;\n          if (self->owned_selected_ && !self->owned_acceptor_debt_) return;\n          self->acceptor_ = std::make_unique<asio::local::stream_protocol::acceptor>(self->io_ctx_);",
    )
    one(
        "              [self] {\n                self->bound();",
        "              [self, debt] {\n                if (self->owned_selected_ && !self->owned_channel_->current_gate()) return;\n                self->bound();",
    )
    one(
        "    acceptor_->async_accept(\n        [self = shared_from_this(), notification_token](auto&& error_code,",
        "    auto owned_accept_handler = owned_channel_ ? owned_channel_->retain_construction() : nullptr;\n    if (owned_selected_ && !owned_accept_handler) return;\n    acceptor_->async_accept(\n        [self = shared_from_this(), notification_token, owned_accept_handler](auto&& error_code,",
    )
    one(
        "    auto credentials = impl::make_peer_credentials(socket);\n    auto id = ++next_peer_id_;",
        "    if (owned_selected_ && (!owned_channel_ || !owned_channel_->current_gate() ||\n        next_peer_id_ == std::numeric_limits<peer_id>::max())) {\n      if (owned_channel_) { owned_channel_->revoke(); owned_channel_->schedule_closures(); }\n      asio::error_code refused; socket.close(refused); return;\n    }\n    std::shared_ptr<ergoptiplus::remap::auth::socket_lifetime> owned;\n    if (owned_selected_) {\n      owned = ergoptiplus::remap::auth::socket_lifetime::bind(owned_channel_, socket.native_handle());\n      if (!owned) { asio::error_code refused; socket.close(refused); accept(notification_token); return; }\n    }\n    auto credentials = impl::make_peer_credentials(socket);\n    auto id = ++next_peer_id_;",
    )
    one(
        "                                                                     options_));",
        "                                                                     options_, owned_selected_ ? std::optional{owned} : std::nullopt));",
    )
    one(
        "    p->async_start();\n\n    accept(notification_token);",
        "    if (owned_selected_) {\n      p->ensure_owned_ports();\n      p->owned_ready_ = [weak_self, id, notification_token](owned_scope& scope) {\n        if (auto self=weak_self.lock()) self->forward_owned(id, scope, notification_token, self->owned_connected_, true);\n      };\n      p->owned_received_ = [weak_self, id, notification_token](owned_scope& scope) {\n        if (auto self=weak_self.lock()) self->forward_owned(id, scope, notification_token, self->owned_received_, false);\n      };\n      p->owned_request_received_ = [weak_self, id, notification_token](owned_scope& scope) {\n        if (auto self=weak_self.lock()) self->forward_owned(id, scope, notification_token, self->owned_request_received_, false);\n      };\n      p->owned_response_received_ = [weak_self, id, weak_p](owned_scope& scope) {\n        if (auto self=weak_self.lock()) {\n          auto ticket=scope.handoff(); auto request_id=scope.view().request_id();\n          if (!ticket) { self->owned_channel_->revoke(); self->owned_channel_->schedule_closures(); return; }\n          asio::post(self->io_ctx_, [self, id, weak_p, ticket, request_id] {\n            auto p=weak_p.lock();\n            if (auto it=self->peers_.find(id); p && it!=self->peers_.end() && it->second.get()==p)\n              self->request_manager_.complete_owned(id, request_id, ticket);\n          });\n        }\n      };\n    }\n    p->async_start();\n\n    accept(notification_token);",
    )
    one(
        "      acceptor_->close(error_code);\n      acceptor_.reset();",
        "      acceptor_->close(error_code);\n      if (owned_selected_ && error_code) return;\n      acceptor_.reset();\n      owned_acceptor_debt_.reset();",
    )
    one(
        "                not_null_shared_ptr_t<impl::peer> p(std::make_shared<impl::peer>(self->weak_dispatcher_,\n                                                                                 std::move(*socket),\n                                                                                 self->options_));",
        "                std::shared_ptr<ergoptiplus::remap::auth::socket_lifetime> owned;\n                if (self->owned_selected_) {\n                  owned = ergoptiplus::remap::auth::socket_lifetime::bind(self->owned_channel_, socket->native_handle());\n                  if (!owned) { timeout->cancel(); asio::error_code refused; socket->close(refused); return; }\n                }\n                not_null_shared_ptr_t<impl::peer> p(std::make_shared<impl::peer>(self->weak_dispatcher_,\n                                                                                 std::move(*socket),\n                                                                                 self->options_, self->owned_selected_ ? std::optional{owned} : std::nullopt));\n                if (owned) {\n                  p->ensure_owned_ports();\n                  p->owned_health_response_ = [weak_self=self->weak_from_this(), timeout, notification_token](owned_scope&) {\n                    if (auto self=weak_self.lock()) asio::post(self->io_ctx_, [self, timeout, notification_token] {\n                      if (self->is_current_socket_path_health_check(notification_token, timeout)) self->close_socket_path_health_check_peer();\n                    });\n                  };\n                }",
    )
    one(
        "    auto id = request_manager_.add(peer_id_value,",
        "    auto id = request_manager_.add(peer_id_value,",
    )
    one(
        "    peer->async_send_request(id,",
        "    if (owned_selected_ && id == 0) return;\n    peer->async_send_request(id,",
    )
    one(
        "  std::function<bool(const peer_credentials&)> verify_peer_;",
        "  std::function<bool(const peer_credentials&)> verify_peer_;\n  const bool owned_selected_;\n  const std::shared_ptr<ergoptiplus::remap::auth::channel_owner> owned_channel_;\n  std::shared_ptr<ergoptiplus::remap::auth::channel_owner::construction_marker> owned_acceptor_debt_;",
    )
    one(
        "  void socket_path_health_check() {\n    auto weak_self",
        "  void socket_path_health_check() {\n    auto owned_probe = owned_channel_ ? owned_channel_->retain_construction() : nullptr;\n    if (owned_selected_ && !owned_probe) return;\n    auto weak_self",
    )
    one(
        "[weak_self, notification_token] {\n          auto self = weak_self.lock();\n          if (!self ||\n              !self->notification_scope_.is_current(notification_token) ||\n              !self->acceptor_",
        "[weak_self, notification_token, owned_probe] {\n          auto self = weak_self.lock();\n          if (!self ||\n              !self->notification_scope_.is_current(notification_token) ||\n              !self->acceptor_",
    )
    one(
        "          timeout->expires_after(self->options_.socket_path_health_check_timeout);",
        "          auto owned_probe_socket = std::make_shared<std::shared_ptr<ergoptiplus::remap::auth::socket_lifetime>>();\n          timeout->expires_after(self->options_.socket_path_health_check_timeout);",
    )
    one(
        "timeout->async_wait([self, socket, timeout, notification_token](const auto& error_code) {",
        "timeout->async_wait([self, socket, timeout, notification_token, owned_probe, owned_probe_socket](const auto& error_code) {",
    )
    one(
        "            asio::error_code close_error_code;\n            socket->close(close_error_code);\n            if (!error_code)",
        "            if (*owned_probe_socket) (*owned_probe_socket)->revoke();\n            else {\n              asio::error_code close_error_code;\n              socket->close(close_error_code);\n            }\n            if (!error_code)",
    )
    one(
        "[self, socket, timeout, notification_token](auto&& error_code) mutable {",
        "[self, socket, timeout, notification_token, owned_probe, owned_probe_socket](auto&& error_code) mutable {",
    )
    one(
        "                if (owned) {\n                  p->ensure_owned_ports();",
        "                if (owned) {\n                  *owned_probe_socket = owned;\n                  p->ensure_owned_ports();",
    )
    one(
        "         std::function<bool(const peer_credentials&)> verify_peer = default_verify_peer)",
        "         std::function<bool(const peer_credentials&)> verify_peer = default_verify_peer,\n         std::optional<std::shared_ptr<ergoptiplus::remap::auth::channel_owner>> owned = std::nullopt)",
    )
    one(
        "                                                    std::move(verify_peer))),",
        "                                                    std::move(verify_peer), std::move(owned))),",
    )
    one(
        "  ~server() override {",
        "  bool set_owned_connected(std::function<void(peer_id, ergoptiplus::remap::auth::frame_scope&)> handler) {\n    return state_->bind_owned(state_->owned_connected_, std::move(handler));\n  }\n  bool set_owned_received(std::function<void(peer_id, ergoptiplus::remap::auth::frame_scope&)> handler) {\n    return state_->bind_owned(state_->owned_received_, std::move(handler));\n  }\n  bool set_owned_request_received(std::function<void(peer_id, ergoptiplus::remap::auth::frame_scope&)> handler) {\n    return state_->bind_owned(state_->owned_request_received_, std::move(handler));\n  }\n  ~server() override {",
    )
    return source


def _receivers(prepared):
    result = {}
    configs = [
        (
            "src/apps/CoreService/include/core_service/daemon/receiver.hpp",
            "daemon_server(current_console_user_id)",
            "receiver_uid",
        ),
        (
            "src/apps/ConsoleUserServer/include/console_user_server/receiver.hpp",
            "console_server()",
            "console",
        ),
    ]
    for name, factory, kind in configs:
        source = prepared[name].decode("utf-8", errors="strict")

        def one(old, new):
            nonlocal source
            if source.count(old) != 1:
                raise RuntimeError(f"{name}: anchor {source.count(old)} {old[:80]}")
            source = source.replace(old, new)

        one('#include "types.hpp"', '#include "types.hpp"\n#include "remap_runtime_auth.hpp"')
        one(
            "      : dispatcher_client(),",
            f"      : dispatcher_client(),\n        owned_channel_(ergoptiplus::remap::auth::channel_owner::{factory}),",
        )
        one(
            "          return result;\n        });",
            "          return result;\n        }, std::optional{owned_channel_});",
        )
        one(
            "    server_->peer_connected.connect([](auto, auto&&) {\n      // Do nothing\n    });",
            "    if (!server_->set_owned_connected([](auto, ergoptiplus::remap::auth::frame_scope&) {})) {\n      if (owned_channel_) { owned_channel_->revoke(); owned_channel_->schedule_closures(); }\n    }",
        )
        one(
            "    server_->received.connect([](auto, auto&&) {\n      // Do nothing\n    });",
            "    if (!server_->set_owned_received([](auto, ergoptiplus::remap::auth::frame_scope&) {})) {\n      if (owned_channel_) { owned_channel_->revoke(); owned_channel_->schedule_closures(); }\n    }",
        )
        one(
            "    server_->request_received.connect([this](auto peer_id, auto request_id, auto&& buffer) {\n      handle_request(peer_id,\n                     request_id,\n                     buffer);\n    });",
            "    if (!server_->set_owned_request_received([this](auto peer_id, ergoptiplus::remap::auth::frame_scope& scope) {\n      handle_request(peer_id, scope.view().request_id(),\n                     std::make_shared<std::vector<uint8_t>>(scope.view().payload()), &scope);\n    })) {\n      if (owned_channel_) { owned_channel_->revoke(); owned_channel_->schedule_closures(); }\n    }",
        )
        one(
            "  ~receiver() override {\n",
            "  ~receiver() override {\n    if (owned_channel_) { owned_channel_->revoke(); owned_channel_->schedule_closures(); }\n",
        )
        one(
            "                      pqrs::not_null_shared_ptr_t<std::vector<uint8_t>> buffer) {",
            "                      pqrs::not_null_shared_ptr_t<std::vector<uint8_t>> buffer,\n                      ergoptiplus::remap::auth::frame_scope* owned_scope = nullptr) {",
        )
        extra = '      if (owned_scope) {\n        const auto operation = json.at("operation_type").get<std::string>();\n        const auto decoded = json.at("operation_type").get<operation_type>();\n        if (nlohmann::json(decoded) != json.at("operation_type") || !owned_scope->permit(operation)) return;\n'
        if kind == "receiver_uid":
            extra += "        if (!current_console_user_id_ || owned_scope->view().peer_uid() != *current_console_user_id_) return;\n"
        extra += "      }\n"
        one(
            "      nlohmann::json json = nlohmann::json::from_msgpack(*buffer);\n      switch",
            "      nlohmann::json json = nlohmann::json::from_msgpack(*buffer);\n"
            + extra
            + "      switch",
        )
        one(
            "private:\n",
            "private:\n  const std::shared_ptr<ergoptiplus::remap::auth::channel_owner> owned_channel_;\n",
        )
        result[name] = source.encode("utf-8")
    return result


def _wrappers(prepared):
    result = {}
    for filename, factory in [
        ("core_service_daemon_client", "daemon_client"),
        ("console_user_server_client", "console_client"),
    ]:
        path = Path("src/share") / (filename + ".hpp")
        source = prepared[str(path)].decode("utf-8", errors="strict")

        def one(old, new):
            nonlocal source
            if source.count(old) != 1:
                raise RuntimeError(f"{filename}: anchor {source.count(old)} {old[:80]}")
            source = source.replace(old, new)

        one('#include "types.hpp"', '#include "types.hpp"\n#include "remap_runtime_auth.hpp"')
        if filename == "core_service_daemon_client":
            one(
                "      : dispatcher_client() {",
                f"      : dispatcher_client(), owned_channel_(ergoptiplus::remap::auth::channel_owner::{factory}()) {{",
            )
        else:
            one(
                "      : dispatcher_client(),",
                f"      : dispatcher_client(), owned_channel_(ergoptiplus::remap::auth::channel_owner::{factory}()),",
            )
        one(
            "            return get_shared_codesign_manager()->same_team_id(peer_credentials.pid);\n          });",
            "            return get_shared_codesign_manager()->same_team_id(peer_credentials.pid);\n          }, std::optional{owned_channel_});",
        )
        old = "      client_->connected.connect([this](auto&&) {"
        a = source.index(old)
        b = source.index("      client_->connect_failed.connect", a)
        source = (
            source[:a]
            + f'      client_->set_owned_connected([this](ergoptiplus::remap::auth::frame_scope& scope) {{\n        auto ticket = scope.handoff();\n        if (!ticket) {{ owned_channel_->revoke(); owned_channel_->schedule_closures(); return; }}\n        enqueue_to_dispatcher([this, ticket] {{\n          ticket->consume([&](ergoptiplus::remap::auth::frame_scope&) {{\n            logger::get_logger()->debug("{filename} is connected.");\n            connected();\n          }});\n        }});\n      }});\n\n'
            + source[b:]
        )
        old = "      client_->received.connect([this](auto&& buffer) {\n        enqueue_to_dispatcher([this, buffer] {"
        a = source.index(old)
        b = source.index("      client_->request_received.connect", a)
        block = source[a:b]
        body = block[len(old) :]
        if not body.endswith("        });\n      });\n\n"):
            raise AuthTransportRefusal("auth_transport_anchor_refused")
        body = body[: -len("        });\n      });\n\n")]
        anchor = '            auto ot = json.at("operation_type").template get<operation_type>();'
        if not body.count(anchor) == 1:
            raise AuthTransportRefusal("auth_transport_anchor_refused")
        body = body.replace(
            anchor,
            anchor
            + '\n            if (nlohmann::json(ot) != json.at("operation_type") ||\n                !current.permit(json.at("operation_type").template get<std::string>())) return;',
        )
        new = (
            "      client_->set_owned_received([this](ergoptiplus::remap::auth::frame_scope& scope) {\n        auto ticket = scope.handoff();\n        if (!ticket) { owned_channel_->revoke(); owned_channel_->schedule_closures(); return; }\n        enqueue_to_dispatcher([this, ticket] {\n          ticket->consume([&](ergoptiplus::remap::auth::frame_scope& current) {\n            auto buffer = std::make_shared<std::vector<uint8_t>>(current.view().payload());"
            + body
            + "\n          });\n        });\n      });\n\n"
        )
        source = source[:a] + new + source[b:]
        if filename == "core_service_daemon_client":
            one(
                "      client_->request_received.connect([this](auto request_id, auto&& buffer) {",
                "      client_->set_owned_request_received([this](ergoptiplus::remap::auth::frame_scope& scope) {\n        const auto request_id = scope.view().request_id();\n        const auto buffer = std::make_shared<std::vector<uint8_t>>(scope.view().payload());",
            )
            one(
                "          handle_message(buffer);\n        }\n      });",
                "          handle_message(buffer, &scope);\n        }\n      });",
            )
            one(
                "    client_->async_request(\n        nlohmann::json::to_msgpack(json),\n        [this, completion_handler = std::move(completion_handler)](auto&& error_code, auto&& buffer) {",
                "    client_->async_request_owned(\n        nlohmann::json::to_msgpack(json),\n        [this, completion_handler = std::move(completion_handler)](const asio::error_code& error_code, ergoptiplus::remap::auth::frame_scope* scope) {\n          const auto buffer = scope ? std::make_shared<std::vector<uint8_t>>(scope->view().payload()) : nullptr;",
            )
            one(
                "            handle_message(buffer);\n          }\n\n          if (completion_handler)",
                "            handle_message(buffer, scope);\n          }\n\n          if (completion_handler)",
            )
        else:
            one(
                "      client_->request_received.connect([](auto, auto&&) {",
                "      client_->set_owned_request_received([](ergoptiplus::remap::auth::frame_scope&) {",
            )
            a = source.index("    client_->async_request(")
            b = source.index("  void handle_message", a)
            source = (
                source[:a]
                + '    client_->async_request_owned(\n        nlohmann::json::to_msgpack(json),\n        [this](const asio::error_code& error_code, ergoptiplus::remap::auth::frame_scope* scope) {\n          if (error_code) {\n            logger::get_logger()->debug("console_user_server_client request failed: {0}", error_code.message());\n            return;\n          }\n          if (!scope) return;\n          auto ticket = scope->handoff();\n          if (!ticket) { owned_channel_->revoke(); owned_channel_->schedule_closures(); return; }\n          enqueue_to_dispatcher([this, ticket] {\n            ticket->consume([&](ergoptiplus::remap::auth::frame_scope& current) {\n              auto buffer = std::make_shared<std::vector<uint8_t>>(current.view().payload());\n              if (!buffer->empty()) handle_message(buffer, &current);\n            });\n          });\n        });\n  }\n\n'
                + source[b:]
            )
        one(
            "  void handle_message(pqrs::not_null_shared_ptr_t<std::vector<uint8_t>> buffer) const {",
            "  void handle_message(pqrs::not_null_shared_ptr_t<std::vector<uint8_t>> buffer,\n                      ergoptiplus::remap::auth::frame_scope* scope = nullptr) const {",
        )
        one(
            '      auto ot = json.at("operation_type").template get<operation_type>();\n      if',
            '      auto ot = json.at("operation_type").template get<operation_type>();\n      if (scope && (nlohmann::json(ot) != json.at("operation_type") ||\n                    !scope->permit(json.at("operation_type").template get<std::string>()))) return;\n      if',
        )
        source = source.replace("enqueue_to_dispatcher(", "enqueue_owned(")
        one(
            "  void async_stop() {\n    enqueue_owned([this] {",
            "  void async_stop() {\n    auto debt = owned_channel_ ? owned_channel_->retain_construction() : nullptr;\n    if (owned_channel_) { owned_channel_->revoke(); owned_channel_->schedule_closures(); }\n    enqueue_to_dispatcher([this, debt] {",
        )
        one(
            "  void unregister_callbacks_and_detach() {\n    std::call_once(unregister_callbacks_and_detach_once_, [this] {\n      detach_from_dispatcher([this] {",
            "  void unregister_callbacks_and_detach() {\n    auto debt = owned_channel_ ? owned_channel_->retain_construction() : nullptr;\n    if (owned_channel_) { owned_channel_->revoke(); owned_channel_->schedule_closures(); }\n    std::call_once(unregister_callbacks_and_detach_once_, [this, debt] {\n      detach_from_dispatcher([this, debt] {",
        )
        one(
            "private:\n",
            "private:\n  const std::shared_ptr<ergoptiplus::remap::auth::channel_owner> owned_channel_;\n  template<class F> bool enqueue_owned(F function) const {\n    auto debt = owned_channel_ ? owned_channel_->retain_construction() : nullptr;\n    if (!debt) return false;\n    return enqueue_to_dispatcher([this, debt, function=std::move(function)] {\n      if (owned_channel_->current_gate()) function();\n    });\n  }\n",
        )
        result[str(path)] = source.encode("utf-8")
    return result


def _session(prepared):
    result = {}
    base = Path("src/apps")
    path = base / "CoreService/include/core_service/daemon/console_user_id_changed_receiver.hpp"
    source = prepared[str(path)].decode("utf-8", errors="strict")

    def one(old, new):
        nonlocal source
        if source.count(old) != 1:
            raise RuntimeError(f"{path}: anchor {source.count(old)} {old[:80]}")
        source = source.replace(old, new)

    one('#include "types.hpp"', '#include "types.hpp"\n#include "remap_runtime_auth.hpp"')
    one(
        "  console_user_id_changed_receiver() : dispatcher_client() {",
        "  console_user_id_changed_receiver() : dispatcher_client(),\n      owned_channel_(ergoptiplus::remap::auth::channel_owner::session_server()) {",
    )
    one(
        "          return result;\n        });",
        "          return result;\n        }, std::optional{owned_channel_});",
    )
    one(
        "    server_->peer_connected.connect([this](auto peer_id, const auto& peer_credentials) {\n      peer_credentials_[peer_id] = peer_credentials;\n    });",
        "    server_->set_owned_connected([this](auto peer_id, ergoptiplus::remap::auth::frame_scope& scope) {\n      // Diagnostic cache only; every positive request uses its fresh native UID.\n      peer_credentials_[peer_id] = pqrs::unix_domain_stream::peer_credentials{\n          .pid = scope.view().peer_pid(), .uid = scope.view().peer_uid()};\n    });",
    )
    one(
        "    server_->received.connect([](auto, auto&&) {",
        "    server_->set_owned_received([](auto, ergoptiplus::remap::auth::frame_scope&) {",
    )
    one(
        "    server_->request_received.connect([this](auto peer_id, auto request_id, auto&& buffer) {",
        "    server_->set_owned_request_received([this](auto peer_id, ergoptiplus::remap::auth::frame_scope& scope) {\n      const auto request_id = scope.view().request_id();\n      const auto buffer = std::make_shared<std::vector<uint8_t>>(scope.view().payload());",
    )
    one(
        "        nlohmann::json json = nlohmann::json::from_msgpack(*buffer);\n        switch",
        '        nlohmann::json json = nlohmann::json::from_msgpack(*buffer);\n        const auto decoded = json.at("operation_type").get<operation_type>();\n        if (nlohmann::json(decoded) != json.at("operation_type") ||\n            !scope.permit(json.at("operation_type").get<std::string>())) return;\n        switch',
    )
    one(
        "            auto uid = get_peer_uid(peer_id);",
        "            std::optional<uid_t> uid = scope.view().peer_uid();",
    )
    one(
        "  ~console_user_id_changed_receiver() override {\n",
        "  ~console_user_id_changed_receiver() override {\n    if (owned_channel_) { owned_channel_->revoke(); owned_channel_->schedule_closures(); }\n",
    )
    one(
        "private:\n",
        "private:\n  const std::shared_ptr<ergoptiplus::remap::auth::channel_owner> owned_channel_;\n",
    )
    result[str(path)] = source.encode("utf-8")
    path = base / "ConsoleUserServer/include/console_user_server/console_user_id_changed_client.hpp"
    source = prepared[str(path)].decode("utf-8", errors="strict")
    one('#include "types.hpp"', '#include "types.hpp"\n#include "remap_runtime_auth.hpp"')
    one(
        "      : dispatcher_client() {",
        "      : dispatcher_client(), owned_channel_(ergoptiplus::remap::auth::channel_owner::session_client()) {",
    )
    one(
        "            return get_shared_codesign_manager()->same_team_id(peer_credentials.pid);\n          });",
        "            return get_shared_codesign_manager()->same_team_id(peer_credentials.pid);\n          }, std::optional{owned_channel_});",
    )
    a = source.index("      client_->connected.connect")
    b = source.index("      client_->connect_failed.connect", a)
    source = (
        source[:a]
        + '      client_->set_owned_connected([this](ergoptiplus::remap::auth::frame_scope& scope) {\n        auto ticket = scope.handoff();\n        if (!ticket) { owned_channel_->revoke(); owned_channel_->schedule_closures(); return; }\n        enqueue_to_dispatcher([this, ticket] {\n          ticket->consume([&](ergoptiplus::remap::auth::frame_scope&) {\n            logger::get_logger()->debug("console_user_id_changed_client is connected.");\n            state_.connected();\n            connected();\n            async_deliver_pending_console_user_id_changed();\n          });\n        });\n      });\n\n'
        + source[b:]
    )
    old = "      client_->received.connect([this](auto&& buffer) {\n        enqueue_to_dispatcher([this, buffer] {"
    a = source.index(old)
    b = source.index("      client_->request_received.connect", a)
    body = source[a + len(old) : b]
    if not body.endswith("        });\n      });\n\n"):
        raise AuthTransportRefusal("auth_transport_anchor_refused")
    body = body[: -len("        });\n      });\n\n")]
    anchor = "            auto json = nlohmann::json::from_msgpack(*buffer);"
    if not body.count(anchor) == 1:
        raise AuthTransportRefusal("auth_transport_anchor_refused")
    body = body.replace(
        anchor,
        anchor
        + '\n            const auto decoded = json.at("operation_type").get<operation_type>();\n            if (nlohmann::json(decoded) != json.at("operation_type") ||\n                !current.permit(json.at("operation_type").get<std::string>())) return;',
    )
    source = (
        source[:a]
        + "      client_->set_owned_received([this](ergoptiplus::remap::auth::frame_scope& scope) {\n        auto ticket = scope.handoff();\n        if (!ticket) { owned_channel_->revoke(); owned_channel_->schedule_closures(); return; }\n        enqueue_to_dispatcher([this, ticket] {\n          ticket->consume([&](ergoptiplus::remap::auth::frame_scope& current) {\n            auto buffer = std::make_shared<std::vector<uint8_t>>(current.view().payload());"
        + body
        + "\n          });\n        });\n      });\n\n"
        + source[b:]
    )
    one(
        "      client_->request_received.connect([](auto, auto&&) {",
        "      client_->set_owned_request_received([](ergoptiplus::remap::auth::frame_scope&) {",
    )
    a = source.index("    client_->async_request(")
    b = source.index("  std::unique_ptr<pqrs::unix_domain_stream::client> client_;", a)
    source = (
        source[:a]
        + '    client_->async_request_owned(\n        nlohmann::json::to_msgpack(json),\n        [this, request = *request](const asio::error_code& error_code, ergoptiplus::remap::auth::frame_scope* scope) {\n          if (error_code) {\n            enqueue_to_dispatcher([this, error_code] {\n              logger::get_logger()->debug("console_user_id_changed_client request failed: {0}", error_code.message());\n              make_connection_not_ready();\n            });\n            return;\n          }\n          if (!scope) return;\n          auto ticket = scope->handoff();\n          if (!ticket) { owned_channel_->revoke(); owned_channel_->schedule_closures(); return; }\n          enqueue_to_dispatcher([this, request, ticket] {\n            ticket->consume([&](ergoptiplus::remap::auth::frame_scope&) {\n              state_.console_user_id_changed_request_succeeded(request);\n              notify_core_service_daemon_server_bound_if_ready();\n              async_deliver_pending_console_user_id_changed();\n            });\n          });\n        });\n  }\n\n'
        + source[b:]
    )
    source = source.replace("enqueue_to_dispatcher(", "enqueue_owned(")
    one(
        "  ~console_user_id_changed_client() override {\n    detach_from_dispatcher([this] {",
        "  ~console_user_id_changed_client() override {\n    auto debt = owned_channel_ ? owned_channel_->retain_construction() : nullptr;\n    if (owned_channel_) { owned_channel_->revoke(); owned_channel_->schedule_closures(); }\n    detach_from_dispatcher([this, debt] {",
    )
    one(
        "private:\n",
        "private:\n  const std::shared_ptr<ergoptiplus::remap::auth::channel_owner> owned_channel_;\n  template<class F> bool enqueue_owned(F function) const {\n    auto debt = owned_channel_ ? owned_channel_->retain_construction() : nullptr;\n    if (!debt) return false;\n    return enqueue_to_dispatcher([this, debt, function=std::move(function)] {\n      if (owned_channel_->current_gate()) function();\n    });\n  }\n",
    )
    result[str(path)] = source.encode("utf-8")
    return result


def _types(source):
    anchor = "namespace pqrs::unix_domain_stream {\n"
    if not source.count(anchor) == 1:
        raise AuthTransportRefusal("auth_transport_anchor_refused")
    source = source.replace(
        anchor,
        "namespace ergoptiplus::remap::auth { class frame_scope; }\n\nnamespace pqrs::unix_domain_stream {\n\n// A successful owned response exists only inside its exact claimed frame.\n// Errors carry no frame and cannot manufacture a response capability.\nusing owned_async_request_callback = std::function<void(\n    const std::error_code&, ergoptiplus::remap::auth::frame_scope*)>;\n",
    )
    return source


def _lambda_end(source, capture_end):
    """Locate one fixed generated closure without counting quoted braces."""
    start = source.index("{", capture_end)
    depth, position, quote, comment = 1, start + 1, None, None
    while depth and position < len(source):
        character = source[position]
        following = source[position : position + 2]
        if comment == "line":
            if character == "\n":
                comment = None
        elif comment == "block":
            if following == "*/":
                comment = None
                position += 1
        elif quote:
            if character == "\\":
                position += 1
            elif character == quote:
                quote = None
        elif following == "//":
            comment = "line"
            position += 1
        elif following == "/*":
            comment = "block"
            position += 1
        elif character in {"'", '"'}:
            quote = character
        elif character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
        position += 1
    if depth:
        raise AuthTransportRefusal("auth_transport_anchor_refused")
    return position


def _ordered_storage(path, data):
    """Retain actual existing task debt until all queued captures are destroyed."""
    source = data.decode("utf-8", errors="strict")
    if path.endswith("impl/request_manager.hpp"):
        before = (
            "    async_request_callback callback;\n"
            "    owned_async_request_callback owned_callback;\n"
            "    std::optional<std::string> request_operation;\n"
            "    std::shared_ptr<ergoptiplus::remap::auth::channel_owner::construction_marker> owned_debt;"
        )
        after = (
            "    std::shared_ptr<ergoptiplus::remap::auth::channel_owner::construction_marker> owned_debt;\n"
            "    async_request_callback callback;\n"
            "    owned_async_request_callback owned_callback;\n"
            "    std::optional<std::string> request_operation;"
        )
        initial = (
            "                                  .callback = request_callback,\n"
            "                                  .owned_callback = std::move(owned_callback),\n"
            "                                  .request_operation = std::move(request_operation),\n"
            "                                  .owned_debt = owned_debt,"
        )
        ordered = (
            "                                  .owned_debt = owned_debt,\n"
            "                                  .callback = request_callback,\n"
            "                                  .owned_callback = std::move(owned_callback),\n"
            "                                  .request_operation = std::move(request_operation),"
        )
        if source.count(before) != 1 or source.count(initial) != 1:
            raise AuthTransportRefusal("auth_transport_anchor_refused")
        source = source.replace(before, after).replace(initial, ordered)
    expected = {
        "src/share/console_user_server_client.hpp": 7,
        "src/share/core_service_daemon_client.hpp": 6,
        "src/apps/ConsoleUserServer/include/console_user_server/console_user_id_changed_client.hpp": 5,
        "vendor/vendor/include/pqrs/unix_domain_stream/server.hpp": 4,
        "vendor/vendor/include/pqrs/unix_domain_stream/client.hpp": 6,
        "vendor/vendor/include/pqrs/unix_domain_stream/impl/request_manager.hpp": 3,
        "vendor/vendor/include/pqrs/unix_domain_stream/impl/peer.hpp": 3,
    }
    pattern = re.compile(r"\[[^\[\]\n]*\b(debt|owned_debt|owned_request|ticket)\b[^\[\]\n]*\]")
    matches = tuple(pattern.finditer(source))
    if len(matches) != expected.get(path, 0):
        raise AuthTransportRefusal("auth_transport_anchor_refused")
    # Nested closures are wrapped from the inside out; their bodies stay exact.
    for capture in reversed(matches):
        end = _lambda_end(source, capture.end())
        source = (
            source[: capture.start()]
            + "ergoptiplus::remap::auth::detail::retain_callable("
            + capture.group(1)
            + ", "
            + source[capture.start() : capture.end()].replace(
                "debt = std::move(debt)", "debt = debt"
            )
            + source[capture.end() : end]
            + ")"
            + source[end:]
        )
    return source.encode("utf-8")


def assemble_owned_auth_transport(
    prepared11: dict[str, bytes], auth_header: bytes, absolute_deadline: float
) -> dict[str, bytes]:
    """Transform already preflighted parent bytes without replacing identities.

    The canonical source provider owns pristine source/identity preflight and
    ordered parent composition. This method owns only the fixed eleven recipes.
    In particular receiver.hpp consumes prepared parent bytes, never a reread
    or a stock-source overwrite. Modified recipe anchors remain refusals.
    """
    _deadline(absolute_deadline)
    if type(prepared11) is not dict or set(prepared11) != set(INPUT_PATHS):
        raise AuthTransportRefusal("auth_transport_inventory_refused")
    if any(type(value) is not bytes for value in prepared11.values()):
        raise AuthTransportRefusal("auth_transport_bytes_refused")
    if any(
        b'#include "remap_runtime_auth.hpp"' in value
        or b"using owned_async_request_callback" in value
        or b"const bool owned_selected_;" in value
        for value in prepared11.values()
    ):
        raise AuthTransportRefusal("auth_transport_already_modified")
    if (
        type(auth_header) is not bytes
        or hashlib.sha256(auth_header).hexdigest() != AUTH_HEADER_SHA256
    ):
        raise AuthTransportRefusal("auth_transport_header_refused")
    result = {}
    result["vendor/vendor/include/pqrs/unix_domain_stream/impl/peer.hpp"] = _peer(
        prepared11["vendor/vendor/include/pqrs/unix_domain_stream/impl/peer.hpp"].decode(
            "utf-8", errors="strict"
        )
    ).encode("utf-8")
    _deadline(absolute_deadline)
    result["vendor/vendor/include/pqrs/unix_domain_stream/client.hpp"] = _client(
        prepared11["vendor/vendor/include/pqrs/unix_domain_stream/client.hpp"].decode(
            "utf-8", errors="strict"
        )
    ).encode("utf-8")
    _deadline(absolute_deadline)
    result["vendor/vendor/include/pqrs/unix_domain_stream/impl/request_manager.hpp"] = _request(
        prepared11["vendor/vendor/include/pqrs/unix_domain_stream/impl/request_manager.hpp"].decode(
            "utf-8", errors="strict"
        )
    ).encode("utf-8")
    _deadline(absolute_deadline)
    result["vendor/vendor/include/pqrs/unix_domain_stream/server.hpp"] = _server(
        prepared11["vendor/vendor/include/pqrs/unix_domain_stream/server.hpp"].decode(
            "utf-8", errors="strict"
        )
    ).encode("utf-8")
    _deadline(absolute_deadline)
    key = "vendor/vendor/include/pqrs/unix_domain_stream/types.hpp"
    result[key] = _types(prepared11[key].decode("utf-8", errors="strict")).encode("utf-8")
    result.update(_receivers(prepared11))
    _deadline(absolute_deadline)
    result.update(_wrappers(prepared11))
    _deadline(absolute_deadline)
    result.update(_session(prepared11))
    _deadline(absolute_deadline)
    result = {path: _ordered_storage(path, value) for path, value in result.items()}
    _deadline(absolute_deadline)
    if set(result) != set(INPUT_PATHS):
        raise AuthTransportRefusal("auth_transport_result_refused")
    return result
