import AppKit

@MainActor
enum AutoSendPasteboardWriter {
    static func write(_ text: String, to pasteboard: NSPasteboard = .general) -> Bool {
        let previousItems = pasteboard.pasteboardItems?.map { item in
            item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { dataByType, type in
                dataByType[type] = item.data(forType: type)
            }
        } ?? []
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            pasteboard.clearContents()
            if !previousItems.isEmpty {
                let restoredItems = previousItems.map { dataByType in
                    let item = NSPasteboardItem()
                    for (type, data) in dataByType {
                        item.setData(data, forType: type)
                    }
                    return item
                }
                _ = pasteboard.writeObjects(restoredItems)
            }
            return false
        }
        return true
    }
}
