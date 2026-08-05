# SDD 進度狀態

> ⚠️ 請勿刪除。這是跨對話的記憶檔。每次開新 session 先讀這份。

**專案**：OpenNet iOS Take-Home — 即時賽事賠率系統
**最後更新**：2026-08-05

---

## 目前階段

**Phase 2/3 — Spec Interview 完成，規格書草案已產出，等待人工審閱**

---

## 已完成

- [x] **Phase 1 Brain Dump** — 來源為 `OpenNet_IOS_Home_Test.pdf`，已完整抽出文字（2 頁）
- [x] **Phase 2 Spec Interview** — 已問 2 題並取得決議（見下方決策紀錄）
- [x] **Phase 3a Feature Spec** — `docs/spec.md` v0.1 草案完成

- [x] **開工前置作業** — Xcode 專案 `OddsBoard` 建立完成、Storyboard 移除、手動 UIWindow 啟動可運行
- [x] **Repo 建立並推送** — `git@github.com:iRogerz/OddsBoard.git`（private）

## 待辦

- [ ] **Phase 3b** — 產出 `CLAUDE.md`（專案憲法：技術棧、不可違反的架構規則、目錄結構、agent 行為指令）
- [ ] 建立 `Packages/OddsCore`、`Packages/OddsUI` 兩個 SPM package 與 SwiftLint 規則
- [ ] **D1** — Domain 模型、`MockAPIClient`、`actor OddsStore` + 單元測試
- [ ] **Phase 4** — Context Reset (`/clear`) 後進入 PEV 迴圈實作，實作 agent 只讀 `CLAUDE.md` + `docs/spec.md`
- [ ] **Phase 5** — Anti-Drift + Hashimoto（每個 bug 留下一條 lint/test）
- [ ] **Phase 6** — Skill 萃取

---

## 關鍵決策紀錄

| 日期 | 決策 | 理由 |
|---|---|---|
| 2026-08-05 | **UI 用純 UIKit，不用 SwiftUI** | 使用者原本想用 SwiftUI，經指出考題技術限制表格明文「限定使用 UIKit（不可使用 SwiftUI）」後決定照文件走，較保險 |
| 2026-08-05 | **禁 RxSwift，但允許 SnapKit（僅限 `OddsUI`）** | 判準是「是否取代文件指定的技術」而非「有無第三方相依」。RxSwift 會取代 Concurrency/Combine ⇒ 禁；SnapKit 只是 Auto Layout 語法糖 ⇒ 可。原先「零第三方相依」是我方自訂規則、非文件要求，已修正 |
| 2026-08-05 | **採用本地 SPM package：`OddsCore` + `OddsUI`** | 使用者選擇更低耦合。附帶效益：`OddsCore` 無 UIKit ⇒ 測試可用 `swift test` 命令列跑、免模擬器、約 2 秒 |
| 2026-08-05 | **Xcode 專案由使用者手動建立** | 手刻 pbxproj 脆弱；已給出建立參數（App template / Storyboard interface / Testing None / iOS 16.0）|
| 2026-08-05 | **Repo 根目錄設在 `OddsBoard/`，題目 PDF 留在 repo 外層** | 保留 Xcode 既有 git 歷史（不必刪 `.git`），且公司內部題目 PDF 在物理上不可能被誤 push |
| 2026-08-05 | **GitHub repo 設為 private** | take-home 解答若公開會被永久索引；交件時邀請面試官為 collaborator 或屆時再轉 public |
| 2026-08-05 | **Concurrency 與 Combine 並用，邊界明確** | 跨執行緒狀態存取 → actor/AsyncStream；ViewModel→View 綁定 → Combine。文件的架構說明文件正好要求說明兩者使用場景 |
| 2026-08-05 | Deployment target iOS 16.0 | `reconfigureItems` 需 iOS 15+，是「不整頁 reload」的核心 API |

---

## 尚未解決的問題

見 `docs/spec.md` §12（5 項），全部有預設值，不阻擋開工。

---

## 給下一個 session 的提醒

- 唯一真實來源是 `docs/spec.md`。實作與規格衝突時改實作。
- 本題最核心的驗收條件是「賠率更新不可整頁 reload」→ 對應 spec §4 FR-3.3 的三層策略。
- 規格書用 📄/⭐/🧩/❓ 標記需求來源，🧩 是文件沒寫、我方主動補的設計，交件的架構文件要能逐條解釋。
