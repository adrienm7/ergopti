// tools/diagnostics/hs274-accept-test.cpp
// Separate a rejected accepted peer from a genuinely invalid listening socket.
#include <asio.hpp>
#include <cerrno>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <stdexcept>
#include <sys/socket.h>
#include <unistd.h>

#if !defined(__APPLE__)
#error This regression requires the native Darwin socket option contract.
#endif

namespace {
void require(bool condition, const char* message) {
  if (!condition) throw std::runtime_error(message);
}

class fixture final {
public:
  fixture() {
    char directory[] = "/tmp/hs274-accept-XXXXXX";
    const auto created = ::mkdtemp(directory);
    require(created != nullptr, "Cannot create the owned socket directory");
    directory_ = created;
    path_ = directory_ / "socket";
  }
  fixture(const fixture&) = delete;
  fixture& operator=(const fixture&) = delete;
  ~fixture() {
    std::error_code error;
    std::filesystem::remove(path_, error);
    if (error) std::abort();
    std::filesystem::remove(directory_, error);
    if (error) std::abort();
  }
  asio::local::stream_protocol::endpoint endpoint() const {
    return asio::local::stream_protocol::endpoint(path_.string());
  }
private:
  std::filesystem::path directory_, path_;
};

void connect_and_close(asio::io_context& context, const fixture& owned) {
  asio::local::stream_protocol::socket client(context);
  client.connect(owned.endpoint());
  client.shutdown(asio::socket_base::shutdown_both);
  client.close();
}

int run() {
  fixture owned;
  asio::io_context context;
  asio::local::stream_protocol::acceptor listener(context, owned.endpoint());
  listener.non_blocking(true);

  // Complete disconnect before accept: no scheduling delay or probabilistic race.
  connect_and_close(context, owned);
  const int raw_peer = ::accept(listener.native_handle(), nullptr, nullptr);
  require(raw_peer >= 0, "Raw accept did not return the already disconnected peer");
  const int enabled = 1;
  const int option_result = ::setsockopt(raw_peer, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled));
  const int option_error = errno;
  const int close_result = ::close(raw_peer);
  require(close_result == 0, "Cannot close the raw accepted peer");
  require(option_result == -1 && option_error == EINVAL, "Darwin did not reject the closed peer option with EINVAL");
  std::puts("raw_accept=success accepted_peer_SO_NOSIGPIPE=EINVAL");

  // The same queue also contains a healthy successor that must remain reachable.
  connect_and_close(context, owned);
  asio::local::stream_protocol::socket healthy(context);
  healthy.connect(owned.endpoint());
  bool completed = false;
  asio::error_code accept_error;
  listener.async_accept([&](const asio::error_code& error, auto peer) {
    completed = true;
    accept_error = error;
    if (!error) require(peer.is_open(), "Successful acceptance returned no socket");
  });
  context.run_for(std::chrono::seconds(2));
  require(completed, "Asynchronous accept did not finish within its bound");
  std::printf("async_accept_error=%d category=%s\n", accept_error.value(), accept_error.category().name());

  int listening = 0;
  socklen_t size = sizeof(listening);
  require(::getsockopt(listener.native_handle(), SOL_SOCKET, SO_ACCEPTCONN, &listening, &size) == 0 && listening,
          "The actual listening socket is no longer healthy");
  if (accept_error) {
    const int successor = ::accept(listener.native_handle(), nullptr, nullptr);
    require(successor >= 0, "Healthy successor disappeared after the accepted-peer error");
    const int result = ::setsockopt(successor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled));
    const int closed = ::close(successor);
    require(result == 0 && closed == 0, "Healthy successor setup failed");
  }

  // A real accept error must keep its identity; no blanket EINVAL suppression.
  asio::local::stream_protocol::socket invalid_listener(context);
  invalid_listener.open(asio::local::stream_protocol());
  asio::error_code invalid_error;
  const auto invalid = asio::detail::socket_ops::accept(invalid_listener.native_handle(), nullptr, nullptr, invalid_error);
  require(invalid == asio::detail::invalid_socket && invalid_error == asio::error::invalid_argument,
          "A genuinely non-listening socket did not preserve EINVAL");
  std::puts("listener=healthy successor=reachable genuine_accept_EINVAL=preserved");
  if (accept_error == asio::error::invalid_argument) {
    std::fputs("Regression: accepted-peer option failure escaped as a listener failure\n", stderr);
    return 17;
  }
  require(!accept_error, "Unexpected asynchronous accept error");
  return 0;
}
} // namespace

int main() {
  try { return run(); }
  catch (const std::exception& error) {
    std::fprintf(stderr, "Transport proof failed: %s\n", error.what());
    return 1;
  }
}
