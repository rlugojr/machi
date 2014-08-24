%% -------------------------------------------------------------------
%%
%% Copyright (c) 2014 Basho Technologies, Inc.  All Rights Reserved.
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
%% -------------------------------------------------------------------

-module(tango_test).

-compile(export_all).

-include("corfurl.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-compile(export_all).
-ifdef(PULSE).
-compile({parse_transform, pulse_instrument}).
-endif.
-endif.

-define(SEQ, corfurl_sequencer).
-define(T, tango).

-ifdef(TEST).
-ifndef(PULSE).

pack_v1_test() ->
    [begin
         Packed = ?T:pack_v1(StreamList, term_to_binary(Term), Size),
         StreamList = ?T:unpack_v1(Packed, stream_list),
         TermBin = ?T:unpack_v1(Packed, page),
         Term = binary_to_term(TermBin)
     end || StreamList <- [[], [1], [1,2,4]],
            Term <- [foo, {bar, baz, <<"yo">>}],
            Size <- lists:seq(100, 5000, 500)].

run_test(Name, PageSize, NumPages, NumFLUs, FUN) ->
    PDir = "./tmp." ++ Name,
    BaseDir = "/tmp/" ++ atom_to_list(?MODULE) ++ ".",
    MyDir = fun(X) -> BaseDir ++ integer_to_list(X) end,
    Del = fun() -> [ok = corfurl_util:delete_dir(MyDir(X)) ||
                       X <- lists:seq(1, NumFLUs)] end,

    Del(),
    FLUs = [begin
                element(2, corfurl_flu:start_link(MyDir(X),
                                                  PageSize, NumPages*PageSize))
            end || X <- lists:seq(1, NumFLUs)],

    try
        {ok, Seq} = ?SEQ:start_link(FLUs),
        try
            P0 = corfurl:new_simple_projection(PDir, 1, 1, 1*100, [FLUs]),
            P1 = P0#proj{seq={Seq, unused, unused}},
            FUN(PageSize, Seq, P1)
        after
            ?SEQ:stop(Seq)
        end
    after
        [ok = corfurl_flu:stop(FLU) || FLU <- FLUs],
        Del()
    end.

smoke_test() ->
    ok = run_test("projection", 4096, 5*1024, 1, fun smoke_test_fun/3).

smoke_test_fun(PageSize, Seq, P1) ->
    ok = ?SEQ:set_tails(Seq, [{42,4242}, {43,4343}]),
    {ok, [4242, 4343]} = ?SEQ:get_tails(Seq, [42, 43]),

    LPN_Pgs = [{X, ?T:pad_bin(PageSize, term_to_binary({smoke, X}))} ||
                  X <- lists:seq(1, 5)],
    [begin
         {{ok, LPN}, _} = corfurl_client:append_page(P1, Pg)
     end || {LPN, Pg} <- LPN_Pgs],
    [begin
         {ok, Pg} = corfurl:read_page(P1, LPN)
     end || {LPN, Pg} <- LPN_Pgs],

    ok.

write_forward_test() ->
    ok = run_test("write_forward", 4096, 5*1024, 1, fun write_forward_test_fun/3).

write_forward_test_fun(PageSize, _Seq, P1) ->
    StreamNum = 0,
    NumPages = 10,
    Pages = [term_to_binary({smoke, X}) || X <- lists:seq(1, NumPages)],
    BackPs0 = [{StreamNum, []}],
    {P2, BackPs1} = write_stream_pages(P1, Pages, PageSize, BackPs0, StreamNum),
    {_P3, _BackPs2} = write_stream_pages(P2, Pages, PageSize, BackPs1, StreamNum),

    ok.

write_stream_pages(Proj0, Pages, PageSize, InitialBackPs, StreamNum) ->
    F = fun(Page, {Proj1, BackPs}) ->
                FullPage = tango:pack_v1(BackPs, Page, PageSize),
                {{ok, LPN}, Proj2} =
                    corfurl_client:append_page(Proj1, FullPage),
                {Proj2, tango:add_back_pointer(StreamNum, BackPs, LPN)}
        end,
    {_Px, BackPs} = Res = lists:foldl(F, {Proj0, InitialBackPs}, Pages),
    io:format(user, "BackPs ~p\n", [BackPs]),
    Res.

scan_backward_test() ->
    ok = run_test("scan_backward", 4096, 5*1024, 1, fun scan_backward_test_fun/3).

scan_backward_test_fun(PageSize, _Seq, P1) ->
    StreamNum = 0,
    NumPages = 10,
    PageSeq = lists:seq(1, NumPages),
    Pages = [term_to_binary({smoke, X}) || X <- PageSeq],
    BackPs0 = [{StreamNum, []}],
    {P2, BackPs1} = write_stream_pages(P1, Pages, PageSize, BackPs0, StreamNum),
    LastLPN = hd(proplists:get_value(StreamNum, BackPs1)),
    io:format(user, "\nLastLPN ~p\n", [LastLPN]),

    LastLPN=LastLPN,
    [begin
         ShouldBe = lists:seq(1, BackwardStartLPN),
         ShouldBePages = lists:zip(ShouldBe, lists:sublist(Pages, BackwardStartLPN)),

         %% If we scan backward, we should get a list of LPNs in
         %% oldest -> newest (i.e. smallest LPN to largest LPN) order.
         ShouldBe = tango:scan_backward(P2, StreamNum, BackwardStartLPN,
                                        false),

         %% If we scan backward, we should get a list of LPNs in
         %% oldest -> newest (i.e. smallest LPN to largest LPN) order
         %% together with the actual page data.
         ShouldBePages = tango:scan_backward(P2, StreamNum, BackwardStartLPN,
                                             true)
     end || BackwardStartLPN <- lists:seq(1, NumPages)],

    ok.

-endif. % not PULSE
-endif. % TEST
