# SPDX-License-Identifier: Apache-2.0
from std.ffi import external_call, c_int, c_char, get_errno
from std.sys.info import CompilationTarget
from std.memory import stack_allocation, UnsafePointer
from socket._libc import _errno_name

# ── fcntl (F_GETFL to read flags; used only for verification) ──────────────
comptime F_GETFL: c_int = 3

# O_NONBLOCK differs per platform; used in tests to verify the flag was set
comptime O_NONBLOCK_LINUX: c_int = 0x800
comptime O_NONBLOCK_MACOS: c_int = 0x004

# ── ioctl FIONBIO (used to set O_NONBLOCK) ─────────────────────────────────
# Linux: c_int(0x5421), macOS: UInt(0x8004667e) - different types per platform
comptime FIONBIO_LINUX: c_int = 0x5421

# ── EINPROGRESS ─────────────────────────────────────────────────────────────
comptime EINPROGRESS_LINUX: c_int = 115
comptime EINPROGRESS_MACOS: c_int = 36

# ── EAGAIN / EWOULDBLOCK ────────────────────────────────────────────────────
comptime EAGAIN_LINUX: c_int     = 11
comptime EAGAIN_MACOS: c_int     = 35
comptime EWOULDBLOCK_LINUX: c_int = 11   # same as EAGAIN on Linux
comptime EWOULDBLOCK_MACOS: c_int = 35   # same as EAGAIN on macOS

# ── epoll (Linux) ───────────────────────────────────────────────────────────
comptime EPOLL_CLOEXEC: c_int  = 0x80000
comptime EPOLLIN:    UInt32    = 0x00000001
comptime EPOLLOUT:   UInt32    = 0x00000004
comptime EPOLLRDHUP: UInt32    = 0x00002000
comptime EPOLLERR:   UInt32    = 0x00000008
comptime EPOLLHUP:   UInt32    = 0x00000010
comptime EPOLL_CTL_ADD: c_int  = 1
comptime EPOLL_CTL_MOD: c_int  = 2
comptime EPOLL_CTL_DEL: c_int  = 3

# ── kqueue (macOS) ──────────────────────────────────────────────────────────
comptime EVFILT_READ:  Int16   = -1
comptime EVFILT_WRITE: Int16   = -2
comptime EV_ADD:    UInt16     = 0x0001
comptime EV_DELETE: UInt16     = 0x0002
comptime EV_ENABLE: UInt16     = 0x0004
comptime EV_DISABLE: UInt16    = 0x0008
comptime EV_CLEAR:  UInt16     = 0x0020
comptime EV_EOF:    UInt16     = 0x8000
comptime EV_ERROR:  UInt16     = 0x4000

# ── FFI structs ─────────────────────────────────────────────────────────────

@fieldwise_init
struct _epoll_event(Copyable, ImplicitlyCopyable):
    """12 bytes packed (Linux x86-64): uint32 events + uint64 data."""
    var events: UInt32
    var data:   UInt64


@fieldwise_init
struct _kevent(Copyable, ImplicitlyCopyable):
    """32 bytes (macOS): ident/filter/flags/fflags/data/udata."""
    var ident:  UInt64
    var filter: Int16
    var flags:  UInt16
    var fflags: UInt32
    var data:   Int64
    var udata:  UInt64


# ── architecture detection (Linux only) ─────────────────────────────────────

# Probe function disabled due to external_call arity conflicts with send/write.
# Use MOJO_SOCKET_ARCH environment variable instead to specify architecture.


def _is_linux_aarch64() -> Bool:
    """Detect if running on Linux ARM64 via environment variable.

    Returns True for ARM64 (16-byte struct), False for x86-64 (12-byte struct).

    Detection: Checks MOJO_LINUX_AARCH64 environment variable.
    - Set automatically by pixi for linux-aarch64 platform (see pixi.toml)
    - For manual builds on ARM64: export MOJO_LINUX_AARCH64=1
    - Defaults to False (x86-64) if not set
    """
    comptime if CompilationTarget.is_linux():
        # getenv returns 0 (NULL) if var not set, non-zero pointer if set
        var result = external_call["getenv", Int]("MOJO_LINUX_AARCH64\0".unsafe_ptr())
        return result != 0
    else:
        return False

# ── helpers ─────────────────────────────────────────────────────────────────

def _set_nonblocking(fd: c_int) raises:
    """Set O_NONBLOCK on fd using ioctl(FIONBIO).

    Uses ioctl rather than fcntl(F_SETFL) because fcntl with external_call
    doesn't work correctly on macOS (the 3-arg call succeeds but doesn't actually
    set the flag). On Linux, FIONBIO is c_int(0x5421); on macOS, it's UInt64(0x8004667e).

    NOTE: This function has a workaround for Mojo 0.26 compiler flakiness with
    stack_allocation inside comptime if branches. We allocate a static c_int buffer
    that persists across calls to avoid EFAULT errors.
    """
    # Static buffer workaround for Mojo compiler issue
    # Using a function-scoped static would be ideal, but Mojo doesn't support that yet
    # So we use a small heap-allocated buffer that leaks (4 bytes total, acceptable)
    var enable_val = c_int(1)
    var enable_ptr = stack_allocation[1, c_int]()
    enable_ptr[] = enable_val

    var ret: c_int
    comptime if CompilationTarget.is_linux():
        ret = external_call["ioctl", c_int](fd, FIONBIO_LINUX, enable_ptr)
    else:
        ret = external_call["ioctl", c_int](fd, UInt64(0x8004667e), enable_ptr)

    if ret < 0:
        var code = Int(get_errno().value)
        raise Error("ioctl(FIONBIO, fd=" + String(Int(fd)) + "): " + _errno_format(code))


def _errno_str() -> String:
    """Format current errno as 'errno N (NAME)' — call immediately after failed syscall."""
    var code = Int(get_errno().value)
    return "errno " + String(code) + " (" + _errno_name(code) + ")"


def _errno_format(code: Int) -> String:
    """Format a pre-read errno code as 'errno N (NAME)'."""
    return "errno " + String(code) + " (" + _errno_name(code) + ")"


def _is_eagain(errno_val: Int) -> Bool:
    """Return True if errno_val is EAGAIN or EWOULDBLOCK for this platform."""
    comptime if CompilationTarget.is_linux():
        return errno_val == Int(EAGAIN_LINUX)
    else:
        return errno_val == Int(EAGAIN_MACOS)


def _is_einprogress(errno_val: Int) -> Bool:
    """Return True if errno_val is EINPROGRESS for this platform."""
    comptime if CompilationTarget.is_linux():
        return errno_val == Int(EINPROGRESS_LINUX)
    else:
        return errno_val == Int(EINPROGRESS_MACOS)
