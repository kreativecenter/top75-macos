import AppKit
import Foundation
import Observation

struct AppVersion: Comparable, Sendable, CustomStringConvertible {
    let parts: [Int]

    init?(_ text: String) {
        let numbers = (text.hasPrefix("v") ? text.dropFirst() : Substring(text)).split(separator: ".", omittingEmptySubsequences: false)
        let parts = numbers.compactMap { Int($0) }
        guard !parts.isEmpty, parts.count == numbers.count, parts.allSatisfy({ $0 >= 0 }) else { return nil }
        self.parts = parts
    }

    var description: String { parts.map(String.init).joined(separator: ".") }

    private func part(_ index: Int) -> Int { index < parts.count ? parts[index] : 0 }

    static func == (lhs: Self, rhs: Self) -> Bool {
        (0..<max(lhs.parts.count, rhs.parts.count)).allSatisfy { lhs.part($0) == rhs.part($0) }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        for index in 0..<max(lhs.parts.count, rhs.parts.count) where lhs.part(index) != rhs.part(index) {
            return lhs.part(index) < rhs.part(index)
        }
        return false
    }
}

@MainActor
@Observable
final class UpdateChecker {
    static let shared = UpdateChecker()
    nonisolated static let latestRelease = URL(string: "https://api.github.com/repos/kreativecenter/top75-macos/releases/latest")!

    struct GitHubRelease: Decodable, Sendable {
        let tagName: String
        let draft: Bool
        let prerelease: Bool

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name", draft, prerelease
        }
    }

    struct Release: Equatable, Sendable {
        let version: AppVersion
        let page: URL
    }

    // TOP75_UPDATE_CURRENT replaces the installed version so the update prompt can be tested.
    let installed = AppVersion(ProcessInfo.processInfo.environment["TOP75_UPDATE_CURRENT"]
        ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
    private(set) var available: Release?
    private(set) var checking = false
    private(set) var failed = false
    private(set) var checkedAt: Date?
    @ObservationIgnored private var monitoring: Task<Void, Never>?

    var automatic: Bool { UserDefaults.standard.object(forKey: "automaticUpdateChecks") as? Bool ?? true }

    nonisolated static func newer(_ release: GitHubRelease, than installed: AppVersion) -> Release? {
        guard !release.draft, !release.prerelease, let version = AppVersion(release.tagName), version > installed,
              let page = URL(string: "https://github.com/kreativecenter/top75-macos/releases/tag/v\(version)") else { return nil }
        return Release(version: version, page: page)
    }

    func start() {
        guard monitoring == nil, installed != nil else { return }
        monitoring = Task {
            try? await Task.sleep(for: .seconds(5))
            while !Task.isCancelled {
                if automatic, checkedAt.map({ Date.now.timeIntervalSince($0) >= 24 * 60 * 60 }) ?? true { await check() }
                try? await Task.sleep(for: .seconds(60 * 60))
            }
        }
    }

    func check() async {
        guard !checking, let installed else { return }
        checking = true
        defer { checking = false; checkedAt = .now }
        do {
            var request = URLRequest(url: Self.latestRelease, timeoutInterval: 20)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            available = Self.newer(try JSONDecoder().decode(GitHubRelease.self, from: data), than: installed)
            failed = false
        } catch {
            failed = true
        }
    }

    func openRelease() {
        if let available { NSWorkspace.shared.open(available.page) }
    }
}
