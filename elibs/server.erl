-module(server).
-export([start_link/0, init/1]).

start_link() ->
  proc_lib:start_link(?MODULE, init, [self()]).

init(Parent) ->
  read_conf(),
  LSock = try_listen(10),
  proc_lib:init_ack(Parent, {ok, self()}),
  loop(LSock).
  
read_conf() ->
  {ok, Conf} = application:get_env(conf),
  io:format("Using conf file ~p~n", [Conf]),
  conf:read_conf(Conf).
  
try_listen(0) ->
  io:format("Could not listen on port 9418~n");
try_listen(Times) ->
  Res = gen_tcp:listen(9418, [list, {packet, 0}, {active, false}]),
  case Res of
    {ok, LSock} ->
      io:format("Listening on port 9418~n"),
      LSock;
    {error, Reason} ->
      io:format("Could not listen on port 9418: ~p~n", [Reason]),
      timer:sleep(5000),
      try_listen(Times - 1)
  end.
    
loop(LSock) ->
  {ok, Sock} = gen_tcp:accept(LSock),
  spawn(fun() -> handle_method(Sock) end),
  loop(LSock).
  
handle_method(Sock) ->
  % get the requested method
  {ok, Header} = gen_tcp:recv(Sock, 0),
  {ok, Host} = extract_host(Header),
  Method = extract_method_name(Header),
  
  io:format("host = ~p~n", [Host]),
  
  % dispatch
  case Method of
    {ok, "upload-pack"} ->
      handle_upload_pack(Sock, Header);
    invalid ->
      gen_tcp:send(Sock, "Invalid method declaration. Upgrade to the latest git.\n"),
      ok = gen_tcp:close(Sock)
  end.
  
handle_upload_pack(Sock, Header) ->
  try
    handle_upload_pack_impl(Sock, Header)
  catch
    throw:{no_such_repo, Repo} ->
      handle_upload_pack_nosuchrepo(Sock, Repo);
    throw:{permission_denied, Repo} ->
      handle_upload_pack_permission_denied(Sock, Repo)
  end.

handle_upload_pack_impl(Sock, Header) ->
  Root = "/Users/tom/dev/sandbox/git/",
  
  % extract and normalize the repo path
  {ok, Path} = extract_repo_path(Header),
  {ok, NormalizedPath} = normalize_path(Path),
  FullPath = Root ++ NormalizedPath,
  
  % check for repo existence
  case file_exists(FullPath) of
    false -> throw({no_such_repo, FullPath});
    true -> ok
  end,
  
  % check for git-daemon-export-ok file
  GitDaemonExportOkFilePath = filename:join([FullPath, "git-daemon-export-ok"]),
  case file_exists(GitDaemonExportOkFilePath) of
    false -> throw({permission_denied, GitDaemonExportOkFilePath});
    true -> ok
  end,
  
  % make the port
  Command = "git upload-pack " ++ FullPath,
  Port = open_port({spawn, Command}, []),
  
  % the initial output from git-upload-pack lists the SHA1s of each head.
  % data completion is denoted by "0000" on it's own line.
  % this is sent back immediately to the client.
  Index = gather_out(Port),
  gen_tcp:send(Sock, Index),
  
  % once the client receives the index data, it will demand that specific
  % revisions be packaged and sent back. this demand will be forwarded to
  % git-upload-pack.
  Demand = gather_demand(Sock),
  port_command(Port, Demand),
  
  % in response to the demand, git-upload-pack will stream out the requested
  % pack information. data completion is denoted by "0000".
  stream_out(Port, Sock),
  
  % close connection
  ok = gen_tcp:close(Sock).

handle_upload_pack_nosuchrepo(Sock, Repo) ->
  io:format("no such repo: ~p~n", [Repo]),
  ok = gen_tcp:close(Sock).
  
handle_upload_pack_permission_denied(Sock, Repo) ->
  io:format("permission denied to repo: ~p~n", [Repo]),
  ok = gen_tcp:close(Sock).

gather_demand(Sock) ->
  gather_demand(Sock, "").
gather_demand(Sock, DataSoFar) ->
  {ok, Data} = gen_tcp:recv(Sock, 0),
  TotalData = DataSoFar ++ Data,
  case regexp:first_match(TotalData, "\n00000009done\n$") of
    {match, _Start, _Length} ->
      TotalData;
    _Else ->
      gather_demand(Sock, TotalData)
  end.

gather_out(Port) ->
  gather_out(Port, "").
gather_out(Port, DataSoFar) ->
  % io:format("gather-out "),
  {data, Data} = readline(Port),
  TotalData = DataSoFar ++ Data,
  case regexp:first_match(TotalData, "\n0000$") of
    {match, _Start, _Length} ->
      TotalData;
    _Else ->
      gather_out(Port, TotalData)
  end.
  
stream_out(Port, Sock) ->
  % io:format("stream out "),
  {data, Data} = readline(Port),
  % io:format("~p", [Data]),
  gen_tcp:send(Sock, Data),
  case regexp:first_match(Data, "0000$") of
    {match, _Start, _Length} ->
      done;
    _Else ->
      stream_out(Port, Sock)
  end.

readline(Port) ->
  receive
    {Port, {data, Data}} ->
      {data, Data};
    Msg ->
      io:format("unknown message ~p~n", [Msg]),
      {error, Msg}
    after 15000 ->
      io:format("timed out waiting for port~n"),
      {error, timeout}
  end.
  
extract_method_name(Header) ->
  case regexp:match(Header, "....git[ -][a-z\-]+ ") of
    {match, Start, Length} ->
      {ok, string:substr(Header, Start + 8, Length - 9)};
    _Else ->
      invalid
  end.
  
extract_host(Header) ->
  case regexp:match(string:to_lower(Header), "\000host=[^\000]+\000") of
    {match, Start, Length} ->
      {ok, string:substr(Header, Start + 6, Length - 7)};
    _Else ->
      {ok, "invalid"}
  end.
  
extract_repo_path(Header) ->
  case regexp:match(Header, " /[^\000]+\000") of
    {match, Start, Length} ->
      {ok, string:substr(Header, Start + 2, Length - 3)};
    _Else ->
      invalid
  end.
  
normalize_path(Path) ->
  Parts = string:tokens(Path, "/"),
  [Name | _RestParts] = Parts,
  SafeName = Name ++ Name,
  [A, B, C | _RestName] = SafeName,
  {ok, string:join([[A], [B], [C]] ++ Parts, "/")}.
  
file_exists(FullPath) ->
  case file:read_file_info(FullPath) of
    {ok, _Info} ->
      true;
    {error, _Reason} ->
      false
  end.