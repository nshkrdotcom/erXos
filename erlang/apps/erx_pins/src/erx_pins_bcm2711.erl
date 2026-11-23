%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The BCM2711's pin controller as a pure planner (docs/design-pinctrl.md, "The plan"):
%% from the registers as read and the settings wanted, the register writes, or a refusal
%% that writes nothing. The GPIO block holds, for each of GPIO 0 to 57, a function select
%% field of 3 bits in GPFSEL0 to GPFSEL5 (register pin div 10), a pull field of 2 bits in
%% GPIO_PUP_PDN_CNTRL_REG0 to REG3 (register pin div 16), and a bit (register pin div 32)
%% in the level register GPLEV and in each of the six detect enables: GPREN and GPFEN for
%% a rising and a falling edge, GPHEN and GPLEN for a high and a low level, and GPAREN and
%% GPAFEN for an asynchronous rising and falling edge. GPSET and GPCLR load an output's
%% latch, a written one acting on its pin (BCM2711 ARM Peripherals, section 5.2). Field
%% codes come from the header generated from hw/svd/bcm2711_gpio, whose FSEL0 and PULL0
%% encodings every pin's field shares.
%%
%% A plan's steps come in the order that drives nothing unasked: pulls, then level
%% commands, so an output's latch is loaded while the pin is still an input, then
%% functions, then edge enables. A step names the pins it is for. A field write changes
%% only the fields of the wanted pins that differ; a level command is planned unless the
%% pin reads as an output at that level already, since GPLEV shows the wire and not the
%% latch. No step reads a command register. No reading makes an entry raise, and each
%% refuses a pin past 57 or a setting it cannot plan as {error, {Pin, Reason}}; a list
%% of pins or settings is a proper list.
-module(erx_pins_bcm2711).

-export([plan/2, registers/1, setting/2, events/2]).

-export_type([register/0, reading/0, setting/0, step/0]).

-include("generated/erx_hw_bcm2711_gpio.hrl").

-define(PIN_COUNT, 58).
-define(WORD_MAX, 16#ffffffff).
-define(FUNCTION_WIDTH, 3).
-define(PULL_WIDTH, 2).

-type pin() :: 0..57.
-type register() :: gpfsel0 | gpfsel1 | gpfsel2 | gpfsel3 | gpfsel4 | gpfsel5
                  | pup_pdn0 | pup_pdn1 | pup_pdn2 | pup_pdn3
                  | gpren0 | gpren1 | gpfen0 | gpfen1 | gphen0 | gphen1 | gplen0 | gplen1
                  | gparen0 | gparen1 | gpafen0 | gpafen1 | gplev0 | gplev1
                  | gpset0 | gpset1 | gpclr0 | gpclr1 | gpeds0 | gpeds1.
%% A word for each register read; anything else in it is refused, never raised on.
-type reading() :: #{register() => term()}.
%% A function is in, out or an alternate number, 0 to 5.
-type setting() :: #{function := in | out | 0..5, level => 0 | 1,
                     pull => none | up | down, edge => none | rising | falling | both}.
-type step() :: {field, [pin()], register(), non_neg_integer(), non_neg_integer()}
              | {command, [pin()], register(), non_neg_integer()}.
-type refusal() :: no_such_pin | twice | bad_setting | bad_function | out_without_level
                 | level_without_out | bad_pull | bad_edge | {unknown_key, term()}
                 | {unread, register()}.

%% One wanted field: the register that holds it, its shift and width, and its code.
-record(field, {pin, register, shift, width, code}).

-spec plan(reading(), [{pin(), setting()}]) -> {ok, [step()]} | {error, {term(), refusal()}}.
plan(Read, Wanted) ->
    refusing(fun() ->
                     Settings = settings(Wanted),
                     {ok, lists:append([field_steps(Read, pull_fields(Settings)),
                                        level_steps(Read, Settings),
                                        field_steps(Read, function_fields(Settings)),
                                        field_steps(Read, edge_fields(Settings))])}
             end).

%% The registers a plan for these pins reads, each once, in order.
-spec registers([pin()]) -> {ok, [register()]} | {error, {term(), refusal()}}.
registers(Pins) ->
    refusing(fun() -> {ok, lists:usort(lists:append([pin_registers(Pin) || Pin <- pins(Pins)]))} end).

%% edge_codes/1 lists each of the six detect enables once, whatever the edge.
pin_registers(Pin) ->
    [function_register(Pin), pull_register(Pin), bank(gplev, Pin) |
     [bank(Family, Pin) || {Family, _} <- edge_codes(none)]].

%% A pin's function, pull and level as a reading holds them, each unknown where the
%% reading lacks its register. A function or pull code with no name stays a number.
-spec setting(reading(), pin()) ->
          {ok, #{function := term(), pull := term(), level := term()}} | {error, {term(), refusal()}}.
setting(Read, Pin) ->
    refusing(fun() -> {ok, read_setting(Read, pin(Pin))} end).

read_setting(Read, Pin) ->
    #{function => read_code(Read, function_register(Pin), function_shift(Pin), ?FUNCTION_WIDTH,
                            fun function_name/1),
      pull => read_code(Read, pull_register(Pin), pull_shift(Pin), ?PULL_WIDTH, fun pull_name/1),
      level => read_code(Read, bank(gplev, Pin), Pin rem 32, 1, fun(Level) -> Level end)}.

%% The driver's own pins that fired, by GPEDS0 and GPEDS1, and the command that clears
%% exactly those bits; an event of a pin not among them is neither reported nor cleared.
-spec events(reading(), [pin()]) -> {ok, [pin()], [step()]} | {error, {term(), refusal()}}.
events(Read, Own) ->
    refusing(fun() ->
                     Fired = [Pin || Pin <- lists:usort(pins(Own)),
                                     word(Read, bank(gpeds, Pin), Pin) band bit(Pin) =/= 0],
                     {ok, Fired, commands(gpeds, Fired)}
             end).

%% The module's one failure route: a check throws {refused, Pin, Reason} at the first
%% fault, and every entry returns it as {error, {Pin, Reason}} in place of an answer.
refusing(Decide) ->
    try
        Decide()
    catch
        throw:{refused, Pin, Reason} -> {error, {Pin, Reason}}
    end.

%% Every wanted pin's setting, checked whole before anything is read.
settings(Wanted) when is_list(Wanted) ->
    Pins = [Pin || {Pin, _} <- Wanted],
    case Pins -- lists:usort(Pins) of
        [] -> ok;
        [Twice | _] -> throw({refused, Twice, twice})
    end,
    [checked(Entry) || Entry <- Wanted];
settings(_) ->
    throw({refused, none, bad_setting}).

checked({Pin, Setting}) ->
    pin(Pin),
    is_map(Setting) orelse throw({refused, Pin, bad_setting}),
    case maps:keys(Setting) -- [function, level, pull, edge] of
        [] -> ok;
        [Unknown | _] -> throw({refused, Pin, {unknown_key, Unknown}})
    end,
    Function = maps:get(function, Setting, none),
    Level = maps:get(level, Setting, none),
    case {Function, Level} of
        {out, none} -> throw({refused, Pin, out_without_level});
        {out, _} when Level =/= 0, Level =/= 1 -> throw({refused, Pin, bad_setting});
        {out, _} -> ok;
        {_, none} -> ok;
        {_, _} -> throw({refused, Pin, level_without_out})
    end,
    function_code(Function) =/= none orelse throw({refused, Pin, bad_function}),
    lists:member(maps:get(pull, Setting, absent), [absent, none, up, down])
        orelse throw({refused, Pin, bad_pull}),
    lists:member(maps:get(edge, Setting, absent), [absent, none, rising, falling, both])
        orelse throw({refused, Pin, bad_edge}),
    {Pin, Setting};
checked(Other) ->
    throw({refused, Other, bad_setting}).

pins(Pins) when is_list(Pins) -> [pin(Pin) || Pin <- Pins];
pins(Other) -> throw({refused, Other, no_such_pin}).

pin(Pin) ->
    valid_pin(Pin) orelse throw({refused, Pin, no_such_pin}),
    Pin.

valid_pin(Pin) -> is_integer(Pin) andalso Pin >= 0 andalso Pin < ?PIN_COUNT.

function_fields(Settings) ->
    [#field{pin = Pin, register = function_register(Pin), shift = function_shift(Pin),
            width = ?FUNCTION_WIDTH, code = function_code(maps:get(function, Setting))}
     || {Pin, Setting} <- Settings].

%% A pin whose setting names no pull keeps the pull it has.
pull_fields(Settings) ->
    [#field{pin = Pin, register = pull_register(Pin), shift = pull_shift(Pin),
            width = ?PULL_WIDTH, code = pull_code(Pull)}
     || {Pin, #{pull := Pull}} <- Settings].

%% A pin whose setting names no edge keeps the detect enables it has.
edge_fields(Settings) ->
    lists:append([edge_bits(Pin, Edge) || {Pin, #{edge := Edge}} <- Settings]).

edge_bits(Pin, Edge) ->
    [#field{pin = Pin, register = bank(Family, Pin), shift = Pin rem 32, width = 1, code = Code}
     || {Family, Code} <- edge_codes(Edge)].

%% A pin's bit in each of the six detect enables for an edge setting: the setting gives all
%% six, so a pin detects the edges it names and no other edge or level.
edge_codes(Edge) ->
    {Rising, Falling} = case Edge of
                            none -> {0, 0};
                            rising -> {1, 0};
                            falling -> {0, 1};
                            both -> {1, 1}
                        end,
    [{gpren, Rising}, {gpfen, Falling}, {gphen, 0}, {gplen, 0}, {gparen, 0}, {gpafen, 0}].

%% One field write for each register in which a wanted field differs from the reading.
field_steps(Read, Fields) ->
    Registers = lists:usort([Field#field.register || Field <- Fields]),
    lists:filtermap(fun(Register) -> field_step(Read, Register, Fields) end, Registers).

field_step(Read, Register, Fields) ->
    Differing = [Field || #field{register = R} = Field <- Fields, R =:= Register,
                          not field_agrees(Read, Field)],
    case Differing of
        [] -> false;
        _ -> {true, {field, [Field#field.pin || Field <- Differing], Register,
                     lists:sum([field_mask(Field) || Field <- Differing]),
                     lists:sum([Field#field.code bsl Field#field.shift || Field <- Differing])}}
    end.

field_agrees(Read, #field{pin = Pin, register = Register, code = Code} = Field) ->
    Word = word(Read, Register, Pin),
    (Word band field_mask(Field)) bsr Field#field.shift =:= Code.

field_mask(#field{shift = Shift, width = Width}) -> ((1 bsl Width) - 1) bsl Shift.

%% GPSET for the outputs wanted at 1 and GPCLR for those at 0, each leaving out a pin that
%% already reads as an output at its level.
level_steps(Read, Settings) ->
    Outputs = [{Pin, Level} || {Pin, #{function := out, level := Level}} <- Settings],
    Pending = [{Pin, Level} || {Pin, Level} <- Outputs, not drives(Read, Pin, Level)],
    commands(gpset, [Pin || {Pin, 1} <- Pending]) ++ commands(gpclr, [Pin || {Pin, 0} <- Pending]).

drives(Read, Pin, Level) ->
    Output = function_code(out) bsl function_shift(Pin),
    Function = word(Read, function_register(Pin), Pin) band (((1 bsl ?FUNCTION_WIDTH) - 1) bsl function_shift(Pin)),
    Function =:= Output andalso (word(Read, bank(gplev, Pin), Pin) bsr (Pin rem 32)) band 1 =:= Level.

%% One command for each bank that has pins, carrying their bits and no other.
commands(Family, Pins) ->
    [{command, BankPins, bank(Family, hd(BankPins)), lists:sum([bit(Pin) || Pin <- BankPins])}
     || BankPins <- [[Pin || Pin <- Pins, Pin < 32], [Pin || Pin <- Pins, Pin >= 32]], BankPins =/= []].

bit(Pin) -> 1 bsl (Pin rem 32).

word(Read, Register, Pin) ->
    case Read of
        #{Register := Word} when is_integer(Word), Word >= 0, Word =< ?WORD_MAX -> Word;
        _ -> throw({refused, Pin, {unread, Register}})
    end.

read_code(Read, Register, Shift, Width, Name) ->
    case Read of
        #{Register := Word} when is_integer(Word), Word >= 0, Word =< ?WORD_MAX ->
            Name((Word bsr Shift) band ((1 bsl Width) - 1));
        _ -> unknown
    end.

function_register(Pin) -> element(Pin div 10 + 1, {gpfsel0, gpfsel1, gpfsel2, gpfsel3, gpfsel4, gpfsel5}).
function_shift(Pin) -> ?FUNCTION_WIDTH * (Pin rem 10).
pull_register(Pin) -> element(Pin div 16 + 1, {pup_pdn0, pup_pdn1, pup_pdn2, pup_pdn3}).
pull_shift(Pin) -> ?PULL_WIDTH * (Pin rem 16).

bank(gpren, Pin) -> element(Pin div 32 + 1, {gpren0, gpren1});
bank(gpfen, Pin) -> element(Pin div 32 + 1, {gpfen0, gpfen1});
bank(gphen, Pin) -> element(Pin div 32 + 1, {gphen0, gphen1});
bank(gplen, Pin) -> element(Pin div 32 + 1, {gplen0, gplen1});
bank(gparen, Pin) -> element(Pin div 32 + 1, {gparen0, gparen1});
bank(gpafen, Pin) -> element(Pin div 32 + 1, {gpafen0, gpafen1});
bank(gplev, Pin) -> element(Pin div 32 + 1, {gplev0, gplev1});
bank(gpset, Pin) -> element(Pin div 32 + 1, {gpset0, gpset1});
bank(gpclr, Pin) -> element(Pin div 32 + 1, {gpclr0, gpclr1});
bank(gpeds, Pin) -> element(Pin div 32 + 1, {gpeds0, gpeds1}).

%% The FSEL codes, DS Table 64 as the SVD gives them for FSEL0.
function_code(in) -> ?ERX_HW_BCM2711_GPIO_GPFSEL0_FSEL0_INPUT;
function_code(out) -> ?ERX_HW_BCM2711_GPIO_GPFSEL0_FSEL0_OUTPUT;
function_code(Alternate) when is_integer(Alternate), Alternate >= 0, Alternate =< 5 ->
    element(Alternate + 1, alternate_codes());
function_code(_) -> none.

alternate_codes() ->
    {?ERX_HW_BCM2711_GPIO_GPFSEL0_FSEL0_ALT0, ?ERX_HW_BCM2711_GPIO_GPFSEL0_FSEL0_ALT1,
     ?ERX_HW_BCM2711_GPIO_GPFSEL0_FSEL0_ALT2, ?ERX_HW_BCM2711_GPIO_GPFSEL0_FSEL0_ALT3,
     ?ERX_HW_BCM2711_GPIO_GPFSEL0_FSEL0_ALT4, ?ERX_HW_BCM2711_GPIO_GPFSEL0_FSEL0_ALT5}.

function_name(Code) ->
    Named = [{function_code(Function), Function} || Function <- [in, out, 0, 1, 2, 3, 4, 5]],
    proplists:get_value(Code, Named, Code).

pull_code(none) -> ?ERX_HW_BCM2711_GPIO_PUP_PDN0_PULL0_NONE;
pull_code(up) -> ?ERX_HW_BCM2711_GPIO_PUP_PDN0_PULL0_UP;
pull_code(down) -> ?ERX_HW_BCM2711_GPIO_PUP_PDN0_PULL0_DOWN.

pull_name(Code) ->
    proplists:get_value(Code, [{pull_code(Pull), Pull} || Pull <- [none, up, down]], Code).
