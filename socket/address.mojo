# socket.address — SocketAddress, AddressFamily, SocketType, Shutdown and constants
# Platform: Linux only (enforced via comptime assert in SocketAddress.__init__).

from std.ffi import c_int
from std.sys.info import CompilationTarget
from socket._libc import AF_INET, AF_INET6, SOCK_STREAM, SHUT_RD, SHUT_WR, SHUT_RDWR, _validate_ip


# -----------------------------------------------------------------------
# AddressFamily
# -----------------------------------------------------------------------

@fieldwise_init
struct AddressFamily(TrivialRegisterPassable, Equatable):
    """Address family for socket creation (AF_INET / AF_INET6)."""
    var value: c_int

    def __eq__(self, other: Self) -> Bool:
        return self.value == other.value

    def __ne__(self, other: Self) -> Bool:
        return self.value != other.value


comptime IPv4 = AddressFamily(AF_INET)   # 2
comptime IPv6 = AddressFamily(AF_INET6)  # 10


# -----------------------------------------------------------------------
# SocketType
# -----------------------------------------------------------------------

@fieldwise_init
struct SocketType(TrivialRegisterPassable, Equatable):
    """Socket type (SOCK_STREAM = TCP)."""
    var value: c_int

    def __eq__(self, other: Self) -> Bool:
        return self.value == other.value

    def __ne__(self, other: Self) -> Bool:
        return self.value != other.value


comptime TCP = SocketType(SOCK_STREAM)   # 1


# -----------------------------------------------------------------------
# Shutdown
# -----------------------------------------------------------------------

@fieldwise_init
struct Shutdown(TrivialRegisterPassable, Equatable):
    """Half-close control for TcpStream.shutdown()."""
    var value: c_int

    def __eq__(self, other: Self) -> Bool:
        return self.value == other.value

    def __ne__(self, other: Self) -> Bool:
        return self.value != other.value


comptime Read  = Shutdown(SHUT_RD)    # 0 — close read half
comptime Write = Shutdown(SHUT_WR)    # 1 — close write half
comptime Both  = Shutdown(SHUT_RDWR)  # 2 — close both halves


# -----------------------------------------------------------------------
# SocketAddress
# -----------------------------------------------------------------------

def _addr_is_ipv6(ip: String) -> Bool:
    """Returns True if ip string contains ':' (IPv6 indicator)."""
    for b in ip.as_bytes():
        if b == UInt8(58):  # ':' = ASCII 58
            return True
    return False


struct SocketAddress(Copyable, Movable, Writable):
    """Numeric network endpoint: IP address (IPv4 or IPv6) plus port.

    Only numeric IP strings are accepted — no hostname resolution.
    Validated via inet_pton on construction.
    """
    var ip:   String
    var port: UInt16

    def __init__(out self, ip: String, port: UInt16) raises:
        """Construct and validate. Raises on invalid numeric IP."""
        comptime assert CompilationTarget.is_linux() or CompilationTarget.is_macos(), \
            "socket requires Linux or macOS"
        _validate_ip(ip)
        self.ip = ip
        self.port = port

    def __init__(out self, *, var _ip: String, _port: UInt16):
        """Internal constructor — skips validation, moves ip. For use by socket helpers only."""
        self.ip = _ip^
        self.port = _port

    def write_to(self, mut writer: Some[Writer]):
        """IPv4: '127.0.0.1:8080'  IPv6: '[::1]:8080'"""
        if _addr_is_ipv6(self.ip):
            writer.write("[", self.ip, "]:", String(Int(self.port)))
        else:
            writer.write(self.ip, ":", String(Int(self.port)))
