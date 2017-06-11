%---------------------------------------------------------------------------%
% vim: ts=4 sw=4 et ft=mercury
%---------------------------------------------------------------------------%

:- module ground_constraint_2.
:- interface.
:- import_module io.

:- pred main(io::di, io::uo) is det.

:- implementation.

main -->
    { S1 = f(0) },
    io__write_string(S1),
    io__nl.

:- typeclass foo(T) where [
    func s(T) = string
].

:- instance foo(int) where [
    (s(_) = "bar")
].

:- func f(int) = string <= foo(int).

f(N) = s(N).
