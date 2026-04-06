# socket.tcp_listener — TcpListener: bind (factory), accept, local_addr, into_socket

from std.ffi import external_call, c_int, c_uint
from std.collections import InlineArray
from std.memory import stack_allocation
from socket._libc import (
    AF_INET, AF_INET6, SOCK_CLOEXEC,
    _sockaddr_in, _sockaddr_in6,
    _ParsedAddr,
    _make_sockaddr_in, _make_sockaddr_in6,
    _parse_sockaddr_in, _parse_sockaddr_in6,
    _parsed_addr_to_ip,
    _errno_str,
)
from socket.address import AddressFamily, SocketType, SocketAddress, TCP, IPv4, IPv6, _addr_is_ipv6
from socket.socket import Socket
from socket.tcp_stream import TcpStream


struct AcceptResult(Movable):
    """Result of TcpListener.accept(): new connection stream + peer address."""
    var stream: TcpStream
    var peer: SocketAddress

    def __init__(out self, *, var stream: TcpStream, var peer: SocketAddress):
        self.stream = stream^
        self.peer = peer^

    def __init__(out self, *, deinit take: Self):
        self.stream = take.stream^
        self.peer = take.peer^


struct TcpListener(Movable):
    """TCP server socket: bind, listen, and accept connections.

    Created via `TcpListener.bind()`. Movable, not Copyable.
    __del__ closes the OS socket deterministically.
    """
    var _socket: Socket

    @staticmethod
    def bind(addr: SocketAddress, backlog: Int = 128) raises -> TcpListener:
        """Bind and listen on addr. Returns a ready TcpListener.

        Uses SO_REUSEADDR implicitly via port=0 (OS-assigned) or explicit port.
        Error format: 'bind(fd=<fd>, <addr>): errno <code> (<name>)'
        """
        var family: AddressFamily
        if _addr_is_ipv6(addr.ip):
            family = IPv6
        else:
            family = IPv4
        var sock = Socket(family, TCP)
        sock.bind(addr)
        sock.listen(backlog)
        return TcpListener(_socket=sock^)

    def __init__(out self, *, var _socket: Socket):
        """Internal — wrap an existing bound+listening socket."""
        self._socket = _socket^

    def __del__(deinit self):
        """Deterministic cleanup — Socket field destroyed automatically."""
        pass

    def accept(self) raises -> AcceptResult:
        """Accept one incoming connection.

        Returns AcceptResult with .stream (TcpStream) and .peer (SocketAddress).
        Error format: 'accept(fd=<fd>): errno <code> (<name>)'
        """
        var raw = self._socket.accept_raw()
        var ip = _parsed_addr_to_ip(raw.addr)
        var peer_addr = SocketAddress(_ip=ip^, _port=raw.addr.port)
        var new_sock = Socket(_fd=raw.fd, family=self._socket.family, sock_type=self._socket.sock_type)
        return AcceptResult(stream=TcpStream(_socket=new_sock^), peer=peer_addr^)

    def local_addr(self) raises -> SocketAddress:
        """Return the locally bound address (useful when port=0 was used)."""
        return self._socket.getsockname()

    def close(mut self):
        """Close the underlying socket."""
        self._socket.close()

    def into_socket(var self) -> Socket:
        """Consume this TcpListener and return the underlying Socket."""
        return self._socket^
