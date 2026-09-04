import SwiftUI
import UniformTypeIdentifiers
import DunnageCore

/// The one screen (spec §4.2): a picker, the token and base-URL fields, one row per planned
/// chunk, and the two markers the tier-2 test reads.
///
/// Every value the test reads carries an accessibility identifier and nothing else does.
/// The rows show what `UploadModel` derived from the log; this view computes no upload
/// state of its own, which is §4.3's precondition and the reason the second assertion is
/// evidence about the ledger.
struct UploadScreen: View {
    @ObservedObject var model: UploadModel
    @State private var choosing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                field("base URL", text: $model.baseURLText, identifier: "base-url")
                field("token", text: $model.token, identifier: "token")

                Button("Choose a file…") { choosing = true }
                    .accessibilityIdentifier("choose-file")

                #if DEBUG
                // The sample the tier-2 test uploads. It exists because a UI test cannot
                // drive the system document browser deterministically, and it is behind
                // `#if DEBUG` for the reason ADR-0007 §10 puts the negative control there:
                // a control the tests need is not a thing a release build ships. It takes
                // the *same* copy path as the picker above — `Container.adoptPayload` — so
                // what the simulator exercises is the path a picked file takes, and rider
                // (b)'s own claim stays `testPayloadRefNamesTheCopyInsideTheContainer`.
                Button("Use the sample payload") {
                    Task { await start(from: SamplePayload.write()) }
                }
                .accessibilityIdentifier("use-sample-payload")
                #endif

                Divider()

                ForEach(model.chunks, id: \.ordinal) { chunk in
                    row("chunk \(chunk.ordinal)",
                        value: (model.statuses[chunk] ?? .planned).rawValue,
                        identifier: "chunk-\(chunk.ordinal)-status")
                }

                Divider()

                row("phase", value: model.phase, identifier: "upload-phase")
                row("last exit", value: model.lastExit, identifier: "last-exit")
                row("note", value: model.note, identifier: "driver-note")
            }
            .padding()
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.data]) { result in
            guard case .success(let picked) = result else { return }
            Task { await start(from: picked) }
        }
    }

    private func start(from source: URL) async {
        await model.startUpload(from: source)
    }

    private func field(_ label: String, text: Binding<String>, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption)
            TextField(label, text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier(identifier)
        }
    }

    /// `children: .contain` so the value keeps its own accessibility element. Merged into
    /// the row's, the identifier the test queries would name a label that is not the value.
    private func row(_ label: String, value: String, identifier: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).accessibilityIdentifier(identifier)
        }
        .accessibilityElement(children: .contain)
    }
}

#if DEBUG
/// The sample payload: four chunks of `UploadModel.chunkSize`, written outside the
/// container so the copy the app makes is a real copy of a file it did not own.
///
/// Deterministic bytes, because a payload from an entropy source would make two runs of the
/// tier-2 test two different experiments.
enum SamplePayload {
    static let chunkCount = 4

    static func write() -> URL {
        let bytes = Data((0..<(chunkCount * UploadModel.chunkSize)).map { UInt8($0 % 251) })
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("dunnage-sample-payload")
        try? bytes.write(to: file)
        return file
    }
}
#endif
