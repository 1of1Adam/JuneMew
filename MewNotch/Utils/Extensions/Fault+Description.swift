//
//  Fault+Description.swift
//  MewNotch
//

import KLineCore

extension Fault {

    /// 面向用户的故障描述。
    ///
    /// 刘海折叠态的 tooltip 与展开面板共用这一份文案 ——
    /// 分成两处各写一遍，日后必然演化出两种说法。
    var userDescription: String {
        switch self {
        case let .clockOffsetExceedsTolerance(offset, threshold):
            return String(
                format: "System clock is off by %+.1fs (tolerance %.0fs). "
                    + "Countdown hidden because it cannot be trusted.",
                offset, threshold
            )
        case let .clockJumped(delta):
            return String(
                format: "System clock jumped by %+.1fs. Recalibrating…", delta
            )
        case let .holidayTableExpired(daysStale):
            return "Holiday table expired \(daysStale) days ago. "
                + "Session boundaries can no longer be trusted."
        case let .holidayTableUnreadable(detail):
            return "Holiday table could not be read: \(detail)"
        case let .calendarInconsistent(detail):
            return "Trading calendar inconsistency: \(detail)"
        }
    }
}
