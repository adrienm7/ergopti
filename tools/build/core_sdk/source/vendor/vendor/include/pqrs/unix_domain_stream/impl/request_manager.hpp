#pragma once

// (C) Copyright Takayama Fumihiko 2026.
// Distributed under the Boost Software License, Version 1.0.
// (See https://www.boost.org/LICENSE_1_0.txt)

#include "../types.hpp"
#include "remap_runtime_auth.hpp"
#include "remap_runtime_vhd.hpp"
#include <limits>
#include <asio.hpp>
#include <chrono>
#include <functional>
#include <memory>
#include <optional>
#include <pqrs/dispatcher.hpp>
#include <pqrs/gsl.hpp>
#include <unordered_map>
#include <utility>
#include <vector>

namespace pqrs::unix_domain_stream::impl {

class request_manager final {
public:
  request_manager(const request_manager&) = delete;

  request_manager(asio::io_context& io_ctx,
                  dispatcher::extra::dispatcher_client& dispatcher_client,
                  std::shared_ptr<ergoptiplus::remap::auth::channel_owner> owned = nullptr,
                  std::shared_ptr<ergoptiplus::remap::vhd::broker_owner> vhd = nullptr)
      : io_ctx_(io_ctx),
        dispatcher_client_(dispatcher_client), owned_channel_(std::move(owned)), vhd_owner_(std::move(vhd)) {
  }

  // Register a pending request and return the request_id to put into the frame.
  // The callback is always delivered on the dispatcher thread.
  request_id add(std::optional<peer_id> peer_id_value,
                 std::chrono::milliseconds timeout,
                 async_request_callback request_callback,
                 std::function<void()> timeout_callback = nullptr,
                 owned_async_request_callback owned_callback = nullptr,
                 std::optional<std::string> request_operation = std::nullopt,
                 std::shared_ptr<ergoptiplus::remap::auth::channel_owner::construction_marker> inherited_debt = nullptr,
                 std::shared_ptr<ergoptiplus::remap::vhd::initializer_delivery> initializer = nullptr,
                 const std::vector<std::uint8_t>* sent = nullptr,
                 std::shared_ptr<ergoptiplus::remap::vhd::output_delivery> output = nullptr) {
    if (output && (!vhd_owner_ || owned_channel_ || !output->source_current())) return 0;
    if (initializer && (!vhd_owner_ || owned_channel_)) { initializer->refuse(); return 0; }
    auto vhd_session = vhd_owner_ ? vhd_owner_->active() : nullptr;
    auto vhd_debt = vhd_owner_ ? vhd_owner_->retain_work(ergoptiplus::remap::vhd::broker_owner::queue::native) : nullptr;
    if (vhd_owner_ && (owned_channel_ || !vhd_session || !vhd_debt)) return 0;
    auto owned_debt = inherited_debt ? std::move(inherited_debt) :
                      owned_channel_ ? owned_channel_->retain_construction() : nullptr;
    if (owned_channel_ && (!owned_debt || !owned_channel_->current_gate())) {
      if (owned_debt) callback_error(std::move(request_callback), asio::error::operation_aborted,
                                     std::move(owned_callback), owned_debt);
      return 0;
    }
    if (owned_channel_ && next_request_id_ == std::numeric_limits<request_id>::max()) {
      owned_channel_->revoke();
      owned_channel_->schedule_closures();
      callback_error(std::move(request_callback), asio::error::no_buffer_space, std::move(owned_callback), owned_debt);
      return 0;
    }
    if (vhd_owner_ && next_request_id_ == std::numeric_limits<request_id>::max()) {
      if (initializer) initializer->refuse();
      vhd_owner_->retire(); return 0;
    }
    auto id = ++next_request_id_;
    if (output && (!sent || !output->bind(vhd_session,id,*sent))) return 0;
    if (initializer && (!sent || !initializer->bind(vhd_session, id, *sent))) {
      initializer->refuse(); vhd_owner_->retire(); return 0;
    }
    not_null_shared_ptr_t<asio::steady_timer> timer(std::make_shared<asio::steady_timer>(io_ctx_));
    timer->expires_after(timeout);
    timer->async_wait(ergoptiplus::remap::auth::detail::retain_callable(vhd_debt, ergoptiplus::remap::auth::detail::retain_callable(owned_debt, [this, id, timeout_callback, owned_debt, vhd_debt, vhd_session](const auto& error_code) {
      // An expired timer may already be queued when completion cancels it.
      // Only a request that is still pending may trigger timeout side effects.
      if (!error_code && pending_requests_.contains(id) && (!vhd_session || vhd_session->current())) {
        complete(id,
                 asio::error::timed_out,
                 nullptr);

        if (timeout_callback) {
          timeout_callback();
        }
      }
    })));

    pending_requests_.emplace(id,
                              pending_request{
                                  .peer_id_value = peer_id_value,
                                  .owned_debt = owned_debt,
                                  .vhd_debt = vhd_debt,
                                  .vhd_session = vhd_session,
                                  .vhd_initializer = initializer,
                                  .vhd_output = output,
                                  .vhd_request_id = id,
                                  .callback = request_callback,
                                  .owned_callback = std::move(owned_callback),
                                  .request_operation = std::move(request_operation),
                                  .timer = timer,
                              });

    return id;
  }

  // Complete one pending request by request_id. Use this for single-peer owners
  // such as client, where request_id alone identifies the active peer.
  void complete(request_id id,
                const asio::error_code& error_code,
                std::shared_ptr<std::vector<uint8_t>> data) {
    if (auto node = pending_requests_.extract(id);
        !node.empty()) {
      complete_request(std::move(node.mapped()), error_code, std::move(data));
    }
  }

  // Complete one pending request only if it belongs to the given peer. Use this
  // for multi-peer owners such as server, where request_id values are shared
  // across peers on the same manager.
  void complete(peer_id peer_id_value,
                request_id id,
                const asio::error_code& error_code,
                std::shared_ptr<std::vector<uint8_t>> data) {
    if (auto it = pending_requests_.find(id);
        it == std::end(pending_requests_) ||
        it->second.peer_id_value != peer_id_value) {
      return;
    }

    complete(id,
             error_code,
             data);
  }

  // Complete all pending requests associated with one peer, typically when that
  // peer closes or reports an error.
  void complete_peer(peer_id id,
                     const asio::error_code& error_code) {
    for (auto it = std::begin(pending_requests_);
         it != std::end(pending_requests_);) {
      if (it->second.peer_id_value == id) {
        auto node = pending_requests_.extract(it++);
        complete_request(std::move(node.mapped()), error_code, nullptr);
      } else {
        ++it;
      }
    }
  }

  // Complete every pending request, typically when the owner is stopping or
  // invalidating all active connections.
  void complete_all(const asio::error_code& error_code) {
    auto pending_requests = std::exchange(pending_requests_,
                                          {});

    for (auto&& [_, request] : pending_requests) {
      complete_request(std::move(request), error_code, nullptr);
    }
  }

  // The exact response ticket survives pending extraction and dispatcher queue.
  // Error/cancellation continues to use the unchanged no-payload error path.
  void complete_owned(request_id id,
                      std::shared_ptr<ergoptiplus::remap::auth::delivery_ticket> ticket) {
    if (auto node = pending_requests_.extract(id); !node.empty()) {
      auto request = std::move(node.mapped());
      request.timer->cancel();
      auto owner = owned_channel_;
      if (!ticket || !dispatcher_client_.enqueue_to_dispatcher(ergoptiplus::remap::auth::detail::retain_callable(ticket, [request = std::move(request), ticket, id, owner] {
            ticket->consume([&](ergoptiplus::remap::auth::frame_scope& scope) {
              if (scope.view().kind() != ergoptiplus::remap::auth::frame_kind::response ||
                  scope.view().request_id() != id ||
                  (scope.view().payload().empty() && request.request_operation != "console_user_id_changed")) {
                if (owner) { owner->revoke(); owner->schedule_closures(); }
                return;
              }
              if (request.owned_callback) request.owned_callback(asio::error_code(), &scope);
              else request.callback(asio::error_code(),
                  std::make_shared<std::vector<std::uint8_t>>(scope.view().payload()));
            });
          }))) {
        if (owned_channel_) { owned_channel_->revoke(); owned_channel_->schedule_closures(); }
      }
    }
  }
  void complete_owned(peer_id peer, request_id id,
                      std::shared_ptr<ergoptiplus::remap::auth::delivery_ticket> ticket) {
    if (auto it = pending_requests_.find(id); it == pending_requests_.end() || it->second.peer_id_value != peer) return;
    complete_owned(id, std::move(ticket));
  }
private:
  friend class client_state;
  bool accepts_vhd_response(request_id id) {
    auto row = pending_requests_.find(id);
    return vhd_owner_ && id != 0 && row != pending_requests_.end() &&
        row->second.vhd_session && row->second.vhd_session->current();
  }
  void callback_error(async_request_callback callback, const asio::error_code& error,
                      owned_async_request_callback owned_callback = nullptr,
                      std::shared_ptr<ergoptiplus::remap::auth::channel_owner::construction_marker> debt = nullptr) {
    dispatcher_client_.enqueue_to_dispatcher(ergoptiplus::remap::auth::detail::retain_callable(debt, [callback = std::move(callback), error, owned_callback = std::move(owned_callback), debt] {
      if (owned_callback) owned_callback(error, nullptr);
      else callback(error, nullptr);
    }));
  }
  struct pending_request final {
    std::optional<peer_id> peer_id_value;
    std::shared_ptr<ergoptiplus::remap::auth::channel_owner::construction_marker> owned_debt;
    std::shared_ptr<void> vhd_debt;
    std::shared_ptr<ergoptiplus::remap::vhd::connection> vhd_session;
    std::shared_ptr<ergoptiplus::remap::vhd::initializer_delivery> vhd_initializer;
    std::shared_ptr<ergoptiplus::remap::vhd::output_delivery> vhd_output;
    request_id vhd_request_id;
    async_request_callback callback;
    owned_async_request_callback owned_callback;
    std::optional<std::string> request_operation;
    not_null_shared_ptr_t<asio::steady_timer> timer;
  };

  // The request has already been removed from pending_requests_ on the I/O thread.
  void complete_request(pending_request request,
                        const asio::error_code& error_code,
                        std::shared_ptr<std::vector<uint8_t>> data) {
    if (request.vhd_output) request.vhd_output->completed();
    if (request.vhd_initializer) request.vhd_initializer->complete(request.vhd_request_id, error_code, data);
    request.timer->cancel();
    auto vhd_session = request.vhd_session;
    auto vhd_dispatch = request.vhd_session ? request.vhd_session->retain_task(ergoptiplus::remap::vhd::connection::task_kind::dispatch) : nullptr;
    if (request.vhd_session && !vhd_dispatch) { request.vhd_session->fail_cleanup(); return; }
    if (!dispatcher_client_.enqueue_to_dispatcher(ergoptiplus::remap::auth::detail::retain_callable(vhd_dispatch,
        [request = std::move(request), error_code, data = std::move(data), vhd_dispatch] {
          if (request.vhd_session && !error_code && !request.vhd_session->current()) { request.callback(asio::error::operation_aborted, nullptr); return; }
          if (request.owned_callback) request.owned_callback(error_code, nullptr);
          else request.callback(error_code, data);
        }))) { if (vhd_session) vhd_session->fail_cleanup(); }
  }

  asio::io_context& io_ctx_;
  dispatcher::extra::dispatcher_client& dispatcher_client_;
  request_id next_request_id_ = 0;
  const std::shared_ptr<ergoptiplus::remap::auth::channel_owner> owned_channel_;
  const std::shared_ptr<ergoptiplus::remap::vhd::broker_owner> vhd_owner_;
  std::unordered_map<request_id, pending_request> pending_requests_;
};

} // namespace pqrs::unix_domain_stream::impl
