#!/usr/bin/env python3
#
# Copyright 2025 Ettus Research, a National Instruments Brand
#
# SPDX-License-Identifier: GPL-3.0-or-later
#
"""Common functions for Python API examples."""

import logging
import os.path
import subprocess
import tempfile
from threading import Thread

import numpy as np
import uhd


class ThreadWithReturnValue(Thread):
    """Extension for the Thread class which passes the return value of a thread."""

    def __init__(self, group=None, target=None, name=None, args=(), kwargs={}):
        """Initialize an object of this class."""
        Thread.__init__(self, group, target, name, args, kwargs)
        self._returncode = None

    def run(self):
        """Run the target function in a thread."""
        if self._target is not None:
            self._returncode = self._target(*self._args, **self._kwargs)

    def join(self, *args):
        """Wait until the thread terminates. Returns the returncode of the executed function."""
        Thread.join(self, *args)
        return self._returncode


def write_graph(graph, filename: str, logger: logging.Logger):
    """Write a RFNoC graph to a .dot file (or other image formats if graphviz is installed)."""
    _, ext = os.path.splitext(filename)
    if ext == ".dot":
        with open(filename, "w") as f:
            f.write(graph.to_dot())
    else:
        with tempfile.NamedTemporaryFile("w") as f:
            f.write(graph.to_dot())
            f.seek(0)
            try:
                proc = subprocess.run(
                    ["dot", "-T", ext[1:], "-o", filename, f.name], capture_output=True
                )
                if (proc.returncode != 0) and logger is not None:
                    logger.warning(
                        f'WARNING: Could not write graph to file {filename}, executable "dot" returned return code {proc.returncode} - {proc.stderr.decode()}'
                    )
            except FileNotFoundError:
                logger.warning(
                    f'WARNING: Could not write graph to file {filename}, executable "dot" was not found'
                )


class NullSrcSinkReferenceData:
    """This class provides the reference data of a NullSrcSink RFNoC block."""

    def __init__(self, words_per_line):
        """Initialize an object of this class."""
        self.mask = words_per_line - 1

    def __iter__(self):
        """Initialize the iterator."""
        self.iteration = 0
        self.line = 0
        self.hi = np.uint32(0x00000000)
        self.lo = np.uint32(0x0000FFFF)
        return self

    def __next__(self):
        """Iterator: Generate and return the value of the next line."""
        retval = self.hi | self.lo
        if (self.iteration & self.mask) == self.mask:  # line change -> increase the counter value
            self.line += 1
            # upper 16 bits: counter increasing from 0x0000
            self.hi += 0x00010000
            self.hi &= 0xFFFF0000
            # lower 16 bits: counter decreasing from 0xFFFF
            self.lo -= 0x00000001
            self.lo &= 0x0000FFFF
        self.iteration += 1
        return retval


class Counter:
    """This class provides the reference data of a NullSrcSink RFNoC block."""

    def __init__(self, dtype):
        """Initialize an object of this class."""
        self.mask = words_per_line - 1

    def __iter__(self):
        """Initialize the iterator."""
        self.iteration = 0
        self.line = 0
        self.hi = np.uint32(0x00000000)
        self.lo = np.uint32(0x0000FFFF)
        return self

    def __next__(self):
        """Iterator: Generate and return the value of the next line."""
        retval = self.hi | self.lo
        if (self.iteration & self.mask) == self.mask:  # line change -> increase the counter value
            self.line += 1
            # upper 16 bits: counter increasing from 0x0000
            self.hi += 0x00010000
            self.hi &= 0xFFFF0000
            # lower 16 bits: counter decreasing from 0xFFFF
            self.lo -= 0x00000001
            self.lo &= 0x0000FFFF
        self.iteration += 1
        return retval


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
