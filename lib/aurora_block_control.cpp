//
// Copyright 2024 Ettus Research, a National Instruments Brand
//
// SPDX-License-Identifier: GPL-3.0-or-later
//

// Include our own header:
#include <rfnoc/oot-blocks/aurora_block_control.hpp>

// These two includes are the minimum required to implement a block:
#include <uhd/rfnoc/defaults.hpp>
#include <uhd/rfnoc/registry.hpp>
#include <uhd/transport/bounded_buffer.hpp>
#include <uhd/utils/compat_check.hpp>
#include <boost/format.hpp>
#include <numeric>

using namespace rfnoc::oot_blocks;
using namespace uhd::rfnoc;

namespace {

constexpr uint16_t MAJOR_COMPAT = 1;
constexpr uint16_t MINOR_COMPAT = 0;

} // namespace

const uint32_t aurora_block_control::REG_COMPAT_ADDR             = 0x0;
const uint32_t aurora_block_control::REG_CORE_CONFIG_ADDR        = 0x4;
const uint32_t aurora_block_control::REG_NUM_CORES_POS           = 0;
const uint32_t aurora_block_control::REG_NUM_CORES_MASK          = 0xFF;
const uint32_t aurora_block_control::REG_NUM_CHAN_POS            = 16;
const uint32_t aurora_block_control::REG_NUM_CHAN_MASK           = 0xFF;
const uint32_t aurora_block_control::REG_CORE_STATUS_ADDR        = 0x8;
const uint32_t aurora_block_control::REG_LANE_STATUS_POS         = 0;
const uint32_t aurora_block_control::REG_LANE_STATUS_MASK        = 0xF;
const uint32_t aurora_block_control::REG_LANE_STATUS_LEN         = 4;
const uint32_t aurora_block_control::REG_LINK_STATUS_POS         = 4;
const uint32_t aurora_block_control::REG_HARD_ERR_POS            = 8;
const uint32_t aurora_block_control::REG_SOFT_ERR_POS            = 9;
const uint32_t aurora_block_control::REG_MMCM_LOCK_POS           = 12;
const uint32_t aurora_block_control::REG_PLL_LOCK_POS            = 13;
const uint32_t aurora_block_control::REG_CORE_RESET_ADDR         = 0xC;
const uint32_t aurora_block_control::REG_AURORA_RESET_POS        = 0;
const uint32_t aurora_block_control::REG_TX_DATAPATH_RESET_POS   = 1;
const uint32_t aurora_block_control::REG_RX_DATAPATH_RESET_POS   = 2;
const uint32_t aurora_block_control::REG_CORE_FC_PAUSE_ADDR      = 0x10;
const uint32_t aurora_block_control::REG_PAUSE_COUNT_POS         = 0;
const uint32_t aurora_block_control::REG_PAUSE_COUNT_MASK        = 0xFF;
const uint32_t aurora_block_control::REG_CORE_FC_THRESHOLD_ADDR  = 0x14;
const uint32_t aurora_block_control::REG_PAUSE_THRESH_POS        = 0;
const uint32_t aurora_block_control::REG_PAUSE_THRESH_MASK       = 0xFF;
const uint32_t aurora_block_control::REG_RESUME_THRESH_POS       = 16;
const uint32_t aurora_block_control::REG_RESUME_THRESH_MASK      = 0xFF;
const uint32_t aurora_block_control::REG_CORE_TX_PKT_CTR_ADDR    = 0x18;
const uint32_t aurora_block_control::REG_CORE_RX_PKT_CTR_ADDR    = 0x1C;
const uint32_t aurora_block_control::REG_CORE_OVERFLOW_CTR_ADDR  = 0x20;
const uint32_t aurora_block_control::REG_CORE_CRC_ERR_CTR_ADDR   = 0x24;
const uint32_t aurora_block_control::REG_CHAN_TX_CTRL_ADDR       = 0x0;
const uint32_t aurora_block_control::REG_CHAN_TX_CTRL_MASK       = 0x3;
const uint32_t aurora_block_control::REG_CHAN_TX_START_POS       = 0;
const uint32_t aurora_block_control::REG_CHAN_TX_STOP_POS        = 1;
const uint32_t aurora_block_control::REG_CHAN_TS_LOW_ADDR        = 0x4;
const uint32_t aurora_block_control::REG_CHAN_TS_LOW_MASK        = 0xFFFFFFFF;
const uint32_t aurora_block_control::REG_CHAN_TS_HIGH_ADDR       = 0x8;
const uint32_t aurora_block_control::REG_CHAN_TS_HIGH_MASK       = 0xFFFFFFFF;
const uint32_t aurora_block_control::REG_CHAN_STOP_POLICY_ADDR   = 0xC;
const uint32_t aurora_block_control::REG_CHAN_STOP_POLICY_MASK   = 0x1;
const uint32_t aurora_block_control::REG_CHAN_TS_QUEUE_STS_ADDR  = 0x10;
const uint32_t aurora_block_control::REG_CHAN_TS_QUEUE_STS_MASK  = 0xFFFFFFFF;
const uint32_t aurora_block_control::REG_TS_FULLNESS_POS         = 0;
const uint32_t aurora_block_control::REG_TS_FULLNESS_MASK        = 0xFFFF;
const uint32_t aurora_block_control::REG_TS_SIZE_POS             = 16;
const uint32_t aurora_block_control::REG_TS_SIZE_MASK            = 0xFFFF;
const uint32_t aurora_block_control::REG_CHAN_TS_QUEUE_CTRL_ADDR = 0x14;
const uint32_t aurora_block_control::REG_CHAN_TS_QUEUE_CTRL_MASK = 0x00000001;

const uint32_t aurora_block_control::channel_reg_size =
    1 << 6; // adopt to AURORA_CHAN_ADDR_W
const uint32_t aurora_block_control::core_reg_size = 1
                                                     << 11; // adopt to AURORA_CORE_ADDR_W

// Depth of the async message queues
constexpr size_t ASYNC_MSG_QUEUE_SIZE = 128;

class aurora_block_control_impl : public aurora_block_control
{
public:
    RFNOC_BLOCK_CONSTRUCTOR(aurora_block_control),
        _fpga_compat(uhd::compat_num32{regs().peek32(REG_COMPAT_ADDR)}),
        _config_reg(regs().peek32(REG_CORE_CONFIG_ADDR)),
        _num_cores((_config_reg >> REG_NUM_CORES_POS) & REG_NUM_CORES_MASK),
        _num_channels((_config_reg >> REG_NUM_CHAN_POS) & REG_NUM_CHAN_MASK)
    {
        if (get_num_input_ports() != get_num_output_ports()) {
            throw uhd::assertion_error(
                "Aurora block has invalid hardware configuration! Number of input ports "
                "does not match number of output ports.");
        }
        if (_fpga_compat.get_major() >= 2) {
            uhd::assert_fpga_compat(MAJOR_COMPAT,
                MINOR_COMPAT,
                _fpga_compat.get(),
                get_unique_id(),
                get_unique_id(),
                false /* Let it slide if minors mismatch */
            );
        }
        RFNOC_LOG_TRACE(
            "Initializing aurora block with num ports=" << get_num_input_ports());

        _channels.reserve(_num_channels);
        for (size_t i = 0; i < _num_channels; i++) {
            _channels.push_back(i);
        }

        // Properties and actions can't propagate through this block, as we
        // treat source and sink of this block like the radio (they terminate
        // the graph).
        set_prop_forwarding_policy(forwarding_policy_t::DROP);
        set_action_forwarding_policy(forwarding_policy_t::DROP);
        // Same for MTU
        set_mtu_forwarding_policy(forwarding_policy_t::DROP);

        _reset();
        _register_properties();
        _register_action_handlers();
    }

    void _assert_channel_param(const size_t channel)
    {
        if (channel >= _num_channels)
            throw uhd::value_error((
                boost::format("channel %u is invalid, Aurora block has only %u channels.")
                % channel % _num_channels)
                                       .str());
    }

    status_struct get_status() override
    {
        uint32_t raw_value = regs().peek32(REG_CORE_STATUS_ADDR);
        status_struct status;
        for (size_t lane = 0; lane < (size_t)REG_LANE_STATUS_LEN; lane++) {
            status.lane_status.push_back(
                (bool)((raw_value >> (REG_LANE_STATUS_POS + lane)) & 1));
        }
        status.link_status               = (bool)((raw_value >> REG_LINK_STATUS_POS) & 1);
        status.aurora_hard_error_status  = (bool)((raw_value >> REG_HARD_ERR_POS) & 1);
        status.aurora_soft_error_status  = (bool)((raw_value >> REG_SOFT_ERR_POS) & 1);
        status.aurora_mmcm_lock_status   = (bool)((raw_value >> REG_MMCM_LOCK_POS) & 1);
        status.aurora_gt_pll_lock_status = (bool)((raw_value >> REG_PLL_LOCK_POS) & 1);
        return status;
    }

    bool get_link_status() override
    {
        return get_status().link_status;
    }

    bool get_lane_status(const size_t channel) override
    {
        _assert_channel_param(channel);
        return get_status().lane_status[channel];
    }

    std::vector<bool> get_lane_status() override
    {
        std::vector<bool> retval;
        for (auto& channel : _channels) {
            retval.push_back(get_status().lane_status[channel]);
        }
        return retval;
    }

    uint8_t get_fc_pause_count() override
    {
        return (regs().peek32(REG_CORE_FC_PAUSE_ADDR) >> REG_PAUSE_COUNT_POS)
               & REG_PAUSE_COUNT_MASK;
    }

    void set_fc_pause_count(uint8_t pause_count) override
    {
        if ((pause_count > 0) && (pause_count < 10)) {
            throw uhd::value_error("Invalid pause count value.");
        }
        regs().poke32(
            REG_CORE_FC_PAUSE_ADDR, (uint32_t)pause_count << REG_PAUSE_COUNT_POS);
    }

    uint8_t get_fc_pause_threshold() override
    {
        return (
            uint8_t)((regs().peek32(REG_CORE_FC_THRESHOLD_ADDR) >> REG_PAUSE_THRESH_POS)
                     & REG_PAUSE_THRESH_MASK);
    }

    void set_fc_pause_threshold(uint8_t pause_threshold) override
    {
        uint32_t other_bits = regs().peek32(REG_CORE_FC_THRESHOLD_ADDR)
                              & ~(REG_PAUSE_THRESH_MASK << REG_PAUSE_THRESH_POS);
        uint32_t own_bits = ((uint32_t)pause_threshold) << REG_PAUSE_THRESH_POS;
        regs().poke32(REG_CORE_FC_THRESHOLD_ADDR, other_bits | own_bits);
    }

    uint8_t get_fc_resume_threshold() override
    {
        return ((regs().peek32(REG_CORE_FC_THRESHOLD_ADDR) >> REG_RESUME_THRESH_POS))
               & REG_RESUME_THRESH_MASK;
    }

    void set_fc_resume_threshold(uint8_t resume_threshold) override
    {
        uint32_t existing_bits = regs().peek32(REG_CORE_FC_THRESHOLD_ADDR)
                                 & ~(REG_RESUME_THRESH_MASK << REG_RESUME_THRESH_POS);
        uint32_t own_bits = (uint32_t)resume_threshold << REG_RESUME_THRESH_POS;
        regs().poke32(REG_CORE_FC_THRESHOLD_ADDR, existing_bits | own_bits);
    }

    uint32_t get_aurora_rx_packet_counter() override
    {
        return regs().peek32(REG_CORE_RX_PKT_CTR_ADDR);
    }

    uint32_t get_aurora_tx_packet_counter() override
    {
        return regs().peek32(REG_CORE_TX_PKT_CTR_ADDR);
    }

    uint32_t get_aurora_overflow_counter() override
    {
        return regs().peek32(REG_CORE_OVERFLOW_CTR_ADDR);
    }

    uint32_t get_aurora_crc_error_counter() override
    {
        return regs().peek32(REG_CORE_CRC_ERR_CTR_ADDR);
    }

    // TODO: remove from API?
    void tx_datapath_enable(bool enable, const size_t channel = ALL_CHANS) override
    {
        if (channel == ALL_CHANS) {
            for (auto& channel : _channels) {
                _tx_datapath_enable(channel, enable);
            }
        } else {
            _assert_channel_param(channel);
            if (enable) {
                RFNOC_LOG_WARNING(
                    "Enabling only a single channel can lead to undesired behavior");
            } else {
                RFNOC_LOG_WARNING(
                    "Disabling only a single channel can lead to undesired behavior");
            }
            _tx_datapath_enable(channel, enable);
        }
    }

    void tx_datapath_enqueue_timestamp(
        const uint64_t timestamp, const size_t channel = ALL_CHANS) override
    {
        if (channel == ALL_CHANS) {
            for (auto& channel : _channels) {
                tx_datapath_enqueue_timestamp(timestamp, channel);
            }
        } else {
            _assert_channel_param(channel);
            _poke32_channel_reg(channel,
                REG_CHAN_TS_LOW_ADDR,
                (uint32_t)(timestamp & REG_CHAN_TS_LOW_MASK));
            _poke32_channel_reg(channel,
                REG_CHAN_TS_HIGH_ADDR,
                (uint32_t)(timestamp >> 32) & REG_CHAN_TS_HIGH_MASK);
        }
    }

    aurora_channel_stop_policy get_channel_stop_policy(const size_t channel) override
    {
        _assert_channel_param(channel);
        uint32_t ret_value = _peek32_channel_reg(channel, REG_CHAN_STOP_POLICY_ADDR)
                             & REG_CHAN_STOP_POLICY_MASK;
        return (aurora_channel_stop_policy)ret_value;
    }

    std::vector<aurora_channel_stop_policy> get_channel_stop_policy() override
    {
        std::vector<aurora_channel_stop_policy> retval;
        for (auto& channel : _channels) {
            retval.push_back(get_channel_stop_policy(channel));
        }
        return retval;
    }

    void set_channel_stop_policy(
        aurora_channel_stop_policy stop_policy, const size_t channel = ALL_CHANS) override
    {
        if (channel == ALL_CHANS) {
            for (auto& channel : _channels) {
                set_channel_stop_policy(stop_policy, channel);
            }
        } else {
            _assert_channel_param(channel);
            _poke32_channel_reg(
                channel, REG_CHAN_STOP_POLICY_ADDR, (uint32_t)stop_policy);
        }
    }

    uint16_t get_timestamp_queue_fullness(const size_t channel) override
    {
        _assert_channel_param(channel);
        return (uint16_t)((_peek32_channel_reg(channel, REG_CHAN_TS_QUEUE_STS_ADDR)
                              >> REG_TS_FULLNESS_POS)
                          & REG_TS_FULLNESS_MASK);
    }

    std::vector<uint16_t> get_timestamp_queue_fullness() override
    {
        std::vector<uint16_t> retval;
        for (auto& channel : _channels) {
            retval.push_back(get_timestamp_queue_fullness(channel));
        }
        return retval;
    }

    uint16_t get_timestamp_queue_size(const size_t channel) override
    {
        _assert_channel_param(channel);
        return (uint16_t)((_peek32_channel_reg(channel, REG_CHAN_TS_QUEUE_STS_ADDR)
                              >> REG_TS_SIZE_POS)
                          & REG_TS_SIZE_MASK);
    }

    std::vector<uint16_t> get_timestamp_queue_size() override
    {
        std::vector<uint16_t> retval;
        for (auto& channel : _channels) {
            retval.push_back(get_timestamp_queue_size(channel));
        }
        return retval;
    }

    size_t get_num_cores() override
    {
        return _num_cores;
    }

    size_t get_num_channels() override
    {
        return _num_channels;
    }

    std::vector<size_t> get_channels() override
    {
        return _channels;
    }

    void reset_tx() override
    {
        regs().poke32(REG_CORE_RESET_ADDR, uint32_t(1 << REG_TX_DATAPATH_RESET_POS));
    }

    void reset() override
    {
        _reset();
    }

    std::optional<uhd::rx_metadata_t> get_rx_async_metadata(
        const double timeout = 0.1) override
    {
        uhd::rx_metadata_t metadata;
        if (_rx_msg_queue.pop_with_timed_wait(metadata, timeout)) {
            return metadata;
        } else {
            return std::nullopt;
        }
    }

    std::optional<uhd::async_metadata_t> get_tx_async_metadata(
        const double timeout = 0.1) override
    {
        uhd::async_metadata_t metadata;
        if (_tx_msg_queue.pop_with_timed_wait(metadata, timeout)) {
            return metadata;
        } else {
            return std::nullopt;
        }
    }

private:
    void _reset()
    {
        regs().poke32(REG_CORE_RESET_ADDR,
            uint32_t((1 << REG_AURORA_RESET_POS) | (1 << REG_TX_DATAPATH_RESET_POS)
                     | (1 << REG_RX_DATAPATH_RESET_POS)));
        for (auto& channel : _channels) {
            _poke32_channel_reg(channel, REG_CHAN_TS_QUEUE_CTRL_ADDR, uint32_t(1));
        }
    }

    void _poke32_channel_reg(size_t channel, uint32_t addr, uint32_t data)
    {
        regs().poke32(addr + ((channel + 1) * channel_reg_size), data);
    }

    uint32_t _peek32_channel_reg(size_t channel, uint32_t addr)
    {
        return regs().peek32(addr + ((channel + 1) * channel_reg_size));
    }

    void _tx_datapath_enable(const size_t channel, bool enable)
    {
        if (enable) {
            RFNOC_LOG_DEBUG("[Channel " << channel << "] Starting TX datapath");
            _poke32_channel_reg(
                channel, REG_CHAN_TX_CTRL_ADDR, 1 << REG_CHAN_TX_START_POS);
        } else {
            RFNOC_LOG_DEBUG("[Channel " << channel << "] Stopping TX datapath");
            _poke32_channel_reg(
                channel, REG_CHAN_TX_CTRL_ADDR, 1 << REG_CHAN_TX_STOP_POS);
        }
    }

    void _handle_rx_event_action(
        const res_source_info& src, rx_event_action_info::sptr rx_event_action)
    {
        UHD_ASSERT_THROW(src.type == res_source_info::INPUT_EDGE);
        uhd::rx_metadata_t rx_md{};
        rx_md.error_code = rx_event_action->error_code;
        RFNOC_LOG_DEBUG("Received RX error on channel " << src.instance << ", error code "
                                                        << rx_md.strerror());
        _rx_msg_queue.push_with_pop_on_full(rx_md);
    }

    void _handle_tx_event_action(
        const res_source_info& src, tx_event_action_info::sptr tx_event_action)
    {
        UHD_ASSERT_THROW(src.type == res_source_info::OUTPUT_EDGE);

        uhd::async_metadata_t md;
        md.event_code    = tx_event_action->event_code;
        md.channel       = src.instance;
        md.has_time_spec = tx_event_action->has_tsf;

        if (md.has_time_spec) {
            md.time_spec =
                uhd::time_spec_t::from_ticks(tx_event_action->tsf, get_tick_rate());
        }
        RFNOC_LOG_DEBUG("Received TX event on channel " << src.instance << ", event code "
                                                        << md.strevent());
        _tx_msg_queue.push_with_pop_on_full(md);
    }

    /**************************************************************************
     * Initialization
     *************************************************************************/
    void _register_properties()
    {
        register_property(&_num_cores_property);
        add_property_resolver({&_num_cores_property}, {&_num_cores_property}, [this]() {
            RFNOC_LOG_TRACE("Calling resolver for '" << PROP_KEY_NUM_CORES << "'");
            this->_num_cores_property.set(get_num_cores());
        });
        register_property(&_num_channels_property);
        add_property_resolver(
            {&_num_channels_property}, {&_num_channels_property}, [this]() {
                RFNOC_LOG_TRACE("Calling resolver for '" << PROP_KEY_NUM_CHANNELS << "'");
                this->_num_channels_property.set(get_num_channels());
            });
        register_property(&_fc_pause_count_property, [this]() {
            uint8_t pause_count = this->_fc_pause_count_property.get();
            RFNOC_LOG_TRACE("Calling resolver for '" << PROP_KEY_FC_PAUSE_COUNT << "'");
            set_fc_pause_count(pause_count);
        });
        register_property(&_fc_pause_threshold_property, [this]() {
            uint16_t pause_threshold = this->_fc_pause_threshold_property.get();
            RFNOC_LOG_TRACE(
                "Calling resolver for '" << PROP_KEY_FC_PAUSE_THRESHOLD << "'");
            set_fc_pause_threshold(pause_threshold);
        });
        register_property(&_fc_resume_threshold_property, [this]() {
            uint16_t resume_threshold = this->_fc_resume_threshold_property.get();
            RFNOC_LOG_TRACE(
                "Calling resolver for '" << PROP_KEY_FC_RESUME_THRESHOLD << "'");
            set_fc_resume_threshold(resume_threshold);
        });
        register_property(&_rx_packet_counter_property);
        add_property_resolver({&_rx_packet_counter_property, &ALWAYS_DIRTY},
            {&_rx_packet_counter_property},
            [this]() {
                RFNOC_LOG_TRACE(
                    "Calling resolver for '" << PROP_KEY_RX_PACKET_COUNTER << "'");
                RFNOC_LOG_TRACE(
                    "Current value: " << this->_rx_packet_counter_property.get(););
                this->_rx_packet_counter_property.set(get_aurora_rx_packet_counter());
            });
        register_property(&_tx_packet_counter_property);
        add_property_resolver({&_tx_packet_counter_property, &ALWAYS_DIRTY},
            {&_tx_packet_counter_property},
            [this]() {
                RFNOC_LOG_TRACE(
                    "Calling resolver for '" << PROP_KEY_TX_PACKET_COUNTER << "'");
                RFNOC_LOG_TRACE(
                    "Current value: " << this->_tx_packet_counter_property.get(););
                this->_tx_packet_counter_property.set(get_aurora_tx_packet_counter());
            });
        register_property(&_overflow_counter_property);
        add_property_resolver({&_overflow_counter_property, &ALWAYS_DIRTY},
            {&_overflow_counter_property},
            [this]() {
                RFNOC_LOG_TRACE(
                    "Calling resolver for '" << PROP_KEY_OVERFLOW_COUNTER << "'");
                RFNOC_LOG_TRACE(
                    "Current value: " << this->_overflow_counter_property.get(););
                this->_overflow_counter_property.set(get_aurora_overflow_counter());
            });
        register_property(&_crc_error_counter_property);
        add_property_resolver({&_crc_error_counter_property, &ALWAYS_DIRTY},
            {&_crc_error_counter_property},
            [this]() {
                RFNOC_LOG_TRACE(
                    "Calling resolver for '" << PROP_KEY_CRC_ERROR_COUNTER << "'");
                RFNOC_LOG_TRACE(
                    "Current value: " << this->_crc_error_counter_property.get(););
                this->_crc_error_counter_property.set(get_aurora_crc_error_counter());
            });
    }

    void _register_action_handlers()
    {
        register_action_handler(ACTION_KEY_RX_EVENT,
            [this](const res_source_info& src, action_info::sptr action) {
                rx_event_action_info::sptr rx_event_action =
                    std::dynamic_pointer_cast<rx_event_action_info>(action);
                if (!rx_event_action) {
                    RFNOC_LOG_WARNING("Received invalid RX event action!");
                    return;
                }
                _handle_rx_event_action(src, rx_event_action);
            });
        register_action_handler(ACTION_KEY_TX_EVENT,
            [this](const res_source_info& src, action_info::sptr action) {
                tx_event_action_info::sptr tx_event_action =
                    std::dynamic_pointer_cast<tx_event_action_info>(action);
                if (!tx_event_action) {
                    RFNOC_LOG_WARNING("Received invalid TX event action!");
                    return;
                }
                _handle_tx_event_action(src, tx_event_action);
            });
    }

    /**************************************************************************
     * Attributes
     *************************************************************************/
    //! Block compat number
    const uhd::compat_num32 _fpga_compat;

    // raw values of registers
    const uint32_t _config_reg;

    // interpreted bitfields
    const size_t _num_cores;
    const size_t _num_channels;
    std::vector<size_t> _channels;

    // properties
    property_t<size_t> _num_cores_property =
        property_t<size_t>{PROP_KEY_NUM_CORES, _num_cores, {res_source_info::USER}};
    property_t<size_t> _num_channels_property =
        property_t<size_t>{PROP_KEY_NUM_CHANNELS, _num_channels, {res_source_info::USER}};
    property_t<uint8_t> _fc_pause_count_property =
        property_t<uint8_t>{PROP_KEY_FC_PAUSE_COUNT, 100, {res_source_info::USER}};
    property_t<uint16_t> _fc_pause_threshold_property =
        property_t<uint16_t>{PROP_KEY_FC_PAUSE_THRESHOLD, 160, {res_source_info::USER}};
    property_t<uint16_t> _fc_resume_threshold_property =
        property_t<uint16_t>{PROP_KEY_FC_RESUME_THRESHOLD, 200, {res_source_info::USER}};
    property_t<uint32_t> _rx_packet_counter_property =
        property_t<uint32_t>{PROP_KEY_RX_PACKET_COUNTER, 0, {res_source_info::USER}};
    property_t<uint32_t> _tx_packet_counter_property =
        property_t<uint32_t>{PROP_KEY_TX_PACKET_COUNTER, 0, {res_source_info::USER}};
    property_t<uint32_t> _overflow_counter_property =
        property_t<uint32_t>{PROP_KEY_OVERFLOW_COUNTER, 0, {res_source_info::USER}};
    property_t<uint32_t> _crc_error_counter_property =
        property_t<uint32_t>{PROP_KEY_CRC_ERROR_COUNTER, 0, {res_source_info::USER}};

    // Message queues for async data
    uhd::transport::bounded_buffer<uhd::async_metadata_t> _tx_msg_queue{
        ASYNC_MSG_QUEUE_SIZE};
    uhd::transport::bounded_buffer<uhd::rx_metadata_t> _rx_msg_queue{
        ASYNC_MSG_QUEUE_SIZE};
};

UHD_RFNOC_BLOCK_REGISTER_DIRECT(
    aurora_block_control, AURORA_BLOCK, "Aurora", CLOCK_KEY_GRAPH, "bus_clk")
