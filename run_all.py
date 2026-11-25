#!/usr/bin/env python3
"""
run_all.py - Master Reproducibility CLI Runner for Axio-Tensor PRO
Executes the full engineering workflow in a single command:
  1. Golden Model Equivalence Check (Pure Python vs NumPy)
  2. 8 Directed Boundary Test Cases
  3. 1,000 Seeded Random Regressions with SHA-256 Verification Digest
  4. 6-Class Hardware Mutation Testing Suite
  5. Multi-Tile TinyML Workload Execution (MobileNet Conv2D & Keyword Spotting)
  6. Automated Design-Space Optimization (Arty S7-25 vs S7-50 Pareto Frontiers)
  7. Three-Tier Latency & GOPS/W Profiling
"""

import sys
import argparse
import subprocess

def run_step(title: str, cmd: list):
    print("\n" + "=" * 82)
    print(f"STEP: {title}")
    print("=" * 82)
    res = subprocess.run(cmd)
    if res.returncode != 0:
        print(f"\n[ERROR] Step '{title}' failed with return code {res.returncode}")
        return False
    return True

def main():
    parser = argparse.ArgumentParser(description="Axio-Tensor PRO Master Runner")
    parser.add_argument("--all", action="store_true", default=True, help="Run complete end-to-end verification")
    parser.add_argument("--verify-only", action="store_true", help="Run only verification engine & regressions")
    parser.add_argument("--optimize-only", action="store_true", help="Run only design-space optimizer")
    parser.add_argument("--benchmark-only", action="store_true", help="Run only CPU vs FPGA latency benchmark")
    parser.add_argument("--gui", action="store_true", help="Launch live graphical dashboard")
    args = parser.parse_args()

    if args.gui:
        print("[LAUNCH] Opening Axio-Tensor PRO Live Visual Cockpit...")
        subprocess.run([sys.executable, "sw/visual_dashboard.py"])
        return

    success = True

    if args.verify_only or args.all:
        success = success and run_step("Dual Golden Model Cross-Validation", [sys.executable, "sw/golden_model.py"])
        success = success and run_step("Directed Boundary & Seeded Regression Suite", [sys.executable, "sw/verification_engine.py", "--mode", "all", "--iterations", "1000"])
        success = success and run_step("Real TinyML Workload Tiling (Conv2D & FC)", [sys.executable, "sw/workload_tiler.py"])

    if args.optimize_only or args.all:
        success = success and run_step("Design-Space Optimization: Arty S7-25", [sys.executable, "sw/optimization_engine.py", "--fpga", "Arty_S7_25", "--workload", "tinyml_conv2d"])
        success = success and run_step("Design-Space Optimization: Arty S7-50", [sys.executable, "sw/optimization_engine.py", "--fpga", "Arty_S7_50", "--workload", "tinyml_conv2d"])

    if args.benchmark_only or args.all:
        success = success and run_step("Three-Tier Latency & GOPS/W Profiling", [sys.executable, "sw/benchmark_cpu.py"])

    print("\n" + "=" * 82)
    if success:
        print("ALL VERIFICATION, OPTIMIZATION & PROFILING STEPS PASSED SUCCESSFULLY (100% BIT-EXACT)")
    else:
        print("ONE OR MORE VERIFICATION STEPS REPORTED FAILURES!")
    print("=" * 82)

    sys.exit(0 if success else 1)

if __name__ == "__main__":
    main()
