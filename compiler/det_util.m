%-----------------------------------------------------------------------------%
% vim: ft=mercury ts=4 sw=4 et
%-----------------------------------------------------------------------------%
% Copyright (C) 1996-2000,2002-2012 The University of Melbourne.
% This file may only be copied under the terms of the GNU General
% Public License - see the file COPYING in the Mercury distribution.
%-----------------------------------------------------------------------------%
%
% File: det_util.m.
% Main authors: fjh, zs.
%
% Utility predicates used in two or more of the modules concerned with
% determinism: switch_detection, cse_detection, det_analysis, det_report
% and simplify.
%
%-----------------------------------------------------------------------------%

:- module check_hlds.det_util.
:- interface.

:- import_module hlds.
:- import_module hlds.hlds_data.
:- import_module hlds.hlds_goal.
:- import_module hlds.hlds_module.
:- import_module hlds.hlds_pred.
:- import_module hlds.instmap.
:- import_module hlds.vartypes.
:- import_module parse_tree.
:- import_module parse_tree.error_util.
:- import_module parse_tree.prog_data.
:- import_module parse_tree.set_of_var.

:- import_module list.

%-----------------------------------------------------------------------------%

:- type maybe_changed
    --->    changed
    ;       unchanged.

    % Should we emit an error message about extra variables in the head
    % of a promise_equivalent_solutions scope?  Extra variables are
    % those non-locals that are not further bound or (potentially) constrained
    % by the goal inside the scope.
    %
    % We ignore such extra variables when re-running determinism
    % analysis after optimisations such as inlining have been performed
    % because not doing so results in spurious error messages.
    % (Inlining can cause variables that had inst any to become ground.)
    %
:- type report_pess_extra_vars
    --->    pess_extra_vars_report
            % Emit an error message if the head of a
            % promise_equivalent_solutions scope contains variables that
            % are not further bound or (potentially) further constrained
            % by the goal inside the scope.

    ;       pess_extra_vars_ignore.
            % Do not emit an error message if the above occurs.

    % Does the predicate being analyzed contain a require_complete_switch
    % or require_detism scope?
    %
:- type contains_require_scope
    --->    does_not_contain_require_scope
    ;       contains_require_scope.

    % Does the predicate being analyzed contain a call that can be optimized
    % by format_call.m?
    %
:- type contains_format_call
    --->    does_not_contain_format_call
    ;       contains_format_call.

:- type det_info.

    % Given a list of cases, and a list of the possible cons_ids
    % that the switch variable could be bound to, select out only
    % those cases whose cons_id occurs in the list of possible cons_ids.
    %
:- pred delete_unreachable_cases(list(case)::in, list(cons_id)::in,
    list(case)::out) is det.

    % Update the current substitution to account for the effects
    % of the given unification.
    %
:- pred interpret_unify(prog_var::in, unify_rhs::in,
    prog_substitution::in, prog_substitution::out) is semidet.

    % Look up the determinism of a procedure, and also return the pred_info
    % containing the procedure. Doing both at once allows a small speedup.
    %
:- pred det_lookup_pred_info_and_detism(det_info::in, pred_id::in, proc_id::in,
    pred_info::out, determinism::out) is det.

:- pred det_get_proc_info(det_info::in, proc_info::out) is det.

:- pred det_lookup_var_type(module_info::in, proc_info::in, prog_var::in,
    hlds_type_defn::out) is semidet.

:- pred det_no_output_vars(det_info::in, instmap::in, instmap_delta::in,
    set_of_progvar::in) is semidet.

:- pred det_info_add_error_spec(error_spec::in, det_info::in, det_info::out)
    is det.

:- pred det_info_init(module_info::in, vartypes::in, pred_id::in, proc_id::in,
    report_pess_extra_vars::in, list(error_spec)::in, det_info::out) is det.

:- pred det_info_get_module_info(det_info::in, module_info::out) is det.
:- pred det_info_get_pred_id(det_info::in, pred_id::out) is det.
:- pred det_info_get_proc_id(det_info::in, proc_id::out) is det.
:- pred det_info_get_vartypes(det_info::in, vartypes::out) is det.
:- pred det_info_get_pess_extra_vars(det_info::in,
    report_pess_extra_vars::out) is det.
:- pred det_info_get_has_format_call(det_info::in,
    contains_format_call::out) is det.
:- pred det_info_get_has_req_scope(det_info::in,
    contains_require_scope::out) is det.
:- pred det_info_get_error_specs(det_info::in, list(error_spec)::out) is det.

:- pred det_info_set_module_info(module_info::in, det_info::in, det_info::out)
    is det.
:- pred det_info_set_has_format_call(det_info::in, det_info::out) is det.
:- pred det_info_set_has_req_scope(det_info::in, det_info::out) is det.

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- implementation.

:- import_module libs.
:- import_module libs.globals.
:- import_module libs.options.
:- import_module parse_tree.prog_type.
:- import_module parse_tree.prog_util.

:- import_module map.
:- import_module set_tree234.
:- import_module term.

%-----------------------------------------------------------------------------%

delete_unreachable_cases(Cases0, PossibleConsIds, Cases) :-
    PossibleConsIdSet = set_tree234.list_to_set(PossibleConsIds),
    % We use a reverse list accumulator because we want to avoid requiring
    % O(n) stack space.
    delete_unreachable_cases_acc(Cases0, PossibleConsIdSet, [], RevCases),
    list.reverse(RevCases, Cases).

:- pred delete_unreachable_cases_acc(list(case)::in, set_tree234(cons_id)::in,
    list(case)::in, list(case)::out) is det.

delete_unreachable_cases_acc([], _PossibleConsIdSet, !RevCases).
delete_unreachable_cases_acc([Case0 | Cases0], PossibleConsIdSet, !RevCases) :-
    Case0 = case(MainConsId0, OtherConsIds0, Goal),
    ( if set_tree234.contains(PossibleConsIdSet, MainConsId0) then
        list.filter(set_tree234.contains(PossibleConsIdSet),
            OtherConsIds0, OtherConsIds),
        Case = case(MainConsId0, OtherConsIds, Goal),
        !:RevCases = [Case | !.RevCases]
    else
        list.filter(set_tree234.contains(PossibleConsIdSet),
            OtherConsIds0, OtherConsIds1),
        (
            OtherConsIds1 = []
            % We don't add Case to !RevCases, effectively deleting it.
        ;
            OtherConsIds1 = [MainConsId | OtherConsIds],
            Case = case(MainConsId, OtherConsIds, Goal),
            !:RevCases = [Case | !.RevCases]
        )
    ),
    delete_unreachable_cases_acc(Cases0, PossibleConsIdSet, !RevCases).

interpret_unify(X, rhs_var(Y), !Subst) :-
    unify_term(variable(X, context_init), variable(Y, context_init), !Subst).
interpret_unify(X, rhs_functor(ConsId, _, ArgVars), !Subst) :-
    term.var_list_to_term_list(ArgVars, ArgTerms),
    cons_id_and_args_to_term(ConsId, ArgTerms, RhsTerm),
    unify_term(variable(X, context_init), RhsTerm, !Subst).
interpret_unify(_X, rhs_lambda_goal(_, _, _, _, _, _, _, _, _), !Subst).
    % For ease of implementation we just ignore unifications with lambda terms.
    % This is a safe approximation, it just prevents us from optimizing them
    % as well as we would like.

det_lookup_pred_info_and_detism(DetInfo, PredId, ModeId, PredInfo, Detism) :-
    det_info_get_module_info(DetInfo, ModuleInfo),
    module_info_get_preds(ModuleInfo, PredTable),
    map.lookup(PredTable, PredId, PredInfo),
    pred_info_get_proc_table(PredInfo, ProcTable),
    map.lookup(ProcTable, ModeId, ProcInfo),
    proc_info_interface_determinism(ProcInfo, Detism).

det_get_proc_info(DetInfo, ProcInfo) :-
    det_info_get_module_info(DetInfo, ModuleInfo),
    det_info_get_pred_id(DetInfo, PredId),
    det_info_get_proc_id(DetInfo, ProcId),
    module_info_get_preds(ModuleInfo, PredTable),
    map.lookup(PredTable, PredId, PredInfo),
    pred_info_get_proc_table(PredInfo, ProcTable),
    map.lookup(ProcTable, ProcId, ProcInfo).

det_lookup_var_type(ModuleInfo, ProcInfo, Var, TypeDefn) :-
    proc_info_get_vartypes(ProcInfo, VarTypes),
    lookup_var_type(VarTypes, Var, Type),
    type_to_ctor_det(Type, TypeCtor),
    module_info_get_type_table(ModuleInfo, TypeTable),
    search_type_ctor_defn(TypeTable, TypeCtor, TypeDefn).

det_no_output_vars(DetInfo, InstMap, InstMapDelta, Vars) :-
    det_info_get_module_info(DetInfo, ModuleInfo),
    VarTypes = DetInfo ^ di_vartypes,
    instmap_delta_no_output_vars(ModuleInfo, VarTypes, InstMap, InstMapDelta,
        Vars).

det_info_add_error_spec(Spec, !DetInfo) :-
    det_info_get_error_specs(!.DetInfo, Specs0),
    Specs = [Spec | Specs0],
    det_info_set_error_specs(Specs, !DetInfo).

%-----------------------------------------------------------------------------%

:- type det_info
    --->    det_info(
                di_module_info      :: module_info,
                di_vartypes         :: vartypes,
                di_pred_id          :: pred_id,     % the id of the proc
                di_proc_id          :: proc_id,     % currently processed
                di_pess_extra_vars  :: report_pess_extra_vars,
                di_has_format_call  :: contains_format_call,
                di_has_req_scope    :: contains_require_scope,
                di_error_specs      :: list(error_spec)
            ).

det_info_init(ModuleInfo, VarTypes, PredId, ProcId, PessExtraVars, Specs,
        DetInfo) :-
    DetInfo = det_info(ModuleInfo, VarTypes, PredId, ProcId, PessExtraVars,
        does_not_contain_format_call, does_not_contain_require_scope, Specs).

det_info_get_module_info(DetInfo, X) :-
    X = DetInfo ^ di_module_info.
det_info_get_pred_id(DetInfo, X) :-
    X = DetInfo ^ di_pred_id.
det_info_get_proc_id(DetInfo, X) :-
    X = DetInfo ^ di_proc_id.
det_info_get_vartypes(DetInfo, X) :-
    X = DetInfo ^ di_vartypes.
det_info_get_pess_extra_vars(DetInfo, X) :-
    X = DetInfo ^ di_pess_extra_vars.
det_info_get_has_format_call(DetInfo, X) :-
    X = DetInfo ^ di_has_format_call.
det_info_get_has_req_scope(DetInfo, X) :-
    X = DetInfo ^ di_has_req_scope.
det_info_get_error_specs(DetInfo, X) :-
    X = DetInfo ^ di_error_specs.

:- pred det_info_set_error_specs(list(error_spec)::in,
    det_info::in, det_info::out) is det.

det_info_set_module_info(X, !DetInfo) :-
    ( if private_builtin.pointer_equal(X, !.DetInfo ^ di_module_info) then
        true
    else
        !DetInfo ^ di_module_info := X
    ).
det_info_set_has_format_call(!DetInfo) :-
    X = contains_format_call,
    ( if X = !.DetInfo ^ di_has_format_call then
        true
    else
        !DetInfo ^ di_has_format_call := X
    ).
det_info_set_has_req_scope(!DetInfo) :-
    X = contains_require_scope,
    ( if X = !.DetInfo ^ di_has_req_scope then
        true
    else
        !DetInfo ^ di_has_req_scope := X
    ).
det_info_set_error_specs(X, !DetInfo) :-
    !DetInfo ^ di_error_specs := X.

% Access stats for the det_info structure, derived using the commented-out
% code below:
%
%  i      read      same      diff   same%
%  0   5135754    209308      2043  99.033%     module_info
%  1    339264         0         0              pred_id
%  2    339264         0         0              proc_id
%  3    211938         0         0              vartypes
%  4       371         0         0              pess_extra_vars
%  5    299597       921      1381  40.009%     has_format_call
%  6    299597       147       140  51.220%     has_req_scope
%  7    300265         0        33   0.000%     error_specs

% :- pragma foreign_decl("C", local,
% "
% #define MR_NUM_INFO_STATS    11
% unsigned long MR_stats_read[MR_NUM_INFO_STATS];
% unsigned long MR_stats_same[MR_NUM_INFO_STATS];
% unsigned long MR_stats_diff[MR_NUM_INFO_STATS];
% ").
%
% :- pred gather_info_read_stats(int::in,
%     det_info::in, det_info::out) is det.
%
% :- pragma foreign_proc("C",
%     gather_info_read_stats(N::in, Info0::in, Info::out),
%     [will_not_call_mercury, promise_pure],
% "
%     ++MR_stats_read[N];
%     Info = Info0;
% ").
%
% :- pred gather_info_write_stats(int::in, T::in, T::in,
%     det_info::in, det_info::out) is det.
%
% :- pragma foreign_proc("C",
%     gather_info_write_stats(N::in, Old::in, New::in, Info0::in, Info::out),
%     [will_not_call_mercury, promise_pure],
% "
%     if (((MR_Unsigned) Old) == ((MR_Unsigned) New)) {
%         ++MR_stats_same[N];
%     } else {
%         ++MR_stats_diff[N];
%     }
%
%     Info = Info0;
% ").
%
% :- interface.
% :- import_module io.
% :- pred write_det_info_stats(io::di, io::uo) is det.
% :- implementation.
%
% :- pragma foreign_proc("C",
%     write_det_info_stats(IO0::di, IO::uo),
%     [will_not_call_mercury, promise_pure],
% "
%     FILE *fp;
%
%     fp = fopen(""/tmp/DET_INFO_STATS"", ""a"");
%     if (fp != NULL) {
%         int i;
%         for (i = 0; i < MR_NUM_INFO_STATS; i++) {
%             fprintf(fp, ""stat_rsd %d %lu %lu %lu\\n"",
%                 i, MR_stats_read[i], MR_stats_same[i], MR_stats_diff[i]);
%         }
%     }
%
%     IO = IO0;
% ").

%-----------------------------------------------------------------------------%
:- end_module check_hlds.det_util.
%-----------------------------------------------------------------------------%
