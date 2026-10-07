"""Fixed VirtualHID projection after the retained Ergopti auth projection.

This module handles source bytes only. It cannot mint a native capability.
"""

import hashlib
import math
import re
import time

LOWER = "vendor/vendor/include/pqrs/unix_domain_stream/client.hpp"
PEER = "vendor/vendor/include/pqrs/unix_domain_stream/impl/peer.hpp"
REQUESTS = "vendor/vendor/include/pqrs/unix_domain_stream/impl/request_manager.hpp"
CORE = "src/apps/CoreService/include/core_service/daemon/device_grabber.hpp"
UPPER = "vendor/Karabiner-DriverKit-VirtualHIDDevice/include/pqrs/karabiner/driverkit/virtual_hid_device_service/client.hpp"
PREIMAGES = (
    (LOWER, "bc47c6499a0e315353ce4af3d172f1f3020bc1d23cf337975f36262aa3b1f49c"),
    (PEER, "f6385a2761bf38d5828ac3733cfaa79c40eda22d756577fe801ffd2114266336"),
    (REQUESTS, "23250dd6733fbfe43cdd030ee575bf0b6a271330a340f96c71541ef54cf27dfc"),
    (CORE, "9aa96f3ce8e2cc8c07a08f4c0d4630d6a70f82d7959030289b7b0e21c6e7a43a"),
    (UPPER, "0e590ff9f652a92dd40fb9c47dd0d61e98f4eb14f0983918a29b223f9c27a8c7"),
)
HEADER_SHA256 = "ca6d4cf40c726ab7c844fdae2bb7ff5dcee476cc2c061944ee76eab385aa1b65"


class VHDTransportRefusal(RuntimeError):
    """The complete fixed source projection cannot be admitted."""


def budget(deadline):
    if type(deadline) not in (float, int) or not math.isfinite(deadline):
        raise VHDTransportRefusal("vhd_deadline_refused")
    if time.monotonic() >= deadline:
        raise VHDTransportRefusal("vhd_deadline_expired")


class Recipe:
    def __init__(self, data):
        self.source = data.decode("utf-8", "strict")

    def one(self, old, new):
        if self.source.count(old) != 1:
            raise VHDTransportRefusal("vhd_anchor_refused:" + old[:60])
        self.source = self.source.replace(old, new)

    def result(self):
        return self.source.encode("utf-8")


def lambda_end(source, begin):
    # Fixed lexical extraction conserves the original callable body; it does
    # not infer runtime identity or permit caller-supplied replacement text.
    at = source.find("{", begin)
    if at < 0:
        raise VHDTransportRefusal("vhd_lambda_refused")
    depth, quote, comment = 1, None, None
    at += 1
    while at < len(source) and depth:
        char, pair = source[at], source[at : at + 2]
        if comment == "line":
            if char == "\n":
                comment = None
        elif comment == "block":
            if pair == "*/":
                comment = None
                at += 1
        elif quote:
            if char == "\\":
                at += 1
            elif char == quote:
                quote = None
        elif pair == "//":
            comment = "line"
            at += 1
        elif pair == "/*":
            comment = "block"
            at += 1
        elif char in "\"'":
            quote = char
        elif char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
        at += 1
    if depth:
        raise VHDTransportRefusal("vhd_lambda_refused")
    return at


def tracked_dispatchers(source, *, weak=False):
    pattern = re.compile(r"\[[^\[\]\n]*(?:self|this)[^\[\]\n]*\]")
    chosen = []
    for match in pattern.finditer(source):
        before = source[max(0, match.start() - 250) : match.start()]
        # Only existing dispatcher registration sites. Native handlers retain
        # native debt separately; close ports added later are terminal controls.
        direct = re.search(r"enqueue_to_dispatcher\(\s*$", before)
        scoped = re.search(r"notification_scope_\.enqueue\(\s*notification_token,\s*$", before)
        retry = re.search(r"reconnect_task_\.enqueue\(\s*$", before)
        if direct or scoped or retry:
            chosen.append(
                (
                    match.start(),
                    match.end(),
                    "self->"
                    if re.search(
                        r"self->(?:notification_scope_\.enqueue|enqueue_to_dispatcher)\([^;]*$",
                        before,
                    )
                    else "",
                )
            )
    for begin, capture_end, prefix in reversed(chosen):
        end = lambda_end(source, capture_end)
        source = source[:begin] + prefix + "vhd_dispatch(" + source[begin:end] + ")" + source[end:]
    return source


def tracked_native_posts(source):
    positions = []
    capture = re.compile(r"\[[^\[\]\n]*(?:self|this)[^\[\]\n]*\]")
    for call in re.finditer(r"asio::post\(", source):
        found = capture.search(source, call.end())
        if found is None:
            raise VHDTransportRefusal("vhd_native_post_refused")
        arguments = source[call.end() : found.start()]
        if "shared_self->" in arguments:
            prefix = "shared_self->"
        elif "self->" in arguments:
            prefix = "self->"
        else:
            prefix = ""
        positions.append((found.start(), found.end(), prefix))
    for begin, capture_end, prefix in reversed(positions):
        end = lambda_end(source, capture_end)
        source = source[:begin] + prefix + "vhd_native(" + source[begin:end] + ")" + source[end:]
    return source


def ordered_vhd_captures(source):
    pattern = re.compile(r"\[[^\[\]\n]*\bvhd_constructor\b[^\[\]\n]*\]")
    for match in reversed(tuple(pattern.finditer(source))):
        end = lambda_end(source, match.end())
        function = source[match.start() : end]
        prefix = "ergoptiplus::remap::auth::detail::retain_callable(vhd_constructor, "
        suffix = ")"
        if "vhd_dispatch_debt" in match.group():
            prefix += "ergoptiplus::remap::auth::detail::retain_callable(vhd_dispatch_debt, "
            suffix += ")"
        source = source[: match.start()] + prefix + function + suffix + source[end:]
    return source


def declare_wrappers_before_use(source, class_anchor):
    # Deduced return types must be defined before the first non-template caller.
    # Move only our added private wrappers; every original auth body stays whole.
    blocks = []
    for name in ("vhd_cleanup", "vhd_native", "vhd_dispatch", "vhd_callback"):
        anchor = "  template<class F> auto " + name + "(F function) {"
        count = source.count(anchor)
        if count > 1:
            raise VHDTransportRefusal("vhd_wrapper_inventory")
        if count:
            begin = source.index(anchor)
            end = lambda_end(source, begin) + 1
            blocks.append(source[begin:end])
            source = source[:begin] + source[end:]
    at = source.index("{", source.index(class_anchor)) + 1
    return source[:at] + "\n" + "".join(blocks) + source[at:]


def checked_vhd_dispatch_queues(source, class_anchor, failure):
    # Preserve the native queue result. Lost publication/cleanup is retained as
    # failed custody for the selected cohort; non-selected auth routes delegate.
    source = source.replace("enqueue_to_dispatcher(", "vhd_enqueue(")
    added = """  bool vhd_enqueue(std::function<void()> function) {
    const bool queued = pqrs::dispatcher::extra::dispatcher_client::enqueue_to_dispatcher(std::move(function));
    if (!queued && vhd_selected_) { FAILURE }
    return queued;
  }
""".replace("FAILURE", failure)
    at = source.index("{", source.index(class_anchor)) + 1
    return source[:at] + "\n" + added + source[at:]


def peer(data):
    r = Recipe(data)
    # Track original callbacks before adding our own physical close controls.
    r.source = tracked_native_posts(tracked_dispatchers(r.source))
    r.one(
        '#include "remap_runtime_auth.hpp"',
        '#include "remap_runtime_auth.hpp"\n#include "remap_runtime_vhd.hpp"',
    )
    r.one(
        "std::optional<std::shared_ptr<ergoptiplus::remap::auth::socket_lifetime>> owned = std::nullopt)",
        "std::optional<std::shared_ptr<ergoptiplus::remap::auth::socket_lifetime>> owned = std::nullopt,\n       std::optional<std::shared_ptr<ergoptiplus::remap::vhd::connection>> vhd = std::nullopt)",
    )
    r.one(
        "        owned_socket_(owned.value_or(nullptr)),",
        "        owned_socket_(owned.value_or(nullptr)),\n        vhd_selected_(vhd.has_value()),\n        vhd_socket_(vhd.value_or(nullptr)),",
    )
    r.one(
        "  const std::shared_ptr<ergoptiplus::remap::auth::socket_lifetime> owned_socket_;",
        "  const std::shared_ptr<ergoptiplus::remap::auth::socket_lifetime> owned_socket_;\n  const bool vhd_selected_;\n  const std::shared_ptr<ergoptiplus::remap::vhd::connection> vhd_socket_;",
    )
    r.one(
        "  template<class F> auto owned_native(F function) {",
        """  template<class F> auto vhd_dispatch(F function) {
    auto debt = vhd_socket_ ? vhd_socket_->retain_task(ergoptiplus::remap::vhd::connection::task_kind::dispatch) : nullptr;
    return ergoptiplus::remap::auth::detail::retain_callable(debt,
        [self = shared_from_this(), function = std::move(function), debt]() mutable {
          if (self->vhd_selected_ && (!debt || !self->vhd_socket_ || !self->vhd_socket_->current())) {
            self->close(); return;
          }
          function();
        });
  }
  template<class F> auto vhd_native(F function) {
    auto debt = vhd_socket_ ? vhd_socket_->retain_task(ergoptiplus::remap::vhd::connection::task_kind::native) : nullptr;
    return ergoptiplus::remap::auth::detail::retain_callable(debt, std::move(function));
  }
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
          if (!debt || !self->enqueue_to_dispatcher(ergoptiplus::remap::auth::detail::retain_callable(debt,
              [self, debt] { self->closed(); }))) self->vhd_socket_->fail_cleanup();
        })) vhd_socket_->fail_cleanup();
    vhd_socket_->request_close();
  }
  std::function<void()> vhd_cancel_requests_;
  bool vhd_ports_ = false;
  std::vector<std::function<void()>> vhd_observers_;
  template<class F> auto owned_native(F function) {""",
    )
    r.one(
        "    return ergoptiplus::remap::auth::detail::retain_callable(debt, [function = std::move(function), debt = debt](auto&&... arguments) mutable {\n      function(std::forward<decltype(arguments)>(arguments)...);\n    });",
        """    auto vhd_debt = vhd_socket_ ? vhd_socket_->retain_task(ergoptiplus::remap::vhd::connection::task_kind::native) : nullptr;
    return ergoptiplus::remap::auth::detail::retain_callable(vhd_debt,
        ergoptiplus::remap::auth::detail::retain_callable(debt, [function = std::move(function), debt = debt, vhd_debt](auto&&... arguments) mutable {
          function(std::forward<decltype(arguments)>(arguments)...);
        }));""",
    )
    r.one(
        "          self->ensure_owned_ports();\n          if (self->owned_selected_",
        "          self->ensure_vhd_ports();\n          if (self->vhd_selected_ && (self->owned_selected_ || !self->vhd_socket_ || !self->vhd_socket_->current())) { self->close(); return; }\n          self->ensure_owned_ports();\n          if (self->owned_selected_",
    )
    r.one(
        "    if (owned_socket_) owned_socket_->revoke();\n    asio::post(",
        "    if (vhd_socket_) vhd_socket_->revoke();\n    if (owned_socket_) owned_socket_->revoke();\n    asio::post(",
    )
    r.one(
        "          if (self->owned_selected_ && self->owned_socket_) {",
        """          if (self->vhd_selected_ && self->vhd_socket_) {
            self->ensure_vhd_ports();
            if (self->vhd_socket_->completed()) { if (completion) completion(); return; }
            if (completion) self->vhd_observers_.push_back(std::move(completion));
            self->close(); return;
          }
          if (self->owned_selected_ && self->owned_socket_) {""",
    )
    for anchor in (
        "  void ensure_ready() {",
        "  void read_header() {",
        "  void read_body() {",
        "  void push_frame(std::vector<uint8_t> frame) {",
        "  void write() {",
    ):
        r.one(
            anchor,
            anchor
            + "\n    if (vhd_selected_ && (!vhd_socket_ || !vhd_socket_->current())) { close(); return; }",
        )
    r.one(
        "  void close() {\n    if (owned_selected_",
        "  void close() {\n    if (vhd_selected_) {\n      if (vhd_socket_) { ensure_vhd_ports(); vhd_socket_->revoke(); }\n      return;\n    }\n    if (owned_selected_",
    )
    r.source = declare_wrappers_before_use(r.source, "class peer final")
    r.source = checked_vhd_dispatch_queues(
        r.source, "class peer final", "if (vhd_socket_) vhd_socket_->fail_cleanup();"
    )
    return r.result()


def lower(data):
    r = Recipe(data)
    end = r.source.index("} // namespace impl")
    r.source = tracked_native_posts(tracked_dispatchers(r.source[:end])) + r.source[end:]
    # Both constructors have this exact optional-argument suffix.
    old = "std::optional<std::shared_ptr<ergoptiplus::remap::auth::channel_owner>> owned = std::nullopt)"
    if r.source.count(old) != 2:
        raise VHDTransportRefusal("vhd_constructor_count")
    r.source = r.source.replace(
        old,
        "std::optional<std::shared_ptr<ergoptiplus::remap::auth::channel_owner>> owned = std::nullopt,\n               std::optional<std::shared_ptr<ergoptiplus::remap::vhd::broker_owner>> vhd = std::nullopt)",
    )
    r.one(
        "        owned_channel_(owned.value_or(nullptr)),",
        "        owned_channel_(owned.value_or(nullptr)),\n        vhd_selected_(vhd.has_value()),\n        vhd_owner_(vhd.value_or(nullptr)),",
    )
    r.one(
        "                                                    std::move(owned))),",
        "                                                    std::move(owned),\n                                                    std::move(vhd))),",
    )
    r.one(
        "  const bool owned_selected_;",
        "  const bool vhd_selected_;\n  const std::shared_ptr<ergoptiplus::remap::vhd::broker_owner> vhd_owner_;\n  std::shared_ptr<ergoptiplus::remap::vhd::connection> connecting_vhd_;\n  const bool owned_selected_;",
    )
    r.one(
        "  void connect() {\n",
        """  void connect() {
    if (vhd_selected_ && (owned_selected_ || !vhd_owner_ || socket_file_path_ != ergoptiplus::remap::vhd::detail::endpoint || !vhd_owner_->current())) return;
    auto vhd_constructor = vhd_owner_ ? vhd_owner_->retain_construction() : nullptr;
    if (vhd_selected_ && !vhd_constructor) return;
""",
    )
    r.one(
        "[weak_self, notification_token, owned_constructor]",
        "[weak_self, notification_token, owned_constructor, vhd_constructor]",
    )
    r.one(
        "[self, socket, notification_token, owned_constructor]",
        "[self, socket, notification_token, owned_constructor, vhd_constructor]",
    )
    r.one(
        "                std::shared_ptr<ergoptiplus::remap::auth::socket_lifetime> owned;",
        """                auto vhd = self->vhd_selected_ ? ergoptiplus::remap::vhd::connection::stage(self->vhd_owner_, socket) : nullptr;
                self->connecting_vhd_ = vhd;
                if (self->vhd_selected_ && (!vhd || !vhd->current())) {
                  if (vhd) vhd->revoke();
                  else { asio::error_code error; socket->close(error); if (error || socket->is_open()) self->vhd_owner_->failed_cleanup(); }
                  self->connecting_socket_.reset(); return;
                }
                auto vhd_dispatch_debt = vhd ? vhd->retain_task(ergoptiplus::remap::vhd::connection::task_kind::dispatch) : nullptr;
                std::shared_ptr<ergoptiplus::remap::auth::socket_lifetime> owned;""",
    )
    r.one(
        "[self, socket, credentials, notification_token, owned, owned_dispatch, owned_constructor]",
        "[self, socket, credentials, notification_token, owned, owned_dispatch, owned_constructor, vhd, vhd_dispatch_debt, vhd_constructor]",
    )
    r.one(
        "                          auto verified = self->owned_selected_ ? owned && owned->current()",
        "                          auto verified = self->vhd_selected_ ? vhd && vhd->current()\n                              : self->owned_selected_ ? owned && owned->current()",
    )
    r.one(
        "[self, socket, credentials, verified, notification_token, owned, owned_dispatch, owned_constructor]",
        "[self, socket, credentials, verified, notification_token, owned, owned_dispatch, owned_constructor, vhd, vhd_dispatch_debt, vhd_constructor]",
    )
    r.one(
        "                                                              owned);",
        "                                                              owned, vhd);",
    )
    r.one(
        "                               std::shared_ptr<ergoptiplus::remap::auth::socket_lifetime> owned = nullptr)",
        "                               std::shared_ptr<ergoptiplus::remap::auth::socket_lifetime> owned = nullptr,\n                               std::shared_ptr<ergoptiplus::remap::vhd::connection> vhd = nullptr)",
    )
    r.one(
        "    if (!verified || (owned_selected_",
        "    if ((vhd_selected_ && (!vhd || !vhd->current())) || !verified || (owned_selected_",
    )
    r.one(
        "                                                                     owned_selected_ ? std::optional{owned} : std::nullopt));",
        "                                                                     owned_selected_ ? std::optional{owned} : std::nullopt,\n                                                                     vhd_selected_ ? std::optional{vhd} : std::nullopt));",
    )
    r.one(
        "                         owned_channel_) {",
        "                         owned_channel_, vhd_owner_) {",
    )
    r.one(
        "    p->async_start();",
        """    if (vhd_selected_) {
      p->vhd_cancel_requests_ = [weak_self, weak_p] {
        auto self = weak_self.lock(); auto peer = weak_p.lock();
        if (self && peer && self->peer_ == peer) self->request_manager_.complete_all(asio::error::operation_aborted);
      };
      p->ensure_vhd_ports();
    }
    p->async_start();""",
    )
    r.one(
        "    if (connecting_socket_) {\n      if (connecting_owned_)",
        "    if (connecting_socket_) {\n      if (connecting_vhd_) { connecting_vhd_->revoke(); connecting_vhd_.reset(); connecting_socket_.reset(); return; }\n      if (connecting_owned_)",
    )
    # A stale connecting continuation must retire the exact VHD session; it
    # must never directly close the moved native FD behind its custody owner.
    r.source = r.source.replace(
        "if (owned) owned->revoke();\n",
        "if (vhd) vhd->revoke();\n                  else if (owned) owned->revoke();\n",
    )
    for method in ("async_stop", "async_shutdown"):
        r.one(
            "  void " + method + "() {",
            "  void "
            + method
            + "() {\n    auto retirement_debt = vhd_owner_ ? vhd_owner_->retain_work(ergoptiplus::remap::vhd::broker_owner::queue::dispatch) : nullptr;\n    if (vhd_owner_) vhd_owner_->retire();",
        )
    r.one(
        "private:\n  friend class client_test_access;",
        """private:
  friend class client_test_access;
  template<class F> auto vhd_cleanup(F function) {
    auto debt = vhd_owner_ ? vhd_owner_->retain_work(ergoptiplus::remap::vhd::broker_owner::queue::dispatch) : nullptr;
    return ergoptiplus::remap::auth::detail::retain_callable(debt, std::move(function));
  }
  template<class F> auto vhd_native(F function) {
    auto debt = vhd_owner_ ? vhd_owner_->retain_work(ergoptiplus::remap::vhd::broker_owner::queue::native) : nullptr;
    return ergoptiplus::remap::auth::detail::retain_callable(debt, std::move(function));
  }
  template<class F> auto vhd_dispatch(F function) {
    auto debt = vhd_owner_ ? vhd_owner_->retain_work(ergoptiplus::remap::vhd::broker_owner::queue::dispatch) : nullptr;
    auto session = vhd_owner_ ? vhd_owner_->active() : nullptr;
    return ergoptiplus::remap::auth::detail::retain_callable(debt,
        [self = shared_from_this(), function = std::move(function), session, debt]() mutable {
          if (self->vhd_selected_ && (!debt || (session ? !session->current() : !self->vhd_owner_->current()))) return;
          function();
        });
  }""",
    )
    r.one(
        "enqueue_to_dispatcher(vhd_dispatch([this] {\n      stop();",
        "enqueue_to_dispatcher(vhd_cleanup([this] {\n      stop();",
    )
    close_signal = r.source.index("    p->closed.connect(")
    close_end = r.source.index("    if (owned_selected_) {", close_signal)
    block = r.source[close_signal:close_end]
    if block.count("self->vhd_dispatch([self]") != 1:
        raise VHDTransportRefusal("vhd_closed_cleanup_anchor")
    block = block.replace("self->vhd_dispatch([self]", "self->vhd_cleanup([self]")
    r.source = r.source[:close_signal] + block + r.source[close_end:]
    # Every actual negative stop/teardown callable receives debt acquired before
    # revocation. Native posts made by those bodies keep their own successor debt.
    for method, following in (
        ("async_stop", "async_invalidate_connection"),
        ("async_shutdown", "async_start"),
    ):
        begin = r.source.index("  void " + method + "() {")
        end = r.source.index("  void " + following + "() {", begin)
        block = r.source[begin:end]
        captures = []
        for match in re.finditer(r"\[(?:this|shared_self)\]", block):
            before = block[max(0, match.start() - 80) : match.start()]
            if re.search(r"(?:vhd_cleanup|vhd_native|detach_from_dispatcher)\(\s*$", before):
                captures.append((match.start(), match.end()))
        expected = 1 if method == "async_stop" else 3
        if len(captures) != expected:
            raise VHDTransportRefusal("vhd_retirement_callable_inventory")
        for start, capture_end in reversed(captures):
            finish = lambda_end(block, capture_end)
            callable = block[start:finish]
            callable = callable.replace("]", ", retirement_debt]", 1)
            block = (
                block[:start]
                + "ergoptiplus::remap::auth::detail::retain_callable(retirement_debt, "
                + callable
                + ")"
                + block[finish:]
            )
        r.source = r.source[:begin] + block + r.source[end:]
    r.source = ordered_vhd_captures(r.source)
    r.source = declare_wrappers_before_use(r.source, "class client_state final")
    r.source = checked_vhd_dispatch_queues(
        r.source, "class client_state final", "if (vhd_owner_) vhd_owner_->failed_cleanup();"
    )
    return initializer_lower(r.result())


def upper(data):
    r = Recipe(data)
    r.source = tracked_dispatchers(r.source)
    r.one(
        '#include "../client_protocol_version.hpp"',
        '#include "../client_protocol_version.hpp"\n#include "remap_runtime_vhd.hpp"',
    )
    r.one(
        "  client()\n      : dispatcher_client() {\n  }",
        """  client()
      : dispatcher_client() {
  }
  explicit client(std::shared_ptr<ergoptiplus::remap::vhd::broker_owner> owner)
      : dispatcher_client(), vhd_selected_(true), vhd_owner_(std::move(owner)) {
  }""",
    )
    r.one(
        "  ~client() override {",
        "  ~client() override {\n    vhd_alive_->store(false);\n    if (vhd_owner_) vhd_owner_->retire();",
    )
    r.one(
        "  void async_stop() {",
        "  void async_stop() {\n    auto retirement_debt = vhd_owner_ ? vhd_owner_->retain_work(ergoptiplus::remap::vhd::broker_owner::queue::dispatch) : nullptr;\n    if (vhd_owner_) vhd_owner_->retire();",
    )
    r.one(
        "  void create_client() {",
        '  void create_client() {\n    if (vhd_selected_ && (!vhd_owner_ || !vhd_owner_->current())) { warning_reported("official_vhd_reference_unavailable"); return; }',
    )
    r.one(
        "                                                           options);",
        """                                                           options,
                                                           vhd_selected_ ? std::function<bool(const unix_domain_stream::peer_credentials&)>([](const auto&) { return false; }) : unix_domain_stream::default_client_verify_peer,
                                                           std::nullopt,
                                                           vhd_selected_ ? std::optional{vhd_owner_} : std::nullopt);""",
    )
    r.one(
        "  std::unique_ptr<unix_domain_stream::client> client_;",
        """  template<class F> auto vhd_cleanup(F function) {
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
  const std::shared_ptr<std::atomic<bool>> vhd_alive_ = std::make_shared<std::atomic<bool>>(true);
  bool vhd_selected_ = false;
  const std::shared_ptr<ergoptiplus::remap::vhd::broker_owner> vhd_owner_;
  std::unique_ptr<unix_domain_stream::client> client_;""",
    )
    r.one(
        "    for (auto index : std::views::iota(size_t{0}, response_buffer.size() / 2)) {",
        """    if (vhd_selected_) {
      if (!vhd_owner_ || !vhd_owner_->active()) return;
      for (std::size_t at = 0; at < response_buffer.size(); at += 2) {
        if (response_buffer[at] > static_cast<std::uint8_t>(response::virtual_hid_pointing_ready) || response_buffer[at + 1] > 1) {
          vhd_owner_->retire(); warning_reported("official_vhd_status_noncanonical"); return;
        }
      }
    }
    for (auto index : std::views::iota(size_t{0}, response_buffer.size() / 2)) {
      if (vhd_selected_ && !vhd_owner_->active()) return;""",
    )
    r.one(
        "        case response::virtual_hid_keyboard_ready:\n",
        '        case response::virtual_hid_keyboard_ready:\n          if (vhd_selected_ && value != 0) { warning_reported("official_vhd_initialized_ready_unqualified"); break; }\n',
    )
    r.one(
        "        case response::virtual_hid_pointing_ready:\n",
        '        case response::virtual_hid_pointing_ready:\n          if (vhd_selected_ && value != 0) { warning_reported("official_vhd_initialized_ready_unqualified"); break; }\n',
    )
    r.one(
        "enqueue_to_dispatcher(vhd_dispatch([this] {\n      client_ = nullptr;\n\n      clear_state();",
        "enqueue_to_dispatcher(vhd_cleanup([this] {\n      client_ = nullptr;\n\n      clear_state();",
    )
    callback = r.source.index("[this](auto&& error_code, auto&& response_buffer)")
    end = lambda_end(r.source, callback)
    r.source = r.source[:callback] + "vhd_callback(" + r.source[callback:end] + ")" + r.source[end:]
    # Retain the actual stop frame before revocation; an untracked logical stop
    # cannot race the queued physical lower shutdown and advertise retirement.
    stop_begin = r.source.index("  void async_stop() {")
    stop_end = r.source.index("  void async_virtual_hid_keyboard_initialize", stop_begin)
    block = r.source[stop_begin:stop_end]
    before = "enqueue_to_dispatcher(vhd_cleanup([this] {"
    if block.count(before) != 1:
        raise VHDTransportRefusal("vhd_stop_anchor")
    block = block.replace(
        before,
        "enqueue_to_dispatcher(ergoptiplus::remap::auth::detail::retain_callable(retirement_debt, vhd_cleanup([this, retirement_debt] {",
    )
    block = block.replace("    }));", "    })));")
    r.source = r.source[:stop_begin] + block + r.source[stop_end:]
    r.source = declare_wrappers_before_use(r.source, "class client final")
    r.source = checked_vhd_dispatch_queues(
        r.source, "class client final", "if (vhd_owner_) vhd_owner_->failed_cleanup();"
    )
    # No initialized-ready capability is published by this broker-only slice.
    # Exact initializer ACK and post-initializer typed readiness require the
    # native generation-bound request/delivery bridge, not a method-call flag.
    return initializer_upper(r.result())


def core(data):
    r = Recipe(data)
    r.one(
        "virtual_hid_device_service_client_ = std::make_shared<pqrs::karabiner::driverkit::virtual_hid_device_service::client>();",
        "virtual_hid_device_service_client_ = std::make_shared<pqrs::karabiner::driverkit::virtual_hid_device_service::client>(ergoptiplus::remap::vhd::broker_owner::acquire());",
    )
    return r.result()


def requests(data):
    r = Recipe(data)
    r.one(
        '#include "remap_runtime_auth.hpp"',
        '#include "remap_runtime_auth.hpp"\n#include "remap_runtime_vhd.hpp"',
    )
    r.one(
        "std::shared_ptr<ergoptiplus::remap::auth::channel_owner> owned = nullptr)",
        "std::shared_ptr<ergoptiplus::remap::auth::channel_owner> owned = nullptr,\n                  std::shared_ptr<ergoptiplus::remap::vhd::broker_owner> vhd = nullptr)",
    )
    r.one(
        "dispatcher_client_(dispatcher_client), owned_channel_(std::move(owned))",
        "dispatcher_client_(dispatcher_client), owned_channel_(std::move(owned)), vhd_owner_(std::move(vhd))",
    )
    r.one(
        "    auto owned_debt = inherited_debt",
        "    auto vhd_session = vhd_owner_ ? vhd_owner_->active() : nullptr;\n    auto vhd_debt = vhd_owner_ ? vhd_owner_->retain_work(ergoptiplus::remap::vhd::broker_owner::queue::native) : nullptr;\n    if (vhd_owner_ && (owned_channel_ || !vhd_session || !vhd_debt)) return 0;\n    auto owned_debt = inherited_debt",
    )
    r.one(
        "timer->async_wait(ergoptiplus::remap::auth::detail::retain_callable(owned_debt, [this, id, timeout_callback, owned_debt]",
        "timer->async_wait(ergoptiplus::remap::auth::detail::retain_callable(vhd_debt, ergoptiplus::remap::auth::detail::retain_callable(owned_debt, [this, id, timeout_callback, owned_debt, vhd_debt, vhd_session]",
    )
    r.one("    }));\n\n    pending_requests_.emplace", "    })));\n\n    pending_requests_.emplace")
    r.one(
        "if (!error_code && pending_requests_.contains(id))",
        "if (!error_code && pending_requests_.contains(id) && (!vhd_session || vhd_session->current()))",
    )
    r.one(
        "                                  .owned_debt = owned_debt,",
        "                                  .owned_debt = owned_debt,\n                                  .vhd_debt = vhd_debt,\n                                  .vhd_session = vhd_session,",
    )
    r.one(
        "    async_request_callback callback;",
        "    std::shared_ptr<void> vhd_debt;\n    std::shared_ptr<ergoptiplus::remap::vhd::connection> vhd_session;\n    async_request_callback callback;",
    )
    r.one(
        "    request.timer->cancel();\n    dispatcher_client_.enqueue_to_dispatcher(\n        [request = std::move(request), error_code, data = std::move(data)] {",
        "    request.timer->cancel();\n    auto vhd_session = request.vhd_session;\n    auto vhd_dispatch = request.vhd_session ? request.vhd_session->retain_task(ergoptiplus::remap::vhd::connection::task_kind::dispatch) : nullptr;\n    if (request.vhd_session && !vhd_dispatch) { request.vhd_session->fail_cleanup(); return; }\n    if (!dispatcher_client_.enqueue_to_dispatcher(ergoptiplus::remap::auth::detail::retain_callable(vhd_dispatch,\n        [request = std::move(request), error_code, data = std::move(data), vhd_dispatch] {\n          if (request.vhd_session && !error_code && !request.vhd_session->current()) { request.callback(asio::error::operation_aborted, nullptr); return; }",
    )
    r.one(
        "          else request.callback(error_code, data);\n        });",
        "          else request.callback(error_code, data);\n        }))) { if (vhd_session) vhd_session->fail_cleanup(); }",
    )
    r.one(
        "  const std::shared_ptr<ergoptiplus::remap::auth::channel_owner> owned_channel_;",
        "  const std::shared_ptr<ergoptiplus::remap::auth::channel_owner> owned_channel_;\n  const std::shared_ptr<ergoptiplus::remap::vhd::broker_owner> vhd_owner_;",
    )
    return initializer_requests(r.result())


def initializer_lower(data):
    r = Recipe(data)
    r.one(
        "                self->request_manager_.complete(request_id,",
        """                if (self->vhd_selected_ && request_id != 0 &&
                    !self->request_manager_.accepts_vhd_response(request_id)) {
                  if (self->vhd_owner_) self->vhd_owner_->retire();
                  return;
                }
                self->request_manager_.complete(request_id,""",
    )
    r.one(
        "                     owned_async_request_callback owned_callback = nullptr) {",
        "                     owned_async_request_callback owned_callback = nullptr,\n                     std::shared_ptr<ergoptiplus::remap::vhd::initializer_delivery> initializer = nullptr) {",
    )
    r.one(
        "[weak_self, data, timeout, callback, owned_callback, owned_request]",
        "[weak_self, data, timeout, callback, owned_callback, owned_request, initializer]",
    )
    r.one(
        "                             owned_callback, owned_request);",
        "                             owned_callback, owned_request, initializer);",
    )
    r.one(
        "std::shared_ptr<ergoptiplus::remap::auth::channel_owner::construction_marker> owned_request = nullptr) {",
        "std::shared_ptr<ergoptiplus::remap::auth::channel_owner::construction_marker> owned_request = nullptr,\n                    std::shared_ptr<ergoptiplus::remap::vhd::initializer_delivery> initializer = nullptr) {\n    if (initializer && (!vhd_selected_ || owned_selected_)) { initializer->refuse(); return; }",
    )
    r.one("    if (!peer_) {", "    if (!peer_) {\n      if (initializer) initializer->refuse();")
    r.one(
        "                                   }, owned_callback, request_operation, owned_request);",
        "                                   }, owned_callback, request_operation, owned_request, initializer, initializer ? &data : nullptr);",
    )
    r.one(
        "    if (owned_selected_ && id == 0) return;",
        "    if ((owned_selected_ || vhd_selected_) && id == 0) return;",
    )
    r.one(
        "  void async_request_owned(const std::vector<uint8_t>& data,",
        """private:
  friend class pqrs::karabiner::driverkit::virtual_hid_device_service::client;
  void async_initializer_request(const std::vector<uint8_t>& data,
      async_request_callback callback,
      std::shared_ptr<ergoptiplus::remap::vhd::initializer_delivery> intent) const {
    state_->async_request(data, state_->options_.read_timeout, std::move(callback), nullptr, std::move(intent));
  }
public:
  void async_request_owned(const std::vector<uint8_t>& data,""",
    )
    r.source = ordered_vhd_shutdown(r.source)
    return r.result()


def ordered_vhd_shutdown(source):
    r = Recipe(source.encode("utf-8"))
    anchor = "  void async_shutdown() {"
    begin = r.source.index(anchor)
    end = lambda_end(r.source, begin)
    original = r.source[begin:end]
    # The complete original physical close and successor-retention sequence is
    # transplanted byte-whole. Default and Ergopti-auth shutdown remain whole.
    tail_begin = original.index("    detach_from_dispatcher(")
    tail_end = original.rfind("  }")
    tail = original[tail_begin:tail_end]
    if tail.count("shared_self->close_peer(asio::error::operation_aborted);") != 1:
        raise VHDTransportRefusal("vhd_shutdown_tail_refused")
    branch = (
        """
    if (vhd_selected_) {
      auto retirement_debt = vhd_owner_ ? vhd_owner_->retain_work(ergoptiplus::remap::vhd::broker_owner::queue::dispatch) : nullptr;
      if (vhd_owner_) vhd_owner_->retire();
      if (shutdown_started_.exchange(true)) return;
      auto shared_self = shared_from_this();
      // Cancellation must admit its existing dispatcher-owned rows before
      // this client detaches. Actual enqueue refusal still retains a failed
      // owner; a logical stop never acknowledges native descriptor closure.
      asio::post(io_ctx_, vhd_native(ergoptiplus::remap::auth::detail::retain_callable(retirement_debt,
          [this, shared_self, retirement_debt] {
            shared_self->request_manager_.complete_all(asio::error::operation_aborted);
            if (!shared_self->enqueue_to_dispatcher(ergoptiplus::remap::auth::detail::retain_callable(retirement_debt,
                [this, shared_self, retirement_debt] {
"""
        + tail
        + """                }))) {
              if (auto owner = shared_self->vhd_owner_) {
                std::lock_guard<std::recursive_mutex> lock(owner->mutex_);
                owner->failed_cleanup();
                for (const auto& session : owner->sessions_) session->fail_cleanup();
              }
            }
          })));
      return;
    }
"""
    )
    r.one(original, anchor + branch + original[len(anchor) :])
    return r.source


def initializer_upper(data):
    r = Recipe(data)
    r.one(
        "      async_request(make_request_buffer(request::virtual_hid_keyboard_initialize,\n                                        parameters));",
        "      async_request(make_request_buffer(request::virtual_hid_keyboard_initialize,\n                                        parameters), ergoptiplus::remap::vhd::initializer_kind::keyboard);",
    )
    r.one(
        "      async_request(make_request_buffer(request::virtual_hid_pointing_initialize));",
        "      async_request(make_request_buffer(request::virtual_hid_pointing_initialize), ergoptiplus::remap::vhd::initializer_kind::pointing);",
    )
    r.one(
        "  void async_request(pqrs::not_null_shared_ptr_t<std::vector<uint8_t>> request_buffer) {\n    vhd_enqueue(vhd_dispatch([this, request_buffer] {\n      if (client_) {\n        client_->async_request(",
        """  void async_request(pqrs::not_null_shared_ptr_t<std::vector<uint8_t>> request_buffer,
      std::optional<ergoptiplus::remap::vhd::initializer_kind> initializer_kind = std::nullopt) {
    auto intent = vhd_selected_ && initializer_kind
        ? ergoptiplus::remap::vhd::initializer_delivery::create(*request_buffer, *initializer_kind) : nullptr;
    vhd_enqueue(vhd_dispatch([this, request_buffer, intent] {
      if (client_) {
        auto callback =""",
    )
    # Reuse the entire original callback callable, its source/currentness guard,
    # nested dispatcher debt, status processing and ready1 refusal unchanged.
    r.one(
        "        auto callback =\n            *request_buffer,\n            vhd_callback(",
        "        auto callback = vhd_callback(",
    )
    r.one(
        "            }));\n      }\n    }));\n  }\n\n  pqrs::not_null_shared_ptr_t<std::vector<uint8_t>> make_request_buffer",
        """            });
        if (intent) client_->async_initializer_request(*request_buffer, std::move(callback), intent);
        else client_->async_request(*request_buffer, std::move(callback));
      }
    }));
  }

  pqrs::not_null_shared_ptr_t<std::vector<uint8_t>> make_request_buffer""",
    )
    return r.result()


def initializer_requests(data):
    r = Recipe(data)
    r.one(
        "std::shared_ptr<ergoptiplus::remap::auth::channel_owner::construction_marker> inherited_debt = nullptr) {",
        "std::shared_ptr<ergoptiplus::remap::auth::channel_owner::construction_marker> inherited_debt = nullptr,\n                 std::shared_ptr<ergoptiplus::remap::vhd::initializer_delivery> initializer = nullptr,\n                 const std::vector<std::uint8_t>* sent = nullptr) {\n    if (initializer && (!vhd_owner_ || owned_channel_)) { initializer->refuse(); return 0; }",
    )
    r.one(
        "    auto id = ++next_request_id_;",
        """    if (vhd_owner_ && next_request_id_ == std::numeric_limits<request_id>::max()) {
      if (initializer) initializer->refuse();
      vhd_owner_->retire(); return 0;
    }
    auto id = ++next_request_id_;
    if (initializer && (!sent || !initializer->bind(vhd_session, id, *sent))) {
      initializer->refuse(); vhd_owner_->retire(); return 0;
    }""",
    )
    r.one(
        "                                  .vhd_session = vhd_session,",
        "                                  .vhd_session = vhd_session,\n                                  .vhd_initializer = initializer,\n                                  .vhd_request_id = id,",
    )
    r.one(
        "private:\n  void callback_error(",
        """private:
  friend class client_state;
  bool accepts_vhd_response(request_id id) {
    auto row = pending_requests_.find(id);
    return vhd_owner_ && id != 0 && row != pending_requests_.end() &&
        row->second.vhd_session && row->second.vhd_session->current();
  }
  void callback_error(""",
    )
    r.one(
        "    std::shared_ptr<ergoptiplus::remap::vhd::connection> vhd_session;",
        "    std::shared_ptr<ergoptiplus::remap::vhd::connection> vhd_session;\n    std::shared_ptr<ergoptiplus::remap::vhd::initializer_delivery> vhd_initializer;\n    request_id vhd_request_id;",
    )
    r.one(
        "    request.timer->cancel();\n    auto vhd_session = request.vhd_session;",
        "    if (request.vhd_initializer) request.vhd_initializer->complete(request.vhd_request_id, error_code, data);\n    request.timer->cancel();\n    auto vhd_session = request.vhd_session;",
    )
    return r.result()


def assemble_vhd_transport(rows, header, deadline):
    budget(deadline)
    if type(rows) is not dict or set(rows) != {p for p, _ in PREIMAGES}:
        raise VHDTransportRefusal("vhd_inventory_refused")
    if type(header) is not bytes or hashlib.sha256(header).hexdigest() != HEADER_SHA256:
        raise VHDTransportRefusal("vhd_header_refused")
    for path, expected in PREIMAGES:
        budget(deadline)
        if type(rows[path]) is not bytes or hashlib.sha256(rows[path]).hexdigest() != expected:
            raise VHDTransportRefusal("vhd_preimage_refused:" + path)
    result = {}
    for path, function in (
        (LOWER, lower),
        (PEER, peer),
        (UPPER, upper),
        (CORE, core),
        (REQUESTS, requests),
    ):
        budget(deadline)
        result[path] = function(rows[path])
    budget(deadline)
    if set(result) != set(rows):
        raise VHDTransportRefusal("vhd_result_inventory_refused")
    return result
