# AVD KernelSU 替換測試與排錯紀錄

本文件紀錄了在 Android Virtual Device (AVD) 上替換 KernelSU 編譯之 `bzImage` 過程中的所有嘗試、碰壁原因，以及最終的 Root Cause 分析。

## 環境配置

* **OS**: Windows 11 (WSL2 Ubuntu 24.04)
* **Emulator**: Android Emulator 36.5.10.0 (API 34)
* **AVD**: Android 14 (Google APIs, x86_64)
* **目標 Kernel**: KernelSU 官方 GitHub Actions 編譯之 `common-android14-6.1-2023-12` (`x86_64`)

---

## 嘗試與碰壁歷程

### 階段一：直接替換 bzImage (Kernel)

* **操作**：下載 KernelSU CI 編譯好的 `bzImage`，使用 `emulator -avd A14-GAPIS -kernel bzImage` 啟動。
* **現象**：模擬器陷入無限重啟 (Bootloop)，錯誤日誌顯示 `InitFatalReboot: signal 6`，並且 `init` 報錯 `module virtio_blk does not exist` 以及 `Failed to mount required partitions early ...`。
* **原因分析**：原廠 AVD 映像檔的 `ramdisk.img` 中，`/lib/modules/` 底下的驅動程式是針對原本的 `6.1.23` 核心編譯的。當我們換上 `6.1.162` 的 KernelSU 核心時，`first_stage_init` 無法載入舊的磁碟驅動 (`virtio_blk`)，導致無法掛載根目錄而崩潰。

### 階段二：透過腳本 ADB 推送 Modules

* **操作**：撰寫 `install-ksu-avd.sh` 腳本，嘗試在模擬器開機或使用原廠核心開機的狀態下，透過 ADB 將針對新核心編譯的 `.ko` 檔案推送到 `/lib/modules/`。
* **碰壁**：
    1. 模擬器不斷重啟，難以穩定建立 ADB 連線。
    2. `/lib/modules` 在開機的最初期 (`first_stage_init`) 就需要被讀取以掛載分區，透過 ADB (在系統啟動後) 推送驅動程式時間點太晚，根本來不及拯救開機初期的崩潰。

### 階段三：手動解包並修改 Ramdisk (使用 magiskboot)

* **操作**：撰寫 `install-avd.sh` 腳本，使用 `magiskboot` 將原廠的 `ramdisk.img` 解壓縮成 `cpio` 格式，強制將新核心的 `virtio_blk.ko`、`virtio_pci.ko` 等關鍵模組注入，然後重新打包。
* **碰壁 (壓縮格式)**：一開始打包回去後核心仍然無法讀取，發現 Android 14 的 `ramdisk.img` 需要使用 `gzip` 格式壓縮，我們修正了腳本使用 `magiskboot compress=gzip`。
* **碰壁 (fstab 遺失)**：注入模組後，日誌顯示找不到 `fstab.default`。我們進一步修改腳本，從 ramdisk 內部的 `first_stage_ramdisk/fstab.ranchu` 複製並注入一份 fallback 命名為 `fstab.default`。
* **碰壁 (依賴解析失敗)**：模組和 fstab 都存在了，日誌依然顯示 `module virtio_blk does not exist`。我們推測是 `libmodprobe` 需要 `modules.dep` 來解析依賴。於是我們**手動生成了包含絕對路徑的自定義 `modules.dep` 並注入到 ramdisk 中**。

### 階段四：深度分析源碼與最終 Root Cause 確認

* **操作**：即使完美注入了 `modules.dep` 和所有需要的驅動模組，模擬器依然報錯 `module virtio_blk does not exist`。我們轉而對比 AOSP 原始碼 (`libmodprobe.cpp` 及 `first_stage_init.cpp`) 與模擬器 Serial Log 進行底層邏輯推演。
* **發現**：在崩潰前，有一行非常不起眼的日誌：
    `[    2.238844] init: Could not stat("/"), not freeing ramdisk: Function not implemented`
* **最終 Root Cause**：
    1. `Function not implemented` 代表 Kernel 回傳了 `-ENOSYS`。
    2. KernelSU 為了實現隱藏功能 (Hide SU)，會攔截 (Hook) 包含 `sys_newfstatat`、`sys_fstat` (在 x86_64 上對應 Syscall 5 和 262) 等查詢檔案狀態的系統呼叫。
    3. 我們下載的這版 KernelSU `x86_64` 編譯產物，**其 `stat` 相關的 Syscall Hook 存在嚴重的 Bug**。只要觸發該 Hook，不管查詢什麼檔案，都會直接報錯 `ENOSYS`。
    4. 當 Android 的 `libmodprobe` 在 `first_stage_init` 嘗試載入 `virtio_blk` 驅動時，會呼叫 `ModuleExists()` 函數。
    5. `ModuleExists()` 內部使用 `stat()` 系統呼叫來確認 `.ko` 檔案真的存在於硬碟(ramdisk)中。
    6. 因為 KernelSU 的 Bug，`stat()` 失敗了。這導致 `libmodprobe` 誤以為驅動檔案不存在，直接跳過掛載！
    7. 沒有 `virtio_blk` 驅動，Android 無法讀取硬碟，無法掛載 `/system`，隨即引發 `Signal 6` 致命重啟。

---

## 結論與下一步建議

經過一連串的實作與除錯，我們證實**單純替換與修改 ramdisk 是無法解決這個 bootloop 的，因為核心本身的 Syscall Hook 是壞的。**

**建議的解決方案：**

1. **自行編譯 Android 14 Kernel (推薦)**：在我們的 WSL2 環境中，下載 Google 官方 `common-android14-6.1` 原始碼，並手動打上 KernelSU Patch。這樣若遇到架構相容性問題，我們可以自行微調代碼（例如針對 AVD x86_64 關閉有 Bug 的隱藏機制）。
2. **尋找舊版/其他分支的編譯產物**：如網路上 2024 年初的教學文章，當時的 KernelSU (`v0.7.x`) 在 x86_64 上的 Hook 可能是正常的，我們需要尋找該時間點的 Action Artifact 進行測試。
