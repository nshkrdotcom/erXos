%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_usb_fake_xhci).
-moduledoc """
A controller process for the bus process's host tests: it speaks
erx_usb_bus_link and erx_usb_pipe as docs/design-usb.md states the
controller does, over a world the test changes.

The world maps places to things: a place is a route from the root, the
root port first, and a thing a `keyboard`, a `composite` of two HID
interfaces, a mass-storage `stick` or `{hub, Ports}`, each
high-speed, with the descriptors erx_usb_desc_tests builds. A root port's
reset ends with a port event showing its reset change; a hub port's when
its next GET_STATUS shows the change, as the design says of each. A hub
answers its class requests on EP0 and reports its ports' changes on its
status pipe whenever a transfer is posted there. Every request the
controller takes is logged, oldest first, for the test to read.

The test plugs and unplugs things, fails a hub's next status transfer, or
makes a request kind fail, with the calls below.
""".

-include("generated/erx_abi.hrl").

-export([start_link/1, plug/3, unplug/2, replace/3, fail_status_transfer/2, log/1, bus/1]).

%% The controller start erx_usb_bus_sup takes. The fake registers as Name, so the
%% test reaches each restart by it, and tells each start to the process registered as
%% erx_usb_bus_tests. A World of `fails_at_start` is a controller that fails as soon
%% as its bus attaches, as one whose host controller error returns after every reset.
-doc "Starts the fake, registered as Name, with RootPorts root ports and the world World.".
start_link({Name, RootPorts, World}) ->
    Pid = proc_lib:spawn_link(fun() -> init(Name, RootPorts, World) end),
    {ok, Pid}.

plug(Name, Place, Thing) -> call(Name, {plug, Place, Thing}).
unplug(Name, Place) -> call(Name, {unplug, Place}).
replace(Name, Place, Thing) -> call(Name, {replace, Place, Thing}).
fail_status_transfer(Name, Hub) -> call(Name, {fail_status_transfer, Hub}).
log(Name) -> call(Name, log).
bus(Name) -> call(Name, bus).

call(Name, Request) ->
    Ref = make_ref(),
    Name ! {test, self(), Ref, Request},
    receive {Ref, Reply} -> Reply after 5000 -> error({fake_timeout, Request}) end.

%% The state: the bus, the world, each place's port (powered, enabled, its change
%% bits pending), each device reference's place, the status transfer posted on each
%% hub, the hubs whose next transfer fails, and the log.
init(Name, RootPorts, World) ->
    true = register(Name, self()),
    case whereis(erx_usb_bus_tests) of
        undefined -> ok;
        Tests -> Tests ! {fake_started, self()}
    end,
    loop(#{bus => none, root_ports => RootPorts, world => World, ports => #{}, refs => #{}, posted => #{},
           failing => [], log => []}).

loop(S) ->
    receive
        {test, From, Ref, Request} ->
            {Reply, S1} = test(Request, S),
            From ! {Ref, Reply},
            loop(S1);
        {erx_usb_bus_link, Bus, Request} ->
            loop(request(Request, logged(Request, S#{bus := Bus})));
        {erx_usb_pipe, From, Request} ->
            loop(transfer(From, Request, logged(Request, S)))
    end.

logged(Request, S = #{log := Log}) -> S#{log := [Request | Log]}.

%% The test's calls.
test({plug, Place, Thing}, S = #{world := World}) ->
    {ok, changed(Place, S#{world := World#{Place => Thing}})};
test({unplug, Place}, S = #{world := World, ports := Ports}) ->
    Port = maps:get(Place, Ports, #{}),
    {ok, changed(Place, S#{world := maps:remove(Place, World), ports := Ports#{Place => Port#{enabled => false}}})};
test({replace, Place, Thing}, S = #{world := World, ports := Ports}) ->
    Port = maps:get(Place, Ports, #{}),
    {ok, changed(Place, S#{world := World#{Place => Thing}, ports := Ports#{Place => Port#{enabled => false}}})};
test({fail_status_transfer, Hub}, S = #{failing := Failing}) ->
    {ok, deliver(Hub, S#{failing := [Hub | Failing]})};
test(log, S = #{log := Log}) ->
    {lists:reverse(Log), S};
test(bus, S = #{bus := Bus}) ->
    {Bus, S}.

%% A place's connection changed: a root port raises a port event, a hub port is
%% reported on its hub's status pipe.
changed(Place, S) ->
    S1 = add_change(Place, connection, S),
    case Place of
        [Root] -> event({port_event, Root}, S1), S1;
        _Below -> deliver(hub_at(lists:droplast(Place), S1), S1)
    end.

add_change(Place, Change, S = #{ports := Ports}) ->
    Port = #{changes := Changes} = port(Place, S),
    S#{ports := Ports#{Place => Port#{changes := lists:usort([Change | Changes])}}}.

port(Place, #{ports := Ports}) ->
    maps:merge(#{powered => false, enabled => false, changes => []}, maps:get(Place, Ports, #{})).

event(Event, #{bus := Bus}) ->
    erx_usb_bus_link:answer(Bus, Event).

%% The bus process's requests.
request(attach, #{world := fails_at_start}) ->
    exit(host_controller_error);
request(attach, S = #{root_ports := RootPorts}) ->
    event({root_ports, RootPorts}, S),
    S;
request({port, root, N, Op}, S) ->
    {Result, S1} = port_op([N], Op, S),
    event({port_done, root, N, root_result(Op, Result, [N], S1)}, S1),
    case Op of
        reset -> event({port_event, N}, S1);
        _ -> ok
    end,
    S1;
request({enable_slot, Ref, Step}, S) ->
    event({slot, Ref, Step, {ok, 1 + map_size(maps:get(refs, S))}}, S),
    S;
request({address, Ref, Step, #{root_port := Root, route := Tiers}}, S = #{refs := Refs}) ->
    event({addressed, Ref, Step, {ok, 1 + map_size(Refs)}}, S),
    S#{refs := Refs#{Ref => [Root | Tiers]}};
request({control, Ref, Tag, Setup, _Data}, S) ->
    {Result, S1} = control(Ref, Setup, S),
    event({control_done, Ref, Tag, Result}, S1),
    S1;
request({evaluate_context, Ref, Step, _Context}, S) ->
    event({evaluated, Ref, Step, ok}, S),
    S;
request({configure_endpoints, Ref, Step, _Endpoints}, S) ->
    event({endpoints_configured, Ref, Step, ok}, S),
    S;
request({reset_pipe, Ref, Interface, Address}, S) ->
    event({pipe_reset, Ref, Interface, Address, ok}, S),
    S;
request({detach, Ref}, S = #{refs := Refs, posted := Posted}) ->
    S#{refs := maps:remove(Ref, Refs), posted := maps:remove(Ref, Posted)}.

%% A port operation on Place: power, reset, disable, a clear or a status read.
port_op(Place, power_on, S) -> {ok, put_port(Place, powered, true, S)};
port_op(Place, reset, S) ->
    case maps:is_key(Place, maps:get(world, S)) of
        true -> {ok, add_change(Place, reset, put_port(Place, enabled, true, S))};
        false -> {ok, S}
    end;
port_op(Place, disable, S) -> {ok, put_port(Place, enabled, false, S)};
port_op(Place, {clear, Change}, S = #{ports := Ports}) ->
    Port = #{changes := Changes} = port(Place, S),
    {ok, S#{ports := Ports#{Place => Port#{changes := Changes -- [Change]}}}};
port_op(Place, get_status, S = #{world := World}) ->
    #{powered := Powered, enabled := Enabled, changes := Changes} = port(Place, S),
    Connected = maps:is_key(Place, World),
    Status = bit(Connected, ?ERX_USB_PORT_STATUS_CONNECTION) bor bit(Enabled, ?ERX_USB_PORT_STATUS_ENABLED)
        bor bit(Powered, ?ERX_USB_PORT_STATUS_POWER) bor bit(Connected, ?ERX_USB_PORT_STATUS_HIGH_SPEED),
    Change = lists:sum([change_bit(C) || C <- Changes]),
    {{ok, <<Status:16/little, Change:16/little>>}, S}.

put_port(Place, Key, Value, S = #{ports := Ports}) ->
    S#{ports := Ports#{Place => (port(Place, S))#{Key => Value}}}.

root_result(get_status, {ok, Words}, _Place, _S) -> {ok, Words, ?ERX_XHCI_SPEED_HIGH};
root_result(_Op, ok, _Place, _S) -> ok.

change_bit(connection) -> ?ERX_USB_PORT_CHANGE_CONNECTION;
change_bit(enabled) -> ?ERX_USB_PORT_CHANGE_ENABLED;
change_bit(reset) -> ?ERX_USB_PORT_CHANGE_RESET.

bit(true, Mask) -> Mask;
bit(false, _Mask) -> 0.

%% A control request on device Ref's EP0, answered by what the device at its
%% place holds; a detached reference answers gone, as the controller's map does.
control(Ref, Setup, S = #{refs := Refs, world := World}) ->
    case Refs of
        #{Ref := Place} when is_map_key(Place, World) -> device_request(Place, maps:get(Place, World), Setup, S);
        #{} -> {{error, gone}, S}
    end.

device_request(Place, Thing, Setup = <<_:6/binary, Length:16/little>>, S) ->
    case request_name(Setup) of
        {hub_port, Port, Op} -> hub_port(Place ++ [Port], Op, S);
        hub_status -> {{ok, <<0:16, 0:16>>}, S};
        {hub_clear, _Change} -> {{ok, <<>>}, S};
        set_configuration -> {{ok, <<>>}, S};
        Name -> {{ok, cut(descriptor(Name, Thing), Length)}, S}
    end.

hub_port(Place, Op, S) ->
    case port_op(Place, Op, S) of
        {ok, S1} -> {{ok, <<>>}, S1};
        {{ok, Words}, S1} -> {{ok, Words}, S1}
    end.

cut(Bytes, Length) -> binary:part(Bytes, 0, min(Length, byte_size(Bytes))).

%% The requests the things understand, by their setup packets written out; any
%% other ends the fake, failing the test.
request_name(<<16#80, 6, 0, 1, 0:16, _:16>>) -> device;
request_name(<<16#80, 6, 0, 2, 0:16, _:16>>) -> configuration;
request_name(<<0, 9, 1, 0, 0:16, 0:16>>) -> set_configuration;
request_name(<<16#a0, 6, 0, 16#29, 0:16, _:16>>) -> hub_descriptor;
request_name(<<16#a0, 0, 0:16, 0:16, 4:16/little>>) -> hub_status;
request_name(<<16#20, 1, Feature:16/little, 0:16, 0:16>>) -> {hub_clear, Feature};
request_name(<<16#a3, 0, 0:16, Port:16/little, 4:16/little>>) -> {hub_port, Port, get_status};
request_name(<<16#23, 3, ?ERX_USB_PORT_FEATURE_POWER:16/little, Port:16/little, 0:16>>) -> {hub_port, Port, power_on};
request_name(<<16#23, 3, ?ERX_USB_PORT_FEATURE_RESET:16/little, Port:16/little, 0:16>>) -> {hub_port, Port, reset};
request_name(<<16#23, 1, ?ERX_USB_PORT_FEATURE_ENABLE:16/little, Port:16/little, 0:16>>) -> {hub_port, Port, disable};
request_name(<<16#23, 1, Feature:16/little, Port:16/little, 0:16>>) -> {hub_port, Port, {clear, cleared(Feature)}}.

cleared(?ERX_USB_PORT_FEATURE_C_CONNECTION) -> connection;
cleared(?ERX_USB_PORT_FEATURE_C_ENABLE) -> enabled;
cleared(?ERX_USB_PORT_FEATURE_C_SUSPEND) -> suspend;
cleared(?ERX_USB_PORT_FEATURE_C_OVER_CURRENT) -> over_current;
cleared(?ERX_USB_PORT_FEATURE_C_RESET) -> reset.

descriptor(device, Thing) when Thing =:= keyboard; Thing =:= composite; Thing =:= stick ->
    erx_usb_desc_tests:device(0, 0, 0);
descriptor(device, {hub, _Ports}) -> erx_usb_desc_tests:device(9, 0, 1);
descriptor(configuration, keyboard) ->
    erx_usb_desc_tests:configuration([erx_usb_desc_tests:interface(0, 0, 3, 1, 1),
                                      erx_usb_desc_tests:endpoint(16#81, 3, 8, 10)]);
descriptor(configuration, composite) ->
    erx_usb_desc_tests:configuration([erx_usb_desc_tests:interface(0, 0, 3, 1, 1),
                                      erx_usb_desc_tests:endpoint(16#81, 3, 8, 10),
                                      erx_usb_desc_tests:interface(1, 0, 3, 0, 0),
                                      erx_usb_desc_tests:endpoint(16#82, 3, 8, 10)]);
descriptor(configuration, stick) ->
    erx_usb_desc_tests:storage();
descriptor(configuration, {hub, _Ports}) ->
    erx_usb_desc_tests:configuration([erx_usb_desc_tests:interface(0, 0, 9, 0, 0),
                                      erx_usb_desc_tests:endpoint(16#81, 3, 1, 12)]);
descriptor(hub_descriptor, {hub, Ports}) ->
    erx_usb_desc_tests:hub(Ports, 0, 50).

%% A function's transfers: a hub's status transfer is held until one of its ports
%% has a change pending, or fails when the test asked.
transfer(From, {control, Pipe, Setup, _Data, Tag}, S) ->
    {Ref, _Address} = erx_usb_pipe:endpoint(Pipe),
    {Result, S1} = control(Ref, Setup, S),
    From ! {Tag, Result},
    S1;
transfer(From, {interrupt_in, Pipe, Tag, _Length}, S = #{posted := Posted}) ->
    {Ref, _Address} = erx_usb_pipe:endpoint(Pipe),
    deliver(Ref, S#{posted := Posted#{Ref => {From, Pipe, Tag}}}).

deliver(Hub, S = #{posted := Posted, failing := Failing, refs := Refs, world := World}) ->
    case Posted of
        #{Hub := {From, Pipe, Tag}} ->
            Place = maps:get(Hub, Refs),
            {hub, Ports} = maps:get(Place, World),
            Changed = [N || N <- lists:seq(1, Ports), maps:get(changes, port(Place ++ [N], S)) =/= []],
            Answer = case {lists:member(Hub, Failing), Changed} of
                         {true, _} -> {error, stall};
                         {false, []} -> none;
                         {false, _} -> {ok, <<(lists:sum([1 bsl N || N <- Changed])):8>>}
                     end,
            answered(Hub, From, Pipe, Tag, Answer, S#{failing := Failing -- [Hub]});
        #{} ->
            S
    end.

answered(_Hub, _From, _Pipe, _Tag, none, S) ->
    S;
answered(Hub, From, Pipe, Tag, Answer, S = #{posted := Posted}) ->
    From ! {usb, Pipe, Tag, Answer},
    S#{posted := maps:remove(Hub, Posted)}.

hub_at(Place, #{refs := Refs}) ->
    [Hub] = [Ref || Ref := P <- Refs, P =:= Place],
    Hub.
