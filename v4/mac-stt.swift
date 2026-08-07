// mac-stt: macOS 26 SpeechAnalyzer/SpeechTranscriber CLI for Hammerspoon dictation.
// Usage: mac-stt <wav-path> [locale]   (locale default ko-KR)
// Prints the transcription to stdout. Exit 0 = success, 2 = no speech, 1 = error.

import AVFoundation
import Foundation
import Speech

let noSpeechExit: Int32 = 2
let errorExit: Int32 = 1

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("mac-stt: \(message)\n".utf8))
    exit(errorExit)
}

@available(macOS 26.0, *)
func transcribe(path: String, localeID: String) async throws -> String {
    let locale = Locale(identifier: localeID)

    // The locale asset must already be installed; we do not trigger a download
    // here because dictation is latency-sensitive and a download would hang.
    let installed = await SpeechTranscriber.installedLocales
    let isInstalled = installed.contains { $0.identifier(.bcp47) == locale.identifier(.bcp47) }
    if !isInstalled {
        fail("locale \(localeID) not installed")
    }

    let transcriber = SpeechTranscriber(
        locale: locale,
        transcriptionOptions: [],
        reportingOptions: [],
        attributeOptions: []
    )
    let analyzer = SpeechAnalyzer(modules: [transcriber])

    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))

    // Results stream must be drained concurrently with analysis, otherwise the
    // analyzer blocks once its internal buffer fills.
    let collector = Task {
        var text = ""
        for try await result in transcriber.results {
            text += String(result.text.characters)
        }
        return text
    }

    if let lastSample = try await analyzer.analyzeSequence(from: file) {
        try await analyzer.finalizeAndFinish(through: lastSample)
    } else {
        try await analyzer.cancelAndFinishNow()
    }

    return try await collector.value
}

let args = CommandLine.arguments
guard args.count >= 2 else {
    fail("usage: mac-stt <wav-path> [locale]")
}
let wavPath = args[1]
let localeID = args.count > 2 ? args[2] : "ko-KR"

guard FileManager.default.fileExists(atPath: wavPath) else {
    fail("file not found: \(wavPath)")
}

if #available(macOS 26.0, *) {
    Task {
        do {
            let raw = try await transcribe(path: wavPath, localeID: localeID)
            // The engine emits "." or "" for silence; treat punctuation-only as no speech.
            let stripped = raw.trimmingCharacters(
                in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
            )
            if stripped.isEmpty {
                exit(noSpeechExit)
            }
            print(raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines))
            exit(0)
        } catch {
            fail("\(error)")
        }
    }
    RunLoop.main.run()
} else {
    fail("requires macOS 26 or later")
}
