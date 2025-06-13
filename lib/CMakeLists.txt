#
# Copyright 2019 Ettus Research, a National Instruments Brand
#
# SPDX-License-Identifier: GPL-3.0-or-later
#

########################################################################
# Set up library
########################################################################
# List any C++ sources here. If there are no sources (e.g., because there
# is no block controller), then this directory will be skipped.
list(APPEND rfnoc_blocks_sources
    #my_block_control.cpp
)
if(NOT rfnoc_blocks_sources)
    MESSAGE(STATUS "No C++ sources... skipping lib/")
    return()
endif()

########################################################################
# Setup the include and linker paths
########################################################################
include_directories(
    ${CMAKE_SOURCE_DIR}/lib
    ${CMAKE_SOURCE_DIR}/include
    ${CMAKE_BINARY_DIR}/lib
    ${CMAKE_BINARY_DIR}/include
    ${UHD_INCLUDE_DIRS}
    ${Boost_INCLUDE_DIR}
)

link_directories(
    ${Boost_LIBRARY_DIRS}
)

add_library(rfnoc-blocks SHARED
    ${rfnoc_blocks_sources}
)
target_link_libraries(rfnoc-blocks
    ${UHD_LIBRARIES}
    ${Boost_LIBRARIES}
)
set_target_properties(rfnoc-blocks
    PROPERTIES DEFINE_SYMBOL "RFNOC_BLOCKS_EXPORTS")

file(GENERATE OUTPUT ${CMAKE_BINARY_DIR}/lib/rfnoc-blocks CONTENT "$<TARGET_FILE_NAME:rfnoc-blocks>\n")

########################################################################
# Install built library files
########################################################################
install(TARGETS rfnoc-blocks
    LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR} # .so/.dylib file
    ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR} # .lib file
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR} # .dll file
)
install(FILES
    ${CMAKE_BINARY_DIR}/lib/rfnoc-blocks
    DESTINATION ${MODULES_D_DIR}
    COMPONENT libraries
)
