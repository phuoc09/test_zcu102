# test_zcu102

Bitstream và phần mềm build sẵn để chạy thử PE HIMAM (N = 16, FP32) trên **ZCU102** (xczu9eg).
Repo này chỉ chứa file để nạp và chạy, không có RTL.

| File | Nội dung |
|---|---|
| `results/hil_zcu102_k4.bit` | PE với khoá LUT-ranking k = 4, AXI4-Lite ở `0xA0000000`, ILA |
| `results/hil_zcu102_k0.bit` | PE với khoá ALM gốc (HIMAM), để đối chứng |
| `results/pe_hil_k{4,0}.elf` | App bare-metal cho A53 #0: ghi 2000 vector qua AXI4-Lite, so bit-exact |
| `results/psu_init_k{4,0}.tcl` | Khởi tạo PS (DDR, UART, PL clock) trích từ XSA |
| `results/hil_k{4,0}.ltx` | File probe của ILA |
| `results/util_k*.rpt`, `timing_k*.rpt` | Báo cáo tài nguyên và timing (WNS +0.043 ns cho K = 4 ở 200 MHz) |
| `flow/board_debug.tcl` | Chạy một lần trên board rồi in toàn bộ thông tin chẩn đoán |
| `flow/board_debug2.tcl` | **Chạy cái này trước.** Tách nguyên nhân A53 không thấy code sau `dow`, rồi thử cả hai cách nạp |
| `results/pe_hil_k{4,0}.bin` | Ảnh nhị phân thô của ELF (đặt ở `0x100000`, entry `0x100800`), dùng cho cách nạp B |
| `flow/arm_ila.tcl` | (Tuỳ chọn) bật ILA và lưu capture CSV |

## Yêu cầu phần cứng

- SW6 đặt chế độ boot **JTAG**, cắm USB-JTAG (và USB-UART nếu muốn xem console).
- Clock của PL lấy từ **USER SI570 (chân AL8/AL7) ở 300 MHz**, qua MMCM xuống 200 MHz. Reset của PL
  lấy từ tín hiệu `locked` của MMCM. Nếu SI570 trên board đã bị đặt sang tần số khác, hãy đặt lại về
  300 MHz bằng System Controller của ZCU102, nếu không PL sẽ không chạy.

## Chạy

```bash
# hw_server cục bộ: không cần biến môi trường
# hw_server từ xa và nhiều board: chỉ định URL và serial của cáp JTAG
HIL_URL=TCP:172.16.36.2:3121 HIL_SER=210308A65523 xsct -no-ini flow/board_debug.tcl 4    # dùng 0 cho bản ALM
```

Script làm theo thứ tự của Vitis/FSBL: `rst -system` → nạp bitstream → `psu_init` → gỡ PS-PL
isolation → reset PL → nạp và chạy ELF trên A53 #0 → đọc kết quả.

## Đọc kết quả

Kết quả đúng (K = 4):

```
RESULT block 0x10000000: 0x48494C31 0x000007D0 0x00000000 ... 0xA5A5A5A5 0xA85E4B0C
STAGE  0x10000080: stage=0x53540006
EXCEPTION none recorded
```

Word 14 = `0xA5A5A5A5` nghĩa là bit-exact PASS. FNV mong đợi là `0xA85E4B0C` (K = 4) và `0x6A15E630` (K = 0).

| Thấy gì | Nghĩa là |
|---|---|
| `stage=0x53540006` và `0xA5A5A5A5` | PASS |
| `EC=0x25 FSC=0x10`, FAR = `0xA00002xx` | Truy cập AXI sang PL bị lỗi. Xem dòng `PSPL isolation`: bit23 phải bằng 0 |
| Isolation đã bằng 0 mà vẫn lỗi, hoặc dừng ở `stage=0x53540003` mà không có exception | PL không có clock hoặc bị giữ reset, khả năng cao do SI570 |
| `PLREG N = 0x00000010`, `K = 0x00000004` | PL trả lời đúng qua AXI |

Các mốc stage: 1 vào `main`, 2 đã ghi UART, 3 bắt đầu đọc PL, 4 đã đọc xong thanh ghi PL,
5 chạy xong 2000 vector, 6 đã ghi khối kết quả.

## Lần chạy thứ 2 (28/10): `board_debug2.tcl`

Lần chạy trước PL đã đúng (N = 0x10, K = 0x4) nhưng sau `dow` ô `0x100800` không phải `0x10004000`.
Script này làm theo thứ tự sau, mỗi bước in ra một dòng:

1. Khởi tạo như cũ (`APU*`, `configparams force-mem-access 1`, `psu_protection`), in `RST_FPD_APU`
   trước và sau `rst -processor`. Nếu bit 8 (L2 cache reset) vẫn bằng 1, script gỡ bit này và in `WARN`.
2. `BLOCK`: ghi 1024 word liên tiếp qua DAP, đọc lại qua DAP và qua A53 #0. `WORD`: ghi qua A53, đọc qua DAP.
3. Cách A: `dow` ELF qua core, kiểm 72 word đọc qua cả hai đường (`VERIFY method A`).
4. Nếu cách A sai hoặc không PASS thì dùng cách B: ghi `pe_hil_k$K.bin` thẳng vào DDR qua DAP (`dow -data`),
   `rst -processor`, đặt `pc = 0x100800` rồi `con`.

```bash
HIL_URL=TCP:172.16.36.2:3121 HIL_SER=210308A65523 xsct -no-ini flow/board_debug2.tcl 4 2>&1 | tee run2_k4.log
```

Gửi lại toàn bộ `run2_k4.log`. Cần nhất là các dòng `RST_FPD_APU`, `BLOCK`, `WORD`, `VERIFY`, `RESULT` và dòng cuối `HIL_PASS` hoặc `HIL_FAIL`.

| Thấy gì | Nghĩa là |
|---|---|
| `BLOCK ... via dap` có mismatch | DDR hỏng khi ghi burst (psu_init/DDR training), không phải lỗi phần mềm |
| `via dap` đúng nhưng `via cpu` sai | A53 nhìn bộ nhớ khác DAP (L2 reset hoặc cache) |
| `VERIFY method A` sai nhưng `method B` đúng | `dow` của xsct 2025.2 ghi qua core bị hỏng, dùng cách B |
| `HIL_PASS` | xong, word 14 = `0xA5A5A5A5` |

## ILA (tuỳ chọn)

App đợi 5 giây sau khi chạy rồi mới gửi vector đầu tiên (vector này kích ILA). Hãy chạy lệnh dưới ngay sau khi `board_debug.tcl` in `BD_STEP psu_init ...`:

```bash
HIL_URL=TCP:172.16.36.2:3121 vivado -mode batch -source flow/arm_ila.tcl -tclargs 4
```
