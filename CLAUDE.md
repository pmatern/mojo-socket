# mojo-socket Development Guidelines

## Active Technologies

- Mojo 0.26.2.0 (pinned: `>=0.26.2.0,<0.27` in `pixi.toml`) + Mojo stdlib only; libc socket API via `external_call` (POSIX)

## Project Structure

```text
socket/
├── __init__.mojo        # Re-exports all public types
├── tcp_listener.mojo    # TcpListener: bind (factory), accept -> AcceptResult, local_addr
├── tcp_stream.mojo      # TcpStream: connect (factory), send, recv, shutdown, peer_addr, local_addr
├── socket.mojo          # Socket: raw fd wrapper (low-level escape hatch)
├── address.mojo         # SocketAddress, AddressFamily, SocketType, Shutdown + constants
└── _libc.mojo           # Private FFI: external_call wrappers, sockaddr structs, helpers

socket_reactor/
├── __init__.mojo          # Re-exports all public types
├── poll.mojo              # Poll, Events, Event
├── interest.mojo          # Interest, Token
├── tcp_stream_nb.mojo     # NonBlockingTcpStream, RecvResult, SendResult
├── tcp_listener_nb.mojo   # NonBlockingTcpListener, NbAcceptResult
└── _libc.mojo             # Private: epoll/kqueue FFI, O_NONBLOCK/FIONBIO, F_GETFL

tests/
├── test_foundation.mojo          # SocketAddress and Socket lifecycle
├── test_server.mojo              # TcpListener: bind/accept/local_addr
├── test_client.mojo              # TcpStream: connect/peer_addr/resource release
├── test_data.mojo                # TcpStream: send/recv/shutdown/EPIPE
├── test_reactor_foundation.mojo  # Token, Interest, _set_nonblocking
├── test_register.mojo            # Poll.create, register/reregister/deregister, readiness
├── test_nb_stream.mojo           # NonBlockingTcpStream connect/send/recv
└── test_nb_listener.mojo         # NonBlockingTcpListener bind/accept
```

## Commands

```bash
# Option 1: Docker (Linux x86_64/aarch64, or for consistent cross-platform dev)
docker compose run --rm mojo-dev
# Inside container:
pixi install
pixi run test-all

# Option 2: Native (macOS on Apple Silicon only — Intel Macs must use Docker)
pixi install
pixi run test-all

# Individual tests (works in Docker or native):
pixi run mojo -I . tests/test_foundation.mojo
pixi run mojo -I . tests/test_server.mojo
pixi run mojo -I . tests/test_client.mojo
pixi run mojo -I . tests/test_data.mojo
pixi run mojo -I . tests/test_reactor_foundation.mojo
pixi run mojo -I . tests/test_register.mojo
pixi run mojo -I . tests/test_nb_stream.mojo
pixi run mojo -I . tests/test_nb_listener.mojo
```

## Code Style

- Use `def` (never `fn`). Add `raises` explicitly when needed.
- Use `comptime` for constants and aliases (never `alias`).
- Use `from std.ffi import external_call, c_int, c_ssize_t, get_errno, ErrNo` for POSIX calls.
- All error messages: `"<operation>(<addr_if_applicable>): errno <code> (<name>)"`
- `TcpListener`, `TcpStream`, `Socket` are all `Movable`, not `Copyable`. `__del__` closes the fd.
- On Linux, `send()` passes `MSG_NOSIGNAL` to prevent SIGPIPE; on macOS `SO_NOSIGPIPE` is used instead.
- On Linux, `socket(2)` ORs in `SOCK_CLOEXEC` atomically; on macOS `fcntl(F_SETFD, FD_CLOEXEC)` is called post-creation.
- `TcpListener.bind()` and `TcpStream.connect()` are static factory methods.
- `accept()` returns `AcceptResult` (stream + peer address).
- Use `comptime if CompilationTarget.is_linux():` for platform-specific logic inside functions.
- Module-level `comptime if` blocks do not create exported names in Mojo 0.26.x — use plain constants and branch at usage sites.
- `Poll`, `NonBlockingTcpStream`, `NonBlockingTcpListener` are `Movable`, not `Copyable`. `__del__` closes the fd.
- `Events` uses a raw `List[UInt8]` byte buffer with hardcoded element sizes (12 bytes for epoll_event, 32 bytes for kevent) and `UnsafePointer` casts. Do not use `sizeof(_epoll_event)` — Mojo may add padding.
- `socket_reactor` error messages follow: `"<operation>(fd=N): errno N (NAME)"`
- epoll_ctl writes are done via raw 12-byte `UInt8` stack buffers (not the `_epoll_event` struct) to avoid Mojo's struct padding between `UInt32` and `UInt64` fields corrupting the token.
- Do not call the same C function via `external_call` with two different arities in the same compilation unit — Mojo emits a conflicting-signature error. Use `ioctl(FIONBIO)` for setting O_NONBLOCK (not `fcntl(F_SETFL)`) to avoid conflicting with the 2-arg `fcntl` declaration baked into the `socket` module.
- Never pass a `SocketAddress` returned from `local_addr()` directly to `connect()` or `bind()` — extract the port and construct a fresh literal: `SocketAddress("127.0.0.1", listener.local_addr().port)`.
- Mojo may drop variables early (at last use, not end of scope). Keep listener sockets alive past `connect()` by using them afterward (e.g. `_ = listener.accept()`).
