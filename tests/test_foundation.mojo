from std.testing import assert_equal, assert_true, assert_raises

from socket import SocketAddress, Socket, AddressFamily, SocketType
from socket._libc import _fd_is_open


# ---------------------------------------------------------------------------
# SocketAddress validation tests
# ---------------------------------------------------------------------------

def test_socket_address_valid_ipv4() raises:
    var addr = SocketAddress("127.0.0.1", 8080)
    assert_equal(addr.ip, "127.0.0.1")
    assert_equal(addr.port, UInt16(8080))


def test_socket_address_valid_ipv6() raises:
    var addr = SocketAddress("::1", 8080)
    assert_equal(addr.ip, "::1")
    assert_equal(addr.port, UInt16(8080))


def test_socket_address_invalid_ip_raises() raises:
    with assert_raises():
        _ = SocketAddress("not-an-ip", 8080)


def test_socket_address_empty_raises() raises:
    with assert_raises():
        _ = SocketAddress("", 8080)


def test_socket_address_write_to_ipv4() raises:
    var addr = SocketAddress("127.0.0.1", 8080)
    assert_equal(String.write(addr), "127.0.0.1:8080")


def test_socket_address_write_to_ipv6() raises:
    var addr = SocketAddress("::1", 8080)
    assert_equal(String.write(addr), "[::1]:8080")


# ---------------------------------------------------------------------------
# Socket lifecycle tests
# ---------------------------------------------------------------------------

def test_socket_create_tcp_ipv4() raises:
    var sock = Socket(AddressFamily(2), SocketType(1))
    assert_true(sock.fd >= 0)


def test_socket_create_bad_family_raises() raises:
    with assert_raises():
        # AF=99 is invalid → EAFNOSUPPORT
        _ = Socket(AddressFamily(99), SocketType(1))


def test_socket_fd_negative_after_close() raises:
    var sock = Socket(AddressFamily(2), SocketType(1))
    sock.close()
    assert_equal(sock.fd, -1)


def test_socket_close_idempotent() raises:
    var sock = Socket(AddressFamily(2), SocketType(1))
    sock.close()
    sock.close()  # double close must not crash


def _capture_fd_then_drop() raises -> Int:
    var sock = Socket(AddressFamily(2), SocketType(1))
    var fd = Int(sock.fd)
    return fd
    # sock.__del__ called at end of this function


def test_socket_fd_not_leaked() raises:
    var fd = _capture_fd_then_drop()
    assert_true(not _fd_is_open(fd))


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
    print("=== test_foundation ===")
    _run_test("test_socket_address_valid_ipv4", passed, failed, test_socket_address_valid_ipv4)
    _run_test("test_socket_address_valid_ipv6", passed, failed, test_socket_address_valid_ipv6)
    _run_test("test_socket_address_invalid_ip_raises", passed, failed, test_socket_address_invalid_ip_raises)
    _run_test("test_socket_address_empty_raises", passed, failed, test_socket_address_empty_raises)
    _run_test("test_socket_address_write_to_ipv4", passed, failed, test_socket_address_write_to_ipv4)
    _run_test("test_socket_address_write_to_ipv6", passed, failed, test_socket_address_write_to_ipv6)
    _run_test("test_socket_create_tcp_ipv4", passed, failed, test_socket_create_tcp_ipv4)
    _run_test("test_socket_create_bad_family_raises", passed, failed, test_socket_create_bad_family_raises)
    _run_test("test_socket_fd_negative_after_close", passed, failed, test_socket_fd_negative_after_close)
    _run_test("test_socket_close_idempotent", passed, failed, test_socket_close_idempotent)
    _run_test("test_socket_fd_not_leaked", passed, failed, test_socket_fd_not_leaked)
    print("")
    print("Results:", passed, "passed,", failed, "failed")
    if failed > 0:
        raise Error("test_foundation: " + String(failed) + " test(s) failed")
