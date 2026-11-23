%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% A model of the BCM2711's GPIO registers for the pin driver's host tests
%% (docs/design-pinctrl.md, "Verification"): it applies a plan's steps as the register
%% module would, a field write as the reading with the masked bits replaced, GPSET and
%% GPCLR into each bank's output latch and a GPEDS command as write-one-to-clear, and
%% shows at GPLEV an output's latch and an input's wire. Each latch starts at what GPLEV
%% reads. A model may drop one pin's field write and hold one pin's wire at a level, and
%% apply_sampled/3 records after each step every wanted output that drives another level
%% than the one wanted.
-module(erx_pins_model).

-export([new/1, new/2, apply/2, apply_sampled/3, reading/1]).

-record(model, {registers, latch = #{0 => 0, 1 => 0}, wire = #{}, drop = none}).

%% A model over a reading; Options may give drop => {Register, Pin, Shift, Width} and
%% wire => #{Pin => Level}.
new(Reading) -> new(Reading, #{}).

new(Reading, Options) ->
    #model{registers = Reading, latch = #{0 => word(Reading, gplev0), 1 => word(Reading, gplev1)},
           wire = maps:get(wire, Options, #{}),
           drop = maps:get(drop, Options, none)}.

apply(Model, Steps) -> lists:foldl(fun step/2, Model, Steps).

%% The steps applied one by one, with the outputs among Wanted that drove another level
%% than wanted after any step.
apply_sampled(Model, Steps, Wanted) ->
    lists:foldl(fun(Step, {M0, Glitches}) ->
                        M = step(Step, M0),
                        {M, Glitches ++ glitches(M, Wanted)}
                end, {Model, []}, Steps).

reading(#model{registers = Registers} = Model) ->
    Registers#{gplev0 => level_word(Model, 0), gplev1 => level_word(Model, 1)}.

step({field, _Pins, Register, Mask, Bits}, #model{registers = Registers, drop = Drop} = M) ->
    Old = maps:get(Register, Registers),
    Kept = case Drop of
               {Register, _Pin, Shift, Width} -> ((1 bsl Width) - 1) bsl Shift;
               _ -> 0
           end,
    Written = Mask band bnot Kept,
    M#model{registers = Registers#{Register => (Old band bnot Written) bor (Bits band Written)}};
step({command, _Pins, Register, Bits}, #model{latch = Latch, registers = Registers} = M) ->
    case Register of
        gpset0 -> M#model{latch = Latch#{0 => maps:get(0, Latch) bor Bits}};
        gpset1 -> M#model{latch = Latch#{1 => maps:get(1, Latch) bor Bits}};
        gpclr0 -> M#model{latch = Latch#{0 => maps:get(0, Latch) band bnot Bits}};
        gpclr1 -> M#model{latch = Latch#{1 => maps:get(1, Latch) band bnot Bits}};
        Events when Events =:= gpeds0; Events =:= gpeds1 ->
            M#model{registers = Registers#{Events => maps:get(Events, Registers) band bnot Bits}}
    end.

level_word(#model{registers = Registers, latch = Latch, wire = Wire} = M, Bank) ->
    Read = word(Registers, element(Bank + 1, {gplev0, gplev1})),
    lists:foldl(fun(Bit, Word) ->
                        Pin = Bank * 32 + Bit,
                        Level = case {maps:find(Pin, Wire), output(M, Pin)} of
                                    {{ok, Held}, _} -> Held;
                                    {error, true} -> (maps:get(Bank, Latch) bsr Bit) band 1;
                                    {error, false} -> (Read bsr Bit) band 1
                                end,
                        (Word band bnot (1 bsl Bit)) bor (Level bsl Bit)
                end, 0, lists:seq(0, 31)).

output(#model{registers = Registers}, Pin) when Pin < 58 ->
    Register = element(Pin div 10 + 1, {gpfsel0, gpfsel1, gpfsel2, gpfsel3, gpfsel4, gpfsel5}),
    (word(Registers, Register) bsr (3 * (Pin rem 10))) band 7 =:= 1;
output(_, _) -> false.

glitches(#model{latch = Latch} = M, Wanted) ->
    [Pin || {Pin, #{function := out, level := Level}} <- Wanted, output(M, Pin),
            (maps:get(Pin div 32, Latch) bsr (Pin rem 32)) band 1 =/= Level].

%% A register as the model reads it: what a random reading holds that is no word reads 0.
word(Registers, Register) ->
    case maps:get(Register, Registers, 0) of
        Word when is_integer(Word), Word >= 0 -> Word;
        _ -> 0
    end.
