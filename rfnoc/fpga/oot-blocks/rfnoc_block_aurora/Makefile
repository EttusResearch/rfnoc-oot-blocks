#
# Copyright 2025 Ettus Research, a National Instruments Brand
#
# SPDX-License-Identifier: LGPL-3.0-or-later
#

#-------------------------------------------------
# Top-of-Makefile
#-------------------------------------------------
# UHD_FPGA_DIR must be passed into this Makefile.
ifndef UHD_FPGA_DIR
$(error UHD_FPGA_DIR is not set. It must point to the UHD FPGA repository!)
endif
# Define BASE_DIR to point to the "top" dir
BASE_DIR = $(UHD_FPGA_DIR)/usrp3/top
# Include viv_sim_preamble after defining BASE_DIR
include $(BASE_DIR)/../tools/make/viv_sim_preamble.mak

#-------------------------------------------------
# Design Specific
#-------------------------------------------------
# Define part using PART_ID (<device>/<package>/<speedgrade>)
ARCH = zynquplusRFSOC
PART_ID = xczu28dr/ffvg1517/-1/e

# Include makefiles and sources for the DUT and its dependencies
include $(BASE_DIR)/../lib/rfnoc/core/Makefile.srcs
include $(BASE_DIR)/../lib/rfnoc/utils/Makefile.srcs
include Makefile.srcs

DESIGN_SRCS += $(abspath \
$(RFNOC_SRCS)      \
$(RFNOC_CORE_SRCS) \
$(RFNOC_UTIL_SRCS) \
)

#-------------------------------------------------
# IP Specific
#-------------------------------------------------
# If simulation contains IP, define the IP_DIR and point it to the base level
# IP directory.
IP_DIR = $(BASE_DIR)/x400/ip
LIB_IP_DIR = $(BASE_DIR)/../lib/ip

# Include makefiles and sources for all IP components *after* defining the
# LIB_IP_DIR.
include $(IP_DIR)/aurora_100g/Makefile.inc

DESIGN_SRCS += $(abspath \
$(IP_AURORA_100G_SRCS) \
$(IP_AURORA_100G_HDL_SIM_SRCS) \
)

#-------------------------------------------------
# Testbench Specific
#-------------------------------------------------
MODELSIM_LIBS += secureip fifo_generator_v13_2_5 gtwizard_ultrascale_v1_7_10
SIM_TOP = rfnoc_block_aurora_all_tb glbl
SIM_SRCS = $(abspath \
rfnoc_block_aurora_tb.sv \
rfnoc_block_aurora_all_tb.sv \
$(VIVADO_PATH)/data/verilog/src/glbl.v \
)

#-------------------------------------------------
# Bottom-of-Makefile
#-------------------------------------------------
# Include all simulator specific makefiles here Each should define a unique
# target to simulate. E.g. xsim, vsim, etc. and a common "clean" target.
include $(BASE_DIR)/../tools/make/viv_simulator.mak
