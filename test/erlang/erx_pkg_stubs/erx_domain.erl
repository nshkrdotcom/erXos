%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_domain).
-moduledoc """
A stub of the domain service's `system_namespace/0` for erx_pkg's tests: the
request goes to the process registered as erx_pkg_namespace, which a case
starts to hold the wait. With none registered the request fails at once, as
it does when the domain service has ended, and the recovery lists all the
same.
""".
-export([system_namespace/0]).

system_namespace() ->
    gen_server:send_request(erx_pkg_namespace, system_namespace).
