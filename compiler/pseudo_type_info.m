%---------------------------------------------------------------------------%
% vim: ft=mercury ts=4 sw=4 et
%---------------------------------------------------------------------------%
% Copyright (C) 1996-2000,2002-2003, 2005-2007 The University of Melbourne.
% This file may only be copied under the terms of the GNU General
% Public License - see the file COPYING in the Mercury distribution.
%---------------------------------------------------------------------------%
%
% File: psuedo_type_info.m.
% Authors: trd, zs.

% This module generates representations for pseudo-type-infos.

% The documentation of the structures of pseudo-type-infos is in
% runtime/mercury_type_info.h; that file also contains a list of all
% the files that depend on such data structures.

%---------------------------------------------------------------------------%

:- module backend_libs.pseudo_type_info.
:- interface.

:- import_module backend_libs.rtti.
:- import_module parse_tree.
:- import_module parse_tree.prog_data.

    % construct_pseudo_type_info(Type, NumUnivQTvars, ExistQVars,
    %   PseudoTypeInfo):
    %
    % Given a Mercury type (`Type'), this predicate returns a representation
    % of the pseudo type info for that type.
    %
    % NumUnivQTvars is either the number of universally quantified type
    % variables of the enclosing type (so that all universally quantified
    % variables in the type have numbers in the range [1..NumUnivQTvars],
    % or is the special value -1, meaning that all variables in the type
    % are universally quantified. ExistQVars is the list of existentially
    % quantified type variables of the constructor in question.
    %
:- pred construct_pseudo_type_info(mer_type::in, int::in, existq_tvars::in,
    rtti_pseudo_type_info::out) is det.

    % construct_type_info(Type, TypeInfo):
    %
    % Given a ground Mercury type (`Type'), this predicate returns a
    % representation of the type info for that type.
    %
:- pred construct_type_info(mer_type::in, rtti_type_info::out) is det.

    % construct_maybe_pseudo_type_info(Type, NumUnivQTvars, ExistQVars,
    %   MaybePseudoTypeInfo):
    %
    % Given a Mercury type (`Type'), this predicate checks whether it is
    % ground or not. If it is ground, it returns a typeinfo for it; if it
    % is not ground, it returns a pseudo type info for it. The arguments
    % are the same as for construct_pseudo_type_info.
    %
:- pred construct_maybe_pseudo_type_info(mer_type::in, int::in,
    existq_tvars::in, rtti_maybe_pseudo_type_info::out) is det.

%---------------------------------------------------------------------------%
%---------------------------------------------------------------------------%

:- implementation.

:- import_module libs.
:- import_module libs.compiler_util.
:- import_module mdbcomp.
:- import_module mdbcomp.prim_data.
:- import_module parse_tree.prog_type.
:- import_module parse_tree.prog_util.

:- import_module int.
:- import_module list.
:- import_module term.

%---------------------------------------------------------------------------%

construct_maybe_pseudo_type_info(Type, NumUnivQTvars, ExistQTvars,
        MaybePseudoTypeInfo) :-
    ( type_is_ground(Type) ->
        construct_type_info(Type, TypeInfo),
        MaybePseudoTypeInfo = plain(TypeInfo)
    ;
        construct_pseudo_type_info(Type, NumUnivQTvars, ExistQTvars,
            PseudoTypeInfo),
        MaybePseudoTypeInfo = pseudo(PseudoTypeInfo)
    ).

construct_pseudo_type_info(Type, NumUnivQTvars, ExistQTvars, PseudoTypeInfo) :-
    (
        ( Type = defined_type(_, _, _)
        ; Type = builtin_type(_)
        ; Type = tuple_type(_, _)
        ; Type = higher_order_type(_, _, _, _)
        ; Type = apply_n_type(_, _, _)
        ; Type = kinded_type(_, _)
        ),
        type_to_ctor_and_args_det(Type, TypeCtor, TypeArgs),
        ( type_is_var_arity(Type, VarArityId) ->
            TypeCtor = type_ctor(_QualTypeName, RealArity),
            generate_pseudo_args(TypeArgs, NumUnivQTvars, ExistQTvars,
                PseudoArgs),
            expect(check_var_arity(VarArityId, PseudoArgs, RealArity),
                this_file, "construct_pseudo_type_info: var arity mismatch"),
            PseudoTypeInfo = var_arity_pseudo_type_info(VarArityId, PseudoArgs)
        ;
            TypeCtor = type_ctor(QualTypeName, Arity),
            TypeName = unqualify_name(QualTypeName),
            sym_name_get_module_name(QualTypeName, unqualified("builtin"),
                TypeModule),
            RttiTypeCtor = rtti_type_ctor(TypeModule, TypeName, Arity),
            generate_pseudo_args(TypeArgs, NumUnivQTvars, ExistQTvars,
                PseudoArgs),
            expect(check_arity(PseudoArgs, Arity), this_file,
                "construct_pseudo_type_info: arity mismatch"),
            (
                PseudoArgs = [],
                PseudoTypeInfo =
                    plain_arity_zero_pseudo_type_info(RttiTypeCtor)
            ;
                PseudoArgs = [_ | _],
                PseudoTypeInfo =
                    plain_pseudo_type_info(RttiTypeCtor, PseudoArgs)
            )
        )
    ;
        Type = type_variable(Var, _),
        % In the case of a type variable, we need to assign a
        % variable number *for this constructor*, i.e. taking
        % only the existentially quantified variables of
        % this constructor (and not those of other functors in
        % the same type) into account.

        % XXX term.var_to_int doesn't guarantee anything about the
        % ints returned (other than that they be distinct for
        % different variables), but here we are relying more,
        % specifically, on the integers being allocated densely
        % (i.e. the first N vars get integers 1 to N).

        term.var_to_int(Var, VarInt0),
        (
            ( VarInt0 =< NumUnivQTvars
            ; NumUnivQTvars < 0
            )
        ->
            % This is a universally quantified variable.
            VarInt = VarInt0
        ;
            % This is an existentially quantified variable.
            ( list.nth_member_search(ExistQTvars, Var, ExistNum0) ->
                VarInt = ExistNum0 + pseudo_typeinfo_exist_var_base
            ;
                unexpected(this_file,
                    "construct_pseudo_type_info: not in list")
            )
        ),
        expect(VarInt =< pseudo_typeinfo_max_var, this_file,
            "construct_pseudo_type_info: type var exceeds limit"),
        PseudoTypeInfo = type_var(VarInt)
    ).

construct_type_info(Type, TypeInfo) :-
    ( type_to_ctor_and_args(Type, TypeCtor, TypeArgs) ->
        ( type_is_var_arity(Type, VarArityId) ->
            TypeCtor = type_ctor(_QualTypeName, RealArity),
            generate_plain_args(TypeArgs, TypeInfoArgs),
            expect(check_var_arity(VarArityId, TypeInfoArgs, RealArity),
                this_file, "construct_type_info: arity mismatch"),
            TypeInfo = var_arity_type_info(VarArityId, TypeInfoArgs)
        ;
            TypeCtor = type_ctor(QualTypeName, Arity),
            TypeName = unqualify_name(QualTypeName),
            sym_name_get_module_name(QualTypeName, unqualified("builtin"),
                TypeModule),
            RttiTypeCtor = rtti_type_ctor(TypeModule, TypeName, Arity),
            generate_plain_args(TypeArgs, TypeInfoArgs),
            expect(check_arity(TypeInfoArgs, Arity),
                this_file, "construct_type_info: arity mismatch"),
            (
                TypeInfoArgs = [],
                TypeInfo = plain_arity_zero_type_info(RttiTypeCtor)
            ;
                TypeInfoArgs = [_ | _],
                TypeInfo = plain_type_info(RttiTypeCtor, TypeInfoArgs)
            )
        )
    ;
        unexpected(this_file, "construct_type_info: type is var")
    ).

:- pred check_var_arity(var_arity_ctor_id::in, list(T)::in, int::in)
    is semidet.

check_var_arity(VarArityId, Args, RealArity) :-
    list.length(Args, NumPseudoArgs),
    (
        VarArityId = func_type_info,
        NumPseudoArgs = RealArity + 1
    ;
        ( VarArityId = pred_type_info
        ; VarArityId = tuple_type_info
        ),
        NumPseudoArgs = RealArity
    ).

:- pred check_arity(list(T)::in, int::in) is semidet.

check_arity(Args, RealArity) :-
    list.length(Args, NumPseudoArgs),
    NumPseudoArgs = RealArity.

:- pred generate_pseudo_args(list(mer_type)::in, int::in, existq_tvars::in,
    list(rtti_maybe_pseudo_type_info)::out) is det.

generate_pseudo_args(TypeArgs, NumUnivQTvars, ExistQTvars, PseudoArgs) :-
    list.map(generate_pseudo_arg(NumUnivQTvars, ExistQTvars),
        TypeArgs, PseudoArgs).

:- pred generate_pseudo_arg(int::in, existq_tvars::in, mer_type::in,
    rtti_maybe_pseudo_type_info::out) is det.

generate_pseudo_arg(NumUnivQTvars, ExistQTvars, TypeArg, MaybePseudoArg) :-
    ( type_is_ground(TypeArg) ->
        construct_type_info(TypeArg, PseudoArg),
        MaybePseudoArg = plain(PseudoArg)
    ;
        construct_pseudo_type_info(TypeArg, NumUnivQTvars, ExistQTvars,
            PseudoArg),
        MaybePseudoArg = pseudo(PseudoArg)
    ).

:- pred generate_plain_args(list(mer_type)::in, list(rtti_type_info)::out)
    is det.

generate_plain_args(TypeArgs, PseudoArgs) :-
    list.map(construct_type_info, TypeArgs, PseudoArgs).

%---------------------------------------------------------------------------%

    % Type_infos and pseudo_type_infos whose principal type constructor
    % is a variable arity type constructor must be handled specially, in that
    % they must include the actual arity of the given instance between the
    % type constructor and the arguments. runtime/mercury_type_info.h has
    % the details.
    %
    % All variable arity type constructors are builtins. At the moment,
    % we have three: pred, func, and tuple.
    % XXX FIXME we should also encode purity in the RTTI!
    %
:- pred type_is_var_arity(mer_type::in, var_arity_ctor_id::out) is semidet.

type_is_var_arity(Type, VarArityCtorId) :-
    ( type_is_higher_order_details(Type, _Purity, PredOrFunc, _, _) ->
        (
            PredOrFunc = pf_predicate,
            VarArityCtorId = pred_type_info
        ;
            PredOrFunc = pf_function,
            VarArityCtorId = func_type_info
        )
    ; type_is_tuple(Type, _) ->
        VarArityCtorId = tuple_type_info
    ;
        fail
    ).

%---------------------------------------------------------------------------%

    % This number corresponds to MR_PSEUDOTYPEINFO_MAX_VAR in
    % runtime/mercury_type_info.h, and must be kept in sync with it.
    % The documentation is located there as well.
    %
:- func pseudo_typeinfo_max_var = int.

pseudo_typeinfo_max_var = 1024.

    % This number corresponds to MR_PSEUDOTYPEINFO_EXIST_VAR_BASE in
    % runtime/mercury_type_info.h, and must be kept in sync with it.
    % The documentation is located there as well.
    %
:- func pseudo_typeinfo_exist_var_base = int.

pseudo_typeinfo_exist_var_base = 512.

%---------------------------------------------------------------------------%

:- func this_file = string.

this_file = "pseudo_type_info.m".

%---------------------------------------------------------------------------%
