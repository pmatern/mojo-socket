# SPDX-License-Identifier: Apache-2.0
from std.ffi import external_call, c_int, c_ssize_t, c_size_t, get_errno
from std.sys.info import CompilationTarget

from socket import Socket, SocketAddress, AddressFamily, SocketType
from socket.address import IPv4, IPv6, TCP, Shutdown, _addr_is_ipv6
from socket._libc import MSG_NOSIGNAL
from socket_reactor._libc import _is_eagain, _is_einprogress, _errno_format


# ── Result types ─────────────────────────────────────────────────────────────

@fieldwise_init
struct RecvResult(TrivialRegisterPassable):
    """Result of NonBlockingTcpStream.recv().

    kind: 0=Data, 1=WouldBlock, 2=Closed
    n:    bytes received (valid only when kind==0)
    """
    var kind: UInt8
    var n:    Int

    @staticmethod
    def data(n: Int) -> RecvResult:
        return RecvResult(UInt8(0), n)

    @staticmethod
    def would_block() -> RecvResult:
        return RecvResult(UInt8(1), 0)

    @staticmethod
    def closed() -> RecvResult:
        return RecvResult(UInt8(2), 0)

    def is_data(self) -> Bool:
        return self.kind == UInt8(0)

    def is_would_block(self) -> Bool:
        return self.kind == UInt8(1)

    def is_closed(self) -> Bool:
        return self.kind == UInt8(2)


@fieldwise_init
struct SendResult(TrivialRegisterPassable):
    """Result of NonBlockingTcpStream.send().

    kind: 0=Sent, 1=WouldBlock
    n:    bytes sent (valid only when kind==0)
    """
    var kind: UInt8
    var n:    Int

    @staticmethod
    def sent(n: Int) -> SendResult:
        return SendResult(UInt8(0), n)

    @staticmethod
    def would_block() -> SendResult:
        return SendResult(UInt8(1), 0)

    def is_sent(self) -> Bool:
        return self.kind == UInt8(0)

    def is_would_block(self) -> Bool:
        return self.kind == UInt8(1)


# ── NonBlockingTcpStream ─────────────────────────────────────────────────────

struct NonBlockingTcpStream(Movable):
    """TCP stream with O_NONBLOCK set. Use with Poll for event-driven I/O.

    Created via NonBlockingTcpStream.connect(). recv() and send() never block —
    they return RecvResult / SendResult indicating whether data was transferred
    or the operation would have blocked.

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
    def connect(addr: SocketAddress) raises -> NonBlockingTcpStream:
        """Create a non-blocking socket and initiate connection to addr.

        Returns immediately; EINPROGRESS is treated as success (connection in
        progress). Register with Poll(Interest.Write) and check getsockopt
        SO_ERROR to confirm the connection completed.
        Raises on hard errors (ECONNREFUSED, ENETUNREACH, etc.).
        """
        var family: AddressFamily
        if _addr_is_ipv6(addr.ip):
            family = IPv6
        else:
            family = IPv4
        var sock = Socket(family, TCP)
        from socket_reactor._libc import _set_nonblocking
        _set_nonblocking(sock.fd)
        try:
            sock.connect(addr)
        except e:
            if "EINPROGRESS" not in String(e):
                raise e^
        return NonBlockingTcpStream(_socket=sock^)

    def recv(self, buf: Span[mut=True, Byte, _]) raises -> RecvResult:
        """Read available bytes into buf. Returns immediately.

        RecvResult.data(n)       — n bytes read into buf[0..n]
        RecvResult.would_block() — no data available; try again after poll readable
        RecvResult.closed()      — peer sent FIN; no more data will arrive
        Raises on hard errors.
        """
        if len(buf) == 0:
            return RecvResult.data(0)
        var result = external_call["recv", c_ssize_t](
            self.fd,
            buf.unsafe_ptr(),
            c_size_t(len(buf)),
            c_int(0),
        )
        if result > 0:
            return RecvResult.data(Int(result))
        if result == 0:
            return RecvResult.closed()
        # result < 0
        var errno_code = Int(get_errno().value)
        if _is_eagain(errno_code):
            return RecvResult.would_block()
        raise Error("recv(fd=" + String(Int(self.fd)) + "): " + _errno_format(errno_code))

    def send(self, data: Span[Byte, _]) raises -> SendResult:
        """Send as many bytes as the kernel buffer allows. Returns immediately.

        SendResult.sent(n)       — n bytes sent (may be partial; caller retries remainder)
        SendResult.would_block() — kernel buffer full; try again after poll writable
        Returns SendResult.sent(0) immediately for empty data (no syscall).
        Raises on hard errors (EPIPE, ECONNRESET, etc.).
        """
        if len(data) == 0:
            return SendResult.sent(0)
        var send_flags: c_int
        comptime if CompilationTarget.is_linux():
            send_flags = MSG_NOSIGNAL
        else:
            send_flags = c_int(0)
        var result = external_call["send", c_ssize_t](
            self.fd,
            data.unsafe_ptr(),
            c_size_t(len(data)),
            send_flags,
        )
        if result >= 0:
            return SendResult.sent(Int(result))
        var errno_code = Int(get_errno().value)
        if _is_eagain(errno_code):
            return SendResult.would_block()
        raise Error("send(fd=" + String(Int(self.fd)) + "): " + _errno_format(errno_code))

    def shutdown(self, how: Shutdown) raises:
        """Half-close the connection. how: Shutdown(0)=SHUT_RD, (1)=SHUT_WR, (2)=SHUT_RDWR."""
        var ret = external_call["shutdown", c_int](self.fd, how.value)
        if ret < 0:
            raise Error("shutdown(fd=" + String(Int(self.fd)) + "): " + _errno_format(Int(get_errno().value)))

    def peer_addr(self) raises -> SocketAddress:
        """Return remote peer address."""
        return self._socket.getpeername()

    def local_addr(self) raises -> SocketAddress:
        """Return local endpoint address."""
        return self._socket.getsockname()

    def close(mut self):
        """Close the underlying socket. Sets fd to -1."""
        self._socket.close()
        self.fd = c_int(-1)

    def into_socket(var self) -> Socket:
        """Consume this NonBlockingTcpStream and return the underlying Socket."""
        return self._socket^
