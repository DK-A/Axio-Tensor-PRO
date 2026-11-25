#!/usr/bin/env python3
"""
golden_model.py - Dual Bit-Exact Reference Models for Axio-Tensor PRO
Cross-validates pure Python scalar integer arithmetic against NumPy INT32 GEMM.
Ensures reference model integrity without relying on a single library implementation.
"""

import sys
import numpy as np

def pure_python_gemm(mat_a: list, mat_b: list, n: int = 4, k: int = 4) -> list:
    """
    Pure Python scalar integer implementation of signed INT8 matrix multiplication.
    Simulates exact 32-bit two's-complement accumulation.
    """
    mat_c = [[0 for _ in range(n)] for _ in range(n)]
    
    for r in range(n):
        for c in range(n):
            acc = 0
            for step_k in range(k):
                a_val = int(mat_a[r][step_k])
                b_val = int(mat_b[step_k][c])
                
                # Check INT8 signed boundaries [-128, +127]
                if not (-128 <= a_val <= 127) or not (-128 <= b_val <= 127):
                    raise ValueError(f"Operand out of INT8 range: A={a_val}, B={b_val}")
                
                prod = a_val * b_val
                # Check theoretical product bound [-16256, +16384]
                if not (-16256 <= prod <= 16384):
                    raise ValueError(f"Product out of theoretical bound [-16256, +16384]: {prod}")
                
                acc += prod
                
            # Convert to signed 32-bit integer with exact wrap-around
            acc = acc & 0xFFFFFFFF
            if acc >= 0x80000000:
                acc -= 0x100000000
                
            mat_c[r][c] = acc
            
    return mat_c

def numpy_gemm(mat_a: np.ndarray, mat_b: np.ndarray) -> np.ndarray:
    """
    NumPy-based bit-exact signed INT8 GEMM with 32-bit signed accumulation.
    """
    a_int32 = mat_a.astype(np.int32)
    b_int32 = mat_b.astype(np.int32)
    c_int32 = np.matmul(a_int32, b_int32, dtype=np.int32)
    return c_int32

def verify_dual_golden_models(n: int = 4, iterations: int = 500, seed: int = 42) -> bool:
    """
    Verifies that pure Python scalar loop and NumPy reference are 100% bit-exact across
    random signed integer distributions.
    """
    rng = np.random.default_rng(seed)
    print(f"[GOLDEN CHECK] Running {iterations} dual-model equivalence tests (N={n}, seed={seed})...")
    
    for i in range(iterations):
        a_np = rng.integers(-128, 128, size=(n, n), dtype=np.int8)
        b_np = rng.integers(-128, 128, size=(n, n), dtype=np.int8)
        
        c_numpy = numpy_gemm(a_np, b_np)
        c_python = pure_python_gemm(a_np.tolist(), b_np.tolist(), n=n, k=n)
        c_python_np = np.array(c_python, dtype=np.int32)
        
        if not np.array_equal(c_numpy, c_python_np):
            print(f"[FAIL] Dual golden model mismatch at iteration {i}!")
            return False
            
    print(f"[PASS] 100% Bit-Exact Equivalence confirmed between Pure Python and NumPy ({iterations}/{iterations} runs).")
    return True

if __name__ == "__main__":
    success = verify_dual_golden_models()
    sys.exit(0 if success else 1)
