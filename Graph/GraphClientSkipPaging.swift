import Foundation

extension GraphClient {
    /// Like `collect`, but Intune often returns small pages (50) whatever `$top` says, so the pages after the first are
    /// requested a few at a time with `$skip` instead of one after another. When the next link is not a `$skip` link,
    /// one extra request checks that `$skip` is honoured; if it is not, the list is followed one page at a time.
    func collectBySkip<T: Decodable>(
        _ type: T.Type,
        path: String,
        query: [URLQueryItem] = [],
        maxInFlight: Int = 8,
        progress: (@MainActor (Int) -> Void)? = nil
    ) async throws -> [GraphItem<T>] {
        let firstURL = try url(path: path, query: query)
        let first = try await page(type, url: firstURL)
        var all = first.items
        if let progress { await progress(all.count) }
        guard let link = first.nextLink, !first.items.isEmpty else { return all }

        let size = first.items.count
        let linkParameters = (URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems ?? []).map(\.name).joined(separator: ",")
        logger.info("paging \(firstURL.path, privacy: .public): pages of \(size), next link parameters \(linkParameters, privacy: .public)")
        var base = URLComponents(url: link, resolvingAgainstBaseURL: false)
        var offset = size
        if Self.skip(of: link) != size {
            // Not a `$skip` link: read the second page as given, then check that `$skip` returns the same page.
            let second = try await page(type, url: link)
            all += second.items
            if let progress { await progress(all.count) }
            guard let next = second.nextLink else { return all }
            let probe = Self.withSkip(firstURL, size)
            let probed = try? await page(type, url: probe)
            guard let probed, Set(probed.items.map(\.raw)) == Set(second.items.map(\.raw)) else {
                try Task.checkCancellation()
                logger.info("skip is not honoured here (\(probed == nil ? "request failed" : "other page", privacy: .public)); reading page by page")
                return try await follow(type, from: next, into: all, progress: progress)
            }
            logger.info("skip is honoured; reading \(maxInFlight) pages at a time")
            base = URLComponents(url: probe, resolvingAgainstBaseURL: false)
            offset = size + second.items.count
        }
        guard let base else { return all }
        return try await readBySkip(type, components: base, size: size, offset: offset, maxInFlight: maxInFlight, into: all, progress: progress)
    }

    private func follow<T: Decodable>(_ type: T.Type, from start: URL, into all: [GraphItem<T>], progress: (@MainActor (Int) -> Void)?) async throws -> [GraphItem<T>] {
        var all = all
        var next: URL? = start
        while let current = next {
            let page = try await page(type, url: current)
            all += page.items
            if let progress { await progress(all.count) }
            next = page.nextLink
        }
        return all
    }

    private func readBySkip<T: Decodable>(
        _ type: T.Type, components: URLComponents, size: Int, offset start: Int, maxInFlight: Int,
        into all: [GraphItem<T>], progress: (@MainActor (Int) -> Void)?
    ) async throws -> [GraphItem<T>] {
        var all = all
        var offset = start
        var finished = false
        while !finished {
            try Task.checkCancellation()
            let urls = (0..<maxInFlight).compactMap { index -> URL? in
                var next = components
                next.queryItems = (components.queryItems ?? []).filter { $0.name != "$skip" } + [URLQueryItem(name: "$skip", value: String(offset + index * size))]
                return next.url
            }
            let pages = try await withThrowingTaskGroup(of: (Int, GraphPage<T>).self) { group in
                for (index, url) in urls.enumerated() {
                    group.addTask { (index, try await self.page(type, url: url)) }
                }
                var results: [(Int, GraphPage<T>)] = []
                for try await result in group { results.append(result) }
                return results.sorted { $0.0 < $1.0 }.map(\.1)
            }
            for page in pages {
                all += page.items
                if page.items.count < size || page.nextLink == nil { finished = true }
            }
            offset += maxInFlight * size
            if let progress { await progress(all.count) }
        }
        return all
    }

    private static func skip(of url: URL) -> Int? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "$skip" }?.value.flatMap(Int.init)
    }

    private static func withSkip(_ url: URL, _ skip: Int) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.queryItems = (components.queryItems ?? []).filter { $0.name != "$skip" } + [URLQueryItem(name: "$skip", value: String(skip))]
        return components.url ?? url
    }
}
