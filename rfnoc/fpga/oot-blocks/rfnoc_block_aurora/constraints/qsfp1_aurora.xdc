#
# Copyright 2025 Ettus Research, a National Instruments Brand
#
# SPDX-License-Identifier: LGPL-3.0-or-later
#
# Description:
#
#   QSFP28 Port 1 pin constraints for X400 series
#

# Bank 128 (Quad X0Y1, Lanes X0Y4-X0Y7)
set_property LOC GTYE4_CHANNEL_X0Y4 [get_cells -hierarchical -filter {NAME =~ *aurora_100g*gen_channel_container[4].*gen_gtye4_channel_inst[0].GTYE4_CHANNEL_PRIM_INST}]
set_property LOC GTYE4_CHANNEL_X0Y5 [get_cells -hierarchical -filter {NAME =~ *aurora_100g*gen_channel_container[4].*gen_gtye4_channel_inst[1].GTYE4_CHANNEL_PRIM_INST}]
set_property LOC GTYE4_CHANNEL_X0Y6 [get_cells -hierarchical -filter {NAME =~ *aurora_100g*gen_channel_container[4].*gen_gtye4_channel_inst[2].GTYE4_CHANNEL_PRIM_INST}]
set_property LOC GTYE4_CHANNEL_X0Y7 [get_cells -hierarchical -filter {NAME =~ *aurora_100g*gen_channel_container[4].*gen_gtye4_channel_inst[3].GTYE4_CHANNEL_PRIM_INST}]
