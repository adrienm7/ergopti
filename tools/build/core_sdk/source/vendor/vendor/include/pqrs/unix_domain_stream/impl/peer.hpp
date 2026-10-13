#pragma once

// (C) Copyright Takayama Fumihiko 2026.
// Distributed under the Boost Software License, Version 1.0.
// (See https://www.boost.org/LICENSE_1_0.txt)

#include "../options.hpp"
#include "remap_runtime_auth.hpp"
#include "remap_runtime_vhd.hpp"
#include "asio_helper.hpp"
#include "protocol.hpp"
#include <algorithm>
#include <atomic>
#include <deque>
#include <functional>
#include <nod/nod.hpp>
#include <pqrs/dispatcher.hpp>
#include <pqrs/gsl.hpp>

namespace pqrs::unix_domain_stream::impl {

class peer final : public dispatcher::extra::dispatcher_client,
                   public std::enable_shared_from_this<peer> {
  bool vhd_enqueue(std::function<void()> function) {
    const bool queued = pqrs::dispatcher::extra::dispatcher_client::enqueue_to_dispatcher(std::move(function));
    if (!queued && vhd_selected_) { if (vhd_socket_) vhd_socket_->fail_cleanup(); }
    return queued;
  }

  template<class F> auto vhd_native(F function) {
    auto debt = vhd_socket_ ? vhd_socket_->retain_task(ergoptiplus::remap::vhd::connection::task_kind::native) : nullptr;
    return ergoptiplus::remap::auth::detail::retain_callable(debt, std::move(function));
  }
  template<class F> auto vhd_dispatch(F function) {
    auto debt = vhd_socket_ ? vhd_socket_->retain_task(ergoptiplus::remap::vhd::connection::task_kind::dispatch) : nullptr;
    return ergoptiplus::remap::auth::detail::retain_callable(debt,
        [self = shared_from_this(), function = std::move(function), debt]() mutable {
          if (self->vhd_selected_ && (!debt || !self->vhd_socket_ || !self->vhd_socket_->current())) {
            self->close(); return;
          }
          function();
        });
  }

public:
  nod::signal<void()> ready;
  nod::signal<void(not_null_shared_ptr_t<std::vector<uint8_t>>)> received;
  nod::signal<void(uint64_t,
                   not_null_shared_ptr_t<std::vector<uint8_t>>)>
      request_received;
  nod::signal<void(uint64_t,
                   not_null_shared_ptr_t<std::vector<uint8_t>>)>
      response_received;
  nod::signal<void()> health_check_response_received;
  nod::signal<void(const asio::error_code&)> error_occurred;
  nod::signal<void()> closed;

  peer(const peer&) = delete;

  peer(std::weak_ptr<dispatcher::dispatcher> weak_dispatcher,
       asio::local::stream_protocol::socket socket,
       const common_options& options,
       std::optional<std::shared_ptr<ergoptiplus::remap::auth::socket_lifetime>> owned = std::nullopt,
       std::optional<std::shared_ptr<ergoptiplus::remap::vhd::connection>> vhd = std::nullopt)
      : dispatcher_client(weak_dispatcher),
        socket_(std::move(socket)),
        options_(options),
        owned_executor_(socket_.get_executor()),
        owned_selected_(owned.has_value()),
        owned_socket_(owned.value_or(nullptr)),
        vhd_selected_(vhd.has_value()),
        vhd_socket_(vhd.value_or(nullptr)),
        ready_deadline_(socket_.get_executor()),
        heartbeat_timer_(socket_.get_executor()),
        heartbeat_deadline_(socket_.get_executor()),
        read_deadline_(socket_.get_executor()),
        write_deadline_(socket_.get_executor()) {
  }

  // The owner must call async_close before releasing the last shared_ptr so
  // socket and timer state is closed on `socket_.get_executor()`.
  ~peer() override {
    if (!closed_on_executor_.load()) {
      abort();
    }

    detach_from_dispatcher();
  }

  void disconnect_all_signal_slots() {
    ready.disconnect_all_slots();
    received.disconnect_all_slots();
    request_received.disconnect_all_slots();
    response_received.disconnect_all_slots();
    health_check_response_received.disconnect_all_slots();
    error_occurred.disconnect_all_slots();
    closed.disconnect_all_slots();
  }

  void async_start() {
    asio::post(
        socket_.get_executor(),
        vhd_native([self = shared_from_this()] {
          self->ensure_vhd_ports();
          if (self->vhd_selected_ && (self->owned_selected_ || !self->vhd_socket_ || !self->vhd_socket_->current())) { self->close(); return; }
          self->ensure_owned_ports();
          if (self->owned_selected_ && (!self->owned_socket_ || !self->owned_socket_->current())) {
            self->close();
            return;
          }
          if (self->owned_selected_ && self->owned_socket_->health_only_.value_or(false)) {
            self->read_header();
            return;
          }
          self->start_ready_deadline();
          self->start_heartbeat_timer();
          self->refresh_heartbeat_deadline();
          self->read_header();
        }));
  }

  // The completion runs on the socket executor after the socket is closed.
  void async_close(std::function<void()> completion = nullptr) {
    if (vhd_socket_) vhd_socket_->revoke();
    if (owned_socket_) owned_socket_->revoke();
    asio::post(
        socket_.get_executor(),
        vhd_native([self = shared_from_this(), completion = std::move(completion)] {
          if (self->vhd_selected_ && self->vhd_socket_) {
            self->ensure_vhd_ports();
            if (self->vhd_socket_->completed()) { if (completion) completion(); return; }
            if (completion) self->vhd_observers_.push_back(std::move(completion));
            self->close(); return;
          }
          if (self->owned_selected_ && self->owned_socket_) {
            self->ensure_owned_ports();
            // A repeated caller may observe a genuinely completed old socket;
            // this cannot reopen its channel, FD, identity or positive ports.
            if (self->owned_socket_->completed()) {
              if (completion) completion();
              return;
            }
            if (completion) self->owned_close_observers_.push_back(std::move(completion));
            self->close();
            return;
          }
          self->close();
          if (completion) {
            completion();
          }
        }));
  }

  void async_send(const std::vector<uint8_t>& data) {
    async_push_frame(protocol::make_user_data_frame(data));
  }

  void async_send_request(uint64_t request_id,
                          const std::vector<uint8_t>& data) {
    async_push_frame(protocol::make_request_frame(request_id, data));
  }

  void async_send_response(uint64_t request_id,
                           const std::vector<uint8_t>& data) {
    async_push_frame(protocol::make_response_frame(request_id, data));
  }

  void async_send_health_check() {
    async_push_frame(protocol::make_health_check_frame());
  }

private:
  friend class client_state;
  friend class server_state;
  using owned_scope = ergoptiplus::remap::auth::frame_scope;
  using owned_ticket = ergoptiplus::remap::auth::delivery_ticket;
  using owned_handler = std::function<void(owned_scope&)>;
  owned_handler owned_ready_;
  owned_handler owned_received_;
  owned_handler owned_request_received_;
  owned_handler owned_response_received_;
  owned_handler owned_health_response_;
  bool owned_ports_installed_ = false;
  bool owned_closed_notification_ = false;
  std::vector<std::function<void()>> owned_close_observers_;

  void ensure_vhd_ports() {
    if (!vhd_socket_ || vhd_ports_) return;
    vhd_ports_ = true;
    auto self = shared_from_this();
    if (!vhd_socket_->migrate(socket_, [self] {
          if (self->vhd_cancel_requests_) self->vhd_cancel_requests_();
          self->ready_deadline_.cancel(); self->heartbeat_timer_.cancel();
          self->heartbeat_deadline_.cancel(); self->read_deadline_.cancel(); self->write_deadline_.cancel();
          self->vhd_socket_->close_native(self->socket_);
        }, [self] {
          self->closed_on_executor_ = true;
          auto observers = std::exchange(self->vhd_observers_, {});
          for (auto& observer : observers) observer();
          auto debt = self->vhd_socket_->retain_task(ergoptiplus::remap::vhd::connection::task_kind::dispatch);
          if (!debt || !self->vhd_enqueue(ergoptiplus::remap::auth::detail::retain_callable(debt,
              [self, debt] { self->closed(); }))) self->vhd_socket_->fail_cleanup();
        })) vhd_socket_->fail_cleanup();
    vhd_socket_->request_close();
  }
  std::function<void()> vhd_cancel_requests_;
  bool vhd_ports_ = false;
  std::vector<std::function<void()>> vhd_observers_;
  template<class F> auto owned_native(F function) {
    auto debt = owned_socket_ ? owned_socket_->retain_task(
        ergoptiplus::remap::auth::socket_lifetime::task_kind::native) : nullptr;
    auto vhd_debt = vhd_socket_ ? vhd_socket_->retain_task(ergoptiplus::remap::vhd::connection::task_kind::native) : nullptr;
    return ergoptiplus::remap::auth::detail::retain_callable(vhd_debt,
        ergoptiplus::remap::auth::detail::retain_callable(debt, [function = std::move(function), debt = debt, vhd_debt](auto&&... arguments) mutable {
          function(std::forward<decltype(arguments)>(arguments)...);
        }));
  }
  bool enqueue_owned(const std::shared_ptr<owned_ticket>& ticket, owned_handler handler) {
    if (!owned_socket_ || !ticket || !handler) {
      if (owned_socket_) owned_socket_->revoke();
      return false;
    }
    auto debt = owned_socket_->retain_task(
        ergoptiplus::remap::auth::socket_lifetime::task_kind::dispatch);
    if (!debt) { owned_socket_->revoke(); return false; }
    try {
      if (!vhd_enqueue(ergoptiplus::remap::auth::detail::retain_callable(debt, [ticket, handler = std::move(handler), debt = debt] {
            ticket->consume(handler);
          }))) { owned_socket_->revoke(); return false; }
    } catch (...) { owned_socket_->revoke(); throw; }
    return true;
  }
  void ensure_owned_ports() {
    if (!owned_socket_ || owned_ports_installed_) return;
    owned_ports_installed_ = true;
    auto self = shared_from_this();
    if (owned_socket_->has_staged_ports()) {
      if (!owned_socket_->transfer_close_ports(socket_,
          [self] { self->owned_close_on_executor(); },
          [self] { self->owned_completed_on_executor(); })) return;
    } else {
      owned_socket_->set_close_ports(
          [self] { asio::post(self->owned_executor_, self->vhd_native([self] { self->owned_close_on_executor(); })); },
          [self] { self->owned_completed_on_executor(); });
    }
    owned_socket_->request_close();
  }
  void owned_completed_on_executor() {
    closed_on_executor_ = true;
    auto observers = std::exchange(owned_close_observers_, {});
    for (auto& observer : observers) observer();
    if (owned_closed_notification_) return;
    owned_closed_notification_ = true;
    auto debt = owned_socket_->retain_task(
        ergoptiplus::remap::auth::socket_lifetime::task_kind::dispatch);
    if (!debt || !vhd_enqueue(ergoptiplus::remap::auth::detail::retain_callable(debt, [self = shared_from_this(), debt = debt] { self->closed(); })))
      owned_socket_->fail_cleanup();
  }
  void owned_close_on_executor() {
    ready_deadline_.cancel();
    heartbeat_timer_.cancel();
    heartbeat_deadline_.cancel();
    read_deadline_.cancel();
    write_deadline_.cancel();
    if (owned_socket_->close_native(socket_)) owned_socket_->finish_close();
  }
  void async_send_output_request(std::uint64_t id,const std::vector<std::uint8_t>& bytes,
      const std::shared_ptr<ergoptiplus::remap::vhd::output_delivery>& output) {
    if (!vhd_selected_ || !output || output->id_!=id || output->bytes_!=bytes || !output->write_current(vhd_socket_)) {
      if (output) output->cancel(); return;
    }
    async_push_frame(protocol::make_request_frame(id,bytes),output);
  }
  void async_push_frame(std::vector<uint8_t> frame,
      std::shared_ptr<ergoptiplus::remap::vhd::output_delivery> output = {}) {
    if (owned_selected_ && (!owned_socket_ || !owned_socket_->current())) {
      if (owned_socket_) owned_socket_->revoke();
      return;
    }
    asio::post(
        socket_.get_executor(),
        vhd_native([self = shared_from_this(), frame = std::move(frame), output]() mutable {
          self->ensure_owned_ports();
          self->push_frame(std::move(frame),output);
        }));
  }

  // This method is executed in `io_ctx_thread_`.
  void start_heartbeat_timer() {
    heartbeat_timer_.expires_after(normalize_scheduling_interval(options_.heartbeat_interval));

    heartbeat_timer_.async_wait(owned_native([self = shared_from_this()](const auto& error_code) {
      if (!error_code &&
          self->socket_.is_open()) {
        self->push_frame(protocol::make_heartbeat_frame());
        self->start_heartbeat_timer();
      }
    }));
  }

  // This method is executed in `io_ctx_thread_`.
  void refresh_heartbeat_deadline() {
    heartbeat_deadline_.expires_after(options_.heartbeat_timeout);

    heartbeat_deadline_.async_wait(owned_native([self = shared_from_this()](const auto& error_code) {
      if (!error_code) {
        self->handle_error(asio::error::timed_out);
      }
    }));
  }

  // This method is executed in `io_ctx_thread_`.
  void start_ready_deadline() {
    ready_deadline_.expires_after(std::chrono::milliseconds(100));

    ready_deadline_.async_wait(owned_native([self = shared_from_this()](const auto& error_code) {
      if (!error_code) {
        self->ensure_ready();
      }
    }));
  }

  // This method is executed in `io_ctx_thread_`.
  void ensure_ready() {
    if (vhd_selected_ && (!vhd_socket_ || !vhd_socket_->current())) { close(); return; }
    if (owned_selected_) {
      if (!owned_socket_ || !owned_socket_->current()) { close(); return; }
      if (owned_socket_->health_only_.value_or(false)) return;
    }
    if (ready_) {
      return;
    }

    ready_ = true;
    ready_deadline_.cancel();

    if (owned_selected_) {
      enqueue_owned(owned_socket_->ticket(ergoptiplus::remap::auth::frame_kind::connected, 0, {}), owned_ready_);
    } else {
      vhd_enqueue(vhd_dispatch([this] {
        ready();
      }));
    }
  }

  // This method is executed in `io_ctx_thread_`.
  void read_header() {
    if (vhd_selected_ && (!vhd_socket_ || !vhd_socket_->current())) { close(); return; }
    if (owned_selected_ && (!owned_socket_ || !owned_socket_->current())) { close(); return; }
    if (!socket_.is_open()) {
      return;
    }

    start_read_deadline();

    asio::async_read(
        socket_,
        asio::buffer(read_header_),
        owned_native([self = shared_from_this()](auto&& error_code,
                                    auto bytes_transferred) {
          self->read_deadline_.cancel();

          if (error_code) {
            if (error_code == asio::error::eof &&
                bytes_transferred == 0) {
              self->close();
              return;
            }

            self->handle_error(error_code);
            return;
          }

          if (bytes_transferred != protocol::header_size) {
            self->handle_error(asio::error::message_size);
            return;
          }

          auto body_size = protocol::decode_uint32(self->read_header_);
          if (body_size < protocol::type_size ||
              body_size > self->options_.max_message_size + protocol::type_size + protocol::request_id_size) {
            self->handle_error(asio::error::message_size);
            return;
          }

          self->read_body_.resize(body_size);
          self->read_body();
        }));
  }

  // This method is executed in `io_ctx_thread_`.
  void read_body() {
    if (vhd_selected_ && (!vhd_socket_ || !vhd_socket_->current())) { close(); return; }
    if (owned_selected_ && (!owned_socket_ || !owned_socket_->current())) { close(); return; }
    start_read_deadline();

    asio::async_read(
        socket_,
        asio::buffer(read_body_),
        owned_native([self = shared_from_this()](auto&& error_code,
                                    auto bytes_transferred) {
          self->read_deadline_.cancel();

          if (error_code) {
            self->handle_error(error_code);
            return;
          }

          if (bytes_transferred != self->read_body_.size()) {
            self->handle_error(asio::error::message_size);
            return;
          }

          if (self->owned_selected_ && (!self->owned_socket_ || !self->owned_socket_->current())) {
            self->close();
            return;
          }
          self->refresh_heartbeat_deadline();

          auto type = static_cast<protocol::message_type>(self->read_body_[0]);
          if (self->owned_selected_ && self->owned_socket_->health_only_.value_or(false) &&
              type != protocol::message_type::health_check && type != protocol::message_type::health_check_response) {
            self->handle_error(asio::error::operation_not_supported);
            return;
          }
          switch (type) {
            case protocol::message_type::heartbeat:
              break;

            case protocol::message_type::user_data: {
              self->ensure_ready();

              if (self->read_body_.size() > self->options_.max_message_size + protocol::type_size) {
                self->handle_error(asio::error::message_size);
                return;
              }

              not_null_shared_ptr_t<std::vector<uint8_t>> v(std::make_shared<std::vector<uint8_t>>(std::begin(self->read_body_) + protocol::type_size,
                                                                                                   std::end(self->read_body_)));
              if (self->owned_selected_) {
                self->enqueue_owned(self->owned_socket_->ticket(
                    ergoptiplus::remap::auth::frame_kind::user_data, 0, *v), self->owned_received_);
              } else {
                self->vhd_enqueue(self->vhd_dispatch([p = self.get(), v] {
                  p->received(v);
                }));
              }
              break;
            }

            case protocol::message_type::request:
            case protocol::message_type::response: {
              self->ensure_ready();

              if (self->read_body_.size() < protocol::type_size + protocol::request_id_size ||
                  self->read_body_.size() > self->options_.max_message_size + protocol::type_size + protocol::request_id_size) {
                self->handle_error(asio::error::message_size);
                return;
              }

              auto request_id = protocol::decode_uint64(self->read_body_,
                                                        protocol::type_size);
              not_null_shared_ptr_t<std::vector<uint8_t>> v(std::make_shared<std::vector<uint8_t>>(std::begin(self->read_body_) + protocol::type_size + protocol::request_id_size,
                                                                                                   std::end(self->read_body_)));

              if (self->owned_selected_) {
                const auto kind = type == protocol::message_type::request
                    ? ergoptiplus::remap::auth::frame_kind::request
                    : ergoptiplus::remap::auth::frame_kind::response;
                self->enqueue_owned(self->owned_socket_->ticket(kind, request_id, *v),
                    type == protocol::message_type::request ? self->owned_request_received_
                                                           : self->owned_response_received_);
              } else if (type == protocol::message_type::request) {
                self->vhd_enqueue(self->vhd_dispatch([p = self.get(), request_id, v] {
                  p->request_received(request_id,
                                      v);
                }));
              } else {
                self->vhd_enqueue(self->vhd_dispatch([p = self.get(), request_id, v] {
                  p->response_received(request_id,
                                       v);
                }));
              }
              break;
            }

            case protocol::message_type::health_check:
              if (self->owned_selected_ &&
                  (!self->owned_socket_->health_only_.value_or(false) || self->read_body_.size() != protocol::type_size)) {
                self->handle_error(asio::error::operation_not_supported);
                return;
              }
              if (self->ready_) {
                self->handle_error(asio::error::operation_not_supported);
              } else {
                self->close_after_write_ = true;
                self->push_frame(protocol::make_health_check_response_frame());
              }
              return;

            case protocol::message_type::health_check_response:
              if (self->owned_selected_) {
                if (!self->owned_socket_->health_only_.value_or(false) || self->read_body_.size() != protocol::type_size) {
                  self->handle_error(asio::error::operation_not_supported);
                  return;
                }
                self->enqueue_owned(self->owned_socket_->ticket(
                    ergoptiplus::remap::auth::frame_kind::health_check_response, 0, {}), self->owned_health_response_);
              } else {
                self->vhd_enqueue(self->vhd_dispatch([p = self.get()] {
                  p->health_check_response_received();
                }));
              }
              break;

            default:
              self->handle_error(asio::error::invalid_argument);
              return;
          }

          self->read_header();
        }));
  }

  // This method is executed in `io_ctx_thread_`.
  void start_read_deadline() {
    read_deadline_.expires_after(options_.read_timeout);

    read_deadline_.async_wait(owned_native([self = shared_from_this()](const auto& error_code) {
      if (!error_code) {
        self->handle_error(asio::error::timed_out);
      }
    }));
  }

  // This method is executed in `io_ctx_thread_`.
  void push_frame(std::vector<uint8_t> frame,
      std::shared_ptr<ergoptiplus::remap::vhd::output_delivery> output = {}) {
    if (output && !output->write_current(vhd_socket_)) { output->cancel(); return; }
    if (vhd_selected_ && (!vhd_socket_ || !vhd_socket_->current())) { close(); return; }
    if (owned_selected_ && (!owned_socket_ || !owned_socket_->current())) { close(); return; }
    if (!socket_.is_open()) {
      return;
    }

    if (owned_selected_ && owned_socket_->health_only_.value_or(false)) {
      if (frame.size() != protocol::header_size + protocol::type_size ||
          (static_cast<protocol::message_type>(frame[protocol::header_size]) != protocol::message_type::health_check &&
           static_cast<protocol::message_type>(frame[protocol::header_size]) != protocol::message_type::health_check_response)) {
        handle_error(asio::error::operation_not_supported);
        return;
      }
    }
    if (!valid_outgoing_frame(frame) ||
        write_queue_.size() >= options_.max_send_queue_size) {
      handle_error(asio::error::no_buffer_space);
      return;
    }

    auto was_empty = write_queue_.empty();
    write_queue_.push_back(write_frame{std::move(frame),std::move(output)});

    if (was_empty) {
      write();
    }
  }

  // This method is executed in `io_ctx_thread_`.
  [[nodiscard]] bool valid_outgoing_frame(const std::vector<uint8_t>& frame) const {
    if (frame.size() < protocol::header_size + protocol::type_size) {
      return false;
    }

    std::array<uint8_t, protocol::header_size> header;
    std::copy_n(std::begin(frame),
                protocol::header_size,
                std::begin(header));

    auto body_size = protocol::decode_uint32(header);
    if (frame.size() != protocol::header_size + body_size ||
        body_size < protocol::type_size) {
      return false;
    }

    auto type = static_cast<protocol::message_type>(frame[protocol::header_size]);
    switch (type) {
      case protocol::message_type::request:
      case protocol::message_type::response:
        return body_size >= protocol::type_size + protocol::request_id_size &&
               body_size <= options_.max_message_size + protocol::type_size + protocol::request_id_size;

      case protocol::message_type::heartbeat:
      case protocol::message_type::user_data:
      case protocol::message_type::health_check:
      case protocol::message_type::health_check_response:
        return body_size <= options_.max_message_size + protocol::type_size;
    }

    return false;
  }

  // This method is executed in `io_ctx_thread_`.
  void write() {
    if (vhd_selected_ && (!vhd_socket_ || !vhd_socket_->current())) { close(); return; }
    if (owned_selected_ && (!owned_socket_ || !owned_socket_->current())) { close(); return; }
    if (!socket_.is_open() ||
        write_queue_.empty()) {
      return;
    }

    while (!write_queue_.empty() && write_queue_.front().output &&
        !write_queue_.front().output->write_current(vhd_socket_)) {
      auto refused=std::move(write_queue_.front().output);
      write_queue_.pop_front();
      refused->cancel();
      if (!socket_.is_open()) return;
    }
    if (write_queue_.empty()) return;
    write_deadline_.expires_after(options_.write_timeout);

    write_deadline_.async_wait(owned_native([self = shared_from_this()](const auto& error_code) {
      if (!error_code) {
        self->handle_error(asio::error::timed_out);
      }
    }));

    asio::async_write(
        socket_,
        asio::buffer(write_queue_.front().bytes),
        owned_native([self = shared_from_this()](auto&& error_code,
                                    auto) {
          self->write_deadline_.cancel();

          if (error_code) {
            self->handle_error(error_code);
            return;
          }

          if (self->owned_selected_ && (!self->owned_socket_ || !self->owned_socket_->current())) {
            self->close();
            return;
          }
          self->write_queue_.pop_front();

          if (self->write_queue_.empty() &&
              self->close_after_write_) {
            self->close();
            return;
          }

          self->write();
        }));
  }

  // This method is executed in `io_ctx_thread_`.
  void handle_error(const asio::error_code& error_code) {
    if (error_code == asio::error::operation_aborted) {
      return;
    }

    vhd_enqueue(vhd_dispatch([this, error_code] {
      error_occurred(error_code);
    }));

    close();
  }

  // This method is executed in `io_ctx_thread_`.
  void close() {
    if (vhd_selected_) {
      if (vhd_socket_) { ensure_vhd_ports(); vhd_socket_->revoke(); }
      return;
    }
    if (owned_selected_ && owned_socket_) {
      ensure_owned_ports();
      owned_socket_->revoke();
      return;
    }
    const auto socket_was_open = socket_.is_open();

    // Cancel the timers even if the socket has already been closed.
    // Otherwise, the io_context can remain alive until a timer such as the
    // heartbeat deadline expires, causing client/server destruction to block
    // while joining the io_context thread.
    close_socket();

    if (socket_was_open) {
      vhd_enqueue(vhd_dispatch([this] {
        closed();
      }));
    }
  }

  // This method is executed in `io_ctx_thread_`.
  void close_socket() {
    closed_on_executor_ = true;

    asio::error_code error_code;
    ready_deadline_.cancel();
    heartbeat_timer_.cancel();
    heartbeat_deadline_.cancel();
    read_deadline_.cancel();
    write_deadline_.cancel();
    socket_.cancel(error_code);
    socket_.close(error_code);
  }

  asio::local::stream_protocol::socket socket_;
  common_options options_;
  const asio::any_io_executor owned_executor_;
  const bool owned_selected_;
  const std::shared_ptr<ergoptiplus::remap::auth::socket_lifetime> owned_socket_;
  const bool vhd_selected_;
  const std::shared_ptr<ergoptiplus::remap::vhd::connection> vhd_socket_;
  std::atomic_bool closed_on_executor_ = false;
  bool ready_ = false;
  bool close_after_write_ = false;
  asio::steady_timer ready_deadline_;
  asio::steady_timer heartbeat_timer_;
  asio::steady_timer heartbeat_deadline_;
  asio::steady_timer read_deadline_;
  asio::steady_timer write_deadline_;
  std::array<uint8_t, protocol::header_size> read_header_;
  std::vector<uint8_t> read_body_;
  struct write_frame final {
    std::vector<std::uint8_t> bytes;
    std::shared_ptr<ergoptiplus::remap::vhd::output_delivery> output;
  };
  std::deque<write_frame> write_queue_;
};

} // namespace pqrs::unix_domain_stream::impl
