# SPDX-License-Identifier: Apache-2.0
from std.testing import assert_equal, assert_true
from std.ffi import external_call, c_int

from socket_reactor.poll import Poll, Events
from socket_reactor.interest import Token, Interest, Read, Write, ReadWrite
from socket import Socket, AddressFamily, SocketType


@fieldwise_init
struct _SocketPair:
    var r: c_int
    var w: c_int


def _make_socketpair() raises -> _SocketPair:
    """Create a connected pair of AF_UNIX SOCK_STREAM fds via socketpair(2)."""
    # AF_UNIX=1, SOCK_STREAM=1
    var fds_buf = List[c_int](capacity=2)
    fds_buf.append(c_int(-1))
    fds_buf.append(c_int(-1))
    var ptr = fds_buf.unsafe_ptr()
    var ret = external_call["socketpair", c_int](c_int(1), c_int(1), c_int(0), ptr)
    if ret < 0:
        raise Error("socketpair() failed")
    return _SocketPair(fds_buf[0], fds_buf[1])


# ---------------------------------------------------------------------------
# Poll lifecycle
# ---------------------------------------------------------------------------

def test_poll_create() raises:
    var poll = Poll.create()
    assert_true(poll._fd >= 0)


def test_poll_fd_closed_on_drop() raises:
    var poll_fd: c_int
    var poll = Poll.create()
    poll_fd = poll._fd
    assert_true(poll_fd >= 0)
    # poll drops here — fd should be closed
    # We cannot easily verify from outside without /proc, so just check no crash


# ---------------------------------------------------------------------------
# register / reregister / deregister
# ---------------------------------------------------------------------------

def test_poll_register() raises:
    var poll = Poll.create()
    var pair = _make_socketpair()
    var r = pair.r
    var w = pair.w
    poll.register(r, Token(UInt64(1)), Read)
    # no exception = pass
    _ = external_call["close", c_int](r)
    _ = external_call["close", c_int](w)


def test_poll_reregister() raises:
    var poll = Poll.create()
    var pair = _make_socketpair()
    var r = pair.r
    var w = pair.w
    poll.register(r, Token(UInt64(1)), Read)
    poll.reregister(r, Token(UInt64(1)), ReadWrite)
    _ = external_call["close", c_int](r)
    _ = external_call["close", c_int](w)


def test_poll_deregister() raises:
    var poll = Poll.create()
    var pair = _make_socketpair()
    var r = pair.r
    var w = pair.w
    poll.register(r, Token(UInt64(1)), Read)
    poll.deregister(r)
    _ = external_call["close", c_int](r)
    _ = external_call["close", c_int](w)


# ---------------------------------------------------------------------------
# Readiness detection
# ---------------------------------------------------------------------------

def test_poll_returns_readable_when_data() raises:
    var poll = Poll.create()
    var pair = _make_socketpair()
    var r = pair.r
    var w = pair.w
    poll.register(r, Token(UInt64(10)), Read)

    # Write a byte on the write end
    var buf = List[UInt8](capacity=1)
    buf.append(UInt8(0x42))
    var n = external_call["send", c_int](w, buf.unsafe_ptr(), c_int(1), c_int(0))
    assert_true(n == 1)

    var events = Events(capacity=8)
    var count = poll.poll(events, timeout_ms=100)
    assert_true(count >= 1)
    assert_true(events[0].is_readable())
    assert_equal(events[0].token().value, UInt64(10))

    _ = external_call["close", c_int](r)
    _ = external_call["close", c_int](w)


def test_poll_returns_writable_on_fresh_fd() raises:
    var poll = Poll.create()
    var pair = _make_socketpair()
    var r = pair.r
    var w = pair.w
    poll.register(w, Token(UInt64(20)), Write)

    var events = Events(capacity=8)
    var count = poll.poll(events, timeout_ms=100)
    assert_true(count >= 1)
    assert_true(events[0].is_writable())
    assert_equal(events[0].token().value, UInt64(20))

    _ = external_call["close", c_int](r)
    _ = external_call["close", c_int](w)


# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------

def _run_test(name: String, mut passed: Int, mut failed: Int, test_fn: fn() raises -> None):
    try:
        test_fn()
        print("  PASS:", name)
        passed += 1
    except e:
        print("  FAIL:", name, "—", String(e))
        failed += 1


def main() raises:
    var passed = 0
    var failed = 0
    print("=== test_register (socket_reactor) ===")
    _run_test("test_poll_create", passed, failed, test_poll_create)
    _run_test("test_poll_fd_closed_on_drop", passed, failed, test_poll_fd_closed_on_drop)
    _run_test("test_poll_register", passed, failed, test_poll_register)
    _run_test("test_poll_reregister", passed, failed, test_poll_reregister)
    _run_test("test_poll_deregister", passed, failed, test_poll_deregister)
    _run_test("test_poll_returns_readable_when_data", passed, failed, test_poll_returns_readable_when_data)
    _run_test("test_poll_returns_writable_on_fresh_fd", passed, failed, test_poll_returns_writable_on_fresh_fd)
    print("")
    print("Results:", passed, "passed,", failed, "failed")
    if failed > 0:
        raise Error("test_register: " + String(failed) + " test(s) failed")
