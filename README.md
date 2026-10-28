# test_zcu102

PE HIMAM (N = 16, FP32) chạy hardware-in-the-loop trên **ZCU102** (xczu9eg-ffvb1156-2-e). Repo có
cả file dựng sẵn để nạp ngay và toàn bộ nguồn để build lại từ RTL đến bitstream, ELF và `.bin`.

## Cấu trúc

| Đường dẫn | Nội dung |
|---|---|
| `pe_rtl/` | RTL của PE: `pe_top`, HIMAM/MAM, khoá ALM và LUT-ranking (`log_rom`), cây so sánh, FP mul/add |
| `rtl/` | Slave AXI4-Lite + thanh ghi vector bọc `pe_top`; wrapper N = 16, K = 0/4; vỏ Verilog cho BD + ILA |
| `bd/build_bd.tcl` | Block design: Zynq UltraScale+ PS (preset ZCU102), AXI interconnect, PE, ILA, MMCM từ SI570 |
| `constraints/zcu102_hil.xdc` | Chân SI570 300 MHz (AL8/AL7), ràng buộc clock |
| `model/` | Mô hình Python bit-exact của PE (sinh vector và giá trị mong đợi) |
| `vectors/gen_hil_vectors.py` | Sinh 2000 vector, `sw/hil_vectors.h` và FNV tham chiếu |
| `tb/` | Testbench AXI4-Lite + PE, so bit-exact (`run_sim.sh`) |
| `sw/` | App bare-metal A53 (`start.S`, `pe_hil_min.c`, `link.ld`), không cần BSP |
| `flow/build_all.sh` | BD → bitstream + XSA → ELF + `.bin` + `psu_init` |
| `flow/build_hil.tcl`, `flow/build_sw_min.sh` | Hai bước con của `build_all.sh` |
| `flow/board_debug2.tcl` | **Chạy trên board** (xsct, hw_server cục bộ hoặc từ xa), in đầy đủ chẩn đoán |
| `flow/board_debug.tcl`, `flow/arm_ila.tcl` | Script chạy board bản đầu; bật ILA và lưu CSV |
| `flow/run_hil.sh`, `prep_hw.tcl`, `run_app.tcl`, `check_result.py` | Flow cũ khi board cắm thẳng vào máy build |
| `results/` | File dựng sẵn: `hil_zcu102_k{4,0}.bit/.xsa/.ltx`, `pe_hil_k{4,0}.elf/.bin`, `psu_init_k{4,0}.tcl`, báo cáo util/timing, log mô phỏng |

K = 4 là PE dùng khoá LUT-ranking (bản chính); K = 0 là khoá ALM gốc của HIMAM, để đối chứng.

## Build lại từ đầu

Cần Vivado 2022.1 (board files ZCU102 có sẵn trong bản cài), Python 3 + NumPy, và một toolchain
`aarch64-none-elf` (có sẵn trong xsct/Vitis). Đường dẫn mặc định là `/opt/Xilinx/Vivado/2022.1` và
`/opt/petalinux/tools/xsct`. Máy khác thì đặt:

```bash
export VIVADO_SETTINGS=/tools/Xilinx/Vivado/2022.1/settings64.sh
export AARCH64_TC=/tools/Xilinx/Vitis/2022.1/gnu/aarch64/lin/aarch64-none/bin
```

```bash
python3 vectors/gen_hil_vectors.py 2000 16   # vector + sw/hil_vectors.h + FNV
./tb/run_sim.sh "0 4"                        # mô phỏng AXI, phải in "AXI SIM ALL PASS"
./flow/build_all.sh 4                        # BD -> bitstream/XSA -> ELF/bin/psu_init (khoảng 30-40 phút)
./flow/build_all.sh 0                        # (tuỳ chọn) bản ALM
```

Kết quả nằm trong `results/` (ghi đè file dựng sẵn) và project Vivado nằm ở `vivado/hil_k$K/`.
Chỉ đổi phần mềm thì không cần build lại bitstream: `./flow/build_sw_min.sh 4` dùng
`results/hil_zcu102_k4.xsa` có sẵn để tạo `pe_hil_k4.elf`, `pe_hil_k4.bin`, `psu_init_k4.tcl`.

Đã kiểm 28/10 trên một bản sao sạch: vector, `sw/hil_vectors.h`, `.bin` và `psu_init` dựng lại giống
từng byte với file trong `results/`; mô phỏng AXI 2000 vector × {K = 0, K = 4}: 0 lỗi.
Thiết kế dựng sẵn: K = 4 đạt WNS +0.043 ns, K = 0 đạt +0.007 ns ở 200 MHz.

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

Kết quả (28/10): `BLOCK` sai 79/1024 word trên zcu102-1 và 38/1024 trên zcu102-2 (cùng một lỗi trên hai board).
`psu_init` khớp hoàn toàn preset DDR của ZCU102 (board file 3.3/3.4) và cấu hình DDR trong workspace Vitis
của lab, nên lỗi không nằm ở cấu hình. Dùng FSBL để khởi tạo PS/DDR, xem mục dưới.

## ILA (tuỳ chọn)

App đợi 5 giây sau khi chạy rồi mới gửi vector đầu tiên (vector này kích ILA). Hãy chạy lệnh dưới ngay sau khi `board_debug.tcl` in `BD_STEP psu_init ...`:

```bash
HIL_URL=TCP:172.16.36.2:3121 vivado -mode batch -source flow/arm_ila.tcl -tclargs 4
```

## Chạy được trên board (28/10): khởi tạo bằng FSBL — `board_run_fsbl.tcl`

**K = 4 trên zcu102-1: HIL_PASS, 2000/2000 vector bit-exact, `mismatches=0`, `fnv=0xA85E4B0C`**
(chạy 2 lần liên tiếp, log: `results/hil_run_zcu102_k4_PASS.log`).

```bash
HIL_URL=TCP:172.16.36.2:3121 HIL_SER=210308A65523 xsct -no-ini flow/board_run_fsbl.tcl 4
```

Script làm: `rst -system` → nạp bitstream → chạy `results/fsbl_zcu102.elf` đến `XFsbl_Exit` (FSBL khởi tạo PS và DDR)
→ kiểm khối DDR 1024 word → đặt lại độ rộng cổng PS→PL → `dow` ELF → chạy → đọc khối kết quả.

Hai nguyên nhân của các lỗi trước:

1. **DDR**: `psu_init.tcl` chạy qua DAP làm DDR hỏng khi ghi khối (46–79/1024 word sai, ảnh `dow` đọc ra sai, A53 rơi về `0x200`).
   Sau FSBL cùng phép thử cho 0 lỗi. FSBL lấy từ platform Vitis của lab (`vitis_test/platform_300`, cấu hình DDR
   giống hệt `psu_init` ở đây). Chưa rõ vì sao chạy `psu_init` qua DAP thì lỗi.
2. **Độ rộng cổng AXI PS→PL**: FSBL đặt `0xFD615000` bits[9:8] = 2 (128-bit) còn thiết kế này là 32-bit. Khi đó
   chỉ thanh ghi ở offset chia hết cho 16 đọc đúng (`N` @0x210, scratch @0x220), còn `K` @0x214 và `WAIT` @0x218 đọc ra 0.
   Script ghi lại bits[9:8] = 0 (đúng như `psu_init`) trước khi chạy app.

Lưu ý:

- **Script vá 1 lệnh trong RAM** (`0x101db4`, `movk x1,#0x5968,lsl#16` → `#0x0001`) để bỏ đoạn đợi 5 s dành cho ILA: sau `rst -processor`
  cache tắt nên vòng đợi 1.5e9 lần lặp kéo dài hàng chục phút. File ELF không bị sửa. **ILA không được chụp ở chế độ này** và
  giá trị `us` trong khối kết quả không dùng được.
- Mới chạy **K = 4**. K = 0 chưa chạy bằng script này.
- Nếu một lần chạy lỗi, DAP có thể ở trạng thái `AXI AP transaction error` và board phải reset cứng trước lần sau
  (script thoát với `NO_PSU_OR_APU`). Mỗi lần chạy lỗi cần reset board.
- Với xsct 2025.2, đọc kết quả phải dùng `mrd -value` (đã dùng trong script); `flow/run_hil.sh`/`run_app.tcl` cũ chưa cập nhật.
