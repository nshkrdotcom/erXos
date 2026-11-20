%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_usb_hid).
-moduledoc """
A HID function (docs/design-usb.md, "HID"): the process that drives one
claimed HID interface and writes what it reports into an input number of
the input tree, the display's source of the interface's keys, pointer,
buttons and wheel. Its decisions are the pure `erx_hid_core` (the plan and
the fold) and `erx_hid_desc` (the report descriptor's parser); this module
is their effects: control requests and interrupt transfers through
`erx_usb_pipe`, records into the number's stream.

**Start.** The bus process starts one per claimed HID interface, with the
claim's function, the device's control pipe, the function's pipes in the
claim's order (the interrupt-IN pipe alone) and the controller's places.
The function first takes the lowest free input number
(`erx_usb_places_sup:occupy_input/2`); when every number is taken it is not
started, and its start answers `{error, no_input_number}`. Then, after the
start has answered, it reads the report descriptor with
GET_DESCRIPTOR(report), asks `erx_hid_core:plan/2` how to drive the
interface, sends SET_PROTOCOL and SET_IDLE(0) as the plan says, ignoring
their answers as FreeBSD's `hkbd` does (`hkbd.c`, lines 1011-1025), and
posts four interrupt-IN transfers, each of `erx_hid_core:transfer_length/1`.
A descriptor the setting does not announce, or announces longer than
`hid_report_descriptor_max`, is not read, and the plan takes that reason
as it takes a failed read's.

**Reports.** Each transfer that completes is folded by
`erx_hid_core:step/3`; its records are written into the number's stream,
which returns once the stream has taken them, and only then is the
transfer posted again. So a display that stops reading stops the function,
and its device waits with its reports; and the transfers complete, and are
folded, in the order the controller sends their completions.

**End.** A transfer that fails, answering `{error, Reason}`, ends the
function with `{shutdown, {transfer, Reason}}`, as the class's disposition
says (docs/design-usb.md, "Transfers and pipes"); a plan that cannot drive
the interface ends it with `{shutdown, Reason}`, and the end of its
number's stream, by a restart of the places, with `{shutdown, stream}`. The function never resets
its pipes: the bus resets them before it starts the function again. Its
number's stream monitors it and writes `release` when it ends, by any of
those, by a crash or by the bus stopping it, so a reader never keeps a key
held by a function that is gone.

Everything the device sends is untrusted: the descriptor goes only to the
parser and each report only to the fold, which bound what they accept and
never raise on any bytes; no text of the device reaches a log or the
display. Its end reasons are atoms and the pipe's own error terms.
""".
-behaviour(gen_server).

-include("generated/erx_abi.hrl").

-export([start_link/1]).
-export([init/1, handle_continue/2, handle_call/3, handle_cast/2, handle_info/2]).

-export_type([start/0]).

%% The interrupt-IN transfers kept posted (docs/design-usb.md, "From reports to records").
-define(POSTED, 4).

-doc """
A handle of one pipe, as the bus process gets it from `erx_usb_pipe`; this
module only passes it back to `erx_usb_pipe` and matches it in completions.
""".
-type pipe() :: term().

-doc """
What the bus process starts a function with: the claimed function, the
device's control pipe, the function's pipes in the order of the function's
`pipes`, and the controller's places.
""".
-type start() :: #{function := erx_usb_claim:function_(),
                   control := pipe(),
                   pipes := [pipe()],
                   places := pid()}.

-record(hid, {interface :: byte(),
              setting :: erx_usb_desc:setting(),
              control :: pipe(),
              interrupt :: pipe(),
              %% The number's stream, which takes the records.
              stream :: pid(),
              %% A restart of the places ends the stream, and with it the number.
              stream_monitor :: reference(),
              %% Set once the plan is made: the layout, each transfer's length, the fold.
              layout = none :: none | erx_hid_desc:layout(),
              length = 0 :: non_neg_integer(),
              fold = none :: none | erx_hid_core:state()}).

-doc """
Starts a function on Start, linked to the caller: `{ok, Pid}` once it has
taken an input number, `{error, no_input_number}` when every number is
taken.
""".
-spec start_link(start()) -> {ok, pid()} | {error, no_input_number | term()}.
start_link(Start) ->
    gen_server:start_link(?MODULE, Start, []).

%% ---------------------------------------------------------------------------
%% gen_server callbacks
%% ---------------------------------------------------------------------------

-doc false.
init(#{function := #{interface := Interface, setting := Setting}, control := Control,
       pipes := [Interrupt], places := Places}) ->
    case erx_usb_places_sup:occupy_input(Places, self()) of
        {ok, _Number, Stream} ->
            {ok, #hid{interface = Interface, setting = Setting, control = Control,
                      interrupt = Interrupt, stream = Stream,
                      stream_monitor = erlang:monitor(process, Stream)},
             {continue, setup}};
        {error, no_input_number} ->
            {error, no_input_number}
    end.

-doc false.
handle_continue(setup, H = #hid{setting = Setting}) ->
    case erx_hid_core:plan(Setting, report_descriptor(H)) of
        {ok, #{layout := Layout, protocol := Protocol, idle := Idle}} ->
            set_protocol(Protocol, H),
            set_idle(Idle, H),
            Running = H#hid{layout = Layout, length = erx_hid_core:transfer_length(Layout),
                            fold = erx_hid_core:new(Layout)},
            lists:foreach(fun(Tag) -> post(Tag, Running) end, lists:seq(1, ?POSTED)),
            {noreply, Running};
        {error, Reason} ->
            {stop, {shutdown, Reason}, H}
    end.

-doc false.
handle_call(_Request, _From, H) ->
    {reply, {error, enotsup}, H}.

-doc false.
handle_cast(_Request, H) ->
    {noreply, H}.

-doc false.
handle_info({usb, Pipe, Tag, {ok, Report}}, H = #hid{interrupt = Pipe, layout = Layout, fold = Fold0}) ->
    {Fold, Records} = erx_hid_core:step(Layout, Report, Fold0),
    write(Records, H),
    post(Tag, H),
    {noreply, H#hid{fold = Fold}};
handle_info({usb, Pipe, _Tag, {error, Reason}}, H = #hid{interrupt = Pipe}) ->
    {stop, {shutdown, {transfer, Reason}}, H};
handle_info({'DOWN', Monitor, process, _, _}, H = #hid{stream_monitor = Monitor}) ->
    {stop, {shutdown, stream}, H};
handle_info(_Message, H) ->
    {noreply, H}.

%% ---------------------------------------------------------------------------
%% Requests
%% ---------------------------------------------------------------------------

%% GET_DESCRIPTOR(report) to the interface, of the length its HID descriptor
%% announced, or the reason it is not read.
report_descriptor(#hid{setting = #{hid := #{report_length := Length}}, interface = Interface,
                       control = Control})
  when Length > 0, Length =< ?ERX_HID_REPORT_DESCRIPTOR_MAX ->
    Setup = erx_usb_setup:packet(?ERX_USB_REQUEST_DIR_IN bor ?ERX_USB_REQUEST_TYPE_STANDARD
                                     bor ?ERX_USB_RECIPIENT_INTERFACE,
                                 ?ERX_USB_REQUEST_GET_DESCRIPTOR, ?ERX_HID_DESCRIPTOR_REPORT bsl 8,
                                 Interface, Length),
    case erx_usb_pipe:control(Control, Setup, {in, Length}) of
        {ok, Bytes} -> {ok, Bytes};
        {error, Reason} -> {error, {report_descriptor, Reason}}
    end;
report_descriptor(#hid{setting = #{hid := #{report_length := Length}}})
  when Length > ?ERX_HID_REPORT_DESCRIPTOR_MAX ->
    {error, too_long};
report_descriptor(#hid{}) ->
    {error, no_report_descriptor}.

set_protocol(none, _H) -> ok;
set_protocol(boot, H) -> class_request(?ERX_HID_REQUEST_SET_PROTOCOL, ?ERX_HID_PROTOCOL_BOOT, H);
set_protocol(report, H) -> class_request(?ERX_HID_REQUEST_SET_PROTOCOL, ?ERX_HID_PROTOCOL_REPORT, H).

%% SET_IDLE with duration 0 for every report id (HID 1.11, section 7.2.4).
set_idle(false, _H) -> ok;
set_idle(true, H) -> class_request(?ERX_HID_REQUEST_SET_IDLE, 0, H).

%% A class request to the interface with no data stage; its answer is ignored.
class_request(Request, Value, #hid{interface = Interface, control = Control}) ->
    Setup = erx_usb_setup:packet(?ERX_USB_REQUEST_TYPE_CLASS bor ?ERX_USB_RECIPIENT_INTERFACE,
                                 Request, Value, Interface, 0),
    _ = erx_usb_pipe:control(Control, Setup, none),
    ok.

%% ---------------------------------------------------------------------------
%% Transfers and records
%% ---------------------------------------------------------------------------

%% Every failure of a posted transfer arrives as its completion, so posting answers ok.
post(Tag, #hid{interrupt = Interrupt, length = Length}) ->
    ok = erx_usb_pipe:interrupt_in(Interrupt, Tag, Length).

%% Returns once the stream has taken the records, which waits while it has no room.
write([], _H) ->
    ok;
write(Records, #hid{stream = Stream}) ->
    ok = erx_usb_input_stream:write(Stream, Records).
