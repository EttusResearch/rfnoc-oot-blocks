//
// Copyright 2020 Ettus Research, a National Instruments Brand
//
// SPDX-License-Identifier: GPL-3.0-or-later
//

#pragma once

#include <uhd/rfnoc/block_controller_factory_python.hpp>
#include <rfnoc/oot-blocks/aurora_block_control.hpp>

using namespace uhd::rfnoc;
using namespace rfnoc::oot_blocks;

void export_aurora_block_control(py::module& m)
{
    // Re-import ALL_CHANS here to avoid linker errors
    const static auto ALL_CHANS = aurora_block_control::ALL_CHANS;

    py::enum_<aurora_channel_stop_policy>(m, "channel_stop_policy")
        .value("DROP", aurora_channel_stop_policy::DROP)
        .value("BUFFER", aurora_channel_stop_policy::BUFFER)
        .export_values();

    py::class_<aurora_block_control, uhd::rfnoc::noc_block_base, aurora_block_control::sptr>(
        m, "aurora_block_control")
        .def(py::init(&block_controller_factory<aurora_block_control>::make_from))
        .def("get_status", &aurora_block_control::get_status)
        .def("get_link_status", &aurora_block_control::get_link_status)
        .def("get_lane_status",
            py::overload_cast<size_t>(&aurora_block_control::get_lane_status))
        .def("get_lane_status",
            py::overload_cast<>(&aurora_block_control::get_lane_status))
        .def("get_fc_pause_count", &aurora_block_control::get_fc_pause_count)
        .def("set_fc_pause_count", &aurora_block_control::set_fc_pause_count)
        .def("get_fc_pause_threshold", &aurora_block_control::get_fc_pause_threshold)
        .def("set_fc_pause_threshold", &aurora_block_control::set_fc_pause_threshold)
        .def("get_fc_resume_threshold", &aurora_block_control::get_fc_resume_threshold)
        .def("set_fc_resume_threshold", &aurora_block_control::set_fc_resume_threshold)
        .def("get_aurora_rx_packet_counter",
            &aurora_block_control::get_aurora_rx_packet_counter)
        .def("get_aurora_tx_packet_counter",
            &aurora_block_control::get_aurora_tx_packet_counter)
        .def("get_aurora_overflow_counter",
            &aurora_block_control::get_aurora_overflow_counter)
        .def("get_aurora_crc_error_counter",
            &aurora_block_control::get_aurora_crc_error_counter)
        .def("tx_datapath_enable",
            &aurora_block_control::tx_datapath_enable,
            py::arg("enable"),
            py::arg("channel") = ALL_CHANS)
        .def("tx_datapath_enqueue_timestamp",
            &aurora_block_control::tx_datapath_enqueue_timestamp,
            py::arg("timestamp"),
            py::arg("channel") = ALL_CHANS)
        .def("get_channel_stop_policy",
            py::overload_cast<size_t>(&aurora_block_control::get_channel_stop_policy))
        .def("get_channel_stop_policy",
            py::overload_cast<>(&aurora_block_control::get_channel_stop_policy))
        .def("set_channel_stop_policy",
            &aurora_block_control::set_channel_stop_policy,
            py::arg("channel_stop_policy"),
            py::arg("channel") = ALL_CHANS)
        .def("get_timestamp_queue_fullness",
            py::overload_cast<size_t>(
                &aurora_block_control::get_timestamp_queue_fullness))
        .def("get_timestamp_queue_fullness",
            py::overload_cast<>(&aurora_block_control::get_timestamp_queue_fullness))
        .def("get_timestamp_queue_size",
            py::overload_cast<size_t>(&aurora_block_control::get_timestamp_queue_size))
        .def("get_timestamp_queue_size",
            py::overload_cast<>(&aurora_block_control::get_timestamp_queue_size))
        .def("get_num_cores", &aurora_block_control::get_num_cores)
        .def("get_num_channels", &aurora_block_control::get_num_channels)
        .def("get_channels", &aurora_block_control::get_channels)
        .def("reset", &aurora_block_control::reset)
        .def("reset_tx", &aurora_block_control::reset_tx)
        .def("get_rx_async_metadata",
            &aurora_block_control::get_rx_async_metadata,
            py::arg("timeout") = 0.1)
        .def("get_tx_async_metadata",
            &aurora_block_control::get_tx_async_metadata,
            py::arg("timeout") = 0.1);
}
