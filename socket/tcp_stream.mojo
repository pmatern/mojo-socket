# socket.tcp_stream — TcpStream: connect (factory), send, recv, shutdown,
#                          peer_addr, local_addr, into_socket

from std.ffi import external_call, c_int, c_ssize_t, c_size_t, get_errno
from std.sys.info import CompilationTarget
from socket._libc import MSG_NOSIGNAL, SHUT_RD, SHUT_WR, SHUT_RDWR, _errno_str
from socket.address import AddressFamily, SocketType, SocketAddress, Shutdown, TCP, IPv4, IPv6, _addr_is_ipv6
from socket.socket import Socket


struct TcpStream(Movable):
    """One end of a TCP connection (client or accepted server side).

    Created via TcpStream.connect() (client) or returned from TcpListener.accept() (server).
    Movable, not Copyable — exactly one owner per fd.
    __del__ closes the OS socket deterministically.
    """
    var _socket: Socket

    @staticmethod
    def connect(addr: SocketAddress) raises -> TcpStream:
        """Create a socket and connect to addr. Raises on failure.

        Error format: 'connect(fd=<fd>, <addr>): errno <code> (<name>)'
        """
        var family: AddressFamily
        if _addr_is_ipv6(addr.ip):
            family = IPv6
        else:
            family = IPv4
        var sock = Socket(family, TCP)
        sock.connect(addr)
        return TcpStream(_socket=sock^)

    def __init__(out self, *, var _socket: Socket):
        """Internal — wrap an existing connected fd (used by TcpListener.accept)."""
        self._socket = _socket^

    def __init__(out self, *, deinit take: Self):
        """Move constructor."""
        self._socket = take._socket^

    def __del__(deinit self):
        """Deterministic cleanup — delegates to Socket.__del__."""
        pass  # Socket field is destroyed automatically

    def send(self, data: Span[Byte, _]) raises -> Int:
        """Send bytes. Uses MSG_NOSIGNAL to prevent SIGPIPE.

        Returns number of bytes sent (may be < len(data) for partial sends).
        Caller must retry remainder for partial sends.
        Returns 0 immediately for empty data (no syscall).
        """
        if len(data) == 0:
            return 0
        # Linux: MSG_NOSIGNAL suppresses SIGPIPE. macOS: SO_NOSIGPIPE is set on socket; use 0.
        var send_flags: c_int
        comptime if CompilationTarget.is_linux():
            send_flags = MSG_NOSIGNAL
        else:
            send_flags = c_int(0)
        var result = external_call["send", c_ssize_t](
            self._socket.fd,
            data.unsafe_ptr(),
            c_size_t(len(data)),
            send_flags,
        )
        if result < 0:
            raise Error("send(fd=" + String(Int(self._socket.fd)) + "): " + _errno_str())
        return Int(result)

    def recv(self, buf: Span[mut=True, Byte, _]) raises -> Int:
        """Receive bytes into buf. Returns 0 on peer close, > 0 on data."""
        var result = external_call["recv", c_ssize_t](
            self._socket.fd,
            buf.unsafe_ptr(),
            c_size_t(len(buf)),
            c_int(0),
        )
        if result < 0:
            raise Error("recv(fd=" + String(Int(self._socket.fd)) + "): " + _errno_str())
        return Int(result)

    def shutdown(self, how: Shutdown) raises:
        """Half-close: Shutdown.Read, Shutdown.Write, or Shutdown.Both."""
        var ret = external_call["shutdown", c_int](self._socket.fd, how.value)
        if ret < 0:
            raise Error("shutdown(fd=" + String(Int(self._socket.fd)) + "): " + _errno_str())

    def peer_addr(self) raises -> SocketAddress:
        """Return remote peer address."""
        return self._socket.getpeername()

    def local_addr(self) raises -> SocketAddress:
        """Return local endpoint address."""
        return self._socket.getsockname()

    def close(mut self):
        """Close the underlying socket."""
        self._socket.close()

    def into_socket(var self) -> Socket:
        """Consume this TcpStream and return the underlying Socket."""
        return self._socket^
