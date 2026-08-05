import Foundation

/// 模擬 WebSocket 的賠率推播來源。
///
/// 以固定節拍（預設 100ms）而非「每筆一個 timer」推送：
/// 每秒 1000 筆的加壓情境下，前者是每秒 10 次喚醒，後者是 1000 次。
/// 推播來源本身就不該成為效能瓶頸，否則量到的是模擬器的極限而不是 UI 的極限。
public actor MockOddsSocket: OddsStreaming {

    public struct Configuration: Sendable {

        public var seed: UInt64
        /// 每秒推播筆數。題目要求「最多 10 筆」，Debug 面板可即時調高加壓。
        public var updatesPerSecond: Int
        /// 節拍間隔。每個節拍送出 `updatesPerSecond / 每秒節拍數` 筆。
        public var tickInterval: Duration
        public var reconnectPolicy: ReconnectPolicy
        /// 模擬「重連要試幾次才成功」，讓退避行為在 demo 中看得見。
        public var failedReconnectAttempts: Int

        public init(
            seed: UInt64 = 20_250_704,
            updatesPerSecond: Int = 10,
            tickInterval: Duration = .milliseconds(100),
            reconnectPolicy: ReconnectPolicy = ReconnectPolicy(),
            failedReconnectAttempts: Int = 2
        ) {
            self.seed = seed
            self.updatesPerSecond = updatesPerSecond
            self.tickInterval = tickInterval
            self.reconnectPolicy = reconnectPolicy
            self.failedReconnectAttempts = failedReconnectAttempts
        }
    }

    public nonisolated let events: AsyncStream<OddsStreamEvent>

    private let continuation: AsyncStream<OddsStreamEvent>.Continuation
    private let clock: AppClock
    private let tickInterval: Duration
    private let reconnectPolicy: ReconnectPolicy
    private let matchIDs: [Int]

    private var configuration: Configuration
    private var generator: SeededGenerator
    private var lastKnown: [Int: Odds]
    private var sequence: UInt64 = 0
    private var loop: Task<Void, Never>?

    /// - Parameter initialOdds: 推播是在現值上做小幅漂移，因此必須知道起始值。
    ///   否則賠率會整數亂跳，漲跌提示也就失去意義。
    public init(
        initialOdds: [Odds],
        configuration: Configuration = Configuration(),
        clock: AppClock = SystemClock()
    ) {
        self.configuration = configuration
        self.clock = clock
        self.tickInterval = configuration.tickInterval
        self.reconnectPolicy = configuration.reconnectPolicy
        self.generator = SeededGenerator(seed: configuration.seed)
        self.matchIDs = initialOdds.map(\.matchID)
        self.lastKnown = Dictionary(
            initialOdds.map { ($0.matchID, $0) },
            uniquingKeysWith: { _, new in new }
        )

        // 緩衝上限刻意設定：若消費端一時跟不上，應該丟掉最舊的推播而不是
        // 無限堆積記憶體。賠率是「最新值才有意義」的資料，舊的丟掉無妨。
        let pipe = AsyncStream<OddsStreamEvent>.makePipe(
            bufferingPolicy: .bufferingNewest(256)
        )
        self.events = pipe.stream
        self.continuation = pipe.continuation
    }

    // MARK: - OddsStreaming

    public func connect() {
        guard loop == nil else { return }

        continuation.yield(.connectionState(.connecting))

        // weak self：否則 actor 持有 Task、Task 持有 actor，形成保留循環，
        // 即使 ViewModel 被釋放，推播迴圈仍會永遠跑下去。
        loop = Task { [weak self] in
            await self?.runLoop()
        }
    }

    public func disconnect() {
        loop?.cancel()
        loop = nil
        continuation.yield(.connectionState(.idle))
    }

    public func setUpdatesPerSecond(_ rate: Int) {
        configuration.updatesPerSecond = max(1, rate)
    }

    /// 模擬非預期斷線，並自動進入重連流程（`docs/spec.md` §FR-6）。
    ///
    /// 與 `disconnect()` 的差別：後者是「使用者主動離開」，不該自動重連；
    /// 這裡是「連線掉了」，必須自己想辦法接回來。
    public func simulateDisconnection() {
        guard loop != nil else { return }

        loop?.cancel()
        loop = Task { [weak self] in
            await self?.runReconnect()
        }
    }

    // MARK: - 重連

    private func runReconnect() async {
        var attempt = 1

        while reconnectPolicy.shouldRetry(attempt: attempt) {
            continuation.yield(.connectionState(.reconnecting(attempt: attempt)))

            let delay = reconnectPolicy.delay(forAttempt: attempt, using: &generator)
            do {
                try await clock.sleep(for: delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }

            if attempt > configuration.failedReconnectAttempts {
                // 接回來了。runLoop 會送出 .connected 並恢復推播；
                // 消費端據此觸發全量對帳（§FR-6.4）—— 斷線期間的推播是
                // 永久遺失的，不重抓一次就會永遠停在舊賠率。
                await runLoop()
                return
            }
            attempt += 1
        }

        // 超過上限就停手，把控制權交還給使用者，而不是無限重試默默耗電。
        continuation.yield(.connectionState(.failed))
    }

    // MARK: - 測試與 Debug 用

    /// 產生並送出一個節拍的推播。
    ///
    /// 獨立成一個方法是為了讓測試能逐拍驅動推播內容，而不必真的把迴圈跑起來 ——
    /// 跑迴圈的測試不是在測推播內容，而是在測排程器。
    @discardableResult
    public func emitNextBatch() -> [OddsUpdate] {
        let batch = makeBatch()
        continuation.yield(.updates(batch))
        return batch
    }

    public func currentOdds(for matchID: Int) -> Odds? {
        lastKnown[matchID]
    }

    /// 目前所有場次的賠率。
    ///
    /// 供 mock 的 `GET /odds` 取用：真實伺服器回傳的是「此刻的盤口」，
    /// 若 mock API 永遠回傳開機時的初始值，重連對帳就會變成「重置到開機值」，
    /// demo 時看起來是一次無來由的大幅跳動，而不是校正。
    public func currentOddsSnapshot() -> [Odds] {
        matchIDs.compactMap { lastKnown[$0] }
    }

    // MARK: - Private

    private func runLoop() async {
        continuation.yield(.connectionState(.connected))

        while !Task.isCancelled {
            do {
                try await clock.sleep(for: tickInterval)
            } catch {
                break
            }
            guard !Task.isCancelled else { break }
            emitNextBatch()
        }
    }

    private func makeBatch() -> [OddsUpdate] {
        guard !matchIDs.isEmpty else { return [] }

        let ticksPerSecond = max(1, Int(1.0 / tickInterval.seconds))
        let count = max(1, configuration.updatesPerSecond / ticksPerSecond)

        var batch: [OddsUpdate] = []
        batch.reserveCapacity(count)

        for _ in 0..<count {
            let matchID = matchIDs[Int.random(in: 0..<matchIDs.count, using: &generator)]
            let previous = lastKnown[matchID]

            let teamAOdds = drift(from: previous?.teamAOdds ?? 2.00)
            let teamBOdds = drift(from: previous?.teamBOdds ?? 2.00)

            sequence += 1
            batch.append(
                OddsUpdate(
                    matchID: matchID,
                    teamAOdds: teamAOdds,
                    teamBOdds: teamBOdds,
                    sequence: sequence,
                    sentAtNanos: clock.monotonicNanos
                )
            )

            lastKnown[matchID] = Odds(
                matchID: matchID,
                teamAOdds: teamAOdds,
                teamBOdds: teamBOdds
            )
        }

        return batch
    }

    /// 在現值上做 ±0.01 ~ 0.15 的漂移，並夾在合理的賠率區間內。
    private func drift(from value: Double) -> Double {
        var delta = Int.random(in: -15...15, using: &generator)
        if delta == 0 {
            delta = 1
        }
        let drifted = value + Double(delta) / 100
        let clamped = min(max(drifted, 1.01), 15.00)
        // 回到 0.01 的刻度上，避免浮點累積出 1.9500000000000002 這種值。
        return (clamped * 100).rounded() / 100
    }
}

extension Duration {

    /// 以秒為單位的浮點表示。
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
