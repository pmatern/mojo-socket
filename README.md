# mojo-socket

A Mojo socket library with two packages:

- **`socket`** — blocking TCP sockets with deterministic ownership
- **`socket_reactor`** — non-blocking TCP sockets with an epoll/kqueue reactor

Both follow the same design principles: deterministic ownership, explicit error
propagation, and no hidden allocation.

---

## `socket` — blocking TCP

### Design

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

### Usage

#### Echo server

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

#### Echo client

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

#### Half-close

```mojo
from socket.address import Write as ShutdownWrite

# Signal end-of-write to the peer while keeping the read half open.
stream.shutdown(ShutdownWrite)
# The peer's recv() will now return 0 (EOF).
```

#### Low-level escape hatch

```mojo
from socket import Socket, AddressFamily, SocketType

# Create a raw socket, configure it, then wrap in a high-level type.
var sock = Socket(AddressFamily(2), SocketType(1))
var fd = sock.fd   # pass to external setsockopt / ioctl calls
var listener = TcpListener(_socket=sock^)
```

### API reference

#### SocketAddress

```
SocketAddress(ip: String, port: UInt16)  # raises on invalid numeric IP
addr.ip    -> String
addr.port  -> UInt16
```

#### TcpListener

```
TcpListener.bind(addr: SocketAddress, backlog: Int = 128) -> TcpListener
listener.accept()      -> AcceptResult   # .stream: TcpStream, .peer: SocketAddress
listener.local_addr()  -> SocketAddress
listener.close()
```

#### TcpStream

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

#### Socket

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

---

## `socket_reactor` — non-blocking TCP with epoll/kqueue

### Design

`socket_reactor` wraps `epoll` (Linux) and `kqueue` (macOS) behind a unified
`Poll` API. Sockets are set to `O_NONBLOCK` at creation; operations that would
block return a result variant (`WouldBlock`, `Sent`, `Data`, etc.) rather than
blocking. A single `Poll` instance can watch many file descriptors at once.

**Types:**

- `Poll` — owns an epoll/kqueue fd. Register fds with `register()`,
  `reregister()`, `deregister()`, and wait for readiness with `poll()`.
- `Events` / `Event` — pre-allocated readiness buffer. Index into `Events` after
  `poll()` to read each `Event`'s token, `is_readable()`, `is_writable()`, etc.
- `Interest` — `Read`, `Write`, or `ReadWrite`; controls which directions are
  watched.
- `Token` — a `UInt64` tag you supply at registration and receive back in each
  ready `Event`, used to identify which fd is ready.
- `NonBlockingTcpListener` — non-blocking listener. `accept()` returns
  `NbAcceptResult` immediately (`Accepted` or `WouldBlock`).
- `NonBlockingTcpStream` — non-blocking stream. `send()` returns `SendResult`
  (`Sent(n)` or `WouldBlock`); `recv()` returns `RecvResult` (`Data(n)`,
  `WouldBlock`, or `Closed`).

**Ownership model**

`Poll`, `NonBlockingTcpStream`, and `NonBlockingTcpListener` are all `Movable`,
not `Copyable`. Each owns exactly one fd; `__del__` closes it.

### Usage

#### Non-blocking echo server (single connection)

```mojo
from socket_reactor import Poll, Events, NonBlockingTcpListener
from socket_reactor.interest import Token, Read, Write
from socket import SocketAddress

def main() raises:
    var listener = NonBlockingTcpListener.bind(SocketAddress("127.0.0.1", 9000))
    var poll = Poll.create()
    poll.register(listener.fd, Token(UInt64(0)), Read)

    var events = Events(capacity=16)
    _ = poll.poll(events, timeout_ms=-1)   # block until readable

    var result = listener.accept()
    if result.is_accepted():
        poll.register(result.stream.fd, Token(UInt64(1)), Read)

        _ = poll.poll(events, timeout_ms=1000)

        var buf = List[UInt8](capacity=4096)
        for _ in range(4096):
            buf.append(0)
        var r = result.stream.recv(Span[mut=True, UInt8](buf))
        if r.is_data():
            _ = result.stream.send(Span[UInt8](buf)[:r.n()])
```

#### Non-blocking connect

```mojo
from socket_reactor import Poll, Events, NonBlockingTcpStream
from socket_reactor.interest import Token, Write
from socket import SocketAddress

def main() raises:
    var stream = NonBlockingTcpStream.connect(SocketAddress("127.0.0.1", 9000))
    # connect() returns with EINPROGRESS in progress; poll for writability
    var poll = Poll.create()
    poll.register(stream.fd, Token(UInt64(0)), Write)

    var events = Events(capacity=4)
    _ = poll.poll(events, timeout_ms=1000)
    # events[0].is_writable() == True when the connection is established

    var msg = "hello reactor"
    var r = stream.send(msg.as_bytes())
    if r.is_sent():
        print("sent", r.n(), "bytes")
```

### API reference

#### Poll

```
Poll.create() -> Poll
poll.register(fd: c_int, token: Token, interest: Interest)
poll.reregister(fd: c_int, token: Token, interest: Interest)
poll.deregister(fd: c_int)
poll.poll(mut events: Events, timeout_ms: Int) -> Int  # count of ready events
```

`timeout_ms=-1` blocks indefinitely; `timeout_ms=0` returns immediately.

#### Events / Event

```
Events(capacity: Int)
events[i]            -> Event
len(events)          -> Int   # count after last poll()

event.token()        -> Token
event.is_readable()  -> Bool
event.is_writable()  -> Bool
event.is_read_closed()   -> Bool   # peer sent FIN
event.is_write_closed()  -> Bool
event.is_error()     -> Bool
```

#### Interest / Token

```
Read        # watch for readability
Write       # watch for writability
ReadWrite   # watch both

Token(UInt64(n))
token.value  -> UInt64
```

#### NonBlockingTcpListener

```
NonBlockingTcpListener.bind(addr: SocketAddress, backlog: Int = 128) -> NonBlockingTcpListener
listener.accept()      -> NbAcceptResult   # .is_accepted(), .is_would_block()
                                           # .stream: NonBlockingTcpStream, .peer: SocketAddress
listener.local_addr()  -> SocketAddress
listener.fd            -> c_int
listener.close()
```

#### NonBlockingTcpStream

```
NonBlockingTcpStream.connect(addr: SocketAddress) -> NonBlockingTcpStream
stream.send(data: Span[Byte, _])            -> SendResult   # .is_sent(), .is_would_block(), .n()
stream.recv(buf: Span[mut=True, Byte, _])   -> RecvResult   # .is_data(), .is_would_block(), .is_closed(), .n()
stream.shutdown(how: Shutdown)
stream.fd   -> c_int
stream.close()
```

---

## Building and testing

### Requirements

- Mojo `>=0.26.2.0,<0.27`
- [pixi](https://prefix.dev/) for environment management
- Docker (the Mojo conda package is only available for `linux-64`)

### Commands

```bash
# Start the development container
docker compose run --rm mojo-dev

# Inside the container — install dependencies and run all tests
pixi install
pixi run test-all
```

Individual test suites:

```bash
# socket
pixi run mojo -I . tests/test_foundation.mojo   # SocketAddress + Socket lifecycle
pixi run mojo -I . tests/test_server.mojo        # TcpListener
pixi run mojo -I . tests/test_client.mojo        # TcpStream.connect
pixi run mojo -I . tests/test_data.mojo          # send / recv / shutdown

# socket_reactor
pixi run mojo -I . tests/test_reactor_foundation.mojo  # Token, Interest, O_NONBLOCK
pixi run mojo -I . tests/test_register.mojo            # Poll register/reregister/deregister
pixi run mojo -I . tests/test_nb_stream.mojo           # NonBlockingTcpStream
pixi run mojo -I . tests/test_nb_listener.mojo         # NonBlockingTcpListener
```

### Error handling

Every operation that can fail raises an `Error`. Error messages include the
syscall name, the file descriptor or address where relevant, and the errno code
and name:

```
bind(fd=3, 127.0.0.1:8080): errno 98 (EADDRINUSE)
connect(fd=5, 127.0.0.1:1): errno 111 (ECONNREFUSED)
ioctl(FIONBIO, fd=7): errno 9 (EBADF)
epoll_ctl(ADD, fd=8): errno 17 (EEXIST)
```

### Platform notes

Both packages target POSIX systems. On Linux, `SOCK_CLOEXEC` is set atomically
at socket creation and `MSG_NOSIGNAL` is passed to every `send()` call. On
macOS, the equivalent `fcntl(F_SETFD, FD_CLOEXEC)` and `SO_NOSIGPIPE` are used
instead. The reactor uses `epoll` on Linux and `kqueue` on macOS. Platform
branches use `comptime if CompilationTarget.is_linux()` so only the relevant
code is emitted.
