#!/usr/bin/env python3
#
# Copyright 2025 Ettus Research, a National Instruments Brand
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
"""Aurora RFNoC block demonstration using Python API."""

import argparse
import contextlib
import os
import sys
import time

import numpy as np
import uhd.rfnoc
from rfnoc_oot_blocks import (AuroraBlockControl, channel_stop_policy)
from common import (
    ThreadWithReturnValue,
    rx_streamer_flush,
    write_graph,
)

# Maps the stream_type to the corresponding numpy data type.
CPU_NUMPY_MAPPING = {
    "sc8": np.dtype([("re", np.int8), ("im", np.int8)]),
    "sc16": np.dtype([("re", np.int16), ("im", np.int16)]),
}

BYTES_PER_SAMPLE = {"sc8": 2, "sc16": 4}


def parse_args():
    """Parse the command line arguments."""
    description = """Aurora RFNoC block demonstation using Python API

    The example streams data from and back to the host.

    The FPGA bitfile usrp_x410_X1_200_Aurora100Gbps is required for running the example.
    """
    parser = argparse.ArgumentParser(
        formatter_class=argparse.RawTextHelpFormatter, description=description
    )
    parser.add_argument("--args", metavar="arg", default="", help="Device address args")
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
        "--stream-type",
        default="sc16",
        choices=("sc8", "sc16"),
        help='The streaming data type (default: "sc16").',
    )
    parser.add_argument(
        "--graph",
        metavar="FILENAME",
        help="Write representation of the generated RFNoC graph to a .dot file (or other image formats if graphviz is installed)",
    )
    parser.add_argument(
        "--iterations",
        default=1,
        type=int,
        help="Stream the input file multiple times (as many times as given by this parameter).",
    )
    parser.add_argument(
        "-b",
        "--buffer-size",
        default=10000,
        type=int,
        help="buffer size for single transmit/receive call",
    )
    parser.add_argument(
        "--aurora-block",
        type=str,
        default="0/Aurora#0",
        help="Aurora block to use. Defaults to 0/Aurora#0",
    )
    parser.add_argument(
        "-g",
        "--generate-input",
        choices=["random", "counter"],
        default=None,
        type=str,
        help="Generate the input file",
    )
    parser.add_argument(
        "-i",
        "--input",
        nargs="+",
        type=str,
        required=True,
        help="The input file name(s) to read the data from. If multiple channels are used but only one input file is given, the channel number will be appended. Use the --generate-input flag to create the file automatically.",
    )
    parser.add_argument(
        "-o",
        "--output",
        nargs="+",
        type=str,
        required=True,
        help="The output file(s) to write the received data. The file is used to verify data integrity. If multiple channels are used but only one input file is given, the channel number will be appended.",
    )
    args = parser.parse_args()
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


def tx_function(tx_streamer, tx_buffer, tx_md, timeout, files, iterations=1):
    """The transmit function which streams data from the host to the USRP."""
    num_chans = tx_buffer.shape[0]
    buffer_size = tx_buffer.shape[1]
    num_tx = 0
    iteration = 0
    while iteration < iterations:
        num_tx_iteration = 0
        # print(f"iteration {iteration}")
        for idx in range(num_chans):
            files[idx].seek(0)
        while True:
            for idx in range(num_chans):
                buffer = np.fromfile(files[idx], count=buffer_size, dtype=tx_buffer.dtype)
                if idx == 0:
                    buffer_len_current = len(buffer)
                else:
                    assert len(buffer) == buffer_len_current
                tx_buffer[idx, :buffer_len_current] = buffer
            if buffer_len_current == 0:
                iteration += 1
                break
            num_tx_current = 0
            while num_tx_current < buffer_len_current:
                transmitted = tx_streamer.send(
                    tx_buffer[:, num_tx_current:buffer_len_current], tx_md, timeout
                )
                num_tx_current += transmitted
                num_tx_iteration += transmitted
                num_tx += transmitted
            # print(f" TX {num_tx}")
    return num_tx


def rx_function(rx_streamer, rx_buffer, rx_md, timeout, files, num_samples):
    """The receive function which streams data from the USRP to the host."""
    num_chans = rx_buffer.shape[0]
    num_rx = 0
    reported_overflow = False
    while num_rx < num_samples:
        received = rx_streamer.recv(rx_buffer, rx_md, timeout)
        num_rx += received
        # print(f" RX {num_rx}")
        for idx in range(num_chans):
            rx_buffer[idx, :received].tofile(files[idx])
        if rx_md.error_code == uhd.types.RXMetadataErrorCode.timeout:
            print("RX timeout")
            return num_rx
        if rx_md.error_code == uhd.types.RXMetadataErrorCode.overflow:
            if not reported_overflow:
                error_name = "out-of-sequence" if rx_md.out_of_sequence else rx_md.error_code.name
                print(f"Got an {error_name} indication.")
                reported_overflow = True
        if rx_md.error_code != uhd.types.RXMetadataErrorCode.none:
            print(f"Got an error indication: {rx_md.strerror()}")
            return num_rx
    return num_rx


def compare(reference_file, received_file, num_samples_total, num_iterations, buffer_size, dtype):
    """Compare the content of two files."""
    processed_samples = 0
    iteration = 0
    while processed_samples < num_samples_total:
        reference = np.fromfile(reference_file, count=buffer_size, dtype=dtype)
        if len(reference) == 0:
            if iteration < num_iterations:
                reference_file.seek(0)
                iteration += 1
                continue
            raise EOFError(
                f"Reference file {reference_file.name} reached EOF early, iteration {iteration}, number of processed samples: {processed_samples}"
            )
        received = np.fromfile(received_file, count=buffer_size, dtype=dtype)
        if len(received) == 0:
            raise EOFError(
                f"Received file {received_file.name} reached EOF early, number of processed samples {processed_samples}"
            )
        assert np.array_equal(
            reference, received
        ), f"array mismatch - number of processed samples: {processed_samples}, reference data: {reference}, received data: {received}"
        processed_samples += len(reference)


class ComplexCounterIter:
    """This class provides an iterator which returns a complex number with counter values.

    The real part contains an increasing counter value.
    The imaginary part contains a decreasing counter value.
    """

    def __init__(self, dtype):
        """Initialize an object of this class."""
        self.dtype = dtype
        if str(dtype[0]) == "int8":
            self.real_dtype = np.int8
        elif str(dtype[0]) == "int16":
            self.real_dtype = np.int16
        else:
            raise NotImplementedError()

    def __iter__(self):
        """Initialize the iterator."""
        self.real = self.real_dtype(0)
        self.imag = self.real_dtype(-1)
        return self

    def __next__(self):
        """Iterator: Generate and return the next value."""
        current_real = self.real
        current_imag = self.imag
        self.real += 1
        self.imag -= 1
        return (current_real, current_imag)


class ComplexRandomIter:
    """This class provides in iterator which returns a random complex number."""

    def __init__(self, dtype):
        """Initialize an object of this class."""
        self.complex_dtype = dtype
        self.real_dtype = dtype[0]
        self.min = np.iinfo(self.real_dtype).min
        self.max = np.iinfo(self.real_dtype).max

    def __iter__(self):
        """Intitialize the iterator."""
        self.rng = np.random.default_rng()
        return self

    def __next__(self):
        """Create and return the next value."""
        real = self.rng.integers(self.min, self.max, dtype=self.real_dtype)
        imag = self.rng.integers(self.min, self.max, dtype=self.real_dtype)
        return (real, imag)


def get_filenames(filenames, channels, pattern="{}-chan{}{}"):
    """Get the filenames. Append the channel number in case of multiple channels."""
    num_files_given = len(filenames)
    num_channels = len(channels)
    if num_files_given == num_channels:
        return filenames
    elif num_files_given == 1:
        basename, ext = os.path.splitext(filenames[0])
        return [pattern.format(basename, chan, ext) for chan in channels]
    else:
        raise ValueError(f"Cannot map {num_files_given} files to {num_channels} channels")


def main():
    """The main function."""
    # 1. Parse the command line arguments
    args = parse_args()
    num_chans = len(args.aurora_channels)

    graph = uhd.rfnoc.RfnocGraph(args.args)

    connections = [[] for x in range(num_chans)]

    # Streaming from host:
    # ... instantiate TX Streamer
    tx_sa = uhd.usrp.StreamArgs(args.stream_type, args.stream_type)
    tx_streamer = graph.create_tx_streamer(num_chans, tx_sa)
    for idx in range(num_chans):
        connections[idx].append((tx_streamer, idx))

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
        connections[idx].append((aurora_block.get_unique_id(), chan))

    # Streaming to host: instantiate RX Streamer
    rx_sa = uhd.usrp.StreamArgs(args.stream_type, args.stream_type)
    rx_streamer = graph.create_rx_streamer(num_chans, rx_sa)
    for idx, chan in enumerate(args.aurora_channels):
        # ... add connection
        connections[idx].append((rx_streamer, idx))

    for idx, connection in enumerate(connections):
        print(f"connecting blocks for channel {args.aurora_channels[idx]} (idx={idx})")
        connect_blocks(graph, connection)
    graph.commit()

    # Write a graphical representation of the graph if the argument "graph" was provided
    if args.graph:
        print(f"Writing graphical representation of the RFNoC graph to {args.graph}")
        write_graph(graph, args.graph, None)

    rx_streamer_flush(rx_streamer)

    in_filenames = get_filenames(args.input, args.aurora_channels)
    out_filenames = get_filenames(args.output, args.aurora_channels)

    if args.generate_input is not None:
        num_samples = 1000000
        print("")
        for idx in range(num_chans):
            dtype = CPU_NUMPY_MAPPING[args.stream_type]
            dtype_str = ",".join([str(dtype[i]) for i in range(len(dtype))])
            print(
                f"Creating file {in_filenames[idx]} (mode: {args.generate_input}, num_samples: {num_samples}, dtype: ({dtype_str}))"
            )
            with open(in_filenames[idx], "wb") as in_file:
                iter_mapping = {"counter": ComplexCounterIter, "random": ComplexRandomIter}
                iter0 = iter_mapping[args.generate_input](CPU_NUMPY_MAPPING[args.stream_type])
                in_file.write(
                    np.fromiter(iter0, dtype=CPU_NUMPY_MAPPING[args.stream_type], count=num_samples)
                )

    with contextlib.ExitStack() as stack:
        in_files = []
        out_files = []
        for idx in range(num_chans):
            in_files.append(stack.enter_context(open(in_filenames[idx], "rb")))
            out_files.append(stack.enter_context(open(out_filenames[idx], "wb")))
            num_samples_idx = (
                os.stat(in_files[0].name).st_size // BYTES_PER_SAMPLE[args.stream_type]
            )
            if idx == 0:
                num_samples = num_samples_idx
            else:
                assert (
                    num_samples == num_samples_idx
                ), f"file {in_filenames[idx]} has different size than {in_filenames[0]}"

        # Setup thread for TX streamer
        tx_buffer = np.zeros(
            (num_chans, args.buffer_size), dtype=CPU_NUMPY_MAPPING[args.stream_type]
        )
        tx_md = uhd.types.TXMetadata()
        tx_thread = ThreadWithReturnValue(
            target=tx_function, args=(tx_streamer, tx_buffer, tx_md, 0.1, in_files, args.iterations)
        )

        # Setup thread for RX streamer
        rx_buffer = np.zeros(
            (num_chans, args.buffer_size), dtype=CPU_NUMPY_MAPPING[args.stream_type]
        )
        rx_md = uhd.types.RXMetadata()
        rx_thread = ThreadWithReturnValue(
            target=rx_function,
            args=(rx_streamer, rx_buffer, rx_md, 0.1, out_files, num_samples * args.iterations),
        )

        print("\nStarting streaming")
        rx_thread.start()
        tx_thread.start()
        num_tx = tx_thread.join()
        num_rx = rx_thread.join()
        print("Stopped streaming")
        assert num_tx is not None
        assert num_rx is not None

        print(f"\nNumber of transmitted samples: {num_tx} ({hex(num_tx)})")
        print(f"Number of received samples   : {num_rx} ({hex(num_rx)})")

    errors = []

    # 8. Check the Aurora block statistics
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
    if aurora_tx_counter > aurora_rx_counter:
        errors.append(f"{aurora_tx_counter - aurora_rx_counter} Packets got lost on Aurora link")
    if aurora_overflow_counter > 0:
        errors.append(f"Aurora block reported {aurora_overflow_counter} overflows")
    if aurora_crc_errors > 0:
        errors.append(f"Aurora block reported {aurora_crc_errors} CRC errors")

    # 9. Verify the data integrity of the received data
    print("")
    for idx, chan in enumerate(args.aurora_channels):
        print(f"Verify data for channel {chan}... ", end="")
        with contextlib.ExitStack() as stack:
            in_file = stack.enter_context(open(in_filenames[idx], "rb"))
            out_file = stack.enter_context(open(out_filenames[idx], "rb"))
            try:
                compare(
                    in_file,
                    out_file,
                    num_rx,
                    num_iterations=args.iterations,
                    buffer_size=args.buffer_size,
                    dtype=CPU_NUMPY_MAPPING[args.stream_type],
                )
                print("OK")
            except AssertionError as error:
                errors.append(str(error))

    if len(errors) > 0:
        print("")
        for error in errors:
            print(f"ERROR: {error}")
        sys.exit(1)

    print("\nPASS")


if __name__ == "__main__":
    main()
