import AppKit
import Foundation
import Testing
@testable import VirtualWormhole

@Suite @MainActor
struct ClipboardFileTests {
    @Test func copiedFilesPasteFromQuarantinedStaging() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let bytes = Data((0..<4096).map { UInt8($0 % 251) })
        let source = try sandbox.file("Screen Recording.mov", bytes)
        let (host, hostBoard) = sandbox.clipboard("host")
        let (guest, guestBoard) = sandbox.clipboard("guest")
        defer { hostBoard.releaseGlobally(); guestBoard.releaseGlobally() }

        hostBoard.clearContents()
        hostBoard.writeObjects([source as NSURL])
        let items = host.read()
        #expect(items.compactMap(ClipboardFile.init) == [ClipboardFile(name: "Screen Recording.mov", contents: bytes)])

        guest.write(items)
        let pasted = try #require(guestBoard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])
        #expect(pasted.map(\.lastPathComponent) == ["Screen Recording.mov"])
        #expect(pasted[0].resolvingSymlinksInPath().path.hasPrefix(sandbox.url.appendingPathComponent("guest-staging").resolvingSymlinksInPath().path))
        #expect(try Data(contentsOf: pasted[0]) == bytes)
        #expect(try pasted[0].resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties != nil)
        // Reading the staged copy gives the same files back, so nothing new is sent.
        #expect(guest.read().compactMap(ClipboardFile.init) == items.compactMap(ClipboardFile.init))
    }

    @Test func peerNamesStayInsideStagingAndDuplicatesAreKept() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let (guest, board) = sandbox.clipboard("guest")
        defer { board.releaseGlobally() }

        let files = [("../../evil.sh", "a"), ("..", "b"), ("a.txt", "c"), ("a.txt", "d")]
            .compactMap { ClipboardFile(name: $0.0, contents: Data($0.1.utf8)).item }
        guest.write(files)
        let pasted = try #require(board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])
        #expect(pasted.map(\.lastPathComponent) == ["evil.sh", "File", "a.txt", "a 2.txt"])
        let staging = sandbox.url.appendingPathComponent("guest-staging").resolvingSymlinksInPath().path
        #expect(pasted.allSatisfy { $0.resolvingSymlinksInPath().path.hasPrefix(staging) })
        #expect(try pasted.map { String(decoding: try Data(contentsOf: $0), as: UTF8.self) } == ["a", "b", "c", "d"])
    }

    @Test func foldersAndOversizedCopiesFallBackToTheName() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let (host, board) = sandbox.clipboard("host")
        defer { board.releaseGlobally() }
        let folder = sandbox.url.appendingPathComponent("Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let large = try sandbox.file("large.bin", Data())
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: UInt64(ClipboardFile.maximumTotalSize + 1)) // sparse, no real disk use
        try handle.close()

        for url in [folder, large] {
            board.clearContents()
            board.writeObjects([url as NSURL])
            board.setString(url.lastPathComponent, forType: .string)
            let items = host.read()
            #expect(items.compactMap(ClipboardFile.init).isEmpty)
            #expect(items.contains { $0.type == NSPasteboard.PasteboardType.string.rawValue })
        }
    }

    @Test func receivingTextRemovesThePreviousStagedFiles() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let (guest, board) = sandbox.clipboard("guest")
        defer { board.releaseGlobally() }
        guest.write([try #require(ClipboardFile(name: "old.txt", contents: Data("x".utf8)).item)])
        let staged = try #require(board.readObjects(forClasses: [NSURL.self], options: nil) as? [URL]).first
        guest.write([ClipboardItem(type: NSPasteboard.PasteboardType.string.rawValue, data: Data("text".utf8))])
        #expect(board.string(forType: .string) == "text")
        #expect(!FileManager.default.fileExists(atPath: try #require(staged).path))
    }
}

@MainActor private struct Sandbox {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("ClipboardFileTests-\(UUID().uuidString)", isDirectory: true)

    init() throws { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }

    func file(_ name: String, _ data: Data) throws -> URL {
        let file = url.appendingPathComponent(name)
        try data.write(to: file)
        return file
    }

    func clipboard(_ name: String) -> (SystemGuestClipboard, NSPasteboard) {
        let board = NSPasteboard(name: .init("codes.rambo.VirtualWormholeTests.\(name).\(UUID().uuidString)"))
        return (SystemGuestClipboard(pasteboard: board, stagingRoot: url.appendingPathComponent("\(name)-staging")), board)
    }

    func remove() { try? FileManager.default.removeItem(at: url) }
}
