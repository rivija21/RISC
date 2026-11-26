\# Single-Cycle RISC-V Core (`core\_sc`)



This sub-directory contains the RTL realization of the single-cycle execution RISC-V processor (`RV32I + Zicsr`, `CPI = 1.00`). It supports selectable microprogrammed ROM control (`control\_rom.sv`) or hardwired control (`control\_hardwired.sv`), machine-mode traps, `MRET`, machine timer interrupts, and performance counters (`mcycle`, `minstret`, `time`). 



All system-level testbenches and verification suites in `tb/` are shared and interchangeable across all CPU micro-architectures in this repository (`CORE = 0` multi-cycle, `CORE = 1` single-cycle, and `CORE = 2` 5-stage pipeline).



\---



\## 1. Synthesis \& Compilation (Quartus Prime)



Target device: \*\*Intel Cyclone V (`5CSEMA5F31C6`)\*\*. Ensure the project is placed in a directory path with \*\*no spaces\*\* (e.g., `C:/fpga/rv32\_edu`) so the relative memory initialization path (`../sw/build/fpga\_demo.hex`) resolves properly.



\### Option A: Automated TCL Setup (Recommended)

Open the \*\*Quartus Prime Command Shell\*\* (or terminal) and run the project generation script from the `quartus/` directory:



```bash

cd quartus



\# Single-cycle core with microprogrammed ROM control (CORE = 1, CTRL\_ROM = 1)

quartus\_sh -t create\_project.tcl 1



\# Single-cycle core with hardwired control (CORE = 1, CTRL\_ROM = 0)

quartus\_sh -t create\_project.tcl 1 0

