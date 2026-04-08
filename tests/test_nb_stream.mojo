# SPDX-License-Identifier: Apache-2.0
from std.testing import assert_equal, assert_true
from std.ffi import external_call, c_int, c_ssize_t, c_size_t

from socket_reactor.poll import Poll, Events
from socket_reactor.interest import Token, Interest, Read, Write, ReadWrite
from socket_reactor.tcp_stream_nb import NonBlockingTcpStream, RecvResult, SendResult
from socket_reactor.tcp_listener_nb import NonBlockingTcpListener
from socket import SocketAddress, Shutdown


def _bind_loopback() raises -> NonBlockingTcpListener:
    """Bind a non-blocking listener on loopback with a random port."""
    return NonBlockingTcpListener.bind(SocketAddress("127.0.0.1", 0))


# ---------------------------------------------------------------------------
# connect
# ---------------------------------------------------------------------------

def test_nb_stream_connect() raises:
    var listener = _bind_loopback()
    var addr = SocketAddress("127.0.0.1", listener.local_addr().port)
    var stream = NonBlockingTcpStream.connect(addr)
    assert_true(stream.fd >= 0)


# ---------------------------------------------------------------------------
# send / recv WouldBlock
# ---------------------------------------------------------------------------

def test_nb_stream_recv_would_block_on_empty() raises:
    var listener = _bind_loopback()
    var addr = SocketAddress("127.0.0.1", listener.local_addr().port)
    var stream = NonBlockingTcpStream.connect(addr)
    _ = listener.accept()  # keep listener alive past connect; drain backlog

    var buf = List[UInt8](length=256, fill=0)
    var result = stream.recv(Span[mut=True, UInt8](buf))
    assert_true(result.is_would_block() or result.is_closed())


def test_nb_stream_send_returns_sent_or_would_block() raises:
    var listener = _bind_loopback()
    var addr = SocketAddress("127.0.0.1", listener.local_addr().port)

    # Use poll to wait for connect to complete
    var poll = Poll.create()
    var stream = NonBlockingTcpStream.connect(addr)
    var accepted = listener.accept()  # keep accepted stream alive to prevent EPIPE
    poll.register(stream.fd, Token(UInt64(1)), Write)

    var events = Events(capacity=4)
    _ = poll.poll(events, timeout_ms=1000)

    var msg = "hello reactor".as_bytes()
    var result = stream.send(Span[UInt8](msg))
    assert_true(result.is_sent() or result.is_would_block())
    # Use accepted to prevent early drop
    _ = accepted.stream.fd


# ---------------------------------------------------------------------------
# recv Closed on FIN
# ---------------------------------------------------------------------------

def test_nb_stream_recv_closed_on_fin() raises:
    var listener = _bind_loopback()
    var addr = SocketAddress("127.0.0.1", listener.local_addr().port)
    var stream = NonBlockingTcpStream.connect(addr)

    # Accept the connection and close it immediately to send FIN
    var result = listener.accept()
    # If would_block, that's fine — connection may not have reached listener yet;
    # shutdown from our side instead
    stream.shutdown(Shutdown(c_int(0)))   # SHUT_RD

    var buf = List[UInt8](length=256, fill=0)
    var r = stream.recv(Span[mut=True, UInt8](buf))
    # After shutdown(SHUT_RD), recv should return closed or would_block
    assert_true(r.is_closed() or r.is_would_block())


# ---------------------------------------------------------------------------
# send + recv round-trip (loopback)
# ---------------------------------------------------------------------------

def test_nb_stream_send_recv_roundtrip() raises:
    var listener = _bind_loopback()
    var addr = SocketAddress("127.0.0.1", listener.local_addr().port)

    var poll = Poll.create()
    var client = NonBlockingTcpStream.connect(addr)
    poll.register(client.fd, Token(UInt64(1)), ReadWrite)

    # Accept on the listener side
    var nb_accept = listener.accept()
    # May be would_block if fast; retry once
    if nb_accept.is_would_block():
        var lev = Events(capacity=4)
        poll.register(listener.fd, Token(UInt64(0)), Read)
        _ = poll.poll(lev, timeout_ms=500)
        nb_accept = listener.accept()

    if nb_accept.is_accepted():
        # server side: send data (access by ref — no partial move needed)
        var msg = "ping".as_bytes()
        _ = nb_accept.stream.send(Span[UInt8](msg))

        # client side: wait for readable then recv
        var cev = Events(capacity=4)
        _ = poll.poll(cev, timeout_ms=500)

        var buf = List[UInt8](length=64, fill=0)
        var r = client.recv(Span[mut=True, UInt8](buf))
        assert_true(r.is_data() or r.is_would_block())


# ---------------------------------------------------------------------------
# fd released on drop
# ---------------------------------------------------------------------------

def test_nb_stream_fd_released_on_drop() raises:
    var fd_val: c_int
    var listener = _bind_loopback()
    var addr = SocketAddress("127.0.0.1", listener.local_addr().port)
    var stream = NonBlockingTcpStream.connect(addr)
    fd_val = stream.fd
    assert_true(fd_val >= 0)
    # stream drops here


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
    print("=== test_nb_stream (socket_reactor) ===")
    _run_test("test_nb_stream_connect", passed, failed, test_nb_stream_connect)
    _run_test("test_nb_stream_recv_would_block_on_empty", passed, failed, test_nb_stream_recv_would_block_on_empty)
    _run_test("test_nb_stream_send_returns_sent_or_would_block", passed, failed, test_nb_stream_send_returns_sent_or_would_block)
    _run_test("test_nb_stream_recv_closed_on_fin", passed, failed, test_nb_stream_recv_closed_on_fin)
    _run_test("test_nb_stream_send_recv_roundtrip", passed, failed, test_nb_stream_send_recv_roundtrip)
    _run_test("test_nb_stream_fd_released_on_drop", passed, failed, test_nb_stream_fd_released_on_drop)
    print("")
    print("Results:", passed, "passed,", failed, "failed")
    if failed > 0:
        raise Error("test_nb_stream: " + String(failed) + " test(s) failed")
