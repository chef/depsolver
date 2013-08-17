%% -*- erlang-indent-level: 4; indent-tabs-mode: nil; fill-column: 100 -*-
%% ex: ts=4 sw=4 et
%%
%% Copyright 2012 Opscode, Inc. All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% @author Eric Merritt <ericbmerritt@gmail.com>
%% @author Mark Anderson <mark@opscode.com>
%%
%%%-------------------------------------------------------------------
%%% @doc
%%% This is a dependency constraint solver. You add your 'world' to the
%%% solver. That is the packages that exist, their versions and their
%%% dependencies. Then give the system a set of targets and ask it to solve.
%%%
%%%  Lets say our world looks as follows
%%%
%%%      app1 that has versions "0.1"
%%%        depends on app3 any version greater then "0.2"
%%%       "0.2" with no dependencies
%%%       "0.3" with no dependencies
%%%
%%%      app2 that has versions "0.1" with no dependencies
%%%       "0.2" that depends on app3 exactly "0.3"
%%%       "0.3" with no dependencies
%%%
%%%      app3 that has versions
%%%       "0.1", "0.2" and "0.3" all with no dependencies
%%%
%%% we can add this world to the system all at once as follows
%%%
%%%      Graph0 = depsolver:new_graph(),
%%%      Graph1 = depsolver:add_packages(
%%%             [{app1, [{"0.1", [{app2, "0.2"},
%%%                               {app3, "0.2", '>='}]},
%%%                               {"0.2", []},
%%%                               {"0.3", []}]},
%%%              {app2, [{"0.1", []},
%%%                       {"0.2",[{app3, "0.3"}]},
%%%                       {"0.3", []}]},
%%%              {app3, [{"0.1", []},
%%%                      {"0.2", []},
%%%                      {"0.3", []}]}]).
%%%
%%% We can also build it up incrementally using the other add_package and
%%% add_package_version functions.
%%%
%%% Finally, once we have built up the graph we can ask depsolver to solve the
%%% dependency constraints. That is to give us a list of valid dependencies by
%%% using the solve function. Lets say we want the app3 version "0.3" and all of
%%% its resolved dependencies. We could call solve as follows.
%%%
%%%    depsolver:solve(Graph1, [{app3, "0.3"}]).
%%%
%%% That will give us the completely resolved dependencies including app3
%%% itself. Lets be a little more flexible. Lets ask for a graph that is rooted
%%% in anything greater then or equal to app3 "0.3". We could do that by
%%%
%%%    depsolver:solve(Graph1, [{app3, "0.3", '>='}]).
%%%
%%% Of course, you can specify any number of goals at the top level.
%%% @end
%%%-------------------------------------------------------------------
-module(depsolver_gecode).

-include_lib("eunit/include/eunit.hrl").

%% Public Api
-export([
         new_graph/0,
         solve/3,
         solve/2,
         add_packages/2,
         add_package/3,
         add_package_version/3,
         add_package_version/4,
         format_error/1]).

-export_type([t/0,
              pkg/0,
              constraint_op/0,
              pkg_name/0,
              vsn/0,
              constraint/0,
              dependency_set/0]).

-export_type([dep_graph/0, constraints/0,
              ordered_constraints/0, fail_info/0,
              fail_detail/0]).
%%============================================================================
%% type
%%============================================================================
-type dep_graph() :: gb_tree().
-opaque t() :: {?MODULE, dep_graph()}.
-type pkg() :: {pkg_name(), vsn()}.
-type pkg_name() :: binary() | atom().
-type raw_vsn() :: ec_semver:any_version().

-type vsn() :: 'NO_VSN'
             | ec_semver:semver().

-type constraint_op() ::
        '=' | gte | '>=' | lte | '<='
      | gt | '>' | lt | '<' | pes | '~>' | between.

-type raw_constraint() :: pkg_name()
                        | {pkg_name(), raw_vsn()}
                        | {pkg_name(), raw_vsn(), constraint_op()}
                        | {pkg_name(), raw_vsn(), vsn(), between}.

-type constraint() :: pkg_name()
                    | {pkg_name(), vsn()}
                    | {pkg_name(), vsn(), constraint_op()}
                    | {pkg_name(), vsn(), vsn(), between}.


-type vsn_constraint() :: {raw_vsn(), [raw_constraint()]}.
-type dependency_set() :: {pkg_name(), [vsn_constraint()]}.

%% Internal Types
-type constraints() :: [constraint()].
-type ordered_constraints() :: [{pkg_name(), constraints()}].
-type fail_info() :: {[pkg()], ordered_constraints()}.
-type fail_detail() :: {fail, [fail_info()]} | {missing, pkg_name()}.

%%============================================================================
%% Macros
%%============================================================================
-define(DEFAULT_TIMEOUT, 2000).
-define(RUNLIST, runlist).
-define(RUNLIST_VERSION, {0,0,0}).
%%============================================================================
%% API
%%============================================================================
%% @doc create a new empty dependency graph
-spec new_graph() -> t().
new_graph() ->
    {?MODULE, gb_trees:empty()}.

%% @doc add a complete set of list of packages to the graph. Where the package
%% consists of the name and a list of versions and dependencies.
%%
%% ``` depsolver:add_packages(Graph,
%%               [{app1, [{"0.1", [{app2, "0.2"},
%%                                 {app3, "0.2", '>='}]},
%%                                 {"0.2", []},
%%                                 {"0.3", []}]},
%%                 {app2, [{"0.1", []},
%%                         {"0.2",[{app3, "0.3"}]},
%%                         {"0.3", []}]},
%%                 {app3, [{"0.1", []},
%%                         {"0.2", []},
%%                         {"0.3", []}]}])
%% '''
-spec add_packages(t(),[dependency_set()]) -> t().
add_packages(Dom0, Info)
  when is_list(Info) ->
    lists:foldl(fun({Pkg, VsnInfo}, Dom1) ->
                        add_package(Dom1, Pkg, VsnInfo)
                end, Dom0, Info).

%% @doc add a single package to the graph, where it consists of a package name
%% and its versions and thier dependencies.
%%  ```depsolver:add_package(Graph, app1, [{"0.1", [{app2, "0.2"},
%%                                              {app3, "0.2", '>='}]},
%%                                              {"0.2", []},
%%                                              {"0.3", []}]}]).
%% '''
-spec add_package(t(),pkg_name(),[vsn_constraint()]) -> t().
add_package(State, Pkg, Versions)
  when is_list(Versions) ->
    lists:foldl(fun({Vsn, Constraints}, Dom1) ->
                        add_package_version(Dom1, Pkg, Vsn, Constraints);
                   (Version, Dom1) ->
                        add_package_version(Dom1, Pkg, Version, [])
                end, State, Versions).

%% @doc add a set of dependencies to a specific package and version.
%% and its versions and thier dependencies.
%%  ```depsolver:add_package(Graph, app1, "0.1", [{app2, "0.2"},
%%                                              {app3, "0.2", '>='}]},
%%                                              {"0.2", []},
%%                                              {"0.3", []}]).
%% '''
-spec add_package_version(t(), pkg_name(), raw_vsn(), [raw_constraint()]) -> t().
add_package_version({?MODULE, Dom0}, RawPkg, RawVsn, RawPkgConstraints) ->
    Pkg = fix_pkg(RawPkg),
    Vsn = parse_version(RawVsn),
    %% Incoming constraints are raw
    %% and need to be fixed
    PkgConstraints = [fix_con(PkgConstraint) ||
                         PkgConstraint <- RawPkgConstraints],
    Info2 =
        case gb_trees:lookup(Pkg, Dom0) of
            {value, Info0} ->
                case lists:keytake(Vsn, 1, Info0) of
                    {value, {Vsn, Constraints}, Info1} ->
                        [{Vsn, join_constraints(Constraints,
                                                PkgConstraints)}
                         | Info1];
                    false ->
                        [{Vsn,  PkgConstraints}  | Info0]
                end;
            none ->
                [{Vsn, PkgConstraints}]
        end,
    {?MODULE, gb_trees:enter(Pkg, Info2, Dom0)}.

%% @doc add a package and version to the dependency graph with no dependency
%% constraints, dependency constraints can always be added after the fact.
%%
%% ```depsolver:add_package_version(Graph, app1, "0.1").'''
-spec add_package_version(t(),pkg_name(),raw_vsn()) -> t().
add_package_version(State, Pkg, Vsn) ->
    add_package_version(State, Pkg, Vsn, []).

solve({?MODULE, DepGraph0}, RawGoals, _Timeout) when erlang:length(RawGoals) > 0 ->
    %% TODO: Implement timeout behavior here
    solve({?MODULE, DepGraph0}, RawGoals).

%% @doc Given a set of goals (in the form of constrains) find a set of packages
%% and versions that satisfy all constraints. If no solution can be found then
%% an exception is thrown.
%% ``` depsolver:solve(State, [{app1, "0.1", '>='}]).'''
-spec solve(t(),[constraint()]) -> {ok, [pkg()]} | {error, term()}.
solve({?MODULE, DepGraph0}, RawGoals) when erlang:length(RawGoals) > 0 ->
    case setup(DepGraph0, RawGoals) of
        {error, {unreachable_package, Name}} ->
            {error, {unreachable_package, Name}};
        {ok, Pid, Problem} ->
            case solve_and_release(Pid) of
                {solution,
                 {{state, invalid},
                  {disabled, _Disabled_Count},
                  {packages, _PackageVersionIds}} = _Results} ->
                    %% Find smallest prefix of the runlist that still fails
                    culprit_search(DepGraph0, RawGoals, 1);
                {solution,
                 {{state, valid},
                  {disabled, _Disabled_Count},
                  {packages, PackageVersionIds}}} ->
                    {ok, unmap_packed_solution(PackageVersionIds, Problem)};
                {solution, none} ->
                   {error, no_solution};
                {error, Reason} ->
                   {error, Reason}
            end
    end.


%% @doc this tries sucessively longer prefixes of the runlist until we make it fail. The goal is to
%% trim the list down a little bit to simplify what people see as broken. Certainly more work could
%% be done to simplify things, but we don't want to spend excessive CPU time on this either.
%%
%% There is some excess work being done, in that we set the problem up mutliple times from scratch,
%% but we're only changing the runlist. Also, what we're doing with the list prefixes search
%% probably could be improved, but for the time being we're assuming the runlists are short enough
%% that quadratic behavior isn't important.
%%
%% Technically the length guard shouldn't be needed, since we know the full runlist fails to solve
culprit_search(DepGraph0, RawGoals, Length) when Length =< length(RawGoals) ->
    NewGoals = lists:sublist(RawGoals, Length),
    {ok, Pid, Problem} = setup(DepGraph0, NewGoals),
    case solve_and_release(Pid) of
        {solution, {{state, valid}, {disabled, _Disabled_Count}, {packages, _PackageVersionIds}}} ->
            %% This solution still now works, so it probably doesn't include our troublemaker,
            culprit_search(DepGraph0, RawGoals, Length+1);
        {solution,
         {{state, invalid},
          {disabled, _Disabled_Count},
          {packages, PackageVersionIds}} = _Results} ->
            %% Ok, we've found the first breaking item
            Disabled = extract_disabled(PackageVersionIds, Problem),
            {error, {no_solution, NewGoals, Disabled}}
    end.

solve_and_release(Pid) ->
    Solution = depselector:solve(Pid),
    release_pool_worker(Solution, Pid),
    Solution.

release_pool_worker({error, {timeout, _Where}}, Pid) ->
    pooler:return_member(depselector, Pid, fail);
release_pool_worker(_Solution, Pid) ->
    pooler:return_member(depselector, Pid, ok).

setup(DepGraph0, RawGoals) when erlang:length(RawGoals) > 0 ->
    case pooler:take_member(depselector) of
        error_no_members ->
            {error, {no_depsolver_workers}};
        Pid ->
            setup(Pid, DepGraph0, RawGoals)
    end.

setup(Pid, DepGraph0, RawGoals) ->
    try
        case trim_unreachable_packages(DepGraph0, RawGoals) of
            Error = {error, _} ->
                Error;
            DepGraph1 ->
                %% Use this to get more debug output...
                %% depselector:new_problem_with_debug(Pid, "TEST", gb_trees:size(DepGraph0) + 1),
                depselector:new_problem(Pid, "TEST", gb_trees:size(DepGraph0) + 1),
                Problem = generate_versions(Pid, DepGraph0),
                generate_constraints(Pid, DepGraph0, RawGoals, Problem),
                {ok, Pid, Problem}
        end
    catch
        throw:{unreachable_package, Name} ->
            pooler:return_member(depselector, Pid, ok),
            {error, {unreachable_package, Name}}
    end.

%% Instantiate versions
%%
%% Note: gecode does naive bounds propagation at every post, which means that any package with
%% exactly one version is considered bound and its dependencies propagated even though there might
%% not be a solution constraint that requires that package to be bound, which means that
%% otherwise-irrelevant constraints (e.g. A1->B1 when the solution constraint is B=2 and there is
%% nothing to induce a dependency on A) can cause unsatisfiability. Therefore, we want every package
%% to have at least two versions, one of which is neither the target of other packages' dependencies
%% nor induces other dependencies. Package version id -1 serves this purpose.
%%
%% So for example, a package with only a single version available would be encoded with range -1, 0
%% inclusive, and a package with 4 versions available would be encoded with range -1, 3.
%%
%% If the final solution results in a package version set to -1, we can assume it was never used.
%%
%% We may likewise want to leave packages with no versions (the target of an invalid dependency)
%% with two versions in order to allow the solver to explore the invalid portion of the state space
%% instead of naively limiting it for the purposes of having failure count heuristics?
generate_versions(Pid, DepGraph0) ->
    Versions0 = version_manager:new(),
    %% the runlist is treated as a virtual package.
    Versions1 = version_manager:add_package(?RUNLIST, [?RUNLIST_VERSION], Versions0),
    depselector:add_package(Pid, 0,0,0),
    depselector:mark_package_required(Pid, 0),

    %% Add all the other packages
    add_versions_for_package(Pid, gb_trees:next(gb_trees:iterator(DepGraph0)), Versions1).

add_versions_for_package(_Pid, none, Acc) ->
    Acc;
add_versions_for_package(Pid, {PkgName, VersionConstraints, Iterator}, Acc) ->
    {Versions, _} = lists:unzip(VersionConstraints),
    NAcc = version_manager:add_package(PkgName, Versions, Acc),
    %% -1 denotes the possibility of an unused package.
    %% While the named versions are always in the range 0...N, we
    %% may want to mark a package as not used As soon as a package is mentioned in the dependency
    %% chain, it creates a constraint limiting it to be 0 or greater, but until it is mentioned, it
    %% can be -1, and hence unused.
    MinVersion = -1,
    MaxVersion = version_manager:get_version_max_for_package(PkgName, NAcc),
%%    ?debugFmt("~p: ~p~n", [PkgName, MaxVersion]),
    depselector:add_package(Pid, MinVersion, MaxVersion, 0),
    add_versions_for_package(Pid, gb_trees:next(Iterator), NAcc).



%% Constraints for each version
generate_constraints(Pid, DepGraph, RawGoals, Problem) ->
    %% The runlist package is a synthetic package
    add_constraints_for_package(Pid, ?RUNLIST, [{ ?RUNLIST_VERSION, RawGoals }], Problem),
    gb_trees:map(fun(N,C) -> add_constraints_for_package(Pid, N,C,Problem) end, DepGraph).

add_constraints_for_package(Pid, PkgName, VersionConstraints, Problem) ->
    AddVersionConstraint =
        fun(Version, Constraints) ->
                {PkgIndex, VersionId} = version_manager:get_version_id(PkgName, Version, Problem),
                [ add_constraint_element(Pid, Constraint, PkgIndex, VersionId, Problem) || Constraint <- Constraints]
        end,
    [AddVersionConstraint(PkgVersion, ConstraintList) || {PkgVersion, ConstraintList} <- VersionConstraints].

add_constraint_element(Pid, {DepPkgName, Version}, PkgIndex, VersionId, Problem) ->
    add_constraint_element(Pid, {DepPkgName, Version, eq}, PkgIndex, VersionId, Problem);
add_constraint_element(Pid, {DepPkgName, DepPkgVersion, Type}, PkgIndex, VersionId, Problem) ->
%%    ?debugFmt("DP: ~p C: ~p ~p~n", [DepPkgName, DepPkgVersion, Type]),
    add_constraint_element_helper(Pid, DepPkgName, {DepPkgVersion, Type}, PkgIndex, VersionId, Problem);
add_constraint_element(Pid, {DepPkgName, DepPkgVersion1, DepPkgVersion2, Type}, PkgIndex, VersionId, Problem) ->
%%    ?debugFmt("DP: ~p C: ~p ~p ~p~n", [DepPkgName, DepPkgVersion1, DepPkgVersion2, Type]),
    add_constraint_element_helper(Pid, DepPkgName, {DepPkgVersion1, DepPkgVersion2, Type},
                                  PkgIndex, VersionId, Problem);
add_constraint_element(Pid, DepPkgName, PkgIndex, VersionId, Problem) when not is_tuple(DepPkgName) ->
%%    ?debugFmt("DP: ~p C: ~p ~n", [DepPkgName, any]),
    add_constraint_element_helper(Pid, DepPkgName, any, PkgIndex, VersionId, Problem).

add_constraint_element_helper(Pid, DepPkgName, Constraint, PkgIndex, VersionId, Problem) ->
    case version_manager:map_constraint(DepPkgName, Constraint, Problem) of
        {DepPkgIndex, {Min,Max}} ->
            depselector:add_version_constraint(Pid, PkgIndex, VersionId, DepPkgIndex, Min, Max);
        no_matching_package ->
            throw( {unreachable_package, DepPkgName} )
    end.

extract_disabled(PackageVersionIds, Problem) ->
    [version_manager:unmap_constraint({PackageId, VersionId}, Problem) ||
        {PackageId, DisabledState, VersionId} <- PackageVersionIds,
        DisabledState =:= 1 ].

unmap_packed_solution(PackageVersionIds, Problem) ->
    %% The runlist is a synthetic package, and should be filtered out
    [{0,0,0} | PackageVersionIdsReal ] = PackageVersionIds,
%%    ?debugFmt("~p~n", [PackageVersionIds]),
    %% Note that the '0' filters out disabled packages.
    %% Packages with versions < 0 are not used, and can be ignored.
    PackageList = [version_manager:unmap_constraint({PackageId, VersionId}, Problem) ||
                      {PackageId, _Disabled=0, VersionId} <- PackageVersionIdsReal, VersionId >= 0],
    PackageList.

%% Parse a string version into a tuple based version
-spec parse_version(raw_vsn() | vsn()) -> vsn().
parse_version(RawVsn)
  when erlang:is_list(RawVsn);
       erlang:is_binary(RawVsn) ->
    ec_semver:parse(RawVsn);
parse_version(Vsn)
  when erlang:is_tuple(Vsn) ->
    Vsn.

%% @doc
%% fix the package name. If its a list turn it into a binary otherwise leave it as an atom
fix_pkg(Pkg) when is_list(Pkg) ->
    erlang:list_to_binary(Pkg);
fix_pkg(Pkg) when is_binary(Pkg); is_atom(Pkg) ->
    Pkg.

%% @doc
%% fix package. Take a package with a possible invalid version and fix it.
-spec fix_con(raw_constraint()) -> constraint().
fix_con({Pkg, Vsn}) ->
    {fix_pkg(Pkg), parse_version(Vsn)};
fix_con({Pkg, Vsn, CI}) ->
    {fix_pkg(Pkg), parse_version(Vsn), CI};
fix_con({Pkg, Vsn1, Vsn2, CI}) ->
    {fix_pkg(Pkg), parse_version(Vsn1),
     parse_version(Vsn2), CI};
fix_con(Pkg) ->
    fix_pkg(Pkg).


%% @doc given two lists of constraints join them in such a way that no
%% constraint is duplicated but the over all order of the constraints is
%% preserved. Order drives priority in this solver and is important for that
%% reason.
-spec join_constraints([constraint()], [constraint()]) ->
                              [constraint()].
join_constraints(NewConstraints, ExistingConstraints) ->
    ECSet = sets:from_list(ExistingConstraints),
    FilteredNewConstraints = [NC || NC <- NewConstraints,
                                    not sets:is_element(NC, ECSet)],
    ExistingConstraints ++ FilteredNewConstraints.


format_error({error, {overconstrained, Runlist, Disabled}}) ->
    erlang:iolist_to_binary(
      ["Unable to solve constraints, the following solutions were attempted \n\n",
       format_error_path("    ", {Runlist, Disabled})]);
format_error({error, {unreachable_package, Name}}) ->
    erlang:iolist_to_binary( ["Unable to find package", Name, "\n\n"]);
format_error(E) ->
    ?debugVal(E).


-spec format_error_path(string(), {[{[depsolver:constraint()], [depsolver:pkg()]}],
                                   [depsolver:constraint()]}) -> iolist().
format_error_path(CurrentIndent, {Roots, FailingDeps}) ->
    [CurrentIndent, "Unable to satisfy goal constraint",
     depsolver_culprit:add_s(Roots), " ", format_roots(Roots),
     " due to constraint", depsolver_culprit:add_s(FailingDeps), " on ",
     format_disabled(FailingDeps), "\n"].

format_roots(L) ->
    join_as_iolist([depsolver_culprit:format_constraint(fix_con(E)) || E <- L]).


%% We could certainly get fancier, but the version doesn't necessarily help much...
format_disabled(Disabled) ->
    join_as_iolist([App || {App, _Version} <- Disabled]).


to_iolist(A) when is_atom(A) ->
    atom_to_list(A);
to_iolist(B) when is_binary(B) ->
    B;
to_iolist(L) when is_list(L) ->
   L.

join_as_iolist(L) ->
    [_ | T] = lists:flatten([ [", ", to_iolist(E)] || E <-L ]),
    T.


%% @doc
%% given a Pkg | {Pkg, Vsn} | {Pkg, Vsn, Constraint} return Pkg
-spec dep_pkg(constraint()) -> pkg_name().
dep_pkg({Pkg, _Vsn}) ->
    Pkg;
dep_pkg({Pkg, _Vsn, _}) ->
    Pkg;
dep_pkg({Pkg, _Vsn1, _Vsn2, _}) ->
    Pkg;
dep_pkg(Pkg) when is_atom(Pkg) orelse is_binary(Pkg) ->
    Pkg.


%% @doc given a graph and a set of top level goals return a graph that contains
%% only those top level packages and those packages that might be required by
%% those packages.

%% We compute the recursive expansion of all cookbooks referenced by any version of a cookbook on
%% the run list, and remove any cookbooks that aren't ever used.
%%
%% We also add dummy cookbooks for missing ones. These cookbooks have no valid versions. This lets
%% us add constraints referencing such cookbooks; they simply cannot be satisfied due to the missing
%% cookbook.
%%
%% An alternate strategy would be to prune versions referencing missing cookbooks, reducing the
%% problem size further, but the current approach allows more useful error messages.
-spec trim_unreachable_packages(dep_graph(), [constraint()]) ->
                                       dep_graph() | {error, term()}.
trim_unreachable_packages(State, Goals) ->
    {_, NewState0} = new_graph(),
    lists:foldl(fun(_Pkg, Error={error, _}) ->
                        Error;
                   (Pkg, NewState1) ->
                        PkgName = dep_pkg(Pkg),
                        find_reachable_packages(State, NewState1, PkgName)
                end, NewState0, Goals).

%% @doc given a list of versions and the constraints for that version rewrite
%% the new graph to reflect the requirements of those versions.
-spec rewrite_vsns(dep_graph(), dep_graph(), [{vsn(), [constraint()]}]) ->
                          dep_graph() | {error, term()}.
rewrite_vsns(ExistingGraph, NewGraph0, Info) ->
    lists:foldl(fun(_, Error={error, _}) ->
                        Error;
                   ({_Vsn, Constraints}, NewGraph1) ->
                        lists:foldl(fun(_DepPkg, Error={error, _}) ->
                                            Error;
                                       (DepPkg, NewGraph2) ->
                                            DepPkgName = dep_pkg(DepPkg),
                                            find_reachable_packages(ExistingGraph,
                                                                    NewGraph2,
                                                                    DepPkgName)
                                    end, NewGraph1, Constraints)
                end, NewGraph0, Info).

%% @doc Rewrite the existing dep graph removing anything that is not reachable
%% required by the goals or any of its potential dependencies.
-spec find_reachable_packages(dep_graph(), dep_graph(), pkg_name()) ->
                                     dep_graph() | {error, term()}.
find_reachable_packages(_ExistingGraph, Error={error, _}, _PkgName) ->
    Error;
find_reachable_packages(ExistingGraph, NewGraph0, PkgName) ->
    case contains_package_version(NewGraph0, PkgName) of
        true ->
            NewGraph0;
        false ->
            case gb_trees:lookup(PkgName, ExistingGraph) of
                {value, Info} ->
                    NewGraph1 = gb_trees:insert(PkgName, Info, NewGraph0),
                    rewrite_vsns(ExistingGraph, NewGraph1, Info);
                none ->
                    NewGraph1 = gb_trees:insert(PkgName, [{{missing}, []}], NewGraph0),
                    rewrite_vsns(ExistingGraph, NewGraph1, [{{missing}, []}])
            end
    end.

%% @doc
%%  Checks to see if a package name has been defined in the dependency graph
-spec contains_package_version(dep_graph(), pkg_name()) -> boolean().
contains_package_version(Dom0, PkgName) ->
    gb_trees:is_defined(PkgName, Dom0).
