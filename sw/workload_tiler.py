#!/usr/bin/env python3
"""
workload_tiler.py - TinyML Layer Matrix Partitioner with Multi-Tile acc_keep
Enables executing real non-square TinyML layers (MobileNet Conv2D and Keyword Spotting FC)
across parameterized systolic hardware tiles with multi-chunk accumulation.
"""

import numpy as np
from golden_model import numpy_gemm

WORKLOADS = {
    "tinyml_conv2d": {
        "name": "MobileNet TinyML Conv2D Layer Patch",
        "M": 16,
        "K": 9,
        "N": 16,
        "description": "3x3 depthwise-separable conv kernel unrolled across 16 channels"
    },
    "kws_fc": {
        "name": "Speech Keyword Spotting Fully-Connected Layer",
        "M": 32,
        "K": 16,
        "N": 16,
        "description": "Dense audio feature classification layer"
    },
    "micro_gemm": {
        "name": "Standard Micro-GEMM Benchmark",
        "M": 4,
        "K": 4,
        "N": 4,
        "description": "Direct 4x4 matrix multiplication tile"
    }
}

class WorkloadTiler:
    def __init__(self, tile_size: int = 4):
        self.tile_size = tile_size

    def partition_and_execute(self, mat_a: np.ndarray, mat_b: np.ndarray, runner_fn=None):
        """
        Tiles an M x K x N matrix multiplication into tile_size x tile_size chunks.
        Uses acc_keep flag across K-dimension splits to accumulate partial sums.
        
        runner_fn(sub_a, sub_b, acc_keep) -> sub_c (if None, uses simulated tile execution)
        """
        M, K_a = mat_a.shape
        K_b, N = mat_b.shape
        assert K_a == K_b, f"Inner dimension mismatch: {K_a} vs {K_b}"
        K = K_a
        T = self.tile_size

        # Pad matrices to multiples of T
        pad_m = (T - (M % T)) % T
        pad_k = (T - (K % T)) % T
        pad_n = (T - (N % T)) % T

        a_padded = np.pad(mat_a, ((0, pad_m), (0, pad_k)), mode='constant', constant_values=0)
        b_padded = np.pad(mat_b, ((0, pad_k), (0, pad_n)), mode='constant', constant_values=0)

        M_pad, K_pad = a_padded.shape
        _, N_pad = b_padded.shape

        c_accumulated = np.zeros((M_pad, N_pad), dtype=np.int32)
        total_tile_transactions = 0

        # Iterate over output tiles (m_tile, n_tile)
        for m_idx in range(0, M_pad, T):
            for n_idx in range(0, N_pad, T):
                # Accumulate across inner dimension K
                for k_step, k_idx in enumerate(range(0, K_pad, T)):
                    sub_a = a_padded[m_idx:m_idx+T, k_idx:k_idx+T]
                    sub_b = b_padded[k_idx:k_idx+T, n_idx:n_idx+T]
                    
                    # First K-chunk clears accumulators (acc_keep=False)
                    # Subsequent K-chunks retain accumulators (acc_keep=True)
                    acc_keep = (k_step > 0)
                    total_tile_transactions += 1

                    if runner_fn is not None:
                        sub_c = runner_fn(sub_a, sub_b, acc_keep=acc_keep)
                    else:
                        # Simulated hardware execution with exact int32 accumulation
                        prod_tile = numpy_gemm(sub_a, sub_b)
                        if not acc_keep:
                            c_accumulated[m_idx:m_idx+T, n_idx:n_idx+T] = prod_tile
                        else:
                            c_accumulated[m_idx:m_idx+T, n_idx:n_idx+T] += prod_tile

        # Unpad result to original (M, N)
        c_final = c_accumulated[:M, :N]
        return c_final, total_tile_transactions

def test_workload_tiling(workload_key: str = "tinyml_conv2d", seed: int = 42):
    """
    Validates that tiled execution of the given TinyML workload matches the golden NumPy reference.
    """
    cfg = WORKLOADS[workload_key]
    M, K, N = cfg["M"], cfg["K"], cfg["N"]
    print(f"\n[WORKLOAD TEST] Testing {cfg['name']} ({M}x{K}x{N}) on 4x4 Systolic Tiles...")

    rng = np.random.default_rng(seed)
    mat_a = rng.integers(-128, 128, size=(M, K), dtype=np.int8)
    mat_b = rng.integers(-128, 128, size=(K, N), dtype=np.int8)

    # Reference full matrix product
    c_golden = np.matmul(mat_a.astype(np.int32), mat_b.astype(np.int32), dtype=np.int32)

    # Tiled execution with acc_keep
    tiler = WorkloadTiler(tile_size=4)
    c_tiled, tile_count = tiler.partition_and_execute(mat_a, mat_b)

    if np.array_equal(c_golden, c_tiled):
        print(f"[PASS] {cfg['name']} successfully partitioned across {tile_count} hardware tiles.")
        print(f"       Result is 100% Bit-Exact with NumPy Golden Model!")
        return True
    else:
        print(f"[FAIL] Tiled matrix product mismatch!")
        diff = np.max(np.abs(c_golden - c_tiled))
        print(f"       Max absolute difference: {diff}")
        return False

if __name__ == "__main__":
    for wl in WORKLOADS:
        test_workload_tiling(wl)
