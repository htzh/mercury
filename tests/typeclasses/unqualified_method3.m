%---------------------------------------------------------------------------%
% vim: ts=4 sw=4 et ft=mercury
%---------------------------------------------------------------------------%

:- module unqualified_method3.

:- interface.

:- import_module io.

:- pred print_modified_int(int::in, io::di, io::uo) is det.

:- implementation.

print_modified_int(_) -->
    io__write_string("This is the right method.\n").
