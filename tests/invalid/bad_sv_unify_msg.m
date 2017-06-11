%---------------------------------------------------------------------------%
% vim: ts=4 sw=4 et ft=mercury
%---------------------------------------------------------------------------%
%
% rotd-2007-10-19 and before emitted the wrong the variable name in the
% error message about !D appearing on the LHS of a unification. The problem
% was that transform_goal was not applying the variable renaming to the
% unification before looking up the variable name.

:- module bad_sv_unify_msg.
:- interface.

:- import_module io.

:- pred x(io::di, io::uo) is det.

:- implementation.

x(!IO) :-
    some [!D] (
        !D = 3, % Error message for this referred to the wrong variable.
        io.write(!.D, !IO)
    ).
