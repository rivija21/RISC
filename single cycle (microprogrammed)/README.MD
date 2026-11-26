\# Single-Cycle RISC-V Core (`core\_sc`)



This sub-directory contains the RTL realization of the single-cycle execution RISC-V processor (`RV32I + Zicsr`, `CPI = 1.00`)\[cite: 2]. It supports selectable microprogrammed ROM control (`control\_rom.sv`) or hardwired control (`control\_hardwired.sv`), machine-mode traps, `MRET`, machine timer interrupts, and performance counters (`mcycle`, `minstret`, `time`)\[cite: 2].



All system-level testbenches and verification suites in `tb/` are shared and interchangeable across all CPU micro-architectures in this repository (`CORE = 0` multi-cycle, `CORE = 1` single-cycle, and `CORE = 2` 5-stage pipeline)\[cite: 1, 2].



\---



\## 1. Simulation \& Testbenches (Questa / ModelSim)



1\. Start \*\*Questa – Intel FPGA Starter Edition\*\* (or ModelSim)\[cite: 1].

2\. Set the working directory to the repository root `rv32\_edu` (the folder containing `rtl`, `tb`, and `sw`) via \*\*File → Change Directory\*\*\[cite: 1].

3\. Compile the RTL and testbenches in the \*\*Transcript\*\* window\[cite: 1]:



```tcl

do sim/questa/compile.do

```



\### Running SoC Programs

Use `run\_soc.do` with the syntax `do sim/questa/run\_soc.do <CORE> <program> \[CTRL\_ROM] \[gui]`, where `<program>` is any prebuilt `.hex` file in `sw/build/` (omitting the `.hex` extension)\[cite: 1]:



```tcl

\# Run hello program on single-cycle core with microprogrammed ROM control (CORE = 1, CTRL\_ROM = 1)

do sim/questa/run\_soc.do 1 hello 1



\# Run trap\_test on single-cycle core with hardwired control (CORE = 1, CTRL\_ROM = 0)

do sim/questa/run\_soc.do 1 trap\_test 0



\# Run other cores for comparison (0 = multi-cycle, 2 = 5-stage pipeline)

do sim/questa/run\_soc.do 2 hello

do sim/questa/run\_soc.do 0 bench\_rv32im

```



\### Waveform Debugging

Append `gui` to load the pre-configured signal list for the selected core and run for `20 us`\[cite: 1]:



```tcl

\# Launch GUI with pre-configured signals and run for 20 us

do sim/questa/run\_soc.do 1 rv32ui-add 1 gui



\# Continue simulation inside the Questa Transcript window

run 20 us

run -all

```



\### Running Unit Testbenches

Run the standalone verification suites (`tb\_muldiv`, `tb\_control\_equiv`, `tb\_fp\_add`, `tb\_fpga\_top`)\[cite: 1, 2]:



```tcl

do sim/questa/run\_unit.do

```



\---



\## 2. Timing Analysis \& Architectural Notes



Static timing analysis is governed by `quartus/fpga\_top.sdc`, which constrains `clk` to \*\*50 MHz (20 ns period)\*\*\[cite: 1].



1\. Open \*\*Compilation Report → Timing Analyzer → Slow 1100mV 85C Model → Fmax Summary\*\*\[cite: 1].

2\. To inspect the critical path, right-click the `clk` row in the Fmax table and select \*\*Report Top Failing Paths\*\* (or open \*\*Reports → Custom Reports → Report Timing\*\* with `From clock: clk`)\[cite: 1].



\### Expected Architectural Behavior

\* \*\*Fmax \& Critical Path:\*\* Because the single-cycle architecture executes `PC → Instruction Memory → Decode → Register File → ALU → Data Memory → Write-Back` within a single clock period (bounded by the load instruction path), failing the 50 MHz constraint in the Timing Analyzer is expected\[cite: 1]. Use the reported `Fmax` directly to compute execution time:

&#x20; $$\\text{Execution Time} = \\text{Instruction Count} \\times \\text{CPI} \\times \\frac{1}{F\_{\\max}}$$

\[cite: 1]

\* \*\*Memory Inference:\*\* Because `soc\_sc` (`mem\_dp\_async`) requires asynchronous reads within the same cycle, Quartus infers \*\*MLABs (LUT-RAM)\*\* rather than M10K block RAM\[cite: 1, 2].

\* \*\*ISA Limitation:\*\* The `RV32M` multiply/divide extension is intentionally omitted from the single-cycle core; executing `MUL`/`DIV` instructions triggers an illegal-instruction trap (`mcause = 2`)\[cite: 2].

