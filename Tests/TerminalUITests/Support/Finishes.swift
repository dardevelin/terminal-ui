import Testing

/// Whether `wait` finishes within `limit`.
func finishes(within limit: Duration, _ wait: @escaping @Sendable () async -> Void) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask {
            await wait()
            return true
        }
        group.addTask {
            try? await Task.sleep(for: limit)
            return false
        }
        let first = await group.next() ?? false
        group.cancelAll()
        return first
    }
}
