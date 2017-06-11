%---------------------------------------------------------------------------%
% vim: ts=4 sw=4 et ft=mercury
%---------------------------------------------------------------------------%

:- module invalid_int.
:- interface.

:- import_module io.

:- pred main(io::di, io::uo) is det.

:- implementation.

main(!IO) :-
    X = {
        0b11111111111111111111111111111111,
        0b100000000000000000000000000000000,
        0b1111111111111111111111111111111111111111111111111111111111111111,
        0b10000000000000000000000000000000000000000000000000000000000000000,

        0o37777777777,
        0o40000000000,
        0o1777777777777777777777,
        0o2000000000000000000000,

        0xffffffff,
        0x100000000,
        0x110000000,
        0xffffffffffffffff,
        0x10000000000000000,

        2147483647,
        2147483648,
        9223372036854775807,
        9223372036854775808
    },
    io.write(X, !IO).
