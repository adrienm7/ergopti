// Observe only the current native stream boundary; never construct an owner.
#pragma once
#include <sys/socket.h>
#include <cerrno>
#include <cstdint>
namespace ergoptiplus::installed_maintenance::detail {
inline bool response_boundary(int descriptor) noexcept {
  std::uint8_t byte=0;
  ssize_t count;
  do { count=::recv(descriptor,&byte,1,MSG_PEEK|MSG_DONTWAIT); } while (count<0 && errno==EINTR);
  return count<0 && (errno==EAGAIN || errno==EWOULDBLOCK);
}
}
