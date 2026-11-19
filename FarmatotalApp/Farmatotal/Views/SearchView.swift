import SwiftUI
import VisionKit
import AVFoundation
import Speech

struct SearchView: View {
    @State private var text = ""
    @State private var query: ProductQuery?
    @State private var scanning = false
    @State private var speech = SpeechRecognizer()
    @AppStorage("recentSearches") private var recentRaw = ""

    private var recent: [String] { recentRaw.split(separator: "\n").map(String.init) }

    var body: some View {
        Group {
            if let query {
                ProductListView(title: query.sku.map { "Código \($0)" } ?? "“\(query.search ?? "")”", query: query)
                    .id(query)
            } else {
                List {
                    if !recent.isEmpty {
                        Section {
                            ForEach(recent, id: \.self) { term in
                                Button { submit(term) } label: {
                                    Label(term, systemImage: "clock.arrow.circlepath").foregroundStyle(.primary)
                                }
                            }
                        } header: {
                            HStack {
                                Text("Búsquedas recientes")
                                Spacer()
                                Button("Borrar") { recentRaw = "" }.font(.caption)
                            }
                        }
                    }
                    Section("Buscá más rápido") {
                        Button { scanning = true } label: { Label("Escanear código de barras", systemImage: "barcode.viewfinder") }
                        Button { toggleVoice() } label: { Label("Buscar por voz", systemImage: "mic") }
                    }
                }
            }
        }
        .navigationTitle("Buscar")
        .searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always), prompt: "Medicamentos, marcas, productos…")
        .onSubmit(of: .search) { submit(text) }
        .onChange(of: text) { _, new in if new.isEmpty { query = nil } }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { toggleVoice() } label: { Image(systemName: speech.isRecording ? "mic.fill" : "mic") }
                    .accessibilityLabel("Buscar por voz")
                Button { scanning = true } label: { Image(systemName: "barcode.viewfinder") }
                    .accessibilityLabel("Escanear código de barras")
            }
        }
        .overlay(alignment: .bottom) {
            if speech.isRecording {
                VStack(spacing: 10) {
                    Image(systemName: "waveform").font(.largeTitle).symbolEffect(.variableColor.iterative)
                    Text(speech.transcript.isEmpty ? "Escuchando…" : speech.transcript).font(.headline)
                    Button("Listo") { speech.stop() }.buttonStyle(.borderedProminent)
                }
                .padding(24)
                .frame(maxWidth: .infinity)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
                .padding()
            }
        }
        .onChange(of: speech.isRecording) { _, recording in
            if !recording, !speech.transcript.isEmpty {
                text = speech.transcript
                submit(speech.transcript)
            }
        }
        .alert("Búsqueda por voz", isPresented: Binding(get: { speech.error != nil }, set: { if !$0 { speech.error = nil } })) {
            Button("OK") {}
        } message: {
            Text(speech.error ?? "")
        }
        .fullScreenCover(isPresented: $scanning) {
            BarcodeScannerView { code in
                scanning = false
                text = code
                query = ProductQuery(sku: code)
            }
        }
    }

    private func toggleVoice() {
        if speech.isRecording { speech.stop() } else { Task { await speech.start() } }
    }

    private func submit(_ term: String) {
        let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        text = t
        query = ProductQuery(search: t)
        recentRaw = ([t] + recent.filter { $0.caseInsensitiveCompare(t) != .orderedSame }).prefix(8).joined(separator: "\n")
    }
}

// MARK: Barcode

struct BarcodeScannerView: View {
    let onCode: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var manual = ""
    @State private var torchOn = false

    var body: some View {
        NavigationStack {
            Group {
                if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                    DataScanner(onCode: onCode).ignoresSafeArea()
                } else {
                    ContentUnavailableView("Escáner no disponible", systemImage: "barcode.viewfinder",
                                           description: Text("Permití el acceso a la cámara en Ajustes o ingresá el código manualmente."))
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    TextField("Ingresar código manualmente", text: $manual)
                        .keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder)
                    Button("Buscar") { onCode(manual) }
                        .buttonStyle(.borderedProminent)
                        .disabled(manual.isEmpty)
                }
                .padding()
                .background(.regularMaterial)
            }
            .navigationTitle("Escanear código")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { toggleTorch() } label: { Image(systemName: torchOn ? "flashlight.on.fill" : "flashlight.off.fill") }
                        .accessibilityLabel("Linterna")
                }
            }
        }
    }

    private func toggleTorch() {
        guard let device = AVCaptureDevice.default(for: .video), device.hasTorch, (try? device.lockForConfiguration()) != nil else { return }
        torchOn.toggle()
        device.torchMode = torchOn ? .on : .off
        device.unlockForConfiguration()
    }
}

private struct DataScanner: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(recognizedDataTypes: [.barcode()], qualityLevel: .balanced,
                                           isHighlightingEnabled: true)
        vc.delegate = context.coordinator
        DispatchQueue.main.async { try? vc.startScanning() }
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        private var done = false
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func dataScanner(_ scanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !done else { return }
            for item in addedItems {
                if case .barcode(let code) = item, let value = code.payloadStringValue {
                    done = true
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    onCode(value)
                    return
                }
            }
        }
    }
}

// MARK: Voice

@MainActor @Observable
final class SpeechRecognizer {
    var transcript = ""
    var isRecording = false
    var error: String?

    @ObservationIgnored private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "es-PY"))
        ?? SFSpeechRecognizer(locale: Locale(identifier: "es-ES"))
    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?

    func start() async {
        transcript = ""
        let speechOK = await withCheckedContinuation { c in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
        let micOK = await AVAudioApplication.requestRecordPermission()
        guard speechOK, micOK, let recognizer, recognizer.isAvailable else {
            error = "Permití el micrófono y el reconocimiento de voz en Ajustes para buscar hablando."
            return
        }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            request = req
            let input = engine.inputNode
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
                req.append(buffer)
            }
            engine.prepare()
            try engine.start()
            isRecording = true
            task = recognizer.recognitionTask(with: req) { [weak self] result, err in
                Task { @MainActor in
                    guard let self else { return }
                    if let result { self.transcript = result.bestTranscription.formattedString }
                    if err != nil || result?.isFinal == true { self.stop() }
                }
            }
        } catch {
            stop()
            self.error = "No se pudo iniciar el micrófono."
        }
    }

    func stop() {
        guard isRecording || request != nil else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isRecording = false
    }
}
