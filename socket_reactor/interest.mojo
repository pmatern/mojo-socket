# SPDX-License-Identifier: Apache-2.0

@fieldwise_init
struct Token(TrivialRegisterPassable, Equatable):
    """User-assigned identifier for a registered fd.

    Carried through poll() back to the caller so the event loop can
    dispatch to the correct handler.
    """
    var value: UInt64

    def __eq__(self, other: Self) -> Bool:
        return self.value == other.value

    def __ne__(self, other: Self) -> Bool:
        return self.value != other.value


@fieldwise_init
struct Interest(TrivialRegisterPassable):
    """Which events to watch for on a registered fd.

    Use the module-level constants Read, Write, or ReadWrite — do not
    construct Interest directly.
    """
    var _flags: UInt8

    def _wants_read(self) -> Bool:
        return (self._flags & UInt8(0b01)) != 0

    def _wants_write(self) -> Bool:
        return (self._flags & UInt8(0b10)) != 0


comptime Read:      Interest = Interest(UInt8(0b01))
comptime Write:     Interest = Interest(UInt8(0b10))
comptime ReadWrite: Interest = Interest(UInt8(0b11))
