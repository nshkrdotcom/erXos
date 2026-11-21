%% Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
%% SPDX-License-Identifier: BSD-2-Clause

-module(erx_usb_setup).
-moduledoc """
A control request's setup packet (USB 2.0, section 9.3; FreeBSD's
`struct usb_device_request`, `usb.h`, lines 157-165): the eight bytes
bmRequestType, bRequest, wValue, wIndex and wLength, the 16-bit fields
little-endian. The bus core, the controller's core and the functions build
every request through packet/5, so the layout has one home.
""".

-export([packet/5]).

-doc "The setup packet of one request; Length is the data stage's, 0 for none.".
-spec packet(byte(), byte(), 0..16#ffff, 0..16#ffff, 0..16#ffff) -> <<_:64>>.
packet(RequestType, Request, Value, Index, Length) ->
    <<RequestType, Request, Value:16/little, Index:16/little, Length:16/little>>.
