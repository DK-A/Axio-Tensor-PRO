## ============================================================================
## File: arty_s7.xdc
## Project: Axio-Tensor PRO
## Target: Digilent Arty S7 (Spartan-7 XC7S25 / XC7S50 - CSGA324)
## Description: Physical Pin Constraints and Primary 100 MHz Timing Constraints
## ============================================================================

## ----------------------------------------------------------------------------
## Primary 100 MHz System Clock
## ----------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN R2    IOSTANDARD SSTL135 } [get_ports { clk }];
create_clock -add -name sys_clk_pin -period 10.000 -waveform {0.000 5.000} [get_ports { clk }];

## ----------------------------------------------------------------------------
## Active-Low Reset Push-Button (btn[0])
## ----------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN C18   IOSTANDARD LVCMOS33 } [get_ports { rst_n }];

## ----------------------------------------------------------------------------
## High-Speed USB-UART Interface (FT2232H Bridge up to 2 Mbaud / 3 Mbaud)
## Note: From FPGA perspective:
##   - V12 is FPGA Input (Host TX -> Board RX)
##   - R12 is FPGA Output (Board TX -> Host RX)
## ----------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN V12   IOSTANDARD LVCMOS33 } [get_ports { uart_rx }];
set_property -dict { PACKAGE_PIN R12   IOSTANDARD LVCMOS33 } [get_ports { uart_tx }];

## ----------------------------------------------------------------------------
## 4 User Green LEDs (FSM State & Status Tracking)
## ----------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN E18   IOSTANDARD LVCMOS33 } [get_ports { led[0] }];
set_property -dict { PACKAGE_PIN F13   IOSTANDARD LVCMOS33 } [get_ports { led[1] }];
set_property -dict { PACKAGE_PIN E13   IOSTANDARD LVCMOS33 } [get_ports { led[2] }];
set_property -dict { PACKAGE_PIN H14   IOSTANDARD LVCMOS33 } [get_ports { led[3] }];

## ----------------------------------------------------------------------------
## RGB LED 0 (Status Indicator: Blue=Compute, Green=Pass, Red=Overflow/Error)
## ----------------------------------------------------------------------------
set_property -dict { PACKAGE_PIN J15   IOSTANDARD LVCMOS33 } [get_ports { rgb_led_r }];
set_property -dict { PACKAGE_PIN G17   IOSTANDARD LVCMOS33 } [get_ports { rgb_led_g }];
set_property -dict { PACKAGE_PIN F15   IOSTANDARD LVCMOS33 } [get_ports { rgb_led_b }];

## ----------------------------------------------------------------------------
## Configuration and Bitstream Properties
## ----------------------------------------------------------------------------
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property CFGBVS VCCO [current_design]
