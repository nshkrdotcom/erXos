# Copyright (c) 2026, Stanislav Sedov <stas@deglitch.com>
# SPDX-License-Identifier: BSD-2-Clause
#
# The device NIF's C below ERTS's glue (erx_device_bif.c, erx_device_nif.c): the records,
# the queues' pure cores and the DMA sequencer, one name per source in this directory,
# without its .c. This list is their one copy: ERTS's build includes it
# (erts/emulator/Makefile.in), and the native IRQ harness and the host tests read it
# through tools/lib/erx/device_nif.rb. Each adds the architecture's cache maintenance
# (arch/<arch>/erx_dma_arch.c) itself, since the architecture is the user's choice. It stays
# one plain assignment of names, with no other make syntax, which the Ruby reader refuses.
ERX_DEVICE_CORES = erx_device erx_device_core erx_device_dma erx_device_genet \
	erx_device_ledger erx_device_rules erx_device_sequencer erx_device_virtio_core
