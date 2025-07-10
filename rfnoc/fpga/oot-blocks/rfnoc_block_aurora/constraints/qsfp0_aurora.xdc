#
# Copyright 2025 Ettus Research, a National Instruments Brand
#
# SPDX-License-Identifier: LGPL-3.0-or-later
#
# Description:
#
#   QSFP28 Port 0 pin constraints for X400 series
#

# Bank 131 (Quad X0Y4, Lanes X0Y16-X0Y19)
set_property LOC GTYE4_CHANNEL_X0Y16 [get_cells -hierarchical -filter {NAME =~ *aurora_100g*gen_channel_container[4].*gen_gtye4_channel_inst[0].GTYE4_CHANNEL_PRIM_INST}]
set_property LOC GTYE4_CHANNEL_X0Y17 [get_cells -hierarchical -filter {NAME =~ *aurora_100g*gen_channel_container[4].*gen_gtye4_channel_inst[1].GTYE4_CHANNEL_PRIM_INST}]
set_property LOC GTYE4_CHANNEL_X0Y18 [get_cells -hierarchical -filter {NAME =~ *aurora_100g*gen_channel_container[4].*gen_gtye4_channel_inst[2].GTYE4_CHANNEL_PRIM_INST}]
set_property LOC GTYE4_CHANNEL_X0Y19 [get_cells -hierarchical -filter {NAME =~ *aurora_100g*gen_channel_container[4].*gen_gtye4_channel_inst[3].GTYE4_CHANNEL_PRIM_INST}]
