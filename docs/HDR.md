# Ultra HDR 實作說明

本文件說明 igapp 的 Ultra HDR（JPEG gain map）匯入、預覽、匯出與相關設定的完整實作，
供未來維護參考。**動到任何 HDR 程式碼前請先讀完「核心設計」與「維護注意事項」兩節。**

---

## 1. 目標與範圍

- **無損匯入/匯出**：原圖（含 gain map、EXIF、ICC）盡可能 byte-for-byte 保留。
- **真 HDR 預覽**：編輯畫布上的 Ultra HDR 圖以真實 HDR headroom 呈現，而非 SDR 底圖。
- **SDR↔HDR 互換**：SDR 圖可合成 HDR；HDR 圖可調整亮度。
- **全域 HDR 開關 + 每張圖亮度 + 背景 HDR 白**。
- **裝置需求**：Android 14（API 34，`UPSIDE_DOWN_CAKE`）以上才有 `Gainmap` API。
  低於 34 或關閉 HDR 時，一律安全降級成 SDR。

---

## 2. 模組地圖

### 原生（Kotlin）`android/app/src/main/kotlin/com/igapp/igapp/`

| 檔案 | 職責 |
|---|---|
| `hdr/UltraHdrSupport.kt` | 能力偵測、Ultra HDR 判定（`fileLooksUltraHdr` 掃 JPEG 標頭找 `hdrgm`）、`decodeWithGainmap`、`inspectImage`、`applyPreviewBrightness`、視窗 color mode 切換 |
| `hdr/GainmapMath.kt` | `CanonicalGainmapSpace`：gain map 的正規化編碼空間與所有數學（LUT 重映射、SDR 合成、亮度縮放、metadata 組裝） |
| `hdr/NativePageRenderer.kt` | **唯一的 Android 匯出路徑**：合成圖片＋文字、組裝輸出 gain map、輸出 JPEG bytes |
| `hdr/HdrImageView.kt` | 即時 HDR 預覽用的 `PlatformView`（**hybrid composition**），含 crop 矩陣與亮度 |
| `ImageAssetStore.kt` | 匯入（內容定址原圖 + 預覽快取）、相簿寫入（重算 JPEG 或無損直出） |
| `MainActivity.kt` | 註冊 channel、第一幀前設定視窗 color mode、接收分享進來的圖片 |

### Dart `lib/hdr/`

| 檔案 | 職責 |
|---|---|
| `ultra_hdr.dart` | `HdrExportMode`(off/on/enhanced)、`HdrCapabilities`、`UltraHdr`（`capabilities`/`isUltraHdrFile`/`setWindowHdrColorMode`） |
| `hdr_image_view.dart` | `HdrImageView` widget（hybrid composition、crop、亮度） |
| `lossless_passthrough.dart` | `evaluateLosslessExport` — 判斷某頁能否走 byte-for-byte 無損直出 |

其他：`lib/app_settings.dart`（全域 HDR 開關，鍵 `settings_hdr_enabled`）、
`lib/settings_page.dart`（設定 UI）、`lib/blank_page.dart`（匯入偵測、HDR 徽章、
每張圖亮度滑桿、背景 HDR 白、匯出 payload 組裝）。

### Platform channels

| Channel | 方法 |
|---|---|
| `igapp/gallery` | `prepareImageAsset`、`readImageBytesForExport`、`saveJpgToGallery`、`saveOriginalToGallery`、`renderPageToJpgNative` |
| `igapp/hdr` | `getCapabilities`、`setHdrColorMode`、`inspectImage` |
| `igapp/share` | `getPendingSharedImages`（拉）、`sharedImagesReceived`（推） |
| `igapp/hdr_image_view` | `PlatformViewFactory`（`HdrImageViewFactory`） |

---

## 3. 核心設計

### 3.1 Gain map 的兩組參數（務必分清楚）

一張 Ultra HDR 的 `Gainmap` 有兩類參數，意義完全不同：

1. **編碼參數（gain 怎麼存）**：`ratioMin`、`ratioMax`、`gamma`。
   決定 0–255 的儲存值如何對應到實際增益 `gain`：
   `log2(gain) = lerp(log2(ratioMin), log2(ratioMax), (p/255)^gamma)`

2. **顯示適配參數（gain 怎麼套）**：`epsilonSdr`、`epsilonHdr`、
   `displayRatioForFullHdr`（HDR 容量上限）、`minDisplayRatioForHdrTransition`（下限）。
   決定「螢幕要有多少 HDR headroom，才把 gain 套到多滿」：
   `weight = clamp((log2(顯示headroom) − log2(capMin)) / (log2(capMax) − log2(capMin)), 0, 1)`
   最終 `HDR = (SDR + epsilonSdr) · gain^weight − epsilonHdr`。

> ⚠️ **`displayRatioForFullHdr` 不是 `ratioMax`。** 早期 bug 就是匯出時把
> `displayRatioForFullHdr` 釘死成 `canonMax`（峰值增益比），手機 headroom 達不到 →
> gain 只套一半 → 匯出比預覽暗。修法見 §6.2。

### 3.2 Canonical gain map space（`CanonicalGainmapSpace`）

多張來源各自有不同的 `ratioMin/Max/gamma`，無法直接畫在同一張輸出 gain map 上。
解法：定義一個**正規化空間**（`gamma = 1`、共用 `canonMin`/`canonMax`），把每張來源的
gain map 透過 256-entry LUT 重新編碼進這個空間，再依 z-order 疊上去。

- `forSources(sourceRanges, extraMaxGain)`：算出涵蓋所有來源 + 合成/背景所需的
  `canonMin`/`canonMax`。
- `lutFor(srcMin, srcMax, srcGamma, brightness)`：把某來源某通道的儲存值翻成本空間，
  並順帶套用**每張圖亮度**（log 空間乘 `brightness`）。
- `remapContents(...)`：對整張 gain map bitmap 套 LUT。
- `neutralValue`：`gain = 1`（無增益）的儲存值，用來填**所有 SDR 區域**（背景、SDR 圖、
  文字），確保 SDR 內容在 HDR 匯出中外觀不變。
- `toGainmap(contents, capMax, capMin, epsSdr, epsHdr)`：把輸出 contents 包成 `Gainmap`，
  **顯示適配參數從來源帶入**（不是寫死）。
- `synthesizeFromSdr(base, downscale, maxGain)`：SDR→HDR 合成（高光逆 tone map，
  `SYNTHESIS_LUMA_START` 以上平滑升到 `maxGain`）。
- `scaledGainmap(source, brightness)`：**預覽**用，把現成 gain map 的 `ratioMin/Max`
  在 log 空間乘 `brightness`（即各自 `pow(brightness)`），contents/gamma/metadata 不動，
  不必重算就能調亮度。

---

## 4. 各條路徑

### 4.1 匯入（`ImageAssetStore.prepareImageAsset`）
- 原圖以 **SHA-256 命名**複製進 `filesDir/project_images/<projectId>/originals/`（內容定址、去重、無路徑穿越；`projectId` 是純數字時間戳）。
- 產生縮放預覽到 `previews/`（API 34+ 的 JPEG 編碼會保留縮放後的 gain map，預覽檔仍是 Ultra HDR）。
- `isUltraHdr` 由 `fileLooksUltraHdr`（掃標頭找 `hdrgm`，不需整張 decode）判定，存進 element data。
- 舊專案沒有 `isUltraHdr` 旗標 → `blank_page.dart` 的 `_backfillUltraHdrFlags` 開檔時補掃。

### 4.2 即時預覽（`HdrImageView`）
- **走 hybrid composition**（`PlatformViewsService.initExpensiveAndroidView`），不是預設的
  texture-layer。原因見 §6.1。
- `UltraHdrSupport.decodeWithGainmap`（上限 `MAX_DECODE_SIDE = 2048`）→
  `applyPreviewBrightness`（HDR：`scaledGainmap`；SDR>1：合成）→ `ImageView`。
- crop：用 `Matrix`（`ScaleType.MATRIX`）複刻 Flutter `_CroppedImageFile` 的幾何，
  HDR 不被 Flutter SDR 圖層裁掉。
- 路由條件（`blank_page.dart` 的 `_ImageElementWidget` / `_PreviewImageElementWidget`）：
  `(isUltraHdr || hdrBrightness > 1) && !crop 模式 && Android && hdrEnabled`。
  crop 拖曳當下退回 `_CroppedImageFile`（即時反饋），放手後恢復 HDR。

### 4.3 匯出（`NativePageRenderer.render`）
- **所有 Android 頁面**都走原生（含文字，用 `TextPaint`/`StaticLayout` 對齊 Flutter
  Roboto w700、`height 1.12`），所以文字頁也保住 HDR。
- 先把圖片＋文字畫進 SDR base bitmap；同時收集每個元素的 `GainmapOp`
  （`DrawSource`／`Synthesize`／`NeutralRect`／`NeutralText`）。
- `attachGainmapIfNeeded`：建 canonical space → 依 z-order 把各 op 畫進輸出 gain map →
  顯示適配參數從來源彙整 → `bitmap.gainmap = ...` → 壓 JPEG（quality 100）。
- **無損直出**（`lib/hdr/lossless_passthrough.dart` + `ImageAssetStore.saveOriginalToGallery`）：
  單張滿版未裁切的照片 → 直接 byte-for-byte 複製原檔，零重編碼。不符條件則回退原生重算。

---

## 5. 本次新增功能（v1.7.3）

### 5.1 每張圖 HDR 亮度（`element.data['hdrBrightness']`，預設 1.0）
- **HDR 原圖**：範圍 0–200%（1.0 = 原樣）。在 log 空間縮放既有 gain。
  - 匯出：`lutFor` 的 `brightness` 參數；canonical 範圍用 `srcMax^brightness`。
  - 預覽：`scaledGainmap`（`ratioMin/Max` 各 `pow(brightness)`）。
- **SDR 圖**：範圍 1–4x（1.0 = 不變 = 純 SDR）。>1 才合成 HDR，峰值 = `brightness`。
  - 匯出：`synthGain = max(brightness, 全域 enhanced ? 2 : 1)`，>1 走 `Synthesize`。
  - 預覽：`applyPreviewBrightness` 對 SDR 圖合成。
- UI：`_ImageSettingsTabPage` 的滑桿（依 `isUltraHdr` 切換範圍/標籤/單位）。
  僅在全域 HDR 開啟時顯示。

### 5.2 背景「HDR 白」（page preset `hdr_white`）
- 背景色選單新增「HDR白」卡片，色值仍是白（`0xFFFFFFFF`），靠 preset 旗標區分。
- 匯出：`backgroundHdr` 為 true 時，輸出 gain map 的**背景填色**改成
  `+1 stop`（`HDR_WHITE_BACKGROUND_GAIN = 2f`）而非 neutral；SDR 圖/文字仍填 neutral。
- ⚠️ **限制**：編輯畫布的背景是 Flutter SDR 圖層（非 platform view），所以「HDR 白」**只在
  匯出與匯出後 HDR 預覽**呈現，即時畫布仍是一般白。這是架構限制，非 bug。

---

## 6. 兩個關鍵正確性修正（別改回去）

### 6.1 預覽/匯出一致 → hybrid composition
預設 `AndroidView` 走 texture-layer composition，會把原生 view 複製進一張 8-bit SDR 的
GL 材質 → HDR 高光被 tone map/裁掉。所以原生算圖（匯出）對，內嵌畫布卻變 SDR。
`HdrImageView` 改用 hybrid composition（`initExpensiveAndroidView`），原生 `ImageView`
以真正的 Android view 留在畫面層級，HDR 才到得了螢幕。

### 6.2 匯出不比預覽暗 → 帶入來源顯示適配參數
重建輸出 gain map 時，`epsilonSdr/Hdr`、`displayRatioForFullHdr`、
`minDisplayRatioForHdrTransition` **從來源 gain map 帶入**（單張來源完全還原；多張取
最寬：`displayRatioForFullHdr` 取 max 並夾到 `canonMax`、轉場下限取 min）。
不要再把 `displayRatioForFullHdr` 寫死成 `canonMax`。

---

## 7. 資料模型

### `element.data`（圖片元素）
| 鍵 | 型別 | 說明 |
|---|---|---|
| `src` / `originalSrc` | String | 預覽路徑 / 原圖路徑 |
| `isUltraHdr` | bool | 來源是否 Ultra HDR |
| `hdrBrightness` | double | 每張圖亮度（HDR 0–2、SDR 1–4，預設 1） |
| `cropOffsetX/Y`、`cropScale` | double | 裁切 |
| `aspectRatio`、`originalAspectRatio` | double | 比例 |
| `borderRadiusRatio` | double | 圓角 |

### `page.extras`（頁面）
| 鍵 | 說明 |
|---|---|
| `backgroundColorValue` | 背景色 ARGB |
| `backgroundColorPreset` | `white`/`black`/`ig_black`/**`hdr_white`**/`custom` |

### 匯出 payload（`renderPageToJpgNative`）
- 頁：`aspectWidth/Height`、`backgroundColor`、**`backgroundHdr`**、`elements`。
- 元素：座標/裁切/圓角、**`hdrBrightness`**、文字欄位。
- 頂層：`exportWidth`、`targetPageIndex`、`hdrMode`(off/on/enhanced)、`images`、`pages`。

---

## 8. 可調參數（tunable constants）

| 常數 | 檔案 | 預設 | 意義 |
|---|---|---|---|
| `SYNTHESIS_MAX_GAIN` | GainmapMath | 2f | 全域 enhanced 模式的 SDR 合成峰值 |
| `SYNTHESIS_LUMA_START` | GainmapMath | 0.6f | 合成增益開始上升的亮度 |
| `SYNTHESIS_DOWNSCALE` | GainmapMath | 4 | 合成 gain map 的降採樣 |
| `HDR_WHITE_BACKGROUND_GAIN` | NativePageRenderer | 2f | 背景 HDR 白的固定增益 |
| `MAX_DECODE_SIDE` | HdrImageView | 2048 | 預覽 decode 邊長上限 |
| `_hdrBrightnessHdr/SdrMin/Max` | blank_page.dart | 0–2 / 1–4 | 亮度滑桿範圍 |

---

## 9. 維護注意事項 / 已知風險

1. **Bitmap 回收**：原生路徑大量手動 `recycle()`。新增中間 bitmap 時務必在 `finally` 回收
   （`NativePageRenderer.render` 的 `gainmapOps`、`outputGainmapContents`、`baseBitmap`）。
2. **文字必須讀成 neutral**：文字會蓋掉底下像素，在 gain map 中其字形一律填 `neutralValue`
   （`GainmapOp.NeutralText`），否則文字會吃到底下的 HDR。
3. **多來源容量取捨**：一張輸出 gain map 只有一組顯示適配參數。單張來源完全還原；多張不同
   `displayRatioForFullHdr` 時取 max（不過曝），代價是容量較小者在中階螢幕略暗。
4. **無損直出條件**要與原生 crop 幾何保持一致（`lossless_passthrough.dart` 的判斷 vs
   `NativePageRenderer.sourceCropRectForFrame`）。改其一要回頭檢查另一。
5. **文字度量對齊**：原生 `TEXT_LINE_HEIGHT = 1.12f` 必須對齊 Flutter 端的 `height`。
   字級/換行邏輯改動時兩邊要同步，否則文字頁原生算圖會跑版。
6. **全域 enhanced 與每張圖亮度的交互**：SDR 合成峰值 =
   `max(該圖 hdrBrightness, enhanced ? 2 : 1)`。改其一留意另一。
7. **尚未在多種真機上廣泛驗證**：亮度範圍與 `HDR_WHITE_BACKGROUND_GAIN` 都是可調常數，
   依實機觀感微調即可，不需動演算法。
8. **視窗 color mode** 必須在第一幀前設好：`MainActivity.onCreate` 直接讀
   `FlutterSharedPreferences` 的 `flutter.settings_hdr_enabled`（鍵需與 Dart 端同步）。

---

## 10. 測試

- `test/lossless_passthrough_test.dart`：無損直出判斷的單元測試（11 個案例）。
- `flutter analyze`：應維持與 master 基線相同的 issue 數、**0 新增**。
- 真 HDR 效果**必須真機驗證**（Android 14+、面板支援 HDR）。重點：
  1. 匯入 Ultra HDR → 編輯畫布應見 HDR 色調；
  2. 每張圖亮度滑桿 → 預覽即時變化、匯出一致；
  3. SDR 圖拉亮度 > 1 → 預覽/匯出出現合成 HDR；
  4. 背景「HDR白」→ 匯出（及匯出後 HDR 預覽）白底發亮；
  5. 預覽與匯出成品亮度一致（§6 兩個修正）。

---

## 11. 相關歷史

- 分支 `feature/ultra-hdr-support` 從 master（v1.6.1）開出，已透過 PR #1 併回 master。
- 明確**不參考**舊實驗分支：`feature/ultra-hdr`、`codex-hdr-input-output`、
  `fix/hdr-gainmap-metadata-mismatch`。未來 HDR 工作以本實作為基礎。
