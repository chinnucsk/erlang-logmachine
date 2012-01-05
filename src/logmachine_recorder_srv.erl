%%%-------------------------------------------------------------------
%%% @author <vjache@gmail.com>
%%% @copyright (C) 2011, Vyacheslav Vorobyov.  All Rights Reserved.
%%% Licensed under the Apache License, Version 2.0 (the "License");
%%% you may not use this file except in compliance with the License.
%%% You may obtain a copy of the License at
%%%
%%% http://www.apache.org/licenses/LICENSE-2.0
%%%
%%% Unless required by applicable law or agreed to in writing, software
%%% distributed under the License is distributed on an "AS IS" BASIS,
%%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%% See the License for the specific language governing permissions and
%%% limitations under the License.
%%%
%%% @doc
%%%    TODO: Document it.
%%% @end
%%% Created : Nov 05, 2011
%%%-------------------------------------------------------------------------------
-module(logmachine_recorder_srv).

-behaviour(gen_server).
%% --------------------------------------------------------------------
%% Include files
%% --------------------------------------------------------------------

-include("log.hrl").
-include("types.hrl").

-import(logmachine_util,[make_name/1,send_after/2,to_millis/1,now_to_millis/1,millis_to_now/1,ensure_dir/1]).

-define(ALARM_REOPEN, {alarm, reopen}).
-define(ALARM_ARCHIVE, {alarm, archive}).

%% --------------------------------------------------------------------
%% External exports
-export([start_link_archiver/1,
         start_link_recorder/1, 
         get_history/3, 
         get_history/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state_recorder, {instance_name, reopen_period, last_timestamp}).
-record(state_archiver, {instance_name, archive_period, archive_after}).

%% ====================================================================
%% External functions
%% ====================================================================

start_link_recorder(InstanceName) ->
    SrvName=get_recorder_srv_name(InstanceName),
    gen_server:start_link({local, SrvName}, ?MODULE, {recorder,InstanceName}, []).
start_link_archiver(InstanceName) ->
    SrvName=get_archiver_srv_name(InstanceName),
    gen_server:start_link({local, SrvName}, ?MODULE, {archiver, InstanceName}, []).

-spec get_history(InstanceName :: atom(), 
                   FromTimestamp :: timestamp(), 
                   ToTimestamp :: timestamp()) -> zlists:zlist(history_entry()) .
get_history(InstanceName, FromTimestamp, ToTimestamp) ->
    History=get_history(InstanceName, FromTimestamp),
    if  ToTimestamp == now orelse 
        ToTimestamp == undefined ->
           History;
       true ->
           zlists:takewhile(fun({T,_Q}) ->  T < ToTimestamp end, History)
    end.

-spec get_history(
        InstanceName :: atom(), 
        From :: timestamp()) -> zlists:zlist(history_entry()) .
get_history(InstanceName, From) ->
    LogDir=get_data_dir(InstanceName),
    LogFilesToScan=get_log_files(InstanceName, From),
    ?ECHO({"LOGS_TO_SCAN",zlists:expand(LogFilesToScan)}),
    zlists:dropwhile(
      fun({T,_})-> T<From end,
      zlists:generate(
        LogFilesToScan, 
        fun(Filename)-> 
                {AccLogs, _}=disk_log:accessible_logs(),
                case lists:member(Filename, AccLogs) of
                    true ->
                        ok;
                    false ->
                        case disk_log:open([{name, Filename},
                                            {linkto,whereis(get_archiver_srv_name(InstanceName))},
                                            {mode,read_only},
                                            {file, filename:join(LogDir, Filename)}]) of
                            {ok,_} ->  ok;
                            {repaired, _, _, _} -> ok;
                            {error, Reason} -> throw(Reason)
                        end
                end,
                zlists_disk_log:read(Filename)
        end)).
%% ====================================================================
%% Server functions
%% ====================================================================

get_recorder_srv_name(InstanceName) ->
    make_name([InstanceName, recorder, srv]).

get_archiver_srv_name(InstanceName) ->
    make_name([InstanceName, archiver, srv]).

get_data_dir(InstanceName) ->
    logmachine_app:get_instance_env(
      InstanceName, 
      dir,
      fun() -> filename:join("./data", InstanceName) end).

get_arch_data_dir(InstanceName) ->
    logmachine_app:get_instance_env(
      InstanceName, 
      arch_dir,
      fun() -> filename:join(get_data_dir(InstanceName), "archive") end).

get_log_file(InstanceName) ->
    filename:join(get_data_dir(InstanceName), InstanceName)++".log".

get_reopen_period(InstanceName) ->
    logmachine_app:get_instance_env(
      InstanceName, 
      reopen_period,
      {30, min}).

get_archive_period(InstanceName) ->
    logmachine_app:get_instance_env(
      InstanceName, 
      archive_period,
      {60, min}).

get_archive_after(InstanceName) ->
    logmachine_app:get_instance_env(
      InstanceName, 
      archive_after,
      {7, day}).

% Init recorder
init({recorder,InstanceName}) ->
	ok=logmachine_receiver_srv:subscribe(
	  InstanceName, self(), {gen_server,cast}),
    ensure_dir(get_data_dir(InstanceName)),
    open_disk_log(InstanceName),
    ReoPeriod=get_reopen_period(InstanceName),
    send_after(ReoPeriod, ?ALARM_REOPEN),
    {ok, #state_recorder{instance_name=InstanceName,reopen_period=ReoPeriod}};
% Init archiver
init({archiver,InstanceName}) ->
    ensure_dir(get_arch_data_dir(InstanceName)),
    ArchPeriod=get_archive_period(InstanceName),
    ArchAfter=get_archive_after(InstanceName), 
    send_after(ArchPeriod, ?ALARM_ARCHIVE),
    {ok, #state_archiver{instance_name=InstanceName,archive_period=ArchPeriod,archive_after=ArchAfter}}.

open_disk_log(InstanceName) ->
    LogFile=get_log_file(InstanceName),
    case disk_log:open([{name,InstanceName}, {file, LogFile}]) of
        {ok,_} -> ok;
        {repaired,_,
         {recovered, _},
         {badbytes, _}} -> ok;
        {error, Reason} -> throw(Reason)
    end.

handle_call(_Request, _From, State) ->
    {reply, {error, unsupported}, State}.

% Record event
handle_cast({Timestamp,_Data}=Event, 
			#state_recorder{instance_name=Name}=State) ->
    ok=disk_log:log(Name, Event),
    {noreply, State#state_recorder{last_timestamp=Timestamp} };
% Skip message
handle_cast(_Msg, State) ->
	{noreply, State}.

% Recorder clauses
handle_info(?ALARM_REOPEN, #state_recorder{instance_name=Name,reopen_period=ReoPeriod}=State) ->
    do_reopen(Name,now()),
    send_after(ReoPeriod, ?ALARM_REOPEN),
    {noreply, State};
% Archiver clauses
handle_info(?ALARM_ARCHIVE, 
            #state_archiver{instance_name=Name,
                            archive_period=ArchPeriod,
                            archive_after=ArchAfter}=State) ->
    do_archive(Name, ArchAfter),
    send_after(ArchPeriod, ?ALARM_ARCHIVE),
    {noreply, State};
% Universal clauses
handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%% --------------------------------------------------------------------
%%% Internal functions
%% --------------------------------------------------------------------

do_archive(InstanceName, ArchAfter) ->
    InfimumMillis=now_to_millis(now()) - to_millis(ArchAfter),
    try do_move(InstanceName,InfimumMillis)
    catch _:Reason1 -> ?LOG_ERROR([{move_failed,Reason1}, {stacktrace, erlang:get_stacktrace()}]) end,
    try do_zip(InstanceName)
    catch _:Reason2 -> ?LOG_ERROR([{zip_failed,Reason2}, {stacktrace, erlang:get_stacktrace()}]) end.

do_move(InstanceName,InfimumMillis) ->
    ArchDir=get_arch_data_dir(InstanceName),
    LogDir=get_data_dir(InstanceName),
    DateTime=calendar:now_to_universal_time(millis_to_now(InfimumMillis)),
    PseudoFilename=reopened_filename(InstanceName,DateTime,InfimumMillis rem 1000),
    case filelib:wildcard(get_wildcard(InstanceName), LogDir) of
        [] -> ok;
        Files ->
            AFiles=lists:takewhile(
                     fun(E)-> PseudoFilename > E end, 
                     lists:sort(Files)),
            [begin
                 NewAFile=filename:join(ArchDir,filename:basename(AFile)),
                 ok=file:rename(AFile, NewAFile)
             end ||AFile <- [filename:join(LogDir,FN)|| FN <- AFiles]],
            ok
    end.

do_zip(InstanceName) ->
    ArchDir=get_arch_data_dir(InstanceName),
    [begin
         File=filename:join(ArchDir,FN),
         ZipAFile=File++".zip",
         case filelib:is_regular(ZipAFile) of
             false ->
                 {ok,_}=zip:create(ZipAFile, [FN], [{cwd,ArchDir}]);
             _ ->
                ok
         end,
         file:delete(File)
     end || FN <- filelib:wildcard(get_wildcard(InstanceName), ArchDir),
            filename:extension(FN)=/=".zip"],
    ok.

do_reopen(InstanceName, undefined) ->
    do_reopen(InstanceName, now()); %TODO: read log for last timestamp instead of now()
do_reopen(InstanceName, {_,_,Micros}=Timestamp) ->
    DateTime=calendar:now_to_universal_time(Timestamp),
    Filename=filename:join(
               get_data_dir(InstanceName),
               reopened_filename(InstanceName, DateTime, Micros div 1000)),
    ok=disk_log:reopen(InstanceName, Filename).

get_wildcard(InstanceName) ->
    lists:flatten(io_lib:format("~p_????-??-??_*", [InstanceName])).
reopened_filename(InstanceName, {{Y,Mon,D},{H,Min,S}}, Millis) ->
    lists:flatten(io_lib:format(
                    "~s_~.4.0w-~.2.0w-~.2.0w_~.2.0w-~.2.0w-~.2.0w.~.3.0wZ",
                    [InstanceName, Y, Mon, D, H, Min, S, Millis])).

-spec get_log_files(
        InstanceName :: atom(), 
        From :: timestamp()) -> zlists:zlist(file:filename()) .
get_log_files(InstanceName, From) ->
    LogDir=get_data_dir(InstanceName),
    Now=now(),
    if From >= Now ->
           [];
       true ->
           FromDateTime=calendar:now_to_universal_time(From),
           get_log_files(
             InstanceName,
             LogDir,
             reopened_filename(InstanceName, FromDateTime, 0))
    end.

get_log_files(InstanceName, LogDir, FromFilenameExcl) ->
    case filelib:wildcard(
		   get_wildcard(InstanceName), LogDir) of
        [] -> [InstanceName];
        Files ->
            case lists:dropwhile(
                     fun(E)-> E =< FromFilenameExcl end, 
                     lists:sort(Files)) of
                [] -> [InstanceName];
                [F|_] -> [F | fun()-> get_log_files(InstanceName, LogDir, F) end]
            end
    end.
