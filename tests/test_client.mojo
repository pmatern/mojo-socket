# SPDX-License-Identifier: Apache-2.0
# tests/test_client.mojo — TcpStream: connect, peer_addr, resource release

from std.testing import assert_equal, assert_true, assert_raises

from socket import SocketAddress, TcpListener, TcpStream
from socket._libc import _fd_is_open


# ---------------------------------------------------------------------------
# TcpStream.connect tests
# ---------------------------------------------------------------------------

def test_connect_establishes_connection() raises:
    var listener = TcpListener.bind(SocketAddress("127.0.0.1", 0))
    # Extract port only (UInt16 is trivially copyable — avoids Mojo 0.26.x String SSO bug).
    var port = listener.local_addr().port
    var client = TcpStream.connect(SocketAddress("127.0.0.1", port))
    client.close()
    listener.close()


def test_peer_addr_returns_server_address() raises:
    var listener = TcpListener.bind(SocketAddress("127.0.0.1", 0))
    var port = listener.local_addr().port
    var client = TcpStream.connect(SocketAddress("127.0.0.1", port))
    var peer = client.peer_addr()
    assert_equal(peer.port, port)
    client.close()
    listener.close()


def test_local_addr_returns_local_endpoint() raises:
    var listener = TcpListener.bind(SocketAddress("127.0.0.1", 0))
    var port = listener.local_addr().port
    var client = TcpStream.connect(SocketAddress("127.0.0.1", port))
    var local = client.local_addr()
    assert_equal(local.ip, "127.0.0.1")
    assert_true(local.port > 0)
    client.close()
    listener.close()


def test_connect_refused_raises() raises:
    # Connect to a port with no listener — should raise ECONNREFUSED
    # Use port 1 which is reserved and not normally listening
    var raised = False
    try:
        var client = TcpStream.connect(SocketAddress("127.0.0.1", 1))
        client.close()
    except e:
        var msg = String(e)
        assert_true("ECONNREFUSED" in msg, "expected ECONNREFUSED in: " + msg)
        raised = True
    assert_true(raised, "expected connect to raise ECONNREFUSED")


def _capture_stream_fd() raises -> Int:
    var listener = TcpListener.bind(SocketAddress("127.0.0.1", 0))
    var port = listener.local_addr().port
    var client = TcpStream.connect(SocketAddress("127.0.0.1", port))
    var fd = Int(client._socket.fd)
    listener.close()
    return fd
    # client.__del__ called here


def test_stream_fd_released_on_drop() raises:
    var fd = _capture_stream_fd()
    assert_true(not _fd_is_open(fd))


def test_stream_close_idempotent() raises:
    var listener = TcpListener.bind(SocketAddress("127.0.0.1", 0))
    var port = listener.local_addr().port
    var client = TcpStream.connect(SocketAddress("127.0.0.1", port))
    client.close()
    client.close()  # second close must not crash
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
    print("=== test_client ===")
    _run_test("test_connect_establishes_connection", passed, failed, test_connect_establishes_connection)
    _run_test("test_peer_addr_returns_server_address", passed, failed, test_peer_addr_returns_server_address)
    _run_test("test_local_addr_returns_local_endpoint", passed, failed, test_local_addr_returns_local_endpoint)
    _run_test("test_connect_refused_raises", passed, failed, test_connect_refused_raises)
    _run_test("test_stream_fd_released_on_drop", passed, failed, test_stream_fd_released_on_drop)
    _run_test("test_stream_close_idempotent", passed, failed, test_stream_close_idempotent)
    print("")
    print("Results:", passed, "passed,", failed, "failed")
    if failed > 0:
        raise Error("test_client: " + String(failed) + " test(s) failed")
