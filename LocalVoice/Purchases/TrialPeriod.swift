import Foundation

struct TrialPeriod: Equatable {
    static let duration: TimeInterval = 7 * 24 * 60 * 60

    let startDate: Date

    func expirationDate() -> Date {
        startDate.addingTimeInterval(Self.duration)
    }

    func isActive(at date: Date) -> Bool {
        date < expirationDate()
    }

    func daysRemaining(at date: Date) -> Int {
        guard isActive(at: date) else { return 0 }
        return max(1, Int(ceil(expirationDate().timeIntervalSince(date) / (24 * 60 * 60))))
    }
}
