import Combine
import OddsCore
import OddsPresentation
import SnapKit
import UIKit

/// 比賽賠率列表。
///
/// 本題的核心驗收條件在這個檔案裡實現（`docs/spec.md` §4 FR-3.3）：
/// **賠率更新只重設對應的 cell，全程不呼叫整頁 reload。**
/// 這件事由三層機制共同保證：
///
/// 1. diffable data source 的 item identifier 是 `matchID`（不含賠率），
///    所以賠率變動不會被判定為「刪一列 + 插一列」。
/// 2. 更新以 `CADisplayLink` 對齊畫面刷新節奏批次觸發，而非每筆推播各觸發一次。
/// 3. 只對**目前可見**的列呼叫 `reconfigureItems` —— 100 場比賽、螢幕只看得到
///    約 10 列，約九成的推播根本不需要碰 UI。
public final class MatchListViewController: UIViewController {

    private enum Section {
        case main
    }

    /// UI 批次更新的間隔。
    ///
    /// 用 `CADisplayLink` 而非 `Timer`：前者與畫面刷新同步，更新永遠發生在
    /// 幀邊界上；後者可能在一幀的中間觸發，造成該幀的工作量突增。
    /// 間隔取 100ms —— 賠率看板不需要比這更即時，而每秒 10 次批次更新對
    /// UITableView 是極輕的負擔。
    private static let flushInterval: CFTimeInterval = 0.1

    private let viewModel: MatchListViewModel
    private var cancellables: Set<AnyCancellable> = []
    private var displayLink: CADisplayLink?
    private var lastFlushTimestamp: CFTimeInterval = 0

    private lazy var tableView: UITableView = {
        let tableView = UITableView(frame: .zero, style: .plain)
        tableView.register(MatchCell.self, forCellReuseIdentifier: MatchCell.reuseIdentifier)
        tableView.rowHeight = 64
        // 固定列高：估算高度會讓 UITableView 在滾動時反覆詢問與修正，
        // 而本列表的高度本來就是固定的。
        tableView.estimatedRowHeight = 0
        tableView.allowsSelection = false
        return tableView
    }()

    private lazy var dataSource = makeDataSource()

    private let statusLabel: UILabel = {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .caption1)
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        return label
    }()

    private let loadingIndicator = UIActivityIndicatorView(style: .large)

    public init(viewModel: MatchListViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("本專案不使用 Storyboard/XIB")
    }

    deinit {
        displayLink?.invalidate()
    }

    // MARK: - 生命週期

    public override func viewDidLoad() {
        super.viewDidLoad()

        title = "即時賠率"
        view.backgroundColor = .systemBackground

        setUpLayout()
        bind()

        Task { await viewModel.start() }
    }

    public override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        startDisplayLink()
    }

    public override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // 畫面離開時停掉節拍。推播仍會寫進 store（回來時資料是最新的），
        // 但不再產生任何 UI 工作。
        stopDisplayLink()
    }

    // MARK: - 綁定

    private func bind() {
        // 列表順序只在載入時變動，因此 snapshot 也只在這時 apply 一次。
        viewModel.$orderedMatchIDs
            .removeDuplicates()
            .sink { [weak self] matchIDs in
                self?.applySnapshot(matchIDs: matchIDs)
            }
            .store(in: &cancellables)

        viewModel.$loadState
            .removeDuplicates()
            .sink { [weak self] state in
                self?.render(state)
            }
            .store(in: &cancellables)

        viewModel.$connectionState
            .removeDuplicates()
            .sink { [weak self] state in
                self?.renderConnection(state)
            }
            .store(in: &cancellables)
    }

    private func applySnapshot(matchIDs: [Int]) {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Int>()
        snapshot.appendSections([.main])
        snapshot.appendItems(matchIDs, toSection: .main)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func render(_ state: MatchListViewModel.LoadState) {
        switch state {
        case .idle, .loading:
            loadingIndicator.startAnimating()
            statusLabel.text = "載入中…"
        case .loaded:
            loadingIndicator.stopAnimating()
        case .failed(let message):
            loadingIndicator.stopAnimating()
            statusLabel.text = "載入失敗：\(message)"
        }
    }

    private func renderConnection(_ state: OddsConnectionState) {
        guard case .loaded = viewModel.loadState else { return }

        switch state {
        case .idle:
            statusLabel.text = "已中斷"
        case .connecting:
            statusLabel.text = "連線中…"
        case .connected:
            statusLabel.text = "● 即時更新中"
        case .reconnecting(let attempt):
            statusLabel.text = "連線中斷，重試中（第 \(attempt) 次）"
        case .failed:
            statusLabel.text = "無法連線"
        }
    }

    // MARK: - 更新節拍

    private func startDisplayLink() {
        guard displayLink == nil else { return }

        let link = CADisplayLink(target: self, selector: #selector(handleDisplayLink(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc
    private func handleDisplayLink(_ link: CADisplayLink) {
        guard link.timestamp - lastFlushTimestamp >= Self.flushInterval else { return }
        lastFlushTimestamp = link.timestamp

        Task { @MainActor [weak self] in
            await self?.flushPendingUpdates()
        }
    }

    private func flushPendingUpdates() async {
        let changedIDs = await viewModel.drainPendingUpdates()
        guard !changedIDs.isEmpty else { return }

        // 只更新看得見的列。看不見的列已經寫進 store，使用者滾到時
        // `cellProvider` 自然會取到最新值 —— 現在動它是純粹浪費。
        let visibleIDs = Set(
            (tableView.indexPathsForVisibleRows ?? [])
                .compactMap { dataSource.itemIdentifier(for: $0) }
        )
        let idsToReconfigure = changedIDs.intersection(visibleIDs)
        guard !idsToReconfigure.isEmpty else { return }

        var snapshot = dataSource.snapshot()
        // reconfigureItems 保留既有 cell 實體，只重跑 cellProvider —— 這正是
        // 「不整頁 reload」與「不刪列再插列」之間的那條路。
        snapshot.reconfigureItems(Array(idsToReconfigure))
        await dataSource.apply(snapshot, animatingDifferences: false)

        playChangeAnimations(for: idsToReconfigure)

        // 動畫已觸發，清掉標記避免 cell 被重用或再次 reconfigure 時重播舊變動。
        await viewModel.clearChanges(for: idsToReconfigure)
    }

    /// 對剛重設過的可見 cell 播放漲跌提示。
    ///
    /// 刻意放在 `dataSource.apply` 之後而非 cellProvider 內，讓職責分明：
    /// cellProvider 只負責「這一列現在該顯示什麼」，短暫的視覺提示是另一回事。
    /// cellProvider 也可能因為滾動而被呼叫，在那裡播動畫會讓使用者
    /// 滾過去就看到一堆不該閃的格子在閃。
    private func playChangeAnimations(for matchIDs: Set<Int>) {
        for matchID in matchIDs {
            guard
                let row = viewModel.row(for: matchID),
                row.change.hasChange,
                let indexPath = dataSource.indexPath(for: matchID),
                let cell = tableView.cellForRow(at: indexPath) as? MatchCell
            else {
                continue
            }
            cell.playChangeAnimation(row.change)
        }
    }

    // MARK: - Data source

    private func makeDataSource() -> UITableViewDiffableDataSource<Section, Int> {
        UITableViewDiffableDataSource<Section, Int>(
            tableView: tableView
        ) { [weak self] tableView, indexPath, matchID in
            let cell = tableView.dequeueReusableCell(
                withIdentifier: MatchCell.reuseIdentifier,
                for: indexPath
            )

            guard
                let self,
                let matchCell = cell as? MatchCell,
                let row = self.viewModel.row(for: matchID)
            else {
                return cell
            }

            // 這裡只負責內容。漲跌動畫由 `playChangeAnimations(for:)` 在
            // apply 之後觸發 —— 原因見該方法的註解。
            matchCell.configure(with: row)
            return matchCell
        }
    }

    // MARK: - 版面

    private func setUpLayout() {
        view.addSubview(tableView)
        view.addSubview(statusLabel)
        view.addSubview(loadingIndicator)

        statusLabel.snp.makeConstraints { make in
            make.top.equalTo(view.safeAreaLayoutGuide)
            make.leading.trailing.equalToSuperview()
            make.height.equalTo(24)
        }

        tableView.snp.makeConstraints { make in
            make.top.equalTo(statusLabel.snp.bottom)
            make.leading.trailing.bottom.equalToSuperview()
        }

        loadingIndicator.snp.makeConstraints { make in
            make.center.equalTo(tableView)
        }
    }
}
