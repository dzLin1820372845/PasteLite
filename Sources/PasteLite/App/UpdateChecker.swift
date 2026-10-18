import Foundation
import Combine

/// GitHub Release 更新检查器。只有用户主动点击检查时才发起网络请求，不在后台联网。
@MainActor
final class UpdateChecker: ObservableObject {
    enum State {
        case idle
        case checking
        case upToDate
        case updateAvailable(version: String, downloadURL: URL, releaseURL: URL)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    let currentVersion: String

    private let latestReleaseURL = URL(string: "https://github.com/dzLin1820372845/PasteLite/releases/latest")!
    private let releaseBaseURL = "https://github.com/dzLin1820372845/PasteLite/releases"

    init() {
        currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "未知"
    }

    func check() {
        guard stateIsNotChecking else { return }
        state = .checking

        Task {
            do {
                var request = URLRequest(url: latestReleaseURL)
                request.setValue("PasteLite/\(currentVersion)", forHTTPHeaderField: "User-Agent")

                let (_, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse,
                      (200..<300).contains(httpResponse.statusCode),
                      let finalURL = httpResponse.url else {
                    throw UpdateError.invalidResponse
                }

                guard let tagIndex = finalURL.pathComponents.firstIndex(of: "tag"),
                      finalURL.pathComponents.count > tagIndex + 1 else {
                    throw UpdateError.invalidRelease
                }
                let tag = finalURL.pathComponents[tagIndex + 1]
                guard let latestVersion = AppVersion(tag) else { throw UpdateError.invalidRelease }

                let releaseURL = URL(string: "\(releaseBaseURL)/tag/\(tag)")!
                let downloadName = "PasteLite-\(latestVersion.displayValue)-macOS-universal.dmg"
                let downloadURL = URL(string: "\(releaseBaseURL)/download/\(tag)/\(downloadName)")!

                if latestVersion > (AppVersion(currentVersion) ?? AppVersion([0])) {
                    state = .updateAvailable(version: latestVersion.displayValue,
                                             downloadURL: downloadURL,
                                             releaseURL: releaseURL)
                } else {
                    state = .upToDate
                }
            } catch is CancellationError {
                state = .idle
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    private var stateIsNotChecking: Bool {
        if case .checking = state { return false }
        return true
    }
}

private struct AppVersion: Comparable {
    let parts: [Int]

    init?(_ rawValue: String) {
        let numbers = rawValue
            .trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            .split(separator: ".")
            .compactMap { Int($0) }
        guard !numbers.isEmpty else { return nil }
        parts = numbers
    }

    init(_ parts: [Int]) {
        self.parts = parts
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.parts.count, rhs.parts.count)
        for index in 0..<count {
            let left = index < lhs.parts.count ? lhs.parts[index] : 0
            let right = index < rhs.parts.count ? rhs.parts[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    var displayValue: String {
        parts.map(String.init).joined(separator: ".")
    }
}

private enum UpdateError: LocalizedError {
    case invalidResponse
    case invalidRelease

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "GitHub 返回了无效响应。"
        case .invalidRelease: return "最新 Release 信息不完整。"
        }
    }
}
