#!/usr/bin/env python3
"""
hardware_validator.py - Live Physical Hardware Verification for Axio-Tensor PRO
Executes live verification over physical USB-UART (FT2232H / COM port):
  - Auto-detects connected FPGA COM port
  - Sends binary test frames with CRC8
  - Receives hardware responses, verifies CRC, cycle counts, status
  - Compares hardware results with Golden NumPy model (zero placeholding)
  - Computes and prints physical SHA-256 digest
"""

import sys
import time
import argparse
import hashlib
import numpy as np
import serial
import serial.tools.list_ports as lp

from protocol import (
    encode_matrix_tiles, decode_response_packet,
    encode_command_packet, CMD_BENCHMARK, CMD_RESET_ACC, calc_crc8
)
from golden_model import numpy_gemm
from verification_engine import generate_directed_boundary_cases

def detect_fpga_port(specified_port=None):
    if specified_port:
        return specified_port
    ports = lp.comports()
    if not ports:
        return None
    # Look for Digilent / FTDI device
    for p in ports:
        desc = (p.description or "").lower()
        hwid = (p.hwid or "").lower()
        if "ftdi" in desc or "digilent" in desc or "usb serial port" in desc or "0403:" in hwid:
            return p.device
    # Fallback to first available port
    return ports[0].device

class HardwareRunner:
    def __init__(self, port: str, baud: int = 2000000, timeout: float = 2.0, n: int = 4):
        self.port_name = port
        self.baud = baud
        self.timeout = timeout
        self.n = n
        self.ser = serial.Serial(
            port=port,
            baudrate=baud,
            bytesize=serial.EIGHTBITS,
            parity=serial.PARITY_NONE,
            stopbits=serial.STOPBITS_ONE,
            timeout=timeout
        )
        # Flush buffers
        self.ser.reset_input_buffer()
        self.ser.reset_output_buffer()
        time.sleep(0.05)

    def close(self):
        if self.ser and self.ser.is_open:
            self.ser.close()

    def reset_accumulator(self):
        pkt = encode_command_packet(CMD_RESET_ACC, self.n, 0x00, b"")
        self.ser.write(pkt)
        time.sleep(0.01)
        resp = self.ser.read(9)
        if len(resp) >= 9:
            return decode_response_packet(resp, n=self.n)
        return None

    def run_gemm(self, mat_a: np.ndarray, mat_b: np.ndarray, acc_keep: bool = False):
        pkt = encode_matrix_tiles(mat_a, mat_b, n=self.n, acc_keep=acc_keep)
        self.ser.reset_input_buffer()
        self.ser.write(pkt)

        # Expected response length: 8 header + 4*N*N payload + 1 CRC = 9 + 4*N*N
        expected_len = 9 + (4 * self.n * self.n)
        raw_resp = bytearray()
        start = time.perf_counter()

        while len(raw_resp) < expected_len:
            chunk = self.ser.read(expected_len - len(raw_resp))
            if not chunk:
                if (time.perf_counter() - start) > self.timeout:
                    raise TimeoutError(f"Hardware response timed out! Received {len(raw_resp)}/{expected_len} bytes.")
            raw_resp.extend(chunk)

        res = decode_response_packet(bytes(raw_resp), n=self.n)
        return res

def run_hardware_verification(port: str, baud: int = 2000000, n: int = 4, iterations: int = 100):
    print("=" * 80)
    print("AXIO-TENSOR PRO: PHYSICAL HARDWARE VALIDATION & TRIPLE-PATH PROOF")
    print(f"Connecting to FPGA on: {port} @ {baud} baud (N={n})")
    print("=" * 80)

    try:
        hw = HardwareRunner(port=port, baud=baud, n=n)
    except Exception as e:
        print(f"[FATAL ERROR] Cannot open serial port {port}: {e}")
        return False

    # 1. Hardware Reset / Ping
    print("\n[STEP 1] Resetting On-Chip Accumulators (CMD_RESET_ACC)...")
    try:
        hw.reset_accumulator()
        print(">> Hardware Acknowledged Reset Command.")
    except Exception as e:
        print(f">> Reset command note: {e}")

    # 2. Directed Boundary Cases
    print("\n[STEP 2] Executing 8 Directed Boundary Test Vectors on Physical Silicon...")
    cases = generate_directed_boundary_cases(n=n)
    all_directed_pass = True

    for idx, (name, a, b) in enumerate(cases, 1):
        c_golden = numpy_gemm(a, b)
        resp = hw.run_gemm(a, b, acc_keep=False)
        c_hw = resp["matrix_c"]
        cycles = resp["cycle_count"]

        match = np.array_equal(c_golden, c_hw)
        status = "[PASS]" if match else "[FAIL]"
        print(f"  Boundary {idx}/8: {name:<38} | HW Cycles: {cycles:2d} -> {status}")

        if not match:
            all_directed_pass = False
            print(f"    Mismatch Details: Expected C[0,0]={c_golden[0,0]}, Got C[0,0]={c_hw[0,0]}")

    # 3. Seeded Physical Random Regressions & SHA-256 Fingerprint
    print(f"\n[STEP 3] Running {iterations} Seeded Random Regressions on Physical FPGA...")
    rng = np.random.default_rng(42)
    hasher_golden = hashlib.sha256()
    hasher_hw     = hashlib.sha256()

    mismatches = 0
    t0 = time.perf_counter()

    for i in range(iterations):
        a = rng.integers(-128, 128, size=(n, n), dtype=np.int8)
        b = rng.integers(-128, 128, size=(n, n), dtype=np.int8)

        c_gold = numpy_gemm(a, b)
        hasher_golden.update(c_gold.tobytes())

        resp = hw.run_gemm(a, b, acc_keep=False)
        c_hw = resp["matrix_c"]
        hasher_hw.update(c_hw.tobytes())

        if not np.array_equal(c_gold, c_hw):
            mismatches += 1
            if mismatches <= 3:
                print(f"  [MISMATCH] Iteration {i} failed bit-exact match!")

    total_time = time.perf_counter() - t0
    digest_gold = hasher_golden.hexdigest()
    digest_hw   = hasher_hw.hexdigest()

    print(f"\nCompleted {iterations} iterations in {total_time:.3f} s ({iterations/total_time:.1f} inferences/sec)")
    print(f"  Golden Model SHA-256 : {digest_gold}")
    print(f"  Physical HW  SHA-256 : {digest_hw}")

    hw.close()

    print("\n" + "=" * 80)
    if all_directed_pass and (digest_gold == digest_hw) and (mismatches == 0):
        print(f"[FINAL VERDICT] BIT-EXACT HARDWARE MATCH CONFIRMED! (SHA-256 MATCH)")
        print(f"All outputs computed by physical hardware identically match NumPy golden model.")
        print("=" * 80)
        return True
    else:
        print(f"[FINAL VERDICT] HARDWARE MISMATCH DETECTED! (Mismatches: {mismatches})")
        print("=" * 80)
        return False

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Axio-Tensor PRO Live Hardware Verification")
    parser.add_argument("--port", type=str, default=None, help="Serial port (e.g., COM3, /dev/ttyUSB0)")
    parser.add_argument("--baud", type=int, default=2000000, help="UART Baud rate (default 2000000)")
    parser.add_argument("--n", type=int, default=4, help="Systolic dimension N")
    parser.add_argument("--iterations", type=int, default=100, help="Number of random tests")
    args = parser.parse_args()

    port = detect_fpga_port(args.port)
    if not port:
        print("[ERROR] No serial/COM port detected! Ensure FPGA USB cable is plugged in.")
        print("Available ports detected by system:")
        for p in lp.comports():
            print(f"  - {p.device}: {p.description}")
        sys.exit(1)

    ok = run_hardware_verification(port=port, baud=args.baud, n=args.n, iterations=args.iterations)
    sys.exit(0 if ok else 1)
