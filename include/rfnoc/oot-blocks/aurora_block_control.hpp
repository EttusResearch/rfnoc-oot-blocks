//
// Copyright 2025 Ettus Research, a National Instruments Brand
//
// SPDX-License-Identifier: GPL-3.0-or-later
//

#pragma once

#include <uhd/types/metadata.hpp>
#include <optional>
#include <uhd/rfnoc/defaults.hpp>
#include <uhd/rfnoc/noc_block_base.hpp>
#include <rfnoc/oot-blocks/config.hpp>

namespace rfnoc::oot_blocks {

// doxygen tables need long long lines
// clang-format off
/*! Aurora Block Controller
 *
 * \ingroup rfnoc_blocks
 *
 * The Aurora block can send data to or receive data from an external (FPGA)
 * device connected via Aurora.
 * 
 * The number of channels supported by the Aurora block is dependent on the FPGA
 * configuration used during synthesis. It can be queried by 
 * 
 * get_num_channels();
 *
 * \section rfnoc_block_aurora_datapath TX/RX Datapath Definition
 *  
 * The chain from another RFNoC block (e.g. Radio) to the Aurora block and then to
 * an external device via the Aurora link is called "RX datapath".
 * 
 * The chain from an external device via the Aurora link, to the Aurora block and then
 * to another RFNoC block (e.g. Radio) is called "TX datapath". Note that the TX
 * datapath must be enabled before data packets are forwarded to the connected RFNoC block:
 * 
 * tx_datapath_enable(true);
 * 
 * It is also possible to enable a certain channel only (restrictions apply, see warning below):
 * 
 * tx_datapath_enable(true, channel);
 * 
 * In case the TX datapath is not enabled but data is being received through the Aurora
 * link, the "channel stop policy" determines whether the received data is dropped
 * (aurora_channel_stop_policy::DROP, default) or if it is stored in a FIFO
 * (aurora_channel_stop_policy::BUFFER). The channel stop policy is set as follows:
 * 
 * set_channel_stop_policy(stop_policy);
 * 
 * \warning When only enabling a subset of the available channels, the user must
 * ensure that either the channel_stop policy is set to aurora_channel_stop_policy::DROP
 * or that only packets addressed to the enabled channels are sent through the
 * Aurora link.
 * See Aurora Block Manual for more details.
 *
 * \section rfnoc_block_aurora_nfc Native Flow Control (NFC)
 * 
 * The Aurora block supports the Aurora native flow control (NFC) interface,
 * defined in the Aurora specification, to provide backpressure through the
 * Aurora link. The supported flow control mode is
 * "Immediate Native Flow Control". The configuration parameters for the
 * NFC feature can be set via the following methods:
 * 
 * - set_fc_pause_count()
 * - set_fc_pause_threshold()
 * - set_fc_resume_threshold()
 * 
 * For detail on the NFC feature and how to use it, please refer to the
 * Aurora block manual.
 * 
 * \section rfnoc_block_aurora_actions Action Handling
 *
 * If this block receives TX or RX actions (uhd::rfnoc::tx_event_action_info or
 * uhd::rfnoc::rx_event_action_info), it will store them in a circular buffer.
 * The API call get_async_metadata() can be used to read them back out
 * asynchronously. To avoid the block controller continously expanding in memory,
 * the total number of messages that will be stored is limited. If this block receives
 * more event info objects than it can store before get_async_metadata() is called,
 * the oldest message will be dropped.
 */
// clang-format on

enum class aurora_channel_stop_policy {
    /*!< The enumeration defines what happens to samples that are fed
    into the TX data chain while the datapath is stopped.*/
    DROP, /*!< Drop all packets from Aurora until we start. */
    BUFFER /*!< Packets are held back until we start. */
};

// Custom property keys
static const std::string PROP_KEY_NUM_CORES           = "num_cores";
static const std::string PROP_KEY_NUM_CHANNELS        = "num_channels";
static const std::string PROP_KEY_FC_PAUSE_COUNT      = "fc_pause_count";
static const std::string PROP_KEY_FC_PAUSE_THRESHOLD  = "fc_pause_threshold";
static const std::string PROP_KEY_FC_RESUME_THRESHOLD = "fc_resume_threshold";
static const std::string PROP_KEY_RX_PACKET_COUNTER   = "rx_packet_counter";
static const std::string PROP_KEY_TX_PACKET_COUNTER   = "tx_packet_counter";
static const std::string PROP_KEY_OVERFLOW_COUNTER    = "overflow_counter";
static const std::string PROP_KEY_CRC_ERROR_COUNTER   = "crc_error_counter";

/*! Aurora Control Class
 *
 * \ingroup rfnoc_blocks
 *
 * The Aurora Block provides a direct interface to the RFNoC Image Core via the
 * Aurora transmission protocol. It allows for sending and receiving data
 * from USRP or non-USRP devices that support the Aurora protocol.
 * The block controller provides methods to control the Aurora link, query its
 * status, and manage the flow of data through the Aurora link and to the RFNoC
 * image core.
 * See the RFNoC Aurora Block Manual for more details on how to configure and use
 * the Aurora block.
 */
class RFNOC_OOT_BLOCKS_API aurora_block_control : public uhd::rfnoc::noc_block_base
{
public:
    static constexpr size_t ALL_CHANS = size_t(~0);
    RFNOC_DECLARE_BLOCK(aurora_block_control)

    // See aurora_regs_pkg.sv for register offsets and descriptions
    static const uint32_t REG_COMPAT_ADDR;
    static const uint32_t REG_CORE_CONFIG_ADDR;
    static const uint32_t REG_NUM_CORES_POS;
    static const uint32_t REG_NUM_CORES_MASK;
    static const uint32_t REG_NUM_CHAN_POS;
    static const uint32_t REG_NUM_CHAN_MASK;
    static const uint32_t REG_CORE_STATUS_ADDR;
    static const uint32_t REG_LANE_STATUS_POS;
    static const uint32_t REG_LANE_STATUS_MASK;
    static const uint32_t REG_LANE_STATUS_LEN;
    static const uint32_t REG_LINK_STATUS_POS;
    static const uint32_t REG_HARD_ERR_POS;
    static const uint32_t REG_SOFT_ERR_POS;
    static const uint32_t REG_MMCM_LOCK_POS;
    static const uint32_t REG_PLL_LOCK_POS;
    static const uint32_t REG_CORE_RESET_ADDR;
    static const uint32_t REG_AURORA_RESET_POS;
    static const uint32_t REG_TX_DATAPATH_RESET_POS;
    static const uint32_t REG_RX_DATAPATH_RESET_POS;
    static const uint32_t REG_CORE_FC_PAUSE_ADDR;
    static const uint32_t REG_PAUSE_COUNT_POS;
    static const uint32_t REG_PAUSE_COUNT_MASK;
    static const uint32_t REG_CORE_FC_THRESHOLD_ADDR;
    static const uint32_t REG_PAUSE_THRESH_POS;
    static const uint32_t REG_PAUSE_THRESH_MASK;
    static const uint32_t REG_RESUME_THRESH_POS;
    static const uint32_t REG_RESUME_THRESH_MASK;
    static const uint32_t REG_CORE_TX_PKT_CTR_ADDR;
    static const uint32_t REG_CORE_RX_PKT_CTR_ADDR;
    static const uint32_t REG_CORE_OVERFLOW_CTR_ADDR;
    static const uint32_t REG_CORE_CRC_ERR_CTR_ADDR;
    static const uint32_t REG_CHAN_TX_CTRL_ADDR;
    static const uint32_t REG_CHAN_TX_CTRL_MASK;
    static const uint32_t REG_CHAN_TX_STOP_POS;
    static const uint32_t REG_CHAN_TX_START_POS;
    static const uint32_t REG_CHAN_TS_LOW_ADDR;
    static const uint32_t REG_CHAN_TS_LOW_MASK;
    static const uint32_t REG_CHAN_TS_HIGH_ADDR;
    static const uint32_t REG_CHAN_TS_HIGH_MASK;
    static const uint32_t REG_CHAN_STOP_POLICY_ADDR;
    static const uint32_t REG_CHAN_STOP_POLICY_MASK;
    static const uint32_t REG_CHAN_TS_QUEUE_STS_ADDR;
    static const uint32_t REG_CHAN_TS_QUEUE_STS_MASK;
    static const uint32_t REG_CHAN_TS_QUEUE_CTRL_ADDR;
    static const uint32_t REG_CHAN_TS_QUEUE_CTRL_MASK;
    static const uint32_t REG_TS_FULLNESS_POS;
    static const uint32_t REG_TS_FULLNESS_MASK;
    static const uint32_t REG_TS_SIZE_POS;
    static const uint32_t REG_TS_SIZE_MASK;

    static const uint32_t channel_reg_size;
    static const uint32_t core_reg_size;

    struct status_struct
    {
        std::vector<bool> lane_status;
        bool link_status;
        bool aurora_hard_error_status;
        bool aurora_soft_error_status;
        bool aurora_mmcm_lock_status;
        bool aurora_gt_pll_lock_status;
    };

    /*! Query the aurora core status (all status parameters)
     *
     * \returns General core status
     */
    virtual status_struct get_status() = 0;

    /*! Query the aurora core status (only the link statuas)
     *
     * \returns Aurora link status
     */
    virtual bool get_link_status() = 0;

    /*! Query the aurora core status (only the lane status)
     *
     * \param channel The channel to query
     *
     * \returns Aurora lane status
     */
    virtual bool get_lane_status(const size_t channel) = 0;


    /*! Query the aurora core status (only the lane status)
     *
     * \returns Aurora link status
     */
    virtual std::vector<bool> get_lane_status() = 0;

    /*! Gets the Aurora native flow control (NFC) parameter pause count.
     *
     * This is the pause count to provide to the NFC interface when flow
     * control is triggered.
     *
     * \returns pause count in number of cycles
     */
    virtual uint8_t get_fc_pause_count() = 0;

    /*! Sets the Aurora native flow control (NFC) parameter pause count.
     *
     * This is the pause count to provide to the NFC interface when flow
     * control is triggered.
     *
     * \param pause_count pause count in number of cycles
     */
    virtual void set_fc_pause_count(uint8_t pause_count) = 0;

    /*! Gets the Aurora native flow control (NFC) parameter pause threshold.
     *
     * We send the XOFF message when the number of
     * clock cycles of remaining buffer falls below this number.
     *
     * \returns pause threshold in number of Aurora data words
     */
    virtual uint8_t get_fc_pause_threshold() = 0;

    /*! Sets the Aurora native flow control (NFC) parameter pause threshold.
     *
     * We send the XOFF message when the number of
     * clock cycles of remaining buffer falls below this number.
     *
     * \param pause_threshold pause threshold in number of Aurora data words
     */
    virtual void set_fc_pause_threshold(uint8_t pause_threshold) = 0;

    /*! Gets the Aurora native flow control (NFC) parameter resume threshold.
     *
     * We send the XON message when the number of
     * clock cycles of remaining buffer falls below this number.
     *
     * \returns resume threshold in number of Aurora data words
     */
    virtual uint8_t get_fc_resume_threshold() = 0;

    /*! Sets the Aurora native flow control (NFC) parameter resume threshold.
     *
     * We send the XON message when the number of
     * clock cycles of remaining buffer falls below this number.
     *
     * \param resume_threshold resume threshold in number of Aurora data words
     */
    virtual void set_fc_resume_threshold(uint8_t resume_threshold) = 0;

    /*! Gets the number of Aurora packets received
     *
     * \returns Number of Aurora packets received (Aurora to RFNoC)
     */
    virtual uint32_t get_aurora_rx_packet_counter() = 0;

    /*! Gets the number of Aurora packets transmitted
     *
     * \returns Number of Aurora packets transmitted (RFNoC to Aurora)
     */
    virtual uint32_t get_aurora_tx_packet_counter() = 0;

    /*! Gets the number of Aurora data words received from the Aurora link that were
     * dropped because there was not sufficient room in the buffer to receive
     * them. With flow control enabled, the value should always be 0.
     *
     * \returns number of Aurora data words received from the Aurora link that were
     * dropped
     */
    virtual uint32_t get_aurora_overflow_counter() = 0;

    /*! Gets the number of CRC errors detected by the Aurora IP, which is
     * also the number of Aurora packets dropped due to CRC errors.
     *
     * \returns number of Aurora packets dropped due to CRC errors
     */
    virtual uint32_t get_aurora_crc_error_counter() = 0;

    /*! Controls the start and stop of the "TX" datapath (i.e., the path from
     * the Aurora link to RFNoC).
     *
     * \param enable Enable (true) or disable (false) the TX data path for the
     * given channel.
     * \param channel The number of the channel to enable/disable.
     * Defaults to all channels if parameter is omitted
     */
    virtual void tx_datapath_enable(
        const bool enable, const size_t channel = ALL_CHANS) = 0;

    /*! Sets the next TX timestamp to be used for the next start of the
     * transmission. Timestamp is applied for the given channel.
     *
     * \param timestamp The timestamp to use.
     * \param channel The number of the channel to set the TX start timestamp.
     * Defaults to all channels if parameter is omitted
     */
    virtual void tx_datapath_enqueue_timestamp(
        const uint64_t timestamp, const size_t channel = ALL_CHANS) = 0;

    /*! Gets the behavior of the TX datapath for a given channel. See the
     * aurora_channel_stop_policy enum for details.
     *
     * \param channel The number of the channel to query the channel stop policy.
     * \returns The channel stop policy.
     */
    virtual aurora_channel_stop_policy get_channel_stop_policy(const size_t channel) = 0;

    /*! Gets the behavior of the TX datapath for all channels. See the
     * aurora_channel_stop_policy enum for details.
     *
     * \param channel The number of the channel to query the channel stop policy.
     * \returns Vector of channel stop policies
     */
    virtual std::vector<aurora_channel_stop_policy> get_channel_stop_policy() = 0;

    /*! Sets the behavior of the TX datapath for a given channel. See the
     * aurora_channel_stop_policy enum for details.
     *
     * \param stop_policy The channel stop policies
     * \param channel The number of the channel to set the channel stop policy.
     * Defaults to all channels if parameter is omitted
     */
    virtual void set_channel_stop_policy(
        aurora_channel_stop_policy stop_policy, const size_t channel = ALL_CHANS) = 0;

    /*! Gets the status of the timestamp queue for a given channel.
     *
     * \param channel The number of the channel to query the status.
     * \returns The number of timestamp entries in the queue.
     */
    virtual uint16_t get_timestamp_queue_fullness(const size_t channel) = 0;

    /*! Gets the status of the timestamp queue for all channels.
     *
     * \returns Vector of the number of timestamp entries in the queue.
     */
    virtual std::vector<uint16_t> get_timestamp_queue_fullness() = 0;

    /*! Gets the size of the timestamp queue for a certain channel.
     *
     * \param channel The number of the channel to query the status.
     * \returns The timestamp queue size of the given channel.
     */
    virtual uint16_t get_timestamp_queue_size(const size_t channel) = 0;

    /*! Gets the size of the timestamp queue for all channels.
     *
     * \returns Vector of timestamp queue sizes for all channels.
     */
    virtual std::vector<uint16_t> get_timestamp_queue_size() = 0;

    /*! Gets the number of aurora cores in the FPGA.
     *
     * \returns Number of aurora cores.
     */
    virtual size_t get_num_cores() = 0;

    /*! Gets the number of channels per aurora core.
     *
     * \returns Number of channels.
     */
    virtual size_t get_num_channels() = 0;

    /*! Gets a vector containing all channel indices. This is useful when you
     * want to iterate over all channels.
     *
     * \returns Vector of channel indices.
     */
    virtual std::vector<size_t> get_channels() = 0;

    /*! Resets the TX datapath only, including the transmit control logic. */
    virtual void reset_tx() = 0;

    /*! Resets the Aurora IP, the TX datapath, and the RX datapath. */
    virtual void reset() = 0;

    /*! Return RX-related (other RFNoC block -> Aurora) metadata.
     *
     * The typical use case for this is when connecting Radio -> Aurora for
     * data transmission, the radio may produce information like 'overrun occurred'.
     * When streaming to a host using a uhd::rx_streamer, this information is
     * returned as part of the uhd::rx_streamer::recv() call, but when the data
     * is streamed into the aurora block, these metadata are stored inside the
     * aurora block until queried by this method.
     *
     * \param timeout A timeout (in seconds) to wait before returning.
     * \returns A metadata object if the metadata could be read.
     */
    virtual std::optional<uhd::rx_metadata_t> get_rx_async_metadata(
        const double timeout = 0.1) = 0;

    /*! Return TX-related (Aurora -> other RFNoC block) metadata.
     *
     * The typical use case for this is when connecting Aurora -> Radio for
     * data transmission, the radio may produce information like 'underrun occurred'.
     * When transmitting from a host using a uhd::tx_streamer, this information
     * is returned as part of the uhd::tx_streamer::recv_async_msg() call, but
     * when the data is streamed into the aurora block, these metadata are
     * stored inside the aurora block until queried by this method.
     *
     * \param timeout A timeout (in seconds) to wait before returning.
     * \returns A metadata object if the metadata could be read.
     */
    virtual std::optional<uhd::async_metadata_t> get_tx_async_metadata(
        const double timeout = 0.1) = 0;
};

// block identifiers
static const uhd::rfnoc::noc_id_t AURORA_BLOCK         = 0xA404A000;

} // namespace rfnoc::oot_blocks
