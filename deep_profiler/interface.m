%----------------------------------------------------------------------------%
% vim: ft=mercury ts=4 sw=4 et
%-----------------------------------------------------------------------------%
% Copyright (C) 2001-2002, 2004-2007 The University of Melbourne.
% This file may only be copied under the terms of the GNU General
% Public License - see the file COPYING in the Mercury distribution.
%-----------------------------------------------------------------------------%
%
% File: interface.m.
% Author: zs.
%
% This module defines interface between CGI programs acting as clients
% and CGI programs acting as servers.
%
% The interface consists of queries (sent from the CGI program to the server)
% and responses (sent back from the server to the CGI program), and shared
% knowledge of how to derive the names of some files from the name of the
% profiling data file being explored.
%
% Queries are sent and received as printed representations of Mercury terms,
% using the predicates send_term and recv_term. Responses are sent as strings
% using the predicates send_string and recv_string. Each response is actually
% the name of a file contained a web page, rather than the text of the web page
% itself. This makes things easy to debug (since we can leave the file around
% for inspection) and avoids any potential problems with the web page being too
% big to transmit atomically across the named pipe. (Printable representations
% of queries and filenames are both guaranteed to be smaller than eight
% kilobytes, which is the typical named pipe buffer size.)
%
% A query consists of three components, a command, a set of preferences, and
% the name of the profiling data file. The command tells the server what
% information the user wants displayed. The preferences tell the server how
% the user wants data displayed; they persist across queries unless the user
% changes them.
%
%-----------------------------------------------------------------------------%

:- module interface.
:- interface.

:- import_module bool.
:- import_module io.

%-----------------------------------------------------------------------------%

    % These functions derive the names of auxiliary files (or parts thereof)
    % from the name of the profiling data file being explored. The auxiliary
    % files are:
    %
    % - the name of the named pipe for transmitting queries to the server;
    % - the name of the named pipe for transmitting responses back to the
    %   CGI program;
    % - the name of the file containing the output of the server program,
    %   which prints statistics about its own performance at startup
    %   (and if invoked with debugging option, debugging information
    %   during its execution);
    % - the name of the mutual exclusion file (which is always empty);
    % - the naming scheme of the `want' files (which are always empty);
    % - the names of the files containing the web page responses;
    % - the name of the file containing contour exclusion information
    %   (see exclude.m).
    %
:- func to_server_pipe_name(string) = string.
:- func from_server_pipe_name(string) = string.
:- func server_startup_name(string) = string.
:- func mutex_file_name(string) = string.
:- func want_dir = string.
:- func want_prefix = string.
:- func want_file_name = string.
:- func response_file_name(string, int) = string.

    % send_term(ToFileName, Debug, Term):
    %
    % Write the term Term to ToFileName, making it is new contents.
    % If Debug is `yes', write it to the file `/tmp/.send_term' as well.
    %
:- pred send_term(string::in, bool::in, T::in, io::di, io::uo) is det.

    % send_string(ToFileName, Debug, Str):
    %
    % Write the string Str to ToFileName, making it is new contents.
    % If Debug is `yes', write it to the file `/tmp/.send_string' as well.
    %
:- pred send_string(string::in, bool::in, string::in, io::di, io::uo) is det.

    % recv_term(FromFileName, Debug, Term):
    %
    % Read the contents of FromFileName, which should be a single Mercury term.
    % If Debug is `yes', write the result of the read to the file
    % `/tmp/.recv_term' as well.
    %
:- pred recv_term(string::in, bool::in, T::out, io::di, io::uo) is det.

    % recv_string(FromFileName, Debug, Str):
    %
    % Read the contents of FromFileName, and return it as Str.
    % If Debug is `yes', write the result of the read to the file
    % `/tmp/.recv_string' as well.
    %
:- pred recv_string(string::in, bool::in, string::out, io::di, io::uo) is det.

%-----------------------------------------------------------------------------%

:- implementation.

:- import_module conf.
:- import_module util.
:- import_module query.

:- import_module char.
:- import_module int.
:- import_module list.
:- import_module require.
:- import_module string.

%-----------------------------------------------------------------------------%

to_server_pipe_name(DataFileName) =
    server_dir ++ "/" ++
    "mdprof_server_to" ++ filename_mangle(DataFileName).

from_server_pipe_name(DataFileName) =
    server_dir ++ "/" ++
    "mdprof_server_from" ++ filename_mangle(DataFileName).

server_startup_name(DataFileName) =
    server_dir ++ "/" ++
    "mdprof_startup_err" ++ filename_mangle(DataFileName).

mutex_file_name(DataFileName) =
    server_dir ++ "/" ++
    "mdprof_mutex" ++ filename_mangle(DataFileName).

want_dir = server_dir.

want_prefix = "mdprof_want".

want_file_name =
    want_dir ++ "/" ++ want_prefix ++ string.int_to_string(getpid).

response_file_name(DataFileName, QueryNum) =
    server_dir ++ "/" ++
    "mdprof_response" ++ filename_mangle(DataFileName) ++
    string.int_to_string(QueryNum).

:- func server_dir = string.

server_dir = "/var/tmp".

:- func filename_mangle(string) = string.

filename_mangle(FileName) = MangledFileName :-
    FileNameChars = string.to_char_list(FileName),
    MangledFileNameChars = filename_mangle_2(FileNameChars),
    MangledFileName = string.from_char_list(MangledFileNameChars).

    % This mangling scheme ensures that (a) the mangled filename doesn't
    % contain any slashes, and (b) two different original filenames will
    % always yield different mangled filenames.
    %
:- func filename_mangle_2(list(char)) = list(char).

filename_mangle_2([]) = [].
filename_mangle_2([First | Rest]) = MangledChars :-
    MangledRest = filename_mangle_2(Rest),
    ( First = ('/') ->
        MangledChars = [':', '.' | MangledRest]
    ; First = (':') ->
        MangledChars = [':', ':' | MangledRest]
    ;
        MangledChars = [First | MangledRest]
    ).

send_term(ToPipeName, Debug, Data, !IO) :-
    io.open_output(ToPipeName, Res, !IO),
    (
        Res = ok(ToStream),
        io.write(ToStream, Data, !IO),
        io.write_string(ToStream, ".\n", !IO),
        io.close_output(ToStream, !IO)
    ;
        Res = error(_),
        error("send_term: couldn't open pipe")
    ),
    (
        Debug = yes,
        io.open_output("/tmp/.send_term", Res2, !IO),
        (
            Res2 = ok(DebugStream),
            io.write(DebugStream, Data, !IO),
            io.write_string(DebugStream, ".\n", !IO),
            io.close_output(DebugStream, !IO)
        ;
            Res2 = error(_),
            error("send_term: couldn't debug")
        )
    ;
        Debug = no
    ).

send_string(ToPipeName, Debug, Data, !IO) :-
    io.open_output(ToPipeName, Res, !IO),
    (
        Res = ok(ToStream),
        io.write_string(ToStream, Data, !IO),
        io.close_output(ToStream, !IO)
    ;
        Res = error(_),
        error("send_string: couldn't open pipe")
    ),
    (
        Debug = yes,
        io.open_output("/tmp/.send_string", Res2, !IO),
        (
            Res2 = ok(DebugStream),
            io.write_string(DebugStream, Data, !IO),
            io.close_output(DebugStream, !IO)
        ;
            Res2 = error(_),
            error("send_string: couldn't debug")
        )
    ;
        Debug = no
    ).

recv_term(FromPipeName, Debug, Resp, !IO) :-
    io.open_input(FromPipeName, Res0, !IO),
    (
        Res0 = ok(FromStream),
        io.read(FromStream, Res1, !IO),
        (
            Res1 = ok(Resp0),
            Resp = Resp0
        ;
            Res1 = eof,
            error("recv_term: read failed")
        ;
            Res1 = error(_, _),
            error("recv_term: read failed")
        ),
        io.close_input(FromStream, !IO),
        (
            Debug = yes,
            io.open_output("/tmp/.recv_term", Res2, !IO),
            (
                Res2 = ok(DebugStream),
                io.write(DebugStream, Res1, !IO),
                io.write_string(DebugStream, ".\n", !IO),
                io.close_output(DebugStream, !IO)
            ;
                Res2 = error(_),
                error("recv_term: couldn't debug")
            )
        ;
            Debug = no
        )
    ;
        Res0 = error(_),
        error("recv_term: couldn't open pipe")
    ).

recv_string(FromPipeName, Debug, Resp, !IO) :-
    io.open_input(FromPipeName, Res0, !IO),
    (
        Res0 = ok(FromStream),
        io.read_file_as_string(FromStream, Res1, !IO),
        (
            Res1 = ok(Resp0),
            Resp = Resp0
        ;
            Res1 = error(_, _),
            error("recv_string: read failed")
        ),
        io.close_input(FromStream, !IO),
        (
            Debug = yes,
            io.open_output("/tmp/.recv_string", Res2, !IO),
            (
                Res2 = ok(DebugStream),
                io.write(DebugStream, Res1, !IO),
                io.write_string(DebugStream, ".\n", !IO),
                io.close_output(DebugStream, !IO)
            ;
                Res2 = error(_),
                error("recv_string: couldn't debug")
            )
        ;
            Debug = no
        )
    ;
        Res0 = error(_),
        error("recv_term: couldn't open pipe")
    ).

%-----------------------------------------------------------------------------%
:- end_module interface.
%-----------------------------------------------------------------------------%
