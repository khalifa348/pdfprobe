//
//  PDFProbeApp.swift
//  PDFProbe
//
//  Defensive QA / fuzzing harness for on-device PDF parsing + rasterization
//  robustness testing. Runs entirely on the user's own dev-signed sideloaded
//  device. No third-party dependencies.
//
//  Frameworks: SwiftUI, PDFKit, CoreGraphics, UIKit, Foundation only.
//
//  Pipeline per file:
//    PDF_START <name>
//    -> CGPDFDocument creation
//       fail -> PDF_ERR <name>:<reason>  (move to Out, continue)
//       ok   -> PDF_PAGES <name>:<n>
//    -> render each page at 72 dpi -> PDF_RENDER <name>:<page>
//    -> document.catalog + document.info
//       -> PDF_TRAILER <name>:<keys>
//    PDF_DONE <name>  (move to Out)
//  Whole-per-file op guarded by a 60s watchdog (PDF_HANG) so one file can
//  never wedge the queue.
//

import SwiftUI
import PDFKit
import CoreGraphics
import UIKit
import os.log
import Foundation
import UniformTypeIdentifiers

// MARK: - Logging

enum ProbeLog {
    static let subsystem = "com.khalifa.pdfprobe"
    static let logger = Logger(subsystem: subsystem, category: "pdf")

    static let start  = Logger(subsystem: subsystem, category: "start")
    static let err    = Logger(subsystem: subsystem, category: "err")
    static let parse  = Logger(subsystem: subsystem, category: "parse")
    static let render = Logger(subsystem: subsystem, category: "render")
    static let meta   = Logger(subsystem: subsystem, category: "meta")
    static let loop   = Logger(subsystem: subsystem, category: "loop")
}

// MARK: - Shared UI Log Sink

final class UILogSink: ObservableObject {
    @Published var lines: [String] = []
    private let maxLines = 500
    private let queue = DispatchQueue(label: "com.khalifa.pdfprobe.uilogsink")

    func append(_ s: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let full = "[\(timestamp)] \(s)"
        queue.async {
            DispatchQueue.main.async {
                self.lines.append(full)
                if self.lines.count > self.maxLines {
                    self.lines.removeFirst(self.lines.count - self.maxLines)
                }
            }
        }
    }
}

// MARK: - Fuzz Engine

final class FuzzEngine: ObservableObject {

    @Published var statusText: String = "Idle"
    @Published var isRunning: Bool = false
    @Published var processedCount: Int = 0
    @Published var totalCount: Int = 0

    let uiLog = UILogSink()

    private var fileQueue: [URL] = []
    private var processedFiles: Set<String> = []
    private var enqueuedFiles: Set<String> = []
    private var isProcessingQueue = false
    private let engineQueue = DispatchQueue(label: "com.khalifa.pdfprobe.engine", qos: .utility)

    private let inDirName = "In"
    private let outDirName = "Out"

    private var docsRootURL: URL {
        URL(fileURLWithPath: NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0], isDirectory: true)
    }

    private var docsInURL: URL {
        let fm = FileManager.default
        let inDir = docsRootURL.appendingPathComponent(inDirName, isDirectory: true)
        if !fm.fileExists(atPath: inDir.path) {
            try? fm.createDirectory(at: inDir, withIntermediateDirectories: true)
        }
        return inDir
    }

    private var docsOutURL: URL {
        let fm = FileManager.default
        let outDir = docsRootURL.appendingPathComponent(outDirName, isDirectory: true)
        if !fm.fileExists(atPath: outDir.path) {
            try? fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        }
        return outDir
    }

    private var fsWatcher: DispatchSourceFileSystemObject?
    private var watchedFD: Int32 = -1

    // PDFKit needs no special permission; we slice off anything that might
    // otherwise trip a system prompt. Nothing to request here.
    func requestPermissionsAndBootstrap() {
        ProbeLog.loop.log("PDF_NO_PERMS_REQUIRED")
        ProbeLog.loop.log("ROOT_DIR \(self.docsRootURL.path, privacy: .public)")
        ProbeLog.loop.log("IN_DIR \(self.docsInURL.path, privacy: .public)")
        ProbeLog.loop.log("OUT_DIR \(self.docsOutURL.path, privacy: .public)")
        bootstrapExistingFiles()
        startWatchingInDirectory()
    }

    // MARK: Bootstrap — process files already present at launch

    func bootstrapExistingFiles() {
        let fm = FileManager.default
        var urls: [URL] = []

        for dir in [docsInURL, docsRootURL] {
            if let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                for u in items where !u.hasDirectoryPath {
                    urls.append(u)
                }
            }
        }

        ProbeLog.loop.log("BOOTSTRAP_FOUND_FILES count=\(urls.count, privacy: .public)")
        uiLog.append("Bootstrap: found \(urls.count) file(s) already in Documents.")

        enqueue(urls: urls)
    }

    // MARK: Directory watching (new file arrivals)

    private func startWatchingInDirectory() {
        let path = docsInURL.path
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            uiLog.append("Failed to open In/ for watching (fd=\(fd)).")
            return
        }
        watchedFD = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .rename, .delete],
            queue: engineQueue
        )
        source.setEventHandler { [weak self] in
            self?.rescanInDirectory()
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        fsWatcher = source

        ProbeLog.loop.log("WATCH_STARTED path=\(path, privacy: .public)")
        uiLog.append("Watching \(path) for new files.")
    }

    private func rescanInDirectory() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: docsInURL, includingPropertiesForKeys: nil) else { return }
        let newOnes = items.filter { !$0.hasDirectoryPath && !processedFiles.contains($0.path) }
        if !newOnes.isEmpty {
            ProbeLog.loop.log("WATCH_NEW_FILES count=\(newOnes.count, privacy: .public)")
            enqueue(urls: newOnes)
        }
    }

    // MARK: Queue management

    func enqueue(urls: [URL]) {
        engineQueue.async { [weak self] in
            guard let self = self else { return }
            let fresh = urls.filter { !self.processedFiles.contains($0.path) && !self.enqueuedFiles.contains($0.path) }
            for u in fresh { self.enqueuedFiles.insert(u.path) }
            self.fileQueue.append(contentsOf: fresh)
            DispatchQueue.main.async {
                self.totalCount += fresh.count
            }
            self.pumpQueue()
        }
    }

    func manualRun() {
        DispatchQueue.main.async {
            self.statusText = "Running"
            self.isRunning = true
        }
        bootstrapExistingFiles()
    }

    private func pumpQueue() {
        engineQueue.async { [weak self] in
            guard let self = self else { return }
            guard !self.isProcessingQueue else { return }
            self.isProcessingQueue = true
            self.drainQueueLoop()
        }
    }

    private func drainQueueLoop() {
        guard let next = fileQueue.first else {
            isProcessingQueue = false
            DispatchQueue.main.async {
                self.statusText = "Idle (queue empty)"
                self.isRunning = false
            }
            return
        }
        fileQueue.removeFirst()
        processedFiles.insert(next.path)

        DispatchQueue.main.async {
            self.statusText = "Processing \(next.lastPathComponent)"
            self.isRunning = true
        }

        processOneFile(next) { [weak self] in
            guard let self = self else { return }
            DispatchQueue.main.async {
                self.processedCount += 1
            }
            self.engineQueue.async {
                self.drainQueueLoop()
            }
        }
    }

    // MARK: Per-file pipeline (guarded by a 60s watchdog)

    private func processOneFile(_ url: URL, completion: @escaping () -> Void) {
        let name = url.lastPathComponent
        let fm = FileManager.default
        let srcExists = fm.fileExists(atPath: url.path)
        let outExists = fm.fileExists(atPath: docsOutURL.path)
        let destExists = fm.fileExists(atPath: docsOutURL.appendingPathComponent(name).path)
        ProbeLog.start.log("PDF_START \(name, privacy: .public) srcExists=\(srcExists) outExists=\(outExists) destExists=\(destExists)")
        ProbeLog.start.log("PDF_PATH \(name, privacy: .public):\(url.path, privacy: .public)")
        uiLog.append("--- \(name) ---")

        let pdfEngine = PDFEngine(url: url, name: name, uiLog: uiLog, outDirURL: docsOutURL)

        let overallGuard = HangGuard(seconds: 60) { [weak self] in
            ProbeLog.loop.log("PDF_HANG \(pdfEngine.name, privacy: .public)")
            self?.uiLog.append("PDF_HANG on \(pdfEngine.name) — watchdog forcing continue.")
        }

        overallGuard.onFire = {
            // Fired only if the pipeline never called back in time.
            completion()
        }

        pdfEngine.run { [weak self] in
            self?.overallRelease(pdfEngine, watchdogGuard: overallGuard, completion: completion)
        }
    }

    private func overallRelease(_ pdfEngine: PDFEngine, watchdogGuard: HangGuard, completion: @escaping () -> Void) {
        watchdogGuard.cancel()
        ProbeLog.loop.log("DONE \(pdfEngine.name, privacy: .public) COMPLETE")
        DispatchQueue.main.async {
            self.uiLog.append("DONE \(pdfEngine.name)")
        }
        completion()
    }
}

// MARK: - PDF Engine: per-file CGPDF work

final class PDFEngine {
    let url: URL
    let name: String
    private let uiLog: UILogSink
    private let outDirURL: URL
    private let workQueue = DispatchQueue(label: "com.khalifa.pdfprobe.pdfwork", qos: .utility)

    // 72 dpi == PDF points (1 PDF pt = 1 device-independent point at 72dpi).
    private let dpiScale: CGFloat = 1.0

    init(url: URL, name: String, uiLog: UILogSink, outDirURL: URL) {
        self.url = url
        self.name = name
        self.uiLog = uiLog
        self.outDirURL = outDirURL
    }

    func run(completion: @escaping () -> Void) {
        // Synchronous execution on the caller's serial queue: guarantees exactly
        // one file is processed at a time and eliminates the rescan/move race
        // that re-enqueued files and double-processed them.
        self.process()
        DispatchQueue.main.async {
            completion()
        }
    }

    private func process() {
        // 1. Open the document.
        guard let document = CGPDFDocument(url as CFURL) else {
            let reason = "CGPDFDocument creation failed"
            ProbeLog.err.log("PDF_ERR \(self.name, privacy: .public):\(reason)")
            ProbeLog.err.log("PDF_ERR_PATH \(self.name, privacy: .public):\(self.url.path, privacy: .public) exists=\(FileManager.default.fileExists(atPath: self.url.path))")
            self.uiLog.append("PDF_ERR \(self.name): \(reason)")
            self.moveToOut()
            return
        }

        // 2. Page count.
        let pageCount = document.numberOfPages
        ProbeLog.parse.log("PDF_PAGES \(self.name, privacy: .public):\(pageCount, privacy: .public)")
        self.uiLog.append("PDF_PAGES \(self.name): \(pageCount)")

        // 3. Render each page at 72 dpi.
        if pageCount > 0 {
            for pageIdx in 1...pageCount {
                guard let page = document.page(at: pageIdx) else {
                    ProbeLog.render.log("PDF_RENDER \(self.name, privacy: .public):\(pageIdx, privacy: .public) SKIP_NOPAGE")
                    self.uiLog.append("PDF_RENDER \(self.name): \(pageIdx) SKIP_NOPAGE")
                    continue
                }
                self.renderPage(page, index: pageIdx)
            }
        }

        // 4. Catalog + Info (trailer) dictionaries.
        self.dumpTrailer(document)

        // 5. Done.
        ProbeLog.parse.log("PDF_DONE \(self.name, privacy: .public)")
        self.uiLog.append("PDF_DONE \(self.name)")
        self.moveToOut()
    }

    private func renderPage(_ page: CGPDFPage, index: Int) {
        let box = page.getBoxRect(.mediaBox)
        // At 72 dpi render (dpiScale = 1 pt : 1 px), a page of width W points
        // becomes W pixels wide. Use ceil to avoid blank edge rows.
        let pxW = max(Int(ceil(box.width * dpiScale)), 1)
        let pxH = max(Int(ceil(box.height * dpiScale)), 1)
        let cgW = CGFloat(pxW)
        let cgH = CGFloat(pxH)

        guard let ctx = CGContext(
            data: nil, width: pxW, height: pxH,
            bitsPerComponent: 8, bytesPerRow: pxW * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            ProbeLog.render.log("PDF_RENDER \(self.name, privacy: .public):\(index, privacy: .public) CTX_FAIL")
            self.uiLog.append("PDF_RENDER \(self.name): \(index) CTX_FAIL")
            return
        }

        let fullPageBox = CGRect(x: 0, y: 0, width: cgW, height: cgH)
        ctx.setFillColor(UIColor.white.cgColor)
        ctx.fill(fullPageBox)
        ctx.saveGState()
        // PDF points are bottom-left origin; CG contexts are bottom-left by
        // default. Draw the page into its media box coordinate space.
        ctx.drawPDFPage(page)
        ctx.restoreGState()
        // Force a flush so the rasterizer must complete before we move on.
        ctx.flush()

        ProbeLog.render.log("PDF_RENDER \(self.name, privacy: .public):\(index, privacy: .public) pts=\(Int(box.width), privacy: .public)x\(Int(box.height), privacy: .public) px=\(pxW, privacy: .public)x\(pxH, privacy: .public)")
        self.uiLog.append("PDF_RENDER \(self.name): \(index) \(pxW)x\(pxH)")
    }

    private func dictKeys(_ dict: CGPDFDictionaryRef) -> [String] {
        var keys: [String] = []
        CGPDFDictionaryApplyBlock(dict, { key, _, _ in
            keys.append(String(cString: key))
            return true
        }, nil)
        return keys
    }

    private func dumpTrailer(_ document: CGPDFDocument) {
        guard let catalog = document.catalog else {
            ProbeLog.meta.log("PDF_TRAILER \(self.name, privacy: .public):CATALOG_NULL")
            self.uiLog.append("PDF_TRAILER \(self.name): CATALOG_NULL")
            return
        }
        let catalogKeys = dictKeys(catalog).map { s in
            s.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }

        guard let info = document.info else {
            ProbeLog.meta.log("PDF_TRAILER \(self.name, privacy: .public):INFO_NULL")
            self.uiLog.append("PDF_TRAILER \(self.name): INFO_NULL")
            return
        }

        let infoKeys = dictKeys(info).map { key in
            key.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }

        let joinedCatalog = catalogKeys.joined(separator: ",")
        let joinedInfo = infoKeys.joined(separator: ",")
        ProbeLog.meta.log("PDF_TRAILER \(self.name, privacy: .public):catalog=[\(joinedCatalog, privacy: .public)] info=[\(joinedInfo, privacy: .public)]")
        self.uiLog.append("PDF_TRAILER \(self.name): catalog=[\(joinedCatalog)] info=[\(joinedInfo)]")
    }

    private func moveToOut() {
        let fm = FileManager.default
        let dest = outDirURL.appendingPathComponent(name)
        let srcExists = fm.fileExists(atPath: url.path)
        let outExists = fm.fileExists(atPath: outDirURL.path)
        if fm.fileExists(atPath: dest.path) {
            // Destination already holds this file (duplicate pass). Never delete it.
            ProbeLog.loop.log("PDF_MOVED_DUP \(self.name, privacy: .public) -> Out (already present)")
            return
        }
        do {
            try fm.moveItem(at: url, to: dest)
            ProbeLog.loop.log("PDF_MOVED \(self.name, privacy: .public) -> Out")
        } catch {
            ProbeLog.err.log("PDF_MOVE_ERR \(self.name, privacy: .public):\(error.localizedDescription, privacy: .public)")
            ProbeLog.err.log("PDF_MOVE_STATE \(self.name, privacy: .public) srcExists=\(srcExists) outExists=\(outExists) srcPath=\(self.url.path, privacy: .public) outPath=\(self.outDirURL.path, privacy: .public)")
            // Best-effort fallback: copy (leave original in place for inspection).
            try? fm.copyItem(at: url, to: dest)
        }
    }
}

// MARK: - HangGuard: deadline-based watchdog

final class HangGuard {
    private var fired = false
    private let lock = NSLock()
    private let workItem: DispatchWorkItem
    var onFire: (() -> Void)?

    init(seconds: TimeInterval, onFireImmediate: @escaping () -> Void) {
        let item = DispatchWorkItem { }
        self.workItem = item
        let localFire: () -> Void = { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            if self.fired {
                self.lock.unlock()
                return
            }
            self.fired = true
            self.lock.unlock()
            onFireImmediate()
            self.onFire?()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: localFire)
    }

    func cancel() {
        lock.lock()
        fired = true
        lock.unlock()
    }
}

// MARK: - SwiftUI Root

@main
struct PDFProbeApp: App {
    @StateObject private var engine = FuzzEngine()

    var body: some Scene {
        WindowGroup {
            RootView(engine: engine)
                .onAppear {
                    engine.requestPermissionsAndBootstrap()
                }
        }
    }
}

struct RootView: View {
    @ObservedObject var engine: FuzzEngine

    var body: some View {
        VStack(spacing: 12) {
            Text("PDFProbe")
                .font(.title2)
                .bold()

            Text("Drop .pdf into Documents/In (HouseArrest) — no perms needed.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            Text(engine.statusText)
                .font(.subheadline)
                .foregroundColor(.secondary)

            Text("\(engine.processedCount) / \(engine.totalCount) processed")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack(spacing: 16) {
                Button("RUN / RESCAN") {
                    engine.manualRun()
                }
                .buttonStyle(.borderedProminent)
            }

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(engine.uiLog.lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 10, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.horizontal, 8)
            }
        }
        .padding()
    }
}
