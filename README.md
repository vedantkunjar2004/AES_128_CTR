# AES-128 Crypto Accelerator with Secure Register Access Control

> **RTL Design Project — Mirafra Technologies**  
> **Engineer:** Vedant Vasant Kunjar · Employee ID: 6948  
> **Specification Version:** v2  
> **Reference Standards:** NIST FIPS 197 (AES) · NIST SP 800-38A (CTR Mode)

---

## Table of Contents

- [Project Overview](#project-overview)
- [Architecture](#architecture)
- [Security Features](#security-features)
- [Register Map](#register-map)
- [Clock Domains and CDC](#clock-domains-and-cdc)
- [Repository Structure](#repository-structure)
- [Documents](#documents)
- [Simulation and Verification](#simulation-and-verification)
- [Known Limitations](#known-limitations)
- [References](#references)

---

## Project Overview

This project implements a **synthesisable AES-128 hardware crypto accelerator** in Verilog RTL. The accelerator performs AES-128 encryption in **Counter (CTR) mode** per NIST SP 800-38A and exposes its interface through an **AMBA APB4 slave port** (32-bit, zero wait states).

### What it does

The accelerator:
1. Accepts a **128-bit AES key** via privileged APB4 register writes
2. Accepts a **128-bit Initial Value (IV / Counter)** via APB4 registers
3. Accepts **128-bit plaintext blocks** through a TX FIFO via APB4
4. Encrypts each block using the CTR-mode formula:

```
C_i = P_i XOR AES_K(CTR_i)
```

5. Returns the **128-bit ciphertext** through an RX FIFO via APB4 register readback

CTR mode means the AES cipher encrypts the counter value (not the plaintext directly), and the result is XOR'd with the plaintext. The **same hardware path handles both encryption and decryption** — only the forward AES cipher is used in both directions.

---

## Architecture

The design is split into **two independent clock domains**:

| Domain | Clock | Drives |
|--------|-------|--------|
| APB Bus | `pclk` (100 MHz typical) | `apb4_interface`, `register_bank`, TX FIFO write, RX FIFO read |
| Crypto Core | `crypto_clk` (200 MHz typical) | `control_fsm`, `aes_engine`, TX FIFO read, RX FIFO write |

### Module Hierarchy

```
aes_crypto_accel_top
├── apb4_interface.v             # APB4 protocol decode (SETUP/ACCESS phases)
├── register_bank.v              # All registers + security gating (S1–S6)
├── async_fifo.v  (x2)           # TX FIFO (plaintext) + RX FIFO (ciphertext)
├── cdc_pulse_sync.v  (x4)       # KEY_LOAD, IV_LOAD, ZEROIZE, cycle_count pulses
├── cdc_level_sync_robust.v (x2) # BUSY and KEY_READY status crossing
├── control_fsm.v                # Block sequencer (5-state FSM, crypto_clk)
└── aes_engine.v
    ├── key_expansion.v          # AES-128 key schedule (11 round keys, 10 cycles)
    ├── round_datapath.v         # 10-round AES cipher (11 crypto_clk cycles total)
    ├── iv_counter_mgmt.v        # 128-bit counter with auto-increment
    └── sbox.v                   # AES S-box lookup table
```

### Data Flow

```
[SW writes PT0-PT3]
      |
      v
 register_bank --PT_PUSH--> TX async FIFO --> control_fsm --> aes_engine
                                                                    |
              RX async FIFO <-- control_fsm <-----------------------+
                    |
[SW reads CT0-CT3] <-- register_bank
```

---

## Security Features

The design implements **six hardware security features**:

| ID | Feature | Description |
|----|---------|-------------|
| **S1** | Write-Only Key Registers | KEY0–KEY3 always read back `0x00000000` regardless of content |
| **S2** | Sticky Key Lock (`KEY_LOCK`) | Once set via `CTRL[4]`, key writes are **silently discarded**. Only `presetn` clears it. No PSLVERR on locked write — intentional to avoid side-channel leakage of lock state |
| **S3** | Zeroize | `CTRL.ZEROIZE` pulse clears `key_bus` and `ct_valid` in pclk domain; full key memory and IV counter cleared in crypto domain |
| **S4** | Constant-Time Computation | AES engine always takes exactly **11 `crypto_clk` cycles** per block — eliminates timing side channels |
| **S5** | Privilege-Gated Access | CTRL and KEY registers require `PPROT[0]=1`. Unprivileged access asserts `PSLVERR` and latches `STATUS.SEC_VIOLATION` |
| **S6** | Ciphertext Gating | CT0–CT3 read back `0x00000000` when no valid result is available (`ct_valid=0`). CT3 read marks result as consumed |

---

## Register Map

All registers are **32-bit, word-aligned**. Internal address decode = `paddr[6:2]` (5-bit word address — bits `[1:0]` are byte-lane selects and are ignored for register decode).

| Offset | Register | Access | Reset | Description |
|--------|----------|--------|-------|-------------|
| `0x00` | CTRL | RW (privileged) | `0x0` | Control — KEY_LOAD, IV_LOAD, PT_PUSH, ZEROIZE, KEY_LOCK |
| `0x04` | STATUS | RO | `0x0` | Status — BUSY, KEY_READY, TX_FIFO_FULL, RX_FIFO_EMPTY, SEC_VIOLATION |
| `0x10` | KEY0 | WO (privileged) | `0x0` | AES key bits [127:96] |
| `0x14` | KEY1 | WO (privileged) | `0x0` | AES key bits [95:64] |
| `0x18` | KEY2 | WO (privileged) | `0x0` | AES key bits [63:32] |
| `0x1C` | KEY3 | WO (privileged) | `0x0` | AES key bits [31:0] |
| `0x20` | IV0 | RW | `0x0` | IV/Counter bits [127:96] |
| `0x24` | IV1 | RW | `0x0` | IV/Counter bits [95:64] |
| `0x28` | IV2 | RW | `0x0` | IV/Counter bits [63:32] |
| `0x2C` | IV3 | RW | `0x0` | IV/Counter bits [31:0] |
| `0x30` | PT0 | RW | `0x0` | Plaintext staging bits [127:96] |
| `0x34` | PT1 | RW | `0x0` | Plaintext staging bits [95:64] |
| `0x38` | PT2 | RW | `0x0` | Plaintext staging bits [63:32] |
| `0x3C` | PT3 | RW | `0x0` | Plaintext staging bits [31:0] |
| `0x40` | CT0 | RO | `0x0` | Ciphertext bits [127:96] |
| `0x44` | CT1 | RO | `0x0` | Ciphertext bits [95:64] |
| `0x48` | CT2 | RO | `0x0` | Ciphertext bits [63:32] |
| `0x4C` | CT3 | RO | `0x0` | Ciphertext bits [31:0] — **read of CT3 marks result consumed** |
| `0x50` | CYCLE_COUNT | RO | `0x0` | Crypto cycles for last block (expected constant: 11) |

### CTRL Bit-Fields (`0x00`)

| Bit | Field | Type | Description |
|-----|-------|------|-------------|
| 0 | KEY_LOAD | WO pulse | Triggers key expansion in crypto_clk domain |
| 1 | IV_LOAD | WO pulse | Loads IV into counter management |
| 2 | PT_PUSH | WO pulse | Enqueues PT0–PT3 into TX FIFO |
| 3 | ZEROIZE | WO pulse | Security wipe (see Known Limitations #7 for scope) |
| 4 | KEY_LOCK | W1S sticky | Locks key registers until hardware reset (`presetn`) |
| 31:5 | Reserved | — | Read-as-zero, write-ignored |

> **Note:** CTRL pulse bits (KEY_LOAD, IV_LOAD, PT_PUSH, ZEROIZE) always read back as `0`. Only KEY_LOCK is readable: CTRL reads return `{27'b0, KEY_LOCK, 4'b0}`.

### STATUS Bit-Fields (`0x04`)

| Bit | Field | Type | Description |
|-----|-------|------|-------------|
| 0 | BUSY | RO | AES engine active (synced from crypto_clk) |
| 1 | KEY_READY | RO | Key expansion complete; safe to push plaintext |
| 2 | TX_FIFO_FULL | RO | TX FIFO full — PT_PUSH will trigger PSLVERR |
| 3 | RX_FIFO_EMPTY | RO | No ciphertext result available |
| 4 | SEC_VIOLATION | W1C | Latched on unprivileged CTRL or KEY access; write 1 to clear |
| 31:5 | Reserved | — | Read-as-zero |

---

## Clock Domains and CDC

All CDC structures are instantiated **only at the top level** (`aes_crypto_accel_top`). No sub-module contains CDC logic.

| Signal | Direction | CDC Structure | Instance |
|--------|-----------|---------------|----------|
| KEY_LOAD pulse | pclk → crypto_clk | `cdc_pulse_sync` | `u_key_load_sync` |
| IV_LOAD pulse | pclk → crypto_clk | `cdc_pulse_sync` | `u_iv_load_sync` |
| ZEROIZE pulse | pclk → crypto_clk | `cdc_pulse_sync` | `u_zeroize_sync` |
| Plaintext blocks | pclk → crypto_clk | `async_fifo` (TX) | `u_tx_fifo` |
| Ciphertext blocks | crypto_clk → pclk | `async_fifo` (RX) | `u_rx_fifo` |
| BUSY status | crypto_clk → pclk | `cdc_level_sync_robust` | `u_busy_sync` |
| KEY_READY status | crypto_clk → pclk | `cdc_level_sync_robust` | `u_key_ready_sync` |

> **Quasi-static buses:** `key_bus` (128-bit) and `iv_bus` (128-bit) cross as quasi-static signals, guaranteed stable before their qualifying pulse traverses the synchronizer chain.

---

## Repository Structure

```
MAJOR PROJECT - AES/
│
├── README.md                           <- This file
├── Design_Specification.tex            <- Full design spec (v2.0, LaTeX)
├── DV_handoff.tex                      <- DV handoff document (LaTeX)
├── minutes_of_meeting.txt              <- DV review meeting notes (Oct 1, 2026)
├── aes_vedant_clarification.txt        <- DV team clarification points (7 items)
│
├── RTL/
│   ├── aes_crypto_accel_top.v          # Top-level integration module
│   ├── apb4_interface.v                # APB4 slave interface
│   ├── register_bank.v                 # Register file + all security gating
│   ├── control_fsm.v                   # 5-state block sequencer FSM
│   ├── aes_engine.v                    # AES engine wrapper
│   ├── key_expansion.v                 # AES-128 key schedule
│   ├── round_datapath.v                # 10-round AES cipher datapath
│   ├── iv_counter_mgmt.v               # 128-bit IV counter management
│   ├── sbox.v                          # AES S-box
│   ├── async_fifo.v                    # Async FIFO (Gray-coded pointers)
│   ├── cdc_pulse_sync.v                # Toggle-based pulse synchronizer
│   └── cdc_level_sync_robust.v         # 2-FF level synchronizer
│
├── Testbench/
│   ├── tb_aes_crypto_accel_top.v       # Directed testbench (NIST F.5.1 vectors)
│   └── Waveforms/
│       ├── waveform_top_level.png      # APB4 bus-level waveform
│       ├── waveform_aes_core_ctr.png   # AES core internal signals
│       └── waveform_ct_readback_zoom.png  # CT0-CT3 readback zoom
│
└── figures/
    ├── microarchitecture_block_diagram.jpg
    └── (waveform images mirrored from Testbench/Waveforms/)
```

---

## Documents

### Design Specification (`Design_Specification.tex`) — v2.0

The primary design document compiled with pdfLaTeX. Contains 11 sections:

1. Document Information
2. Overview — AES CTR mode theory, encryption/decryption diagrams, block diagrams
3. Interfaces — Full APB4 port list, PSLVERR timing clarification, read/write waveforms
4. Clocking and Reset — Dual-domain structure, independent reset behaviour, CDC table
5. Register Map — All registers with bit-field tables and security behaviour
6. Functional Description — Key load path, IV load path, encryption path, error handling, zeroize scope
7. FSM / State Transitions — Three FSMs with explicit **If true / If false** conditions
8. Simulation Waveform Evidence — 3 waveforms with timestamp-by-timestamp walkthroughs
9. Reference Specification and Supported Features — NIST compliance table
10. Parameters — Configurable FIFO depth, address width
11. Known Limitations — 11 documented design constraints

> Compile: upload to [Overleaf](https://www.overleaf.com) or run `pdflatex Design_Specification.tex` with TeX Live.

### DV Handoff Document (`DV_handoff.tex`)

Addressed to the DV team. Covers RTL file list, module hierarchy, clock/reset summary, register map for UVM RAL model, CDC crossing summary, testbench guidance, security feature constraints, and known issues.

---

## Simulation and Verification

The directed testbench (`tb_aes_crypto_accel_top.v`) validates the design against **NIST SP 800-38A Appendix F.5.1** AES-128 CTR mode test vectors.

### NIST Test Vector (Block 1)

| Parameter | Value |
|-----------|-------|
| Key | `2b7e151628aed2a6 abf7158809cf4f3c` |
| Initial Counter (IV) | `f0f1f2f3f4f5f6f7 f8f9fafbfcfdfeff` |
| Plaintext | `6bc1bee22e409f96 e93d7e117393172a` |
| Expected Ciphertext | `874d6191b620e326 1bef6864990db6ce` |

### Simulation Results Summary

| Check | Result |
|-------|--------|
| NIST vectors passed | ✅ 6 / 6 |
| Fail count | ✅ 0 |
| Constant-time (11 cycles/block) | ✅ Confirmed |
| PSLVERR only during ACCESS phase | ✅ Confirmed |
| KEY read-back = 0 (S1) | ✅ Confirmed |
| CT gated to 0 when not valid (S6) | ✅ Confirmed |

---

## Known Limitations

1. **AES-128 only** — No AES-192/256 support
2. **CTR mode only** — No ECB, CBC, CFB, OFB, GCM, or CCM
3. **No DMA interface** — All data via programmed APB4 I/O (4 writes × 32-bit per 128-bit block)
4. **Single-block serialisation** — One block processed at a time
5. **KEY_LOAD / IV_LOAD dropped if not idle** — Software must ensure `STATUS.BUSY = 0` and TX FIFO empty before issuing these commands
6. **CDC pulse spacing constraint** — Back-to-back pulses must be spaced ≥ 3 destination clock cycles apart
7. **Zeroize does not clear `iv_bus` / `pt_bus` in pclk domain** — Only `key_bus` and `ct_valid` are cleared; software should overwrite IV and PT registers after zeroize if stale values are a concern
8. **FIFO memories lack asynchronous reset** — Only Gray-coded pointers are reset; memory arrays retain stale data (overwritten before reuse)
9. **Full 128-bit counter** — No configurable nonce/counter split (e.g. 96-bit nonce + 32-bit counter)
10. **No watchdog on `S_WAIT_DONE`** — Recovery via ZEROIZE or hardware reset only
11. **KEY_LOCK silent ignore** — KEY writes silently discarded without PSLVERR when lock is active (intentional — avoids side-channel leakage)

---

## References

| Standard | Title |
|----------|-------|
| [NIST FIPS 197](https://doi.org/10.6028/NIST.FIPS.197-upd1) | Advanced Encryption Standard (AES), Updated May 2023 |
| [NIST SP 800-38A](https://doi.org/10.6028/NIST.SP.800-38A) | Recommendation for Block Cipher Modes of Operation, 2001 |
| [ARM IHI 0024E](https://developer.arm.com/documentation/ihi0024/e/) | AMBA APB Protocol Specification |

---

*AES-128 Crypto Accelerator RTL Design — Mirafra Technologies, September–November 2026*
