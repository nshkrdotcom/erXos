%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The line groups (docs/design-shared-devices.md, "Lines inside a domain";
%% docs/design-bluetooth.md, "The shared line 153"): one group for each interrupt line,
%% so one owner binds each line whichever services' UARTs are on it.
-module(erx_uart_sup_tests).

-include_lib("eunit/include/eunit.hrl").

uart(Path, Line) ->
    #{peripheral => pl011, path => Path, window => {physical, 16#9040000, 4096}, lines => [Line], clock => 24000000,
      index => 0}.

%% The Pi 4's line 153: the host link and the line tree share one group, whose one owner
%% starts first, then the line's services, the host link and the tree, neither of which
%% restarts the other.
one_owner_binds_a_shared_line_test() ->
    Hostlink = {hostlink, uart(<<"/soc/serial@7e201a00">>, {shared, 153})},
    Line = {line, uart(<<"/soc/serial@7e201000">>, {shared, 153})},
    ?assertEqual([{153, [Hostlink, Line]}], erx_uart_sup:groups([Line, Hostlink])),
    {ok, {#{strategy := rest_for_one}, Children}} = erx_uart_sup:init({group, [Hostlink, Line]}),
    ?assertEqual([owner, services], [Id || #{id := Id} <- Children]),
    #{start := {supervisor, start_link, [erx_uart_sup, Services]}} = lists:last(Children),
    {ok, {#{strategy := one_for_one}, Served}} = erx_uart_sup:init(Services),
    ?assertEqual([hostlink, {line_tree, <<"/soc/serial@7e201000">>}], [Id || #{id := Id} <- Served]).

%% QEMU virt: UARTs on lines of their own are groups of their own, with no owner.
uarts_on_two_lines_are_two_groups_test() ->
    Hostlink = {hostlink, uart(<<"/pl011@9040000">>, 40)},
    Line = {line, uart(<<"/pl011@9050000">>, 41)},
    ?assertEqual([{40, [Hostlink]}, {41, [Line]}], erx_uart_sup:groups([Hostlink, Line])),
    {ok, {_, Children}} = erx_uart_sup:init({group, [Hostlink]}),
    ?assertEqual([services], [Id || #{id := Id} <- Children]).

%% The line grants are those of the system domain's service named line, the name the
%% manifest check gives the line interface's service, and none of a configured domain's
%% service of that name or of another of the system domain's services.
line_grants_are_the_system_s_line_service_s_test() ->
    Grant = #{uart => 3, rate => 115200, flow => <<"rts_cts">>},
    Configured = #{grants => [{1, line, system, Grant}, {1, line, 0, Grant#{uart => 4}},
                              {1, uart, system, Grant#{uart => 5}}]},
    ?assertEqual(#{3 => Grant}, erx_uart_sup:line_grants(Configured)).
