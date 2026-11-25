#!/usr/bin/env python3
"""
protocol.py - Binary Packet Protocol and CRC-8 Engine for Axio-Tensor PRO
Defines structured frame encoding and decoding for Host-FPGA communication.
CRC-8 Polynomial: x^8 + x^2 + x + 1 (0x07).
"""

import struct
import numpy as np

SOF_CMD  = 0xAA
SOF_RESP = 0x55

CMD_COMPUTE   = 0x01
CMD_BENCHMARK = 0x02
CMD_RESET_ACC = 0x03

FLAG_ACC_KEEP = 0x01
FLAG_REQUANT  = 0x02
FLAG_BANK_SEL = 0x04

def calc_crc8(data: bytes, init: int = 0x00) -> int:
    """
    Computes CRC-8 using polynomial x^8 + x^2 + x + 1 (0x07).
    Bit-exact equivalent to rtl/crc8.sv.
    """
    crc = init
    for byte in data:
        crc ^= byte
        for _ in range(8):
            if crc & 0x80:
                crc = ((crc << 1) ^ 0x07) & 0xFF
            else:
                crc = (crc << 1) & 0xFF
    return crc

def encode_command_packet(cmd: int, n: int, flags: int, payload: bytes) -> bytes:
    """
    Constructs a binary command frame:
    [SOF: 0xAA] [CMD: 1B] [N: 1B] [FLAGS: 1B] [LENGTH: 2B (BE)] [PAYLOAD] [CRC8: 1B]
    """
    length = len(payload)
    header = struct.pack(">BBBxH", SOF_CMD, cmd, n, length) # 6 bytes header
    # Correct header format: SOF, CMD, N, FLAGS, LENGTH (BE)
    header = bytes([SOF_CMD, cmd, n, flags, (length >> 8) & 0xFF, length & 0xFF])
    packet_no_crc = header + payload
    crc = calc_crc8(packet_no_crc)
    return packet_no_crc + bytes([crc])

def encode_matrix_tiles(mat_a: np.ndarray, mat_b: np.ndarray, n: int = 4, acc_keep: bool = False, bank_sel: int = 0) -> bytes:
    """
    Serializes Matrix A and Matrix B into bytes and wraps into a CMD_COMPUTE packet.
    """
    flags = 0
    if acc_keep:
        flags |= FLAG_ACC_KEEP
    if bank_sel == 1:
        flags |= FLAG_BANK_SEL
        
    # Cast to signed 8-bit bytes
    bytes_a = mat_a.astype(np.int8).tobytes()
    bytes_b = mat_b.astype(np.int8).tobytes()
    payload = bytes_a + bytes_b
    
    return encode_command_packet(CMD_COMPUTE, n, flags, payload)

def decode_response_packet(raw_bytes: bytes, n: int = 4) -> dict:
    """
    Parses an FPGA response frame:
    [SOF: 0x55] [STATUS: 1B] [CYCLES: 4B (BE)] [LENGTH: 2B (BE)] [PAYLOAD: 4*N*N] [CRC8: 1B]
    """
    if len(raw_bytes) < 9:
        raise ValueError(f"Packet too short: {len(raw_bytes)} bytes")
        
    sof = raw_bytes[0]
    if sof != SOF_RESP:
        raise ValueError(f"Invalid Response SOF: expected 0x55, got {hex(sof)}")
        
    status = raw_bytes[1]
    done_bit         = bool(status & 0x01)
    overflow_sticky  = bool(status & 0x02)
    crc_err          = bool(status & 0x04)
    
    cycle_count = struct.unpack(">I", raw_bytes[2:6])[0]
    length      = struct.unpack(">H", raw_bytes[6:8])[0]
    
    expected_payload_len = 4 * n * n
    if length != expected_payload_len:
        raise ValueError(f"Unexpected payload length: expected {expected_payload_len}, got {length}")
        
    payload = raw_bytes[8:8+length]
    received_crc = raw_bytes[8+length]
    computed_crc = calc_crc8(raw_bytes[:8+length])
    
    if received_crc != computed_crc:
        raise ValueError(f"CRC mismatch! Received {hex(received_crc)}, Computed {hex(computed_crc)}")
        
    # Unpack 32-bit signed little-endian matrix values
    matrix_c = np.frombuffer(payload, dtype='<i4').reshape((n, n))
    
    return {
        "status": status,
        "done": done_bit,
        "overflow_sticky": overflow_sticky,
        "crc_err": crc_err,
        "cycle_count": cycle_count,
        "matrix_c": matrix_c,
        "crc_valid": True
    }
