# SPDX-License-Identifier: Apache-2.0
from std.ffi import external_call, c_int
from std.sys.info import CompilationTarget
from std.memory import stack_allocation

from socket_reactor._libc import (
    _errno_str,
    _kevent,
    EPOLL_CLOEXEC, EPOLLIN, EPOLLOUT, EPOLLRDHUP, EPOLLERR, EPOLLHUP,
    EPOLL_CTL_ADD, EPOLL_CTL_MOD, EPOLL_CTL_DEL,
    EVFILT_READ, EVFILT_WRITE,
    EV_ADD, EV_DELETE, EV_ENABLE, EV_CLEAR, EV_EOF, EV_ERROR,
)
from socket_reactor.interest import Token, Interest


# ── Event ────────────────────────────────────────────────────────────────────

@fieldwise_init
struct Event(TrivialRegisterPassable):
    """A single ready event returned from poll().

    Normalised bit field (_flags):
      bit 0 = readable
      bit 1 = writable
      bit 2 = read_closed  (peer sent FIN)
      bit 3 = write_closed (write half can no longer send)
      bit 4 = error
    """
    var _token: UInt64
    var _flags: UInt32

    def token(self) -> Token:
        return Token(self._token)

    def is_readable(self) -> Bool:
        return (self._flags & UInt32(0x1)) != 0

    def is_writable(self) -> Bool:
        return (self._flags & UInt32(0x2)) != 0

    def is_read_closed(self) -> Bool:
        return (self._flags & UInt32(0x4)) != 0

    def is_write_closed(self) -> Bool:
        return (self._flags & UInt32(0x8)) != 0

    def is_error(self) -> Bool:
        return (self._flags & UInt32(0x10)) != 0


# ── Events ───────────────────────────────────────────────────────────────────

struct Events(Movable):
    """Pre-allocated buffer of ready events for use with poll().

    Uses a raw byte buffer sized to the platform element size (12 bytes for
    epoll_event on Linux, 32 bytes for kevent on macOS) so that the element
    types do not need to share a common Mojo struct definition.
    """
    var _buf:   List[UInt8]
    var _count: Int
    var _cap:   Int

    def __init__(out self, capacity: Int):
        self._cap = capacity
        self._count = 0
        var element_size: Int
        comptime if CompilationTarget.is_linux():
            element_size = 12   # sizeof(epoll_event) packed
        else:
            element_size = 32   # sizeof(kevent)
        self._buf = List[UInt8](length=capacity * element_size, fill=0)

    def __init__(out self, *, deinit take: Self):
        self._buf   = take._buf^
        self._count = take._count
        self._cap   = take._cap

    def __len__(self) -> Int:
        return self._count

    def __getitem__(self, i: Int) raises -> Event:
        if i < 0 or i >= self._count:
            raise Error("Events index out of range: " + String(i))
        comptime if CompilationTarget.is_linux():
            return self._read_epoll_event(i)
        else:
            return self._read_kevent(i)

    def _read_epoll_event(self, i: Int) -> Event:
        # epoll_event layout: UInt32 events (4 bytes) + UInt64 data (8 bytes)
        # Packed: no padding between them on Linux x86-64.
        var base = i * 12
        var ptr = self._buf.unsafe_ptr()
        var events_ptr = (ptr + base).bitcast[UInt32]()
        var data_ptr   = (ptr + base + 4).bitcast[UInt64]()
        var ev = events_ptr[]
        var token_val = data_ptr[]
        var flags = UInt32(0)
        if (ev & EPOLLIN) != 0:
            flags |= UInt32(0x1)
        if (ev & EPOLLOUT) != 0:
            flags |= UInt32(0x2)
        if (ev & EPOLLRDHUP) != 0:
            flags |= UInt32(0x4)
        if (ev & (EPOLLERR | EPOLLHUP)) != 0:
            # HUP on write side
            flags |= UInt32(0x8)
        if (ev & EPOLLERR) != 0:
            flags |= UInt32(0x10)
        return Event(token_val, flags)

    def _read_kevent(self, i: Int) -> Event:
        # kevent layout (32 bytes):
        #   ident:  UInt64  (8)
        #   filter: Int16   (2)
        #   flags:  UInt16  (2)
        #   fflags: UInt32  (4)
        #   data:   Int64   (8)
        #   udata:  UInt64  (8)
        var base = i * 32
        var ptr = self._buf.unsafe_ptr()
        var filter_ptr = (ptr + base + 8).bitcast[Int16]()
        var kflags_ptr = (ptr + base + 10).bitcast[UInt16]()
        var udata_ptr  = (ptr + base + 24).bitcast[UInt64]()
        var filter = filter_ptr[]
        var kflags = kflags_ptr[]
        var token_val = udata_ptr[]
        var flags = UInt32(0)
        if filter == EVFILT_READ:
            flags |= UInt32(0x1)
            if (kflags & EV_EOF) != 0:
                flags |= UInt32(0x4)  # read_closed
        if filter == EVFILT_WRITE:
            flags |= UInt32(0x2)
            if (kflags & EV_EOF) != 0:
                flags |= UInt32(0x8)  # write_closed
        if (kflags & EV_ERROR) != 0:
            flags |= UInt32(0x10)
        return Event(token_val, flags)


# ── Poll ─────────────────────────────────────────────────────────────────────

struct Poll(Movable):
    """Owns an epoll fd (Linux) or kqueue fd (macOS).

    Create with Poll.create(). Register fds with poll.register(), call
    poll.poll() to wait for readiness events, then inspect Events.
    """
    var _fd: c_int

    def __init__(out self, fd: c_int):
        self._fd = fd

    def __init__(out self, *, deinit take: Self):
        self._fd = take._fd

    def __del__(deinit self):
        if self._fd >= 0:
            _ = external_call["close", c_int](self._fd)

    @staticmethod
    def create() raises -> Poll:
        """Create a new Poll instance (epoll on Linux, kqueue on macOS)."""
        var fd: c_int
        comptime if CompilationTarget.is_linux():
            fd = external_call["epoll_create1", c_int](EPOLL_CLOEXEC)
        else:
            fd = external_call["kqueue", c_int]()
        if fd < 0:
            raise Error("poll_create(): " + _errno_str())
        return Poll(fd)

    def register(self, fd: c_int, token: Token, interest: Interest) raises:
        """Register fd for the given interest. Token is returned in ready events."""
        comptime if CompilationTarget.is_linux():
            self._epoll_ctl_add(fd, token, interest)
        else:
            self._kevent_add(fd, token, interest)

    def reregister(self, fd: c_int, token: Token, interest: Interest) raises:
        """Update an existing registration."""
        comptime if CompilationTarget.is_linux():
            self._epoll_ctl_mod(fd, token, interest)
        else:
            # kqueue: re-add with EV_ADD (idempotent update)
            self._kevent_add(fd, token, interest)

    def deregister(self, fd: c_int) raises:
        """Remove fd from the watch set."""
        comptime if CompilationTarget.is_linux():
            self._epoll_ctl_del(fd)
        else:
            self._kevent_del(fd)

    def poll(self, mut events: Events, timeout_ms: Int) raises -> Int:
        """Block until events are ready or timeout_ms expires.

        timeout_ms=0: returns immediately.
        timeout_ms=-1: blocks indefinitely.
        Returns the count of ready events.
        """
        var count: c_int
        comptime if CompilationTarget.is_linux():
            count = external_call["epoll_wait", c_int](
                self._fd,
                events._buf.unsafe_ptr(),
                c_int(events._cap),
                c_int(timeout_ms),
            )
        else:
            if timeout_ms < 0:
                # kqueue with NULL timeout = block indefinitely
                count = external_call["kevent", c_int](
                    self._fd,
                    stack_allocation[1, UInt8](),   # no changes
                    c_int(0),
                    events._buf.unsafe_ptr(),
                    c_int(events._cap),
                    stack_allocation[1, UInt8](),   # NULL = block
                )
            else:
                # Build a timespec on the stack
                var ts_buf = stack_allocation[2, Int64]()
                ts_buf[0] = Int64(timeout_ms) // Int64(1000)
                ts_buf[1] = (Int64(timeout_ms) % Int64(1000)) * Int64(1_000_000)
                count = external_call["kevent", c_int](
                    self._fd,
                    stack_allocation[1, UInt8](),
                    c_int(0),
                    events._buf.unsafe_ptr(),
                    c_int(events._cap),
                    ts_buf.bitcast[UInt8](),
                )
        if count < 0:
            raise Error("poll(): " + _errno_str())
        events._count = Int(count)
        return Int(count)

    # ── Linux epoll helpers ──────────────────────────────────────────────────

    def _epoll_ctl_add(self, fd: c_int, token: Token, interest: Interest) raises:
        # Write a packed 12-byte epoll_event directly at byte offsets to avoid
        # any padding Mojo inserts between UInt32 and UInt64 in a struct.
        # Layout: [UInt32 events @ 0][UInt64 data/token @ 4]
        var buf = stack_allocation[12, UInt8]()
        var ev_flags = UInt32(0)
        if interest._wants_read():
            ev_flags |= EPOLLIN | EPOLLRDHUP
        if interest._wants_write():
            ev_flags |= EPOLLOUT
        ev_flags |= EPOLLERR | EPOLLHUP
        buf.bitcast[UInt32]()[] = ev_flags
        (buf + 4).bitcast[UInt64]()[] = token.value
        var ret = external_call["epoll_ctl", c_int](
            self._fd, EPOLL_CTL_ADD, fd, buf,
        )
        if ret < 0:
            raise Error("epoll_ctl(ADD, fd=" + String(Int(fd)) + "): " + _errno_str())

    def _epoll_ctl_mod(self, fd: c_int, token: Token, interest: Interest) raises:
        var buf = stack_allocation[12, UInt8]()
        var ev_flags = UInt32(0)
        if interest._wants_read():
            ev_flags |= EPOLLIN | EPOLLRDHUP
        if interest._wants_write():
            ev_flags |= EPOLLOUT
        ev_flags |= EPOLLERR | EPOLLHUP
        buf.bitcast[UInt32]()[] = ev_flags
        (buf + 4).bitcast[UInt64]()[] = token.value
        var ret = external_call["epoll_ctl", c_int](
            self._fd, EPOLL_CTL_MOD, fd, buf,
        )
        if ret < 0:
            raise Error("epoll_ctl(MOD, fd=" + String(Int(fd)) + "): " + _errno_str())

    def _epoll_ctl_del(self, fd: c_int) raises:
        # Kernel ignores the event pointer for EPOLL_CTL_DEL; pass any valid ptr.
        var buf = stack_allocation[12, UInt8]()
        var ret = external_call["epoll_ctl", c_int](
            self._fd, EPOLL_CTL_DEL, fd, buf,
        )
        if ret < 0:
            raise Error("epoll_ctl(DEL, fd=" + String(Int(fd)) + "): " + _errno_str())

    # ── macOS kqueue helpers ─────────────────────────────────────────────────

    def _kevent_add(self, fd: c_int, token: Token, interest: Interest) raises:
        # Submit changes one filter at a time via the changelist
        if interest._wants_read():
            var kev = _kevent(
                UInt64(fd), EVFILT_READ,
                EV_ADD | EV_ENABLE | EV_CLEAR,
                UInt32(0), Int64(0), token.value,
            )
            var kev_ptr = stack_allocation[1, _kevent]()
            kev_ptr[] = kev
            var ret = external_call["kevent", c_int](
                self._fd,
                kev_ptr,
                c_int(1),
                stack_allocation[1, _kevent](),  # no events output
                c_int(0),
                stack_allocation[1, UInt8](),    # NULL timeout (non-blocking change)
            )
            if ret < 0:
                raise Error("kevent(ADD READ, fd=" + String(Int(fd)) + "): " + _errno_str())
        if interest._wants_write():
            var kev = _kevent(
                UInt64(fd), EVFILT_WRITE,
                EV_ADD | EV_ENABLE | EV_CLEAR,
                UInt32(0), Int64(0), token.value,
            )
            var kev_ptr = stack_allocation[1, _kevent]()
            kev_ptr[] = kev
            var ret = external_call["kevent", c_int](
                self._fd,
                kev_ptr,
                c_int(1),
                stack_allocation[1, _kevent](),
                c_int(0),
                stack_allocation[1, UInt8](),
            )
            if ret < 0:
                raise Error("kevent(ADD WRITE, fd=" + String(Int(fd)) + "): " + _errno_str())

    def _kevent_del(self, fd: c_int) raises:
        # Delete both EVFILT_READ and EVFILT_WRITE; ignore ENOENT on each
        for filt in [EVFILT_READ, EVFILT_WRITE]:
            var kev = _kevent(
                UInt64(fd), filt, EV_DELETE,
                UInt32(0), Int64(0), UInt64(0),
            )
            var kev_ptr = stack_allocation[1, _kevent]()
            kev_ptr[] = kev
            _ = external_call["kevent", c_int](
                self._fd,
                kev_ptr,
                c_int(1),
                stack_allocation[1, _kevent](),
                c_int(0),
                stack_allocation[1, UInt8](),
            )
