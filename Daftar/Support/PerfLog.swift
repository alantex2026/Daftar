//  PerfLog.swift
//  Temporary instrumentation to measure where navigation lag is actually
//  coming from, instead of guessing again. Safe to delete once the real
//  bottleneck is found and fixed - not meant to ship long-term.

import os
import Foundation

enum PerfLog {
    static let logger = Logger(subsystem: "com.alaa.daftar", category: "perf")

    @discardableResult
    static func measure<T>(_ label: String, _ work: () -> T) -> T {
        let start = CFAbsoluteTimeGetCurrent()
        let result = work()
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
        logger.notice("\(label, privacy: .public): \(ms, format: .fixed(precision: 2), privacy: .public)ms")
        return result
    }

    @discardableResult
    static func measure<T>(_ label: String, _ work: () throws -> T) throws -> T {
        let start = CFAbsoluteTimeGetCurrent()
        let result = try work()
        let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
        logger.notice("\(label, privacy: .public): \(ms, format: .fixed(precision: 2), privacy: .public)ms")
        return result
    }

    static func mark(_ label: String) {
        logger.notice("\(label, privacy: .public)")
    }
}
