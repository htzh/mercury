%-----------------------------------------------------------------------------%
% Copyright (C) 1995 University of Melbourne.
% This file may only be copied under the terms of the GNU General
% Public License - see the file COPYING in the Mercury distribution.
%-----------------------------------------------------------------------------%
%
% File: typecheck.m.
% Main author: fjh.
%
% This file contains a type-checker.
% 
% The predicates in this module are named as follows:
% 
% 	Predicates that type check a particular language
% 	construct (goal, clause, etc.) are called typecheck_*.
% 	These will eventually have to iterate over every type
% 	assignment in the type assignment set.
% 
% 	Predicates that unify two things with respect to a
% 	single type assignment, as opposed to a type assignment set
% 	are called type_assign_*.
% 
% 	Access predicates for the type_info data structure are called
% 	type_info_*.
%
% Note that DCGS are used for THREE different purposes in this file:
%
%	1.  For accumulating io__states as usual.
%
%	2.  For accumulating type_infos, which contain:
%		- an io_state, which is modified if we need to
%		  to write out an error message
%		- various semi-global info which doesn't change often,
%		  namely the pred_id and term__context of the clause
%		  we are type-checking
%		- a type_assign_set which stores the set of possible
%		  type assignments and is modified as we traverse through
%		  the clause
%	
%	3.  For accumulating type_assign_sets.  This is when we are
%	    type-checking a single atomic construct (unification or
%	    predicate), and we are iterating through all the
%	    possible existing type-assignments to accumulate a new
%	    type-assignment set.
%
% This can be a little confusing if you're not aware of it, so be
% careful to look at the pred declarations to see what each DCG predicate
% is actually accumulating.
% 
% There are four sorts of types:
%
% 1) discriminated unions:
%	:- type tree(T) ---> nil ; t(tree(T), T, tree(T)).
%
% 2) undiscriminated unions [NOT YET IMPLEMENTED].
%	If rhs has a single type then the two
%	types have same structure but *different* name.
%	Basically just syntactic sugar for discriminated unions,
%	except that it also works for builtin types like int.
%
%		% an undiscriminate union
%		% same as type t3 ---> a ; b ; c ; d.
%	:- type t3 = t1 + t2.
%
%	:- type t1 ---> a ; b.
%	:- type t2 ---> c ; d.
%
%		% another undiscriminated union
%	:- type number = int + float.
%
%    undiscriminated unions are NOT YET IMPLEMENTED.
%
% 3) equivalent types (treated identically, ie, same name.  Any number
%	of types can be equivalent; the *canonical* one is the one
%	which is not defined using ==):
%	:- type real == float.
%
%    Currently references to equivalence types are expanded
%    in a separate pass by mercury_compile.m.  It would be better
%    to avoid expanding them (and instead modify the type unification
%    algorithm to handle equivalent types) because this would
%    give better error messages.  However, this is not a high
%    priority.
%
% 4) builtin types
%	character, int, float, string
%	pred, pred(T), pred(T1, T2), pred(T1, T2, T3), ... 
%       These types have special syntax for constants.
%	There may be other types (short integers, complex numbers, rationals,
%	etc.) provided by the system, but they can just be part of the
%	standard library.
%
% Each predicate must have a `:- pred' declaration specifying the
% types of the arguments for that predicate.
%
%-----------------------------------------------------------------------------%
%  Wish list:
%
%	improve the error reporting for the unify var & functor case
%
% 	we should handle explicit type qualifications
% 	(and remove them here) but we don't do so yet
%
%	we should handle equivalence types here
%
%	we should handle overloading of predicates
%
%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- module typecheck.
:- interface.
:- import_module hlds, io, prog_io.

:- pred typecheck(module_info, module_info, bool, io__state, io__state).
:- mode typecheck(in, out, out, di, uo) is det.

:- pred typecheck_pred_type(pred_id, pred_info, module_info,
	maybe(pred_info), io__state, io__state).
:- mode typecheck_pred_type(in, in, in, out, di, uo) is det.

/*
	Formally, typecheck(Module0, Module, FoundError, IO0, IO) is
	intended to be true iff Module is Module0 annotated with the
	variable typings that result from the process of type-checking,
	FoundError is `yes' if Module0 contains any type errors and `no'
	otherwise, and IO is the io__state that results from IO0 after
	printing out appropriate error messages for the type errors in
	Module0, if any.

	Informally, typecheck(Module0, Module, FoundError, IO0, IO) 
	type-checks Module0 and annotates it with variable typings
	(returning the result in Module), prints out appropriate error
	messages, and sets FoundError to `yes' if it finds any errors
	and `no' otherwise.

	Typecheck also copies the clause_info structure it annotates
	to the proc structures. This is done at the end of typecheck
	and not at the start of modecheck because modecheck may be
	reinvoked after HLDS transformations. Any transformation that
	needs typechecking should work with the clause_info structure.
*/

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

:- implementation.
:- import_module int, list, map, string, require, std_util, tree234.
:- import_module varset, term, prog_util, type_util, code_util.
:- import_module term_io, prog_out, hlds_out, mercury_to_mercury.
:- import_module options, getopt, globals, passes_aux, clause_to_proc.
:- import_module undef_types.

%-----------------------------------------------------------------------------%

	% XXX need to pass FoundError to all steps

typecheck(Module0, Module, FoundError) -->
	globals__io_lookup_bool_option(statistics, Statistics),
	globals__io_lookup_bool_option(verbose, Verbose),
	io__stderr_stream(StdErr),
	io__set_output_stream(StdErr, OldStream),
	maybe_report_stats(Statistics),

	maybe_write_string(Verbose, "% Checking for undefined types...\n"),
	check_undefined_types(Module0, Module1, FoundUndefError),
	maybe_report_stats(Statistics),
	( { FoundUndefError = yes } ->
		{ Module = Module1 },
		{ FoundError = yes }
	;
		%%% maybe_write_string(Verbose,
		%%% 	"% Checking for circular type definitions...\n"),
		check_circular_types(Module1, Module2),
		%%% maybe_report_stats(Statistics),

		maybe_write_string(Verbose, "% Type-checking clauses...\n"),
		check_pred_types(Module2, Module, FoundError),
		maybe_report_stats(Statistics)
	),
	io__set_output_stream(OldStream, _).

%-----------------------------------------------------------------------------%
	
	% Type-check the code for all the predicates in a module.

:- pred check_pred_types(module_info, module_info, bool, io__state, io__state).
:- mode check_pred_types(in, out, out, di, uo) is det.

check_pred_types(Module0, Module, FoundError) -->
	{ module_info_predids(Module0, PredIds) },
	typecheck_pred_types_2(PredIds, Module0, Module, no, FoundError).

%-----------------------------------------------------------------------------%

	% Iterate over the list of pred_ids in a module.

:- pred typecheck_pred_types_2(list(pred_id), module_info, module_info,
	bool, bool, io__state, io__state).
:- mode typecheck_pred_types_2(in, in, out, in, out, di, uo) is det.

typecheck_pred_types_2([], ModuleInfo, ModuleInfo, Error, Error) --> [].
typecheck_pred_types_2([PredId | PredIds],
		ModuleInfo0, ModuleInfo, Error0, Error) -->
	{ module_info_preds(ModuleInfo0, Preds0) },
	{ map__lookup(Preds0, PredId, PredInfo0) },
	(
		{ pred_info_is_imported(PredInfo0) }
	->
		{ Error1 = Error0 },
		{ ModuleInfo1 = ModuleInfo0 }
	;
		typecheck_pred_type(PredId, PredInfo0, ModuleInfo0,
			MaybePredInfo),
		{
			MaybePredInfo = yes(PredInfo1),
			Error1 = Error0,
			map__set(Preds0, PredId, PredInfo1, Preds),
			module_info_set_preds(ModuleInfo0, Preds, ModuleInfo1)
		;
			MaybePredInfo = no,
			Error1 = yes,
			module_info_remove_predid(ModuleInfo0, PredId,
				ModuleInfo1)
		}
	),
	typecheck_pred_types_2(PredIds, ModuleInfo1, ModuleInfo, Error1, Error).

typecheck_pred_type(PredId, PredInfo0, ModuleInfo, MaybePredInfo,
		IOState0, IOState) :-
	typecheck_pred_type_2(PredId, PredInfo0, ModuleInfo, MaybePredInfo0,
		IOState0, IOState),
	(
		MaybePredInfo0 = no,
		MaybePredInfo = no
	;
		MaybePredInfo0 = yes(PredInfo1),
		copy_clauses_to_procs(PredInfo1, PredInfo),
		MaybePredInfo = yes(PredInfo)
	).

:- pred typecheck_pred_type_2(pred_id, pred_info, module_info,
	maybe(pred_info), io__state, io__state).
:- mode typecheck_pred_type_2(in, in, in, out, di, uo) is det.

typecheck_pred_type_2(PredId, PredInfo0, ModuleInfo, MaybePredInfo,
		IOState0, IOState) :-
	(
	    % Compiler-generated predicates are created already type-correct,
	    % there's no need to typecheck them.
	    code_util__compiler_generated(PredInfo0)
	->
	    pred_info_clauses_info(PredInfo0, ClausesInfo0),
	    ClausesInfo0 = clauses_info(VarSet, VarTypes0, HeadVars, Clauses0),
	    ( Clauses0 = [] ->
		pred_info_mark_as_external(PredInfo0, PredInfo)
	    ;
	        PredInfo = PredInfo0
	    ),
	    MaybePredInfo = yes(PredInfo),
	    IOState = IOState0
	;
	    pred_info_arg_types(PredInfo0, _ArgTypeVarSet, ArgTypes),
	    pred_info_typevarset(PredInfo0, TypeVarSet0),
	    pred_info_clauses_info(PredInfo0, ClausesInfo0),
	    ClausesInfo0 = clauses_info(VarSet, VarTypes0, HeadVars, Clauses0),
	    ( Clauses0 = [] ->
		report_error_no_clauses(PredId, PredInfo0, ModuleInfo,
			IOState0, IOState),
		MaybePredInfo = no
	    ;
		write_progress_message("% Type-checking predicate ",
			PredId, ModuleInfo, IOState0, IOState1),
		term__vars_list(ArgTypes, HeadTypeParams),
		type_info_init(IOState1, ModuleInfo, PredId,
				TypeVarSet0, VarSet, VarTypes0, HeadTypeParams,
				TypeInfo1),
		typecheck_clause_list(Clauses0, HeadVars, ArgTypes, Clauses,
				TypeInfo1, TypeInfo2),
		type_info_get_final_info(TypeInfo2, TypeVarSet, VarTypes1),
		map__optimize(VarTypes1, VarTypes),
		ClausesInfo = clauses_info(VarSet, VarTypes, HeadVars, Clauses),
		pred_info_set_clauses_info(PredInfo0, ClausesInfo, PredInfo1),
		pred_info_set_typevarset(PredInfo1, TypeVarSet, PredInfo),
		type_info_get_found_error(TypeInfo2, Error),
		(
			Error = yes,
			MaybePredInfo = no
		;
			Error = no,
			MaybePredInfo = yes(PredInfo)
		),
		type_info_get_io_state(TypeInfo2, IOState)
	    )
	).

%-----------------------------------------------------------------------------%

	% Iterate over the list of clauses for a predicate.

:- pred typecheck_clause_list(list(clause), list(var), list(type), list(clause),
				type_info, type_info).
:- mode typecheck_clause_list(in, in, in, out, type_info_di, type_info_uo)
	is det.

typecheck_clause_list([], _, _, []) --> [].
typecheck_clause_list([Clause0|Clauses0], HeadVars, ArgTypes,
			[Clause|Clauses]) -->
	typecheck_clause(Clause0, HeadVars, ArgTypes, Clause),
	typecheck_clause_list(Clauses0, HeadVars, ArgTypes, Clauses).

%-----------------------------------------------------------------------------%

	% Type-check a single clause.

	% As we go through a clause, we determine the possible
	% type assignments for the clause.  A type assignment
	% is an assignment of a type to each variable in the
	% clause.
	%
	% Note that this may cause exponential time & space usage
	% in the presence of overloading of predicates and/or
	% functors.  This is a potentially serious problem, but
	% there's no easy solution apparent.
	%
	% It would be more natural to use non-determinism to write
	% this code, and perhaps even more efficient.
	% But doing it nondeterministically would make bootstrapping more
	% difficult, and most importantly would make good error
	% messages very difficult.

	% we should perhaps do manual garbage collection here

:- pred typecheck_clause(clause, list(var), list(type), clause,
			type_info, type_info).
:- mode typecheck_clause(in, in, in, out, type_info_di, type_info_uo) is det.

typecheck_clause(Clause0, HeadVars, ArgTypes, Clause) -->
		% XXX abstract clause/3
	{ Clause0 = clause(Modes, Body0, Context) },
	type_info_set_context(Context),
		% typecheck the clause - first the head unification, and
		% then the body
	typecheck_var_has_type_list(HeadVars, ArgTypes, 0),
	typecheck_goal(Body0, Body),
	{ Clause = clause(Modes, Body, Context) },
		% check for type ambiguities
	typecheck_finish_clause.

%-----------------------------------------------------------------------------%

	% If there are still multiple type assignments for the clause,
	% then we issue an error message here.

:- pred typecheck_finish_clause(type_info, type_info).
:- mode typecheck_finish_clause(type_info_di, type_info_uo) is det.

typecheck_finish_clause(TypeInfo0, TypeInfo) :-
	type_info_get_type_assign_set(TypeInfo0, TypeAssignSet),
	( TypeAssignSet = [_TypeAssign] ->
		TypeInfo = TypeInfo0
	; TypeAssignSet = [TypeAssign1, TypeAssign2 | _] ->
			% we only report an ambiguity error if
			% there weren't any other errors in the clause
		type_info_get_found_error(TypeInfo0, FoundError),
		( FoundError = no ->
			type_info_set_found_error(TypeInfo0, yes, TypeInfo1),
			type_info_get_io_state(TypeInfo1, IOState0),
			report_ambiguity_error(TypeInfo1, TypeAssign1,
				TypeAssign2, IOState0, IOState),
			type_info_set_io_state(TypeInfo1, IOState, TypeInfo)
		;
			TypeInfo = TypeInfo0
		)
	;
		% there should always be a type assignment, because
		% if there is an error somewhere, instead of setting
		% the current type assignment set to the empty set,
		% the type-checker should continue with the previous
		% type assignment set (so that it can detect other
		% errors in the same clause).
		error("internal error in typechecker: no type-assignment"),
		TypeInfo = TypeInfo0
	).

/************************ BEGIN JUNK
This section is commented out, since the error which it attempts
to detect is in fact not an error at all!

	% Check that the all of the types which have been inferred
	% for the variables in the clause do not contain any unbound type
	% variables other than the HeadTypeParams.

:- pred check_type_bindings(type_assign, type_info, type_info).
:- mode check_type_bindings(in, type_info_di, type_info_uo) is det.

check_type_bindings(TypeAssign, TypeInfo0, TypeInfo) :-
	type_info_get_head_type_params(TypeInfo0, HeadTypeParams),
	type_assign_get_type_bindings(TypeAssign, TypeBindings),
	type_assign_get_var_types(TypeAssign, VarTypes),
	map__values(VarTypes, Types),
	set__init(Set0),
	check_type_bindings_2(Types, TypeBindings, HeadTypeParams, Set0, Set),
	set__to_sorted_list(Set, ErrorVars),
	( ErrorVars = [] ->
		TypeInfo = TypeInfo0
	;
		type_assign_get_typevarset(TypeAssign, TVarSet),
		report_unresolved_type_error(ErrorVars, TVarSet, TypeInfo0,
			TypeInfo)
	).

:- pred check_type_bindings_2(list(term), tsubst, headtypes, set(var),
				set(var)).
:- mode check_type_bindings_2(in, in, in, in, out) is det.

check_type_bindings_2([], _, _, Set, Set).
check_type_bindings_2([Type0 | Types], TypeBindings, HeadTypeParams, Set0,
			Set) :-
	term__apply_rec_substitution(Type0, TypeBindings, Type),
	term__vars(Type, TVars),
	set__list_to_set(TVars, TVarsSet0),
	set__remove_list(TVarsSet0, HeadTypeParams, TVarsSet1),
	set__union(Set0, TVarsSet1, Set1),
	check_type_bindings_2(Types, TypeBindings, HeadTypeParams, Set1, Set).

	% report an error: uninstantiated type parameter

:- pred report_unresolved_type_error(list(var), tvarset, type_info, type_info).
:- mode report_unresolved_type_error(in, in, type_info_di, type_info_uo) is det.

report_unresolved_type_error(TVars, TVarSet, TypeInfo0, TypeInfo) :-
	type_info_get_io_state(TypeInfo0, IOState0),
	report_unresolved_type_error_2(TypeInfo0, TVars, TVarSet,
		IOState0, IOState),
	type_info_set_io_state(TypeInfo0, IOState, TypeInfo1),
	type_info_set_found_error(TypeInfo1, yes, TypeInfo).

:- pred report_unresolved_type_error_2(type_info, list(var), tvarset,
					io__state, io__state).
:- mode report_unresolved_type_error_2(type_info_no_io, in, in, di, uo) is det.

report_unresolved_type_error_2(TypeInfo, TVars, TVarSet) -->
	write_type_info_context(TypeInfo),
	{ type_info_get_context(TypeInfo, Context) },
	io__write_string("  type error: unresolved polymorphism.\n"),
	prog_out__write_context(Context),
	io__write_string("  Unbound type vars were: "),
	write_type_var_list(TVars, TVarSet),
	io__write_string(".\n"),
	globals__io_lookup_option(verbose_errors, bool(VerboseErrors)),
	( { VerboseErrors = yes } ->
		io__write_string("\tThe body of the clause contains a call to a polymorphic predicate,\n"),
		io__write_string("\tbut I can't determine which version should be called,\n"),
		io__write_string("\tbecause the type variables listed above didn't get bound.\n"),
			% XXX improve error message
		io__write_string("\t(I ought to tell you which call caused the error, but I'm afraid\n"),
		io__write_string("\tyou'll have to work it out yourself.  My apologies.)\n")
	;
		[]
	).

:- pred write_type_var_list(list(var), varset, io__state, io__state).
:- mode write_type_var_list(in, in, di, uo) is det.

write_type_var_list([], _) -->
	io__write_string("<none>").
write_type_var_list([V|Vs], VarSet) -->
	mercury_output_var(V, VarSet),
	write_type_var_list_2(Vs, VarSet).

:- pred write_type_var_list_2(list(var), varset, io__state, io__state).
:- mode write_type_var_list_2(in, in, di, uo) is det.

write_type_var_list_2([], _) --> [].
write_type_var_list_2([V|Vs], VarSet) -->
	io__write_string(", "),
	mercury_output_var(V, VarSet),
	write_type_var_list_2(Vs, VarSet).

END JUNK ***************************/

%-----------------------------------------------------------------------------%

:- pred typecheck_goal(hlds__goal, hlds__goal, type_info, type_info).
:- mode typecheck_goal(in, out, type_info_di, type_info_uo) is det.

	% Typecheck a goal.
	% Note that we save the context of the goal in the typeinfo for
	% use in error messages.  Also, if the context of the goal is empty,
	% we set the context of the goal from the surrounding
	% context saved in the type-info.  (That should probably be done
	% in make_hlds, but it was easier to do here.)

typecheck_goal(Goal0 - GoalInfo0, Goal - GoalInfo, TypeInfo0, TypeInfo) :-
	goal_info_context(GoalInfo0, Context),
	term__context_init(EmptyContext),
	( Context = EmptyContext ->
		type_info_get_context(TypeInfo0, EnclosingContext),
		goal_info_set_context(GoalInfo0, EnclosingContext, GoalInfo),
		TypeInfo1 = TypeInfo0
	;
		GoalInfo = GoalInfo0,
		type_info_set_context(Context, TypeInfo0, TypeInfo1)
	),

		% type-check the goal
	typecheck_goal_2(Goal0, Goal, TypeInfo1, TypeInfo2),

	check_warn_too_much_overloading(TypeInfo2, TypeInfo).
	
:- pred typecheck_goal_2(hlds__goal_expr, hlds__goal_expr,
				type_info, type_info).
:- mode typecheck_goal_2(in, out, type_info_di, type_info_uo) is det.

typecheck_goal_2(conj(List0), conj(List)) -->
	checkpoint("conj"),
	typecheck_goal_list(List0, List).
typecheck_goal_2(disj(List0), disj(List)) -->
	checkpoint("disj"),
	typecheck_goal_list(List0, List).
typecheck_goal_2(if_then_else(Vs, A0, B0, C0), if_then_else(Vs, A, B, C)) -->
	checkpoint("if"),
	typecheck_goal(A0, A),
	checkpoint("then"),
	typecheck_goal(B0, B),
	checkpoint("else"),
	typecheck_goal(C0, C).
typecheck_goal_2(not(A0), not(A)) -->
	checkpoint("not"),
	typecheck_goal(A0, A).
typecheck_goal_2(some(Vs, G0), some(Vs, G)) -->
	checkpoint("some"),
	typecheck_goal(G0, G).
typecheck_goal_2(call(_, Mode, Args, Builtin, PredName, Follow),
			call(PredId, Mode, Args, Builtin, PredName, Follow)) -->
	checkpoint("call"),
	typecheck_call_pred(PredName, Args, PredId).
typecheck_goal_2(unify(A, B0, Mode, Info, UnifyContext),
		unify(A, B, Mode, Info, UnifyContext)) -->
	checkpoint("unify"),
	type_info_set_arg_num(0),
	type_info_set_unify_context(UnifyContext),
	typecheck_unification(A, B0, B).
typecheck_goal_2(switch(_, _, _), _) -->
	{ error("unexpected switch") }.

%-----------------------------------------------------------------------------%

:- pred typecheck_goal_list(list(hlds__goal), list(hlds__goal),
				type_info, type_info).
:- mode typecheck_goal_list(in, out, type_info_di, type_info_uo) is det.

typecheck_goal_list([], []) --> [].
typecheck_goal_list([Goal0 | Goals0], [Goal | Goals]) -->
	typecheck_goal(Goal0, Goal),
	typecheck_goal_list(Goals0, Goals).

%-----------------------------------------------------------------------------%

:- pred typecheck_call_pred(sym_name, list(var), pred_id, type_info,
				type_info).
:- mode typecheck_call_pred(in, in, out, type_info_di, type_info_uo) is det.

	% WISHLIST - we should handle overloading of predicates

typecheck_call_pred(PredName, Args, PredId, TypeInfo0, TypeInfo) :-
		% repair the module name in the PredId
		% (make_hlds.m doesn't set it up correctly)
	list__length(Args, Arity),
	unqualify_name(PredName, Name),

	PredCallId = PredName/Arity,
	type_info_set_called_predid(TypeInfo0, PredCallId, TypeInfo1),

		% look up the called predicate's arg types
	type_info_get_module_info(TypeInfo1, ModuleInfo),
	module_info_get_predicate_table(ModuleInfo, PredicateTable),
	( 
		predicate_table_search_sym_arity(PredicateTable,
			PredName, Arity, PredIdList)
	->
		( PredIdList = [PredId0] ->
			PredId = PredId0
		;
			error("sorry, predicate overloading not implemented")
		),

		predicate_table_get_preds(PredicateTable, Preds),
		map__lookup(Preds, PredId, PredInfo),
		pred_info_arg_types(PredInfo, PredTypeVarSet, PredArgTypes),

			% rename apart the type variables in called
			% predicate's arg types and then
			% unify the types of the call arguments with
			% the called predicates' arg types
			% (optimize for the common case of
			% a non-polymorphic predicate)
		( varset__is_empty(PredTypeVarSet) ->
			typecheck_var_has_type_list(Args, PredArgTypes, 0,
					TypeInfo1, TypeInfo)
		;
			typecheck_var_has_polymorphic_type_list(
				Args, PredTypeVarSet, PredArgTypes,
				TypeInfo1, TypeInfo)
		)
	;
		invalid_pred_id(PredId),
		type_info_get_io_state(TypeInfo1, IOState0),
		( predicate_table_search_name(PredicateTable, Name, OtherIds) ->
			typecheck_find_arities(ModuleInfo, OtherIds, Arities),
			report_error_pred_num_args(TypeInfo1, PredCallId,
				Arities, IOState0, IOState)
		;
			report_error_undef_pred(TypeInfo1, PredCallId,
				IOState0, IOState)
		),
		type_info_set_io_state(TypeInfo1, IOState, TypeInfo2),
		type_info_set_found_error(TypeInfo2, yes, TypeInfo)
	).

:- pred typecheck_find_arities(module_info, list(pred_id), list(int)).
:- mode typecheck_find_arities(in, in, out) is det.

typecheck_find_arities(_ModuleInfo, [], []).
typecheck_find_arities(ModuleInfo, [PredId | PredIds], [Arity | Aritis]) :-
	predicate_arity(ModuleInfo, PredId, Arity),
	typecheck_find_arities(ModuleInfo, PredIds, Aritis).

%-----------------------------------------------------------------------------%

	% Rename apart the type variables in called predicate's arg types
	% separately for each type assignment, resulting in an "arg type
	% assignment set", and then for each arg type assignment in the
	% arg type assignment set, check that the argument variables have
	% the expected types.

:- pred typecheck_var_has_polymorphic_type_list(list(var), tvarset, list(type),
					type_info, type_info).
:- mode typecheck_var_has_polymorphic_type_list(in, in, in,
					type_info_di, type_info_uo) is det.

typecheck_var_has_polymorphic_type_list(Args, PredTypeVarSet, PredArgTypes,
					TypeInfo0, TypeInfo) :-
	type_info_get_type_assign_set(TypeInfo0, TypeAssignSet0),
	rename_apart(TypeAssignSet0, PredTypeVarSet, PredArgTypes,
				ArgsTypeAssignSet),
	typecheck_var_has_arg_type_list(Args, 0,
				ArgsTypeAssignSet, TypeInfo0, TypeInfo).

:- pred rename_apart(type_assign_set, tvarset, list(type),
                        args_type_assign_set).
:- mode rename_apart(in, in, in, out) is det.

rename_apart([], _, _, []).
rename_apart([TypeAssign0 | TypeAssigns0], PredTypeVarSet, PredArgTypes0,
                [TypeAssign - PredArgTypes | TypeAssigns]) :-
        type_assign_rename_apart(TypeAssign0, PredTypeVarSet, PredArgTypes0,
                        TypeAssign, PredArgTypes),
        rename_apart(TypeAssigns0, PredTypeVarSet, PredArgTypes0, TypeAssigns).

:- pred type_assign_rename_apart(type_assign, tvarset, list(type),
			type_assign, list(type)).
:- mode type_assign_rename_apart(in, in, in, out, out) is det.

type_assign_rename_apart(TypeAssign0, PredTypeVarSet, PredArgTypes0,
		TypeAssign, PredArgTypes) :-
	type_assign_get_typevarset(TypeAssign0, TypeVarSet0),
	varset__merge(TypeVarSet0, PredTypeVarSet, PredArgTypes0,
			  TypeVarSet, PredArgTypes),
	type_assign_set_typevarset(TypeAssign0, TypeVarSet, TypeAssign).

%-----------------------------------------------------------------------------%

	% Given a list of variables and a list of types, ensure
	% that each variable has the corresponding type.

:- pred typecheck_var_has_arg_type_list(list(var), int, args_type_assign_set,
					type_info, type_info).
:- mode typecheck_var_has_arg_type_list(in, in, in,
					type_info_di, type_info_uo) is det.

typecheck_var_has_arg_type_list([], _, ArgTypeAssignSet,
		TypeInfo0, TypeInfo) :-
	convert_args_type_assign_set(ArgTypeAssignSet, TypeAssignSet),
	type_info_set_type_assign_set(TypeInfo0, TypeAssignSet, TypeInfo).

typecheck_var_has_arg_type_list([Var|Vars], ArgNum, ArgTypeAssignSet0) -->
	{ ArgNum1 is ArgNum + 1 },
	type_info_set_arg_num(ArgNum1),
	typecheck_var_has_arg_type(Var, ArgTypeAssignSet0, ArgTypeAssignSet1),
	typecheck_var_has_arg_type_list(Vars, ArgNum1, ArgTypeAssignSet1).

:- pred convert_args_type_assign_set(args_type_assign_set, type_assign_set).
:- mode convert_args_type_assign_set(in, out) is det.

convert_args_type_assign_set([], []).
convert_args_type_assign_set([TypeAssign - Args | ArgTypeAssigns],
				[TypeAssign | TypeAssigns]) :-
	( Args = [] ->
		true
	;
		% this should never happen, since the arguments should
		% all have been processed at this point
		error("convert_args_type_assign_set")
	),
	convert_args_type_assign_set(ArgTypeAssigns, TypeAssigns).

:- pred typecheck_var_has_arg_type(var, 
				args_type_assign_set, args_type_assign_set,
				type_info, type_info).
:- mode typecheck_var_has_arg_type(in, in, out,
				type_info_di, type_info_uo) is det.

typecheck_var_has_arg_type(VarId, ArgTypeAssignSet0, ArgTypeAssignSet,
				TypeInfo0, TypeInfo) :-
	type_info_get_head_type_params(TypeInfo0, HeadTypeParams),
	typecheck_var_has_arg_type_2(ArgTypeAssignSet0, HeadTypeParams,
				VarId, [], ArgTypeAssignSet1),
	(
		ArgTypeAssignSet1 = [],
		ArgTypeAssignSet0 \= []
	->
		skip_arg(ArgTypeAssignSet0, ArgTypeAssignSet),
		type_info_get_io_state(TypeInfo0, IOState0),
		report_error_arg_var(TypeInfo0, VarId,
				ArgTypeAssignSet0, IOState0, IOState),
		type_info_set_io_state(TypeInfo0, IOState, TypeInfo1),
		type_info_set_found_error(TypeInfo1, yes, TypeInfo)
	;
		ArgTypeAssignSet = ArgTypeAssignSet1,
		TypeInfo = TypeInfo0
	).

:- pred skip_arg(args_type_assign_set, args_type_assign_set).
:- mode skip_arg(in, out) is det.

skip_arg([], []).
skip_arg([TypeAssign - Args0 | ArgTypeAssigns0],
				[TypeAssign - Args| ArgTypeAssigns]) :-
	( Args0 = [_ | Args1] ->
		Args = Args1
	;
		% this should never happen
		error("typecheck.m: skip_arg")
	),
	skip_arg(ArgTypeAssigns0, ArgTypeAssigns).

:- pred typecheck_var_has_arg_type_2(args_type_assign_set, headtypes, var,
				args_type_assign_set, args_type_assign_set).
:- mode typecheck_var_has_arg_type_2(in, in, in, in, out) is det.

typecheck_var_has_arg_type_2([], _, _) --> [].
typecheck_var_has_arg_type_2([TypeAssign0 - ArgTypes0 | TypeAssignSet0],
				HeadTypeParams, VarId) -->
	arg_type_assign_var_has_type(TypeAssign0, ArgTypes0,
					HeadTypeParams, VarId),
	typecheck_var_has_arg_type_2(TypeAssignSet0, HeadTypeParams, VarId).

:- pred arg_type_assign_var_has_type(type_assign, list(type), headtypes, var,
				args_type_assign_set, args_type_assign_set).
:- mode arg_type_assign_var_has_type(in, in, in, in, in, out) is det.

arg_type_assign_var_has_type(TypeAssign0, ArgTypes0, HeadTypeParams, VarId,
		ArgTypeAssignSet0, ArgTypeAssignSet) :-
	type_assign_get_var_types(TypeAssign0, VarTypes0),
	( ArgTypes0 = [Type | ArgTypes] ->
	    (
		map__search(VarTypes0, VarId, VarType)
	    ->
		(
		    type_assign_unify_type(TypeAssign0, HeadTypeParams,
				VarType, Type, TypeAssign1)
		->
		    ArgTypeAssignSet = [TypeAssign1 - ArgTypes |
					ArgTypeAssignSet0]
		;
		    ArgTypeAssignSet = ArgTypeAssignSet0
		)
	    ;
		map__set(VarTypes0, VarId, Type, VarTypes),
		type_assign_set_var_types(TypeAssign0, VarTypes, TypeAssign),
		ArgTypeAssignSet = [TypeAssign - ArgTypes | ArgTypeAssignSet0]
	    )
	;
	    error("arg_type_assign_var_has_type")
	).

%-----------------------------------------------------------------------------%

	% Given a list of variables and a list of types, ensure
	% that each variable has the corresponding type.

:- pred typecheck_var_has_type_list(list(var), list(type), int, type_info,
					type_info).
:- mode typecheck_var_has_type_list(in, in, in, type_info_di, type_info_uo)
	is det.

typecheck_var_has_type_list([], [_|_], _) -->
	{ error("typecheck_var_has_type_list: length mismatch") }.
typecheck_var_has_type_list([_|_], [], _) -->
	{ error("typecheck_var_has_type_list: length mismatch") }.
typecheck_var_has_type_list([], [], _) --> [].
typecheck_var_has_type_list([Var|Vars], [Type|Types], ArgNum) -->
	{ ArgNum1 is ArgNum + 1 },
	type_info_set_arg_num(ArgNum1),
	typecheck_var_has_type(Var, Type),
	typecheck_var_has_type_list(Vars, Types, ArgNum1).

:- pred typecheck_var_has_type(var, type, type_info, type_info).
:- mode typecheck_var_has_type(in, in, type_info_di, type_info_uo) is det.

typecheck_var_has_type(VarId, Type, TypeInfo0, TypeInfo) :-
	type_info_get_type_assign_set(TypeInfo0, TypeAssignSet0),
	type_info_get_head_type_params(TypeInfo0, HeadTypeParams),
	typecheck_var_has_type_2(TypeAssignSet0, HeadTypeParams, VarId, Type,
			[], TypeAssignSet),
	(
		TypeAssignSet = [],
		TypeAssignSet0 \= []
	->
		type_info_get_io_state(TypeInfo0, IOState0),
		report_error_var(TypeInfo0, VarId, 
				Type, TypeAssignSet0, IOState0, IOState),
		type_info_set_io_state(TypeInfo0, IOState, TypeInfo1),
		type_info_set_found_error(TypeInfo1, yes, TypeInfo)
	;
		type_info_set_type_assign_set(TypeInfo0, TypeAssignSet, TypeInfo)
	).

	% Given a type assignment set and a variable id,
	% return the list of possible different types for the variable.

:- type type_stuff ---> type_stuff(type, tvarset, tsubst).

:- pred get_type_stuff(type_assign_set, var, list(type_stuff)).
:- mode get_type_stuff(in, in, out) is det.
get_type_stuff([], _VarId, []).
get_type_stuff([TypeAssign | TypeAssigns], VarId, L) :-
	get_type_stuff(TypeAssigns, VarId, L0),
	type_assign_get_type_bindings(TypeAssign, TypeBindings),
	type_assign_get_typevarset(TypeAssign, TVarSet),
	type_assign_get_var_types(TypeAssign, VarTypes),
	(
		map__search(VarTypes, VarId, Type0)
	->
		Type = Type0
	;
		% this shouldn't happen - how can a variable which has
		% not yet been assigned a type variable fail to have
		% the correct type?
		term__context_init(Context),
		Type = term__functor(term__atom("<any>"), [], Context)
	),
	TypeStuff = type_stuff(Type, TVarSet, TypeBindings),
	(
		list__member(TypeStuff, L0)
	->
		L = L0
	;
		L = [TypeStuff | L0]
	).

	% Given an arg type assignment set and a variable id,
	% return the list of possible different types for the argument
	% and the variable.

:- type arg_type_stuff ---> arg_type_stuff(type, type, tvarset).

:- pred get_arg_type_stuff(args_type_assign_set, var, list(arg_type_stuff)).
:- mode get_arg_type_stuff(in, in, out) is det.
get_arg_type_stuff([], _VarId, []).
get_arg_type_stuff([TypeAssign - ArgTypes | ArgTypeAssigns], VarId, L) :-
	get_arg_type_stuff(ArgTypeAssigns, VarId, L0),
	type_assign_get_type_bindings(TypeAssign, TypeBindings),
	type_assign_get_typevarset(TypeAssign, TVarSet),
	type_assign_get_var_types(TypeAssign, VarTypes),
	(
		map__search(VarTypes, VarId, VarType0)
	->
		VarType = VarType0
	;
		% this shouldn't happen - how can a variable which has
		% not yet been assigned a type variable fail to have
		% the correct type?
		term__context_init(Context),
		VarType = term__functor(term__atom("<any>"), [], Context)
	),
	list__index0_det(ArgTypes, 0, ArgType),
	term__apply_rec_substitution(ArgType, TypeBindings, ArgType2),
	term__apply_rec_substitution(VarType, TypeBindings, VarType2),
	TypeStuff = arg_type_stuff(ArgType2, VarType2, TVarSet),
	(
		list__member(TypeStuff, L0)
	->
		L = L0
	;
		L = [TypeStuff | L0]
	).

:- type headtypes == list(tvar).

:- pred typecheck_var_has_type_2(type_assign_set, headtypes, var, type,
				type_assign_set, type_assign_set).
:- mode typecheck_var_has_type_2(in, in, in, in, in, out) is det.

typecheck_var_has_type_2([], _, _, _) --> [].
typecheck_var_has_type_2([TypeAssign0 | TypeAssignSet0], HeadTypeParams, VarId,
		Type) -->
	type_assign_var_has_type(TypeAssign0, HeadTypeParams, VarId, Type),
	typecheck_var_has_type_2(TypeAssignSet0, HeadTypeParams, VarId, Type).

:- pred type_assign_var_has_type(type_assign, headtypes, var, type,
				type_assign_set, type_assign_set).
:- mode type_assign_var_has_type(in, in, in, in, in, out) is det.

type_assign_var_has_type(TypeAssign0, HeadTypeParams, VarId, Type,
		TypeAssignSet0, TypeAssignSet) :-
	type_assign_get_var_types(TypeAssign0, VarTypes0),
	( %%% if some [VarType]
		map__search(VarTypes0, VarId, VarType)
	->
		( %%% if some [TypeAssign1]
			type_assign_unify_type(TypeAssign0, HeadTypeParams,
				VarType, Type, TypeAssign1)
		->
			TypeAssignSet = [TypeAssign1 | TypeAssignSet0]
		;
			TypeAssignSet = TypeAssignSet0
		)
	;
		map__set(VarTypes0, VarId, Type, VarTypes),
		type_assign_set_var_types(TypeAssign0, VarTypes, TypeAssign),
		TypeAssignSet = [TypeAssign | TypeAssignSet0]
	).

%-----------------------------------------------------------------------------%

	% type_assign_var_has_type_list(Vars, Types, TypeAssign, TypeInfo,
	%		TypeAssignSet0, TypeAssignSet):
	% 	Let TAs = { TA | TA is a an extension of TypeAssign
	%		    	 for which the types of the Vars unify with
	%		    	 their respective Types },
	% 	list__append(TAs, TypeAssignSet0, TypeAssignSet).

:- pred type_assign_var_has_type_list(list(var), list(type), type_assign,
			type_info, type_assign_set, type_assign_set).
:- mode type_assign_var_has_type_list(in, in, in, type_info_ui, in, out)
	is det.

type_assign_var_has_type_list([], [_|_], _, _, _, _) :-
	error("type_assign_var_has_type_list: length mis-match").
type_assign_var_has_type_list([_|_], [], _, _, _, _) :-
	error("type_assign_var_has_type_list: length mis-match").
type_assign_var_has_type_list([], [], TypeAssign, _,
		TypeAssignSet, [TypeAssign|TypeAssignSet]).
type_assign_var_has_type_list([Arg | Args], [Type | Types], TypeAssign0,
		TypeInfo, TypeAssignSet0, TypeAssignSet) :-
	type_info_get_head_type_params(TypeInfo, HeadTypeParams),
	type_assign_var_has_type(TypeAssign0, HeadTypeParams, Arg, Type,
		[], TypeAssignSet1),
	type_assign_list_var_has_type_list(TypeAssignSet1,
		Args, Types, TypeInfo, TypeAssignSet0, TypeAssignSet).

	% type_assign_list_var_has_type_list(TAs, Terms, Types, 
	%		TypeInfo, TypeAssignSet0, TypeAssignSet):
	% 	Let TAs2 = { TA | TA is a an extension of a member of TAs
	%		    	  for which the types of the Terms unify with
	%		    	  their respective Types },
	% 	list__append(TAs, TypeAssignSet0, TypeAssignSet).

:- pred type_assign_list_var_has_type_list(type_assign_set, list(var),
		list(type), type_info, type_assign_set, type_assign_set).
:- mode type_assign_list_var_has_type_list(in, in, in, type_info_ui, in, out)
	is det.

type_assign_list_var_has_type_list([], _, _, _) --> [].
type_assign_list_var_has_type_list([TA | TAs], Args, Types, TypeInfo) -->
	type_assign_var_has_type_list(Args, Types, TA, TypeInfo),
	type_assign_list_var_has_type_list(TAs, Args, Types, TypeInfo).
	
%-----------------------------------------------------------------------------%

	% Because we allow overloading, type-checking is NP-complete.
	% Rather than disallow it completely, we issue a warning
	% whenever "too much" overloading is used.  "Too much"
	% is arbitrarily defined as anthing which results in
	% more than 50 possible type assignments.

:- pred check_warn_too_much_overloading(type_info, type_info).
:- mode check_warn_too_much_overloading(type_info_di, type_info_uo) is det.

check_warn_too_much_overloading(TypeInfo0, TypeInfo) :-
	(
		type_info_get_warned_about_overloading(TypeInfo0,
			AlreadyWarned),
		AlreadyWarned = no,
		type_info_get_type_assign_set(TypeInfo0, TypeAssignSet),
		list__length(TypeAssignSet, Count),
		Count > 50
	->
		type_info_get_io_state(TypeInfo0, IOState0),
		report_warning_too_much_overloading(TypeInfo0,
			IOState0, IOState1),
		type_info_set_io_state(TypeInfo0, IOState1, TypeInfo1),
		type_info_set_warned_about_overloading(TypeInfo1, yes,
			TypeInfo)
	;
		TypeInfo = TypeInfo0
	).

%-----------------------------------------------------------------------------%

	% used for debugging

:- pred checkpoint(string, type_info, type_info).
:- mode checkpoint(in, type_info_di, type_info_uo) is det.

checkpoint(Msg, T0, T) :-
	type_info_get_io_state(T0, I0),
	globals__io_lookup_bool_option(debug_types, DoCheckPoint, I0, I1),
	( DoCheckPoint = yes ->
		checkpoint_2(Msg, T0, I1, I)
	;	
		I = I1
	),
	type_info_set_io_state(T0, I, T).

:- pred checkpoint_2(string, type_info, io__state, io__state).
:- mode checkpoint_2(in, type_info_no_io, di, uo) is det.

checkpoint_2(Msg, T0) -->
	io__write_string("At "),
	io__write_string(Msg),
	io__write_string(": "),
	globals__io_lookup_bool_option(statistics, Statistics),
	maybe_report_stats(Statistics),
	io__write_string("\n"),
	{ type_info_get_type_assign_set(T0, TypeAssignSet) },
	(
		{ Statistics = yes },
		{ TypeAssignSet = [TypeAssign | _] }
	->
		{ type_assign_get_var_types(TypeAssign, VarTypes) },
		checkpoint_tree_stats("\t`var -> type' map", VarTypes),
		{ type_assign_get_type_bindings(TypeAssign, TypeBindings) },
		checkpoint_tree_stats("\t`type var -> type' map", TypeBindings)
	;
		[]
	),
	{ type_info_get_varset(T0, VarSet) },
	write_type_assign_set(TypeAssignSet, VarSet).

:- pred checkpoint_tree_stats(string, map(_K, _V), io__state, io__state).
:- mode checkpoint_tree_stats(in, in, di, uo) is det.

checkpoint_tree_stats(Description, Tree) -->
        { tree234__count(Tree, Count) },
        %{ tree234__depth(Tree, Depth) },
        io__write_string(Description),
        io__write_string(": count = "),
        io__write_int(Count),
        %io__write_string(", depth = "),
        %io__write_int(Depth),
        io__write_string("\n").

%-----------------------------------------------------------------------------%

	% Type check a unification.
	% Get the type assignment set from the type info and then just
	% iterate over all the possible type assignments.

:- pred typecheck_unification(var, unify_rhs, unify_rhs, type_info, type_info).
:- mode typecheck_unification(in, in, out, type_info_di, type_info_uo) is det.

:- typecheck_unification(_, Y, _, _, _) when Y.

typecheck_unification(X, var(Y), var(Y)) -->
	typecheck_unify_var_var(X, Y).
typecheck_unification(X, functor(F, As), functor(F, As)) -->
	typecheck_unify_var_functor(X, F, As).
typecheck_unification(_X, lambda_goal(Vars, Goal0), lambda_goal(Vars, Goal)) -->
	typecheck_goal(Goal0, Goal),
	{ error("type checking of lambda terms not implemented") }.
	% LambdaType = term__functor("pred", VarTypes, _)
 	% typecheck_var_has_type(X, LambdaType).

:- pred typecheck_unify_var_var(var, var, type_info, type_info).
:- mode typecheck_unify_var_var(in, in, type_info_di, type_info_uo) is det.

typecheck_unify_var_var(X, Y, TypeInfo0, TypeInfo) :-
	type_info_get_type_assign_set(TypeInfo0, TypeAssignSet0),
	typecheck_unify_var_var_2(TypeAssignSet0, X, Y, TypeInfo0,
			[], TypeAssignSet),
	( TypeAssignSet = [], TypeAssignSet0 \= [] ->
		type_info_get_io_state(TypeInfo0, IOState0),
		report_error_unif_var_var(TypeInfo0, X, Y, TypeAssignSet0,
					IOState0, IOState1),
		type_info_set_io_state(TypeInfo0, IOState1, TypeInfo1),
		type_info_set_found_error(TypeInfo1, yes, TypeInfo)
	;
		type_info_set_type_assign_set(TypeInfo0, TypeAssignSet,
			TypeInfo)
	).

:- pred typecheck_unify_var_functor(var, const, list(var),
					type_info, type_info).
:- mode typecheck_unify_var_functor(in, in, in, type_info_di, type_info_uo)
	is det.

typecheck_unify_var_functor(Var, Functor, Args, TypeInfo0, TypeInfo) :-
	%
	% get the list of possible constructors that match this functor/arity
	% if there aren't any, report an undefined constructor error
	%
	list__length(Args, Arity),
	type_info_get_ctor_list(TypeInfo0, Functor, Arity, ConsDefnList),
	( ConsDefnList = [] ->
		type_info_get_io_state(TypeInfo0, IOState0),
		report_error_undef_cons(TypeInfo0, Functor, Arity, 
					IOState0, IOState1),
		type_info_set_io_state(TypeInfo0, IOState1, TypeInfo1),
		type_info_set_found_error(TypeInfo1, yes, TypeInfo)
	;
		%
		% produce the ConsTypeAssignSet, which is essentially the
		% cross-product of the TypeAssignSet0 and the ConsDefnList
		%
		type_info_get_type_assign_set(TypeInfo0, TypeAssignSet0),
		typecheck_unify_var_functor_get_ctors(TypeAssignSet0,
			TypeInfo0, ConsDefnList, [], ConsTypeAssignSet),
		( ConsTypeAssignSet = [], TypeAssignSet0 \= [] ->
			% this should never happen, since undefined ctors
			% should be caught by the check just above
			error("typecheck_unify_var_functor: undefined cons?")
		;
			true
		),

		%
		% check that the type of the functor matches the type
		% of the variable
		%
		typecheck_functor_type( ConsTypeAssignSet, Var,
			TypeInfo0, [], ArgsTypeAssignSet),
		( ArgsTypeAssignSet = [], ConsTypeAssignSet \= [] ->
			type_info_get_io_state(TypeInfo0, IOState0),
			report_error_functor_type(TypeInfo0,
				Var, ConsDefnList, Functor, Arity,
				TypeAssignSet0,
				IOState0, IOState1),
			type_info_set_io_state(TypeInfo0, IOState1, TypeInfo1),
			type_info_set_found_error(TypeInfo1, yes, TypeInfo2)
		;
			TypeInfo2 = TypeInfo0
		),

		%
		% check that the type of the arguments of the functor matches
		% their expected type for this functor
		%
		typecheck_functor_arg_types( ArgsTypeAssignSet, Args,
			TypeInfo2, [], TypeAssignSet),
		( TypeAssignSet = [], ArgsTypeAssignSet \= [] ->
			type_info_get_io_state(TypeInfo2, IOState2),
			report_error_functor_arg_types(TypeInfo2,
				Var, ConsDefnList, Functor, Args,
				TypeAssignSet0,
				IOState2, IOState3),
			type_info_set_io_state(TypeInfo2, IOState3, TypeInfo3),
			type_info_set_found_error(TypeInfo3, yes, TypeInfo4)
		;
			TypeInfo4 = TypeInfo2
		),
		%
		% if we encountered an error, continue checking with the
		% original type assign set
		%
		( TypeAssignSet = [] ->
			type_info_set_type_assign_set(TypeInfo4, TypeAssignSet0,
					TypeInfo)
		;
			type_info_set_type_assign_set(TypeInfo4, TypeAssignSet,
					TypeInfo)
		)
	).

	% typecheck_unify_var_functor_get_ctors(TypeAssignSet, TypeInfo,
	%	ConsDefns):
	%	
	% Iterate over all the different possible type assignments and
	% constructor definitions.
	% For each type assignment in `TypeAssignSet', and constructor
	% definition in `ConsDefns', produce a pair 
	%
	%	TypeAssign - cons_type(Type, ArgTypes)
	%
	% where `cons_type(Type, ArgTypes)' records one of the possible
	% types for the constructor in `ConsDefns', and where `TypeAssign' is
	% the type assignment renamed apart from the types of the constructors.

:- type cons_type ---> cons_type(type, list(type)).
:- type cons_type_assign_set == list(pair(type_assign, cons_type)).

:- type args_type_assign_set == list(pair(type_assign, list(type))).

:- pred typecheck_unify_var_functor_get_ctors(type_assign_set,
				type_info, list(cons_type_info),
				cons_type_assign_set, cons_type_assign_set).
:- mode typecheck_unify_var_functor_get_ctors(in, in, in, in, out) is det.

	% Iterate over the type assign sets

typecheck_unify_var_functor_get_ctors([], _, _) --> [].
typecheck_unify_var_functor_get_ctors([TypeAssign | TypeAssigns], TypeInfo,
		ConsDefns) -->
	typecheck_unify_var_functor_get_ctors_2(ConsDefns, TypeInfo,
		TypeAssign),
	typecheck_unify_var_functor_get_ctors(TypeAssigns, TypeInfo, ConsDefns).

	% Iterate over all the different cons defns.

:- pred typecheck_unify_var_functor_get_ctors_2(list(cons_type_info), type_info,
				type_assign,
				cons_type_assign_set, cons_type_assign_set).
:- mode typecheck_unify_var_functor_get_ctors_2(in, in, in, in, out) is det.

typecheck_unify_var_functor_get_ctors_2([], _, _) --> [].
typecheck_unify_var_functor_get_ctors_2([ConsDefn | ConsDefns], TypeInfo,
					TypeAssign0) -->
	{ get_cons_stuff(ConsDefn, TypeAssign0, TypeInfo,
			ConsType, ArgTypes, TypeAssign1) },
	list__append([TypeAssign1 - cons_type(ConsType, ArgTypes)]),
	typecheck_unify_var_functor_get_ctors_2(ConsDefns, TypeInfo,
			TypeAssign0).

	% typecheck_functor_type(ConsTypeAssignSet, Var, ...):
	%
	% For each possible cons type assignment in `ConsTypeAssignSet',
	% for each possible constructor type,
	% check that the type of `Var' matches this type.

:- pred typecheck_functor_type(cons_type_assign_set, var, type_info,
				args_type_assign_set, args_type_assign_set).
:- mode typecheck_functor_type(in, in, type_info_ui, in, out) is det.

typecheck_functor_type([], _, _) --> [].
typecheck_functor_type([TypeAssign - ConsType | ConsTypeAssigns],
			Var, TypeInfo) -->
	{ ConsType = cons_type(Type, ArgTypes) },
	type_assign_check_functor_type(Type, ArgTypes, Var,
					TypeAssign, TypeInfo),
	typecheck_functor_type(ConsTypeAssigns, Var, TypeInfo).

	% typecheck_functor_arg_types(ConsTypeAssignSet, Var, Args, ...):
	%
	% For each possible cons type assignment in `ConsTypeAssignSet',
	% for each possible constructor argument types,
	% check that the types of `Args' matches these types.

:- pred typecheck_functor_arg_types(args_type_assign_set, list(var),
				type_info, type_assign_set, type_assign_set).
:- mode typecheck_functor_arg_types(in, in, type_info_ui, in, out)
	is det.

typecheck_functor_arg_types([], _, _) --> [].
typecheck_functor_arg_types([TypeAssign - ArgTypes | ConsTypeAssigns],
			Args, TypeInfo) -->
	type_assign_var_has_type_list(Args, ArgTypes, TypeAssign, TypeInfo),
	typecheck_functor_arg_types(ConsTypeAssigns, Args, TypeInfo).

	% iterate over all the possible type assignments.

:- pred typecheck_unify_var_var_2(type_assign_set, var, var,
				type_info, type_assign_set, type_assign_set).
:- mode typecheck_unify_var_var_2(in, in, in, type_info_ui, in, out) is det.

typecheck_unify_var_var_2([], _, _, _) --> [].
typecheck_unify_var_var_2([TypeAssign0 | TypeAssigns0], X, Y, TypeInfo) -->
	type_assign_unify_var_var(X, Y, TypeAssign0, TypeInfo),
	typecheck_unify_var_var_2(TypeAssigns0, X, Y, TypeInfo).
	
%-----------------------------------------------------------------------------%

	% Type-check the unification of two variables,
	% and update the type assignment.
	% TypeAssign0 is the type assignment we are updating,
	% TypeAssignSet0 is an accumulator for the list of possible
	% type assignments so far, and TypeAssignSet is TypeAssignSet plus
	% any type assignment(s) resulting from TypeAssign0 and this
	% unification.

:- pred type_assign_unify_var_var(var, var, type_assign, type_info,
				type_assign_set, type_assign_set).
:- mode type_assign_unify_var_var(in, in, in, type_info_ui, in, out) is det.

type_assign_unify_var_var(X, Y, TypeAssign0, TypeInfo, TypeAssignSet0,
			TypeAssignSet) :-
	type_assign_get_var_types(TypeAssign0, VarTypes0),
	(
		map__search(VarTypes0, X, TypeX)
	->
		(
			map__search(VarTypes0, Y, TypeY)
		->
			% both X and Y already have types - just
			% unify their types
			type_info_get_head_type_params(TypeInfo,
					HeadTypeParams),
			( 
				type_assign_unify_type(TypeAssign0,
					HeadTypeParams, TypeX, TypeY,
					TypeAssign3)
			->
				TypeAssignSet = [TypeAssign3 | TypeAssignSet0]
			;
				TypeAssignSet = TypeAssignSet0
			)
		;
			% Y is a fresh variable which hasn't been
			% assigned a type yet
			map__set(VarTypes0, Y, TypeX, VarTypes),
			type_assign_set_var_types(TypeAssign0, VarTypes,
				TypeAssign),
			TypeAssignSet = [TypeAssign | TypeAssignSet0]
		)
	;
		(
			map__search(VarTypes0, Y, TypeY)
		->
			% X is a fresh variable which hasn't been
			% assigned a type yet
			map__set(VarTypes0, X, TypeY, VarTypes),
			type_assign_set_var_types(TypeAssign0, VarTypes,
				TypeAssign),
			TypeAssignSet = [TypeAssign | TypeAssignSet0]
		;
			% both X and Y are fresh variables -
			% introduce a fresh type variable to represent
			% their type
			type_assign_get_typevarset(TypeAssign0, TypeVarSet0),
			varset__new_var(TypeVarSet0, TypeVar, TypeVarSet),
			type_assign_set_typevarset(TypeAssign0, TypeVarSet,
				TypeAssign1),
			Type = term__variable(TypeVar),
			map__set(VarTypes0, X, Type, VarTypes1),
			map__set(VarTypes1, Y, Type, VarTypes),
			type_assign_set_var_types(TypeAssign1, VarTypes,
				TypeAssign),
			TypeAssignSet = [TypeAssign | TypeAssignSet0]
		)
	).

%-----------------------------------------------------------------------------%

:- pred type_assign_check_functor_type(type, list(type), 
		var, type_assign, type_info,
		args_type_assign_set, args_type_assign_set).
:- mode type_assign_check_functor_type(in, in, in, in, type_info_ui,
		in, out) is det.

type_assign_check_functor_type(ConsType, ArgTypes, Y, TypeAssign1,
		TypeInfo, TypeAssignSet0, TypeAssignSet) :-

		% unify the type of Var with the type of the constructor
	type_assign_get_var_types(TypeAssign1, VarTypes0),
	( %%% if some [TypeY]
		map__search(VarTypes0, Y, TypeY)
	->
		type_info_get_head_type_params(TypeInfo, HeadTypeParams),
		( %%% if some [TypeAssign2]
			type_assign_unify_type(TypeAssign1, HeadTypeParams,
					ConsType, TypeY, TypeAssign2)
		->
			TypeAssignSet = [TypeAssign2 - ArgTypes |
					TypeAssignSet0]
		;
			TypeAssignSet = TypeAssignSet0
		)
	;
		map__set(VarTypes0, Y, ConsType, VarTypes),
		type_assign_set_var_types(TypeAssign1, VarTypes, TypeAssign3),
		TypeAssignSet = [TypeAssign3 - ArgTypes | TypeAssignSet0]
	).

%-----------------------------------------------------------------------------%

	% Given an cons_type_info, construct a type for the
	% constructor and a list of types of the arguments,
	% suitable renamed apart from the current type_assign's
	% typevarset.

:- pred get_cons_stuff(cons_type_info, type_assign, type_info,
			type, list(type), type_assign).
:- mode get_cons_stuff(in, in, in, out, out, out) is det.

get_cons_stuff(ConsDefn, TypeAssign0, _TypeInfo, ConsType, ArgTypes,
			TypeAssign) :-

	ConsDefn = cons_type_info(ConsTypeVarSet, ConsType0, ArgTypes0),

	% Rename apart the type vars in the type of the constructor
	% and the types of it's arguments.
	% (Optimize the common case of a non-polymorphic type)

	( ConsType0 = term__functor(_, [], _) ->
		ConsType = ConsType0,
		ArgTypes = ArgTypes0,
		TypeAssign = TypeAssign0
	;
		type_assign_rename_apart(TypeAssign0, ConsTypeVarSet,
			[ConsType0 | ArgTypes0],
			TypeAssign1, [ConsType1 | ArgTypes1])
	->
		ConsType = ConsType1,
		ArgTypes = ArgTypes1,
		TypeAssign = TypeAssign1
	;
		error("get_cons_stuff: type_assign_rename_apart failed")
	).

%-----------------------------------------------------------------------------%

	% Unify (with occurs check) two types in a type assignment 
	% and update the type bindings.

:- pred type_assign_unify_type(type_assign, headtypes, type, type, type_assign).
:- mode type_assign_unify_type(in, in, in, in, out) is semidet.

type_assign_unify_type(TypeAssign0, HeadTypeParams, X, Y, TypeAssign) :-
	type_assign_get_type_bindings(TypeAssign0, TypeBindings0),
	type_unify(X, Y, HeadTypeParams, TypeBindings0, TypeBindings),
	type_assign_set_type_bindings(TypeAssign0, TypeBindings, TypeAssign).

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

	% XXX - At the moment we don't check for circular equivalence types.
	% (If they aren't used, the compiler will probably not
	% detect the error; if they are, it will probably go into
	% an infinite loop).

:- pred check_circular_types(module_info, module_info, io__state, io__state).
:- mode check_circular_types(in, out, di, uo) is det.

check_circular_types(Module0, Module) -->
	{ Module = Module0 }.

/**** JUNK
	{ module_info_types(Module0, Types0 },
	{ map__keys(Types0, TypeIds) },
	check_circular_types_2(TypeIds, Types0, Types),
	{ module_info_set_types(Module0, Types, Module) }.

check_circular_types_2([], Types, Types) --> [].
check_circular_types_2([TypeId | TypeIds], Types0, Types) -->

JUNK ****/
	
%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

	% builtin_atomic_type(Const, TypeName)
	%	If Const is a constant of a builtin atomic type,
	%	instantiates TypeName to the name of that type,
	%	otherwise fails.

:- pred builtin_atomic_type(const, string).
:- mode builtin_atomic_type(in, out) is semidet.

builtin_atomic_type(term__integer(_), "int").
builtin_atomic_type(term__float(_), "float").
builtin_atomic_type(term__string(_), "string").
builtin_atomic_type(term__atom(String), "character") :-
	string__char_to_string(_, String).

	% builtin_pred_type(TypeInfo, Functor, Arity, PredConsInfoList) :
	%	If Functor/Arity is a constant of a pred type,
	%	instantiates the output parameters, otherwise fails.
	%
	%	Instantiates PredConsInfoList to the set of cons_type_info
	%	structures for each predicate with name `Functor' and arity
	%	greater than or equal to Arity.
	%
	%	For example, functor `map__search/1' has type `pred(K,V)'
	%	(hence PredTypeParams = [K,V]) and argument types [map(K,V)].


:- pred builtin_pred_type(type_info, const, int, list(cons_type_info)).
:- mode builtin_pred_type(type_info_ui, in, in, out)
	is semidet.

builtin_pred_type(TypeInfo, Functor, Arity, PredConsInfoList) :-
	Functor = term__atom(Name),
	type_info_get_module_info(TypeInfo, ModuleInfo),
	module_info_get_predicate_table(ModuleInfo, PredicateTable),
	( predicate_table_search_name(PredicateTable, Name, PredIdList) ->
		predicate_table_get_preds(PredicateTable, Preds),
		make_pred_cons_info_list(PredIdList, Preds, Arity,
			ModuleInfo, [], PredConsInfoList)
	;
		PredConsInfoList = []
	).

:- pred make_pred_cons_info_list(list(pred_id), pred_table, int, module_info,
				list(cons_type_info), list(cons_type_info)).
:- mode make_pred_cons_info_list(in, in, in, in, in, out) is det.

make_pred_cons_info_list([], _PredTable, _Arity, _ModuleInfo, L, L).
make_pred_cons_info_list([PredId|PredIds], PredTable, Arity, ModuleInfo,
		L0, L) :-
	make_pred_cons_info(PredId, PredTable, Arity, ModuleInfo, L0, L1),
	make_pred_cons_info_list(PredIds, PredTable, Arity, ModuleInfo, L1, L).

:- type cons_type_info ---> cons_type_info(tvarset, type, list(type)).

:- pred make_pred_cons_info(pred_id, pred_table, int, module_info,
				list(cons_type_info), list(cons_type_info)).
:- mode make_pred_cons_info(in, in, in, in, in, out) is det.

make_pred_cons_info(PredId, PredTable, FuncArity, ModuleInfo, L0, L) :-
	map__lookup(PredTable, PredId, PredInfo),
	predicate_arity(ModuleInfo, PredId, PredArity),
	(
		PredArity >= FuncArity
	->
		pred_info_arg_types(PredInfo, PredTypeVarSet, CompleteArgTypes),
		(
			list__split_list(FuncArity, CompleteArgTypes,
				ArgTypes, PredTypeParams)
		->
			term__context_init("<builtin>", 0, Context),
			PredType = term__functor(term__atom("pred"),
					PredTypeParams, Context),
			ConsInfo = cons_type_info(PredTypeVarSet, PredType,
					ArgTypes),
			L = [ConsInfo | L0]
		;
			error("make_pred_cons_info: split_list failed")
		)
	;
		L = L0
	).

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

	% The type_info data structure and access predicates.

:- type type_info
	---> type_info(
			io__state, 	% The io state
			
			module_info, 	% The global symbol tables

			pred_call_id,	% The pred_call_id of the pred
					% being called (if any)

			int,		% The argument number within
					% a pred call 

			pred_id,	% The pred we're checking

			term__context,	% The context of the goal
					% we're checking

			unify_context,	% The original source of the
					% unification we're checking

			varset,		% Variable names

			type_assign_set,
					% This is the main piece of
					% information that we are
					% computing and which gets
					% updated as we go along

			bool,		% did we find any type errors?

			headtypes,	% Head type params

			bool		% Have we already warned about
					% highly ambiguous overloading?
		).

	% The normal inst of a type_info struct: ground, with
	% the io_state and the struct itself unique, but with
	% multiple references allowed for the other parts.

:- inst uniq_type_info	=	bound_unique(
					type_info(
						ground_unique, ground,
						ground, ground, ground, ground,
						ground, ground, ground, ground,
						ground, ground
					)
				).

:- mode type_info_uo :: (free -> uniq_type_info).
:- mode type_info_ui :: (uniq_type_info -> uniq_type_info).
:- mode type_info_di :: (uniq_type_info -> dead).

	% Some fiddly modes used when we want to extract
	% the io_state from a type_info struct and then put it back again.

:- inst type_info_no_io	=	bound_unique(
					type_info(
						dead, ground,
						ground, ground, ground, ground,
						ground, ground, ground, ground,
						ground, ground
					)
				).

:- mode type_info_get_io_state 	:: (uniq_type_info -> type_info_no_io).
:- mode type_info_no_io 	:: (type_info_no_io -> type_info_no_io).
:- mode type_info_set_io_state 	:: (type_info_no_io -> dead).

%-----------------------------------------------------------------------------%

:- pred type_info_init(io__state, module_info, pred_id, varset,
			varset, map(var, type), headtypes, type_info).
:- mode type_info_init(di, in, in, in, in, in, in, type_info_uo) is det.

type_info_init(IOState, ModuleInfo, PredId, TypeVarSet, VarSet,
		VarTypes, HeadTypeParams, TypeInfo) :-
	CallPredId = unqualified("") / 0,
	term__context_init(Context),
	map__init(TypeBindings),
	FoundTypeError = no,
	WarnedAboutOverloading = no,
	TypeInfo = type_info(
		IOState, ModuleInfo, CallPredId, 0, PredId, Context,
		unify_context(explicit, []),
		VarSet, [type_assign(VarTypes, TypeVarSet, TypeBindings)],
		FoundTypeError, HeadTypeParams, WarnedAboutOverloading
	).

%-----------------------------------------------------------------------------%

:- pred type_info_get_io_state(type_info, io__state).
:- mode type_info_get_io_state(type_info_get_io_state, uo) is det.

type_info_get_io_state(type_info(IOState,_,_,_,_,_,_,_,_,_,_,_), IOState).

%-----------------------------------------------------------------------------%

:- pred type_info_set_io_state(type_info, io__state, type_info).
:- mode type_info_set_io_state(type_info_set_io_state, ui, type_info_uo) is det.

type_info_set_io_state( type_info(_,B,C,D,E,F,G,H,I,J,K,L), IOState,
			type_info(IOState,B,C,D,E,F,G,H,I,J,K,L)).

%-----------------------------------------------------------------------------%

:- pred type_info_get_module_name(type_info, string).
:- mode type_info_get_module_name(in, out) is det.

type_info_get_module_name(type_info(_,ModuleInfo,_,_,_,_,_,_,_,_,_,_), Name) :-
	module_info_name(ModuleInfo, Name).

%-----------------------------------------------------------------------------%

:- pred type_info_get_module_info(type_info, module_info).
:- mode type_info_get_module_info(in, out) is det.

type_info_get_module_info(type_info(_,ModuleInfo,_,_,_,_,_,_,_,_,_,_),
			ModuleInfo).

%-----------------------------------------------------------------------------%

:- pred type_info_get_preds(type_info, predicate_table).
:- mode type_info_get_preds(in, out) is det.

type_info_get_preds(type_info(_,ModuleInfo,_,_,_,_,_,_,_,_,_,_), Preds) :-
	module_info_get_predicate_table(ModuleInfo, Preds).

%-----------------------------------------------------------------------------%

:- pred type_info_get_types(type_info, type_table).
:- mode type_info_get_types(in, out) is det.

type_info_get_types(type_info(_,ModuleInfo,_,_,_,_,_,_,_,_,_,_), Types) :-
	module_info_types(ModuleInfo, Types).

%-----------------------------------------------------------------------------%

:- pred type_info_get_ctors(type_info, cons_table).
:- mode type_info_get_ctors(in, out) is det.

type_info_get_ctors(type_info(_,ModuleInfo,_,_,_,_,_,_,_,_,_,_), Ctors) :-
	module_info_ctors(ModuleInfo, Ctors).

%-----------------------------------------------------------------------------%

:- pred type_info_get_called_predid(type_info, pred_call_id).
:- mode type_info_get_called_predid(in, out) is det.

type_info_get_called_predid(type_info(_,_,PredId,_,_,_,_,_,_,_,_,_), PredId).

%-----------------------------------------------------------------------------%

:- pred type_info_set_called_predid(type_info, pred_call_id, type_info).
:- mode type_info_set_called_predid(type_info_di, in, type_info_uo) is det.

type_info_set_called_predid(type_info(A,B,_,D,E,F,G,H,I,J,K,L), PredCallId,
			   type_info(A,B,PredCallId,D,E,F,G,H,I,J,K,L)).

%-----------------------------------------------------------------------------%

:- pred type_info_get_arg_num(type_info, int).
:- mode type_info_get_arg_num(in, out) is det.

type_info_get_arg_num(type_info(_,_,_,ArgNum,_,_,_,_,_,_,_,_), ArgNum).

%-----------------------------------------------------------------------------%

:- pred type_info_set_arg_num(int, type_info, type_info).
:- mode type_info_set_arg_num(in, type_info_di, type_info_uo) is det.

type_info_set_arg_num(ArgNum, type_info(A,B,C,_,     E,F,G,H,I,J,K,L),
			     type_info(A,B,C,ArgNum,E,F,G,H,I,J,K,L)).

%-----------------------------------------------------------------------------%

:- pred type_info_get_predid(type_info, pred_id).
:- mode type_info_get_predid(in, out) is det.

type_info_get_predid(type_info(_,_,_,_,PredId,_,_,_,_,_,_,_), PredId).

%-----------------------------------------------------------------------------%

:- pred type_info_get_context(type_info, term__context).
:- mode type_info_get_context(in, out) is det.

type_info_get_context(type_info(_,_,_,_,_,Context,_,_,_,_,_,_), Context).

%-----------------------------------------------------------------------------%

:- pred type_info_set_context(term__context, type_info, type_info).
:- mode type_info_set_context(in, type_info_di, type_info_uo) is det.

type_info_set_context(Context, type_info(A,B,C,D,E,_,G,H,I,J,K,L),
			type_info(A,B,C,D,E,Context,G,H,I,J,K,L)).

%-----------------------------------------------------------------------------%

:- pred type_info_get_unify_context(type_info, unify_context).
:- mode type_info_get_unify_context(in, out) is det.

type_info_get_unify_context(type_info(_,_,_,_,_,_,UnifyContext,_,_,_,_,_),
				UnifyContext).

%-----------------------------------------------------------------------------%

:- pred type_info_set_unify_context(unify_context, type_info, type_info).
:- mode type_info_set_unify_context(in, type_info_di, type_info_uo) is det.

type_info_set_unify_context(UnifyContext, type_info(A,B,C,D,E,F,_,H,I,J,K,L),
			type_info(A,B,C,D,E,F,UnifyContext,H,I,J,K,L)).

%-----------------------------------------------------------------------------%

:- pred type_info_get_varset(type_info, varset).
:- mode type_info_get_varset(in, out) is det.

type_info_get_varset(type_info(_,_,_,_,_,_,_,VarSet,_,_,_,_), VarSet).

%-----------------------------------------------------------------------------%

:- pred type_info_get_type_assign_set(type_info, type_assign_set).
:- mode type_info_get_type_assign_set(in, out) is det.

type_info_get_type_assign_set(type_info(_,_,_,_,_,_,_,_,TypeAssignSet,_,_,_),
			TypeAssignSet).

%-----------------------------------------------------------------------------%

:- pred type_info_get_final_info(type_info, tvarset, map(var, type)).
:- mode type_info_get_final_info(in, out, out) is det.

type_info_get_final_info(TypeInfo, TypeVarSet, VarTypes) :-
	type_info_get_type_assign_set(TypeInfo, TypeAssignSet),
	( TypeAssignSet = [TypeAssign | _] ->
		type_assign_get_typevarset(TypeAssign, TypeVarSet),
		type_assign_get_var_types(TypeAssign, VarTypes0),
		type_assign_get_type_bindings(TypeAssign, TypeBindings),
		map__keys(VarTypes0, Vars),
		expand_types(Vars, TypeBindings, VarTypes0, VarTypes)
	;
		error("internal error in type_info_get_vartypes")
	).

	% fully expand the types of the variables by applying the type
	% bindings

:- pred expand_types(list(var), tsubst, map(var, type), map(var, type)).
:- mode expand_types(in, in, in, out) is det.

expand_types([], _, VarTypes, VarTypes).
expand_types([Var | Vars], TypeSubst, VarTypes0, VarTypes) :-
	map__lookup(VarTypes0, Var, Type0),
	term__apply_rec_substitution(Type0, TypeSubst, Type),
	map__set(VarTypes0, Var, Type, VarTypes1),
	expand_types(Vars, TypeSubst, VarTypes1, VarTypes).

%-----------------------------------------------------------------------------%

:- pred type_info_set_type_assign_set(type_info, type_assign_set, type_info).
:- mode type_info_set_type_assign_set(type_info_di, in, type_info_uo) is det.

type_info_set_type_assign_set( type_info(A,B,C,D,E,F,G,H,_,J,K,L),
		TypeAssignSet, type_info(A,B,C,D,E,F,G,H,TypeAssignSet,J,K,L)).

%-----------------------------------------------------------------------------%

:- pred type_info_get_found_error(type_info, bool).
:- mode type_info_get_found_error(type_info_ui, out) is det.

type_info_get_found_error(type_info(_,_,_,_,_,_,_,_,_,FoundError,_,_),
			FoundError).

%-----------------------------------------------------------------------------%

:- pred type_info_set_found_error(type_info, bool, type_info).
:- mode type_info_set_found_error(type_info_di, in, type_info_uo) is det.

type_info_set_found_error( type_info(A,B,C,D,E,F,G,H,I,_,K,L), FoundError,
			type_info(A,B,C,D,E,F,G,H,I,FoundError,K,L)).

%-----------------------------------------------------------------------------%

:- pred type_info_get_head_type_params(type_info, headtypes).
:- mode type_info_get_head_type_params(type_info_ui, out) is det.

type_info_get_head_type_params( type_info(_,_,_,_,_,_,_,_,_,_,HeadTypeParams,_),
				HeadTypeParams).

%-----------------------------------------------------------------------------%

:- pred type_info_set_head_type_params(type_info, headtypes, type_info).
:- mode type_info_set_head_type_params(type_info_di, in, type_info_uo) is det.

type_info_set_head_type_params( type_info(A,B,C,D,E,F,G,H,I,J,_,L),
			HeadTypeParams,
			type_info(A,B,C,D,E,F,G,H,I,J,HeadTypeParams,L)).

%-----------------------------------------------------------------------------%

:- pred type_info_get_warned_about_overloading(type_info, bool).
:- mode type_info_get_warned_about_overloading(type_info_ui, out) is det.

type_info_get_warned_about_overloading(type_info(_,_,_,_,_,_,_,_,_,_,_,Warned),
				Warned).

%-----------------------------------------------------------------------------%

:- pred type_info_set_warned_about_overloading(type_info, bool, type_info).
:- mode type_info_set_warned_about_overloading(type_info_di, in, type_info_uo)
	is det.

type_info_set_warned_about_overloading( type_info(A,B,C,D,E,F,G,H,I,J,K,_),
			Warned,
			type_info(A,B,C,D,E,F,G,H,I,J,K,Warned)).

%-----------------------------------------------------------------------------%

:- pred type_info_get_ctor_list(type_info, const, int, list(cons_type_info)).
:- mode type_info_get_ctor_list(type_info_ui, in, in, out) is det.

type_info_get_ctor_list(TypeInfo, Functor, Arity, ConsInfoList) :-
	% Check if `Functor/Arity' has been defined as a constructor
	% in some discriminated union type(s).  This gives
	% us a list of possible cons_type_infos.
	type_info_get_ctors(TypeInfo, Ctors),
	(
		Functor = term__atom(Name),
		map__search(Ctors, cons(Name, Arity), HLDS_ConsDefnList)
	->
		convert_cons_defn_list(TypeInfo, HLDS_ConsDefnList,
			ConsInfoList0)
	;
		ConsInfoList0 = []
	),
	% Check if Functor is a constant of one of the builtin atomic
	% types (string, float, int, character).  If so, insert
	% the resulting cons_type_info at the start of the list.
	(
		Arity = 0,
		builtin_atomic_type(Functor, BuiltInTypeName)
	->
		term__context_init("<builtin>", 0, Context),
		ConsType = term__functor(term__atom(BuiltInTypeName), [],
				Context),
		varset__init(ConsTypeVarSet),
		ConsInfo = cons_type_info(ConsTypeVarSet, ConsType, []),
		ConsInfoList1 = [ConsInfo | ConsInfoList0]
	;
		ConsInfoList1 = ConsInfoList0
	),
	% Check if Functor is the name of a predicate which takes at least
	% Arity arguments.  If so, insert the resulting cons_type_info
	% at the start of the list.
	(
		builtin_pred_type(TypeInfo, Functor, Arity, PredConsInfoList)
	->
		list__append(ConsInfoList1, PredConsInfoList, ConsInfoList)
	;
		ConsInfoList = ConsInfoList1
	).

:- pred convert_cons_defn_list(type_info, list(hlds__cons_defn),
				list(cons_type_info)).
:- mode convert_cons_defn_list(type_info_ui, in, out) is det.

:- convert_cons_defn_list(_, L, _) when L.	% NU-Prolog indexing.

convert_cons_defn_list(_TypeInfo, [], []).
convert_cons_defn_list(TypeInfo, [X|Xs], [Y|Ys]) :-
	convert_cons_defn(TypeInfo, X, Y),
	convert_cons_defn_list(TypeInfo, Xs, Ys).

:- pred convert_cons_defn(type_info, hlds__cons_defn, cons_type_info).
:- mode convert_cons_defn(type_info_ui, in, out) is det.

convert_cons_defn(TypeInfo, HLDS_ConsDefn, ConsTypeInfo) :-
	HLDS_ConsDefn = hlds__cons_defn(ArgTypes, TypeId, Context),
	type_info_get_types(TypeInfo, Types),
	map__lookup(Types, TypeId, TypeDefn),
	TypeDefn = hlds__type_defn(ConsTypeVarSet, ConsTypeParams, _, _, _),
	TypeId = QualifiedName - _Arity,
	unqualify_name(QualifiedName, Name),
	ConsType = term__functor(term__atom(Name), ConsTypeParams, Context),
	ConsTypeInfo = cons_type_info(ConsTypeVarSet, ConsType, ArgTypes).

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

	% The type_assign and type_assign_set data structures.

:- type type_assign_set	==	list(type_assign).

:- type type_assign	--->	type_assign(
					map(var, type),		% var types
					tvarset,		% type names
					tsubst			% type bindings
				).

%-----------------------------------------------------------------------------%

	% Access predicates for the type_assign data structure.
	% Excruciatingly boring code.

:- pred type_assign_get_var_types(type_assign, map(var, type)).
:- mode type_assign_get_var_types(in, out) is det.

type_assign_get_var_types(type_assign(VarTypes, _, _), VarTypes).

%-----------------------------------------------------------------------------%

:- pred type_assign_get_typevarset(type_assign, tvarset).
:- mode type_assign_get_typevarset(in, out) is det.

type_assign_get_typevarset(type_assign(_, TypeVarSet, _), TypeVarSet).

%-----------------------------------------------------------------------------%

:- pred type_assign_get_type_bindings(type_assign, tsubst).
:- mode type_assign_get_type_bindings(in, out) is det.

type_assign_get_type_bindings(type_assign(_, _, TypeBindings), TypeBindings).

%-----------------------------------------------------------------------------%

:- pred type_assign_set_var_types(type_assign, map(var, type), type_assign).
:- mode type_assign_set_var_types(in, in, out) is det.

type_assign_set_var_types(type_assign(_, B, C), VarTypes,
			type_assign(VarTypes, B, C)).

%-----------------------------------------------------------------------------%

:- pred type_assign_set_typevarset(type_assign, tvarset, type_assign).
:- mode type_assign_set_typevarset(in, in, out) is det.

type_assign_set_typevarset(type_assign(A, _, C), TypeVarSet,
			type_assign(A, TypeVarSet, C)).

%-----------------------------------------------------------------------------%

:- pred type_assign_set_type_bindings(type_assign, tsubst, type_assign).
:- mode type_assign_set_type_bindings(in, in, out) is det.

type_assign_set_type_bindings(type_assign(A, B, _), TypeBindings,
			type_assign(A, B, TypeBindings)).

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%

% The next section contains predicates for writing error diagnostics.

%-----------------------------------------------------------------------------%

:- pred report_error_no_clauses(pred_id, pred_info,
					module_info, io__state, io__state).
:- mode report_error_no_clauses(in, in, in, di, uo) is det.

report_error_no_clauses(PredId, PredInfo, ModuleInfo) -->
	{ pred_info_context(PredInfo, Context) },
	prog_out__write_context(Context),
	io__write_string("Error: no clauses for "),
	hlds_out__write_pred_id(ModuleInfo, PredId),
	io__write_string("\n").

%-----------------------------------------------------------------------------%

:- pred report_warning_too_much_overloading(type_info, io__state, io__state).
:- mode report_warning_too_much_overloading(type_info_no_io, di, uo) is det.

report_warning_too_much_overloading(TypeInfo) -->
	{ type_info_get_context(TypeInfo, Context) },
	write_context_and_pred_id(TypeInfo),
	prog_out__write_context(Context),
	io__write_string("  warning: highly ambiguous overloading.\n"),
	globals__io_lookup_bool_option(verbose_errors, VerboseErrors),
	( { VerboseErrors = yes } ->
		prog_out__write_context(Context),
		io__write_string(
		    "  This may cause type-checking to be very slow.\n"
		),
		prog_out__write_context(Context),
		io__write_string(
		    "  It may also make your code difficult to understand.\n"
		)
	;
		[]
	).

%-----------------------------------------------------------------------------%

:- pred report_error_unif_var_var(type_info, var, var, type_assign_set,
					io__state, io__state).
:- mode report_error_unif_var_var(type_info_no_io, in, in, in, di, uo) is det.

report_error_unif_var_var(TypeInfo, X, Y, TypeAssignSet) -->

	{ type_info_get_context(TypeInfo, Context) },
	{ type_info_get_varset(TypeInfo, VarSet) },
	{ type_info_get_unify_context(TypeInfo, UnifyContext) },

	write_context_and_pred_id(TypeInfo),
	hlds_out__write_unify_context(UnifyContext, Context),

	prog_out__write_context(Context),
	io__write_string("  type error in unification of variable `"),
	mercury_output_var(X, VarSet),
	io__write_string("'\n"),
	prog_out__write_context(Context),
	io__write_string("  and variable `"),
	mercury_output_var(Y, VarSet),
	io__write_string("'.\n"),

	prog_out__write_context(Context),
	io__write_string("  `"),
	mercury_output_var(X, VarSet),
	io__write_string("'"),
	write_type_of_var(TypeInfo, TypeAssignSet, X),
	io__write_string(",\n"),

	prog_out__write_context(Context),
	io__write_string("  `"),
	mercury_output_var(Y, VarSet),
	io__write_string("'"),
	write_type_of_var(TypeInfo, TypeAssignSet, Y),
	io__write_string(".\n"),

	write_type_assign_set_msg(TypeAssignSet, VarSet).

:- pred report_error_functor_type(type_info, var, list(cons_type_info),
					const, int,
					type_assign_set,
					io__state, io__state).
:- mode report_error_functor_type(type_info_no_io, in, in, in, in, in,
					di, uo) is det.

report_error_functor_type(TypeInfo, Var, ConsDefnList, Functor, Arity,
		TypeAssignSet) -->

	{ type_info_get_context(TypeInfo, Context) },
	{ type_info_get_varset(TypeInfo, VarSet) },
	{ type_info_get_unify_context(TypeInfo, UnifyContext) },

	write_context_and_pred_id(TypeInfo),
	hlds_out__write_unify_context(UnifyContext, Context),

	prog_out__write_context(Context),
	io__write_string("  type error in unification of "),
	write_argument_name(VarSet, Var),
	io__write_string("\n"),
	prog_out__write_context(Context),
	io__write_string("  and "),
	write_functor_name(Functor, Arity),
	io__write_string(".\n"),

	prog_out__write_context(Context),
	io__write_string("  "),
	write_argument_name(VarSet, Var),
	write_type_of_var(TypeInfo, TypeAssignSet, Var),
	io__write_string(",\n"),

	prog_out__write_context(Context),
	io__write_string("  "),
	write_functor_name(Functor, Arity),
	write_type_of_functor(Functor, Arity, Context, ConsDefnList),
	io__write_string(".\n"),

	write_type_assign_set_msg(TypeAssignSet, VarSet).

:- pred report_error_functor_arg_types(type_info, var, list(cons_type_info),
					const, list(var),
					type_assign_set,
					io__state, io__state).
:- mode report_error_functor_arg_types(type_info_no_io, in, in, in, in, in,
					di, uo) is det.

report_error_functor_arg_types(TypeInfo, Var, ConsDefnList, Functor, Args,
		TypeAssignSet) -->

	{ type_info_get_context(TypeInfo, Context) },
	{ type_info_get_varset(TypeInfo, VarSet) },
	{ type_info_get_unify_context(TypeInfo, UnifyContext) },
	{ list__length(Args, Arity) },

	write_context_and_pred_id(TypeInfo),
	hlds_out__write_unify_context(UnifyContext, Context),

	prog_out__write_context(Context),
	io__write_string("  in unification of "),
	write_argument_name(VarSet, Var),
	io__write_string("\n"),
	prog_out__write_context(Context),
	io__write_string("  and term `"),
	hlds_out__write_functor(Functor, Args, VarSet),
	io__write_string("':\n"),
	prog_out__write_context(Context),
	io__write_string("  type error in argument(s) of "),
	write_functor_name(Functor, Arity),
	io__write_string(".\n"),

	prog_out__write_context(Context),
	io__write_string("  "),
	write_functor_name(Functor, Arity),
	write_type_of_functor(Functor, Arity, Context, ConsDefnList),

	write_types_of_vars(Args, VarSet, Context, TypeInfo, TypeAssignSet),

	write_type_assign_set_msg(TypeAssignSet, VarSet).

:- pred write_types_of_vars(list(var), varset, term__context, type_info,
				type_assign_set, io__state, io__state).
:- mode write_types_of_vars(in, in, in, type_info_ui, in, di, uo) is det.

write_types_of_vars([], _, _, _, _) -->
	io__write_string(".\n").
write_types_of_vars([Var | Vars], VarSet, Context, TypeInfo, TypeAssignSet) -->
	io__write_string(",\n"),
	prog_out__write_context(Context),
	io__write_string("  "),
	write_argument_name(VarSet, Var),
	write_type_of_var(TypeInfo, TypeAssignSet, Var),
	write_types_of_vars(Vars, VarSet, Context, TypeInfo, TypeAssignSet).

:- pred write_argument_name(varset, var, io__state, io__state).
:- mode write_argument_name(in, in, di, uo) is det.

write_argument_name(VarSet, VarId) -->
	( { varset__lookup_name(VarSet, VarId, _) } ->
		io__write_string("variable `"),
		mercury_output_var(VarId, VarSet),
		io__write_string("'")
	;
		io__write_string("argument")
	).

:- pred write_functor_name(const, int, io__state, io__state).
:- mode write_functor_name(in, in, di, uo) is det.

write_functor_name(Functor, Arity) -->
	( { Arity = 0 } ->
		io__write_string("constant `"),
		term_io__write_constant(Functor)
	;
		io__write_string("functor `"),
		term_io__write_constant(Functor),
		io__write_string("/"),
		io__write_int(Arity)
	),
	io__write_string("'").

:- pred write_type_of_var(type_info, type_assign_set, var,
				io__state, io__state).
:- mode write_type_of_var(type_info_no_io, in, in, di, uo) is det.

write_type_of_var(_TypeInfo, TypeAssignSet, Var) -->
	{ get_type_stuff(TypeAssignSet, Var, TypeStuffList) },
	( { TypeStuffList = [SingleTypeStuff] } ->
		{ SingleTypeStuff = type_stuff(VType, TVarSet, TBinding) },
		io__write_string(" has type `"),
		write_type_b(VType, TVarSet, TBinding),
		io__write_string("'")
	;
		io__write_string(" has overloaded type { "),
		write_type_stuff_list(TypeStuffList),
		io__write_string(" }")
	).

:- pred write_type_of_functor(const, int, term__context, list(cons_type_info),
				io__state, io__state).
:- mode write_type_of_functor(in, in, in, in, di, uo) is det.

write_type_of_functor(Functor, Arity, Context, ConsDefnList) -->
	( { ConsDefnList = [SingleDefn] } ->
		io__write_string(" has type "),
		( { Arity \= 0 } ->
			io__write_string("\n"),
			prog_out__write_context(Context),
			io__write_string("  `")
		;
			io__write_string("`")
		),
		write_cons_type(SingleDefn, Functor, Context),
		io__write_string("'")
	;
		io__write_string(" has overloaded type\n"),
		prog_out__write_context(Context),
		io__write_string("  { "),
		write_cons_type_list(ConsDefnList, Functor, Arity, Context),
		io__write_string(" }")
	).
		
:- pred write_cons_type(cons_type_info, const, term__context,
			io__state, io__state).
:- mode write_cons_type(in, in, in, di, uo) is det.

write_cons_type(cons_type_info(TVarSet, ConsType, ArgTypes), Functor, Context)
		-->
	( { ArgTypes \= [] } ->
		{ Term = term__functor(Functor, ArgTypes, Context) },
		mercury_output_term(Term, TVarSet),
		io__write_string(" :: ")
	;
		[]
	),
	mercury_output_term(ConsType, TVarSet).

:- pred write_cons_type_list(list(cons_type_info), const, int, term__context,
				io__state, io__state).
:- mode write_cons_type_list(in, in, in, in, di, uo) is det.

write_cons_type_list([], _, _, _) --> [].
write_cons_type_list([ConsDefn | ConsDefns], Functor, Arity, Context) -->
	write_cons_type(ConsDefn, Functor, Context),
	( { ConsDefns = [] } ->
		[]
	;
		( { Arity = 0 } ->
			io__write_string(", ")
		;
			io__write_string(",\n"),
			prog_out__write_context(Context),
			io__write_string("  ")
		),
		write_cons_type_list(ConsDefns, Functor, Arity, Context)
	).

%-----------------------------------------------------------------------------%

:- pred write_type_assign_set_msg(type_assign_set, tvarset,
				io__state, io__state).
:- mode write_type_assign_set_msg(in, in, di, uo) is det.

write_type_assign_set_msg(TypeAssignSet, VarSet) -->
	globals__io_lookup_bool_option(verbose_errors, VerboseErrors),
	( { VerboseErrors = yes } ->
		( { TypeAssignSet = [_] } ->
		    io__write_string("\tThe partial type assignment was:\n")
		;
		    io__write_string(
			"\tThe possible partial type assignments were:\n")
		),
		write_type_assign_set(TypeAssignSet, VarSet)
	;
		[]
	).

:- pred write_args_type_assign_set_msg(args_type_assign_set, tvarset,
				io__state, io__state).
:- mode write_args_type_assign_set_msg(in, in, di, uo) is det.

write_args_type_assign_set_msg(ArgTypeAssignSet, VarSet) -->
	globals__io_lookup_bool_option(verbose_errors, VerboseErrors),
	( { VerboseErrors = yes } ->
		( { ArgTypeAssignSet = [_] } ->
		    io__write_string("\tThe partial type assignment was:\n")
		;
		    io__write_string(
			"\tThe possible partial type assignments were:\n")
		),
		write_args_type_assign_set(ArgTypeAssignSet, VarSet)
	;
		[]
	).

%-----------------------------------------------------------------------------%

:- pred write_type_assign_set(type_assign_set, tvarset, io__state, io__state).
:- mode write_type_assign_set(in, in, di, uo) is det.

write_type_assign_set([], _) --> [].
write_type_assign_set([TypeAssign | TypeAssigns], VarSet) -->
	io__write_string("\t"),
	write_type_assign(TypeAssign, VarSet),
	io__write_string("\n"),
	write_type_assign_set(TypeAssigns, VarSet).

:- pred write_args_type_assign_set(args_type_assign_set, tvarset,
				io__state, io__state).
:- mode write_args_type_assign_set(in, in, di, uo) is det.

write_args_type_assign_set([], _) --> [].
write_args_type_assign_set([TypeAssign - _ArgTypes| TypeAssigns], VarSet) -->
	io__write_string("\t"),
	write_type_assign(TypeAssign, VarSet),
	io__write_string("\n"),
	write_args_type_assign_set(TypeAssigns, VarSet).

:- pred write_type_assign(type_assign, tvarset, io__state, io__state).
:- mode write_type_assign(in, in, di, uo) is det.

write_type_assign(TypeAssign, VarSet) -->
	{
	  type_assign_get_var_types(TypeAssign, VarTypes),
	  type_assign_get_type_bindings(TypeAssign, TypeBindings),
	  type_assign_get_typevarset(TypeAssign, TypeVarSet),
	  map__keys(VarTypes, Vars)
	},
	write_type_assign_2(Vars, VarSet, VarTypes, TypeBindings, TypeVarSet,
			no),
	io__write_string("\n").

:- pred write_type_assign_2(list(var), varset, map(var, type),
			tsubst, tvarset, bool, io__state, io__state).
:- mode write_type_assign_2(in, in, in, in, in, in, di, uo) is det.

write_type_assign_2([], _, _, _, _, FoundOne) -->
	( { FoundOne = no } ->
		io__write_string("(No variables were assigned a type)")
	;
		[]
	).

write_type_assign_2([Var | Vars], VarSet, VarTypes, TypeBindings, TypeVarSet,
			FoundOne) -->
	( 
		{ map__search(VarTypes, Var, Type) }
	->
		( { FoundOne = yes } ->
			io__write_string("\n\t")
		;
			[]
		),
		mercury_output_var(Var, VarSet),
		io__write_string(" :: "),
		write_type_b(Type, TypeVarSet, TypeBindings),
		write_type_assign_2(Vars, VarSet, VarTypes, TypeBindings,
			TypeVarSet, yes)
	;
		write_type_assign_2(Vars, VarSet, VarTypes, TypeBindings,
			TypeVarSet, FoundOne)
	).

	% write_type_b writes out a type after applying the type bindings.

:- pred write_type_b(type, tvarset, tsubst, io__state, io__state).
:- mode write_type_b(in, in, in, di, uo) is det.

write_type_b(Type, TypeVarSet, TypeBindings) -->
	{ term__apply_rec_substitution(Type, TypeBindings, Type2) },
	mercury_output_term(Type2, TypeVarSet).

%-----------------------------------------------------------------------------%

:- pred report_error_var(type_info, var, type, type_assign_set,
			io__state, io__state).
:- mode report_error_var(type_info_no_io, in, in, in, di, uo) is det.

report_error_var(TypeInfo, VarId, Type, TypeAssignSet0) -->
	{ type_info_get_called_predid(TypeInfo, CalledPredId) },
	{ type_info_get_arg_num(TypeInfo, ArgNum) },
	{ type_info_get_context(TypeInfo, Context) },
	{ type_info_get_unify_context(TypeInfo, UnifyContext) },
	{ get_type_stuff(TypeAssignSet0, VarId, TypeStuffList) },
	{ type_info_get_varset(TypeInfo, VarSet) },
	write_context_and_pred_id(TypeInfo),
	write_call_context(Context, CalledPredId, ArgNum, UnifyContext),
	prog_out__write_context(Context),
	io__write_string("  type error: "),
	( { TypeStuffList = [SingleTypeStuff] } ->
		write_argument_name(VarSet, VarId),
		{ SingleTypeStuff = type_stuff(VType, TVarSet, TBinding) },
		io__write_string(" has type `"),
		write_type_b(VType, TVarSet, TBinding),
		io__write_string("',\n"),
		prog_out__write_context(Context),
		io__write_string("  expected type was `"),
		write_type_b(Type, TVarSet, TBinding),
		io__write_string("'.\n")
	;
		io__write_string("type of "),
		write_argument_name(VarSet, VarId),
		io__write_string(" does not match its expected type;\n"),

		prog_out__write_context(Context),
		io__write_string("  "),
		write_argument_name(VarSet, VarId),
		io__write_string(" has overloaded actual/expected types {\n"),

		prog_out__write_context(Context),
		io__write_string("    "),
		write_var_type_stuff_list(TypeStuffList, Type),
		io__write_string("\n"),

		prog_out__write_context(Context),
		io__write_string("  }.\n")
	),
	write_type_assign_set_msg(TypeAssignSet0, VarSet).

:- pred report_error_arg_var(type_info, var, args_type_assign_set,
			io__state, io__state).
:- mode report_error_arg_var(type_info_no_io, in, in, di, uo) is det.

report_error_arg_var(TypeInfo, VarId, ArgTypeAssignSet0) -->
	{ type_info_get_called_predid(TypeInfo, CalledPredId) },
	{ type_info_get_arg_num(TypeInfo, ArgNum) },
	{ type_info_get_context(TypeInfo, Context) },
	{ type_info_get_unify_context(TypeInfo, UnifyContext) },
	{ get_arg_type_stuff(ArgTypeAssignSet0, VarId, ArgTypeStuffList) },
	{ type_info_get_varset(TypeInfo, VarSet) },
	write_context_and_pred_id(TypeInfo),
	write_call_context(Context, CalledPredId, ArgNum, UnifyContext),
	prog_out__write_context(Context),
	io__write_string("  type error: "),
	( { ArgTypeStuffList = [SingleArgTypeStuff] } ->
		write_argument_name(VarSet, VarId),
		{ SingleArgTypeStuff = arg_type_stuff(Type, VType, TVarSet) },
		io__write_string(" has type `"),
		mercury_output_term(VType, TVarSet),
		io__write_string("',\n"),
		prog_out__write_context(Context),
		io__write_string("  expected type was `"),
		mercury_output_term(Type, TVarSet),
		io__write_string("'.\n")
	;
		io__write_string("type of "),
		write_argument_name(VarSet, VarId),
		io__write_string(" does not match its expected type;\n"),

		prog_out__write_context(Context),
		io__write_string("  "),
		write_argument_name(VarSet, VarId),
		io__write_string(" has overloaded actual/expected types {\n"),

		prog_out__write_context(Context),
		io__write_string("    "),
		write_arg_type_stuff_list(ArgTypeStuffList),
		io__write_string("\n"),

		prog_out__write_context(Context),
		io__write_string("  }.\n")
	),
	write_args_type_assign_set_msg(ArgTypeAssignSet0, VarSet).

:- pred write_type_stuff_list(list(type_stuff), io__state, io__state).
:- mode write_type_stuff_list(in, di, uo) is det.

write_type_stuff_list([]) --> [].
write_type_stuff_list([type_stuff(T, TVarSet, TBinding) | Ts]) -->
	write_type_b(T, TVarSet, TBinding),
	write_type_stuff_list_2(Ts).

:- pred write_type_stuff_list_2(list(type_stuff), io__state, io__state).
:- mode write_type_stuff_list_2(in, di, uo) is det.

write_type_stuff_list_2([]) --> [].
write_type_stuff_list_2([type_stuff(T, TVarSet, TBinding) | Ts]) -->
	io__write_string(", "),
	write_type_b(T, TVarSet, TBinding),
	write_type_stuff_list_2(Ts).

:- pred write_var_type_stuff_list(list(type_stuff), type, io__state, io__state).
:- mode write_var_type_stuff_list(in, in, di, uo) is det.

write_var_type_stuff_list([], _Type) --> [].
write_var_type_stuff_list([type_stuff(VT, TVarSet, TBinding) | Ts], T) -->
	write_type_b(VT, TVarSet, TBinding),
	io__write_string("/"),
	write_type_b(T, TVarSet, TBinding),
	write_var_type_stuff_list_2(Ts, T).

:- pred write_var_type_stuff_list_2(list(type_stuff), type,
					io__state, io__state).
:- mode write_var_type_stuff_list_2(in, in, di, uo) is det.

write_var_type_stuff_list_2([], _Type) --> [].
write_var_type_stuff_list_2([type_stuff(VT, TVarSet, TBinding) | Ts], T) -->
	io__write_string(", "),
	write_type_b(VT, TVarSet, TBinding),
	io__write_string("/"),
	write_type_b(T, TVarSet, TBinding),
	write_type_stuff_list_2(Ts).

:- pred write_arg_type_stuff_list(list(arg_type_stuff), io__state, io__state).
:- mode write_arg_type_stuff_list(in, di, uo) is det.

write_arg_type_stuff_list([]) --> [].
write_arg_type_stuff_list([arg_type_stuff(T, VT, TVarSet) | Ts]) -->
	mercury_output_term(VT, TVarSet),
	io__write_string("/"),
	mercury_output_term(T, TVarSet),
	write_arg_type_stuff_list_2(Ts).

:- pred write_arg_type_stuff_list_2(list(arg_type_stuff), io__state, io__state).
:- mode write_arg_type_stuff_list_2(in, di, uo) is det.

write_arg_type_stuff_list_2([]) --> [].
write_arg_type_stuff_list_2([arg_type_stuff(T, VT, TVarSet) | Ts]) -->
	io__write_string(", "),
	mercury_output_term(VT, TVarSet),
	io__write_string("/"),
	mercury_output_term(T, TVarSet),
	write_arg_type_stuff_list_2(Ts).

%-----------------------------------------------------------------------------%

:- pred report_error_undef_pred(type_info, pred_call_id, io__state, io__state).
:- mode report_error_undef_pred(type_info_no_io, in, di, uo) is det.

report_error_undef_pred(TypeInfo, PredId) -->
	write_type_info_context(TypeInfo),
	io__write_string("  error: undefined predicate `"),
	hlds_out__write_pred_call_id(PredId),
	io__write_string("'.\n").

:- pred report_error_pred_num_args(type_info, pred_call_id, list(int),
					io__state, io__state).
:- mode report_error_pred_num_args(type_info_no_io, in, in, di, uo) is det.

report_error_pred_num_args(TypeInfo, Name / Arity, Arities) -->
	write_type_info_context(TypeInfo),
	io__write_string("  error: wrong number of arguments ("),
	io__write_int(Arity),
	io__write_string(") in call to pred `"),
	prog_out__write_sym_name(Name),
	io__write_string("'; should be "),
	report_error_pred_num_right_args(Arities),
	io__write_string(".\n").

:- pred report_error_pred_num_right_args(list(int), io__state, io__state).
:- mode report_error_pred_num_right_args(in, di, uo) is det.

report_error_pred_num_right_args([]) --> [].
report_error_pred_num_right_args([Arity | Arities]) -->
	io__write_int(Arity),
	( { Arities = [] } ->
		[]
	; { Arities = [_] } ->
		io__write_string(" or ")
	;
		io__write_string(", ")
	),
	report_error_pred_num_right_args(Arities).

:- pred report_error_undef_cons(type_info, const, int, io__state, io__state).
:- mode report_error_undef_cons(type_info_no_io, in, in, di, uo) is det.

report_error_undef_cons(TypeInfo, Functor, Arity) -->
	{ type_info_get_called_predid(TypeInfo, CalledPredId) },
	{ type_info_get_arg_num(TypeInfo, ArgNum) },
	{ type_info_get_context(TypeInfo, Context) },
	{ type_info_get_unify_context(TypeInfo, UnifyContext) },
	write_context_and_pred_id(TypeInfo),
	write_call_context(Context, CalledPredId, ArgNum, UnifyContext),
	prog_out__write_context(Context),
	io__write_string("  error: undefined symbol `"),
	term_io__write_constant(Functor),
	io__write_string("/"),
	io__write_int(Arity),
	io__write_string("'.\n").

:- pred write_call_context(term__context, pred_call_id, int, unify_context,
				io__state, io__state).
:- mode write_call_context(in, in, in, in, di, uo) is det.

write_call_context(Context, PredCallId, ArgNum, UnifyContext) -->
	( { ArgNum = 0 } ->
		hlds_out__write_unify_context(UnifyContext, Context)
	;
		prog_out__write_context(Context),
		io__write_string("  in argument "),
		io__write_int(ArgNum),
		io__write_string(" of call to pred `"),
		hlds_out__write_pred_call_id(PredCallId),
		io__write_string("':\n")
	).

%-----------------------------------------------------------------------------%

:- pred write_type_info_context(type_info, io__state, io__state).
:- mode write_type_info_context(type_info_no_io, di, uo) is det.

write_type_info_context(TypeInfo) -->
	write_context_and_pred_id(TypeInfo),
	{ type_info_get_context(TypeInfo, Context) },
	prog_out__write_context(Context).

:- pred write_context_and_pred_id(type_info, io__state, io__state).
:- mode write_context_and_pred_id(type_info_no_io, di, uo) is det.

write_context_and_pred_id(TypeInfo) -->
	{ type_info_get_module_info(TypeInfo, ModuleInfo) },
	{ type_info_get_context(TypeInfo, Context) },
	{ type_info_get_predid(TypeInfo, PredId) },
	prog_out__write_context(Context),
	io__write_string("In clause for predicate `"),
	hlds_out__write_pred_id(ModuleInfo, PredId),
	io__write_string("':\n").

%-----------------------------------------------------------------------------%

:- pred report_ambiguity_error(type_info, type_assign, type_assign,
				io__state, io__state).
:- mode report_ambiguity_error(type_info_no_io, in, in, di, uo) is det.

report_ambiguity_error(TypeInfo, TypeAssign1, TypeAssign2) -->
	write_type_info_context(TypeInfo),
	io__write_string("  error: ambiguous overloading causes type ambiguity.\n"),
	{ type_info_get_context(TypeInfo, Context) },
	prog_out__write_context(Context),
	io__write_string("  Possible type assignments include:\n"),
	{ type_info_get_varset(TypeInfo, VarSet) },
	{ type_assign_get_var_types(TypeAssign1, VarTypes1) },
	{ map__keys(VarTypes1, Vars1) },
	report_ambiguity_error_2(Vars1, VarSet, TypeInfo,
					TypeAssign1, TypeAssign2).

:- pred report_ambiguity_error_2(list(var), varset, type_info,
				type_assign, type_assign,
				io__state, io__state).
:- mode report_ambiguity_error_2(in, in, type_info_no_io, in, in, di, uo)
				is det.

report_ambiguity_error_2([], _VarSet, _, _TypeAssign1, _TypeAssign2) --> [].
report_ambiguity_error_2([V | Vs], VarSet, TypeInfo, TypeAssign1, TypeAssign2)
		-->
	{ type_assign_get_var_types(TypeAssign1, VarTypes1) },
	{ type_assign_get_var_types(TypeAssign2, VarTypes2) },
	{ type_assign_get_type_bindings(TypeAssign1, TypeBindings1) },
	{ type_assign_get_type_bindings(TypeAssign2, TypeBindings2) },
	( {
		map__search(VarTypes1, V, Type1),
		map__search(VarTypes2, V, Type2),
		term__apply_rec_substitution(Type1, TypeBindings1, T1),
		term__apply_rec_substitution(Type2, TypeBindings2, T2),
		T1 \= T2
	} ->
		{ type_info_get_context(TypeInfo, Context) },
		prog_out__write_context(Context),
		mercury_output_var(V, VarSet),
		io__write_string(" :: "),
		{ type_assign_get_typevarset(TypeAssign1, TVarSet1) },
		mercury_output_term(T1, TVarSet1),
		io__write_string(" or "),
		{ type_assign_get_typevarset(TypeAssign2, TVarSet2) },
		mercury_output_term(T2, TVarSet2),
		io__write_string("\n")
	;
		[]
	),
	report_ambiguity_error_2(Vs, VarSet, TypeInfo,
				TypeAssign1, TypeAssign2).

%-----------------------------------------------------------------------------%
%-----------------------------------------------------------------------------%
