import matplotlib
matplotlib.use("Agg") # Non-interactive headless backend
import os
import matplotlib.pyplot as plt

# Configure IEEE style standards
plt.rcParams.update({
    "font.family": "serif",
    "font.serif": ["Times New Roman", "DejaVu Serif"],
    "font.size": 8.5,
    "axes.labelsize": 9,
    "axes.titlesize": 9.5,
    "legend.fontsize": 7.5,
    "xtick.labelsize": 8,
    "ytick.labelsize": 8,
    "figure.dpi": 300,
    "axes.linewidth": 0.8,
    "grid.linewidth": 0.5,
    "grid.linestyle": ":",
    "grid.alpha": 0.7,
    "mathtext.fontset": "stix"
})

output_dir = "plots"
os.makedirs(output_dir, exist_ok=True)

# -------------------------------------------------------------------------
# Figure 1: Pareto Design Space Exploration
# -------------------------------------------------------------------------
fig1, ax1 = plt.subplots(figsize=(3.5, 2.7))
dsps_pass = [4, 4, 4, 16, 16, 64]
gops_pass = [0.288, 0.432, 0.576, 0.873, 1.309, 2.504]

dsps_fail = [16, 64, 64]
gops_fail = [1.745, 3.757, 5.009]

ax1.scatter(dsps_pass, gops_pass, color="#1f77b4", s=40, zorder=3, label="Timing Met (WNS ≥ 0)")
ax1.scatter(dsps_fail, gops_fail, color="#d62728", marker="x", s=50, linewidth=1.5, zorder=3, label="Timing Violated (WNS < 0)")

# Pareto frontier
pareto_d = [4, 16, 64]
pareto_g = [0.576, 1.309, 2.504]
ax1.plot(pareto_d, pareto_g, linestyle="--", color="#1f77b4", linewidth=1.0, zorder=2, label="Pareto Frontier")

# Winner highlight
ax1.scatter([64], [2.504], color="#ff7f0e", marker="*", s=110, edgecolor="black", linewidth=0.6, zorder=4, label="Pareto Winner (8×8)")

ax1.annotate("2×2@200M", (4, 0.576), textcoords="offset points", xytext=(5,-2), fontsize=6.8)
ax1.annotate("4×4@150M", (16, 1.309), textcoords="offset points", xytext=(5,-2), fontsize=6.8)
ax1.annotate("8×8@100M*", (64, 2.504), textcoords="offset points", xytext=(-45,4), fontsize=6.8, fontweight="bold", color="#ff7f0e")
ax1.annotate("4×4@200M (WNS<0)", (16, 1.745), textcoords="offset points", xytext=(5,-2), fontsize=6.5, color="#d62728")
ax1.annotate("8×8@150M (WNS<0)", (64, 3.757), textcoords="offset points", xytext=(-65,2), fontsize=6.5, color="#d62728")

ax1.set_xlabel("Silicon Footprint (DSP48E1 Slices)")
ax1.set_ylabel("Sustained Throughput (GOPS)")
ax1.set_title("(a) Design-Space Pareto Frontier", fontweight="bold")
ax1.set_xlim(0, 85)
ax1.set_ylim(0, 5.5)
ax1.grid(True)
ax1.legend(loc="upper left", framealpha=0.9)
plt.tight_layout()
plt.savefig(os.path.join(output_dir, "fig1_pareto_dse.png"), dpi=300)
plt.savefig(os.path.join(output_dir, "fig1_pareto_dse.pdf"))
plt.close()

# -------------------------------------------------------------------------
# Figure 2: Three-Tier Latency Breakdown (Log Scale)
# -------------------------------------------------------------------------
fig2, ax2 = plt.subplots(figsize=(3.5, 2.5))
categories = ["Core Compute\n(Link-Free)", "Host CPU\n(Vector BLAS)", "UART Link\n(2 Mbaud)"]
latencies_ns = [110, 77.9, 565000]
colors = ["#1f77b4", "#7f7f7f", "#d62728"]

bars = ax2.bar(categories, latencies_ns, color=colors, width=0.45, edgecolor="black", linewidth=0.5, zorder=3)
ax2.set_yscale("log")
ax2.set_ylabel("Execution Latency (ns, Log-Scale)")
ax2.set_ylim(10, 3e6)
ax2.set_title("(b) Three-Tier Honest Latency Breakdown", fontweight="bold")
ax2.grid(True, which="both", axis="y")

ax2.text(0, 180, "110 ns", ha="center", va="bottom", fontsize=7.5, fontweight="bold")
ax2.text(1, 130, "77.9 ns", ha="center", va="bottom", fontsize=7.5, fontweight="bold")
ax2.text(2, 850000, "565 µs (99.9%)", ha="center", va="bottom", fontsize=7.5, fontweight="bold", color="#d62728")

plt.tight_layout()
plt.savefig(os.path.join(output_dir, "fig2_latency_tiers.png"), dpi=300)
plt.savefig(os.path.join(output_dir, "fig2_latency_tiers.pdf"))
plt.close()

# -------------------------------------------------------------------------
# Figure 3: Energy Efficiency Comparison
# -------------------------------------------------------------------------
fig3, ax3 = plt.subplots(figsize=(3.5, 2.5))
platforms = ["Host CPU\n(BLAS)", "Axio-Tensor\n(4×4 @ 150M)", "Axio-Tensor\n(8×8 @ 100M)"]
efficiency = [0.11, 26.5, 20.6]
colors = ["#7f7f7f", "#2ca02c", "#1f77b4"]

bars3 = ax3.bar(platforms, efficiency, color=colors, width=0.45, edgecolor="black", linewidth=0.5, zorder=3)
ax3.set_ylabel("Energy Efficiency (GOPS / Watt)")
ax3.set_ylim(0, 32)
ax3.set_title("(c) Energy Efficiency Comparison", fontweight="bold")
ax3.grid(True, axis="y")

ax3.text(0, 1.0, "0.11", ha="center", va="bottom", fontsize=8, fontweight="bold")
ax3.text(1, 27.2, "26.5 (240×)", ha="center", va="bottom", fontsize=8, fontweight="bold", color="#2ca02c")
ax3.text(2, 21.3, "20.6 (187×)", ha="center", va="bottom", fontsize=8, fontweight="bold", color="#1f77b4")

plt.tight_layout()
plt.savefig(os.path.join(output_dir, "fig3_energy_efficiency.png"), dpi=300)
plt.savefig(os.path.join(output_dir, "fig3_energy_efficiency.pdf"))
plt.close()

# -------------------------------------------------------------------------
# Figure 4: Timing Slack (WNS) vs Clock Frequency
# -------------------------------------------------------------------------
fig4, ax4 = plt.subplots(figsize=(3.5, 2.7))
freqs = [100, 150, 200]
wns_2x2 = [5.30, 1.97, 0.30]
wns_4x4 = [4.60, 1.27, -0.40]
wns_8x8 = [3.20, -0.13, -1.80]

ax4.plot(freqs, wns_2x2, "o-", color="#2ca02c", linewidth=1.2, markersize=5, label="2×2 Mesh", zorder=3)
ax4.plot(freqs, wns_4x4, "s-", color="#1f77b4", linewidth=1.2, markersize=5, label="4×4 Mesh", zorder=3)
ax4.plot(freqs, wns_8x8, "^-", color="#d62728", linewidth=1.2, markersize=5, label="8×8 Mesh", zorder=3)

ax4.axhline(0, color="black", linestyle="--", linewidth=0.9, zorder=2, label="Closure Boundary (WNS=0)")

ax4.set_xlabel("Operating Clock Frequency (MHz)")
ax4.set_ylabel("Worst Negative Slack, WNS (ns)")
ax4.set_title("(d) Timing Closure Slack vs. Frequency", fontweight="bold")
ax4.set_xlim(90, 210)
ax4.set_ylim(-2.2, 6.2)
ax4.grid(True)
ax4.legend(loc="lower left", framealpha=0.9)

plt.tight_layout()
plt.savefig(os.path.join(output_dir, "fig4_timing_slack.png"), dpi=300)
plt.savefig(os.path.join(output_dir, "fig4_timing_slack.pdf"))
plt.close()

# -------------------------------------------------------------------------
# Figure 5: Multi-Panel Combined IEEE Figure
# -------------------------------------------------------------------------
fig5, ((p1, p2), (p3, p4)) = plt.subplots(2, 2, figsize=(7.0, 5.0))

# Subplot 1
p1.scatter(dsps_pass, gops_pass, color="#1f77b4", s=35, zorder=3, label="Met (WNS≥0)")
p1.scatter(dsps_fail, gops_fail, color="#d62728", marker="x", s=40, linewidth=1.2, zorder=3, label="Fail (WNS<0)")
p1.plot(pareto_d, pareto_g, linestyle="--", color="#1f77b4", linewidth=1.0, zorder=2)
p1.scatter([64], [2.504], color="#ff7f0e", marker="*", s=90, edgecolor="black", zorder=4)
p1.set_xlabel("DSP48E1 Slices")
p1.set_ylabel("Throughput (GOPS)")
p1.set_title("(a) Pareto Exploration Frontier", fontweight="bold")
p1.grid(True)
p1.legend(loc="upper left", fontsize=7)

# Subplot 2
p2.bar(categories, latencies_ns, color=colors, width=0.45, edgecolor="black", linewidth=0.5, zorder=3)
p2.set_yscale("log")
p2.set_ylabel("Latency (ns, Log)")
p2.set_title("(b) Three-Tier Honest Latency", fontweight="bold")
p2.grid(True, which="both", axis="y")
p2.text(0, 180, "110 ns", ha="center", fontsize=7, fontweight="bold")
p2.text(1, 130, "77.9 ns", ha="center", fontsize=7, fontweight="bold")
p2.text(2, 850000, "565 µs", ha="center", fontsize=7, fontweight="bold", color="#d62728")

# Subplot 3
p3.bar(platforms, efficiency, color=["#7f7f7f", "#2ca02c", "#1f77b4"], width=0.45, edgecolor="black", linewidth=0.5, zorder=3)
p3.set_ylabel("Efficiency (GOPS / W)")
p3.set_title("(c) Energy Efficiency Comparison", fontweight="bold")
p3.grid(True, axis="y")
p3.text(0, 1.0, "0.11", ha="center", fontsize=7.5, fontweight="bold")
p3.text(1, 27.2, "26.5", ha="center", fontsize=7.5, fontweight="bold", color="#2ca02c")
p3.text(2, 21.3, "20.6", ha="center", fontsize=7.5, fontweight="bold", color="#1f77b4")

# Subplot 4
p4.plot(freqs, wns_2x2, "o-", color="#2ca02c", linewidth=1.1, markersize=4, label="2×2")
p4.plot(freqs, wns_4x4, "s-", color="#1f77b4", linewidth=1.1, markersize=4, label="4×4")
p4.plot(freqs, wns_8x8, "^-", color="#d62728", linewidth=1.1, markersize=4, label="8×8")
p4.axhline(0, color="black", linestyle="--", linewidth=0.8)
p4.set_xlabel("Clock Frequency (MHz)")
p4.set_ylabel("Slack WNS (ns)")
p4.set_title("(d) Timing Closure Sensitivity", fontweight="bold")
p4.grid(True)
p4.legend(loc="lower left", fontsize=7)

plt.tight_layout()
plt.savefig(os.path.join(output_dir, "fig_ieee_combined_matrix.png"), dpi=300)
plt.savefig(os.path.join(output_dir, "fig_ieee_combined_matrix.pdf"))
plt.close()

print("[SUCCESS] All IEEE format figures generated in 300 DPI PNG and vector PDF format.")
