%-----------------------------------------------------------------------------%

% Peephole.nl - LLDS to LLDS peephole optimization.

% Main author: fjh.
% Jump to jump optimizations and label elimination by zs.

% XXX jump optimization and label elimination must be revisited
% when we start using unilabels.

%-----------------------------------------------------------------------------%

:- module peephole.
:- interface.
:- import_module llds, options.

:- pred peephole__optimize(option_table, c_file, c_file).
:- mode peephole__optimize(in, in, out) is det.

%-----------------------------------------------------------------------------%

:- implementation.
:- import_module value_number, code_util, map, bintree_set.
:- import_module string, list, require, std_util.

%-----------------------------------------------------------------------------%

	% Boring LLDS traversal code.

peephole__optimize(Options, c_file(Name, Modules0), c_file(Name, Modules)) :-
	peephole__opt_module_list(Options, Modules0, Modules).

:- pred peephole__opt_module_list(option_table, list(c_module), list(c_module)).
:- mode peephole__opt_module_list(in, in, out) is det.

peephole__opt_module_list(_Options, [], []).
peephole__opt_module_list(Options, [M0|Ms0], [M|Ms]) :-
	peephole__opt_module(Options, M0, M),
	peephole__opt_module_list(Options, Ms0, Ms).

:- pred peephole__opt_module(option_table, c_module, c_module).
:- mode peephole__opt_module(in, in, out) is det.

peephole__opt_module(Options, c_module(Name, Procs0), c_module(Name, Procs)) :-
	peephole__opt_proc_list(Options, Procs0, Procs).

:- pred peephole__opt_proc_list(option_table,
				list(c_procedure), list(c_procedure)).
:- mode peephole__opt_proc_list(in, in, out) is det.

peephole__opt_proc_list(_Options, [], []).
peephole__opt_proc_list(Options, [P0|Ps0], [P|Ps]) :-
	peephole__opt_proc(Options, P0, P),
	peephole__opt_proc_list(Options, Ps0, Ps).

	% We short-circuit jump sequences before normal peepholing
	% to create more opportunities for use of the tailcall macro.

:- pred peephole__opt_proc(option_table, c_procedure, c_procedure).
:- mode peephole__opt_proc(in, in, out) is det.

peephole__opt_proc(Options, c_procedure(Name, Arity, Mode, Instructions0),
		   c_procedure(Name, Arity, Mode, Instructions)) :-
	peephole__repeat_opts(Options, Instructions0, Instructions1),
	peephole__nonrepeat_opts(Options, Instructions1, Instructions).

:- pred peephole__repeat_opts(option_table, list(instruction),
	list(instruction)).
:- mode peephole__repeat_opts(in, in, out) is det.

peephole__repeat_opts(Options, Instructions0, Instructions) :-
	options__lookup_bool_option(Options, peephole_jump_opt, Jumpopt),
	( Jumpopt = yes ->
		peephole__short_circuit(Instructions0, Instructions1, Mod0)
	;
		Instructions1 = Instructions0,
		Mod0 = no
	),
	options__lookup_bool_option(Options, peephole_local, Local),
	( Local = yes ->
		peephole__local_opt(Instructions1, Instructions2, Mod1)
	;
		Instructions2 = Instructions1,
		Mod1 = no
	),
	options__lookup_bool_option(Options, peephole_label_elim, LabelElim),
	( LabelElim = yes ->
		peephole__label_elim(Instructions2, Instructions3, Mod2)
	;
		Instructions3 = Instructions2,
		Mod2 = no
	),
	( Mod0 = no, Mod1 = no, Mod2 = no ->
		Instructions = Instructions3
	;
		peephole__repeat_opts(Options, Instructions3, Instructions)
	).

:- pred peephole__nonrepeat_opts(option_table, list(instruction),
	list(instruction)).
:- mode peephole__nonrepeat_opts(in, in, out) is det.

peephole__nonrepeat_opts(Options, Instructions0, Instructions) :-
	options__lookup_bool_option(Options, peephole_value_number, ValueNumber),
	( ValueNumber = yes ->
		value_number__optimize(Instructions0, Instructions)
	;
		Instructions = Instructions0
	).

%-----------------------------------------------------------------------------%

	% Build up a table showing the first instruction following each label.
	% Then traverse the instruction list, short-circuiting jump sequences.

:- type jumpmap == map(label, instruction).
:- type procmap == map(label, list(instruction)).

:- pred peephole__short_circuit(list(instruction), list(instruction), bool).
:- mode peephole__short_circuit(in, out, out) is det.

peephole__short_circuit(Instrs0, Instrs, Mod) :-
	map__init(Jumpmap0),
	map__init(Procmap0),
	peephole__jumpopt_build_maps(Instrs0, Jumpmap0, Jumpmap,
		Procmap0, Procmap),
	peephole__jumpopt_instr_list(Instrs0, Jumpmap, Procmap, Instrs, Mod).

:- pred peephole__jumpopt_build_maps(list(instruction), jumpmap, jumpmap,
	procmap, procmap).
:- mode peephole__jumpopt_build_maps(in, di, uo, di, uo) is det.

peephole__jumpopt_build_maps([], Jumpmap, Jumpmap, Procmap, Procmap).
peephole__jumpopt_build_maps([Instr - _Comment|Instrs],
		Jumpmap0, Jumpmap, Procmap0, Procmap) :-
	( Instr = label(Label) ->
		peephole__skip_comments(Instrs, Instrs1),
		( Instrs1 = [Nextinstr | _] ->
			% write('label '),
			% write(Label),
			% write(' maps to '),
			% write(Nextinstr),
			% nl,
			map__set(Jumpmap0, Label, Nextinstr, Jumpmap1)
		;
			Jumpmap1 = Jumpmap0
		),
		( peephole__is_proceed_next(Instrs, Between) ->
			% write('label '),
			% write(Label),
			% write(' is followed by proceed '),
			% nl,
			map__set(Procmap0, Label, Between, Procmap1)
		;
			Procmap1 = Procmap0
		)
	;
		Jumpmap1 = Jumpmap0,
		Procmap1 = Procmap0
	),
	peephole__jumpopt_build_maps(Instrs, Jumpmap1, Jumpmap,
		Procmap1, Procmap).

:- pred peephole__jumpopt_instr_list(list(instruction),
	jumpmap, procmap, list(instruction), bool).
:- mode peephole__jumpopt_instr_list(in, in, in, out, out) is det.

peephole__jumpopt_instr_list([], _Jumpmap, _Procmap, [], no).
peephole__jumpopt_instr_list([Instr0|Moreinstrs0], Jumpmap, Procmap,
		Instrs, Mod) :-
	Instr0 = Uinstr0 - Comment0,
	string__append(Comment0, " (redirected return)", Redirect),
	( Uinstr0 = call(Proc, Retlabel) ->
		map__lookup(Jumpmap, Retlabel, Retinstr),
		peephole__jumpopt_final_dest(Retlabel, Retinstr,
			Jumpmap, Destlabel, Destinstr),
		( Retlabel = Destlabel ->
			Newinstrs = [Instr0],
			Mod0 = no
		;
			Newinstrs = [call(Proc, Destlabel) - Redirect],
			Mod0 = yes
		)
	; Uinstr0 = entrycall(Proc, Retlabel) ->
		map__lookup(Jumpmap, Retlabel, Retinstr),
		peephole__jumpopt_final_dest(Retlabel, Retinstr,
			Jumpmap, Destlabel, Destinstr),
		( Retlabel = Destlabel ->
			Newinstrs = [Instr0],
			Mod0 = no
		;
			Newinstrs = [entrycall(Proc, Destlabel) - Redirect],
			Mod0 = yes
		)
	; Uinstr0 = unicall(Unilabel, Retlabel) ->
		map__lookup(Jumpmap, Retlabel, Retinstr),
		peephole__jumpopt_final_dest(Retlabel, Retinstr,
			Jumpmap, Destlabel, Destinstr),
		( Retlabel = Destlabel ->
			Newinstrs = [Instr0],
			Mod0 = no
		;
			Newinstrs = [unicall(Unilabel, Destlabel) - Redirect],
			Mod0 = yes
		)
	; Uinstr0 = goto(Targetlabel) ->
		( Moreinstrs0 = [label(Targetlabel) - _|_] ->
			% eliminating the goto (by the local peephole pass)
			% is better than shortcircuiting it here
			Newinstrs = [Instr0],
			Mod0 = no
		; map__search(Procmap, Targetlabel, Between) ->
			list__append(Between, [proceed - "shortcircuit"], Newinstrs),
			Mod0 = yes
		;
			map__lookup(Jumpmap, Targetlabel, Targetinstr),
			peephole__jumpopt_final_dest(Targetlabel, Targetinstr,
				Jumpmap, Destlabel, Destinstr),
			Destinstr = Udestinstr - _Destcomment,
			string__append("shortcircuited jump: ",
				Comment0, Shorted),
			code_util__can_instr_fall_through(Udestinstr, Canfallthrough),
			( Canfallthrough = no ->
				Newinstrs = [Udestinstr - Shorted],
				Mod0 = yes
			;
				( Targetlabel = Destlabel ->
					Newinstrs = [Instr0],
					Mod0 = no
				;
					Newinstrs = [goto(Destlabel) - Shorted],
					Mod0 = yes
				)
			)
		)
	;
		Newinstrs = [Instr0],
		Mod0 = no
	),
	peephole__jumpopt_instr_list(Moreinstrs0, Jumpmap, Procmap,
		Moreinstrs, Mod1),
	list__append(Newinstrs, Moreinstrs, Instrs),
	( Mod0 = no, Mod1 = no ->
		Mod = no
	;
		Mod = yes
	).

:- pred peephole__jumpopt_final_dest(label, instruction, jumpmap,
	label, instruction).
:- mode peephole__jumpopt_final_dest(in, in, in, out, out) is det.

	% Currently we don't check for infinite loops.  This is OK at
	% the moment since the compiler never generates code containing
	% infinite loops, but it may cause problems in the future.

peephole__jumpopt_final_dest(Srclabel, Srcinstr, Jumpmap,
		Destlabel, Destinstr) :-
	(
		Srcinstr = goto(Targetlabel) - Comment,
		map__search(Jumpmap, Targetlabel, Targetinstr)
	->
		% write('goto short-circuit from '),
		% write(Srclabel),
		% write(' to '),
		% write(Targetlabel),
		% nl,
		peephole__jumpopt_final_dest(Targetlabel, Targetinstr,
			Jumpmap, Destlabel, Destinstr)
	;
		Srcinstr = label(Targetlabel) - Comment,
		map__search(Jumpmap, Targetlabel, Targetinstr)
	->
		% write('fallthrough short-circuit from '),
		% write(Srclabel),
		% write(' to '),
		% write(Targetlabel),
		% nl,
		peephole__jumpopt_final_dest(Targetlabel, Targetinstr,
			Jumpmap, Destlabel, Destinstr)
	;
		Destlabel = Srclabel,
		Destinstr = Srcinstr
	).

%-----------------------------------------------------------------------------%

	% We zip down to the end of the instruction list, and start attempting
	% to optimize instruction sequences.  As long as we can continue
	% optimizing the instruction sequence, we keep doing so;
	% when we find a sequence we can't optimize, we back up try
	% so optimize the sequence starting with the previous instruction.

:- pred peephole__local_opt(list(instruction), list(instruction), bool).
:- mode peephole__local_opt(in, out, out) is det.

peephole__local_opt([], [], no).
peephole__local_opt([Instr0 - Comment|Instructions0], Instructions, Mod) :-
	peephole__local_opt(Instructions0, Instructions1, Mod0),
	peephole__opt_instr(Instr0, Comment, Instructions1, Instructions, Mod1),
	( Mod0 = no, Mod1 = no ->
		Mod = no
	;
		Mod = yes
	).

:- pred peephole__opt_instr(instr, string, list(instruction),
				list(instruction), bool).
:- mode peephole__opt_instr(in, in, in, out, out) is det.

peephole__opt_instr(Instr0, Comment0, Instructions0, Instructions, Mod) :-
	(
		peephole__skip_comments(Instructions0, Instructions1),
		peephole__opt_instr_2(Instr0, Comment0, Instructions1,
			Instructions2)
	->
		( Instructions2 = [Instr2 - Comment2 | Instructions3] ->
			peephole__opt_instr(Instr2, Comment2, Instructions3,
				Instructions, _)
		;
			Instructions = Instructions2
		),
		Mod = yes
	;
		Instructions = [Instr0 - Comment0 | Instructions0],
		Mod = no
	).

:- pred peephole__opt_instr_2(instr, string, list(instruction),
				list(instruction)).
:- mode peephole__opt_instr_2(in, in, in, out) is semidet.

	% A `call' followed by a `proceed' can be replaced with a `tailcall'.
	%
	%					succip = ...
	%					decr_sp(X)
	%	call(Foo, &&ret);		tailcall(Foo)
	%       <comments, labels>		<comments, labels>
	%     ret:			=>    ret:
	%       <comments, labels>		<comments, labels>
	%	succip = ...			succip = ...
	%       <comments, labels>		<comments, labels>
	%	decr_sp(X)			decr_sp(X)
	%       <comments, labels>		<comments, labels>
	%	proceed				proceed
	%
	% Note that we can't delete the return label and the following
	% code, since the label might be branched to from elsewhere.
	% If it isn't, label elimination will get rid of it later.

peephole__opt_instr_2(call(CodeAddress, ContLabel), Comment, Instrs0, Instrs) :-
	peephole__is_this_label_next(ContLabel, Instrs0, Instrs1),
	peephole__is_proceed_next(Instrs1, Instrs_to_proceed),
	list__append(Instrs_to_proceed,
		[tailcall(CodeAddress) - Comment | Instrs0], Instrs).

	% if a `mkframe' is followed by a `modframe', with the instructions
	% in between containing only straight-line code, we can delete the
	% `modframe' and instead just set the redoip directly in the `mkframe'.
	%
	%	mkframe(D, S, _)	=>	mkframe(D, S, Redoip)
	%	<straightline instrs>		<straightline instrs>
	%	modframe(Redoip)

peephole__opt_instr_2(mkframe(Descr, Slots, _), Comment, Instrs0, Instrs) :-
	peephole__next_modframe(Instrs0, [], Redoip, Skipped, Rest),
	list__append(Skipped, Rest, Instrs1),
	Instrs = [mkframe(Descr, Slots, Redoip) - Comment | Instrs1].

	% a `goto' can be deleted if the target of the jump is the very
	% next instruction.
	%
	%	goto next;	=>	  <comments, labels>
	%	<comments, labels>	next:
	%     next:
	%
	% dead code after a `goto' is deleted in label-elim.

peephole__opt_instr_2(goto(Label), _Comment, Instrs0, Instrs) :-
	peephole__is_this_label_next(Label, Instrs0, _),
	Instrs = Instrs0.

	% a conditional branch over a branch can be replaced
	% by an inverse conditional branch
	%
	%	if (x) goto skip;		if (!x) goto somewhere
	%	<comments>			omit <comments>
	%	goto somewhere;		=>	<comments, labels>
	%	<comments, labels>	      skip:
	%     skip:
	%
	% a conditional branch around a redo or fail can be replaced
	% by an inverse conditional redo or fail (this is better if
	% the label can later be eliminated)
	%
	%	if (x) goto skip;		if (!x) redo;
	%	<comments>			omit <comments>
	%	redo;			=>      <comments, labels>
	%	<comments, labels>	      skip:
	%     skip:
	%
	% a conditional branch to the very next instruction
	% can be deleted
	%	if (x) goto next;	=>	<comments, labels>
	%	<comments, labels>	      next:
	%     next:

peephole__opt_instr_2(if_val(Rval, goto(Target)), _C1, Instrs0, Instrs) :-
	peephole__skip_comments(Instrs0, Instrs1),
	( Instrs1 = [goto(Somewhere) - C2 | Instrs2] ->
		peephole__is_this_label_next(Target, Instrs2, _),
		code_util__neg_rval(Rval, NotRval),
		Instrs = [if_val(NotRval, goto(Somewhere)) - C2 | Instrs2]

	; Instrs1 = [redo - C2 | Instrs2] ->
		peephole__is_this_label_next(Target, Instrs2, _),
		code_util__neg_rval(Rval, NotRval),
		Instrs = [if_val(NotRval, redo) - C2 | Instrs2]

	; Instrs1 = [fail - C2 | Instrs2] ->
		peephole__is_this_label_next(Target, Instrs2, _),
		code_util__neg_rval(Rval, NotRval),
		Instrs = [if_val(NotRval, fail) - C2 | Instrs2]

	;
		peephole__is_this_label_next(Target, Instrs1, _),
		Instrs = Instrs0
	).

%-----------------------------------------------------------------------------%

	% Build up a table showing which labels are branched to.
	% Then traverse the instruction list removing unnecessary labels.
	% If the instruction before the label branches away, we also
	% remove the instruction block following the label.

:- type usemap == bintree_set(label).

:- pred peephole__label_elim(list(instruction), list(instruction), bool).
:- mode peephole__label_elim(in, out, out) is det.

peephole__label_elim(Instructions0, Instructions, Mod) :-
	bintree_set__init(Usemap0),
	peephole__label_elim_build_usemap(Instructions0, Usemap0, Usemap),
	peephole__label_elim_instr_list(Instructions0, Usemap,
		Instructions, Mod).

:- pred peephole__label_elim_build_usemap(list(instruction), usemap, usemap).
:- mode peephole__label_elim_build_usemap(in, di, uo) is det.

peephole__label_elim_build_usemap([], Usemap, Usemap).
peephole__label_elim_build_usemap([Instr - _Comment|Instructions],
		Usemap0, Usemap) :-
	( Instr = call(Code_addr, Label) ->
		bintree_set__insert(Usemap0, Label, Usemap1),
		peephole__code_addr_build_usemap(Code_addr, Usemap1, Usemap2)
	; Instr = entrycall(Code_addr, Label) ->
		bintree_set__insert(Usemap0, Label, Usemap1),
		peephole__code_addr_build_usemap(Code_addr, Usemap1, Usemap2)
	; Instr = unicall(_, Label) ->
		bintree_set__insert(Usemap0, Label, Usemap2)
	; Instr = tailcall(local(Label)) ->
		bintree_set__insert(Usemap0, Label, Usemap2)
	; Instr = mkframe(_, _, yes(Label)) ->
		bintree_set__insert(Usemap0, Label, Usemap2)
	; Instr = modframe(yes(Label)) ->
		bintree_set__insert(Usemap0, Label, Usemap2)
	; Instr = goto(Label) ->
		bintree_set__insert(Usemap0, Label, Usemap2)
	; Instr = if_val(_, goto(Label)) ->
		bintree_set__insert(Usemap0, Label, Usemap2)
	;
		Usemap2 = Usemap0
	),
	peephole__label_elim_build_usemap(Instructions, Usemap2, Usemap).

:- pred peephole__code_addr_build_usemap(code_addr, usemap, usemap).
:- mode peephole__code_addr_build_usemap(in, di, uo) is det.

peephole__code_addr_build_usemap(Code_addr, Usemap0, Usemap) :-
	( Code_addr = local(Label) ->
		bintree_set__insert(Usemap0, Label, Usemap)
	;
		Usemap = Usemap0
	).

:- pred peephole__label_elim_instr_list(list(instruction),
	usemap, list(instruction), bool).
:- mode peephole__label_elim_instr_list(in, in, out, out) is det.

peephole__label_elim_instr_list(Instrs0, Usemap, Instrs, Mod) :-
	peephole__label_elim_instr_list(Instrs0, yes, Usemap, Instrs, Mod).

:- pred peephole__label_elim_instr_list(list(instruction),
	bool, usemap, list(instruction), bool).
:- mode peephole__label_elim_instr_list(in, in, in, out, out) is det.

peephole__label_elim_instr_list([], _Fallthrough, _Usemap, [], no).
peephole__label_elim_instr_list([Instr0 | Moreinstrs0],
		Fallthrough, Usemap, [Instr | Moreinstrs], Mod) :-
	( Instr0 = label(Label) - Comment ->
		(
		    (   Label = entrylabel(_, _, _, _)
		    ;   bintree_set__is_member(Label, Usemap)
		    )
		->
			Instr = Instr0,
			Fallthrough1 = yes,
			Mod0 = no
		;
			peephole__eliminate(Instr0, yes(Fallthrough), Instr,
				Mod0),
			Fallthrough1 = Fallthrough
		)
	;
		( Fallthrough = yes ->
			Instr = Instr0,
			Mod0 = no
		;
			peephole__eliminate(Instr0, no, Instr, Mod0)
		),
		Instr0 = Uinstr0 - Comment,
		code_util__can_instr_fall_through(Uinstr0, Canfallthrough),
		( Canfallthrough = yes ->
			Fallthrough1 = Fallthrough
		;
			Fallthrough1 = no
		)
	),
	peephole__label_elim_instr_list(Moreinstrs0, Fallthrough1, Usemap,
				Moreinstrs, Mod1),
	( Mod0 = no, Mod1 = no ->
		Mod = no
	;
		Mod = yes
	).

:- pred peephole__eliminate(instruction, maybe(bool), instruction, bool).
:- mode peephole__eliminate(in, in, out, out) is det.

peephole__eliminate(Uinstr0 - Comment0, Label, Uinstr - Comment, Mod) :-
	( Uinstr0 = comment(_) ->
		Comment = Comment0,
		Uinstr = Uinstr0,
		Mod = no
	;
		(
			Label = yes(Follow)
		->
			(
				Follow = yes
			->
				Uinstr = comment("eliminated label only")
			;
				% Follow = no,
				Uinstr = comment("eliminated label and block")
			)
		;
			% Label = no,
			Uinstr = comment("eliminated instruction")
		),
		Comment = Comment0,
		Mod = yes
	).

%-----------------------------------------------------------------------------%

	% Given a list of instructions, skip past any comment instructions
	% at the start and return the remaining instructions.
	% We do this because comment instructions get in the way of
	% peephole optimization.

:- pred peephole__skip_comments(list(instruction), list(instruction)).
:- mode peephole__skip_comments(in, out) is det.

peephole__skip_comments(Instrs0, Instrs) :-
	( Instrs0 = [comment(_) - _ | Instrs1] ->
		peephole__skip_comments(Instrs1, Instrs)
	;
		Instrs = Instrs0
	).

:- pred peephole__skip_comments_labels(list(instruction), list(instruction)).
:- mode peephole__skip_comments_labels(in, out) is det.

peephole__skip_comments_labels(Instrs0, Instrs) :-
	( Instrs0 = [comment(_) - _ | Instrs1] ->
		peephole__skip_comments_labels(Instrs1, Instrs)
	; Instrs0 = [label(_) - _ | Instrs1] ->
		peephole__skip_comments_labels(Instrs1, Instrs)
	;
		Instrs = Instrs0
	).

	% Find the next modframe if it is guaranteed to be reached from here

:- pred peephole__next_modframe(list(instruction), list(instruction),
	maybe(label), list(instruction), list(instruction)).
:- mode peephole__next_modframe(in, in, out, out, out) is semidet.

peephole__next_modframe([Instr | Instrs], RevSkip, Redoip, Skip, Rest) :-
	Instr = Uinstr - _Comment,
	( Uinstr = modframe(Redoip0) ->
		Redoip = Redoip0,
		list__reverse(RevSkip, Skip),
		Rest = Instrs
	; Uinstr = mkframe(_, _, _) ->
		fail
	;
		code_util__can_instr_branch_away(Uinstr, Canbranchaway),
		( Canbranchaway = no ->
			peephole__next_modframe(Instrs, [Instr | RevSkip],
				Redoip, Skip, Rest)
		;
			fail
		)
	).

	% Check whether the named label follows without any intervening code.
	% If yes, return the instructions after the label.

:- pred peephole__is_this_label_next(label, list(instruction),
	list(instruction)).
:- mode peephole__is_this_label_next(in, in, out) is semidet.

peephole__is_this_label_next(Label, [Instr | Moreinstr], Remainder) :-
	Instr = Uinstr - _Comment,
	( Uinstr = comment(_) ->
		peephole__is_this_label_next(Label, Moreinstr, Remainder)
	; Uinstr = label(NextLabel) ->
		( Label = NextLabel ->
			Remainder = Moreinstr
		;
			peephole__is_this_label_next(Label, Moreinstr,
				Remainder)
		)
	;
		fail
	).

	% Is a proceed instruction in the instruction list, possibly preceded
	% by a restoration of succip and a det stack frame removal? If yes,
	% return the instructions up to the proceed.

:- pred peephole__is_proceed_next(list(instruction), list(instruction)).
:- mode peephole__is_proceed_next(in, out) is semidet.

peephole__is_proceed_next(Instrs0, Instrs_between) :-
	peephole__skip_comments_labels(Instrs0, Instrs1),
	Instrs1 = [Instr1 | Instrs2],
	Instr1 = assign(succip, lval(stackvar(_))) - _,
	peephole__skip_comments_labels(Instrs2, Instrs3),
	Instrs3 = [Instr3 | Instrs4],
	Instr3 = decr_sp(_) - _,
	peephole__skip_comments_labels(Instrs4, Instrs5),
	Instrs5 = [Instr5 | _],
	Instr5 = proceed - _,
	Instrs_between = [Instr1, Instr3].

:- end_module peephole.

%-----------------------------------------------------------------------------%
