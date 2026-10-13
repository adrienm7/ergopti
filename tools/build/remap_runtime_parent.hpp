#pragma once

// Native lifetime observation only; this grants no signing, socket or capture authority.
#include "remap_runtime_identity.hpp"
#include "remap_runtime_parent_policy.hpp"
#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <fcntl.h>
#include <libproc.h>
#include <sys/event.h>
#include <unistd.h>
#include <condition_variable>
#include <cstdint>
#include <exception>
#include <memory>
#include <mutex>
#include <new>
#include <optional>
#include <thread>

namespace ergoptiplus::remap {

enum class watch_state { prepared, active, refused_with_resources, retiring, retired, tainted };

class owned_console_parent_watch final : public std::enable_shared_from_this<owned_console_parent_watch> {
public:
  owned_console_parent_watch(const owned_console_parent_watch&) = delete;
  owned_console_parent_watch& operator=(const owned_console_parent_watch&) = delete;
  owned_console_parent_watch(owned_console_parent_watch&&) = delete;
  owned_console_parent_watch& operator=(owned_console_parent_watch&&) = delete;

  [[nodiscard]] static std::shared_ptr<owned_console_parent_watch> make(void (*callback)()) {
    if (!callback) {
      return nullptr;
    }
    const auto sealed = native_identity();
    if (!sealed) {
      return nullptr;
    }

    // Allocate retained ownership before acquiring any native descriptor.
    auto watch = std::shared_ptr<owned_console_parent_watch>(new owned_console_parent_watch(*sealed, callback));
    watch->data_->queued = std::make_unique<queued_callback>();
    watch->data_->queued->owner = watch;
    const auto descriptor = ::kqueue();
    if (descriptor < 0) {
      return nullptr;
    }
    watch->data_->descriptor = descriptor;
    const auto flags = ::fcntl(descriptor, F_GETFD);
    if (flags < 0 || ::fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) != 0) {
      watch->data_->phase = watch_state::refused_with_resources;
      return watch;
    }

    struct kevent change {};
    struct kevent receipt {};
    EV_SET(&change, static_cast<uintptr_t>(sealed->parent_pid), EVFILT_PROC,
           EV_ADD | EV_ENABLE | EV_ONESHOT | EV_RECEIPT, NOTE_EXIT, 0, nullptr);
    const auto count = ::kevent(descriptor, &change, 1, &receipt, 1, nullptr);
    if (count != 1 || receipt.ident != static_cast<uintptr_t>(sealed->parent_pid) ||
        receipt.filter != EVFILT_PROC || (receipt.flags & EV_ERROR) == 0 || receipt.data != 0 ||
        !same_native_identity(*sealed)) {
      watch->data_->phase = watch_state::refused_with_resources;
    }
    return watch;
  }

  [[nodiscard]] bool activate() {
    if (!same_native_identity(data_->sealed)) {
      request_stop();
      return false;
    }
    std::lock_guard<std::mutex> lock(data_->mutex);
    if (data_->phase != watch_state::prepared || data_->stop || data_->terminal_observed || data_->descriptor < 0) {
      return false;
    }
    data_->phase = watch_state::active;
    data_->armed = true;
    try {
      worker_ = std::thread(run_worker, data_);
    } catch (...) {
      data_->armed = false;
      data_->stop = true;
      data_->phase = watch_state::refused_with_resources;
      return false;
    }
    return true;
  }

  [[nodiscard]] bool current() const noexcept {
    {
      std::lock_guard<std::mutex> lock(data_->mutex);
      if (!active_locked(*data_) || data_->terminal_observed) {
        return false;
      }
    }
    if (!same_native_identity(data_->sealed)) {
      return false;
    }
    std::lock_guard<std::mutex> lock(data_->mutex);
    return active_locked(*data_) && !data_->terminal_observed;
  }

  [[nodiscard]] watch_state state() const noexcept {
    std::lock_guard<std::mutex> lock(data_->mutex);
    return data_->phase;
  }

  void request_stop() noexcept {
    std::lock_guard<std::mutex> lock(data_->mutex);
    data_->armed = false;
    data_->stop = true;
    if (data_->phase != watch_state::retired && data_->phase != watch_state::tainted) {
      data_->phase = watch_state::retiring;
    }
    data_->changed.notify_all();
  }

  [[nodiscard]] bool retire() noexcept {
    request_stop();
    // Reentrant retirement may revoke, but cannot acknowledge its own held frame.
    if (emitting_watch_ == this) {
      return false;
    }
    std::lock_guard<std::mutex> retirement(retirement_mutex_);
    {
      std::lock_guard<std::mutex> lock(data_->mutex);
      if (data_->phase == watch_state::retired) {
        return true;
      }
      if (data_->phase == watch_state::tainted) {
        return false;
      }
    }
    try {
      if (worker_.joinable()) {
        worker_.join();
      }
    } catch (...) {
      std::lock_guard<std::mutex> lock(data_->mutex);
      data_->phase = watch_state::tainted;
      return false;
    }
    std::unique_lock<std::mutex> lock(data_->mutex);
    data_->changed.wait(lock, [this] { return data_->callback_frames == 0; });
    if (data_->descriptor >= 0) {
      const auto descriptor = data_->descriptor;
      // A failed close is ambiguous. Never retry its numeric descriptor or reuse debt.
      data_->descriptor = -1;
      if (::close(descriptor) != 0) {
        data_->phase = watch_state::tainted;
        return false;
      }
    }
    data_->phase = watch_state::retired;
    return true;
  }

  [[nodiscard]] static const owned_console_parent_watch* emitting_watch() noexcept {
    return emitting_watch_;
  }

  ~owned_console_parent_watch() {
    // The consuming runtime must retain unresolved debt. Destruction never grants an ACK.
    if (!retire()) {
      std::terminate();
    }
  }

private:
  struct queued_callback final {
    std::weak_ptr<owned_console_parent_watch> owner;
  };

  struct shared_state final {
    explicit shared_state(parent_policy::identity identity, void (*handler)())
        : sealed(identity), callback(handler) {}

    const parent_policy::identity sealed;
    void (*const callback)();
    std::mutex mutex;
    std::condition_variable changed;
    std::unique_ptr<queued_callback> queued;
    int descriptor = -1;
    watch_state phase = watch_state::prepared;
    bool armed = false;
    bool stop = false;
    bool notification_queued = false;
    bool terminal_observed = false;
    std::uint64_t callback_frames = 0;
  };

  class callback_frame final {
  public:
    explicit callback_frame(owned_console_parent_watch& owner) noexcept
        : owner_(owner), previous_(emitting_watch_) {
      emitting_watch_ = &owner_;
    }
    ~callback_frame() {
      emitting_watch_ = previous_;
      std::lock_guard<std::mutex> lock(owner_.data_->mutex);
      --owner_.data_->callback_frames;
      owner_.data_->changed.notify_all();
    }
    callback_frame(const callback_frame&) = delete;
    callback_frame& operator=(const callback_frame&) = delete;

  private:
    owned_console_parent_watch& owner_;
    const owned_console_parent_watch* const previous_;
  };

  explicit owned_console_parent_watch(parent_policy::identity sealed, void (*callback)())
      : data_(std::make_shared<shared_state>(sealed, callback)) {}

  [[nodiscard]] static bool active_locked(const shared_state& data) noexcept {
    return data.phase == watch_state::active && data.armed && !data.stop;
  }

  [[nodiscard]] static bool native_console_role() noexcept {
    const auto bundle = CFBundleGetMainBundle();
    if (!bundle) {
      return false;
    }
    const auto actual = CFBundleGetIdentifier(bundle);
    const auto identifier = identity::identifier(identity::role::console);
    const auto expected = CFStringCreateWithBytes(kCFAllocatorDefault,
                                                 reinterpret_cast<const UInt8*>(identifier.data()),
                                                 static_cast<CFIndex>(identifier.size()),
                                                 kCFStringEncodingUTF8, false);
    if (!expected) {
      return false;
    }
    const auto matches = actual && CFEqual(actual, expected);
    CFRelease(expected);
    return matches;
  }

  [[nodiscard]] static parent_policy::process_frame process_frame(pid_t requested) noexcept {
    struct proc_bsdinfo info {};
    const auto bytes = ::proc_pidinfo(requested, PROC_PIDTBSDINFO, 0, &info, sizeof(info));
    if (bytes != static_cast<int>(sizeof(info)) || info.pbi_pid != static_cast<std::uint32_t>(requested)) {
      return {false, 0, 0, 0, 0, 0};
    }
    return {true, static_cast<std::int32_t>(info.pbi_pid), static_cast<std::int32_t>(info.pbi_ppid),
            info.pbi_status, info.pbi_start_tvsec, info.pbi_start_tvusec};
  }

  [[nodiscard]] static std::optional<parent_policy::identity> native_identity() noexcept {
    if (!native_console_role()) {
      return std::nullopt;
    }
    const auto self = ::getpid();
    const auto parent = ::getppid();
    if (self <= 1 || parent <= 1 || self == parent) {
      return std::nullopt;
    }
    const parent_policy::observation observed{parent_policy::console_role::owned_console,
                                              process_frame(self), process_frame(parent)};
    if (::getpid() != self || ::getppid() != parent || !native_console_role()) {
      return std::nullopt;
    }
    return parent_policy::qualify(observed);
  }

  [[nodiscard]] static bool same_native_identity(const parent_policy::identity& sealed) noexcept {
    const auto actual = native_identity();
    return actual && actual->self_pid == sealed.self_pid && actual->parent_pid == sealed.parent_pid &&
           actual->self_start_seconds == sealed.self_start_seconds &&
           actual->self_start_microseconds == sealed.self_start_microseconds &&
           actual->parent_start_seconds == sealed.parent_start_seconds &&
           actual->parent_start_microseconds == sealed.parent_start_microseconds;
  }

  static void emit_on_main(void* raw) noexcept {
    std::unique_ptr<queued_callback> queued(static_cast<queued_callback*>(raw));
    const auto owner = queued->owner.lock();
    if (!owner) {
      return;
    }
    {
      std::lock_guard<std::mutex> lock(owner->data_->mutex);
      if (!active_locked(*owner->data_) || !owner->data_->notification_queued) {
        return;
      }
      ++owner->data_->callback_frames;
    }
    // The debt guard unwinds before the last retained watch; callback runs outside locks.
    callback_frame frame(*owner);
    owner->data_->callback();
  }

  static void queue_termination(const std::shared_ptr<shared_state>& data) noexcept {
    queued_callback* queued = nullptr;
    {
      std::lock_guard<std::mutex> lock(data->mutex);
      // Monitor failure permanently revokes admission before the main-queue endpoint.
      if (data->terminal_observed) {
        return;
      }
      data->terminal_observed = true;
      if (!active_locked(*data) || data->notification_queued) {
        return;
      }
      data->notification_queued = true;
      queued = data->queued.release();
    }
    ::dispatch_async_f(::dispatch_get_main_queue(), queued, emit_on_main);
  }

  static void run_worker(std::shared_ptr<shared_state> data) noexcept {
    for (;;) {
      {
        std::lock_guard<std::mutex> lock(data->mutex);
        if (!active_locked(*data)) {
          return;
        }
      }
      struct kevent event {};
      const struct timespec idle {0, 100000000};
      const auto count = ::kevent(data->descriptor, nullptr, 0, &event, 1, &idle);
      if (count < 0 || count > 1 || !same_native_identity(data->sealed)) {
        queue_termination(data);
        return;
      }
      if (count == 1) {
        // Both the expected exit and unknown/error observations revoke the owner once.
        const auto expected_exit = event.ident == static_cast<uintptr_t>(data->sealed.parent_pid) &&
                                   event.filter == EVFILT_PROC && (event.flags & EV_ERROR) == 0 &&
                                   (event.fflags & NOTE_EXIT) != 0;
        (void)expected_exit;
        queue_termination(data);
        return;
      }
    }
  }

  std::shared_ptr<shared_state> data_;
  std::thread worker_;
  std::mutex retirement_mutex_;
  inline static thread_local const owned_console_parent_watch* emitting_watch_ = nullptr;
};

} // namespace ergoptiplus::remap
