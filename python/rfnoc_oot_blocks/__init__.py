#
# Copyright 2024 Ettus Research, a National Instruments Company
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
"""
rfnoc-blocks: Example module for Python support of an RFNoC OOT Module
"""

import uhd.rfnoc

# Import all bindings from C++
from . import rfnoc_oot_blocks_python as lib

# Expose the block controllers
AuroraBlockControl = lib.aurora_block_control

# Expose types
channel_stop_policy = lib.channel_stop_policy
