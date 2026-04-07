# SPDX-License-Identifier: Apache-2.0
from std.ffi import external_call, c_int, c_uint, get_errno
from std.collections import InlineArray
from std.memory import stack_allocation

from socket import Socket, SocketAddress, AddressFamily, SocketType
from socket.address import IPv4, IPv6, TCP, _addr_is_ipv6
from socket._libc import (
    _sockaddr_in, _parse_sockaddr_in, _parsed_addr_to_ip,
)
from socket_reactor._libc import _set_nonblocking, _is_eagain, _errno_format
from socket_reactor.tcp_stream_nb import NonBlockingTcpStream


# ── NbAcceptResult ───────────────────────────────────────────────────────────

struct NbAcceptResult(Movable):
    """Result of NonBlockingTcpListener.accept().

    kind: 0=Accepted, 1=WouldBlock
    stream: valid NonBlockingTcpStream when kind==0; sentinel (fd=-1) when kind==1
    peer:   peer SocketAddress when kind==0; sentinel when kind==1
    """
    var kind:   UInt8
    var stream: NonBlockingTcpStream
    var peer:   SocketAddress

    @staticmethod
    def accepted(var stream: NonBlockingTcpStream, var peer: SocketAddress) -> NbAcceptResult:
        return NbAcceptResult(UInt8(0), stream^, peer^)

    @staticmethod
    def would_block() -> NbAcceptResult:
        var sentinel = Socket(_fd=c_int(-1), family=IPv4, sock_type=TCP)
        var sentinel_stream = NonBlockingTcpStream(_socket=sentinel^)
        var sentinel_peer = SocketAddress(_ip=String("0.0.0.0"), _port=UInt16(0))
        return NbAcceptResult(UInt8(1), sentinel_stream^, sentinel_peer^)

    def __init__(
        out self,
        kind: UInt8,
        var stream: NonBlockingTcpStream,
        var peer: SocketAddress,
    ):
        self.kind   = kind
        self.stream = stream^
        self.peer   = peer^

    def __init__(out self, *, deinit take: Self):
        self.kind   = take.kind
        self.stream = take.stream^
        self.peer   = take.peer^

    def is_accepted(self) -> Bool:
        return self.kind == UInt8(0)

    def is_would_block(self) -> Bool:
        return self.kind == UInt8(1)


# ── NonBlockingTcpListener ───────────────────────────────────────────────────

struct NonBlockingTcpListener(Movable):
    """TCP listener with O_NONBLOCK set. accept() returns immediately.

    Created via NonBlockingTcpListener.bind(). Register with Poll(Interest.Read)
    and call accept() when the listener fd is reported readable.

    .fd is the raw OS fd for use with Poll.register(). It is set to -1 after close().
    """
    var fd:      c_int   # raw fd, -1 after close
    var _socket: Socket

    def __init__(out self, *, var _socket: Socket):
        self.fd = _socket.fd
        self._socket = _socket^

    def __init__(out self, *, deinit take: Self):
        self.fd = take.fd
        self._socket = take._socket^

    def __del__(deinit self):
        pass  # Socket __del__ closes fd

    @staticmethod
    def bind(addr: SocketAddress, backlog: Int = 128) raises -> NonBlockingTcpListener:
        """Create a non-blocking listening socket bound to addr.

        Raises on failure (bind, listen, or set_nonblocking errors).
        Use port=0 to let the OS assign a port (recover with local_addr()).
        """
        var family: AddressFamily
        if _addr_is_ipv6(addr.ip):
            family = IPv6
        else:
            family = IPv4
        var sock = Socket(family, TCP)
        _set_nonblocking(sock.fd)
        sock.bind(addr)
        sock.listen(backlog)
        return NonBlockingTcpListener(_socket=sock^)

    def accept(self) raises -> NbAcceptResult:
        """Accept one pending connection. Returns immediately.

        NbAcceptResult.accepted(stream, peer) — new NonBlockingTcpStream + peer address.
          The accepted stream also has O_NONBLOCK set.
        NbAcceptResult.would_block()          — no pending connection; try again after poll.
        Raises on hard errors.
        """
        var sa = _sockaddr_in(UInt16(0), UInt16(0), UInt32(0), InlineArray[UInt8, 8](fill=0))
        var sa_ptr = stack_allocation[1, _sockaddr_in]()
        sa_ptr[] = sa^
        var len_ptr = stack_allocation[1, c_uint]()
        len_ptr[] = c_uint(16)

        var client_fd = external_call["accept", c_int](self.fd, sa_ptr, len_ptr)
        if client_fd < 0:
            var errno_code = Int(get_errno().value)
            if _is_eagain(errno_code):
                return NbAcceptResult.would_block()
            raise Error("accept(fd=" + String(Int(self.fd)) + "): " + _errno_format(errno_code))

        # Set O_NONBLOCK on the accepted fd
        _set_nonblocking(client_fd)

        var parsed = _parse_sockaddr_in(sa_ptr[])
        var ip = _parsed_addr_to_ip(parsed)
        var peer_addr = SocketAddress(_ip=ip^, _port=parsed.port)
        var new_sock = Socket(
            _fd=client_fd,
            family=self._socket.family,
            sock_type=self._socket.sock_type,
        )
        var stream = NonBlockingTcpStream(_socket=new_sock^)
        return NbAcceptResult.accepted(stream^, peer_addr^)

    def local_addr(self) raises -> SocketAddress:
        """Return the locally bound address."""
        return self._socket.getsockname()

    def close(mut self):
        """Close the underlying socket. Sets fd to -1."""
        self._socket.close()
        self.fd = c_int(-1)

    def into_socket(var self) -> Socket:
        """Consume this NonBlockingTcpListener and return the underlying Socket."""
        return self._socket^
