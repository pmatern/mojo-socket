# socket

A Mojo socket library that wraps the POSIX / libc network API in an idiomatic,
ownership-safe interface. The design follows the same principles as Mojo's own
standard library: deterministic ownership, explicit error propagation, and no
hidden allocation.

## Design

The library has two layers.

**High-level layer** — the types most programs use:

- `TcpListener` — a bound, listening TCP socket. Created with
  `TcpListener.bind(addr)`. Blocks on `accept()` and returns an `AcceptResult`
  containing a `TcpStream` and the peer `SocketAddress`.
- `TcpStream` — one end of a TCP connection, either accepted by a listener or
  created by `TcpStream.connect(addr)`. Supports `send()`, `recv()`, and
  `shutdown()` for half-close.

**Low-level layer** — for callers that need raw control:

- `Socket` — a thin wrapper around a single OS file descriptor. Exposes
  `bind`, `listen`, `connect`, `accept_raw`, `getsockname`, and `getpeername`
  directly. The high-level types are built on top of `Socket`; you can
  construct either type from an existing `Socket` when you need to call
  `setsockopt` or other syscalls before handing it to the library.

**Ownership model**

All three types are `Movable` and not `Copyable`. Each value owns exactly one
file descriptor. The destructor closes the fd deterministically when the value
goes out of scope, so there is no need to call `close()` explicitly in the
normal case. `close()` is provided for early release and is safe to call
multiple times.

**Error handling**

Every operation that can fail raises an `Error`. Error messages include the
syscall name, the file descriptor number, the address where relevant, and the
errno code and name:

```
bind(fd=3, 127.0.0.1:8080): errno 98 (EADDRINUSE)
connect(fd=5, 127.0.0.1:1): errno 111 (ECONNREFUSED)
```

**Platform notes**

The library targets POSIX systems with a libc that provides the standard socket
API. On Linux, `SOCK_CLOEXEC` is set atomically at socket creation and
`MSG_NOSIGNAL` is passed to every `send()` call. On macOS, the equivalent
`fcntl(F_SETFD, FD_CLOEXEC)` and `SO_NOSIGPIPE` are applied post-creation.
Platform branches use `comptime if CompilationTarget.is_linux()` so that only
the relevant code is emitted for each target.

Only numeric IP addresses are accepted — `SocketAddress` validates its input
via `inet_pton` and never performs hostname resolution.

## Requirements

- Mojo `>=0.26.2.0,<0.27`
- [pixi](https://prefix.dev/) for environment management
- Docker (the Mojo conda package is only available for `linux-64`)

## Building

```bash
# Start the development container
docker compose run --rm mojo-dev

# Inside the container — install dependencies
pixi install

# Run all tests
pixi run test-all
```

Individual test suites:

```bash
pixi run mojo -I . tests/test_foundation.mojo   # SocketAddress + Socket lifecycle
pixi run mojo -I . tests/test_server.mojo        # TcpListener
pixi run mojo -I . tests/test_client.mojo        # TcpStream.connect
pixi run mojo -I . tests/test_data.mojo          # send / recv / shutdown
```

## Usage

### Echo server

```mojo
from socket import TcpListener, TcpStream, SocketAddress

def main() raises:
    var listener = TcpListener.bind(SocketAddress("127.0.0.1", 9000))
    print("Listening on", listener.local_addr())

    var result = listener.accept()
    print("Connection from", result.peer)

    var buf = List[Byte](capacity=4096)
    for _ in range(4096):
        buf.append(0)
    var n = result.stream.recv(Span[mut=True, Byte](buf))
    if n > 0:
        _ = result.stream.send(Span(buf)[:n])
```

### Echo client

```mojo
from socket import TcpStream, SocketAddress

def main() raises:
    var stream = TcpStream.connect(SocketAddress("127.0.0.1", 9000))
    print("Connected to", stream.peer_addr())

    var msg = "hello, socket"
    var sent = stream.send(msg.as_bytes())
    print("Sent:", sent, "bytes")

    var buf = List[Byte](capacity=4096)
    for _ in range(4096):
        buf.append(0)
    var n = stream.recv(Span[mut=True, Byte](buf))
    print("Received:", StringSlice(unsafe_from_utf8=Span[Byte](buf)[:n]))
```

### Error handling

```mojo
try:
    var listener = TcpListener.bind(SocketAddress("127.0.0.1", 80))
except e:
    print(e)  # bind(fd=3, 127.0.0.1:80): errno 13 (EACCES)
```

### Half-close

```mojo
from socket.address import Write as ShutdownWrite

# Signal end-of-write to the peer while keeping the read half open.
stream.shutdown(ShutdownWrite)

# The peer's recv() will now return 0 (EOF).
```

### Low-level escape hatch

```mojo
from socket import Socket, AddressFamily, SocketType

# Create a raw socket, configure it, then wrap in a high-level type.
var sock = Socket(AddressFamily(2), SocketType(1))
var fd = sock.fd   # pass to external setsockopt / ioctl calls
var listener = TcpListener(_socket=sock^)
```

## API reference

### SocketAddress

```
SocketAddress(ip: String, port: UInt16)  # raises on invalid numeric IP
addr.ip    -> String
addr.port  -> UInt16
```

### TcpListener

```
TcpListener.bind(addr: SocketAddress, backlog: Int = 128) -> TcpListener
listener.accept()      -> AcceptResult   # .stream: TcpStream, .peer: SocketAddress
listener.local_addr()  -> SocketAddress
listener.close()
```

### TcpStream

```
TcpStream.connect(addr: SocketAddress) -> TcpStream
stream.send(data: Span[Byte, _])             -> Int   # bytes sent; may be partial
stream.recv(buf: Span[mut=True, Byte, _])    -> Int   # bytes received; 0 = peer closed
stream.shutdown(how: Shutdown)
stream.peer_addr()   -> SocketAddress
stream.local_addr()  -> SocketAddress
stream.close()
```

`Shutdown` values: `socket.address.Read`, `Write`, `Both`

### Socket

```
Socket(family: AddressFamily, sock_type: SocketType)
socket.fd          -> c_int
socket.bind(addr)
socket.listen(backlog)
socket.connect(addr)
socket.accept_raw()    -> _AcceptRaw
socket.getsockname()   -> SocketAddress
socket.getpeername()   -> SocketAddress
socket.close()
```
