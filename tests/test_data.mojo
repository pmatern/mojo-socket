# SPDX-License-Identifier: Apache-2.0
# tests/test_data.mojo — TcpStream: send, recv, shutdown

from std.testing import assert_equal, assert_true

from socket import SocketAddress, TcpListener, TcpStream, AcceptResult, Shutdown
from socket.address import Read as ShutdownRead, Write as ShutdownWrite, Both as ShutdownBoth
from socket._libc import _fd_is_open


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _connect_pair() raises -> AcceptResult:
    """Returns AcceptResult(.stream=server, .peer=client_addr) + sets up listener.

    NOTE: Returns server side in .stream. Caller owns a separate client.
    Use _connect_pair_full for both sides.
    """
    var listener = TcpListener.bind(SocketAddress("127.0.0.1", 0))
    var port = listener.local_addr().port
    var client = TcpStream.connect(SocketAddress("127.0.0.1", port))
    var result = listener.accept()
    listener.close()
    # We need to return both client and server — use AcceptResult for server,
    # but we also need the client. Caller pattern: connect_pair manually.
    client.close()
    return result^


# ---------------------------------------------------------------------------
# send/recv tests
# ---------------------------------------------------------------------------

def test_echo_bytes_match() raises:
    var listener = TcpListener.bind(SocketAddress("127.0.0.1", 0))
    var port = listener.local_addr().port
    var client = TcpStream.connect(SocketAddress("127.0.0.1", port))
    var result = listener.accept()
    listener.close()

    var payload = "hello, socket".as_bytes()
    var n_sent = client.send(Span(payload))
    assert_true(n_sent > 0)

    var buf = List[Byte](length=64, fill=0)
    var n_recv = result.stream.recv(Span[mut=True, Byte](buf))
    assert_equal(n_recv, n_sent)
    for i in range(n_recv):
        assert_equal(buf[i], payload[i])

    client.close()
    result.stream.close()


def test_send_returns_byte_count() raises:
    var listener = TcpListener.bind(SocketAddress("127.0.0.1", 0))
    var port = listener.local_addr().port
    var client = TcpStream.connect(SocketAddress("127.0.0.1", port))
    var result = listener.accept()
    listener.close()

    var payload = "hello".as_bytes()
    var n = client.send(Span(payload))
    assert_true(n > 0)
    assert_true(n <= len(payload))

    client.close()
    result.stream.close()


def test_send_empty_buffer() raises:
    var listener = TcpListener.bind(SocketAddress("127.0.0.1", 0))
    var port = listener.local_addr().port
    var client = TcpStream.connect(SocketAddress("127.0.0.1", port))
    var result = listener.accept()
    listener.close()

    var empty = List[Byte]()
    var n = client.send(Span(empty))
    assert_equal(n, 0)

    client.close()
    result.stream.close()


def test_recv_after_peer_close_raises() raises:
    var listener = TcpListener.bind(SocketAddress("127.0.0.1", 0))
    var port = listener.local_addr().port
    var client = TcpStream.connect(SocketAddress("127.0.0.1", port))
    var result = listener.accept()
    listener.close()

    # Close the server side to simulate peer death, then send from client
    result.stream.close()

    var raised = False
    # First send may succeed (kernel buffer), second should fail
    var payload = "data".as_bytes()
    try:
        _ = client.send(Span(payload))
        _ = client.send(Span(payload))
    except e:
        var msg = String(e)
        assert_true(
            "EPIPE" in msg or "ECONNRESET" in msg,
            "expected EPIPE/ECONNRESET in: " + msg,
        )
        raised = True
    assert_true(raised, "expected send to raise after peer close")
    client.close()


def test_no_fd_leaks_after_echo() raises:
    var listener = TcpListener.bind(SocketAddress("127.0.0.1", 0))
    var port = listener.local_addr().port
    var client = TcpStream.connect(SocketAddress("127.0.0.1", port))
    var result = listener.accept()
    listener.close()

    var client_fd = Int(client._socket.fd)
    var server_fd = Int(result.stream._socket.fd)
    client.close()
    result.stream.close()
    assert_true(not _fd_is_open(client_fd))
    assert_true(not _fd_is_open(server_fd))


# ---------------------------------------------------------------------------
# shutdown tests
# ---------------------------------------------------------------------------

def test_recv_zero_on_peer_close() raises:
    var listener = TcpListener.bind(SocketAddress("127.0.0.1", 0))
    var port = listener.local_addr().port
    var client = TcpStream.connect(SocketAddress("127.0.0.1", port))
    var result = listener.accept()
    listener.close()

    # client shuts down write → server's recv returns 0 (EOF)
    client.shutdown(ShutdownWrite)
    var buf = List[Byte](length=64, fill=0)
    var n = result.stream.recv(Span[mut=True, Byte](buf))
    assert_equal(n, 0)

    client.close()
    result.stream.close()


def test_shutdown_write_signals_eof() raises:
    var listener = TcpListener.bind(SocketAddress("127.0.0.1", 0))
    var port = listener.local_addr().port
    var client = TcpStream.connect(SocketAddress("127.0.0.1", port))
    var result = listener.accept()
    listener.close()

    result.stream.shutdown(ShutdownWrite)
    var buf = List[Byte](length=64, fill=0)
    var n = client.recv(Span[mut=True, Byte](buf))
    assert_equal(n, 0)

    client.close()
    result.stream.close()


def test_shutdown_read() raises:
    var listener = TcpListener.bind(SocketAddress("127.0.0.1", 0))
    var port = listener.local_addr().port
    var client = TcpStream.connect(SocketAddress("127.0.0.1", port))
    var result = listener.accept()
    listener.close()

    client.shutdown(ShutdownRead)
    client.close()
    result.stream.close()


def test_shutdown_both() raises:
    var listener = TcpListener.bind(SocketAddress("127.0.0.1", 0))
    var port = listener.local_addr().port
    var client = TcpStream.connect(SocketAddress("127.0.0.1", port))
    var result = listener.accept()
    listener.close()

    client.shutdown(ShutdownBoth)
    client.close()
    result.stream.close()


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
    print("=== test_data ===")
    _run_test("test_echo_bytes_match", passed, failed, test_echo_bytes_match)
    _run_test("test_send_returns_byte_count", passed, failed, test_send_returns_byte_count)
    _run_test("test_send_empty_buffer", passed, failed, test_send_empty_buffer)
    _run_test("test_recv_after_peer_close_raises", passed, failed, test_recv_after_peer_close_raises)
    _run_test("test_no_fd_leaks_after_echo", passed, failed, test_no_fd_leaks_after_echo)
    _run_test("test_recv_zero_on_peer_close", passed, failed, test_recv_zero_on_peer_close)
    _run_test("test_shutdown_write_signals_eof", passed, failed, test_shutdown_write_signals_eof)
    _run_test("test_shutdown_read", passed, failed, test_shutdown_read)
    _run_test("test_shutdown_both", passed, failed, test_shutdown_both)
    print("")
    print("Results:", passed, "passed,", failed, "failed")
    if failed > 0:
        raise Error("test_data: " + String(failed) + " test(s) failed")
