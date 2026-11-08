# Vime

[简体中文](README.md) | **繁體中文** | [English](README.en.md) | [日本語](README.ja.md) | [한국어](README.ko.md)

![Platform](https://img.shields.io/badge/platform-iOS%2018%2B-blue) ![Swift](https://img.shields.io/badge/Swift-UIKit%20%2B%20SwiftUI-orange) ![License](https://img.shields.io/badge/license-GPL--3.0--or--later-green)

Vime 是一款完全離線的 iOS 日語輸入法，也可以用拼音輸入簡體或繁體中文。它支援羅馬字 QWERTY 和假名九宮格兩種佈局，平假名、片假名和英文可以隨時切換。假名漢字轉換以 [azooKey](https://github.com/azooKey/AzooKeyKanaKanjiConverter) 辭典引擎為基礎，再由裝置上的小型 Core ML 語言模型為候選字詞重新排序，並在確認文字後提供下一詞聯想。中文拼音輸入以 [librime](https://github.com/rime/librime) 為基礎。轉換、糾錯、學習和聯想都在本機完成，輸入內容不會上傳。

主應用程式負責啟用引導、試打練習、外觀自訂和各項設定；系統鍵盤延伸功能可在任何支援第三方鍵盤的 App 中使用。

## 特色

### 輸入

- **兩種日語佈局**：羅馬字全鍵盤；或假名九宮格，點按輸入あ段，上下左右滑動輸入其他段，連續點按同一鍵依序切換（トグル入力）。九宮格附有 `↶` 退回、`゛゜小` 修飾和 `→` 結束連打鍵，「確定」佔兩列高度，更好按。
- **即時假名草稿**：輸入時立即顯示假名，尚未組成假名的子音保留為羅馬字；轉換和預測在背景更新，不會打斷輸入。
- **英文直接輸入**與日英一鍵切換，候選欄提供單字補全；自動大寫和連按兩下空白鍵輸入句號可在設定中開啟。數字頁可選九宮格或全鍵盤。
- 長按空白鍵拖動，或在按鍵區橫向滑動，都能移動游標；字母鍵上滑輸入符號。
- 連按兩下 Shift 鎖定大寫；直向 iPhone 可開啟**單手模式**，按鍵靠左或靠右。

### 轉換與候選

- **整句與分段轉換**：展開候選後用 `−` / `+` 調整前段範圍，確認前段後繼續轉換後段，內文只寫入已確認的部分。
- **復原轉換**：確認轉換後，點候選欄開頭的 ↩ 即可回到讀音重新選擇；也可在設定中改為按刪除鍵復原。
- **即時轉換**（ライブ変換，預設關閉）：輸入時直接顯示轉換結果，不必按空白鍵；空白鍵切換到下一個候選（次候補），Return 鍵會等結果出現後再確認。可在設定或鍵盤快速設定中開關。
- **智慧排序**：azooKey 產生候選，再由本機語言模型（INT8、僅 CPU）參考上文重新評分；也可改用純辭典排序。
- **下一詞聯想**：確認文字後，閒置的候選欄會顯示後續字詞，點一下即可接著輸入。
- **糾錯候選**：誤觸鄰鍵、近音和有限的多音錯誤會以候選形式出現，只有在您選取時才會採用。
- **日語中用拼音查詞**（中日混輸）：日語模式下以漢語拼音也能找到日語漢字詞，例如 `jiancha` → 検察，拼音和羅馬字也可以混著輸入；候選上方會標注假名讀音。意思與中文不同的詞（如 手紙）會註明它在日語中的意思，並在後面提供中文意思對應的日語詞。可在設定中關閉。
- **格式候選**：半形片假名（ｶﾞｯｺｳ）和全形英數字（ａｂｃ１２３）。

### 中文輸入

- **拼音輸入**：以 librime 為基礎的全拼輸入，支援整句輸入、只打聲母的簡拼和未打完音節的補全，也能辨識常見的誤觸鄰鍵和字母順序打反。
- **中英混輸**：同一串輸入中可以直接輸入英文單字。
- **簡繁切換**：點工具列上的「简 / 繁」按鈕即可切換，繁體由 OpenCC 轉換。
- **中日切換**：上滑語言鍵即可在日語和中文之間切換，也可以在設定中選擇；不需要時可在設定中關閉中文輸入。
- **本機學習**：選過的詞會排得更前面；送出後立刻按刪除鍵刪掉，這次的學習也會一併撤銷。中文學習記錄可以單獨清除。
- 詞庫由多個開源詞表和詞頻資料產生，來源見第三方聲明。

### 效率工具

- **使用者辭典與短語快速輸入**，可匯入 Google 日本語入力、Microsoft IME、ATOK 與 macOS 的使用者辭典，並以 JSON 或 Google 日本語入力文字格式匯出（最多 1,024 筆）；iOS 的文字替代也能直接使用。
- **剪貼簿建議**（預設關閉）：新拷貝的文字會出現在候選欄；另保留最近 24 小時的歷史記錄，只存在本機。
- **數字頁計算**：輸入 `1+1` 時，候選會提供 `2` 和 `1+1=2`。
- **自動補全括號**：支援 `()`、`（）`、`「」` 等，游標會放在括號中間。
- 分類符號、Emoji 和顏文字面板；數字頁左側欄的符號可以自訂。

### 個人化

- 內建多種外觀，也可自建主題：背景、按鍵圖片和配色皆可設定，以 `.vimeskin` 檔案匯入匯出。
- 鍵盤高度可拖動調整，並提供按鍵聲音和可連續調整的震動強度；按鍵預覽的停留時間可在 0–500 毫秒之間調整。
- 在本機學習您的選字習慣：長按候選可刪除該字詞的學習記錄，也可隨時一鍵清除。
- **無障礙**：支援 VoiceOver（九宮格滑動和上滑符號可透過自訂動作輸入）、最大的輔助使用字級、粗體文字和增強對比。

### 主應用程式

- **三步驟啟用引導**：新增鍵盤、允許完整取用、切換到 Vime，完成後自動進入試打。
- **跟打練習**：照著例句輸入，打對的部分逐字標為藍色。
- 設定頁的狀態卡會顯示鍵盤是否正常運作、已載入的模型版本和學習統計。
- 介面支援简体中文、繁體中文、日本語、English 和 한국어。

## 安裝與啟用

需要 iOS 18 或以上版本，以及支援目前 SDK 的 Xcode。

1. 用 Xcode 開啟 [Vime.xcodeproj](Vime.xcodeproj)，選擇 `Vime` scheme。首次建置會解析固定版本的 SwiftPM 相依套件，模型和分詞器資源已包含在儲存庫中。
2. 安裝到實機前，請為主應用程式和 `VimeKeyboard` 延伸功能設定簽署，兩者須使用相同的 App Group（目前為 `group.com.Voltline.Vime`）。詳見 [開發與驗證](Docs/Development.md)。
3. 執行主應用程式，依照首頁引導操作；也可以手動在「設定」→「一般」→「鍵盤」→「鍵盤」→「新增鍵盤⋯」中加入 Vime。
4. 在任一輸入框長按地球鍵，選擇「Vime 日本語」。

基本的離線輸入不需要「允許完整取用」。按鍵聲音和震動、App 與鍵盤共用設定、自訂主題、使用者辭典同步以及剪貼簿建議，需要開啟完整取用。修改設定後，切換到其他鍵盤再切回來，延伸功能就會重新讀取設定。

## 常用操作

| 操作 | 行為 |
| --- | --- |
| 輸入羅馬字 | 即時顯示假名，未完成的子音維持羅馬字 |
| 九宮格點按 / 滑動 | 點按輸入あ段，上下左右滑動輸入其他段；連續點按同一鍵依序切換 |
| `↶` / `゛゜小` / `→` | 退回連打的上一個字 / 切換濁音、半濁音和小寫 / 結束連打，以同一鍵輸入新字 |
| 空白鍵 | 開始轉換，再按切換到下一個候選；沒有輸入中的文字時輸入空白，日語模式可在設定中選半形或全形，Shift + 空白鍵輸入另一種 |
| 點選候選 | 確認該候選；分段時後段繼續保持轉換狀態 |
| 展開候選 → `−` / `+` / `整句` | 調整前段範圍或恢復整句，捲動檢視更多候選 |
| Return / 確定 | 確認已選候選或目前的假名；沒有輸入中的文字時執行宿主 App 的 Return 動作 |
| 刪除 / 長按刪除 | 刪除一個字元 / 連續刪除 |
| `あ` / `ア`、日英鍵 | 切換平假名與片假名，或切換日英輸入 |
| 上滑語言鍵 | 在日語和中文之間切換 |
| `简` / `繁` | 中文模式下切換簡體和繁體 |
| 字母上滑、橫滑按鍵區、長按空白鍵拖動 | 輸入符號、移動游標 |
| 數字鍵、表情鍵 | 開啟數字頁、分類符號或 Emoji 面板 |
| 左上角 Vime 標誌 | 快速設定：剪貼簿歷史記錄、聲音與震動、數字佈局、即時轉換、單手模式、輸入語言 |

候選品質受辭典、上下文和查詢時間預算影響，不保證每個字詞或每種誤輸入都能得到理想結果。目前沒有 macOS 版本。

## 隱私

- 轉換、糾錯、排序、聯想和學習都在裝置上完成，沒有網路請求，不會上傳輸入內容或剪貼簿。
- 學習資料、使用者辭典和主題儲存在 App Group 共用容器中；剪貼簿歷史記錄不納入系統備份。
- 完整說明請見 [隱私權政策](Docs/Guides/Privacy.zh-Hant.md)（另有 [简体中文](Docs/Guides/Privacy.md)、[日本語](Docs/Guides/Privacy.ja.md)、[English](Docs/Guides/Privacy.en.md)、[한국어](Docs/Guides/Privacy.ko.md)）。

## 專案結構

| 目錄 | 內容 |
| --- | --- |
| `Vime/` | 主應用程式（SwiftUI）：首頁、引導、自訂、設定和關於 |
| `Keyboard/` | 鍵盤延伸功能入口 `KeyboardViewController` |
| `Shared/` | App 與延伸功能共用：輸入工作階段、候選引擎、語言模型、鍵盤 UI、設定和資源 |
| `Tests/` | 引擎、候選、工作階段、UI 元件和延伸功能的 XCTest |
| `Dependencies/` | 內建的 SentencePiece 分詞器，以及中文輸入用的 librime（`VimeRime`） |
| `Scripts/` | 資源產生、模型和 App 資源驗證、可重現的測試腳本 |
| `Docs/` | 使用指南、開發流程和架構文件 |

## 開發

```bash
python3 Scripts/validate_model_resources.py
```

```bash
python3 Scripts/validate_app_resources.py
```

前者驗證模型 manifest、分詞器和 SHA256，後者驗證授權聲明、隱私權政策和在地化目錄是否完整。介面文字統一放在 `Shared/Resources/Localizable.xcstrings`，新增文字需要補齊五種語言。完整測試流程（`Scripts/verify_review.sh`）、實際鍵盤延伸功能的驗證方法和疑難排解請見 [開發與驗證](Docs/Development.md)。

## 文件

以下文件以简体中文撰寫。

- [文件索引](Docs/README.md)
- 使用：[App 設定](Docs/Guides/AppSettings.md) · [自訂主題](Docs/Guides/CustomSkins.md) · [使用者辭典](Docs/Guides/UserDictionary.md) · [無障礙](Docs/Guides/Accessibility.md)
- 開發：[專案目錄](Docs/ProjectLayout.md) · [開發與驗證](Docs/Development.md) · [日語模型](Docs/Models/JapaneseModel.md)
- 架構：[輸入與宿主](Docs/Architecture/InputPipeline.md) · [候選與聯想](Docs/Architecture/Candidates.md) · [學習與個人化](Docs/Architecture/Personalization.md) · [輸入後端介面](Docs/Architecture/InputBackends.md) · [表情顯示](Docs/Architecture/EmojiRendering.md)

## 授權與致謝

Vime 以 [GPL-3.0-or-later](LICENSE) 授權發布，並依 GPLv3 第 7 條附加一項額外許可，允許在 App Store 等應用程式商店散布，條件是同時提供對應的原始碼，請見 [LICENSE-EXCEPTION](LICENSE-EXCEPTION)。2026-10-22 之前的版本仍以 GPL-2.0-only 發布。隨附的 [VimeML](https://github.com/Voltline/VimeML) 日語模型採用相同授權，訓練語料的署名請見第三方聲明。假名漢字轉換使用 [AzooKeyKanaKanjiConverter](https://github.com/azooKey/AzooKeyKanaKanjiConverter)，分詞使用 [SentencePiece](https://github.com/google/sentencepiece)。中文輸入使用 [librime](https://github.com/rime/librime) 和 [OpenCC](https://github.com/BYVoid/OpenCC)，拼音詞庫含 CC BY-SA 4.0 資料，並以相同授權發布。第三方程式碼與資料的授權、致謝和來源請見 [ThirdPartyNotices.txt](Shared/Resources/ThirdPartyNotices.txt)、[SentencePiece LICENSE](Dependencies/VimeSentencePiece/LICENSE) 和 [語言資源來源清單](Shared/Resources/LanguageResourceSources.json)，App 內「設定 → 關於 Vime → 開放原始碼元件與授權」也可檢視完整原文。
