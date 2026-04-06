# SPDX-License-Identifier: Apache-2.0
# socket.socket — Socket: raw fd wrapper (low-level escape hatch)
# Platform guard applied in __init__ via comptime assert.

from std.ffi import external_call, c_int, c_uint, get_errno, ErrNo
from std.sys.info import CompilationTarget
from std.collections import InlineArray
from std.memory import stack_allocation
from socket._libc import (
    AF_INET, AF_INET6, SOCK_CLOEXEC,
    F_SETFD, FD_CLOEXEC, SOL_SOCKET_MACOS, SO_NOSIGPIPE,
    _sockaddr_in, _sockaddr_in6, _ParsedAddr,
    _make_sockaddr_in, _make_sockaddr_in6,
    _parse_sockaddr_in, _parse_sockaddr_in6,
    _parsed_addr_to_ip, _errno_str,
)
from socket.address import AddressFamily, SocketType, SocketAddress, _addr_is_ipv6


struct _AcceptRaw(Movable):
    """Raw accept(2) result: new fd + parsed peer address."""
    var fd: c_int
    var addr: _ParsedAddr

    def __init__(out self, fd: c_int, var addr: _ParsedAddr):
        self.fd = fd
        self.addr = addr^

    def __init__(out self, *, deinit take: Self):
        self.fd = take.fd
        self.addr = take.addr^


struct Socket(Movable):
    """Raw OS socket file descriptor wrapper.

    Low-level escape hatch. Use TcpListener / TcpStream for normal usage.
    Exactly one owner per fd (Movable, not Copyable).
    SOCK_CLOEXEC is always set on creation — fd does not leak to children.
    __del__ calls close(2) deterministically.
    """
    var fd:        c_int
    var family:    AddressFamily
    var sock_type: SocketType

    def __init__(out self, family: AddressFamily, sock_type: SocketType) raises:
        """Create an OS socket. Raises on failure with errno info.

        On Linux, SOCK_CLOEXEC is ORed in atomically at creation.
        On macOS, close-on-exec is set via fcntl post-creation, and SIGPIPE
        is suppressed per-socket via SO_NOSIGPIPE (MSG_NOSIGNAL is absent on macOS).
        """
        comptime assert CompilationTarget.is_linux() or CompilationTarget.is_macos(), \
            "socket requires Linux or macOS"
        var new_fd: c_int
        comptime if CompilationTarget.is_linux():
            new_fd = external_call["socket", c_int](
                family.value, sock_type.value | SOCK_CLOEXEC, c_int(0)
            )
            if new_fd < 0:
                raise Error("socket(): " + _errno_str())
        else:
            new_fd = external_call["socket", c_int](family.value, sock_type.value, c_int(0))
            if new_fd < 0:
                raise Error("socket(): " + _errno_str())
            # macOS: set close-on-exec and suppress SIGPIPE post-creation
            _ = external_call["fcntl", c_int](new_fd, F_SETFD, FD_CLOEXEC)
            var one_ptr = stack_allocation[1, c_int]()
            one_ptr[] = c_int(1)
            _ = external_call["setsockopt", c_int](
                new_fd, SOL_SOCKET_MACOS, SO_NOSIGPIPE, one_ptr, c_uint(4)
            )
        self.fd = new_fd
        self.family = family
        self.sock_type = sock_type

    def __init__(out self, *, _fd: c_int, family: AddressFamily, sock_type: SocketType):
        """Internal — wrap an existing fd without calling socket(2)."""
        self.fd = _fd
        self.family = family
        self.sock_type = sock_type

    def close(mut self):
        """Close the OS socket and mark fd as -1. Safe to call multiple times."""
        if self.fd >= 0:
            _ = external_call["close", c_int](self.fd)
            self.fd = c_int(-1)

    def __del__(deinit self):
        """Deterministic cleanup. Closes fd if still open."""
        if self.fd >= 0:
            _ = external_call["close", c_int](self.fd)

    # ------------------------------------------------------------------
    # Low-level socket operations
    # ------------------------------------------------------------------

    def bind(self, addr: SocketAddress) raises:
        """Bind socket to addr. Raises with fd + addr in message on failure."""
        if _addr_is_ipv6(addr.ip):
            var sa = _make_sockaddr_in6(addr.ip, addr.port)
            var sa_ptr = stack_allocation[1, _sockaddr_in6]()
            sa_ptr[] = sa^
            var ret = external_call["bind", c_int](self.fd, sa_ptr, c_uint(28))
            if ret != 0:
                raise Error(
                    "bind(fd=" + String(Int(self.fd)) + ", [" + addr.ip
                    + "]:" + String(Int(addr.port)) + "): " + _errno_str()
                )
        else:
            var sa = _make_sockaddr_in(addr.ip, addr.port)
            var sa_ptr = stack_allocation[1, _sockaddr_in]()
            sa_ptr[] = sa^
            var ret = external_call["bind", c_int](self.fd, sa_ptr, c_uint(16))
            if ret != 0:
                raise Error(
                    "bind(fd=" + String(Int(self.fd)) + ", " + addr.ip
                    + ":" + String(Int(addr.port)) + "): " + _errno_str()
                )

    def listen(self, backlog: Int) raises:
        """Mark socket as passive (listening). Raises on failure."""
        var ret = external_call["listen", c_int](self.fd, c_int(backlog))
        if ret != 0:
            raise Error("listen(fd=" + String(Int(self.fd)) + "): " + _errno_str())

    def connect(self, addr: SocketAddress) raises:
        """Connect to addr. Raises with fd + addr in message on failure."""
        if _addr_is_ipv6(addr.ip):
            var sa = _make_sockaddr_in6(addr.ip, addr.port)
            var sa_ptr = stack_allocation[1, _sockaddr_in6]()
            sa_ptr[] = sa^
            var ret = external_call["connect", c_int](self.fd, sa_ptr, c_uint(28))
            if ret != 0:
                raise Error(
                    "connect(fd=" + String(Int(self.fd)) + ", [" + addr.ip
                    + "]:" + String(Int(addr.port)) + "): " + _errno_str()
                )
        else:
            var sa = _make_sockaddr_in(addr.ip, addr.port)
            var sa_ptr = stack_allocation[1, _sockaddr_in]()
            sa_ptr[] = sa^
            var ret = external_call["connect", c_int](self.fd, sa_ptr, c_uint(16))
            if ret != 0:
                raise Error(
                    "connect(fd=" + String(Int(self.fd)) + ", " + addr.ip
                    + ":" + String(Int(addr.port)) + "): " + _errno_str()
                )

    def accept_raw(self) raises -> _AcceptRaw:
        """Accept one incoming connection. Returns _AcceptRaw (fd + peer addr)."""
        var sa = _sockaddr_in(UInt16(0), UInt16(0), UInt32(0), InlineArray[UInt8, 8](fill=0))
        var sa_ptr = stack_allocation[1, _sockaddr_in]()
        sa_ptr[] = sa^
        var len_ptr = stack_allocation[1, c_uint]()
        len_ptr[] = c_uint(16)
        var client_fd = external_call["accept", c_int](self.fd, sa_ptr, len_ptr)
        if client_fd < 0:
            raise Error("accept(fd=" + String(Int(self.fd)) + "): " + _errno_str())
        var parsed = _parse_sockaddr_in(sa_ptr[])
        return _AcceptRaw(client_fd, parsed^)

    def getsockname(self) raises -> SocketAddress:
        """Return locally bound address. Raises on failure."""
        var sa = _sockaddr_in(UInt16(0), UInt16(0), UInt32(0), InlineArray[UInt8, 8](fill=0))
        var sa_ptr = stack_allocation[1, _sockaddr_in]()
        sa_ptr[] = sa^
        var len_ptr = stack_allocation[1, c_uint]()
        len_ptr[] = c_uint(16)
        var ret = external_call["getsockname", c_int](self.fd, sa_ptr, len_ptr)
        if ret != 0:
            raise Error("local_addr(fd=" + String(Int(self.fd)) + "): " + _errno_str())
        var parsed = _parse_sockaddr_in(sa_ptr[])
        var ip = _parsed_addr_to_ip(parsed)
        return SocketAddress(_ip=ip^, _port=parsed.port)

    def getpeername(self) raises -> SocketAddress:
        """Return remote peer address. Raises on failure."""
        var sa = _sockaddr_in(UInt16(0), UInt16(0), UInt32(0), InlineArray[UInt8, 8](fill=0))
        var sa_ptr = stack_allocation[1, _sockaddr_in]()
        sa_ptr[] = sa^
        var len_ptr = stack_allocation[1, c_uint]()
        len_ptr[] = c_uint(16)
        var ret = external_call["getpeername", c_int](self.fd, sa_ptr, len_ptr)
        if ret != 0:
            raise Error("peer_addr(fd=" + String(Int(self.fd)) + "): " + _errno_str())
        var parsed = _parse_sockaddr_in(sa_ptr[])
        var ip = _parsed_addr_to_ip(parsed)
        return SocketAddress(_ip=ip^, _port=parsed.port)
