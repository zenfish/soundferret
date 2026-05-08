#!/usr/bin/env swift
// whoplays — list macOS processes currently emitting audio.
// Uses CoreAudio process objects (macOS 14.2+).
//   kAudioProcessPropertyIsRunningOutput — bool, engine running for process.
// --rms: tap each emitting PID for ~150 ms, compute RMS / dBFS to filter silence.
//        First run prompts TCC for "System Audio Recording" — must approve.
// Usage:
//   whoplays                  # one-shot
//   whoplays --watch [secs]   # refreshing
//   whoplays --rms            # one-shot with sample-level RMS
//   whoplays --watch --rms    # both

import CoreAudio
import Foundation
import Darwin

let sysObj = AudioObjectID(kAudioObjectSystemObject)

func addr(_ sel: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
        mSelector: sel,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
}

func getProcs() -> [AudioObjectID] {
    var a = addr(AudioObjectPropertySelector(kAudioHardwarePropertyProcessObjectList))
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(sysObj, &a, 0, nil, &size) == noErr else { return [] }
    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    var procs = [AudioObjectID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(sysObj, &a, 0, nil, &size, &procs) == noErr else { return [] }
    return procs
}

func getPID(_ obj: AudioObjectID) -> pid_t? {
    var a = addr(AudioObjectPropertySelector(kAudioProcessPropertyPID))
    var pid: pid_t = -1
    var size = UInt32(MemoryLayout<pid_t>.size)
    guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &pid) == noErr else { return nil }
    return pid >= 0 ? pid : nil
}

func getBool(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> Bool {
    var a = addr(sel)
    var v: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &v) == noErr else { return false }
    return v != 0
}

func getCFString(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
    var a = addr(sel)
    var cf: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &cf) == noErr,
          let s = cf?.takeRetainedValue() else { return nil }
    return s as String
}

func procName(_ pid: pid_t) -> String {
    let p = Process()
    p.launchPath = "/bin/ps"
    p.arguments = ["-o", "comm=", "-p", String(pid)]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()
    do { try p.run() } catch { return "?" }
    p.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if s.isEmpty { return "?" }
    return (s as NSString).lastPathComponent
}

// RMS via CoreAudio Process Tap (macOS 14.2+)
// Returns (rms, dBFS). nil = tap creation failed (TCC denial likely).
@available(macOS 14.2, *)
func sampleRMS(processObjID: AudioObjectID, duration: Double = 0.15) -> (Float, Float)? {
    let desc = CATapDescription(stereoMixdownOfProcesses: [processObjID])
    desc.uuid = UUID()
    desc.isPrivate = true
    desc.isExclusive = false

    var tapID: AudioObjectID = 0
    let tapStatus = AudioHardwareCreateProcessTap(desc, &tapID)
    guard tapStatus == noErr, tapID != 0 else { return nil }
    defer { AudioHardwareDestroyProcessTap(tapID) }

    guard let tapUID = getCFString(tapID, AudioObjectPropertySelector(kAudioTapPropertyUID)) else {
        return nil
    }

    let aggDesc: [String: Any] = [
        kAudioAggregateDeviceUIDKey: UUID().uuidString,
        kAudioAggregateDeviceNameKey: "whoplays-rms",
        kAudioAggregateDeviceIsPrivateKey: 1,
        kAudioAggregateDeviceIsStackedKey: 0,
        kAudioAggregateDeviceTapAutoStartKey: 1,
        kAudioAggregateDeviceTapListKey: [
            [
                kAudioSubTapUIDKey: tapUID,
                kAudioSubTapDriftCompensationKey: 0,
            ]
        ],
    ]
    var aggID: AudioObjectID = 0
    guard AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &aggID) == noErr,
          aggID != 0 else { return nil }
    defer { AudioHardwareDestroyAggregateDevice(aggID) }

    if debugMode {
        // Inspect tap format
        var fmtAddr = AudioObjectPropertyAddress(
            mSelector: AudioObjectPropertySelector(kAudioTapPropertyFormat),
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var fSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let fStatus = AudioObjectGetPropertyData(tapID, &fmtAddr, 0, nil, &fSize, &asbd)
        FileHandle.standardError.write("tap format status=\(fStatus) sr=\(asbd.mSampleRate) chs=\(asbd.mChannelsPerFrame) bits=\(asbd.mBitsPerChannel) flags=0x\(String(asbd.mFormatFlags, radix:16)) id=0x\(String(asbd.mFormatID, radix:16))\n".data(using: .utf8)!)
    }

    let sumSq = Atomic<Double>(0)
    let sampleCount = Atomic<Int>(0)
    let cbCount = Atomic<Int>(0)
    let maxAbs = Atomic<Double>(0)

    var procID: AudioDeviceIOProcID?
    let createStatus = AudioDeviceCreateIOProcIDWithBlock(
        &procID, aggID, nil
    ) { _, inInputData, _, _, _ in
        cbCount.add(1)
        let mutPtr = UnsafeMutablePointer<AudioBufferList>(mutating: inInputData)
        let ablPtr = UnsafeMutableAudioBufferListPointer(mutPtr)
        var localSum: Double = 0
        var localCount: Int = 0
        var localMax: Double = 0
        for buf in ablPtr {
            let n = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
            guard let p = buf.mData?.bindMemory(to: Float.self, capacity: n) else { continue }
            for i in 0..<n {
                let v = Double(p[i])
                localSum += v * v
                let a = abs(v); if a > localMax { localMax = a }
            }
            localCount += n
        }
        sumSq.add(localSum)
        sampleCount.add(localCount)
        maxAbs.maxWith(localMax)
    }
    guard createStatus == noErr, let pidProc = procID else {
        if debugMode { FileHandle.standardError.write("createIOProc status=\(createStatus)\n".data(using: .utf8)!) }
        return nil
    }
    defer { AudioDeviceDestroyIOProcID(aggID, pidProc) }

    let startStatus = AudioDeviceStart(aggID, pidProc)
    guard startStatus == noErr else {
        if debugMode { FileHandle.standardError.write("AudioDeviceStart status=\(startStatus)\n".data(using: .utf8)!) }
        return nil
    }
    Thread.sleep(forTimeInterval: duration)
    AudioDeviceStop(aggID, pidProc)

    if debugMode {
        FileHandle.standardError.write("tapID=\(tapID) aggID=\(aggID) cbs=\(cbCount.value) samples=\(sampleCount.value) maxAbs=\(maxAbs.value)\n".data(using: .utf8)!)
    }

    let count = sampleCount.value
    guard count > 0 else { return (0, -.infinity) }
    let rms = Float(sqrt(sumSq.value / Double(count)))
    let db = rms > 0 ? 20 * log10f(rms) : -.infinity
    return (rms, db)
}

// Tiny atomic wrapper (NSLock — fine for ~150 ms of callbacks).
final class Atomic<T> {
    private var v: T
    private let lock = NSLock()
    init(_ initial: T) { v = initial }
    var value: T { lock.lock(); defer { lock.unlock() }; return v }
}
extension Atomic where T == Double {
    func add(_ x: Double) { lock.lock(); v += x; lock.unlock() }
    func maxWith(_ x: Double) { lock.lock(); if x > v { v = x }; lock.unlock() }
}
extension Atomic where T == Int {
    func add(_ x: Int) { lock.lock(); v += x; lock.unlock() }
}

var debugMode = false

struct Emitter {
    let pid: pid_t
    let objID: AudioObjectID
    let name: String
    let bundle: String?
    let output: Bool
    let input: Bool
    var rmsDB: Float? = nil
}

func scan(withRMS: Bool) -> [Emitter] {
    var out: [Emitter] = []
    for obj in getProcs() {
        guard let pid = getPID(obj) else { continue }
        let outActive = getBool(obj, AudioObjectPropertySelector(kAudioProcessPropertyIsRunningOutput))
        let inActive  = getBool(obj, AudioObjectPropertySelector(kAudioProcessPropertyIsRunningInput))
        guard outActive || inActive else { continue }
        var e = Emitter(
            pid: pid,
            objID: obj,
            name: procName(pid),
            bundle: getCFString(obj, AudioObjectPropertySelector(kAudioProcessPropertyBundleID)),
            output: outActive,
            input: inActive
        )
        if withRMS, outActive, #available(macOS 14.2, *) {
            if let (_, db) = sampleRMS(processObjID: obj) {
                e.rmsDB = db
            }
        }
        out.append(e)
    }
    return out.sorted { $0.pid < $1.pid }
}

func pad(_ s: String, _ w: Int) -> String {
    s.count >= w ? s : s + String(repeating: " ", count: w - s.count)
}

func fmtDB(_ db: Float?) -> String {
    guard let db else { return "  -  " }
    if db == -.infinity { return " -inf" }
    return String(format: "%5.1f", db)
}

func renderLines(_ rows: [Emitter], showRMS: Bool) -> [String] {
    if rows.isEmpty { return ["(no audio-active processes)"] }
    var out: [String] = []
    var header = "\(pad("PID", 7)) \(pad("I/O", 4)) \(pad("NAME", 28))"
    if showRMS { header += " \(pad("dBFS", 6))" }
    header += " BUNDLE"
    out.append(header)
    for r in rows {
        var io = ""
        if r.output { io += "O" }
        if r.input  { io += "I" }
        var line = "\(pad(String(r.pid), 7)) \(pad(io, 4)) \(pad(r.name, 28))"
        if showRMS { line += " \(pad(fmtDB(r.rmsDB), 6))" }
        line += " \(r.bundle ?? "-")"
        out.append(line)
    }
    return out
}

func render(_ rows: [Emitter], showRMS: Bool) {
    for line in renderLines(rows, showRMS: showRMS) { print(line) }
}

let args = Array(CommandLine.arguments.dropFirst())
let watch = args.contains("--watch")
let rms   = args.contains("--rms")
debugMode = args.contains("--debug")
let interval: Double = {
    if let i = args.firstIndex(of: "--watch"), i + 1 < args.count, let v = Double(args[i + 1]) {
        return v
    }
    return 1.0
}()

if watch {
    // Alt screen + hide cursor. Restore on SIGINT/SIGTERM.
    let enterAlt   = "\u{001B}[?1049h"
    let leaveAlt   = "\u{001B}[?1049l"
    let hideCursor = "\u{001B}[?25l"
    let showCursor = "\u{001B}[?25h"
    let cursorHome = "\u{001B}[H"
    let clearEOL   = "\u{001B}[K"
    let clearBelow = "\u{001B}[J"

    func teardown() {
        FileHandle.standardOutput.write((showCursor + leaveAlt).data(using: .utf8)!)
    }
    let sigSrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    sigSrc.setEventHandler { teardown(); exit(0) }
    sigSrc.resume()
    signal(SIGINT, SIG_IGN) // let DispatchSource handle it

    let sigT = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    sigT.setEventHandler { teardown(); exit(0) }
    sigT.resume()
    signal(SIGTERM, SIG_IGN)

    atexit { FileHandle.standardOutput.write(("\u{001B}[?25h" + "\u{001B}[?1049l").data(using: .utf8)!) }

    FileHandle.standardOutput.write((enterAlt + hideCursor).data(using: .utf8)!)

    // Background thread for rendering; main thread runs the dispatch loop so signal source delivers.
    DispatchQueue.global(qos: .userInitiated).async {
        while true {
            let header = "whoplays — \(Date())\(rms ? "  [rms]" : "")  (Ctrl-C to quit)"
            let lines = [header] + renderLines(scan(withRMS: rms), showRMS: rms)
            var frame = cursorHome
            for line in lines { frame += line + clearEOL + "\n" }
            frame += clearBelow
            FileHandle.standardOutput.write(frame.data(using: .utf8)!)
            Thread.sleep(forTimeInterval: interval)
        }
    }
    dispatchMain()
} else {
    render(scan(withRMS: rms), showRMS: rms)
}
