import QuartzCore

/// `CADisplayLink` 的弱引用轉接器。
///
/// `CADisplayLink(target:selector:)` 會**強引用** target。若直接把 view
/// controller 當 target，只要 link 還在排程中，該 VC 就永遠不會被釋放 ——
/// 而寫在 `deinit` 裡的 `invalidate()` 也就永遠執行不到，正好在最需要它的
/// 情況下失效。
///
/// 讓 link 持有這個代理、代理弱引用真正的目標，即可切斷循環：
/// VC 被釋放後 `target` 變成 nil，下一次觸發時順手把 link 停掉。
final class DisplayLinkProxy {

    private weak var target: AnyObject?
    private let handler: (AnyObject) -> Void

    init<T: AnyObject>(target: T, handler: @escaping (T) -> Void) {
        self.target = target
        self.handler = { object in
            guard let typed = object as? T else { return }
            handler(typed)
        }
    }

    @objc
    func handleDisplayLink(_ link: CADisplayLink) {
        guard let target else {
            // 目標已釋放，代表沒有人再需要這個節拍。
            link.invalidate()
            return
        }
        handler(target)
    }
}
