import Foundation
@preconcurrency import UserNotifications
import QuotaCore

// MARK: - The reset moment

extension UsageStore {
    /// How long a row keeps saying "just reset".
    static let justResetSpan: TimeInterval = 10 * 60

    /// Windows that reset between the previous reading and this one. Only
    /// fresh ones count: a cached reading replaced hours after its reset is
    /// not news.
    func noteResets(_ events: [ResetEvent], before: MeterReading) {
        let fresh = events.filter(\.isFresh)
        guard !fresh.isEmpty else { return }
        let until = Date().addingTimeInterval(Self.justResetSpan)
        for event in fresh { recentResets[event.id] = until }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.justResetSpan + 1))
            self?.recentResets = self?.recentResets.filter { $0.value > Date() } ?? [:]
        }
        notifyResets(fresh)
        guard experience.resetEffects, !isPrivacyMasked else { return }
        onResets?(fresh, before)
    }

    /// Whether a row should say it reset a moment ago.
    func justReset(_ id: ProviderID, window windowID: String) -> Bool {
        guard experience.resetEffects, let until = recentResets["\(id.rawValue)|\(windowID)"] else { return false }
        return until > Date()
    }

    private func notifyResets(_ events: [ResetEvent]) {
        let mode = experience.resetNotify
        let due = events.filter { mode.shouldNotify($0) }
        guard !due.isEmpty, notificationsReady, notificationsAvailable, !isPrivacyMasked else { return }
        for event in due {
            let content = UNMutableNotificationContent()
            content.title = L10n.t("Limit reset", "额度已重置")
            content.subtitle = "\(event.provider.displayName) · \(event.name)"
            let left = QuotaFormat.percent(100 - event.usedNow)
            content.body = event.followedHeavyUse
                ? L10n.t("\(left) left again — carry on.", "又有 \(left) 可用了，可以继续用。")
                : L10n.t("\(left) left.", "现在剩余 \(left)。")
            content.threadIdentifier = "bar.quota.reset"
            UNUserNotificationCenter.current().add(UNNotificationRequest(
                identifier: "bar.quota.reset.\(event.id).\(Int(event.resetAt.timeIntervalSince1970))",
                content: content,
                trigger: nil))
        }
    }

    /// Reads a provider again just after its next window resets, so the
    /// moment shows when it happens rather than at the next scheduled
    /// refresh. A provider that still reports the passed reset time gets up
    /// to three more reads a minute apart.
    func scheduleResetCheck() {
        resetCheckTask?.cancel()
        let now = Date()
        var due: [(id: ProviderID, at: Date)] = []
        for id in displayProviders(enabled) {
            guard let snapshot = displayPhase(for: id)?.snapshot else { continue }
            if let next = ResetDetector.nextCheck(for: snapshot, after: now) {
                due.append((id, next))
            }
            if let overdue = snapshot.windows.compactMap(\.resetsAt).filter({ $0 <= now && now.timeIntervalSince($0) < 300 }).max() {
                let key = "\(id.rawValue)|\(Int(overdue.timeIntervalSince1970))"
                let tries = resetRetries[key, default: 0]
                if tries < 3 {
                    resetRetries[key] = tries + 1
                    due.append((id, now.addingTimeInterval(60)))
                }
            }
        }
        resetRetries = resetRetries.filter { key, _ in
            guard let stamp = key.split(separator: "|").last.flatMap({ Double($0) }) else { return false }
            return now.timeIntervalSince1970 - stamp < 900
        }
        guard let first = due.map(\.at).min() else { return }
        // Everything resetting within the same minute is read together.
        let ids = Set(due.filter { $0.at <= first.addingTimeInterval(60) }.map(\.id))
        resetCheckTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(1, first.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self else { return }
            for id in ids where self.isEnabled(id) { self.refresh(id) }
        }
    }

    /// `QuotaBar --simulate-reset <provider>`: plays the moment for that
    /// provider's fullest window a few seconds after launch, as if it had
    /// just reset, without touching the reading.
    func simulateReset(_ id: ProviderID) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard let self else { return }
            let window = self.headlineWindow(for: id) ?? self.states[id]?.snapshot?.windows.first
            let name = window.map { $0.displayName } ?? L10n.t("5-hour", "5 小时")
            var before = self.meterReading
            before.preferred = 96
            before.short = 96
            before.long = max(before.long ?? 0, 96)
            let event = ResetEvent(
                provider: id, windowID: window?.id ?? name, name: name,
                previousUsed: 96, usedNow: window?.usedPercent ?? 0,
                resetAt: Date(), noticedAt: Date())
            self.recentResets[event.id] = Date().addingTimeInterval(Self.justResetSpan)
            self.onResets?([event], before)
        }
    }
}

// MARK: - Resets the account is given

extension UsageStore {
    /// A reset given since the reading before, and a reset or a credit about
    /// to run out unspent — Codex and Claude hand resets out every so often
    /// and each lasts about a month. A reminder is remembered even while
    /// notifications are off, so turning them on does not bring back a day of
    /// old ones.
    func noteResetCredits(_ id: ProviderID, previous: UsageSnapshot?, current snapshot: UsageSnapshot) {
        let notices = ResetCreditCheck.notices(
            provider: id, previous: previous, current: snapshot.resetCredits,
            credits: snapshot.windows.filter { $0.credit != nil }, account: snapshot.account,
            notified: experience.resetCreditNotified)
        let reminders = notices.compactMap { notice -> String? in
            if case .given = notice.kind { return nil }
            return notice.key
        }
        if !reminders.isEmpty {
            updateExperience { $0.resetCreditNotified = Array(($0.resetCreditNotified + reminders).suffix(24)) }
        }
        scheduleLastCalls(id, snapshot)
        guard !notices.isEmpty, experience.resetCreditNotify, notificationsReady, notificationsAvailable, !isPrivacyMasked else { return }
        for notice in notices { post(notice, credits: snapshot.resetCredits) }
    }

    private func post(_ notice: ResetCreditNotice, credits: ResetCredits?) {
        let content = UNMutableNotificationContent()
        content.subtitle = notice.provider.displayName
        switch notice.kind {
        case let .given(count):
            content.title = L10n.t("An early reset for you", "收到新的限额重置")
            var body = L10n.t(
                "\(notice.provider.displayName) gave you \(count) early reset\(count == 1 ? "" : "s"); \(notice.available) available now.",
                "\(notice.provider.displayName) 送你 \(count) 次限额重置，现在共 \(notice.available) 次可用。")
            if let soonest = credits?.upcomingExpirations().first {
                body += L10n.t(
                    " The soonest expires in \(QuotaFormat.countdown(to: soonest)).",
                    "最早的 \(QuotaFormat.countdown(to: soonest))后到期。")
            }
            content.body = body
        case let .expiring(credit):
            content.title = L10n.t("An early reset is about to expire", "限额重置快过期了")
            content.body = Self.resetReminder(credit, provider: notice.provider, when: QuotaFormat.creditExpiry(credit, format: .countdown))
        case let .creditExpiring(name, credit):
            content.title = L10n.t("A credit is about to expire", "额度快过期了")
            content.body = Self.creditReminder(
                name, credit, when: QuotaFormat.creditExpiry(ResetCredit(expiresAt: credit.expiresAt), format: .countdown))
        }
        content.threadIdentifier = "bar.quota.reset-credit"
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: "bar.quota.reset-credit.\(notice.key)", content: content, trigger: nil))
    }

    private static func resetReminder(_ credit: ResetCredit, provider: ProviderID, when: String) -> String {
        let name = credit.title ?? L10n.t("An early reset", "一次限额重置")
        let howTo = ResetCreditCheck.spendHint(for: provider).map { L10n.t(" \($0)", $0) } ?? ""
        return L10n.t("\(name) \(when), unspent.", "\(name) \(when)，还没用。") + howTo
    }

    /// "Credits: 12,300 credits left, expires in 23h 4m — what is unused is lost."
    private static func creditReminder(_ name: String, _ credit: CreditAmount, when: String) -> String {
        if let part = credit.expiring {
            return L10n.t(
                "\(name): \(part) of \(credit.amount) \(when) — what is unused is lost.",
                "\(name)中有 \(part)\(when)，过期作废。")
        }
        return L10n.t(
            "\(name): \(credit.amount) left, \(when) — what is unused is lost.",
            "\(name)还剩 \(credit.amount)，\(when)，过期作废。")
    }

    /// Hands the system this reading's last calls, an hour before each
    /// deadline within the day, and takes back the ones it set for this
    /// account that the reading no longer lists — spent, or switched off.
    private func scheduleLastCalls(_ id: ProviderID, _ snapshot: UsageSnapshot) {
        guard notificationsAvailable else { return }
        let center = UNUserNotificationCenter.current()
        let prefix = "bar.quota.reset-credit." + ResetCreditCheck.lastCallPrefix(provider: id, account: snapshot.account)
        let wanted = experience.resetCreditNotify && experience.resetCreditLastCall && notificationsReady
            ? ResetCreditCheck.lastCalls(provider: id, snapshot: snapshot) : []
        if !isPrivacyMasked {
            for call in wanted { center.add(lastCallRequest(call, provider: id)) }
        }
        let keep = Set(wanted.map { "bar.quota.reset-credit.\($0.key)" })
        Task {
            let stale = await center.pendingNotificationRequests().map(\.identifier)
                .filter { $0.hasPrefix(prefix) && !keep.contains($0) }
            if !stale.isEmpty { center.removePendingNotificationRequests(withIdentifiers: stale) }
        }
    }

    private func lastCallRequest(_ call: ResetCreditLastCall, provider: ProviderID) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.subtitle = provider.displayName
        let when = L10n.t("expires in an hour", "1 小时后到期")
        switch call.deadline.item {
        case let .reset(credit):
            content.title = L10n.t("An early reset expires in an hour", "限额重置还有 1 小时过期")
            content.body = Self.resetReminder(credit, provider: provider, when: when)
        case let .credit(name, credit):
            content.title = L10n.t("A credit expires in an hour", "额度还有 1 小时过期")
            content.body = Self.creditReminder(name, credit, when: when)
        }
        content.threadIdentifier = "bar.quota.reset-credit"
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: call.fireAt)
        return UNNotificationRequest(
            identifier: "bar.quota.reset-credit.\(call.key)", content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
    }

    /// After the switches change: the last calls follow them at once rather
    /// than at each provider's next reading.
    func syncResetCreditLastCalls() {
        for (id, snapshot) in reported { scheduleLastCalls(id, snapshot) }
    }

    /// The row's help: each given reset with what it resets and when it runs
    /// out, in the reset rows' format.
    func resetCreditHelp(_ credits: ResetCredits) -> String {
        var lines = [L10n.t(
            "Early resets reset your usage limits before their time. \(credits.applicable ?? 0) apply to the window limiting you right now.",
            "限额重置可以提前重置用量限制。当前正在限流的窗口可用 \(credits.applicable ?? 0) 次。")]
        if let earned = credits.totalEarned {
            lines.append(L10n.t("\(earned) given in all.", "累计获得 \(earned) 次。"))
        }
        lines += QuotaFormat.creditLines(
            credits.credits, format: experience.resetTimeFormat, clock: experience.clockStyle)
        return lines.joined(separator: "\n")
    }
}
