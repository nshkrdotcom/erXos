%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The report filter at boot (docs/design-log.md, "Reports carry no term"): the tree's
%% logger, loaded over the kernel's, configures the kernel's logger as the kernel's start
%% does (edit 57 of docs/design-runtime.md), and the primary filters it leaves are printed.
-module(erx_report_boot_tests).

-export([primary_filters_at_boot/0]).

%% Prints the ids of the primary filters, in the order logger applies them, when the
%% domain's configuration names a filter of its own, `own`.
primary_filters_at_boot() ->
    code:purge(logger),
    {module, logger} = code:load_abs("logger"),
    Own = {own, {fun logger_filters:domain/2, {log, sub, [otp]}}},
    ok = application:set_env(kernel, logger, [{filters, log, [Own]}]),
    ok = logger:internal_init_logger(),
    #{filters := Filters} = logger:get_primary_config(),
    io:format("filters: ~p~n", [[Id || {Id, _Filter} <- Filters]]).
