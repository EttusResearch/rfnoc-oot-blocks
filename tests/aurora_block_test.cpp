//
// Copyright 2025 Ettus Research, a National Instruments Brand
//
// SPDX-License-Identifier: GPL-3.0-or-later
//

#include "rfnoc_graph_mock_nodes.hpp"
#include <rfnoc/oot-blocks/aurora_block_control.hpp>
#include <uhd/rfnoc/defaults.hpp>
#include <uhd/rfnoc/detail/graph.hpp>
#include <uhd/rfnoc/mock_block.hpp>
#include <uhd/rfnoc/node_accessor.hpp>
#include <boost/test/unit_test.hpp>
#include <iostream>

using namespace rfnoc::oot_blocks;

// Redeclare this here, since it's only defined outside of UHD_API
noc_block_base::make_args_t::~make_args_t() = default;

/*
 * This class extends mock_reg_iface_t, adding a register poke override
 * that monitors the reset strobe address and sets a flag when written.
 */
class aurora_mock_reg_iface_t : public mock_reg_iface_t
{
public:
    bool is_ro_register(uint32_t addr)
    {
        bool core_reg                   = false;
        bool channel_reg                = false;
        uint32_t addr_in_channel_region = -1;
        if (addr < aurora_block_control::channel_reg_size) {
            core_reg = true;
        } else {
            channel_reg            = true;
            addr_in_channel_region = addr & (aurora_block_control::channel_reg_size - 1);
        }
        if (core_reg
            && ((addr == aurora_block_control::REG_COMPAT_ADDR)
                || (addr == aurora_block_control::REG_CORE_CONFIG_ADDR)
                || (addr == aurora_block_control::REG_CORE_STATUS_ADDR)
                || (addr == aurora_block_control::REG_CORE_TX_PKT_CTR_ADDR)
                || (addr == aurora_block_control::REG_CORE_RX_PKT_CTR_ADDR)
                || (addr == aurora_block_control::REG_CORE_OVERFLOW_CTR_ADDR)
                || (addr == aurora_block_control::REG_CORE_CRC_ERR_CTR_ADDR))) {
            return true;
        } else if (channel_reg
                   && (addr_in_channel_region
                       == aurora_block_control::REG_CHAN_TS_QUEUE_STS_ADDR)) {
            return true;
        }
        return false;
    }

    bool is_wo_register(uint32_t addr)
    {
        bool core_reg                   = false;
        bool channel_reg                = false;
        uint32_t addr_in_channel_region = -1;
        if (addr < aurora_block_control::channel_reg_size) {
            core_reg = true;
        } else {
            channel_reg            = true;
            addr_in_channel_region = addr & (aurora_block_control::channel_reg_size - 1);
        }
        if (core_reg && (addr == aurora_block_control::REG_CORE_RESET_ADDR)) {
            return true;
        } else if (channel_reg
                   && ((addr_in_channel_region
                           == aurora_block_control::REG_CHAN_TX_CTRL_ADDR)
                       || (addr_in_channel_region
                           == aurora_block_control::REG_CHAN_TS_LOW_ADDR)
                       || (addr_in_channel_region
                           == aurora_block_control::REG_CHAN_TS_HIGH_ADDR))) {
            return true;
        }
        return false;
    }

    void set_ro_register(uint32_t addr, uint32_t data)
    {
        if (!is_ro_register(addr)) {
            throw uhd::assertion_error(
                str(boost::format("Register at address %08x is not a read-only register ")
                    % addr));
        }
        read_memory[addr] = data;
    }

    uint32_t read_wo_register(uint32_t addr)
    {
        if (!is_wo_register(addr)) {
            throw uhd::assertion_error(str(
                boost::format("Register at address %08x is not a write-only register ")
                % addr));
        }
        return write_memory[addr];
    }

    aurora_mock_reg_iface_t()
    {
        // Minor: 0 -> 0x0000
        // Major: 1 -> 0x0001
        set_ro_register(aurora_block_control::REG_COMPAT_ADDR, 0x00010000);
        // Number of cores: 1 -> 0x0001
        // Number of channels: 4 -> 0x0004
        set_ro_register(aurora_block_control::REG_CORE_CONFIG_ADDR, 0x00040001);
        set_ro_register(aurora_block_control::REG_CORE_STATUS_ADDR, 0);
        set_ro_register(aurora_block_control::REG_CORE_TX_PKT_CTR_ADDR, 0);
        set_ro_register(aurora_block_control::REG_CORE_RX_PKT_CTR_ADDR, 0);
        set_ro_register(aurora_block_control::REG_CORE_OVERFLOW_CTR_ADDR, 0);
        set_ro_register(aurora_block_control::REG_CORE_CRC_ERR_CTR_ADDR, 0);
    }

    uint32_t get_channel_register_addr(uint32_t channel, uint32_t addr)
    {
        return addr + ((channel + 1) * aurora_block_control::channel_reg_size);
    }

    void _poke_cb(
        uint32_t addr, uint32_t data, uhd::time_spec_t /*time*/, bool /*ack*/) override
    {
        if (is_ro_register(addr)) {
            throw uhd::assertion_error(
                str(boost::format("Trying to write to read-only register %08x") % addr));
        } else {
            write_memory[addr] = data;
        }
        UHD_LOG_TRACE("TEST", str(boost::format("poke [%04x] = %08x") % addr % data));
        if (addr == aurora_block_control::REG_CORE_RESET_ADDR) {
            reset();
        }
    }

    void _peek_cb(uint32_t addr, uhd::time_spec_t /*time*/) override
    {
        if (is_ro_register(addr)) {
            // the value in read_memory was set during initialization
        } else {
            read_memory[addr] = write_memory[addr];
        }
        UHD_LOG_TRACE(
            "TEST", str(boost::format("peek [%04x] = %08x") % addr % read_memory[addr]));
    }

    void reset()
    {
        aurora_was_reset = true;
    }

    bool aurora_was_reset = false;
};

/* aurora_block_fixture is a class which is instantiated before each test case
 * is run. It sets up the block container, mock register interface, and
 * aurora_block_control object, all of which are accessible to the test case.
 * The instance of the object is destroyed at the end of each test case.
 */

namespace {
constexpr size_t DEFAULT_MTU              = 8000;
constexpr uint8_t PAUSE_COUNT_DEFAULT     = 100;
constexpr size_t PAUSE_THRESHOLD_DEFAULT  = 160;
constexpr size_t RESUME_THRESHOLD_DEFAULT = 200;
}; // namespace

struct aurora_block_fixture
{
    //! Create an FFT block and all related infrastructure for unit testsing.
    aurora_block_fixture()
        : reg_iface(std::make_shared<aurora_mock_reg_iface_t>())
        , block_container(get_mock_block(AURORA_BLOCK,
              1,
              1,
              uhd::device_addr_t(),
              DEFAULT_MTU,
              ANY_DEVICE,
              reg_iface))
        , test_aurora(block_container.get_block<aurora_block_control>())
    {
        node_accessor.init_props(test_aurora.get());
    }

    std::shared_ptr<aurora_mock_reg_iface_t> reg_iface;
    mock_block_container block_container;
    std::shared_ptr<aurora_block_control> test_aurora;
    node_accessor_t node_accessor{};
};

/*
 * This test case ensures that the hardware is programmed correctly with
 * defaults when the FFT block is constructed.
 */
BOOST_FIXTURE_TEST_CASE(aurora_test_construction, aurora_block_fixture)
{
    BOOST_CHECK(reg_iface->aurora_was_reset);
}

/*
 * This test case ensures that the number of cores is set correctly.
 */
BOOST_FIXTURE_TEST_CASE(aurora_test_num_cores, aurora_block_fixture)
{
    UHD_LOG_INFO("TEST", "get_num_cores()");
    BOOST_CHECK_EQUAL(test_aurora->get_num_cores(), 1);
}

/*
 * This test case ensures that the number of channels is set correctly.
 */
BOOST_FIXTURE_TEST_CASE(aurora_test_num_channels, aurora_block_fixture)
{
    UHD_LOG_INFO("TEST", "get_num_channels()");
    BOOST_CHECK_EQUAL(test_aurora->get_num_channels(), 4);
}

// BOOST_CHECK_EQUAL_COLLECTIONS(left.lane_status.begin(), left.lane_status.end(),
// right.lane_status.begin(), right.lane_status.end());

#define COMPARE_STATUS_STRUCT(left, right)                                            \
    BOOST_CHECK(left.lane_status == right.lane_status);                               \
    BOOST_CHECK_EQUAL(left.link_status, right.link_status);                           \
    BOOST_CHECK_EQUAL(left.aurora_hard_error_status, right.aurora_hard_error_status); \
    BOOST_CHECK_EQUAL(left.aurora_soft_error_status, right.aurora_soft_error_status); \
    BOOST_CHECK_EQUAL(left.aurora_mmcm_lock_status, right.aurora_mmcm_lock_status);   \
    BOOST_CHECK_EQUAL(left.aurora_gt_pll_lock_status, right.aurora_gt_pll_lock_status);

/*
 * This test case ensures that reading the core status works correctly.
 */
BOOST_FIXTURE_TEST_CASE(aurora_test_get_status, aurora_block_fixture)
{
    aurora_block_control::status_struct default_status = {};
    default_status.lane_status                         = {false, false, false, false};
    {
        aurora_block_control::status_struct status = default_status;
        UHD_LOG_INFO("TEST", "get_status()");
        COMPARE_STATUS_STRUCT(test_aurora->get_status(), status);
    }
    {
        for (uint32_t i = 0; i < default_status.lane_status.size(); i++) {
            aurora_block_control::status_struct status = default_status;
            status.lane_status[i]                      = true;
            UHD_LOG_INFO("TEST",
                "get_status() with lane_status={"
                    << status.lane_status[0] << "," << status.lane_status[1] << ","
                    << status.lane_status[2] << "," << status.lane_status[3] << "}");
            reg_iface->set_ro_register(
                aurora_block_control::REG_CORE_STATUS_ADDR, 1 << i);
            COMPARE_STATUS_STRUCT(test_aurora->get_status(), status);
        }
    }
    {
        aurora_block_control::status_struct status = default_status;
        status.link_status                         = true;
        UHD_LOG_INFO("TEST", "get_status() with link_status=true");
        reg_iface->set_ro_register(aurora_block_control::REG_CORE_STATUS_ADDR, 1 << 4);
        COMPARE_STATUS_STRUCT(test_aurora->get_status(), status);
    }
    {
        aurora_block_control::status_struct status = default_status;
        status.aurora_hard_error_status            = true;
        UHD_LOG_INFO("TEST", "get_status() with aurora_hard_error_status=true");
        reg_iface->set_ro_register(aurora_block_control::REG_CORE_STATUS_ADDR, 1 << 8);
        COMPARE_STATUS_STRUCT(test_aurora->get_status(), status);
    }
    {
        aurora_block_control::status_struct status = default_status;
        status.aurora_soft_error_status            = true;
        UHD_LOG_INFO("TEST", "get_status() with aurora_soft_error_status=true");
        reg_iface->set_ro_register(aurora_block_control::REG_CORE_STATUS_ADDR, 1 << 9);
        COMPARE_STATUS_STRUCT(test_aurora->get_status(), status);
    }
    {
        aurora_block_control::status_struct status = default_status;
        status.aurora_mmcm_lock_status             = true;
        UHD_LOG_INFO("TEST", "get_status() with aurora_mmcm_lock_status=true");
        reg_iface->set_ro_register(aurora_block_control::REG_CORE_STATUS_ADDR, 1 << 12);
        COMPARE_STATUS_STRUCT(test_aurora->get_status(), status);
    }
    {
        aurora_block_control::status_struct status = default_status;
        status.aurora_gt_pll_lock_status           = true;
        UHD_LOG_INFO("TEST", "get_status() with aurora_gt_pll_lock_status=true");
        reg_iface->set_ro_register(aurora_block_control::REG_CORE_STATUS_ADDR, 1 << 13);
        COMPARE_STATUS_STRUCT(test_aurora->get_status(), status);
    }
}

/*
 * This test case ensures that the flow control parameters pause count,
 * pause threshold and resume threshold have the expected default values
 * after block reset.
 */
BOOST_FIXTURE_TEST_CASE(aurora_test_fcdefaults, aurora_block_fixture)
{
    BOOST_CHECK_EQUAL(test_aurora->get_fc_pause_count(), PAUSE_COUNT_DEFAULT);
    BOOST_CHECK_EQUAL(test_aurora->get_fc_pause_threshold(), PAUSE_THRESHOLD_DEFAULT);
    BOOST_CHECK_EQUAL(test_aurora->get_fc_resume_threshold(), RESUME_THRESHOLD_DEFAULT);
}

/*
 * This test case ensures that writing the fc_pause_count parameter works
 * correctly.
 */
BOOST_FIXTURE_TEST_CASE(aurora_test_fc_pause_count, aurora_block_fixture)
{
    std::vector<uint8_t> values = {0, 0x10, 0xFF, 0};
    uint16_t pause_threshold    = test_aurora->get_fc_pause_threshold();
    uint16_t resume_threshold   = test_aurora->get_fc_resume_threshold();
    for (uint8_t& value : values) {
        UHD_LOG_INFO(
            "TEST", str(boost::format("set_fc_pause_count(0x%02x)") % (uint32_t)value));
        test_aurora->set_fc_pause_count(value);
        BOOST_CHECK_EQUAL(test_aurora->get_fc_pause_count(), value);
        BOOST_CHECK_EQUAL(test_aurora->get_fc_pause_threshold(), pause_threshold);
        BOOST_CHECK_EQUAL(test_aurora->get_fc_resume_threshold(), resume_threshold);
    }
}

/*
 * This test case ensures that writing the fc_pause_threshold parameter works
 * correctly.
 */
BOOST_FIXTURE_TEST_CASE(aurora_test_fc_pause_threshold, aurora_block_fixture)
{
    std::vector<uint8_t> values = {0, 100, 255, 0};
    uint8_t pause_count         = test_aurora->get_fc_pause_count();
    uint16_t resume_threshold   = test_aurora->get_fc_resume_threshold();
    for (uint8_t& value : values) {
        UHD_LOG_INFO("TEST",
            str(boost::format("set_fc_pause_threshold(0x%02x)") % (uint32_t)value));
        test_aurora->set_fc_pause_threshold(value);
        BOOST_CHECK_EQUAL(test_aurora->get_fc_pause_count(), pause_count);
        BOOST_CHECK_EQUAL(test_aurora->get_fc_pause_threshold(), value);
        BOOST_CHECK_EQUAL(test_aurora->get_fc_resume_threshold(), resume_threshold);
    }
}

/*
 * This test case ensures that writing the fc_resume_threshold parameter works
 * correctly.
 */
BOOST_FIXTURE_TEST_CASE(aurora_test_fc_resume_threshold, aurora_block_fixture)
{
    std::vector<uint8_t> values = {0, 100, 255, 0};
    uint8_t pause_count         = test_aurora->get_fc_pause_count();
    uint16_t pause_threshold    = test_aurora->get_fc_pause_threshold();
    for (uint8_t& value : values) {
        UHD_LOG_INFO("TEST",
            str(boost::format("set_fc_resume_threshold(0x%02x)") % (uint32_t)value));
        test_aurora->set_fc_resume_threshold(value);
        BOOST_CHECK_EQUAL(test_aurora->get_fc_pause_count(), pause_count);
        BOOST_CHECK_EQUAL(test_aurora->get_fc_pause_threshold(), pause_threshold);
        BOOST_CHECK_EQUAL(test_aurora->get_fc_resume_threshold(), value);
    }
}

/*
 * This test case ensures that reading the RX packet counter works correctly.
 */
BOOST_FIXTURE_TEST_CASE(aurora_test_rx_packet_counter, aurora_block_fixture)
{
    std::vector<uint32_t> values = {0, 0x1, 0x1000, 0x10000000, 0xFFFFFFFF, 0};
    for (uint32_t& value : values) {
        UHD_LOG_INFO(
            "TEST", str(boost::format("get_aurora_rx_packet_counter(0x%08x)") % value));
        reg_iface->set_ro_register(aurora_block_control::REG_CORE_RX_PKT_CTR_ADDR, value);
        BOOST_CHECK_EQUAL(test_aurora->get_aurora_rx_packet_counter(), value);
        BOOST_CHECK_EQUAL(test_aurora->get_aurora_tx_packet_counter(), 0);
        BOOST_CHECK_EQUAL(test_aurora->get_aurora_overflow_counter(), 0);
        BOOST_CHECK_EQUAL(test_aurora->get_aurora_crc_error_counter(), 0);
    }
}

/*
 * This test case ensures that reading the overflow counter works correctly.
 */
BOOST_FIXTURE_TEST_CASE(aurora_test_tx_packet_counter, aurora_block_fixture)
{
    std::vector<uint32_t> values = {0, 0x1, 0x1000, 0x10000000, 0xFFFFFFFF, 0};
    for (uint32_t& value : values) {
        UHD_LOG_INFO(
            "TEST", str(boost::format("get_aurora_tx_packet_counter(0x%08x)") % value));
        reg_iface->set_ro_register(aurora_block_control::REG_CORE_TX_PKT_CTR_ADDR, value);
        BOOST_CHECK_EQUAL(test_aurora->get_aurora_rx_packet_counter(), 0);
        BOOST_CHECK_EQUAL(test_aurora->get_aurora_tx_packet_counter(), value);
        BOOST_CHECK_EQUAL(test_aurora->get_aurora_overflow_counter(), 0);
        BOOST_CHECK_EQUAL(test_aurora->get_aurora_crc_error_counter(), 0);
    }
}

/*
 * This test case ensures that reading the CRC error counter works correctly.
 */
BOOST_FIXTURE_TEST_CASE(aurora_test_overflow_counter, aurora_block_fixture)
{
    std::vector<uint32_t> values = {0, 0x1, 0x1000, 0x10000000, 0xFFFFFFFF, 0};
    for (uint32_t& value : values) {
        UHD_LOG_INFO(
            "TEST", str(boost::format("get_aurora_overflow_counter(0x%08x)") % value));
        reg_iface->set_ro_register(
            aurora_block_control::REG_CORE_OVERFLOW_CTR_ADDR, value);
        BOOST_CHECK_EQUAL(test_aurora->get_aurora_rx_packet_counter(), 0);
        BOOST_CHECK_EQUAL(test_aurora->get_aurora_tx_packet_counter(), 0);
        BOOST_CHECK_EQUAL(test_aurora->get_aurora_overflow_counter(), value);
        BOOST_CHECK_EQUAL(test_aurora->get_aurora_crc_error_counter(), 0);
    }
}

/*
 * This test case ensures that reading the RX packet counter works correctly.
 */
BOOST_FIXTURE_TEST_CASE(aurora_test_crc_error_counter, aurora_block_fixture)
{
    std::vector<uint32_t> values = {0, 0x1, 0x1000, 0x10000000, 0xFFFFFFFF, 0};
    for (uint32_t& value : values) {
        UHD_LOG_INFO(
            "TEST", str(boost::format("get_aurora_crc_error_counter(0x%08x)") % value));
        reg_iface->set_ro_register(
            aurora_block_control::REG_CORE_CRC_ERR_CTR_ADDR, value);
        BOOST_CHECK_EQUAL(test_aurora->get_aurora_rx_packet_counter(), 0);
        BOOST_CHECK_EQUAL(test_aurora->get_aurora_tx_packet_counter(), 0);
        BOOST_CHECK_EQUAL(test_aurora->get_aurora_overflow_counter(), 0);
        BOOST_CHECK_EQUAL(test_aurora->get_aurora_crc_error_counter(), value);
    }
}

/*
 * This test case ensures that reading the packet counters works correctly.
 */
BOOST_FIXTURE_TEST_CASE(aurora_test_tx_datapath_all, aurora_block_fixture)
{
    UHD_LOG_INFO("TEST", "tx_datapath_enable(true)");
    test_aurora->tx_datapath_enable(true);
    for (auto& channel : test_aurora->get_channels()) {
        BOOST_CHECK_EQUAL(
            reg_iface->read_wo_register(reg_iface->get_channel_register_addr(
                channel, aurora_block_control::REG_CHAN_TX_CTRL_ADDR)),
            0x01);
    }
    UHD_LOG_INFO("TEST", "tx_datapath_enable(false)");
    test_aurora->tx_datapath_enable(false);
    for (auto& channel : test_aurora->get_channels()) {
        BOOST_CHECK_EQUAL(
            reg_iface->read_wo_register(reg_iface->get_channel_register_addr(
                channel, aurora_block_control::REG_CHAN_TX_CTRL_ADDR)),
            0x02);
    }
}

/*
 * This test case ensures that reading the packet counters works correctly.
 */
BOOST_FIXTURE_TEST_CASE(aurora_test_tx_datapath_single_channel, aurora_block_fixture)
{
    for (auto& channel : test_aurora->get_channels()) {
        UHD_LOG_INFO(
            "TEST", str(boost::format("tx_datapath_enable(true, channel=%d)") % channel));
        test_aurora->tx_datapath_enable(true, channel);
        BOOST_CHECK_EQUAL(
            reg_iface->read_wo_register(reg_iface->get_channel_register_addr(
                channel, aurora_block_control::REG_CHAN_TX_CTRL_ADDR)),
            0x01);
    }
    for (auto& channel : test_aurora->get_channels()) {
        UHD_LOG_INFO("TEST",
            str(boost::format("tx_datapath_enable(false, channel=%d)") % channel));
        test_aurora->tx_datapath_enable(false, channel);
        BOOST_CHECK_EQUAL(
            reg_iface->read_wo_register(reg_iface->get_channel_register_addr(
                channel, aurora_block_control::REG_CHAN_TX_CTRL_ADDR)),
            0x02);
    }
}

/*
 * This test case ensures that reading the packet counters works correctly.
 */
BOOST_FIXTURE_TEST_CASE(aurora_test_tx_start_timestamp, aurora_block_fixture)
{
    for (auto& channel : test_aurora->get_channels()) {
        std::vector<uint64_t> values = {0x00000001, 0x12345678, 0xFFFFFFFF};
        for (auto& high : values) {
            for (auto& low : values) {
                UHD_LOG_INFO("TEST",
                    str(boost::format("tx_datapath_enqueue_timestamp(0x%08x%08x)") % high
                        % low));
                test_aurora->tx_datapath_enqueue_timestamp((high << 32) | low);
                BOOST_CHECK_EQUAL(
                    reg_iface->read_wo_register(reg_iface->get_channel_register_addr(
                        channel, aurora_block_control::REG_CHAN_TS_LOW_ADDR)),
                    low);
                BOOST_CHECK_EQUAL(
                    reg_iface->read_wo_register(reg_iface->get_channel_register_addr(
                        channel, aurora_block_control::REG_CHAN_TS_HIGH_ADDR)),
                    high);
            }
        }
    }
}

/*
 * This test case ensures that setting and reading the channel stop policy works
 * correctly.
 */
BOOST_FIXTURE_TEST_CASE(
    aurora_test_channel_stop_policy_single_channel, aurora_block_fixture)
{
    std::vector<aurora_channel_stop_policy> values = {aurora_channel_stop_policy::DROP,
        aurora_channel_stop_policy::BUFFER,
        aurora_channel_stop_policy::DROP};
    for (auto& value : values) {
        for (auto& channel : test_aurora->get_channels()) {
            UHD_LOG_INFO("TEST",
                str(boost::format("set_channel_stop_policy(%u, %u)") % channel
                    % (uint32_t)value));
            test_aurora->set_channel_stop_policy(value, channel);
            BOOST_CHECK_EQUAL(
                (uint32_t)test_aurora->get_channel_stop_policy(channel), (uint32_t)value);
        }
    }
}

/*
 * This test case ensures that setting and reading the channel stop policy works
 * correctly.
 */
BOOST_FIXTURE_TEST_CASE(
    aurora_test_channel_stop_policy_all_channels, aurora_block_fixture)
{
    std::vector<aurora_channel_stop_policy> values = {aurora_channel_stop_policy::DROP,
        aurora_channel_stop_policy::BUFFER,
        aurora_channel_stop_policy::DROP};
    for (auto& value : values) {
        UHD_LOG_INFO(
            "TEST", str(boost::format("set_channel_stop_policy(%u)") % (uint32_t)value));
        std::vector<aurora_channel_stop_policy> vec(
            test_aurora->get_num_channels(), value);
        test_aurora->set_channel_stop_policy(value, aurora_block_control::ALL_CHANS);
        BOOST_CHECK(test_aurora->get_channel_stop_policy() == vec);
    }
}

/*
 * This test case ensures that reading the timestamp queue fullness and size works
 * correctly.
 */
BOOST_FIXTURE_TEST_CASE(
    aurora_test_channel_get_timestamp_queue_fullness_and_size_single_channel,
    aurora_block_fixture)
{
    std::vector<uint16_t> values = {0, 0x1, 0x1234, 0xFFFF};
    for (auto& channel : test_aurora->get_channels()) {
        for (auto& fullness : values) {
            for (auto& size : values) {
                uint32_t data = ((uint32_t)size << 16) | (uint32_t)fullness;
                reg_iface->set_ro_register(
                    reg_iface->get_channel_register_addr(
                        channel, aurora_block_control::REG_CHAN_TS_QUEUE_STS_ADDR),
                    data);
                UHD_LOG_INFO("TEST",
                    str(boost::format("get_timestamp_queue_fullness(%u) with "
                                      "fullness=0x%04x and size=0x%04x")
                        % channel % fullness % size));
                BOOST_CHECK_EQUAL(
                    test_aurora->get_timestamp_queue_fullness(channel), fullness);
                UHD_LOG_INFO("TEST",
                    str(boost::format("get_timestamp_queue_size(%u) with fullness=0x%04x "
                                      "and size=0x%04x")
                        % channel % fullness % size));
                BOOST_CHECK_EQUAL(test_aurora->get_timestamp_queue_size(channel), size);
            }
        }
    }
}

/*
 * This test case ensures that reading the timestamp queue fullness and size works
 * correctly.
 */
BOOST_FIXTURE_TEST_CASE(
    aurora_test_channel_get_timestamp_queue_fullness_and_size_all_channels,
    aurora_block_fixture)
{
    std::vector<uint16_t> values = {0, 0x1, 0x1234, 0xFFFF};
    for (auto& fullness : values) {
        for (auto& size : values) {
            uint32_t data = ((uint32_t)size << 16) | (uint32_t)fullness;
            for (auto& channel : test_aurora->get_channels()) {
                reg_iface->set_ro_register(
                    reg_iface->get_channel_register_addr(
                        channel, aurora_block_control::REG_CHAN_TS_QUEUE_STS_ADDR),
                    data);
            }
            UHD_LOG_INFO("TEST",
                str(boost::format("get_timestamp_queue_fullness() with fullness=0x%04x "
                                  "and size=0x%04x")
                    % fullness % size));
            for (auto& retval : test_aurora->get_timestamp_queue_fullness()) {
                BOOST_CHECK_EQUAL(retval, fullness);
            }
            UHD_LOG_INFO("TEST",
                str(boost::format(
                        "get_timestamp_queue_size() with fullness=0x%04x and size=0x%04x")
                    % fullness % size));
            for (auto& retval : test_aurora->get_timestamp_queue_size()) {
                BOOST_CHECK_EQUAL(retval, size);
            }
        }
    }
}

/*
 * This test case ensures that reading and writing the properties works.
 */
BOOST_FIXTURE_TEST_CASE(aurora_test_properties, aurora_block_fixture)
{
    std::vector<uint32_t> u32_values = {0x00000000, 0x00010002, 0x1234567, 0xFFFFFFFF};
    {
        UHD_LOG_INFO("TEST", "Testing property " << PROP_KEY_NUM_CORES);
        BOOST_CHECK_EQUAL(test_aurora->get_num_cores(),
            test_aurora->get_property<size_t>(PROP_KEY_NUM_CORES));
    }
    {
        UHD_LOG_INFO("TEST", "Testing property " << PROP_KEY_NUM_CHANNELS);
        BOOST_CHECK_EQUAL(test_aurora->get_num_channels(),
            test_aurora->get_property<size_t>(PROP_KEY_NUM_CHANNELS));
    }
    {
        UHD_LOG_INFO("TEST", "Testing property " << PROP_KEY_NUM_CHANNELS);
        uint8_t pause_count = 10;
        test_aurora->set_property<uint8_t>(PROP_KEY_FC_PAUSE_COUNT, pause_count);
        BOOST_CHECK_EQUAL(
            test_aurora->get_property<uint8_t>(PROP_KEY_FC_PAUSE_COUNT), pause_count);
    }
    {
        UHD_LOG_INFO("TEST", "Testing property " << PROP_KEY_FC_PAUSE_THRESHOLD);
        uint16_t pause_threshold = 1000;
        test_aurora->set_property<uint16_t>(PROP_KEY_FC_PAUSE_THRESHOLD, pause_threshold);
        BOOST_CHECK_EQUAL(
            test_aurora->get_property<uint16_t>(PROP_KEY_FC_PAUSE_THRESHOLD),
            pause_threshold);
    }
    {
        UHD_LOG_INFO("TEST", "Testing property " << PROP_KEY_FC_RESUME_THRESHOLD);
        uint16_t resume_threshold = 2000;
        test_aurora->set_property<uint16_t>(
            PROP_KEY_FC_RESUME_THRESHOLD, resume_threshold);
        BOOST_CHECK_EQUAL(
            test_aurora->get_property<uint16_t>(PROP_KEY_FC_RESUME_THRESHOLD),
            resume_threshold);
    }
    {
        UHD_LOG_INFO("TEST", "Testing property " << PROP_KEY_RX_PACKET_COUNTER);
        for (auto& value : u32_values) {
            reg_iface->set_ro_register(
                aurora_block_control::REG_CORE_RX_PKT_CTR_ADDR, value);
            BOOST_CHECK_EQUAL(test_aurora->get_aurora_rx_packet_counter(), value);
            BOOST_CHECK_EQUAL(
                test_aurora->get_property<uint32_t>(PROP_KEY_RX_PACKET_COUNTER), value);
        }
    }
    {
        UHD_LOG_INFO("TEST", "Testing property " << PROP_KEY_TX_PACKET_COUNTER);
        for (auto& value : u32_values) {
            reg_iface->set_ro_register(
                aurora_block_control::REG_CORE_TX_PKT_CTR_ADDR, value);
            BOOST_CHECK_EQUAL(test_aurora->get_aurora_tx_packet_counter(), value);
            BOOST_CHECK_EQUAL(
                test_aurora->get_property<uint32_t>(PROP_KEY_TX_PACKET_COUNTER), value);
        }
    }
    {
        UHD_LOG_INFO("TEST", "Testing property " << PROP_KEY_OVERFLOW_COUNTER);
        for (auto& value : u32_values) {
            reg_iface->set_ro_register(
                aurora_block_control::REG_CORE_OVERFLOW_CTR_ADDR, value);
            BOOST_CHECK_EQUAL(test_aurora->get_aurora_overflow_counter(), value);
            BOOST_CHECK_EQUAL(
                test_aurora->get_property<uint32_t>(PROP_KEY_OVERFLOW_COUNTER), value);
        }
    }
    {
        UHD_LOG_INFO("TEST", "Testing property " << PROP_KEY_CRC_ERROR_COUNTER);
        for (auto& value : u32_values) {
            reg_iface->set_ro_register(
                aurora_block_control::REG_CORE_CRC_ERR_CTR_ADDR, value);
            BOOST_CHECK_EQUAL(test_aurora->get_aurora_crc_error_counter(), value);
            BOOST_CHECK_EQUAL(
                test_aurora->get_property<uint32_t>(PROP_KEY_CRC_ERROR_COUNTER), value);
        }
    }
    {
        UHD_LOG_INFO("TEST", "Testing property " << PROP_KEY_CRC_ERROR_COUNTER);
        for (auto& value : u32_values) {
            reg_iface->set_ro_register(
                aurora_block_control::REG_CORE_CRC_ERR_CTR_ADDR, value);
            BOOST_CHECK_EQUAL(test_aurora->get_aurora_crc_error_counter(), value);
            BOOST_CHECK_EQUAL(
                test_aurora->get_property<uint32_t>(PROP_KEY_CRC_ERROR_COUNTER), value);
        }
    }
}
