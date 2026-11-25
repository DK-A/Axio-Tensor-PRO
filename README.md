<div align="center">

# Axio-Tensor PRO
### Parameterized INT8 Systolic Array Accelerator for Spartan-7 FPGAs

[![Platform](https://img.shields.io/badge/FPGA-Xilinx%20Spartan--7%20(XC7S25%2F50)-orange.svg)](https://www.xilinx.com/products/silicon-devices/fpga/spartan-7.html)
[![Toolchain](https://img.shields.io/badge/Vivado-2023.1-blue.svg)]()
[![Verification](https://img.shields.io/badge/RTL%20Sim-Passing%20(2%2F2)-brightgreen.svg)]()
[![Regressions](https://img.shields.io/badge/Seeded%20Regressions-1000%2F1000%20Match-brightgreen.svg)]()
[![Fault Coverage](https://img.shields.io/badge/Mutations%20Trapped-6%2F6%20(100%25)-success.svg)]()

We built this project to solve a practical hardware problem: edge devices like microcontrollers and cheap single-board computers waste almost all their energy on cache misses and instruction decode when running simple convolution layers. Running custom INT8 matrix multipliers on a budget FPGA cuts that waste, but only if the hardware accounting is honest about data transfer bottlenecks.

[Architecture](#how-the-hardware-is-built) • [Execution Flow](#how-data-moves-through-the-chip) • [Measured Numbers](#timing-resources-and-the-dse-sweep) • [Verification](#how-we-verified-this) • [Bugs Found](#ablation-and-debugging-notes) • [How to Run It](#running-it-yourself)

---

</div>

## The Problem We Wanted to Solve

If you look at modern edge ML models—things like MobileNetV2 or 16-channel keyword spotters—the actual arithmetic is trivial. It is mostly signed 8-bit dot products. When you run those on an ARM Cortex core or a Raspberry Pi, the arithmetic units sit idle waiting on memory, and the CPU burns watts on branch predictors and register renames that a fixed convolution loop never needed in the first place.

Commercial accelerators like Google Coral or Intel Movidius fix this, but they cost $30–$70 and lock you into closed toolchains. 

We wanted to build an open, parameterized INT8 tensor core that fits on an entry-level Xilinx Spartan-7 (XC7S25), talks over a reliable serial wire, and can be sized up or down depending on what board you have on hand.

More importantly, we wanted to avoid the classic hackathon trap: claiming a "20x speedup" by comparing raw on-chip clock cycles against an entire Python script on a PC, while ignoring the 2 Mbaud serial link sitting in between.

---

## What We Actually Built

1. **A Synthesizable 2D Output-Stationary Systolic Array**: Written in SystemVerilog, parameterized by $N$ (2, 4, or 8) and inner-product depth $K$. It maps cleanly to Spartan-7 DSP48E1 slices and keeps running partial sums locally inside 32-bit accumulators.
2. **`acc_en` Mesh Routing**: A fix for a very specific hardware bug where systolic skew causes edge PEs to keep accumulating garbage while waiting on later wavefronts. We pass a delayed valid token through the mesh along with the data so each PE accumulates for exactly $K$ cycles.
3. **Multi-Tile Accumulation (`acc_keep`)**: TinyML layers like a $16 \times 9 \times 16$ convolution have $K=144$, which does not fit in a $4\times 4$ array in one shot. Our packet header includes an `acc_keep` flag that tells the PEs to hold their accumulators across consecutive chunks without resetting.
4. **Binary Wire Protocol with Hardware CRC-8**: Every packet uses a clean header with start-of-frame markers (`0xAA`/`0x55`), command IDs, matrix size, bank selectors, and an 8-bit checksum checked in silicon.
5. **Physical Place-and-Route Sweep**: We scripted Vivado batch runs across 18 points (varying $N$, clock frequencies from 100 to 200 MHz, and buffer schemes) to find where Spartan-7 timing actually closes instead of guessing theoretical numbers.
6. **Triple-Path Bit-Exact Verification**: We test every vector through a pure-Python scalar loop, a vectorized NumPy reference, and the full RTL in Vivado `xsim`. All paths generate matching SHA-256 digests.

---

## How the Hardware is Built

<div align="center">
  <img src="plots/fig_ieee_architecture_diagram.png" width="92%" alt="Hardware Block Diagram"/>
  <p><em>Figure 1: High-level hardware organization across the communication, memory, and compute stages.</em></p>
</div>

The accelerator lives in three distinct layers:

### 1. Ingress and Buffering
* **UART Core (`rtl/uart_rx.sv`, `rtl/uart_tx.sv`)**: Uses 2-flop synchronizers to sample incoming serial bits at 2,000,000 baud with 50 clocks per bit at 100 MHz.
* **CRC-8 Checker (`rtl/crc8.sv`)**: Hardware implementation using polynomial $x^8 + x^2 + x + 1$ (0x07). Packets with corrupt bytes get rejected immediately without burning compute cycles.
* **Matrix Buffer (`rtl/matrix_buffer.sv`)**: Dual-port BRAM memory with single and ping-pong modes. In ping-pong mode, the host streams tile $K+1$ into Bank 1 while the systolic array chews through tile $K$ in Bank 0.

### 2. Wavefront Timing (Skew Buffer)
Systolic arrays need matrix rows and columns staggered in time. Row $r$ of activation matrix $A$ is delayed by $r$ clock cycles through a triangular shift register. Column $c$ of weight matrix $B$ is delayed by $c$ cycles. This turns square matrices into diagonal data wavefronts that slide across the PE grid.

### 3. The Processing Element (PE)
Each PE contains:
* An $8 \times 8$ signed multiplier that infers a native Xilinx DSP48E1 slice.
* A registered product stage. Signed 8-bit numbers range from -128 to +127, so worst-case products land between $-16{,}256$ and $+16{,}384$.
* A signed 32-bit accumulator. With a maximum product of 16,384, an INT32 accumulator will not overflow until $K > 131{,}071$ steps, which is several orders of magnitude deeper than any real edge model layer.
* A sticky overflow latch that stays high if saturation limits are ever breached, reporting errors back in the packet status byte.

---

## How Data Moves Through the Chip

<div align="center">
  <img src="plots/fig_ieee_workflow_diagram.png" width="92%" alt="Execution Pipeline Flowchart"/>
  <p><em>Figure 2: Step-by-step pipeline from host-side matrix tiling to hardware execution and SHA-256 verification.</em></p>
</div>

The end-to-end execution flow follows five steps:

1. **Host Decomposes Workload**: `sw/workload_tiler.py` takes a layer shape (e.g. $16 \times 9 \times 16$), slices it into $4 \times 4$ chunks, marks intermediate chunks with `acc_keep = 1`, and reserves `acc_keep = 0` for the final drain step.
2. **Wire Framing**: `sw/protocol.py` packs 32 bytes of operands into a framed packet with length bytes and a CRC-8 checksum, then fires it over UART.
3. **Ingress and Launch**: The FSM parses the header, checks CRC, and moves to `ST_START_COMP`. It asserts `sa_acc_en` one clock cycle early so PE(0,0) captures its first multiplication on cycle 0.
4. **Compute and Drain**: The array computes for $K + 2N - 2$ cycles. On cycle $K + 2N - 1$ (11 cycles for $N=4, K=4$), `ST_LATCH_DRAIN` copies all 16 accumulators into the output FIFO simultaneously.
5. **Drain and Check**: The FIFO streams 64 bytes (16 signed 32-bit values) out through UART TX with a trailing CRC. The host reads the buffer, checks the status byte, and verifies every element against NumPy.

---

## Timing, Resources, and the DSE Sweep

Rather than assuming our design runs at arbitrary clock rates, we ran batch out-of-context placement and routing in Vivado across combinations of array sizes, clock frequencies, and buffer modes on the Spartan-7 (xc7s25csga324-1).

<div align="center">
  <img src="plots/fig_ieee_combined_matrix.png" width="92%" alt="Experimental Results Summary"/>
  <p><em>Figure 3: Measured numbers from Vivado: (a) Pareto frontier, (b) Honest latency comparison, (c) GOPS/Watt efficiency, (d) Setup slack across frequency.</em></p>
</div>

### Measured P&R Results Table

| Grid Size | Frequency | Buffering | DSPs Used | LUTs Used | Post-Route Slack (WNS) | Workload Latency | Sustained Throughput | Efficiency | Hardware Status |
| :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| $2\times 2$ | 100 MHz | Single | 4 (5%) | 908 (6%) | +5.30 ns | 16.00 µs | 0.288 GOPS | 27.0 GOPS/W | Meets Timing |
| $2\times 2$ | 150 MHz | Single | 4 (5%) | 908 (6%) | +1.97 ns | 10.67 µs | 0.432 GOPS | 27.0 GOPS/W | Meets Timing |
| $2\times 2$ | 200 MHz | Single | 4 (5%) | 908 (6%) | +0.30 ns | 8.00 µs | 0.576 GOPS | 27.0 GOPS/W | Meets Timing |
| **$4\times 4$** | **100 MHz** | **Single** | **16 (20%)** | **2,420 (17%)** | **+4.60 ns** | **5.28 µs** | **0.873 GOPS** | **26.5 GOPS/W** | **Our Default Baseline** |
| $4\times 4$ | 150 MHz | Single | 16 (20%) | 2,420 (17%) | +1.27 ns | 3.52 µs | 1.309 GOPS | 26.5 GOPS/W | Meets Timing |
| $4\times 4$ | 200 MHz | Single | 16 (20%) | 2,420 (17%) | -0.40 ns | — | — | — | Fails Timing (Pruned) |
| **$8\times 8$** | **100 MHz** | **Single** | **64 (80%)** | **8,396 (58%)** | **+3.20 ns** | **1.84 µs** | **2.504 GOPS** | **20.6 GOPS/W** | **Pareto Throughput Winner** |
| $8\times 8$ | 150 MHz | Single | 64 (80%) | 8,396 (58%) | -0.13 ns | — | — | — | Fails Timing (Pruned) |
| $8\times 8$ | 200 MHz | Single | 64 (80%) | 8,396 (58%) | -1.80 ns | — | — | — | Fails Timing (Pruned) |

*Note: Any configuration with negative setup slack ($\text{WNS} < 0$) is flagged as unstable and excluded from viable deployment.*

### An Honest Latency Breakdown

If someone tells you an FPGA is 50x faster than a CPU on single 4x4 matrix multiplications, they are hiding the wire transfer time. Here are the unvarnished numbers:

* **Core On-Chip Compute (BRAM benchmark mode)**: **110 ns** at 100 MHz (11 cycles).
* **Host CPU Vectorized GEMM (NumPy/BLAS)**: **77.9 ns**.
* **Serial Wire Transfer (2 Mbaud UART, 113 bytes round-trip)**: **565,000 ns (0.565 ms)**.

For a standalone $4\times 4$ tile, the serial link accounts for over 99.9% of total elapsed time. The FPGA compute itself is comparable in speed to an ARM core, but it uses a fraction of the power:
* **Host CPU**: ~15 W system draw $\to$ **0.11 GOPS/Watt**.
* **Spartan-7 Core**: ~142 mW dynamic draw $\to$ **26.5 GOPS/Watt**.

**Where the accelerator actually wins**: It wins when weights remain resident in on-chip BRAM across streaming sensor frames, or during multi-tile accumulation where thousands of operations execute per wire transaction. In those conditions, the $74\times$ to $240\times$ energy efficiency advantage pays off directly in battery life.

---

## Ablation and Debugging Notes

Building this wasn't seamless. We ran into three architectural snags that required fixing before the numbers worked:

### 1. The Skew Accumulation Bug
In our initial RTL, `sa_en` stayed high for all 10 compute cycles. PEs kept multiplying and accumulating whatever was on their inputs during the 6-cycle drain phase. The result: PE(0,0) accumulated 10 products instead of 4, producing garbage on every non-zero test vector.
* **The fix**: We separated data forwarding (`en`) from accumulation gating (`acc_en`). The accumulation gate is pushed through the PE mesh as a delayed token matching the triangular skew, so every single PE accumulates for exactly $K$ clock cycles.

### 2. The Cycle-0 Register Delay
SystemVerilog registers take one posedge to update. If the FSM asserted `sa_acc_en` inside `ST_COMPUTE`, PE(0,0) didn't see the signal until cycle 1—missing its very first inner product.
* **The fix**: We moved the first `sa_acc_en` pulse into `ST_START_COMP` (the state immediately preceding compute). It becomes active on the exact clock edge where operands enter the mesh.

### 3. Two's-Complement Range Asymmetry
A common mistake in INT8 hardware models is assuming bounds are symmetric ($\pm 16{,}384$). But signed two's complement numbers run from $-128$ to $+127$. 
* $(-128) \times (-128) = +16{,}384$
* $(-128) \times (+127) = -16{,}256$
* Tightening our assertions to $[-16{,}256, +16{,}384]$ prevented spurious formal assertion triggers while ensuring genuine multiplier bugs were still caught.

---

## How We Verified This

We used a three-layer verification harness to confirm correctness before touching hardware:

```
               [Test Matrix Pair (A, B)]
                           │
        ┌──────────────────┼──────────────────┐
        ▼                  ▼                  ▼
┌───────────────┐  ┌───────────────┐  ┌───────────────┐
│  Pure Python  │  │ Vectorized    │  │ Vivado xsim   │
│  Scalar Loop  │  │ NumPy Ref     │  │ SystemVerilog │
└───────┬───────┘  └───────┬───────┘  └───────┬───────┘
        │                  │                  │
        ▼                  ▼                  ▼
  SHA-256 Digest     SHA-256 Digest     Hardware Output
 [c3ebfbf45504...]  [c3ebfbf45504...]   (Bit-exact match)
```

1. **8 Directed Boundary Cases**: Edge cases including all-zeros, identity matrices, maximum positive ($+127 \times +127$), maximum negative asymmetry ($-128 \times -128$), and checkerboard sign toggles.
2. **1,000 Seeded Random Regressions**: Generates pseudo-random INT8 matrix pairs with seed 42. Both the Python model and the hardware simulation stream outputs into a SHA-256 hasher. Both digests matched bit-for-bit:
   ```
   Golden Digest: c3ebfbf45504d012ce5bf11f98a207b343a102e528dee88545b199961e97565f
   Sim    Digest: c3ebfbf45504d012ce5bf11f98a207b343a102e528dee88545b199961e97565f
   ```
3. **6-Class Mutation Testing**: To prove our test suite wasn't just passing blindly, we injected deliberate faults into the datapath:
   * Multiplier bit 15 flip $\to$ **Caught** by boundary checks.
   * Multiplier lower 2 bits dropped $\to$ **Caught** by regression checks.
   * `clr_acc` reset ignored $\to$ **Caught** by SVA assertion `assert_clr_acc`.
   * Skew buffer row delay shifted by 1 $\to$ **Caught** by matrix output comparison.
   * UART handshake dropped early $\to$ **Caught** by SVA assertion `assert_tx_handshake`.
   * Output FIFO read when empty $\to$ **Caught** by SVA assertion `assert_no_underflow`.

Every injected fault was caught (6/6, 100% mutation coverage).

---

## Running It Yourself

### Quick Simulation Run
To run the Vivado batch simulation directly on your machine:
```powershell
# Compile RTL and testbench
G:\Xilinx\Vivado\2023.1\bin\xvlog.bat --sv rtl\*.sv tb\tb_systolic_top.sv

# Elaborate
G:\Xilinx\Vivado\2023.1\bin\xelab.bat -debug typical tb_systolic_top -s tb_sim

# Run the simulation snapshot
G:\Xilinx\Vivado\2023.1\bin\xsim.bat tb_sim --runall
```
You should see:
```
==================================================================
VERIFICATION RESULT: 2/2 Tests Passed Bit-Exactly without SVA Errors
==================================================================
```

### Running the Python Verification Suite
```bash
python sw/verification_engine.py
```
This runs the 8 directed tests, the 1,000-matrix seeded regression, and the 6 mutation tests in sequence.

### Building the Bitstream for Arty S7
If you have an Arty S7 board connected and want to generate a physical `.bit` file:
```powershell
G:\Xilinx\Vivado\2023.1\bin\vivado.bat -mode batch -source vivado/build_bitstream.tcl -tclargs xc7s25csga324-1 4
```

### Physical Hardware Verification over UART
Plug the Arty S7 into your USB port and run:
```bash
python sw/hardware_validator.py
```
It auto-detects the FTDI COM port, resets the accumulator, streams test vectors over 2 Mbaud serial, and verifies hardware responses against NumPy.

---

## File Structure

```
├── rtl/                        # Synthesizable SystemVerilog
│   ├── pe.sv                   # Processing element with DSP48E1 inference and acc_en
│   ├── systolic_array.sv       # NxN mesh routing
│   ├── skew_buffer.sv          # Triangular delay registers
│   ├── matrix_buffer.sv        # BRAM single/double buffer
│   ├── output_fifo.sv          # Drain FIFO serializer
│   ├── crc8.sv                 # Hardware CRC-8 engine
│   ├── uart_rx.sv / uart_tx.sv # 2 Mbaud UART controller
│   ├── fsm_controller.sv       # Central 10-state machine
│   └── axio_tensor_top.sv      # Top-level integration
├── tb/
│   ├── tb_systolic_top.sv      # Self-checking UART testbench
│   └── tb_mutation_test.sv     # Mutation injection harness
├── sw/
│   ├── golden_model.py         # Scalar Python and NumPy reference GEMM
│   ├── protocol.py             # Binary packet encoder/decoder
│   ├── verification_engine.py  # 8 boundary tests, 1000 regressions, mutations
│   ├── hardware_validator.py   # Physical board validation over serial
│   ├── workload_tiler.py       # MobileNet and KWS convolution tiler
│   ├── optimization_engine.py  # DSE sweep parser and Pareto model
│   └── benchmark_cpu.py        # CPU vs FPGA honest latency profiler
├── plots/                          # Publication plots and generator scripts
│   ├── generate_ieee_plots.m       # MATLAB plotting script
│   └── generate_ieee_plots.py      # Python headless plotting script
├── vivado/
│   ├── build_bitstream.tcl     # Batch synthesis and place-and-route
│   ├── program_fpga.tcl        # Hardware manager flashing script
│   └── run_sweep.tcl           # Out-of-context 18-point sweep script
└── axio_tensor_pro_report.md   # Detailed engineering report
```

---

## License

This project is licensed under the MIT License - feel free to use, modify, and build upon it.
