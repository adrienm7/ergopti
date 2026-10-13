#pragma once

// pqrs::osx::iokit_service_monitor v6.2.0

// (C) Copyright Takayama Fumihiko 2018.
// Distributed under the Boost Software License, Version 1.0.
// (See https://www.boost.org/LICENSE_1_0.txt)

// `pqrs::osx::iokit_service_monitor` can be used safely in a multi-threaded environment.

#include <algorithm>
#include <atomic>
#include <functional>
#include <memory>
#include <nod/nod.hpp>
#include <optional>
#include <pqrs/cf/run_loop_thread.hpp>
#include <pqrs/dispatcher.hpp>
#include <pqrs/gsl.hpp>
#include <pqrs/osx/iokit_iterator.hpp>
#include <pqrs/osx/iokit_object_ptr.hpp>
#include <pqrs/osx/iokit_registry_entry.hpp>
#include <pqrs/osx/iokit_types.hpp>
#include <pqrs/osx/kern_return.hpp>
#include <unordered_set>

namespace pqrs::osx {
class iokit_hid_manager;
class iokit_service_monitor final : dispatcher::extra::dispatcher_client {
public:
  // Signals (invoked from the dispatcher thread)

  nod::signal<void(iokit_registry_entry_id::value_t, iokit_object_ptr)> service_matched;
  nod::signal<void(iokit_registry_entry_id::value_t)> service_terminated;
  nod::signal<void(const std::string&, kern_return)> error_occurred;

  nod::signal<void(bool)> ergopti_initial_inventory;
  nod::signal<void()> ergopti_inventory_failed;

  // Methods

  iokit_service_monitor(const iokit_service_monitor&) = delete;

  // Creating cf::run_loop_thread instances may rarely prevent CFRunLoop processing from starting,
  // particularly when the system is under heavy load on macOS 26.
  // In that situation, cf::run_loop_thread terminates the process to avoid hanging indefinitely.
  // If monitor owned its own cf::run_loop_thread, repeated monitor construction would also repeatedly expose that failure path.
  // For that reason, cf::run_loop_thread is injected from the outside.
  iokit_service_monitor(std::weak_ptr<dispatcher::dispatcher> weak_dispatcher,
                        pqrs::not_null_shared_ptr_t<cf::run_loop_thread> run_loop_thread,
                        CFDictionaryRef _Nonnull matching_dictionary)
      : dispatcher_client(weak_dispatcher),
        run_loop_thread_(run_loop_thread),
        matching_dictionary_(matching_dictionary),
        notification_port_(nullptr),
        scan_timer_(*this) {
  }

  ~iokit_service_monitor() override {
    // dispatcher_client

    detach_from_dispatcher([this] {
      scan_timer_.stop();
    });

    // run_loop_thread

    run_loop_thread_->enqueue(^{
      stop();
    });

    // Wait until all tasks are processed

    auto wait = make_thread_wait();
    run_loop_thread_->enqueue(^{
      wait->notify();
    });
    wait->wait_notice();
  }

  void async_start() {
    run_loop_thread_->enqueue(^{
      start();
    });
  }

  void async_stop() {
    run_loop_thread_->enqueue(^{
      stop();
    });
  }

private:
  friend class iokit_hid_manager;
  class owned_registration final {
    friend class iokit_service_monitor;
    friend class iokit_hid_manager;
    std::atomic<bool> native_started_{false};
    std::atomic<bool> invalidated_{false};
    owned_registration()=default;
    bool current() const noexcept {
      return native_started_.load(std::memory_order_acquire) &&
             !invalidated_.load(std::memory_order_acquire);
    }
  };
  std::shared_ptr<owned_registration> owned_registration_;
  bool async_owned_start(std::function<bool()> scope,
      std::function<void(std::shared_ptr<const owned_registration>)> completion) {
    if (!scope || !completion || owned_registration_) return false;
    auto receipt=std::shared_ptr<owned_registration>(new owned_registration);
    owned_registration_=receipt;
    run_loop_thread_->enqueue(^{
      bool permitted=false;
      try { permitted=scope(); } catch (...) {}
      if (permitted) {
        start();
        // These are native resources obtained by the original start body.
        // Empty device enumeration is permitted, absent registrations are not.
        permitted=owned_initial_inventory_valid_ && notification_port_ &&
            matched_notification_.get() && terminated_notification_.get() &&
            matched_notification_.valid() && terminated_notification_.valid();
        try { permitted=permitted && scope(); } catch (...) { permitted=false; }
      }
      if (permitted && !receipt->invalidated_.load(std::memory_order_acquire))
        receipt->native_started_.store(true,std::memory_order_release);
      else receipt->invalidated_.store(true,std::memory_order_release);
      enqueue_to_dispatcher([receipt,completion] {
        completion(receipt->current() ? receipt : nullptr);
      });
    });
    return true; // Admission only; completion is on the original dispatcher.
  }
  // This method is executed in run_loop_thread_.
  void start() {
    owned_initial_inventory_valid_=false;
    bool ergopti_initial_valid = true;
    if (!ergopti_inventory_live_) ergopti_inventory_live_ = std::make_shared<bool>(true);
    if (!notification_port_) {
      notification_port_ = IONotificationPortCreate(type_safe::get(iokit_mach_port::null));
      if (!notification_port_) {
        enqueue_to_dispatcher([this] {
          error_occurred("IONotificationPortCreate is failed.", kIOReturnError);
        });
        return;
      }

      if (auto loop_source = IONotificationPortGetRunLoopSource(notification_port_)) {
        run_loop_thread_->add_source(loop_source);
      } else {
        IONotificationPortDestroy(notification_port_);
        notification_port_ = nullptr;

        enqueue_to_dispatcher([this] {
          error_occurred("IONotificationPortGetRunLoopSource is failed.", kIOReturnError);
        });
        return;
      }
    }

    // kIOMatchedNotification

    if (!matched_notification_.get() &&
        *matching_dictionary_) {
      io_iterator_t it = IO_OBJECT_NULL;
      CFRetain(*matching_dictionary_);
      kern_return r = IOServiceAddMatchingNotification(notification_port_,
                                                       kIOFirstMatchNotification,
                                                       *matching_dictionary_,
                                                       &static_matched_callback,
                                                       static_cast<void*>(this),
                                                       &it);
      if (r) {
        matched_notification_ = adopt_iokit_iterator(it);
        ergopti_initial_valid = ergopti_initial_valid && matched_notification_.valid();
        matched_callback(make_services(matched_notification_));
        ergopti_initial_valid = ergopti_initial_valid && matched_notification_.valid();
      } else {
        enqueue_to_dispatcher([this, r] {
          error_occurred("IOServiceAddMatchingNotification is failed.", r);
        });
      }
    }

    // kIOTerminatedNotification

    if (!terminated_notification_.get() &&
        *matching_dictionary_) {
      io_iterator_t it = IO_OBJECT_NULL;
      CFRetain(*matching_dictionary_);
      kern_return r = IOServiceAddMatchingNotification(notification_port_,
                                                       kIOTerminatedNotification,
                                                       *matching_dictionary_,
                                                       &static_terminated_callback,
                                                       static_cast<void*>(this),
                                                       &it);
      if (r) {
        terminated_notification_ = adopt_iokit_iterator(it);
        ergopti_initial_valid = ergopti_initial_valid && terminated_notification_.valid();
        terminated_callback(make_services(terminated_notification_));
        ergopti_initial_valid = ergopti_initial_valid && terminated_notification_.valid();
      } else {
        enqueue_to_dispatcher([this, r] {
          error_occurred("IOServiceAddMatchingNotification is failed.", r);
        });
      }
    }

    const bool ergopti_success = ergopti_initial_valid && matched_notification_.get() && terminated_notification_.get();
    owned_initial_inventory_valid_=ergopti_success;
    enqueue_to_dispatcher([this, weak = std::weak_ptr<bool>(ergopti_inventory_live_), ergopti_success] {
      const auto live = weak.lock();
      if (!live || !*live) return;
      ergopti_initial_inventory(ergopti_success);
    });

    //
    // Setup scan timer
    //

    enqueue_to_dispatcher([this] {
      // There are rare cases where IOFirstMatchNotification and kIOTerminatedNotification are not triggered.
      // In such cases, service_terminated is never called for the terminated service.
      // To avoid this issue, periodic scans will be performed, and callbacks will be invoked for services that didn't receive the notification.

      scan_timer_.start(
          [this] {
            if (!*matching_dictionary_) {
              return;
            }

            io_iterator_t it = IO_OBJECT_NULL;
            CFRetain(*matching_dictionary_);
            kern_return r = IOServiceGetMatchingServices(type_safe::get(iokit_mach_port::null),
                                                         *matching_dictionary_,
                                                         &it);
            if (r) {
              const auto ergopti_iterator = iokit_iterator(it);
              const bool ergopti_valid_before = ergopti_iterator.valid();
              auto services = make_services(adopt_iokit_iterator(it));
              if (!ergopti_valid_before || !ergopti_iterator.valid()) ergopti_inventory_failed();

              // Call service_matched

              for (const auto& s : services) {
                if (auto registry_entry_id = s.find_registry_entry_id()) {
                  invoke_service_matched(*registry_entry_id, s);
                } else {
                  ergopti_inventory_failed();
                }
              }

              // Call service_terminated

              std::unordered_set<iokit_registry_entry_id::value_t> terminated_registry_entry_ids;

              for (const auto stored_registry_entry_id : registry_entry_ids_) {
                if (!std::ranges::any_of(services, [stored_registry_entry_id](const auto& s) {
                      if (auto registry_entry_id = s.find_registry_entry_id()) {
                        return stored_registry_entry_id == *registry_entry_id;
                      }
                      return false;
                    })) {
                  terminated_registry_entry_ids.insert(stored_registry_entry_id);
                }
              }

              for (const auto terminated_registry_entry_id : terminated_registry_entry_ids) {
                invoke_service_terminated(terminated_registry_entry_id);
              }
            } else {
              enqueue_to_dispatcher([this, r] {
                error_occurred("IOServiceGetMatchingServices is failed.", r);
              });
            }
          },
          std::chrono::milliseconds(3000));
    });
  }

  // This method is executed in run_loop_thread_.
  void stop() {
    ergopti_inventory_live_.reset();
    if (owned_registration_) owned_registration_->invalidated_.store(true,std::memory_order_release);
    matched_notification_ = iokit_iterator();
    terminated_notification_ = iokit_iterator();

    if (notification_port_) {
      if (auto loop_source = IONotificationPortGetRunLoopSource(notification_port_)) {
        run_loop_thread_->remove_source(loop_source);
      }

      IONotificationPortDestroy(notification_port_);
      notification_port_ = nullptr;
    }

    enqueue_to_dispatcher([this] {
      scan_timer_.stop();
      registry_entry_ids_.clear();
    });
  }

  static void static_matched_callback(void* _Nonnull refcon, io_iterator_t iterator) {
    auto self = static_cast<iokit_service_monitor*>(refcon);
    if (!self) {
      return;
    }

    const auto ergopti_entry_owner = std::weak_ptr<bool>(self->ergopti_inventory_live_);
    const auto ergopti_iterator = iokit_iterator(iterator);
    const bool ergopti_valid_before = ergopti_iterator.valid();
    auto services = make_services(iokit_iterator(iterator));
    const bool ergopti_valid = ergopti_valid_before && ergopti_iterator.valid();

    self->run_loop_thread_->enqueue(^{
      const auto ergopti_live = ergopti_entry_owner.lock();
      if (!ergopti_live || !*ergopti_live) return;
      if (!ergopti_valid) self->enqueue_to_dispatcher([self, weak = ergopti_entry_owner] { const auto live = weak.lock(); if (live && *live) self->ergopti_inventory_failed(); });
      self->matched_callback(services);
    });
  }

  void matched_callback(const std::vector<iokit_registry_entry>& services) {
    for (const auto& s : services) {
      if (auto registry_entry_id = s.find_registry_entry_id()) {
        enqueue_to_dispatcher([this, registry_entry_id, s] {
          invoke_service_matched(*registry_entry_id, s);
        });
      } else {
        enqueue_to_dispatcher([this, weak = std::weak_ptr<bool>(ergopti_inventory_live_)] { const auto live = weak.lock(); if (live && *live) ergopti_inventory_failed(); });
      }
    }
  }

  // This method is executed in the dispatcher thread.
  void invoke_service_matched(iokit_registry_entry_id::value_t registry_entry_id,
                              iokit_registry_entry service) {
    if (!registry_entry_ids_.contains(registry_entry_id)) {
      registry_entry_ids_.insert(registry_entry_id);
      service_matched(registry_entry_id, service.get());
    }
  }

  static void static_terminated_callback(void* _Nonnull refcon, io_iterator_t iterator) {
    auto self = static_cast<iokit_service_monitor*>(refcon);
    if (!self) {
      return;
    }

    const auto ergopti_entry_owner = std::weak_ptr<bool>(self->ergopti_inventory_live_);
    const auto ergopti_iterator = iokit_iterator(iterator);
    const bool ergopti_valid_before = ergopti_iterator.valid();
    auto services = make_services(iokit_iterator(iterator));
    const bool ergopti_valid = ergopti_valid_before && ergopti_iterator.valid();

    self->run_loop_thread_->enqueue(^{
      const auto ergopti_live = ergopti_entry_owner.lock();
      if (!ergopti_live || !*ergopti_live) return;
      if (!ergopti_valid) self->enqueue_to_dispatcher([self, weak = ergopti_entry_owner] { const auto live = weak.lock(); if (live && *live) self->ergopti_inventory_failed(); });
      self->terminated_callback(services);
    });
  }

  void terminated_callback(const std::vector<iokit_registry_entry>& services) {
    for (const auto& s : services) {
      if (auto registry_entry_id = s.find_registry_entry_id()) {
        enqueue_to_dispatcher([this, registry_entry_id] {
          invoke_service_terminated(*registry_entry_id);
        });
      } else {
        enqueue_to_dispatcher([this, weak = std::weak_ptr<bool>(ergopti_inventory_live_)] { const auto live = weak.lock(); if (live && *live) ergopti_inventory_failed(); });
      }
    }
  }

  // This method is executed in the dispatcher thread.
  void invoke_service_terminated(iokit_registry_entry_id::value_t registry_entry_id) {
    if (registry_entry_ids_.contains(registry_entry_id)) {
      registry_entry_ids_.erase(registry_entry_id);
      service_terminated(registry_entry_id);
    }
  }

  [[nodiscard]] static std::vector<iokit_registry_entry> make_services(const iokit_iterator& iterator) {
    std::vector<iokit_registry_entry> services;

    while (auto next = iterator.next()) {
      services.emplace_back(iokit_registry_entry(next));
    }

    return services;
  }

  bool owned_initial_inventory_valid_=false;
  std::shared_ptr<bool> ergopti_inventory_live_;
  pqrs::not_null_shared_ptr_t<cf::run_loop_thread> run_loop_thread_;
  cf::cf_ptr<CFDictionaryRef> matching_dictionary_;

  IONotificationPortRef _Nullable notification_port_;
  iokit_iterator matched_notification_;
  iokit_iterator terminated_notification_;

  pqrs::dispatcher::extra::timer scan_timer_;
  std::unordered_set<iokit_registry_entry_id::value_t> registry_entry_ids_;
};
} // namespace pqrs::osx
