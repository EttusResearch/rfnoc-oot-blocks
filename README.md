# RFNoC OOT Blocks: Official Ettus Research Out Of Tree (OOT) RFNoC blocks

This is an out-of-tree (OOT) module for RFNoC blocks. Out-of-tree means that
these RFNoC blocks are maintained outside of the [uhd](https://github.com/EttusResearch/uhd)
repository. The uhd repository contains the core RFNoC blocks which are
required for the default FPGA bitfiles which are published as part of the
UHD releases.

In this repository we maintain RFNoC blocks which further extend the functionality
of RFNoC-capable USRPs.

This repository is maintained by Ettus Research, a National Instruments (NI) Brand.
NI is now part of Emerson.

## RFNoC Blocks

The following RFNoC blocks are contained in this repository:

- Aurora
    - Block definition file: [aurora.yml](rfnoc/blocks/aurora.yml)
    - FPGA implementation: [rfnoc/fpga/oot-blocks/rfnoc_block_aurora](./rfnoc/fpga/oot-blocks/rfnoc_block_aurora)
    - Getting Started: [RFNoC Block Aurora](rfnoc/fpga/oot-blocks/rfnoc_block_aurora/README.md)
    - User manual: [Aurora RFNoC Block User Manual](rfnoc/fpga/oot-blocks/rfnoc_block_aurora/docs/RFNoC_block_Aurora_manual.md)

## Directory Structure (in alphabetical order)

* `apps`: This directory is for applications that should get installed into
  the $PATH.

* `cmake`: This directory only needs to be modified if this OOT module will
  come with its own custom CMake modules.

* `examples`: Any example that shows how to use this OOT module goes here.
  Examples that are listed in CMake get installed into `share/rfnoc-oot-blocks/examples`
  within the installation prefix.

* `rfnoc/fpga/oot-blocks`: This directory contains the gateware for the HDL modules
  of the individual RFNoC blocks, along with their testbenches, and additional
  modules required to build the blocks. There is one subdirectory for every
  block (or module, or transport adapter). This is also where to define IP that
  is required to build the modules (e.g., Vivado-generated IP).
  Note that this is an "include directory" for gateware, which is why the
  module name ('oot-blocks') is included in the path. When installing this OOT
  module, these files get copied to the installation path's RFNoC package dir
  (e.g., `/usr/share/uhd/rfnoc/fpga/oot-blocks`) so the image builder can find
  all the source files when compiling bitfiles that use multiple OOT modules.

* `gr-rfnoc_oot-blocks`: An out-of-tree module for GNU Radio, which depends on this
  RFNoC out-of-tree module and provides GNU Radio and GNU Radio Companion
  bindings for using the oot-blocks block from within GNU Radio.

* `icores`: Stores full image core files. YAML files in this directory get
  picked up by CMake and get turned into build targets. For example, here we
  include an image core file called `x410_X1_200_Aurora100Gbps_rfnoc_image_core.yml`
  which defines an X310 image core with the oot-blocks block included. You can build
  this image directly using the image builder, but you can also run
  `make x410_X1_200_Aurora100Gbps_rfnoc_image_core` to build it using `make`.
  These files do not get installed.

* `include/rfnoc/oot-blocks`: Here, all the header files for the block controllers
  are stored, along with any other include files that should be installed when
  installing this OOT module.
  As with the gateware, the path name mirrors the path after the installation,
  e.g., these header files could get installed to `/usr/include/rfnoc/oot-blocks`.
  By mirroring the path name, we can write
  `#include <rfnoc/oot-blocks/aurora_block_control.hpp>` in our C++ source code, and
  the compilation will work for building this OOT module directly, or in 3rd
  party applications.

* `lib`: Here, all the non-header source files for the block controllers are stored,
  along with any other include file that should not be installed when installing
  this OOT module. This includes the block controller cpp files. All of these
  source files comprise the DLL that gets built from this OOT module.

* `python`: Use this directory to add Python bindings for blocks. Note that if
  the UHD Python API is not found (or Python dependencies for building bindings,
  such as pybind11, are not found) no Python bindings will be generated.

* `rfnoc/blocks`: This directory contains all the block definitions (YAML files).
  These block definitions can be read by the RFNoC tools, and will get
  installed into the system for use by other out-of-tree modules.
  If an out-of-tree module contains other types of RFNoC components, such as
  modules or transport adapters, they should be placed in the appropriate
  subdirectory of `rfnoc` (e.g., `rfnoc/modules` or `rfnoc/transport_adapters`).
  Like with the gateware, these get installed into the RFNoC package data
  directory, e.g., `/usr/share/uhd/rfnoc/blocks/*.yml`.

* `rfnoc/dts`: This is an example folder for when blocks or transport adapters
  require additional .dtsi files (DTS include files). The only file in here is
  empty, and is included for example purposes only.

A note on the directory structure: After installation, all files that are
required by `rfnoc_image_builder` get installed into a common directory, e.g.
`/usr/share/uhd/rfnoc`. The directory structure underneath is identical to the
directory structure in this example, e.g., `/usr/share/uhd/rfnoc/fpga/oot-blocks` will
have the same content as `./fpga/oot-blocks`. This allows the image builder to work
with the OOT module as an include directory.

Files that are required for the software component (e.g., everything under `include`,
`lib`, `apps` and so on) are installed like any other software (e.g., include
files may go to `/usr/include/rfnoc`, shared libraries might go to `/usr/lib`,
and so on).



## Building FPGA bitfiles from this OOT module

Building a bitfile requires an image core file, and those are stored under the
`icores` directory. The image core files are YAML files that define the contents
of the RFNoC image, including the blocks that are part of the image.

Inside the `icores` directory is a CMakeLists.txt file, inside which bitfile
targets can be defined using the `RFNOC_REGISTER_IMAGE_CORE()` macro. For example,
if we register the image core file `x410_X1_200_Aurora100Gbps_rfnoc_image_core.yml`
in the CMakeLists.txt file, we can build the bitfile using the following command
(assuming CMake was executed beforehand):

```sh
cd /path/to/rfnoc-oot-blocks/build
make x410_X1_200_Aurora100Gbps_rfnoc_image_core
```

Note that this will build the bitfile with source files from this directory. This
workflow is therefore a sensible way to build bitfiles during development.

Using `make` is not a requirement, it is merely a convenience. You can also
directly run `rfnoc_image_builder` and point it to the `rfnoc` subdirectory:

```sh
cd /path/to/rfnoc-oot-blocks/
rfnoc_image_builder -y ./icores/x410_X1_200_Aurora100Gbps_rfnoc_image_core.yml -I ./rfnoc
```

This has the same effect, but let's you control the precise arguments to the
image builder.

However, the design of the out-of-tree module is such that it is also possible
to install, and then build bitfiles using the installed files. This is of value
when installing multiple OOT modules, and not planning to modify their source
files.

For example, the following workflow is valid:

```sh
cd /path/to/rfnoc-oot-blocks  # Switch to this file's directory
mkdir build && cd build && cmake .. -DUHD_FPGA_DIR=/path/to/uhd/fpga  # Configure the project
# Now, launch an image build and use all files from this directory:
rfnoc_image_builder -y ../icores/x410_X1_200_Aurora100Gbps_rfnoc_image_core.yml -I ../rfnoc
make install  # Install software and gateware
# Build again, without -I:
rfnoc_image_builder -y ../icores/x410_X1_200_Aurora100Gbps_rfnoc_image_core.yml
```

In this workflow, we launch `rfnoc_image_builder` once with `-I` on the current
directory, and once without. In the latter case, the image builder will only
use files that were installed into the right location.
