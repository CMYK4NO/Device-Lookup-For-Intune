import Foundation

/// Reads an Intune report (`POST …/reports/<name>`) page by page and returns its rows as column name → text.
enum ReportReader {
    /// `search` is the text of the portal's search box; reading stops after `limit` rows.
    static func rows(
        path: String,
        filter: String,
        select: [String]? = nil,
        search: String? = nil,
        pageSize: Int,
        limit: Int = .max,
        client: GraphClient,
        progress: (@MainActor (Int) -> Void)? = nil
    ) async throws -> [[String: String]] {
        let url = try client.url(path: path)
        var rows: [[String: String]] = []
        while true {
            try Task.checkCancellation()
            // Like the Intune portal, an empty `select` asks for every column.
            var body: [String: Any] = ["select": select ?? [], "filter": filter, "skip": rows.count, "top": pageSize, "orderBy": [String]()]
            if let search { body["search"] = search }
            let table = try ReportTable(try await client.post(url: url, json: body))
            rows += table.rows
            if let progress { await progress(rows.count) }
            // Intune may return fewer rows than asked for, so a short page alone does not mean the end.
            if table.rows.isEmpty || rows.count >= min(limit, table.total ?? .max) || (table.total == nil && table.rows.count < pageSize) { return rows }
        }
    }
}
