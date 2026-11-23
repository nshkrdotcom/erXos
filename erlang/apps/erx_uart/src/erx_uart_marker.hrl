%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

%% The byte a console UART's driver puts in its input where received bytes were lost, as
%% FreeBSD's uart(4) puts UART_STAT_OVERRUN's character: NUL. The line editor finishes no
%% line that holds it (docs/design-live.md, "The console").
-define(MARKER, 0).
