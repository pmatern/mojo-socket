# SPDX-License-Identifier: Apache-2.0
# socket._libc — private FFI: external_call wrappers, sockaddr structs, helpers
# All symbols in this file are private to socket (prefix _ convention).

from std.ffi import external_call, c_int, c_ssize_t, c_size_t, c_uint, c_char, get_errno, ErrNo
from std.sys.info import CompilationTarget
from std.collections import InlineArray
from std.memory import stack_allocation

# -----------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------

comptime AF_INET: c_int = 2
comptime AF_INET6: c_int = 10        # Linux; macOS = 30 (handled via comptime if at usage sites)
comptime SOCK_STREAM: c_int = 1
comptime SOCK_CLOEXEC: c_int = 0x80000   # Linux — set close-on-exec atomically at socket creation
comptime MSG_NOSIGNAL: c_int = 0x4000    # Linux — prevent SIGPIPE on broken socket writes
comptime SHUT_RD: c_int = 0
comptime SHUT_WR: c_int = 1
comptime SHUT_RDWR: c_int = 2

# POSIX fcntl constants (same values on Linux and macOS)
comptime F_GETFD: c_int = 1
comptime F_SETFD: c_int = 2
comptime FD_CLOEXEC: c_int = 1

# macOS setsockopt constants (safe to define on Linux — unused there)
comptime SOL_SOCKET_MACOS: c_int = 0xFFFF   # SOL_SOCKET on macOS/BSD
comptime SO_NOSIGPIPE: c_int = 0x1022        # suppress SIGPIPE per-socket on macOS

# -----------------------------------------------------------------------
# C struct definitions (Linux x86-64 layout — no padding between fields)
# -----------------------------------------------------------------------

@fieldwise_init
struct _sockaddr_in(Copyable):
    """16-byte IPv4 socket address (struct sockaddr_in on Linux x86-64)."""
    var sin_family: UInt16               # 2 bytes — AF_INET
    var sin_port:   UInt16               # 2 bytes — network byte order
    var sin_addr:   UInt32               # 4 bytes — network byte order
    var sin_zero:   InlineArray[UInt8, 8]  # 8 bytes padding


@fieldwise_init
struct _sockaddr_in6(Copyable):
    """28-byte IPv6 socket address (struct sockaddr_in6 on Linux x86-64)."""
    var sin6_family:   UInt16                  # 2 bytes
    var sin6_port:     UInt16                  # 2 bytes — network byte order
    var sin6_flowinfo: UInt32                  # 4 bytes
    var sin6_addr:     InlineArray[UInt8, 16]  # 16 bytes
    var sin6_scope_id: UInt32                  # 4 bytes


@fieldwise_init
struct _stat(Copyable):
    """Minimal stat struct for fstat — we only need it to exist for the call.
    Layout doesn't matter since we only check the return code, not the contents.
    144 bytes is enough to hold struct stat on Linux/macOS x86-64.
    """
    var _padding: InlineArray[UInt8, 144]


# -----------------------------------------------------------------------
# Byte-order helpers (inline — Linux x86-64 is little-endian; network = big-endian)
# -----------------------------------------------------------------------

def _htons(x: UInt16) -> UInt16:
    """Host-to-network byte order (16-bit)."""
    return (x >> 8) | (x << 8)


def _ntohs(x: UInt16) -> UInt16:
    """Network-to-host byte order (16-bit)."""
    return (x >> 8) | (x << 8)


def _htonl(x: UInt32) -> UInt32:
    """Host-to-network byte order (32-bit)."""
    return (
        ((x & 0xFF) << 24)
        | ((x & 0xFF00) << 8)
        | ((x & 0xFF0000) >> 8)
        | ((x >> 24) & 0xFF)
    )


def _ntohl(x: UInt32) -> UInt32:
    """Network-to-host byte order (32-bit)."""
    return _htonl(x)


# -----------------------------------------------------------------------
# errno formatting helpers
# -----------------------------------------------------------------------

def _errno_name(code: Int) -> String:
    """Return the C constant name for an errno value (e.g. EADDRINUSE).
    Handles platform-varying numeric codes via comptime if.
    Falls back to the decimal string for unknown codes.
    """
    # Portable: same numeric value on Linux and macOS
    if code == 1:  return "EPERM"
    if code == 2:  return "ENOENT"
    if code == 4:  return "EINTR"
    if code == 5:  return "EIO"
    if code == 9:  return "EBADF"
    if code == 12: return "ENOMEM"
    if code == 13: return "EACCES"
    if code == 14: return "EFAULT"
    if code == 22: return "EINVAL"
    if code == 24: return "EMFILE"
    if code == 32: return "EPIPE"
    # Platform-varying socket errno codes
    comptime if CompilationTarget.is_linux():
        if code == 11:  return "EAGAIN"
        if code == 95:  return "EOPNOTSUPP"
        if code == 97:  return "EAFNOSUPPORT"
        if code == 98:  return "EADDRINUSE"
        if code == 99:  return "EADDRNOTAVAIL"
        if code == 100: return "ENETDOWN"
        if code == 101: return "ENETUNREACH"
        if code == 104: return "ECONNRESET"
        if code == 107: return "ENOTCONN"
        if code == 110: return "ETIMEDOUT"
        if code == 111: return "ECONNREFUSED"
        if code == 113: return "EHOSTUNREACH"
        if code == 115: return "EINPROGRESS"
        if code == 125: return "ECANCELED"
    else:
        if code == 35:  return "EAGAIN"
        if code == 47:  return "EAFNOSUPPORT"
        if code == 48:  return "EADDRINUSE"
        if code == 49:  return "EADDRNOTAVAIL"
        if code == 50:  return "ENETDOWN"
        if code == 51:  return "ENETUNREACH"
        if code == 54:  return "ECONNRESET"
        if code == 57:  return "ENOTCONN"
        if code == 60:  return "ETIMEDOUT"
        if code == 61:  return "ECONNREFUSED"
        if code == 36:  return "EINPROGRESS"
        if code == 65:  return "EHOSTUNREACH"
        if code == 89:  return "ECANCELED"
        if code == 102: return "EOPNOTSUPP"
    return String(code)


def _errno_str() -> String:
    """Format current errno as 'errno N (NAME)' for error messages.
    Reads errno once — call immediately after the failed syscall.
    """
    var code = Int(get_errno().value)
    return "errno " + String(code) + " (" + _errno_name(code) + ")"


# -----------------------------------------------------------------------
# IP address validation
# -----------------------------------------------------------------------

def _validate_ip(ip: String) raises:
    """Raises if ip is not a valid numeric IPv4 or IPv6 address.
    Validated via inet_pton — no hostname resolution.
    """
    comptime assert CompilationTarget.is_linux() or CompilationTarget.is_macos(), \
        "socket requires Linux or macOS"
    var buf4 = stack_allocation[1, UInt32]()
    var r4 = external_call["inet_pton", c_int](AF_INET, ip.unsafe_ptr(), buf4)
    if r4 == 1:
        return
    var buf6 = stack_allocation[16, UInt8]()
    # Use platform-correct AF_INET6: Linux=10, macOS=30
    comptime if CompilationTarget.is_linux():
        var r6 = external_call["inet_pton", c_int](c_int(10), ip.unsafe_ptr(), buf6)
        if r6 == 1:
            return
    else:
        var r6 = external_call["inet_pton", c_int](c_int(30), ip.unsafe_ptr(), buf6)
        if r6 == 1:
            return
    raise Error("SocketAddress: invalid IP address: " + ip)


def _parsed_addr_to_ip(parsed: _ParsedAddr) -> String:
    """Build an owned ip String from a _ParsedAddr's raw bytes.
    Uses String(capacity=) to pre-allocate a heap buffer before appending chars,
    so that unsafe_ptr() remains valid after the String is moved into SocketAddress.
    (Avoids Mojo 0.26.x String SSO bug where inline storage becomes stale after moves.)
    """
    var ip = String(capacity=parsed.ip_len + 1)
    for i in range(parsed.ip_len):
        ip += chr(Int(parsed.ip_bytes[i]))
    return ip^


# -----------------------------------------------------------------------
# sockaddr construction
# -----------------------------------------------------------------------

def _make_sockaddr_in(ip: String, port: UInt16) raises -> _sockaddr_in:
    """Convert (IPv4 string, port) -> _sockaddr_in for passing to bind/connect.

    The first UInt16 field encodes the first two bytes of the struct:
    - Linux: sin_family=AF_INET → bytes [2, 0]
    - macOS: sin_len=16, sin_family=2 → bytes [16, 2] → UInt16(0x0210) = 528
    sin_port (offset 2) and sin_addr (offset 4) are identical on both platforms.
    """
    var addr_ptr = stack_allocation[1, UInt32]()
    var ret = external_call["inet_pton", c_int](AF_INET, ip.unsafe_ptr(), addr_ptr)
    if ret != 1:
        raise Error("SocketAddress: invalid IPv4 address: " + ip)
    comptime if CompilationTarget.is_linux():
        return _sockaddr_in(UInt16(AF_INET), _htons(port), addr_ptr[], InlineArray[UInt8, 8](fill=0))
    else:
        # macOS BSD layout: bytes[0]=sin_len=16, bytes[1]=sin_family=AF_INET=2
        # Little-endian UInt16: value = (AF_INET << 8) | 16 = (2 << 8) | 16 = 528
        return _sockaddr_in(UInt16((Int(AF_INET) << 8) | 16), _htons(port), addr_ptr[], InlineArray[UInt8, 8](fill=0))


def _make_sockaddr_in6(ip: String, port: UInt16) raises -> _sockaddr_in6:
    """Convert (IPv6 string, port) -> _sockaddr_in6 for passing to bind/connect.

    The first UInt16 field encodes the first two bytes of the struct:
    - Linux: sin6_family=AF_INET6=10 → bytes [10, 0]
    - macOS: sin6_len=28, sin6_family=AF_INET6=30 → bytes [28, 30] → UInt16((30 << 8) | 28) = 7708
    sin6_port (offset 2), sin6_flowinfo (offset 4), sin6_addr (offset 8) are identical on both.
    """
    var addr_buf = stack_allocation[16, UInt8]()
    var ret = external_call["inet_pton", c_int](AF_INET6, ip.unsafe_ptr(), addr_buf)
    if ret != 1:
        raise Error("SocketAddress: invalid IPv6 address: " + ip)
    # Copy inet_pton result into InlineArray
    var addr = InlineArray[UInt8, 16](fill=0)
    for i in range(16):
        addr[i] = addr_buf[i]
    comptime if CompilationTarget.is_linux():
        return _sockaddr_in6(UInt16(AF_INET6), _htons(port), UInt32(0), addr, UInt32(0))
    else:
        # macOS BSD layout: bytes[0]=sin6_len=28, bytes[1]=sin6_family=AF_INET6=30
        # Little-endian UInt16: value = (AF_INET6 << 8) | 28 = (30 << 8) | 28 = 7708
        return _sockaddr_in6(UInt16((Int(AF_INET6) << 8) | 28), _htons(port), UInt32(0), addr, UInt32(0))


# -----------------------------------------------------------------------
# sockaddr parsing — result struct avoids tuple return (Mojo 0.26.x bug)
# -----------------------------------------------------------------------

@fieldwise_init
struct _ParsedAddr(Copyable, Movable):
    """Raw parsed address: ip bytes (null-terminated ASCII) + port.
    Stores ip as InlineArray to avoid String SSO issues during struct moves.
    Call sites build the String locally via chr() concat + move (^).
    """
    var ip_bytes: InlineArray[UInt8, 46]  # INET6_ADDRSTRLEN max
    var ip_len: Int
    var port: UInt16


def _parse_sockaddr_in(sa: _sockaddr_in) raises -> _ParsedAddr:
    """Convert _sockaddr_in -> _ParsedAddr via inet_ntop (stores raw bytes, no String)."""
    var addr_buf = stack_allocation[1, UInt32]()
    addr_buf[] = sa.sin_addr
    var ip_buf = stack_allocation[16, UInt8]()  # INET_ADDRSTRLEN = 16
    var ret = external_call["inet_ntop", c_ssize_t](
        AF_INET, addr_buf, ip_buf, c_uint(16)
    )
    if ret == 0:
        raise Error("inet_ntop (IPv4) failed: " + _errno_str())
    var ip_bytes = InlineArray[UInt8, 46](fill=0)
    var ip_len = 0
    for i in range(16):
        if ip_buf[i] == 0:
            break
        ip_bytes[i] = ip_buf[i]
        ip_len += 1
    return _ParsedAddr(ip_bytes, ip_len, _ntohs(sa.sin_port))


def _parse_sockaddr_in6(sa: _sockaddr_in6) raises -> _ParsedAddr:
    """Convert _sockaddr_in6 -> _ParsedAddr via inet_ntop (stores raw bytes, no String)."""
    var addr_buf = stack_allocation[16, UInt8]()
    for i in range(16):
        addr_buf[i] = sa.sin6_addr[i]
    var ip_buf = stack_allocation[46, UInt8]()  # INET6_ADDRSTRLEN = 46
    var ret = external_call["inet_ntop", c_ssize_t](
        AF_INET6, addr_buf, ip_buf, c_uint(46)
    )
    if ret == 0:
        raise Error("inet_ntop failed: " + _errno_str())
    var ip_bytes = InlineArray[UInt8, 46](fill=0)
    var ip_len = 0
    for i in range(46):
        if ip_buf[i] == 0:
            break
        ip_bytes[i] = ip_buf[i]
        ip_len += 1
    return _ParsedAddr(ip_bytes, ip_len, _ntohs(sa.sin6_port))


# -----------------------------------------------------------------------
# fd leak detection (used by tests)
# -----------------------------------------------------------------------

def _fd_is_open(fd: Int) -> Bool:
    """Returns True if the OS file descriptor fd is still open.
    Uses fstat — more direct than fcntl(F_GETFD), POSIX portable (Linux and macOS).
    Returns False if fstat returns -1 (invalid fd).
    """
    var buf = stack_allocation[1, _stat]()
    return external_call["fstat", c_int](c_int(fd), buf) >= 0
