# SPDX-License-Identifier: Apache-2.0
from std.testing import assert_equal, assert_true
from std.ffi import external_call, c_int

from socket_reactor.poll import Poll, Events
from socket_reactor.interest import Token, Interest, Read, Write, ReadWrite
from socket_reactor.tcp_listener_nb import NonBlockingTcpListener, NbAcceptResult
from socket_reactor.tcp_stream_nb import NonBlockingTcpStream
from socket import SocketAddress


# ---------------------------------------------------------------------------
# bind
# ---------------------------------------------------------------------------

def test_nb_listener_bind() raises:
    var listener = NonBlockingTcpListener.bind(SocketAddress("127.0.0.1", 0))
    assert_true(listener.fd >= 0)
    var addr = listener.local_addr()
    assert_equal(addr.ip, "127.0.0.1")
    assert_true(addr.port > UInt16(0))


# ---------------------------------------------------------------------------
# accept returns WouldBlock with no clients
# ---------------------------------------------------------------------------

def test_nb_listener_accept_would_block() raises:
    var listener = NonBlockingTcpListener.bind(SocketAddress("127.0.0.1", 0))
    var result = listener.accept()
    assert_true(result.is_would_block())


# ---------------------------------------------------------------------------
# accept returns Accepted with a client
# ---------------------------------------------------------------------------

def test_nb_listener_accept_accepted() raises:
    var listener = NonBlockingTcpListener.bind(SocketAddress("127.0.0.1", 0))
    var addr = SocketAddress("127.0.0.1", listener.local_addr().port)

    # Register listener with poll so we can wait for a connection
    var poll = Poll.create()
    poll.register(listener.fd, Token(UInt64(0)), Read)

    # Initiate a connection
    var client = NonBlockingTcpStream.connect(addr)

    # Wait for listener to become readable (connection pending)
    var events = Events(capacity=4)
    _ = poll.poll(events, timeout_ms=1000)

    var result = listener.accept()
    assert_true(result.is_accepted())
    assert_equal(result.peer.ip, "127.0.0.1")
    assert_true(result.stream.fd >= 0)


# ---------------------------------------------------------------------------
# fd access
# ---------------------------------------------------------------------------

def test_nb_listener_fd_access() raises:
    var listener = NonBlockingTcpListener.bind(SocketAddress("127.0.0.1", 0))
    var fd = listener.fd
    assert_true(fd >= 0)


# ---------------------------------------------------------------------------
# close idempotent
# ---------------------------------------------------------------------------

def test_nb_listener_close_idempotent() raises:
    var listener = NonBlockingTcpListener.bind(SocketAddress("127.0.0.1", 0))
    listener.close()
    listener.close()  # second close must not crash


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
    print("=== test_nb_listener (socket_reactor) ===")
    _run_test("test_nb_listener_bind", passed, failed, test_nb_listener_bind)
    _run_test("test_nb_listener_accept_would_block", passed, failed, test_nb_listener_accept_would_block)
    _run_test("test_nb_listener_accept_accepted", passed, failed, test_nb_listener_accept_accepted)
    _run_test("test_nb_listener_fd_access", passed, failed, test_nb_listener_fd_access)
    _run_test("test_nb_listener_close_idempotent", passed, failed, test_nb_listener_close_idempotent)
    print("")
    print("Results:", passed, "passed,", failed, "failed")
    if failed > 0:
        raise Error("test_nb_listener: " + String(failed) + " test(s) failed")
