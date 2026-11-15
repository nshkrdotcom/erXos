%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_bytes).
-moduledoc """
The host stand-in for erx_bytes' SHA-256, whose NIF the host tests do not
load: stock OTP's crypto gives the same digest (FIPS 180-4).
""".
-export([sha256/1]).

sha256(Data) when is_binary(Data) -> crypto:hash(sha256, Data).
