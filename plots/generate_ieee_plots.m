%% ==============================================================================
%% Axio-Tensor PRO: IEEE Standard Publication Plot Generation Script
%% Project: Axio-Tensor PRO (Spartan-7 Edge TinyML Accelerator)
%% Output: 300 DPI Vector/TIFF/PNG publication-ready figures complying with
%%         IEEE formatting guidelines (Times font, standard column widths).
%% ==============================================================================

clear; clc; close all;

% Set IEEE Publication Default Graphics Styling
set(groot, 'DefaultTextFontName', 'Times New Roman');
set(groot, 'DefaultAxesFontName', 'Times New Roman');
set(groot, 'DefaultAxesFontSize', 9);
set(groot, 'DefaultTextFontSize', 9);
set(groot, 'DefaultAxesLineWidth', 0.8);
set(groot, 'DefaultLineLineWidth', 1.2);
set(groot, 'DefaultAxesBox', 'on');
set(groot, 'DefaultAxesTickDir', 'in');

output_dir = './plots';
if ~exist(output_dir, 'dir')
    mkdir(output_dir);
end

%% ==============================================================================
%% FIGURE 1: Pareto Design-Space Exploration (Throughput vs Area vs Timing Slack)
%% ==============================================================================
fig1 = figure('Units', 'inches', 'Position', [1, 1, 3.5, 2.8], 'Color', 'w');

% Data points from real DSE evaluation
% Configurations: [N, Freq(MHz), DSPs, LUTs, WNS(ns), Latency(us), GOPS, Status]
dsps_pass   = [4, 4, 4, 16, 16, 64];
gops_pass   = [0.288, 0.432, 0.576, 0.873, 1.309, 2.504];
labels_pass = {'2x2 @100M', '2x2 @150M', '2x2 @200M', '4x4 @100M', '4x4 @150M', '8x8 @100M*'};

dsps_fail   = [16, 64, 64];
gops_fail   = [1.745, 3.757, 5.009];
labels_fail = {'4x4 @200M', '8x8 @150M', '8x8 @200M'};

% Scatter plot
h1 = scatter(dsps_pass, gops_pass, 45, 'b', 'filled', 'DisplayName', 'Timing Closed (WNS \geq 0)');
hold on; grid on; set(gca, 'GridLineStyle', ':', 'GridAlpha', 0.6);
h2 = scatter(dsps_fail, gops_fail, 45, 'r', 'x', 'LineWidth', 1.5, 'DisplayName', 'Timing Failed (WNS < 0)');

% Pareto Frontier line connecting feasible Pareto optimal points
pareto_dsps = [4, 16, 64];
pareto_gops = [0.576, 1.309, 2.504];
plot(pareto_dsps, pareto_gops, 'b--', 'LineWidth', 1.0, 'DisplayName', 'Pareto Frontier');

% Annotate Points
for i = 1:length(dsps_pass)
    text(dsps_pass(i)+1.5, gops_pass(i)-0.05, labels_pass{i}, 'FontSize', 7.5, 'FontName', 'Times New Roman');
end
for i = 1:length(dsps_fail)
    text(dsps_fail(i)+1.5, gops_fail(i)-0.1, [labels_fail{i} ' (WNS<0)'], 'FontSize', 7.5, 'Color', [0.7 0 0], 'FontName', 'Times New Roman');
end

% Highlight Winner
plot(64, 2.504, 'kp', 'MarkerSize', 11, 'MarkerFaceColor', 'y', 'DisplayName', 'Pareto Winner (8x8@100MHz)');

xlabel('Silicon Resource Footprint (DSP48E1 Slices)');
ylabel('Sustained Compute Throughput (GOPS)');
xlim([0 85]); ylim([0 5.5]);
title('(a) Design-Space Pareto Exploration', 'FontSize', 9.5, 'FontWeight', 'bold');
legend('Location', 'northwest', 'FontSize', 7.5);

exportgraphics(fig1, fullfile(output_dir, 'fig1_pareto_dse.png'), 'Resolution', 300);
exportgraphics(fig1, fullfile(output_dir, 'fig1_pareto_dse.pdf'), 'ContentType', 'vector');


%% ==============================================================================
%% FIGURE 2: Three-Tier Latency Breakdown (Honest Log-Scale Analysis)
%% ==============================================================================
fig2 = figure('Units', 'inches', 'Position', [1, 1, 3.5, 2.6], 'Color', 'w');

tiers = {'On-Chip Core\n(Link-Free)', 'Host CPU Ref.\n(ARM/x86 BLAS)', 'UART Round-Trip\n(2 Mbaud)'};
latencies_ns = [110, 77.9, 565000]; % Nanoseconds

b = bar(latencies_ns, 0.45, 'FaceColor', 'flat');
b.CData(1,:) = [0.12 0.53 0.90]; % Blue: FPGA
b.CData(2,:) = [0.45 0.45 0.45]; % Gray: CPU
b.CData(3,:) = [0.90 0.35 0.15]; % Orange: UART

set(gca, 'YScale', 'log');
grid on; set(gca, 'GridLineStyle', ':', 'GridAlpha', 0.6);
set(gca, 'XTickLabel', {'Core Compute', 'CPU BLAS', 'UART Link'}, 'FontSize', 8.5);

ylabel('Execution Latency (ns, Log-Scale)');
ylim([10 2e6]);
title('(b) Three-Tier Honest Latency Breakdown', 'FontSize', 9.5, 'FontWeight', 'bold');

% Annotate Exact Values
text(1, 180, '110 ns', 'HorizontalAlignment', 'center', 'FontSize', 8, 'FontWeight', 'bold');
text(2, 130, '77.9 ns', 'HorizontalAlignment', 'center', 'FontSize', 8, 'FontWeight', 'bold');
text(3, 900000, '565 \mus (99.9%)', 'HorizontalAlignment', 'center', 'FontSize', 8, 'Color', [0.8 0.2 0], 'FontWeight', 'bold');

exportgraphics(fig2, fullfile(output_dir, 'fig2_latency_tiers.png'), 'Resolution', 300);
exportgraphics(fig2, fullfile(output_dir, 'fig2_latency_tiers.pdf'), 'ContentType', 'vector');


%% ==============================================================================
%% FIGURE 3: Energy Efficiency Comparison (GOPS / Watt)
%% ==============================================================================
fig3 = figure('Units', 'inches', 'Position', [1, 1, 3.5, 2.6], 'Color', 'w');

platforms = {'Host CPU (BLAS)', 'Axio-Tensor PRO (4x4)', 'Axio-Tensor PRO (8x8)'};
gops_per_w = [0.11, 26.5, 20.6];

b3 = bar(gops_per_w, 0.45, 'FaceColor', [0.15 0.65 0.35]);
grid on; set(gca, 'GridLineStyle', ':', 'GridAlpha', 0.6);
set(gca, 'XTickLabel', {'Host CPU', 'FPGA (4x4)', 'FPGA (8x8)'}, 'FontSize', 8.5);

ylabel('Energy Efficiency (GOPS / Watt)');
ylim([0 32]);
title('(c) Compute Energy Efficiency Comparison', 'FontSize', 9.5, 'FontWeight', 'bold');

% Annotations
text(1, 1.5, '0.11', 'HorizontalAlignment', 'center', 'FontSize', 8.5, 'FontWeight', 'bold');
text(2, 27.8, '26.5 (240x)', 'HorizontalAlignment', 'center', 'FontSize', 8.5, 'Color', [0 0.5 0], 'FontWeight', 'bold');
text(3, 21.9, '20.6 (187x)', 'HorizontalAlignment', 'center', 'FontSize', 8.5, 'Color', [0 0.5 0], 'FontWeight', 'bold');

exportgraphics(fig3, fullfile(output_dir, 'fig3_energy_efficiency.png'), 'Resolution', 300);
exportgraphics(fig3, fullfile(output_dir, 'fig3_energy_efficiency.pdf'), 'ContentType', 'vector');


%% ==============================================================================
%% FIGURE 4: Timing Slack (WNS) vs Operating Frequency across Array Geometries
%% ==============================================================================
fig4 = figure('Units', 'inches', 'Position', [1, 1, 3.5, 2.8], 'Color', 'w');

freqs = [100, 150, 200];
wns_2x2 = [5.30, 1.97, 0.30];
wns_4x4 = [4.60, 1.27, -0.40];
wns_8x8 = [3.20, -0.13, -1.80];

plot(freqs, wns_2x2, 'o-s', 'Color', [0.1 0.6 0.2], 'LineWidth', 1.2, 'MarkerFaceColor', [0.1 0.6 0.2], 'DisplayName', '2\times2 Array');
hold on; grid on; set(gca, 'GridLineStyle', ':', 'GridAlpha', 0.6);
plot(freqs, wns_4x4, 's-b', 'LineWidth', 1.2, 'MarkerFaceColor', 'b', 'DisplayName', '4\times4 Array');
plot(freqs, wns_8x8, '^-r', 'LineWidth', 1.2, 'MarkerFaceColor', 'r', 'DisplayName', '8\times8 Array');

% Zero Slack Boundary Line
yline(0, 'k--', 'LineWidth', 1.0, 'DisplayName', 'Timing Closure Threshold (WNS = 0)');

xlabel('Clock Frequency (MHz)');
ylabel('Worst Negative Slack, WNS (ns)');
xlim([90 210]); ylim([-2.2 6.0]);
title('(d) Timing Closure Slack vs. Frequency', 'FontSize', 9.5, 'FontWeight', 'bold');
legend('Location', 'southwest', 'FontSize', 7.5);

exportgraphics(fig4, fullfile(output_dir, 'fig4_timing_slack.png'), 'Resolution', 300);
exportgraphics(fig4, fullfile(output_dir, 'fig4_timing_slack.pdf'), 'ContentType', 'vector');

disp('Successfully exported IEEE publication-ready figures in vector PDF and 300 DPI PNG.');
