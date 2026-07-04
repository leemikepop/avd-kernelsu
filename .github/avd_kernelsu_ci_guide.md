# AVD-KernelSU GitHub Actions CI 架構分析與指南

`avd-kernelsu` 專案中的 `.github` 資料夾包含了一套完整且強大的自動化持續整合（CI）管線。這套管線的核心目標是：**完全在雲端為 Android Virtual Device (AVD) 自動編譯包含 Root (KernelSU / SuSFS) 的自訂核心與模組**，幫助開發者免去本地端數十 GB 源碼與繁雜的編譯環境設定。

以下是針對該 CI 架構的完整分析與使用指南。

---

## 🏗️ 架構全貌 (Architecture)

整個 `.github` 目錄設計採用了模組化架構，將複雜的編譯流程拆解為可重複使用的 **Composite Actions**（自訂動作），並利用多層級的 **Workflows** 進行任務排程。

### 1. Workflows (工作流排程)

位於 `.github/workflows/`，負責定義觸發條件與任務矩陣。

* **`main.yml`**: CI 的主入口點。
  * **觸發機制**：支援 `workflow_dispatch` 手動觸發，並允許使用者選擇：**KSU 版本** (KernelSU / KernelSU-Next / SukiSU-Ultra)、**編譯核心目標** (A14-6.1, A15-6.6 等)、**架構** (x86_64, aarch64) 以及是否要釋出 Release。
  * **排程邏輯**：它會先發送一個 job (`fetch-commits`) 查詢上游 KernelSU 的最新 Git commit，接著利用 GitHub Actions 的 matrix 呼叫 `prepare.yml`，最後將所有編譯好的核心自動打包壓縮，生成 GitHub Release。
* **`prepare.yml`**: 負責讀取 `.github/kernel-config` 目錄下的 JSON 檔案（例如 `a14-6.1.json`），生成跨架構的動態編譯矩陣，然後呼叫核心編譯腳本 `build.yml`。
* **`build.yml`**: **最核心的編譯腳本**。它整合了以下步驟：
    1. 釋放 GitHub Runner 磁碟空間（移除不需要的預裝軟體）。
    2. 下載 Google Android GKI 核心源碼。
    3. 套用 `glibc 2.38` 等舊版編譯相容性修補。
    4. 呼叫客製化 Actions 注入 KernelSU 並修改核心參數。
    5. 使用 Bazel 或傳統 `build.sh` 進行核心與虛擬裝置（Virtual Device）驅動模組的編譯。
    6. 將 `bzImage` (或 `Image`) 與所有產出的 `.ko` 模組打包成 Artifacts。

### 2. Custom Actions (客製化動作)

位於 `.github/actions/`，是編譯流程的靈魂，主要解決 AVD 相容性與 KSU 整合的問題：

* **`setup-ksu`**:
  * **功能**：根據使用者的選擇，動態下載對應的 Root 方案腳本（KernelSU 官方、KernelSU-Next 或 SukiSU-Ultra），將其整合進核心樹，並強制將 `CONFIG_KSU=y` 寫入 `gki.fragment`（核心設定片段檔）。
* **`configure-kernel`** (⭐ 關鍵黑科技):
  * **功能**：對於 AVD 模擬器，有很多硬體是虛擬化的（如 virtio 網路、virtio 磁碟）。如果這些模組不是編譯在核心內 (`=y`) 而是外部模組 (`=m`)，開機時如果 `ramdisk` 模組沒掛載好就會當機。這個 action 會掃描並將所有 `CONFIG_VIRTIO_*` 與 `CONFIG_GOLDFISH` 等相關設定強制設定為 `y`，大幅提升 AVD 開機的成功率與穩定性。
* **`clean-flags`**:
  * **功能**：在修改核心後，官方腳本常會自動給核心版本加上 `-dirty` 後綴，這會導致核心無法通過 Android 的 KMI（Kernel Module Interface）符號嚴格檢查。這個腳本會透過正則表達式移除 `-dirty` 標記，並關閉 Bazel 的嚴格檢查。
* **`download-kernel`**:
  * **運作機制**：利用 `repo` 工具同步 Android GKI 核心源碼。它使用 `repo init -b common-${inputs.android_version}-${inputs.kernel_version}-${inputs.os_patch_level} --depth=1` 的方式。這代表它抓取的是該 GKI 分支的 **最新提交 (Branch HEAD)**，而非某個特定 AVD 版本的歷史 Build ID。
  * **與 AVD 實際運行的差異與痛點**：
    * **核心版本不一致 (Vermagic Mismatch)**：原廠 AVD 映像檔的核心通常鎖定在某個特定的歷史編譯點（例如 Android 14 6.1 核心原廠為 `6.1.23`）。但 GitHub CI 同步的是分支 HEAD，會編譯出更新的核心版本（例如 `6.1.162`）。這導致我們必須手動將編譯產出的所有 `.ko` 模組打包置換進 AVD 的 ramdisk 中，否則核心會因為 Vermagic 不匹配拒絕載入驅動。
    * **安全性硬化核心 (Syscall Hardening)**：因為 CI 抓的是最新的分支 HEAD，這些最新的分支已經被 Google 移植了 upstream 的安全性修正（如 `sys_call_table` 改為 inlined `switch-case` 分支）。這會強行觸發 KernelSU 的 `X86_FEATURE_INDIRECT_SAFE` 安全機制。若像 `build.yml` 中那樣使用 `sed -i` 強行跳過檢查，KernelSU 會在 runtime 發生攔截失效，導致 `stat` 系統呼叫回傳 `-ENOSYS`，讓 AVD 在掛載階段陷入 Signal 6 無限重啟。
    * **為什麼手動編譯更易成功**：手動編譯（如 `installation_guide.md` 所示）是透過 `curl` 下載 Android CI 對應原廠 AVD Build ID 的 `manifest_9964412.xml` 來精確還原 2023 年的舊版源碼。該舊版源碼中**沒有**併入 syscall table 硬化，因此可以使用舊版或傳統 KernelSU (如 `v0.9.5` 或 `v0.7.x`) 的 syscall table hook 機制，無痛開機成功。

---

## 📘 如何使用這套 CI 產出？(使用指南)

若您是開發者，您不需要在本地編譯，可以直接透過以下步驟取得您需要的 Root 核心：

### 步驟一：觸發雲端編譯

1. Fork `avd-kernelsu` 專案到您的 GitHub 帳號下。
2. 點擊倉庫頂部的 **Actions** 頁籤。
3. 在左側選擇 **Build AVD Kernels with KernelSU** 工作流。
4. 點擊右側的 **Run workflow** 按鈕。
5. 在彈出的選項中設定：
    * **KernelSU variant**: 選擇 `KernelSU-Next`（我們研究推薦的版本，自帶 SuSFS）。
    * **Kernel version to build**: 選擇您目標 AVD 的版本（例如 `a14-6-1` 代表 Android 14, 核心 6.1）。
    * **Target architecture**: 選擇 `x86_64` (給 Windows 電腦上的 AVD 使用)。
    * **Release type**: 選擇 `Actions`（僅保留在 Artifacts 中）或 `Release`（直接發布為公開 Release 檔）。
6. 點擊 **Run workflow**，然後等待約 1~2 小時讓 GitHub 幫您編譯完成。

### 步驟二：下載 Artifact

1. 當 Workflow 顯示綠色打勾完成後，點入該次執行紀錄。
2. 滑到最下方的 **Artifacts** 區塊。
3. 下載名為類似 `6.1.75-android14-2024-05-x86_64` 的 `.zip` 壓縮檔。

### 步驟三：本地端部署

將下載下來的壓縮檔解壓縮，您會得到：

* `bzImage` (您的新核心)
* `modules/` (對應此核心的驅動模組，如 `mac80211_hwsim.ko` 等)
* `modules-initramfs.gz` (這是 CI 幫您打包好的純模組 ramdisk，但不含 AVD 根目錄，較少單獨使用)

接下來，您就可以搭配我們稍早優化過的 Windows 版腳本，為您的 AVD 安裝這個核心：

```bash
# 在 Git Bash 中執行
./install-avd.sh /path/to/extracted_artifact <您的AVD名稱>
```

腳本會自動將 Artifact 內的模組塞入 AVD 的 ramdisk 中，並生成 `kernel-ksu` 與 `ramdisk-ksu.img`，讓您的模擬器立刻擁有強大的 KSU 與 SuSFS 隱藏能力！
