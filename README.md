# test_zcu102

PE HIMAM (N = 16, FP32) chạy hardware-in-the-loop trên **ZCU102** (xczu9eg-ffvb1156-2-e). Repo có
cả file dựng sẵn để nạp ngay và toàn bộ nguồn để build lại từ RTL đến bitstream, ELF và `.bin`.

K = 4 là PE dùng khoá LUT-ranking (bản chính); K = 0 là khoá ALM gốc của HIMAM, để đối chứng.

## Kết quả đến nay

| Ngày / script | Vector | K = 4 | K = 0 | Đối chứng chéo |
|---|---|---|---|---|
| 28/10 `board_run_fsbl.tcl 4` (2 lần) | 2000 | PASS, 0 sai | — | — |
| 28/10 `board_run.tcl 4 0` | 2000 | PASS, 0 sai, FNV `0xA85E4B0C` | PASS, 0 sai, FNV `0x6A15E630` | — |
| **cần chạy:** `board_run.tcl` | 4085 | | | |

Chi tiết và số liệu implementation: `results/HIL_RESULTS.md`. Flow này chỉ kiểm **chức năng** (bit-exact).
Nó không đo năng lượng: số năng lượng của PE lấy từ SAIF.

## Lần đo tiếp theo (cần chạy)

```bash
git pull
HIL_URL=TCP:172.16.36.2:3121 HIL_SER=210308A65523 xsct -no-ini flow/board_run.tcl 2>&1 | tee results/hil_run_v4085.log
```

Lệnh này chạy ba mục (mặc định `4 0 cross`), mỗi mục mất vài chục giây (FSBL + nạp app 562 KB):

| Mục | Bitstream | App | Phải ra |
|---|---|---|---|
| `4` | K = 4 | `pe_hil_k4.elf` | `HIL_PASS`, 0/4085 sai |
| `0` | K = 0 | `pe_hil_k0.elf` | `HIL_PASS`, 0/4085 sai |
| `cross` | K = 0 | `pe_hil_k4.elf` | `CROSS_OK`: **đúng 1124 vector sai, vector sai đầu tiên là 23** |

`cross` là đối chứng âm. Nó cho thấy phép kiểm thật sự đọc kết quả từ PL và bắt được khoá xếp hạng sai.
1124 chính là số vector mà y(K = 0) ≠ y(K = 4) theo mô hình (`vectors/cross_k4_on_k0.txt`). Mô phỏng đã ra
đúng con số này.

Cuối log mong đợi:

```
PARTS  k=4: mismatches per part (random discrim edge) = 26 1000 98     <- dòng PARTS của mục cross (mục 4, 0: 0 0 0)
== SUMMARY
HIL_PASS k=4 init=fsbl vectors=4085 run_us=... (... us/vector, caches off, AXI4-Lite MMIO bound)
HIL_PASS k=0 init=fsbl vectors=4085 run_us=...
CROSS_OK K=4 app on K=0 bitstream (init=fsbl): mismatches=1124 first=23, expected 1124 first=23
BOARD_RUN_DONE
```

| Thấy gì | Nghĩa là |
|---|---|
| `HIL_FAIL ... mismatches=n` | Có vector sai. Dòng `PARTS` cho biết sai ở phần nào; `RESULT` word 3/4/5 là vector đầu tiên sai, giá trị lấy được và giá trị mong đợi |
| `CROSS_WRONG` với `mismatches` ≠ 1124 | Kết quả từ PL không khớp mô hình K = 0 ở đâu đó, hoặc nạp nhầm bitstream |
| `STEP3 ... DDR block test` khác 0 | DDR chưa khởi tạo đúng; reset cứng board rồi chạy lại |
| `NO_PSU_OR_APU` | DAP kẹt sau một lần chạy lỗi; reset cứng board rồi chạy lại |

Với mỗi mục, script làm: `rst -system` → nạp bitstream → chạy FSBL đến `XFsbl_Exit` → kiểm khối DDR 1024 word
→ xoá `AFI_FS` bits[9:8] → `dow` app → đặt mailbox (đợi ILA = 0 ms) → `con` → đọc khối kết quả.
Chạy riêng một mục: `... flow/board_run.tcl 4`. Chụp ILA (tuỳ chọn): đặt `HIL_ILA=1` (app đợi 5 s trước vector đầu),
rồi ngay khi log in `STEP5 k=4 app running` chạy
`HIL_URL=TCP:172.16.36.2:3121 vivado -mode batch -source flow/arm_ila.tcl -tclargs 4`.

## Bộ vector

`vectors/gen_hil_vectors.py` sinh 4085 vector. Đầu vào giống nhau cho K = 0 và K = 4, giá trị mong đợi lấy từ mô hình
Python bit-exact (`model/`).

| Phần | Số vector | Chỉ số | Nội dung | y(K=0) ≠ y(K=4) |
|---|---|---|---|---|
| random | 2000 | 0–1999 | bộ vector của các lần chạy trước (seed 42), giữ nguyên | 26 |
| discrim | 1500 | 2000–3499 | vector mà khoá xếp hạng quyết định kết quả: 1000 vector K = 0 ≠ K = 4, 500 vector K = 4 ≠ xếp hạng chính xác | 1000 |
| edge | 585 | 3500–4084 | x toàn 0, w = ±0, hoà (cặp lặp lại), tích bằng nhau trái dấu, bias triệt tiêu (y = +0), mũ đến ±60, gần hoà trong cùng một ô LUT k = 4, w cùng dấu, chỉ một x khác 0, làm tròn half-even ở cả hai phép cộng | 98 |

Không có trong bộ: tích subnormal hoặc tràn. RTL flush subnormal về 0 còn mô hình dùng IEEE float32. Datapath
khoá ở các mũ biên đó chỉ được kiểm trong mô phỏng (`tb_key`).

## Cấu trúc

| Đường dẫn | Nội dung |
|---|---|
| `pe_rtl/` | RTL của PE: `pe_top`, HIMAM/MAM, khoá ALM và LUT-ranking (`log_rom`), cây so sánh, FP mul/add |
| `rtl/` | Slave AXI4-Lite + thanh ghi vector bọc `pe_top`; wrapper N = 16, K = 0/4; vỏ Verilog cho BD + ILA |
| `bd/build_bd.tcl` | Block design: Zynq UltraScale+ PS (preset ZCU102), AXI interconnect, PE, ILA, MMCM từ SI570 |
| `constraints/zcu102_hil.xdc` | Chân SI570 300 MHz (AL8/AL7), ràng buộc clock |
| `model/` | Mô hình Python bit-exact của PE (sinh vector và giá trị mong đợi) |
| `vectors/gen_hil_vectors.py` | Sinh 4085 vector, `sw/hil_vectors.h`, FNV tham chiếu, số lỗi mong đợi của đối chứng chéo |
| `tb/` | Testbench AXI4-Lite + PE, so bit-exact (`run_sim.sh "0 4 cross"`) |
| `sw/` | App bare-metal A53 (`start.S`, `pe_hil_min.c`, `link.ld`), không cần BSP |
| `sw/psinit/` | Thử nghiệm: chạy `psu_init.c` của XSA trên OCM thay FSBL (trên board chưa chạy được, xem dưới) |
| `flow/build_all.sh` | BD → bitstream + XSA → ELF + `.bin` + `psu_init` |
| `flow/build_hil.tcl`, `flow/build_sw_min.sh` | Hai bước con của `build_all.sh` |
| `flow/board_run.tcl` | **Chạy trên board**: K = 4, K = 0 và đối chứng chéo |
| `flow/arm_ila.tcl` | Bật ILA và lưu CSV |
| `results/` | File dựng sẵn (`.bit/.xsa/.ltx`, `pe_hil_k*.elf/.bin`, `fsbl_zcu102.elf`), báo cáo util/timing, log mô phỏng và log board |
| *Cũ, chỉ để tham khảo* | `flow/board_run_fsbl.tcl` (bản đầu của `board_run.tcl`), `flow/board_debug.tcl`, `flow/board_debug2.tcl` (chẩn đoán DDR), `flow/run_hil.sh`, `prep_hw.tcl`, `run_app.tcl`, `build_sw.tcl`, `check_result.py` (flow khi board cắm thẳng vào máy build; chưa sửa cho xsct 2025.2) |

## Build lại từ đầu

Cần Vivado 2022.1 (board files ZCU102 có sẵn trong bản cài), Python 3 + NumPy, và một toolchain
`aarch64-none-elf` (có sẵn trong xsct/Vitis). Đường dẫn mặc định là `/opt/Xilinx/Vivado/2022.1` và
`/opt/petalinux/tools/xsct`. Máy khác thì đặt:

```bash
export VIVADO_SETTINGS=/tools/Xilinx/Vivado/2022.1/settings64.sh
export AARCH64_TC=/tools/Xilinx/Vitis/2022.1/gnu/aarch64/lin/aarch64-none/bin
```

```bash
python3 vectors/gen_hil_vectors.py           # vector + sw/hil_vectors.h + FNV + cross_k4_on_k0.txt
./tb/run_sim.sh "0 4 cross"                  # mô phỏng AXI, phải in "CROSS SIM OK" và "AXI SIM ALL PASS"
./flow/build_all.sh 4                        # BD -> bitstream/XSA -> ELF/bin/psu_init (khoảng 30-40 phút)
./flow/build_all.sh 0                        # bản ALM
```

Kết quả nằm trong `results/` (ghi đè file dựng sẵn) và project Vivado nằm ở `vivado/hil_k$K/`.
Chỉ đổi phần mềm hoặc vector thì không cần build lại bitstream: `./flow/build_sw_min.sh 4` dùng
`results/hil_zcu102_k4.xsa` có sẵn để tạo `pe_hil_k4.elf`, `pe_hil_k4.bin`, `psinit_k4.elf`, `psu_init_k4.tcl`.

Đã kiểm 28/10:
- Bản sao sạch dựng lại bitstream, `.bin` và `psu_init` giống file trong `results/`.
- `gen_hil_vectors.py` cho ra file giống từng byte qua các lần chạy (sha256 trong `vectors/manifest.json`).
- Mô phỏng AXI 4085 vector: K = 0 và K = 4 đều 0 lỗi; đối chứng chéo ra 1124 lỗi, vector sai đầu tiên là 23, đúng như dự đoán.
- Thiết kế dựng sẵn: K = 4 đạt WNS +0.043 ns, K = 0 đạt +0.007 ns ở 200 MHz.

## Yêu cầu phần cứng

- SW6 đặt chế độ boot **JTAG**, cắm USB-JTAG (và USB-UART nếu muốn xem console).
- Clock của PL lấy từ **USER SI570 (chân AL8/AL7) ở 300 MHz**, qua MMCM xuống 200 MHz. Reset của PL
  lấy từ tín hiệu `locked` của MMCM. Nếu SI570 trên board đã bị đặt sang tần số khác, hãy đặt lại về
  300 MHz bằng System Controller của ZCU102, nếu không PL sẽ không chạy.

## Khối kết quả trong DDR

`0x10000000`, 16 word:

| Word | Nội dung | Word | Nội dung |
|---|---|---|---|
| 0 | `0x48494C31` ("HIL1") | 8 | `vec_done` của PL |
| 1 | số vector | 9 | thanh ghi trạng thái cuối |
| 2 | số vector sai | 10, 11 | thanh ghi N, K đọc từ PL |
| 3 | chỉ số vector sai đầu tiên (`0xFFFFFFFF` = không có) | 12 | scratch đọc lại (`0x5A5AC33C`) |
| 4, 5 | giá trị lấy được / mong đợi ở vector sai đầu tiên | 13 | thời gian chạy, µs |
| 6, 7 | FNV của y lấy được / mong đợi | 14 | `0xA5A5A5A5` PASS, `0xDEADDEAD` FAIL |
| | | 15 | FNV của mô hình |

PASS đòi hỏi: 0 vector sai, `vec_done` = số vector, FNV khớp mô hình, và thanh ghi K, N, scratch đúng với bản
build của app. `0x10000100`: `0x50415254` ("PART"), số phần, rồi số vector sai của từng phần.
`0x10000080`: stage (`0x5354000s`; 1 vào `main`, 3 bắt đầu đọc PL, 5 chạy xong vector, 6 đã ghi kết quả)
và chỉ số vector đang chạy. `0x10000040`: bản ghi exception (`0xE7C0DEAD`, ESR, ELR, FAR).

Thời gian chạy (word 13) là tốc độ A53 ghi/đọc qua AXI4-Lite khi MMU và cache tắt (khoảng 10.6 µs/vector).
Đây không phải tốc độ tính của PE và không phải số throughput.

## Khởi tạo PS: FSBL

`results/fsbl_zcu102.elf` (sha256 `97ed1b81cd884b7e9c6d94b8d74150a68bdd2489cbbfeaea987f8a64365a0d96`) lấy từ
platform Vitis 2025.2 của lab (`vitis_test/platform_300`), có cấu hình DDR giống hệt `psu_init` của thiết kế này.
Repo không build lại được file này. Có hai điều cần biết:

1. FSBL đặt cổng PS→PL rộng 128 bit (`AFI_FS 0xFD615000` bits[9:8] = 2) còn thiết kế là 32 bit. Khi đó chỉ
   thanh ghi ở offset chia hết cho 16 đọc đúng. `board_run.tcl` ghi lại bits[9:8] = 0 sau FSBL.
2. Muốn bỏ hẳn file nhị phân này, hãy dựng FSBL từ chính `results/hil_zcu102_k4.xsa` trong Vitis 2025.2
   (platform mới từ XSA, domain standalone, ứng dụng `zynqmp_fsbl`). Khi đó bước 1 cũng không cần nữa.

Các cách khởi tạo khác đã thử và **không** dùng:
- `psu_init.tcl` chạy qua DAP: DDR hỏng khi ghi khối (79/1024 word sai trên zcu102-1, 38/1024 trên zcu102-2),
  dù cấu hình khớp preset ZCU102 (board file 3.3/3.4). Chưa rõ nguyên nhân.
- `psinit` (`sw/psinit/`, `HIL_INIT=psinit` hoặc `auto`): `psu_init()` không trả về trong 20 s
  (status giữ `0x50534900`). Chưa điều tra; FSBL đủ dùng.

## Lịch sử chẩn đoán (28/10)

1. `board_debug.tcl`: PL trả lời đúng (N = 0x10, K = 0x4) nhưng app không chạy, A53 rơi về `0x200`.
2. `board_debug2.tcl`: khối 1024 word ghi qua DAP sau `psu_init.tcl` sai 79/1024 (zcu102-1) và 38/1024 (zcu102-2).
3. `board_run_fsbl.tcl`: FSBL + xoá AFI → K = 4 PASS. Bản đó vá một lệnh trong RAM để bỏ đoạn đợi ILA 5 s.
   App giờ đọc thời gian đợi từ mailbox `0x100000C0` nên không cần vá nữa.
4. `board_run.tcl 4 0`: K = 4 và K = 0 PASS trên 2000 vector, đo được thời gian chạy.

Với xsct 2025.2, đọc bộ nhớ phải dùng `mrd -value`. Tên target của APU là `APU (L2 Cache Reset)`, nên script lọc
theo `APU*`.
