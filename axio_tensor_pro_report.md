# Axio-Tensor PRO: Design, Verification, and Characterization of a Parameterized INT8 Systolic Core on Spartan-7

**Authors:** TECHTONICS Team  
**Platform:** Digilent Arty S7 (Xilinx Spartan-7 XC7S25 / XC7S50)  
**Host Controller:** Raspberry Pi 4/5 or Workstation PC over 2 Mbaud UART  
**Repository:** [https://github.com/DK-A/Axio-Tensor-PRO](https://github.com/DK-A/Axio-Tensor-PRO)

---

## 1. Abstract

Edge machine learning inference requires computing millions of multiply-accumulate operations under strict power budgets. While modern microcontrollers and small single-board computers can technically evaluate these networks, they waste most of their power budget on instruction decode, cache hierarchies, and speculative execution for loops that are fundamentally static. Dedicated tensor processing units solve this, but commercial options are often costly and closed-source. 

In this work, we present **Axio-Tensor PRO**, an open-source, parameterized INT8 output-stationary systolic array accelerator implemented on the Xilinx Spartan-7 FPGA. The system combines an RTL compute fabric with a structured 2 Mbaud binary packet protocol, hardware CRC-8 error detection, and multi-tile accumulation support for deep neural network layers. To address common pitfalls in hardware reporting, we evaluate the system across three distinct physical latency tiers and execute an automated 18-point place-and-route design-space exploration in Vivado to establish true timing closure limits. 

On an Arty S7-25, our optimal $8\times 8$ configuration at 100 MHz delivers **2.504 GOPS** sustained throughput at **20.6 GOPS/Watt**, offering a **$74.8\times$ to $240\times$ energy efficiency advantage** over host CPU vector execution. All RTL modules are verified through a triple-path bit-exact flow, 1,000 seeded random regressions certified by matching SHA-256 digests, and a 6-class mutation testing suite achieving 100% fault trapping.

---

## 2. Motivation and Practical Context

Edge intelligence has increasingly shifted toward quantized neural networks like MobileNetV2 and Keyword Spotting models. In these architectures, floating-point weights are replaced by signed 8-bit integers (INT8), dramatically reducing memory bandwidth while preserving task accuracy within 1–2%.

Despite this algorithmic simplification, standard edge microprocessors handle these operations inefficiently. An ARM Cortex-A72 running a vectorized GEMM loop expends roughly 85–90% of its total energy outside the ALU—managing cache coherency, instruction pipelines, and memory interfaces.

FPGAs offer an attractive middle ground:
1. **Arithmetic Density**: Logic slices and DSP blocks can be wired directly into systolic pipelines where data flows directly from one multiplier to the next without bouncing back and forth to a register file.
2. **Energy Efficiency**: A low-cost Spartan-7 device draws roughly 150 mW to 600 mW of dynamic power, making it suitable for battery-powered IoT nodes.
3. **Reconfigurability**: The array geometry ($N$) and inner-product depth ($K$) can be retargeted to match specific layer shapes without silicon re-spins.

However, many academic and hackathon FPGA accelerators suffer from a credibility problem: they report "10x–50x speedups" by comparing on-chip FPGA clock cycles against full Python execution time on a PC, completely ignoring the slow communication link connecting them. Our goal was to build a complete, transparent, and provably verified hardware system that accounts for real-world wire latency, reports physical post-route timing, and guarantees bit-exact results against a reference model.

---

## 3. System Architecture and Implementation

Axio-Tensor PRO is partitioned into three functional tiers: the Host Communication Layer, the Memory and Wavefront Shaper, and the 2D Systolic Compute Fabric.

```
+-------------------------------------------------------------------------+
|                              HOST PLANE                                 |
|      [Host Python Driver] <==== 2 Mbaud Serial ====> [FTDI Bridge]      |
+------------------------------------+------------------------------------+
                                     | Binary Packets (SOF=0xAA, CRC8)
+------------------------------------v------------------------------------+
|                         FPGA CONTROL & STORAGE                          |
|   +------------------+    +-------------------+    +----------------+   |
|   |  UART RX Core    |--->|  FSM Controller   |<---|  CRC8 Engine   |   |
|   +------------------+    +---------+---------+    +----------------+   |
|                                     |                                   |
|                                     v                                   |
|                     +-------------------------------+                   |
|                     | Matrix Buffer (Single/Double) |                   |
|                     +---------------+---------------+                   |
+-------------------------------------|-----------------------------------+
                                      v Staggered Vector Slices
+-------------------------------------------------------------------------+
|                           COMPUTE ENGINE                                |
|   +--------------------+     +--------------------------------------+   |
|   | Triangular Skew    |---->| 2D Systolic Array (N x N PEs)        |   |
|   | Delay Buffers      |     | - DSP48E1 Signed Multipliers         |   |
|   +--------------------+     | - acc_en Mesh Propagation Gating     |   |
|                              | - INT32 Accumulators & Sticky OVF    |   |
|                              +------------------+-------------------+   |
|                                                 |                       |
|                                                 v                       |
|                               +-----------------------------------+     |
|                               | Output FIFO Drain Serializer      |     |
|                               +-----------------+-----------------+     |
|                                                 |                       |
+-------------------------------------------------|-----------------------+
                                                  v
                                     [UART TX Core] ===> Host
```

### 3.1 Host Communication and Packet Protocol
Communication occurs over a 2,000,000 baud UART link (50 clock cycles per bit at 100 MHz) through the Arty S7's onboard FTDI FT2232HQ USB-UART bridge. 

To ensure data integrity, all transmissions are encapsulated in structured binary frames:

* **Command Packet (Host to FPGA)**:
  `[0xAA] [CMD: 1B] [N: 1B] [FLAGS: 1B] [LEN: 2B] [PAYLOAD: 2*N^2 bytes] [CRC8: 1B]`
* **Response Packet (FPGA to Host)**:
  `[0x55] [STATUS: 1B] [CYCLES: 4B] [LEN: 2B] [PAYLOAD: 4*N^2 bytes] [CRC8: 1B]`

The hardware CRC-8 module computes an 8-bit checksum using polynomial $x^8 + x^2 + x + 1$ (`0x07`). If a corrupt byte arrives, the FSM flags the error in the status byte and discards the packet without executing false computations.

### 3.2 Matrix Storage and Ping-Pong Operation
The matrix buffer stores input activations (Matrix A) and weights (Matrix B). In default single-buffer mode, it allocates $2N^2$ bytes of BRAM. When `DOUBLE_BUFFER_EN = 1`, storage expands to $4N^2$ bytes, splitting into Bank 0 and Bank 1. This allows the host to stream the next tile's operands into Bank 1 over UART while the systolic array actively computes using Bank 0, masking communication latency during streaming inference.

### 3.3 Wavefront Skew Buffering
In an output-stationary systolic array, data must enter the mesh along diagonal wavefronts. A triangular shift register network introduces the necessary pipelined delays:
* Row $r$ of activation matrix A is delayed by $r$ cycles ($r \in [0, N-1]$).
* Column $c$ of weight matrix B is delayed by $c$ cycles ($c \in [0, N-1]$).

For an $N \times N$ array with inner depth $K$, the active compute window requires exactly $K + 2N - 2$ clock cycles.

### 3.4 Processing Element (PE) Design
Each PE implements a two-stage pipelined multiply-accumulate unit:

1. **Multiplier Stage**: Evaluates $P = A \times B$ using an inferred DSP48E1 block. Since operands are signed 8-bit values ($[-128, +127]$), the product spans $[-16{,}256, +16{,}384]$.
2. **Accumulator Stage**: Accumulates into a 32-bit register:
   $$\text{acc}[t+1] = \begin{cases} P[t], & \text{if } \text{clr\_acc} \land \neg\text{acc\_keep} \\ \text{acc}[t] + P[t], & \text{if } \text{reg\_acc\_en} \\ \text{acc}[t], & \text{otherwise} \end{cases}$$

An accumulator depth of 32 bits guarantees safety against overflow for $K \le 131{,}071$ consecutive worst-case operations ($131{,}071 \times 16{,}384 = 2{,}147{,}468{,}288 < 2^{31}-1$). If an anomalous value triggers an overflow, a sticky overflow latch records the event and transmits it in the response header.

### 3.5 The `acc_en` Mesh Propagation Mechanism
A critical bug in naive systolic array implementations is premature accumulation. Because the skew buffer delays inputs, PE(0,0) begins computing immediately, whereas PE($N-1, N-1$) does not see valid data until cycle $2N-2$. If a global accumulation enable signal is broadcast, edge PEs accumulate invalid boundary data during the startup and drain phases.

Rather than managing complex per-PE state counters in the central FSM, Axio-Tensor PRO routes an `acc_en` token through the mesh alongside the data. The FSM asserts `sa_acc_en` for exactly $K$ cycles. This token travels East and South through pipeline registers with the exact same latency as operands $A$ and $B$, guaranteeing that every PE accumulates for exactly $K$ valid cycles regardless of array dimensions.

### 3.6 Multi-Tile Accumulation (`acc_keep`)
Real-world TinyML layers routinely exceed the hardware dimension $N$. For example, a $3\times 3$ convolution with 16 channels requires $K = 144$ inner products. 

To execute this on a $4\times 4$ array, the host decomposition script (`sw/workload_tiler.py`) divides the operation into $\lceil 144/4 \rceil = 36$ successive tile passes. For passes 1 through 35, the packet header sets `acc_keep = 1`, which prevents the accumulator from resetting. Only the 36th tile clears `acc_keep`, allowing the final accumulated sum to be captured and drained into the output FIFO.

---

## 4. Design-Space Exploration (DSE) and Physical Results

To avoid speculative performance claims, we scripted a headless Vivado 2023.1 batch sweep (`vivado/run_sweep.tcl`) executing out-of-context synthesis, placement, and routing across 18 configuration points on the Spartan-7 (XC7S25CSGA324-1).

### 4.1 Measured Utilization and Timing Closure

| Grid Size | Frequency | Buffering | DSP48E1 | Slice LUTs | Post-Route WNS | Latency (µs) | Throughput (GOPS) | Efficiency (GOPS/W) | Status |
| :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: |
| $2\times 2$ | 100 MHz | Single | 4 (5%) | 908 (6%) | +5.30 ns | 16.00 | 0.288 | 27.0 | Met Timing |
| $2\times 2$ | 150 MHz | Single | 4 (5%) | 908 (6%) | +1.97 ns | 10.67 | 0.432 | 27.0 | Met Timing |
| $2\times 2$ | 200 MHz | Single | 4 (5%) | 908 (6%) | +0.30 ns | 8.00 | 0.576 | 27.0 | Met Timing |
| **$4\times 4$** | **100 MHz** | **Single** | **16 (20%)** | **2,420 (17%)** | **+4.60 ns** | **5.28** | **0.873** | **26.5** | **Baseline Target** |
| $4\times 4$ | 150 MHz | Single | 16 (20%) | 2,420 (17%) | +1.27 ns | 3.52 | 1.309 | 26.5 | Met Timing |
| $4\times 4$ | 200 MHz | Single | 16 (20%) | 2,420 (17%) | -0.40 ns | — | — | — | Violated Setup (Pruned) |
| **$8\times 8$** | **100 MHz** | **Single** | **64 (80%)** | **8,396 (58%)** | **+3.20 ns** | **1.84** | **2.504** | **20.6** | **Pareto Winner** |
| $8\times 8$ | 150 MHz | Single | 64 (80%) | 8,396 (58%) | -0.13 ns | — | — | — | Violated Setup (Pruned) |
| $8\times 8$ | 200 MHz | Single | 64 (80%) | 8,396 (58%) | -1.80 ns | — | — | — | Violated Setup (Pruned) |

### 4.2 Analysis of the Pareto Frontier
* **Frequency Limit**: On a -1 speed grade Spartan-7, long control broadcast paths (specifically `clr_acc` fanout across large meshes) cause setup violations at 200 MHz for $4\times 4$ and at 150 MHz for $8\times 8$.
* **Sweet Spot**: For balanced area and timing margin, **$4\times 4$ at 150 MHz** offers comfortable positive slack (+1.27 ns) using only 20% of device DSPs. 
* **Maximum Throughput**: If peak performance is prioritized, **$8\times 8$ at 100 MHz** achieves **2.504 GOPS** while retaining +3.20 ns of setup slack, utilizing 80% of DSP slices.

### 4.3 Honest Three-Tier Latency Breakdown
Rather than obscuring serial transmission overhead, we report latency across three distinct physical tiers for a $4\times 4$ matrix multiplication:

1. **On-Chip Compute (BRAM Benchmark Mode)**: **110 ns** (11 clock cycles at 100 MHz).
2. **Host CPU Vector Baseline (NumPy/BLAS)**: **77.9 ns** (averaged over $10^5$ iterations on host workstation).
3. **Serial Round-Trip (2 Mbaud UART, 113 wire bytes)**: **565,000 ns (0.565 ms)**.

**Key Finding**: For an isolated $4\times 4$ tile, serial transfer dominates 99.9% of elapsed wall-clock time. This proves that offloading single tiny operations over UART is counterproductive. However, when weights remain cached on-chip or during large multi-tile convolution streaming, the compute core's **26.5 GOPS/Watt** energy efficiency ($240\times$ higher than the host CPU's 0.11 GOPS/Watt) delivers substantial system-level power savings.

---

## 5. Verification and Robustness

### 5.1 Triple-Path Verification Architecture
To eliminate circular validation (e.g. comparing NumPy against NumPy), our test suite evaluates three independent paths:
* **Path 1**: Scalar Python nested integer loop (independent arithmetic model).
* **Path 2**: Vectorized NumPy BLAS reference.
* **Path 3**: Cycle-accurate Vivado `xsim` RTL simulation running synthesizable SystemVerilog.

Across 1,000 pseudo-random test matrices (PRNG seed 42), the streaming output digests matched bit-for-bit:
```
NumPy Golden SHA-256 : c3ebfbf45504d012ce5bf11f98a207b343a102e528dee88545b199961e97565f
Hardware Sim SHA-256 : c3ebfbf45504d012ce5bf11f98a207b343a102e528dee88545b199961e97565f
```

### 5.2 Directed Boundary Vectors
Eight edge-case tests verify arithmetic corner behavior:
1. All-zero matrices ($0 \times 0 \to 0$).
2. Identity matrix multiplication ($A \times I = A$).
3. Maximum positive values ($+127 \times +127 \to +16{,}129$).
4. Maximum negative two's-complement asymmetry ($-128 \times -128 \to +16{,}384$).
5. Cross-sign extremes ($-128 \times +127 \to -16{,}256$).
6. Checkerboard alternating signs ($\pm 127, \mp 128$).
7. Single-impulse sparse corners.
8. Symmetric zero-cancellation sums.

### 5.3 Fault Injection and Mutation Testing
To confirm the sensitivity of our testbench, we injected 6 distinct fault classes into the simulation model:

| Class | Injected Fault Description | Detection Mechanism | Status |
| :---: | :--- | :--- | :---: |
| **M1** | Multiplier sign bit inversion (bit 15 flipped) | Directed Boundary Suite | **Trapped** |
| **M2** | Multiplier LSB truncation (lower 2 bits zeroed) | Seeded Regression Suite | **Trapped** |
| **M3** | Accumulator reset suppression (`clr_acc` ignored) | SVA Assertion `assert_clr_acc` | **Trapped** |
| **M4** | Skew buffer row delay shifted by 1 cycle | Matrix Regression Comparison | **Trapped** |
| **M5** | Premature `tx_valid` deassertion during handshake | SVA Assertion `assert_tx_handshake` | **Trapped** |
| **M6** | Output FIFO read assertion while empty | SVA Assertion `assert_no_underflow` | **Trapped** |

All six fault classes were successfully trapped, achieving 100% mutation coverage.

---

## 6. Ablation Studies

To quantify the architectural value of each module, we disabled or altered individual blocks in simulation:

1. **`acc_en` Mesh Routing Removed**: Accumulation was gated solely on global `sa_en`. PEs accumulated invalid inputs during drain cycles. Test 1 failed completely (Column 0 evaluated to 0), and Test 2 accumulated 163,840 instead of 65,536.
2. **Skew Buffers Bypassed**: Inputs were driven directly into the array boundaries without cycle staggering. Non-diagonal matrix elements were corrupted across all test runs.
3. **Single vs. Ping-Pong Buffer**: Double buffering increased slice LUT utilization by +128 LUTs (+5.3%) while leaving DSP utilization unchanged, confirming that ping-pong latency hiding carries minimal area penalty.
4. **CRC-8 Omitted**: Dropping CRC-8 saved one byte per packet header, but intentional single-bit baud misalignments produced silent data corruption in 100% of tested transmission errors.

---

## 7. Conclusion

Axio-Tensor PRO demonstrates that low-cost Spartan-7 FPGAs can serve as highly effective edge tensor coprocessors when designed with cycle-accurate skew compensation and honest performance accounting. By implementing mesh-propagated accumulation gating, multi-tile accumulator persistence, and a verified binary packet protocol, the system achieves **20.6 to 26.5 GOPS/Watt** under realistic physical constraints. 

Our open-source release includes complete synthesizable SystemVerilog sources, self-checking testbenches, Python verification scripts, Vivado batch build flows, and physical board communication utilities, providing a verified foundation for edge TinyML acceleration.
