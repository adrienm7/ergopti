#pragma once

// (C) Copyright Takayama Fumihiko 2020.
// Distributed under the Boost Software License, Version 1.0.
// (See https://www.boost.org/LICENSE_1_0.txt)

#include "../client_protocol_version.hpp"
#include "remap_runtime_vhd.hpp"
#include "../virtual_hid_device_driver.hpp"
#include "constants.hpp"
#include "parameters.hpp"
#include "request.hpp"
#include "response.hpp"
#include <cstring>
#include <array>
#include <mutex>

namespace krbn::core_service::daemon { class device_grabber; }
#include <pqrs/dispatcher.hpp>
#include <pqrs/gsl.hpp>
#include <pqrs/hid.hpp>
#include <pqrs/unix_domain_stream.hpp>
#include <ranges>
#include <type_traits>

namespace pqrs::karabiner::driverkit::virtual_hid_device_service {
class client final : public dispatcher::extra::dispatcher_client {
  friend class krbn::core_service::daemon::device_grabber;
  bool vhd_enqueue(std::function<void()> function) {
    const bool queued = pqrs::dispatcher::extra::dispatcher_client::enqueue_to_dispatcher(std::move(function));
    if (!queued && vhd_selected_) { if (vhd_owner_) vhd_owner_->failed_cleanup(); }
    return queued;
  }

  template<class F> auto vhd_cleanup(F function) {
    auto debt = vhd_owner_ ? vhd_owner_->retain_work(ergoptiplus::remap::vhd::broker_owner::queue::dispatch) : nullptr;
    return ergoptiplus::remap::auth::detail::retain_callable(debt, std::move(function));
  }
  template<class F> auto vhd_dispatch(F function) {
    auto debt = vhd_owner_ ? vhd_owner_->retain_work(ergoptiplus::remap::vhd::broker_owner::queue::dispatch) : nullptr;
    auto session = vhd_owner_ ? vhd_owner_->active() : nullptr;
    return ergoptiplus::remap::auth::detail::retain_callable(debt,
        [this, function = std::move(function), session, debt]() mutable {
          if (vhd_selected_ && (!debt || (session ? !session->current() : !vhd_owner_->current()))) return;
          function();
        });
  }
  template<class F> auto vhd_callback(F function) {
    auto debt = vhd_owner_ ? vhd_owner_->retain_work(ergoptiplus::remap::vhd::broker_owner::queue::native) : nullptr;
    auto session = vhd_owner_ ? vhd_owner_->active() : nullptr;
    return ergoptiplus::remap::auth::detail::retain_callable(debt,
        [selected = vhd_selected_, alive = vhd_alive_, session, function = std::move(function), debt](auto&&... arguments) mutable {
          if (selected) {
            if (!alive->load() || !debt || !session) return;
            auto frame = session->retain_task(ergoptiplus::remap::vhd::connection::task_kind::dispatch);
            if (!frame || !session->current()) return;
            function(std::forward<decltype(arguments)>(arguments)...);
          } else function(std::forward<decltype(arguments)>(arguments)...);
        });
  }


  // Native daemon status and queued request replies have separate provenance.
  enum class status_origin { request_reply, daemon_push };
  struct ready_projection final {
    const std::shared_ptr<ergoptiplus::remap::vhd::connection> connection;
    const std::uint64_t generation;
    const std::array<bool,5> bits;
    const std::array<std::shared_ptr<ergoptiplus::remap::vhd::initializer_delivery>,2> initializer;
  };
public:
  class owned_status;
  class initialized_ready final {
    friend class owned_status;
    const std::shared_ptr<client> client_;
    const std::shared_ptr<const ready_projection> projection_;
    const std::size_t kind_;
    initialized_ready(std::shared_ptr<client> owner,
                      std::shared_ptr<const ready_projection> projection,
                      std::size_t kind)
      :client_(std::move(owner)),projection_(std::move(projection)),kind_(kind) {}
  public:
    bool current() const {
      if (!client_ || !projection_ || kind_>=2 || !client_->vhd_alive_->load() ||
          !client_->vhd_owner_ || !projection_->connection ||
          !projection_->connection->current() ||
          client_->vhd_owner_->active()!=projection_->connection ||
          !projection_->bits[0] || !projection_->bits[1] || projection_->bits[2] ||
          !projection_->bits[3+kind_] || !projection_->initializer[kind_]) return false;
      {
        std::lock_guard<std::recursive_mutex> lock(client_->vhd_owner_->mutex_);
        if (client_->vhd_owner_->generation_!=projection_->generation) return false;
      }
      {
        std::lock_guard<std::mutex> lock(client_->owned_status_mutex_);
        if (client_->owned_ready_projection_!=projection_ ||
            client_->owned_initializer_[kind_]!=projection_->initializer[kind_]) return false;
      }
      if (projection_->initializer[kind_]->state()!=
          ergoptiplus::remap::vhd::initializer_delivery::observation::delivered ||
          !projection_->connection->current()) return false;
      std::lock_guard<std::mutex> lock(client_->owned_status_mutex_);
      return client_->owned_ready_projection_==projection_ &&
             client_->owned_initializer_[kind_]==projection_->initializer[kind_];
    }
  };
private:
  // This participant is constructed only by the original Core device owner.
  // Read-only status is an observation; it is not installed/capture authority.
public:
  class owned_status final {
    friend class client;
    friend class ::krbn::core_service::daemon::device_grabber;
    std::shared_ptr<client> client_;
    const std::shared_ptr<ergoptiplus::remap::vhd::broker_owner> broker_;
    std::shared_ptr<ergoptiplus::remap::vhd::connection> connection_;
    std::uint64_t generation_=0;
    bool admission_bound_=false;
    explicit owned_status(std::shared_ptr<ergoptiplus::remap::vhd::broker_owner> broker)
      :broker_(std::move(broker)) {} // Inert storage, not a native observation.
    bool retirement_requested_=false;
    std::function<void()> progress_;
    owned_status(std::shared_ptr<client> client,
                 std::shared_ptr<ergoptiplus::remap::vhd::broker_owner> broker,
                 std::shared_ptr<ergoptiplus::remap::vhd::connection> connection,
                 std::uint64_t generation)
      :client_(std::move(client)),broker_(std::move(broker)),
       connection_(std::move(connection)),generation_(generation),admission_bound_(true) {}
    bool same_lifetime() const {
      return client_ && broker_ && client_->dispatcher_thread() && client_->vhd_owner_==broker_ && client_->vhd_alive_->load();
    }
    bool same_generation() const {
      if (!admission_bound_ || !same_lifetime()) return false;
      std::lock_guard<std::recursive_mutex> lock(broker_->mutex_);
      return client_->dispatcher_thread() && client_->vhd_owner_==broker_ && client_->vhd_alive_->load() &&
             broker_->generation_==generation_;
    }
  public:
    struct observation final {
      std::array<std::optional<bool>,5> response_bits;
      std::array<std::optional<ergoptiplus::remap::vhd::initializer_delivery::observation>,2> initializer;
    };
    bool current() const {
      return same_generation() && !retirement_requested_ && broker_->current() &&
             (!connection_ || (broker_->active()==connection_ && connection_->current()));
    }
    std::optional<observation> observe() const {
      if (!current()) return std::nullopt;
      observation result;
      {
        std::lock_guard<std::mutex> lock(client_->owned_status_mutex_);
        if (client_->owned_status_connection_!=connection_) return std::nullopt;
        result.response_bits=client_->owned_status_bits_;
        for (std::size_t i=0;i<2;++i) {
          if (client_->owned_initializer_[i]) result.initializer[i]=client_->owned_initializer_[i]->state();
        }
      }
      if (!current()) return std::nullopt;
      return result;
    }
    std::shared_ptr<const initialized_ready> ready(
        ergoptiplus::remap::vhd::initializer_kind kind) const {
      if (!current()) return nullptr;
      const auto index=kind==ergoptiplus::remap::vhd::initializer_kind::keyboard ? 0u :
                       kind==ergoptiplus::remap::vhd::initializer_kind::pointing ? 1u : 2u;
      if (index>=2) return nullptr;
      std::shared_ptr<const ready_projection> projection;
      {
        std::lock_guard<std::mutex> lock(client_->owned_status_mutex_);
        projection=client_->owned_ready_projection_;
      }
      if (!projection || projection->connection!=connection_ || projection->generation!=generation_) return nullptr;
      auto receipt=std::shared_ptr<const initialized_ready>(new initialized_ready(client_,projection,index));
      return receipt->current() && current() ? receipt : nullptr;
    }
    bool observe_retirement(std::function<void()> observer) {
      if (!same_lifetime() || !observer) return false;
      if (progress_) return false;
      progress_=observer;
      client_->owned_stop_progress_=observer;
      const auto self=client_;
      const auto broker=broker_;
      const auto generation=generation_;
      auto continuation=[self,broker,generation,observer=std::move(observer)] {
        try {
          if (!self->enqueue_to_dispatcher([self,broker,generation,observer] {
            bool ready=false;
            {
              std::lock_guard<std::recursive_mutex> lock(broker->mutex_);
              ready=self->vhd_owner_==broker && self->vhd_alive_->load() && broker->retired();
            }
            if (ready) observer();
          })) broker->failed_cleanup();
        } catch (...) { broker->failed_cleanup(); }
      };
      bool ready=false;
      {
        std::lock_guard<std::recursive_mutex> lock(broker_->mutex_);
        if (broker_->failed_ || client_->vhd_owner_!=broker_) return false;
        ready=broker_->retired_;
        if (!ready) broker_->retired_observers_.push_back(continuation);
      }
      if (ready) continuation();
      return true;
    }
    bool request_retirement() {
      if (!same_lifetime()) return false;
      if (retirement_requested_) return true;
      // Cleanup of this previously captured original generation cannot require
      // fresh live admission after disconnect or publisher currentness loss.
      retirement_requested_=true;
      try { client_->async_stop(); }
      catch (...) { broker_->failed_cleanup(); return false; }
      return true; // original work queued, never a terminal acknowledgement
    }
    bool retired() const {
      return retirement_requested_ && same_lifetime() && client_->owned_stop_completed_ && broker_->retired();
    }
  };
private:
  static std::shared_ptr<owned_status> allocate_owned_status_slot(
      const std::shared_ptr<ergoptiplus::remap::vhd::broker_owner>& broker) {
    if (!broker) return nullptr;
    return std::shared_ptr<owned_status>(new owned_status(broker));
  }
  bool bind_owned_status_slot(const std::shared_ptr<client>& self,
                              const std::shared_ptr<owned_status>& slot) noexcept {
    if (!slot || slot->client_ || self.get()!=this || !vhd_selected_ ||
        !vhd_owner_ || slot->broker_!=vhd_owner_) return false;
    // Retain real cleanup lineage BEFORE locks which can throw/refuse admission.
    slot->client_=self;
    try {
      if (!dispatcher_thread() || !vhd_alive_->load()) return false;
      std::lock_guard<std::recursive_mutex> lock(vhd_owner_->mutex_);
      slot->connection_=vhd_owner_->active();
      slot->generation_=vhd_owner_->generation_;
      slot->admission_bound_=true;
      owned_status_slot_=slot;
      return true;
    } catch (...) { return false; }
  }
  std::shared_ptr<owned_status> retain_owned_status(const std::shared_ptr<client>& self) {
    if (self.get()!=this || !dispatcher_thread() || !vhd_selected_ || !vhd_owner_) return nullptr;
    std::lock_guard<std::recursive_mutex> lock(vhd_owner_->mutex_);
    // Retain genuine constructor cleanup lineage even when native acquisition
    // was refused. current() still cannot grant a closed broker admission.
    const auto connection=vhd_owner_->active();
    {
      std::lock_guard<std::mutex> status_lock(owned_status_mutex_);
      if (owned_status_connection_!=connection) {
        owned_status_connection_=connection;
        owned_status_bits_={};
        owned_initializer_={};
      }
    }
    return std::shared_ptr<owned_status>(new owned_status(self,vhd_owner_,connection,vhd_owner_->generation_));
  }

public:
  // Signals (invoked from the dispatcher thread)

  nod::signal<void(const std::string&)> warning_reported;
  nod::signal<void()> connected;
  nod::signal<void(const asio::error_code&)> connect_failed;
  nod::signal<void()> closed;
  nod::signal<void(const asio::error_code&)> error_occurred;
  nod::signal<void(bool)> driver_activated;
  nod::signal<void(bool)> driver_connected;
  nod::signal<void(bool)> driver_version_mismatched;
  nod::signal<void(bool)> virtual_hid_keyboard_ready;
  nod::signal<void(bool)> virtual_hid_pointing_ready;

  // Methods

  client()
      : dispatcher_client() {
  }
  explicit client(std::shared_ptr<ergoptiplus::remap::vhd::broker_owner> owner)
      : dispatcher_client(), vhd_selected_(true), vhd_owner_(std::move(owner)) {
  }

  ~client() override {
    vhd_alive_->store(false);
    if (vhd_owner_) vhd_owner_->retire();
    detach_from_dispatcher([this] {
      client_ = nullptr;
    });
  }

  void async_start() {
    vhd_enqueue(vhd_dispatch([this] {
      if (client_) {
        return;
      }

      create_client();

      if (client_) {
        client_->async_start();
      }
    }));
  }

  void async_stop() {
    // Ready receipts retain their native client. Close this captured report
    // loan before stop so client -> input -> ready -> client cannot form a
    // permanent ownership cycle. Device and original callbacks keep custody.
    { std::lock_guard<std::mutex> lock(owned_report_mutex_); owned_report_scope_={}; }
    auto retirement_debt = vhd_owner_ ? vhd_owner_->retain_work(ergoptiplus::remap::vhd::broker_owner::queue::dispatch) : nullptr;
    if (vhd_owner_) vhd_owner_->retire();
    vhd_enqueue(ergoptiplus::remap::auth::detail::retain_callable(retirement_debt, vhd_cleanup([this, retirement_debt] {
      client_ = nullptr;

      clear_state();
      if (vhd_selected_) owned_stop_completed_=true;
      if (vhd_owner_) vhd_owner_->settle();
      if (owned_stop_progress_) owned_stop_progress_();
    })));
  }

  void async_virtual_hid_keyboard_initialize(const pqrs::karabiner::driverkit::virtual_hid_device_service::virtual_hid_keyboard_parameters& parameters,
                                             bool force = false) {
    vhd_enqueue(vhd_dispatch([this, parameters, force] {
      if (!force) {
        if (last_virtual_hid_keyboard_ready_ == true &&
            last_virtual_hid_keyboard_parameters_ == parameters) {
          return;
        }
      }

      last_virtual_hid_keyboard_parameters_ = parameters;

      async_request(make_request_buffer(request::virtual_hid_keyboard_initialize,
                                        parameters), ergoptiplus::remap::vhd::initializer_kind::keyboard);
    }));
  }

  void async_virtual_hid_keyboard_terminate() {
    if (vhd_selected_) {
      std::lock_guard<std::mutex> lock(owned_status_mutex_);
      owned_ready_projection_.reset();
      owned_initializer_[0].reset();
    }
    async_request(make_request_buffer(request::virtual_hid_keyboard_terminate));
  }

  void async_virtual_hid_keyboard_reset() {
    if (vhd_selected_) {
      std::lock_guard<std::mutex> lock(owned_status_mutex_);
      owned_ready_projection_.reset();
      owned_initializer_[0].reset();
    }
    async_request(make_request_buffer(request::virtual_hid_keyboard_reset));
  }

  void async_virtual_hid_pointing_initialize(bool force = false) {
    vhd_enqueue(vhd_dispatch([this, force] {
      if (!force) {
        if (last_virtual_hid_pointing_ready_ == true) {
          return;
        }
      }

      async_request(make_request_buffer(request::virtual_hid_pointing_initialize), ergoptiplus::remap::vhd::initializer_kind::pointing);
    }));
  }

  void async_virtual_hid_pointing_terminate() {
    if (vhd_selected_) {
      std::lock_guard<std::mutex> lock(owned_status_mutex_);
      owned_ready_projection_.reset();
      owned_initializer_[1].reset();
    }
    async_request(make_request_buffer(request::virtual_hid_pointing_terminate));
  }

  void async_virtual_hid_pointing_reset() {
    if (vhd_selected_) {
      std::lock_guard<std::mutex> lock(owned_status_mutex_);
      owned_ready_projection_.reset();
      owned_initializer_[1].reset();
    }
    async_request(make_request_buffer(request::virtual_hid_pointing_reset));
  }

  void async_post_report(const virtual_hid_device_driver::hid_report::keyboard_input& report) {
    async_owned_report(make_request_buffer(request::post_keyboard_input_report,
                                      report));
  }

  void async_post_report(const virtual_hid_device_driver::hid_report::consumer_input& report) {
    async_owned_report(make_request_buffer(request::post_consumer_input_report,
                                      report));
  }

  void async_post_report(const virtual_hid_device_driver::hid_report::apple_vendor_keyboard_input& report) {
    async_owned_report(make_request_buffer(request::post_apple_vendor_keyboard_input_report,
                                      report));
  }

  void async_post_report(const virtual_hid_device_driver::hid_report::apple_vendor_top_case_input& report) {
    async_owned_report(make_request_buffer(request::post_apple_vendor_top_case_input_report,
                                      report));
  }

  void async_post_report(const virtual_hid_device_driver::hid_report::generic_desktop_input& report) {
    async_owned_report(make_request_buffer(request::post_generic_desktop_input_report,
                                      report));
  }

  void async_post_report(const virtual_hid_device_driver::hid_report::pointing_input& report) {
    async_owned_report(make_request_buffer(request::post_pointing_input_report,
                                      report));
  }

private:
  // This method is executed in the dispatcher thread.
  void clear_state() {
    if (vhd_selected_) {
      std::lock_guard<std::mutex> lock(owned_status_mutex_);
      owned_ready_projection_.reset();
      owned_initializer_={};
    }
    last_virtual_hid_keyboard_ready_ = std::nullopt;
    virtual_hid_keyboard_ready(false);

    last_virtual_hid_pointing_ready_ = std::nullopt;
    virtual_hid_pointing_ready(false);

    last_virtual_hid_keyboard_parameters_ = std::nullopt;
  }

  // This method is executed in the dispatcher thread.
  void create_client() {
    if (vhd_selected_ && (!vhd_owner_ || !vhd_owner_->current())) { warning_reported("official_vhd_reference_unavailable"); return; }
    auto options = pqrs::unix_domain_stream::client_options(
        {
            .max_message_size = constants::unix_domain_stream_max_message_size,
            .heartbeat_timeout = std::chrono::milliseconds(30000),
            .read_timeout = std::chrono::milliseconds(15000),
            .write_timeout = std::chrono::milliseconds(15000),
        },
        {
            .reconnect_interval = std::chrono::milliseconds(1000),
        });

    client_ = std::make_unique<unix_domain_stream::client>(weak_dispatcher_,
                                                           constants::get_server_socket_file_path(),
                                                           options,
                                                           vhd_selected_ ? std::function<bool(const unix_domain_stream::peer_credentials&)>([](const auto&) { return false; }) : unix_domain_stream::default_client_verify_peer,
                                                           std::nullopt,
                                                           vhd_selected_ ? std::optional{vhd_owner_} : std::nullopt);

    client_->connected.connect([this](auto&&) {
      vhd_enqueue(vhd_dispatch([this] {
        if (vhd_selected_) {
          const auto slot=owned_status_slot_.lock();
          const auto session=vhd_owner_->active();
          if (!slot || !session || !session->current()) return;
          std::lock_guard<std::recursive_mutex> lock(vhd_owner_->mutex_);
          if (slot->connection_) {
            if (slot->connection_!=session || slot->generation_!=vhd_owner_->generation_) return;
          } else {
            if (!slot->admission_bound_ || slot->generation_==std::numeric_limits<std::uint64_t>::max() ||
                vhd_owner_->generation_!=slot->generation_+1) return;
            slot->connection_=session;
            slot->generation_=vhd_owner_->generation_;
          }
        }
        connected();
      }));
    });

    client_->connect_failed.connect([this](auto&& error_code) {
      vhd_enqueue(vhd_dispatch([this, error_code] {
        connect_failed(error_code);
      }));
    });

    client_->closed.connect([this] {
      vhd_enqueue(vhd_dispatch([this] {
        closed();

        clear_state();
      }));
    });

    client_->error_occurred.connect([this](auto&& error_code) {
      vhd_enqueue(vhd_dispatch([this, error_code] {
        error_occurred(error_code);
      }));
    });

    client_->peer_verification_failed.connect([this](auto&&) {
      vhd_enqueue(vhd_dispatch([this] {
        warning_reported("peer_verification_failed");
      }));
    });

    client_->received.connect([](auto&&) {
      // Do nothing
    });

    client_->request_received.connect([this](auto request_id, auto&& buffer) {
      vhd_enqueue(vhd_dispatch([this, request_id, buffer] {
        handle_message(buffer,status_origin::daemon_push);

        if (client_) {
          client_->async_respond(request_id,
                                 {});
        }
      }));
    });
  }

  // This method is executed in the dispatcher thread.
  void handle_message(pqrs::not_null_shared_ptr_t<std::vector<uint8_t>> buffer,
                      status_origin origin=status_origin::request_reply) {
    if (buffer->empty()) {
      return;
    }

    const auto& response_buffer = *buffer;
    if (response_buffer.size() % 2 != 0) {
      warning_reported("virtual_hid_device_service::client: message buffer size is invalid");
      return;
    }

    if (vhd_selected_) {
      if (!vhd_owner_ || !vhd_owner_->active()) return;
      for (std::size_t at = 0; at < response_buffer.size(); at += 2) {
        if (response_buffer[at] > static_cast<std::uint8_t>(response::virtual_hid_pointing_ready) || response_buffer[at + 1] > 1) {
          vhd_owner_->retire(); warning_reported("official_vhd_status_noncanonical"); return;
        }
      }
    }
    if (vhd_selected_) {
      const auto session=vhd_owner_->active();
      if (!session || !session->current()) return;
      std::lock_guard<std::mutex> lock(owned_status_mutex_);
      if (owned_status_connection_!=session) {
        owned_status_connection_=session;
        owned_status_bits_={};
        owned_initializer_={};
      }
      if (origin==status_origin::daemon_push) {
        owned_ready_projection_.reset();
        bool canonical=response_buffer.size()==10;
        std::array<bool,5> bits{};
        if (canonical) {
          for (std::size_t at=0;at<10;at+=2) {
            if (response_buffer[at]!=at/2+1 || response_buffer[at+1]>1) { canonical=false; break; }
            bits[at/2]=response_buffer[at+1]!=0;
          }
        }
        if (canonical) {
          // This immutable projection retains the exact latest manager lineage.
          // Its current receipt still requires native delivery, not queued work.
          const auto generation=session->generation_;
          auto delivered_lineage=owned_initializer_;
          for (auto& intent:delivered_lineage) {
            if (!intent) continue;
            // Snapshot the manager's genuine sent/bound lineage at THIS daemon
            // frame. A frame preceding native send cannot gain authority later.
            std::lock_guard<std::mutex> intent_lock(intent->mutex_);
            if (intent->session_.lock()!=session || !intent->id_ ||
                (intent->state_!=ergoptiplus::remap::vhd::initializer_delivery::observation::pending &&
                 intent->state_!=ergoptiplus::remap::vhd::initializer_delivery::observation::delivered)) intent.reset();
          }
          try {
            owned_ready_projection_=std::make_shared<const ready_projection>(
                ready_projection{session,generation,bits,std::move(delivered_lineage)});
          } catch (...) {
            owned_ready_projection_.reset();
            throw;
          }
        }
      }
      for (std::size_t at=0;at<response_buffer.size();at+=2) {
        const auto kind=response_buffer[at];
        if (kind>=1 && kind<=5) owned_status_bits_[kind-1]=(response_buffer[at+1]!=0);
      }
    }
    for (auto index : std::views::iota(size_t{0}, response_buffer.size() / 2)) {
      if (vhd_selected_ && !vhd_owner_->active()) return;
      auto response_type = response(response_buffer[index * 2]);
      auto value = response_buffer[index * 2 + 1];

      switch (response_type) {
        case response::none:
          break;

        case response::driver_activated:
          driver_activated(value);
          break;

        case response::driver_connected:
          driver_connected(value);
          break;

        case response::driver_version_mismatched:
          driver_version_mismatched(value);
          break;

        case response::virtual_hid_keyboard_ready:
          if (vhd_selected_ && value != 0) {
            if (!emit_owned_ready(0)) warning_reported("official_vhd_initialized_ready_unqualified");
            break;
          }
          last_virtual_hid_keyboard_ready_ = value;
          virtual_hid_keyboard_ready(value);
          break;

        case response::virtual_hid_pointing_ready:
          if (vhd_selected_ && value != 0) {
            if (!emit_owned_ready(1)) warning_reported("official_vhd_initialized_ready_unqualified");
            break;
          }
          last_virtual_hid_pointing_ready_ = value;
          virtual_hid_pointing_ready(value);
          break;

        default:
          warning_reported("virtual_hid_device_service::client: unknown message");
          break;
      }
    }
  }

  bool emit_owned_ready(std::size_t kind) {
    const auto slot=owned_status_slot_.lock();
    if (!slot) return false;
    const auto receipt=slot->ready(kind==0 ? ergoptiplus::remap::vhd::initializer_kind::keyboard :
                                        ergoptiplus::remap::vhd::initializer_kind::pointing);
    if (!receipt || !receipt->current()) return false;
    if (kind==0) {
      last_virtual_hid_keyboard_ready_=true;
      virtual_hid_keyboard_ready(true);
    } else {
      last_virtual_hid_pointing_ready_=true;
      virtual_hid_pointing_ready(true);
    }
    return true;
  }

  std::mutex owned_report_mutex_;
  std::function<bool()> owned_report_scope_;
  void bind_owned_report_scope(std::function<bool()> scope) {
    std::lock_guard<std::mutex> lock(owned_report_mutex_);
    owned_report_scope_=std::move(scope);
  }
  void async_owned_report(pqrs::not_null_shared_ptr_t<std::vector<uint8_t>> bytes) {
    if (!vhd_selected_) { async_request(bytes); return; }
    std::function<bool()> scope;
    { std::lock_guard<std::mutex> lock(owned_report_mutex_); scope=owned_report_scope_; }
    const auto kind=(*bytes)[sizeof(client_protocol_version::value_t)]==static_cast<std::uint8_t>(request::post_pointing_input_report)
      ? ergoptiplus::remap::vhd::initializer_kind::pointing : ergoptiplus::remap::vhd::initializer_kind::keyboard;
    const auto status=owned_status_slot_.lock();
    const auto ready=status ? status->ready(kind) : nullptr;
    if (!ready || !scope) return;
    auto output=ergoptiplus::remap::vhd::output_delivery::create(*bytes,[scope=std::move(scope),ready] {
      return ready->current() && scope();
    });
    if (!output) return;
    async_request(bytes,std::nullopt,{},std::move(output));
  }
  bool prepare_owned_start(const std::function<bool()>& current_scope) {
    if (!vhd_selected_ || !current_scope || !current_scope()) return false;
    return vhd_enqueue(vhd_dispatch([this,current_scope] {
      if (!current_scope()) return;
      if (client_) return;
      create_client();
      if (client_ && current_scope()) client_->async_start();
    }));
  }
  bool prepare_owned_keyboard(
      const pqrs::karabiner::driverkit::virtual_hid_device_service::virtual_hid_keyboard_parameters& parameters,
      const std::function<bool()>& current_scope) {
    if (!vhd_selected_ || !current_scope || !current_scope()) return false;
    return vhd_enqueue(vhd_dispatch([this,parameters,current_scope] {
      if (!current_scope()) return;
      last_virtual_hid_keyboard_parameters_=parameters;
      async_request(make_request_buffer(request::virtual_hid_keyboard_initialize,parameters),
          ergoptiplus::remap::vhd::initializer_kind::keyboard,current_scope);
    }));
  }
  bool prepare_owned_pointing(const std::function<bool()>& current_scope) {
    if (!vhd_selected_ || !current_scope || !current_scope()) return false;
    return vhd_enqueue(vhd_dispatch([this,current_scope] {
      if (!current_scope()) return;
      async_request(make_request_buffer(request::virtual_hid_pointing_initialize),
          ergoptiplus::remap::vhd::initializer_kind::pointing,current_scope);
    }));
  }
  void async_request(pqrs::not_null_shared_ptr_t<std::vector<uint8_t>> request_buffer,
      std::optional<ergoptiplus::remap::vhd::initializer_kind> initializer_kind = std::nullopt,
      std::function<bool()> current_scope = {},
      std::shared_ptr<ergoptiplus::remap::vhd::output_delivery> output = {}) {
    if (output && (!vhd_selected_ || !output->source_current())) return;
    if (current_scope && (!initializer_kind || !current_scope())) return;
    auto intent = vhd_selected_ && initializer_kind
        ? (current_scope ? ergoptiplus::remap::vhd::initializer_delivery::create(*request_buffer,*initializer_kind,current_scope) :
           ergoptiplus::remap::vhd::initializer_delivery::create(*request_buffer, *initializer_kind)) : nullptr;
    if (current_scope && !intent) return;
    vhd_enqueue(vhd_dispatch([this, request_buffer, intent, current_scope, output] {
      if (output && !output->source_current()) return;
      if (current_scope && !current_scope()) { if (intent) intent->refuse(); return; }
      if (client_) {
        auto callback = vhd_callback([this, output](auto&& error_code, auto&& response_buffer) {
              if (output && error_code==asio::error::operation_aborted) return;
              vhd_enqueue(vhd_dispatch([this, error_code, response_buffer] {
                if (error_code) {
                  error_occurred(error_code);
                  return;
                }

                handle_message(response_buffer);
                if (vhd_selected_) {
                  // A daemon push may precede this reply. The retained projection
                  // cannot pass until its exact native manager receipt is delivered.
                  emit_owned_ready(0);
                  emit_owned_ready(1);
                }
              }));
            });
        if (intent) {
          const auto session=vhd_owner_->active();
          std::lock_guard<std::mutex> lock(owned_status_mutex_);
          if (session && session->current()) {
            if (owned_status_connection_!=session) {
              owned_status_connection_=session;
              owned_status_bits_={};
              owned_initializer_={};
            }
            const auto index=intent->kind_==ergoptiplus::remap::vhd::initializer_kind::keyboard ? 0u : 1u;
            owned_ready_projection_.reset();
            owned_initializer_[index]=intent;
          }
        }
        if (output) client_->async_output_request(*request_buffer,std::move(callback),output);
        else if (intent) client_->async_initializer_request(*request_buffer, std::move(callback), intent);
        else client_->async_request(*request_buffer, std::move(callback));
      }
    }));
  }

  pqrs::not_null_shared_ptr_t<std::vector<uint8_t>> make_request_buffer(request request_type) const {
    pqrs::not_null_shared_ptr_t<std::vector<uint8_t>> buffer(std::make_shared<std::vector<uint8_t>>());

    append_data(*buffer, client_protocol_version::embedded_client_protocol_version);
    append_data(*buffer, request_type);

    return buffer;
  }

  template <typename T>
  pqrs::not_null_shared_ptr_t<std::vector<uint8_t>> make_request_buffer(request request_type, const T& data) const {
    auto buffer = make_request_buffer(request_type);

    append_data(*buffer, data);

    return buffer;
  }

  template <typename T>
  void append_data(std::vector<uint8_t>& buffer, const T& data) const {
    static_assert(std::is_trivially_copyable_v<T>);

    auto size = buffer.size();
    buffer.resize(size + sizeof(data));
    std::memcpy(buffer.data() + size,
                std::addressof(data),
                sizeof(data));
  }

  bool owned_stop_completed_=false;
  std::function<void()> owned_stop_progress_;
  std::mutex owned_status_mutex_;
  std::weak_ptr<owned_status> owned_status_slot_;
  std::shared_ptr<const ready_projection> owned_ready_projection_;
  std::shared_ptr<ergoptiplus::remap::vhd::connection> owned_status_connection_;
  std::array<std::optional<bool>,5> owned_status_bits_;
  std::array<std::shared_ptr<ergoptiplus::remap::vhd::initializer_delivery>,2> owned_initializer_;
  const std::shared_ptr<std::atomic<bool>> vhd_alive_ = std::make_shared<std::atomic<bool>>(true);
  bool vhd_selected_ = false;
  const std::shared_ptr<ergoptiplus::remap::vhd::broker_owner> vhd_owner_;
  std::unique_ptr<unix_domain_stream::client> client_;

  std::optional<bool> last_virtual_hid_keyboard_ready_;
  std::optional<bool> last_virtual_hid_pointing_ready_;

  std::optional<pqrs::karabiner::driverkit::virtual_hid_device_service::virtual_hid_keyboard_parameters> last_virtual_hid_keyboard_parameters_;
};
} // namespace pqrs::karabiner::driverkit::virtual_hid_device_service
