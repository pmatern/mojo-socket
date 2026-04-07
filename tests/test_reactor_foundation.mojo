# SPDX-License-Identifier: Apache-2.0
from std.testing import assert_equal, assert_true
from std.ffi import external_call, c_int
from std.sys.info import CompilationTarget

from socket_reactor.interest import Token, Interest, Read, Write, ReadWrite
from socket_reactor._libc import (
    _epoll_event, _kevent, _set_nonblocking,
    O_NONBLOCK_LINUX, O_NONBLOCK_MACOS, F_GETFL,
)
from socket import Socket, AddressFamily, SocketType


# ---------------------------------------------------------------------------
# Token tests
# ---------------------------------------------------------------------------

def test_token_equality() raises:
    var a = Token(UInt64(42))
    var b = Token(UInt64(42))
    var c = Token(UInt64(99))
    assert_true(a == b)
    assert_true(a != c)


def test_token_value() raises:
    var t = Token(UInt64(1337))
    assert_equal(t.value, UInt64(1337))


# ---------------------------------------------------------------------------
# Interest tests
# ---------------------------------------------------------------------------

def test_interest_read_flag() raises:
    assert_true(Read._wants_read())
    assert_true(not Read._wants_write())


def test_interest_write_flag() raises:
    assert_true(not Write._wants_read())
    assert_true(Write._wants_write())


def test_interest_readwrite_flag() raises:
    assert_true(ReadWrite._wants_read())
    assert_true(ReadWrite._wants_write())


# ---------------------------------------------------------------------------
# _set_nonblocking test
# ---------------------------------------------------------------------------

def test_set_nonblocking() raises:
    # Create a real socket fd, set nonblocking, verify via F_GETFL
    var sock = Socket(AddressFamily(2), SocketType(1))
    _set_nonblocking(sock.fd)
    var flags = external_call["fcntl", c_int](sock.fd, F_GETFL)
    comptime if CompilationTarget.is_linux():
        assert_true((flags & O_NONBLOCK_LINUX) != 0)
    else:
        assert_true((flags & O_NONBLOCK_MACOS) != 0)


# ---------------------------------------------------------------------------
# _run_test helper
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
    print("=== test_foundation (socket_reactor) ===")
    _run_test("test_token_equality", passed, failed, test_token_equality)
    _run_test("test_token_value", passed, failed, test_token_value)
    _run_test("test_interest_read_flag", passed, failed, test_interest_read_flag)
    _run_test("test_interest_write_flag", passed, failed, test_interest_write_flag)
    _run_test("test_interest_readwrite_flag", passed, failed, test_interest_readwrite_flag)
    _run_test("test_set_nonblocking", passed, failed, test_set_nonblocking)
    print("")
    print("Results:", passed, "passed,", failed, "failed")
    if failed > 0:
        raise Error("test_foundation: " + String(failed) + " test(s) failed")
