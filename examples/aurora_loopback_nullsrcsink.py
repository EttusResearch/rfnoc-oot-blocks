#!/usr/bin/env python3
#
# Copyright 2025 Ettus Research, a National Instruments Brand
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
"""Aurora RFNoC block demonstration using Python API."""

import argparse
import logging
import sys
import time

import numpy as np
import uhd.rfnoc
from rfnoc_oot_blocks import (AuroraBlockControl, channel_stop_policy)
from common import (
    NullSrcSinkReferenceData,
    ThreadWithReturnValue,
    rx_streamer_flush,
    write_graph,
)
from uhd.libpyuhd.rfnoc import LINES, PACKETS, SINK, SOURCE


def parse_args():
    """Parse the command line arguments."""
    description = """Aurora RFNoC block demonstation using Python API

    The following data sinks ("--sink" argument) are available:

    "fpga" (default): Generate data on the FPGA, feed it through the Aurora link
    (QSFP loopback adapter required) and evaluate the data on the FPGA.
    +-----------------+       +--------------+
    | 0/NullSrcSink#0 | ----> |  0/AURORA#0  |
    |                 | <---- |              |
    +-----------------+       +--------------+
    
    "host": Generate data on the FPGA, feed it through the Aurora link
    (QSFP loopback adapter requied) and stream the data to the host.
    +-----------------+       +--------------+       +----------------+
    | 0/NullSrcSink#0 | ----> |  0/AURORA#0  | ----> |  RxStreamer#0  |
    +-----------------+       +--------------+       +----------------+
    
    "host" and "--no-aurora" flag present: Generate data on the FPGA and stream it to the host. This mode is useful
    for verifying the streaming to the host independently of the Aurora link.
    +-----------------+       +--------------+
    | 0/NullSrcSink#0 | ----> | RxStreamer#0 |
    +-----------------+       +--------------+

    The FPGA bitfile usrp_x410_X1_200_Aurora100Gbps is required for running the example.
    """
    parser = argparse.ArgumentParser(
        formatter_class=argparse.RawTextHelpFormatter, description=description
    )
    parser.add_argument("--args", metavar="arg", default="", help="Device address args")
    parser.add_argument(
        "--sink",
        default="fpga",
        choices=["host", "fpga"],
        help='The sink to use. "host": stream data to the host and verify it. "fpga": Use NullSrcSink block on the FPGA to count packets and discard the data',
    )
    parser.add_argument(
        "--no-aurora",
        default=False,
        action="store_true",
        help="Don't use stream over Aurora loopback (default: False). This is useful for verifying streaming to and from the host independent of the Aurora link."
        " This flag can only be used together with --sink=host.",
    )
    parser.add_argument(
        "--bytes-per-packet",
        default=1024,
        type=int,
        help="Bytes per packet parameter of the Null source (default: 1024)",
    )
    parser.add_argument(
        "--throttle-cycles",
        default=1,
        type=int,
        help="Throttle cycles parameter of the Null source (default: 1)",
    )
    parser.add_argument(
        "-c",
        "--aurora-channels",
        default=[0],
        nargs="+",
        type=int,
        help='specifies the channel(s) to use (specify "0", "1", "0 1", etc) [default = 0].',
    )
    parser.add_argument(
        "--aurora-nfc",
        default=[100, 160, 200],
        metavar=("PAUSE_COUNT", "PAUSE_THRESHOLD", "RESUME_THRESHOLD"),
        nargs=3,
        type=int,
        help="The Aurora native flow control (NFC) settings. Tweak these parameters in case the Aurora block reports overflows. (default: 100 160 200)",
    )
    parser.add_argument(
        "--graph",
        metavar="FILENAME",
        help="Write representation of the generated RFNoC graph to a .dot file (or other image formats if graphviz is installed)",
    )
    parser.add_argument(
        "--duration",
        default=1.0,
        type=float,
        help="The duration of the data transmission (default: 1.0)",
    )
    parser.add_argument(
        "--aurora-block",
        type=str,
        default="0/Aurora#0",
        help="Aurora block to use. Defaults to 0/Aurora#0",
    )
    args = parser.parse_args()
    if args.sink == "fpga" and args.no_aurora:
        parser.print_usage()
        print("\nError: the --no-aurora flag can only be used together with --sink=host.")
        sys.exit(2)
    args.num_chans = len(args.aurora_channels)
    return args


def wait_for_link_up(aurora_block, timeout=3.0):
    """Wait for the Aurora block to report link up."""
    start_time = time.time()
    dt = 0
    while dt < timeout:
        if aurora_block.get_link_status() is True:
            return True, dt
        time.sleep(0.1)
        dt = time.time() - start_time
    return False, timeout


def generate_data(null_blocks, duration):
    """Activate streaming on null block for the given duration to generate some data."""
    for null_block in null_blocks:
        null_block.issue_stream_cmd(uhd.types.StreamCMD(uhd.types.StreamMode.start_cont))
    time.sleep(duration)
    for null_block in null_blocks:
        null_block.issue_stream_cmd(uhd.types.StreamCMD(uhd.types.StreamMode.stop_cont))


def rx_streamer_flush(rx_streamer):
    """Flush the RX streamer.

    Repeatedly call .recv until no data is received within the given timeout.
    """
    rx_md = uhd.types.RXMetadata()
    rx_data = np.zeros((rx_streamer.get_num_channels(), 10000000), dtype=np.uint32)
    num_rx_total = 0
    num_rx = None
    while num_rx != 0:
        num_rx = rx_streamer.recv(rx_data, rx_md, 0.1)
        num_rx_total += num_rx
    if num_rx_total > 0:
        print(f"Flushed {num_rx_total} samples from RX streamer")


def generate_data_and_stream_to_host(
    null_blocks, rx_streamer, rx_data, duration, rx_md=uhd.types.RXMetadata()
):
    """Generate data on the FPGA using the Null block and stream the data to the host."""
    rx_thread = ThreadWithReturnValue(
        target=rx_streamer.recv, args=(rx_data, rx_md, duration + 0.1)
    )
    rx_thread.start()
    rx_streamer_flush(rx_streamer)
    generate_data(null_blocks, duration)
    num_rx = rx_thread.join()
    rx_streamer_flush(rx_streamer)
    return num_rx


def connect_blocks(graph, connections, is_back_edge=False):
    """Connect RFNoC Blocks.

    Args:
        graph: the RFNoC graph
        connections: array of tuples (block, port) where the connection is established
            from the first to the second entry, then from the second to the third
            and so on
        is_back_edge: Set this flag to true if the graph is a circular graph
    """
    src = connections[:-1]  # elements 0..N-1
    dst = connections[1:]  # elements 1..N
    for (src_blk, src_port), (dst_blk, dst_port) in zip(src, dst):
        graph.connect(src_blk, src_port, dst_blk, dst_port, is_back_edge)


def print_null_statistics(null_block, port_type=SOURCE, header_append=""):
    """Print the statistics (packets, lines) of the NullSrcSink block."""
    num_lines = null_block.get_count(port_type, LINES)
    num_packets = null_block.get_count(port_type, PACKETS)
    port_type = "source" if port_type == SOURCE else "sink"
    header = f"Null {port_type} statistics" + header_append
    print("\n" + header + "\n" + "=" * len(header))
    print(f"# of packets received    : {num_packets}")
    print(f"# of lines received      : {num_lines}")


def main():
    """The main function."""
    # 1. Parse the command line arguments
    args = parse_args()
    graph = uhd.rfnoc.RfnocGraph(args.args)

    null_block_src = []
    null_block_sink = []

    connections = [[] for x in range(args.num_chans)]
    is_back_edge = False

    # 2. Instantiate the NullSrcSink block(s) which are used as data source
    null_blocks = graph.find_blocks("NullSrcSink")
    if len(null_blocks) < args.num_chans:
        raise ValueError(
            f"Requested {args.num_chans} channels but only {len(null_blocks)} NullSrcSink blocks are available. Note that the standard"
            " bitfiles for the X400 series do not include NullSrcSink blocks. You need to compile a custom bitfile with those blocks"
            " included."
        )
    for idx in range(args.num_chans):
        # ... remember that this Null block is used as source
        null_block_src.append(uhd.rfnoc.NullBlockControl(graph.get_block(null_blocks[idx])))
        # ... configure the Null block
        null_block_src[idx].set_bytes_per_packet(args.bytes_per_packet)
        null_block_src[idx].set_throttle_cycles(args.throttle_cycles)
        # ... add connection
        connections[idx].append((null_block_src[idx].get_unique_id(), 0))

    # 3. Instanciate and configure the Aurora block controllers
    if args.no_aurora:
        print("Not streaming over Aurora (--no-aurora flag set)")
        aurora_block = None
    else:
        # Streaming over Aurora
        # ... instantiate the Aurora block
        aurora_block = AuroraBlockControl(graph.get_block(args.aurora_block))
        assert (
            aurora_block.get_num_input_ports() == aurora_block.get_num_output_ports()
        ), "The number of input and output ports of the Aurora block do not match."
        # ... configure the Aurora block
        aurora_block.set_fc_pause_count(args.aurora_nfc[0])
        aurora_block.set_fc_pause_threshold(args.aurora_nfc[1])
        aurora_block.set_fc_resume_threshold(args.aurora_nfc[2])
        aurora_block.set_channel_stop_policy(channel_stop_policy.BUFFER)
        aurora_block.tx_datapath_enable(True)
        # ... wait for link up
        link_up, dt = wait_for_link_up(aurora_block)
        if not link_up:
            print(f"ERROR: Aurora link not up within {dt:0.1f} seconds")
            sys.exit(1)
        print(f"Aurora link up within {dt:0.1f} seconds")
        # ... print information about used channels
        print(
            f"The Aurora block has {aurora_block.get_num_input_ports()} channels, using channel(s) {",".join([str(x) for x in args.aurora_channels])}"
        )
        for idx, chan in enumerate(args.aurora_channels):
            # Add connection
            assert (
                chan < aurora_block.get_num_input_ports()
            ), f"Requested channel {chan} but Aurora block has only {aurora_block.get_num_input_ports()} channels"
            connections[idx].append((aurora_block.get_unique_id(), chan))

    # 4. Create a RX streamer when streaming to host
    if args.sink == "host":
        sa = uhd.usrp.StreamArgs("sc16", "sc16")
        rx_streamer = graph.create_rx_streamer(args.num_chans, sa)
        for idx, _ in enumerate(args.aurora_channels):
            connections[idx].append((rx_streamer, idx))
    else:
        # Use NullSrcSink Block on FPGA as data sink
        null_blocks = graph.find_blocks("NullSrcSink")
        for idx, chan in enumerate(args.aurora_channels):
            # ... remember that this Null block is used as sink
            null_block_sink.append(uhd.rfnoc.NullBlockControl(graph.get_block(null_blocks[idx])))
            # ... configure the Null block
            null_block_sink[idx].set_bytes_per_packet(args.bytes_per_packet)
            null_block_sink[idx].set_throttle_cycles(args.throttle_cycles)
            # ... add connection
            connections[idx].append((null_block_sink[idx].get_unique_id(), 0))
        is_back_edge = True
        rx_streamer = None

    # 5. Connect the blocks
    for idx, connection in enumerate(connections):
        print(f"connecting blocks for channel {args.aurora_channels[idx]}")
        connect_blocks(graph, connection, is_back_edge)
    graph.commit()

    # 6. Write a graphical representation of the graph if the argument "graph" was provided
    if args.graph:
        write_graph(graph, args.graph, logger)

    # 7. Print out the current mode
    sink_description = {
        "fpga": "Generate data on the FPGA, feed it through the Aurora link"
        " (QSFP loopback adapter required) and evaluate the data on the FPGA.",
        "host": "Generate data on the FPGA, feed it through the Aurora link"
        " (QSFP loopback adapter requied) and stream the data to the host.",
    }
    print(f'\nUsing data sink "{args.sink}": {sink_description[args.sink]}')

    # 8. Actually stream the data
    if rx_streamer is not None:
        rx_buffer_size = 10000000
        rx_data = np.zeros((args.num_chans, rx_buffer_size), dtype=np.uint32)
        num_rx = generate_data_and_stream_to_host(
            null_block_src, rx_streamer, rx_data, args.duration
        )
        print(f"Received {num_rx} samples over RX streamer")
        rx_data = rx_data[:, 0:num_rx]
    else:
        generate_data(null_block_src, args.duration)

    # 9. Evaluate the results
    errors = []

    null_src_packets = 0
    null_src_lines = 0
    for chan, null_block in zip(args.aurora_channels, null_block_src):
        print_null_statistics(null_block, SOURCE, f" (channel {chan})")
        if null_block.get_count(SOURCE, PACKETS) == 0:
            errors.append(
                f"Null data source for channel {chan} ({null_block.get_unique_id()}) did not generate any data"
            )
        null_src_packets += null_block.get_count(SOURCE, PACKETS)
        null_src_lines += null_block.get_count(SOURCE, LINES)

    if aurora_block is not None:
        aurora_tx_counter = aurora_block.get_aurora_tx_packet_counter()
        aurora_rx_counter = aurora_block.get_aurora_rx_packet_counter()
        aurora_overflow_counter = aurora_block.get_aurora_overflow_counter()
        aurora_crc_errors = aurora_block.get_aurora_crc_error_counter()
        print("\nAurora statistics")
        print("=================")
        print(f"# of packets transmitted : {aurora_tx_counter}")
        print(f"# of packets received    : {aurora_rx_counter}")
        print(f"# of overflows           : {aurora_overflow_counter}")
        print(f"# of CRC errors          : {aurora_crc_errors}")
        if aurora_tx_counter < null_src_packets:
            errors.append(
                f"{null_src_packets - aurora_tx_counter} packets got lost from Null Source block(s) to Aurora block"
            )
        if aurora_tx_counter > aurora_rx_counter:
            errors.append(
                f"{aurora_tx_counter - aurora_rx_counter} Packets got lost on Aurora link"
            )
        if aurora_overflow_counter > 0:
            errors.append(f"Aurora block reported {aurora_overflow_counter} overflows")
        if aurora_crc_errors > 0:
            errors.append(f"Aurora block reported {aurora_crc_errors} CRC errors")

    if rx_streamer is not None:

        def _print_data(rx_data):
            """Print the received data."""
            for dat in rx_data:
                print(f"0x{dat:08x}")

        def _verify_data(rx_data):
            """Verify the data. The data from the null source block contains counter values.

            The upper 16 bits contain a counter value increasing from 0x0000. The lower 16
            bits contain a counter value decreasing from 0xFFFF. The counter changes for every
            line where the line width is determined by the CHDR width. For a CHDR width of
            64 bits, the counter values for every second U32 are increased, example:

            [0] 0x0000FFFF
            [1] 0x0000FFFF
            [2] 0x0001FFFE
            [3] 0x0001FFFE
            [4] 0x0002FFFD
            [5] 0x0002FFFD
            (...)
            """
            null_ref = iter(NullSrcSinkReferenceData(words_per_line=2))
            for dat in rx_data:
                reference = next(null_ref)
                if dat != reference:
                    return (
                        False,
                        f"mismatch in line {null_ref.line:02d} expected: 0x{reference:08x}, received: 0x{dat:08x}",
                    )
            return True, ""

        rx_data = rx_data[0]
        rx_lines = len(rx_data) // 2
        print("\nReceived data on the host")
        print("=========================")
        print(f"# of U32 words received  : {len(rx_data)}")
        print(f"# of lines received      : {rx_lines}")
        lines_reference = aurora_rx_counter if aurora_block else null_src_lines
        if num_rx == rx_buffer_size:
            pass
        elif rx_lines < lines_reference:
            errors.append(f"{lines_reference - rx_lines} lines got lost when streaming to the host")
        print("\nReceived data:")
        _print_data(rx_data[:4])
        print("...")
        _print_data(rx_data[-4:])
        print("\nValidating received data for continuously increasing counter value...", end="")
        data_ok, message = _verify_data(rx_data)
        if data_ok:
            print("OK")
        else:
            print("MISMATCH")
            errors.append(message)
    else:
        for chan, null_src, null_sink in zip(args.aurora_channels, null_block_src, null_block_sink):
            print_null_statistics(null_sink, SINK, f" (channel {chan})")
            missing_packets = null_src.get_count(SOURCE, PACKETS) - null_sink.get_count(
                SINK, PACKETS
            )
            missing_lines = null_src.get_count(SOURCE, LINES) - null_sink.get_count(SINK, LINES)
            if missing_packets != 0:
                errors.append(
                    f"channel {chan}: {missing_packets} packets got lost from source to sink"
                )
            if missing_lines != 0:
                errors.append(f"channel {chan}: {missing_lines} lines got lost from source to sink")

    if len(errors) > 0:
        print("")
        for error in errors:
            print(f"ERROR: {error}")
        sys.exit(1)

    print("\nPASS")


if __name__ == "__main__":
    global logger
    logger = logging.getLogger(__name__)
    main()
