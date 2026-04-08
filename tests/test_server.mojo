# SPDX-License-Identifier: Apache-2.0
# tests/test_server.mojo — TcpListener: bind, accept, local_addr

from std.testing import assert_equal, assert_true, assert_raises

from socket import SocketAddress, TcpListener, TcpStream, AcceptResult
from socket._libc import _fd_is_open


# ---------------------------------------------------------------------------
# TcpListener tests
# ---------------------------------------------------------------------------

def test_bind_listen_no_error() raises:
    var listener = TcpListener.bind(SocketAddress("127.0.0.1", 0))
    listener.close()


def test_local_addr_returns_bound_address() raises:
    var listener = TcpListener.bind(SocketAddress("127.0.0.1", 0))
    var addr = listener.local_addr()
    assert_equal(addr.ip, "127.0.0.1")
    assert_true(addr.port > 0)
    listener.close()


def test_accept_returns_stream_and_peer() raises:
    var listener = TcpListener.bind(SocketAddress("127.0.0.1", 0))
    var port = listener.local_addr().port
    var client = TcpStream.connect(SocketAddress("127.0.0.1", port))
    var result = listener.accept()
    assert_equal(result.peer.ip, "127.0.0.1")
    result.stream.close()
    client.close()
    listener.close()


def test_bind_port_in_use_raises() raises:
    var listener = TcpListener.bind(SocketAddress("127.0.0.1", 0))
    # Extract port as an integer (UInt16 is trivially copyable — no SSO issues).
    # Use a literal IP for the second bind to avoid Mojo 0.26.x String SSO bug
    # where unsafe_ptr() becomes stale after struct moves through local_addr().
    var port = listener.local_addr().port
    var raised = False
    try:
        var listener2 = TcpListener.bind(SocketAddress("127.0.0.1", port))
        listener2.close()
    except e:
        var msg = String(e)
        assert_true("EADDRINUSE" in msg, "expected EADDRINUSE in: " + msg)
        assert_true(String(Int(port)) in msg, "expected port in: " + msg)
        raised = True
    assert_true(raised, "expected second bind to raise")
    listener.close()


def test_bind_already_bound_raises() raises:
    var listener = TcpListener.bind(SocketAddress("127.0.0.1", 0))
    # Try to bind the underlying socket a second time (to a fresh addr) — expect EINVAL
    var raised = False
    try:
        listener._socket.bind(SocketAddress("127.0.0.1", 0))
    except e:
        var msg = String(e)
        assert_true("EINVAL" in msg or "EADDRINUSE" in msg, "expected EINVAL/EADDRINUSE in: " + msg)
        raised = True
    assert_true(raised, "expected second bind to raise")
    listener.close()


def _capture_listener_fd() raises -> Int:
    var listener = TcpListener.bind(SocketAddress("127.0.0.1", 0))
    var fd = Int(listener._socket.fd)
    return fd
    # listener.__del__ called here


def test_listener_fd_released_on_drop() raises:
    var fd = _capture_listener_fd()
    assert_true(not _fd_is_open(fd))


def test_listener_operation_after_close_raises() raises:
    var listener = TcpListener.bind(SocketAddress("127.0.0.1", 0))
    listener.close()
    var raised = False
    try:
        var result = listener.accept()
        result.stream.close()
    except e:
        var msg = String(e)
        assert_true("EBADF" in msg, "expected EBADF in: " + msg)
        raised = True
    assert_true(raised, "expected accept after close to raise")


def test_bind_backlog_zero() raises:
    var listener = TcpListener.bind(SocketAddress("127.0.0.1", 0), backlog=0)
    listener.close()


# ---------------------------------------------------------------------------
# Test runner
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
    print("=== test_server ===")
    _run_test("test_bind_listen_no_error", passed, failed, test_bind_listen_no_error)
    _run_test("test_local_addr_returns_bound_address", passed, failed, test_local_addr_returns_bound_address)
    _run_test("test_accept_returns_stream_and_peer", passed, failed, test_accept_returns_stream_and_peer)
    _run_test("test_bind_port_in_use_raises", passed, failed, test_bind_port_in_use_raises)
    _run_test("test_bind_already_bound_raises", passed, failed, test_bind_already_bound_raises)
    _run_test("test_listener_fd_released_on_drop", passed, failed, test_listener_fd_released_on_drop)
    _run_test("test_listener_operation_after_close_raises", passed, failed, test_listener_operation_after_close_raises)
    _run_test("test_bind_backlog_zero", passed, failed, test_bind_backlog_zero)
    print("")
    print("Results:", passed, "passed,", failed, "failed")
    if failed > 0:
        raise Error("test_server: " + String(failed) + " test(s) failed")
