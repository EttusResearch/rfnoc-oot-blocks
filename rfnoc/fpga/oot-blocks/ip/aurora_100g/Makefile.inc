#
# Copyright 2025 Ettus Research, a National Instruments Brand
#
# SPDX-License-Identifier: LGPL-3.0-or-later
#

# We first need to figure out our own path, because this file could be included
# from anywhere.
THIS_IP_DIR := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))/..

# This include provides BUILD_VIVADO_IP
include $(TOOLS_DIR)/make/viv_ip_builder.mak


IP_AURORA_100G_SRCS = $(IP_BUILD_DIR)/aurora_100g/aurora_100g.xci

IP_AURORA_100G_HDL_SIM_SRCS = \
$(wildcard $(addprefix $(IP_BUILD_DIR)/aurora_100g/, \
ip_0/sim/gtwizard_ultrascale_v1_7_gtye4_channel.v \
ip_0/sim/aurora_100g_gt_gtye4_channel_wrapper.v \
ip_0/sim/aurora_100g_gt_gtwizard_gtye4.v \
ip_0/sim/aurora_100g_gt_gtwizard_top.v \
ip_0/sim/aurora_100g_gt.v \
ip_1/sim/aurora_100g_fifo_gen_master.v \
ip_2/sim/aurora_100g_fifo_gen_slave.v \
aurora_100g/src/aurora_100g_aurora_lane.v \
aurora_100g/src/aurora_100g_support.v \
aurora_100g/example_design/gtwizard_ultrascale_v1_7_gtye4_common.v \
aurora_100g/example_design/aurora_100g_gt_gtye4_common_wrapper.v \
aurora_100g/src/aurora_100g_gt_common_wrapper.v \
aurora_100g/src/aurora_100g_support_reset_logic.v \
aurora_100g/src/aurora_100g_ultrascale_tx_userclk.v \
aurora_100g/src/aurora_100g_clock_module.v \
aurora_100g/example_design/aurora_100g_axi_to_drp.v \
aurora_100g/example_design/gt/aurora_100g_multi_wrapper.v \
aurora_100g/example_design/gt/aurora_100g_ultrascale_rx_userclk.v \
aurora_100g/src/aurora_100g_standard_cc_module.v \
aurora_100g/src/aurora_100g_reset_logic.v \
aurora_100g/src/aurora_100g_cdc_sync.v \
aurora_100g_core.v \
aurora_100g/src/aurora_100g_block_sync_sm.v \
aurora_100g/src/aurora_100g_common_reset_cbcc.v \
aurora_100g/src/aurora_100g_common_logic_cbcc.v \
aurora_100g/src/aurora_100g_cbcc_gtx_6466.v \
aurora_100g/src/aurora_100g_channel_err_detect.v \
aurora_100g/src/aurora_100g_channel_init_sm.v \
aurora_100g/src/aurora_100g_ch_bond_code_gen.v \
aurora_100g/src/aurora_100g_crc_top.v \
aurora_100g/src/aurora_100g_64b66b_descrambler.v \
aurora_100g/src/aurora_100g_err_detect.v \
aurora_100g/src/aurora_100g_global_logic.v \
aurora_100g/src/aurora_100g_polarity_check.v \
aurora_100g/example_design/gt/aurora_100g_wrapper.v \
aurora_100g/src/aurora_100g_lane_init_sm.v \
aurora_100g/src/aurora_100g_rxcrc_axi.v \
aurora_100g/src/aurora_100g_rx_ll_datapath.v \
aurora_100g/src/aurora_100g_rx_ll.v \
aurora_100g/src/aurora_100g_rx_ll_nfc.v \
aurora_100g/src/aurora_100g_width_conversion.v \
aurora_100g/src/aurora_100g_64b66b_scrambler.v \
aurora_100g/src/aurora_100g_sym_dec.v \
aurora_100g/src/aurora_100g_sym_gen.v \
aurora_100g/src/aurora_100g_txcrc_axi.v \
aurora_100g/src/aurora_100g_tx_ll_control_sm.v \
aurora_100g/src/aurora_100g_tx_ll_datapath.v \
aurora_100g/src/aurora_100g_tx_ll.v \
aurora_100g.v \
))

IP_AURORA_100G_OUTS = $(addprefix $(IP_BUILD_DIR)/aurora_100g/, \
aurora_100g.xci.out \
aurora_100g.v \
)

.INTERMEDIATE: IP_AURORA_100G_TRGT
$(IP_AURORA_100G_SRCS) $(IP_AURORA_100G_OUTS): IP_AURORA_100G_TRGT
	@:

IP_AURORA_100G_TRGT: $(THIS_IP_DIR)/aurora_100g/aurora_100g.xci
	$(call BUILD_VIVADO_IP,aurora_100g,$(ARCH),$(PART_ID),$(THIS_IP_DIR),$(IP_BUILD_DIR),1)
