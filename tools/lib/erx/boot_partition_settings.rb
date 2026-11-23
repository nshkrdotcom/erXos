# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
# frozen_string_literal: true

require_relative 'build_kind'

module Erx
  # The boot description's settings table (docs/design-pinctrl.md, "The pin table"): each
  # config.txt setting the boot partition can write that makes the firmware set pins, by the
  # SoC's pin-table kind, with the signal the firmware puts on each pin and the kinds of card
  # it is written on. The pin table's reader checks every firmware row (the console's, jtag)
  # against it, and BootPartition#config_txt writes a setting when its pins are rows and the
  # card is of a kind it lists, so a pin erXos leaves alone is a pin the firmware is told to
  # set.
  module BootPartition
    Setting = Data.define(:name, :signals, :kinds) do
      def pins = signals.keys
    end

    FIRMWARE_SETTINGS = {
      'bcm2711' => [
        # The mini UART's TXD1 and RXD1, seen set on the board whatever gpio= lines ask
        # (docs/design-platforms.md, "Raspberry Pi 4 Model B").
        Setting.new(name: 'enable_uart', signals: { 14 => 'TXD1', 15 => 'RXD1' }.freeze,
                    kinds: BuildKind::ALL),
        # The ARM's six JTAG signals in ALT4, from the Raspberry Pi documentation
        # (docs/design-header-io.md, "The hardware"); a probe's, on a development card only.
        Setting.new(name: 'enable_jtag_gpio',
                    signals: { 22 => 'ARM_TRST', 23 => 'ARM_RTCK', 24 => 'ARM_TDO', 25 => 'ARM_TCK',
                               26 => 'ARM_TDI', 27 => 'ARM_TMS' }.freeze,
                    kinds: [BuildKind::DEVELOPMENT].freeze)
      ].freeze
    }.freeze
  end
end
