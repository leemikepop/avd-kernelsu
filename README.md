# AVD KernelSU Installer 🚀

這個專案提供了一套自動化工具與 GitHub Actions 工作流程，協助開發者與研究人員在 Android 虛擬裝置 (AVD) 上輕鬆部署自訂核心（如整合了 KernelSU 或 SuSFS 的 `kernel-ranchu`），並自動解決核心模組不匹配（Vermagic）導致的硬體失效問題。

## 🌟 核心功能與痛點解決

在 Android 12+ (GKI 核心架構) 中，如果您自行編譯了 AVD 的核心 (`kernel-ranchu`) 並直接替換 Android SDK 中的原廠核心，模擬器雖然能開機，但會因為 **核心與原始 `ramdisk.img` 中的驅動模組版本（Vermagic）不匹配**，導致核心拒絕載入原廠驅動。
**常見症狀：** 模擬器開機後沒有網路 (Wi-Fi 壞掉)、沒有音效、滑鼠鍵盤無回應。

這個工具包提供了三種解決方案：

1. **自動重包 (Repack) Ramdisk**：將自製的 `.ko` 模組置換到 ramdisk 中，使核心與驅動完美同步。
2. **安全無痛調試**：不破壞原始 Android SDK 檔案，利用命令列參數引導自製核心與 ramdisk 啟動。
3. **GitHub CI 自動化**：利用 Actions 自動下載 GKI 源碼並編譯，您只需下載產出的 Artifacts 即可使用。

---

## 🛠️ 工具說明

### 1. `repack-ramdisk.py` (跨平台 Python 解包工具)

一個不依賴宿主機 `cpio` 命令行工具的純 Python 腳本。它能解析 `lz4` 或 `gzip` 壓縮的 `ramdisk.img`，將您編譯出來的核心模組（包含 `kernelsu.ko` 與原廠 goldfish 模組）置換進 `lib/modules/` 內並重新打包。
**相容性**：Windows, Linux, macOS

```bash
python repack-ramdisk.py <SDK原始_ramdisk.img> <您的_modules路徑> <輸出_ramdisk-ksu.img>
```

### 2. `install-ksu-avd.sh` (模擬器內部打包方案)

當您的開發環境（例如純 Windows）缺乏 Python 或相關依賴時，這個腳本透過 `adb` 將原始 `ramdisk.img` 與 `.ko` 模組推送到**已經啟動的 AVD 內部**，利用 Android 內建的精簡版 Linux 工具鏈進行解包重包，再將成品拉回電腦。

* **特色**：支援 Windows Git Bash / WSL 路徑自動解析。

```bash
# 1. 啟動您的 AVD
emulator -avd <您的AVD名稱>
# 2. 執行腳本，傳入包含 bzImage 與 modules 目錄的 artifact 路徑
./install-ksu-avd.sh /path/to/artifact
```

### 3. `install-avd.sh` (無痛安全啟動配置)

如果您有本地 `cpio`/`lz4` 環境（Linux/macOS/WSL），此腳本會在本地解包置換，並產生不污染原廠 SDK 的 `kernel-ksu` 與 `ramdisk-ksu.img`，讓您可以安全地進行測試與回滾。

* **特色**：完美支援 Windows Git Bash 與 WSL 環境中的 Android SDK / AVD 路徑定位。

```bash
./install-avd.sh /path/to/artifact <您的AVD名稱>

# 啟動時請使用腳本提示的指令：
emulator -avd <您的AVD名稱> -kernel <AVD_DIR>/kernel-ksu -ramdisk <AVD_DIR>/ramdisk-ksu.img -no-snapshot-load -show-kernel
```

---

## ☁️ GitHub Actions 工作流程

本專案包含一組完整的 GitHub CI 流程（位於 `.github/workflows/`）。如果您不想在本地端配置龐大的 Android 核心編譯環境（需下載數十 GB 的源碼並耗時數小時），您可以直接利用 GitHub Actions：

1. 在您的 Fork 中，前往 **Actions** 頁籤。
2. 觸發 **Build Kernel** 工作流，並填寫您需要的核心版本（如 `6.1.75-android14-2024-05`）、架構（`x86_64` 或 `aarch64`）以及 KernelSU 分支。
3. 等待編譯完成後，從 Artifacts 下載產生的壓縮包。
4. 壓縮包內將包含 `bzImage` (或 `Image`) 與 `modules` 目錄。
5. 將該壓縮包解壓後作為 `<artifact-dir>`，搭配上述腳本部署至本地 AVD 即可！

---

## 💻 Windows (WSL / Git Bash) 用戶特別指南

本專案的腳本經過優化，已完美相容於 Windows 環境：

* **路徑解析**：自動轉換 Android SDK 內部 `config.ini` 中的反斜線 (`\`)。
* **WSL 整合**：如果您在 WSL 中執行腳本，系統會自動透過 `wslpath` 尋找 Windows 宿主機的 `C:\Users\username\AppData\Local\Android\Sdk` 與 `C:\Users\username\.android\avd`。
* **前置條件**：請確保在 Git Bash 或 WSL 中可以執行 `adb` 指令。

### Q: 執行腳本時提示找不到 `modules/` 資料夾？

若您是在本地端編譯 AVD 核心（例如 `common-android13-5.15`），編譯產出的模組資料夾名稱通常叫做 `kernel_x86_64_modules` 或者是放在 `system_dlkm_staging_archive` 內。
腳本預期模組存放在名為 `modules` 的子目錄。請在您的輸出路徑中建立軟連結，例如：

```bash
ln -s kernel_x86_64_modules out/dist/modules
```

然後再將 `out/dist` 作為參數傳給腳本即可。
