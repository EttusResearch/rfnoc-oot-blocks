#
# Copyright 2019 Ettus Research, a National Instruments Brand
#
# SPDX-License-Identifier: GPL-3.0-or-later
#

# IP gets installed as-is, we simply recursively copy the ip directory to
# wherever it's supposed to go.
install(
   DIRECTORY ip/
   DESTINATION ${GATEWARE_PKG_DATA_DIR}/ip
   COMPONENT gateware
)

add_subdirectory(rfnoc_block_aurora)
