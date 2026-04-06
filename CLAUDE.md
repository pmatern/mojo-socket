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

tests/
├── test_foundation.mojo # SocketAddress and Socket lifecycle
├── test_server.mojo     # TcpListener: bind/accept/local_addr
├── test_client.mojo     # TcpStream: connect/peer_addr/resource release
└── test_data.mojo       # TcpStream: send/recv/shutdown/EPIPE
```

## Commands

```bash
# All commands must run inside Docker — Mojo does not run on native macOS host
docker compose run --rm mojo-dev

# Inside container:
pixi install
pixi run test-all
# or individually:
pixi run mojo -I . tests/test_foundation.mojo
pixi run mojo -I . tests/test_server.mojo
pixi run mojo -I . tests/test_client.mojo
pixi run mojo -I . tests/test_data.mojo
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
