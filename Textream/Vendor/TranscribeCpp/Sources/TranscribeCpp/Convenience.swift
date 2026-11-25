import CTranscribe

extension Transcribe {
    /// One-shot helper: load a model, transcribe one utterance, return the
    /// result. For repeated use, hold a `Model` and reuse its `Session`.
    public static func transcribe(
        modelPath: String,
        pcm: [Float],
        options: RunOptions = .init(),
        modelOptions: ModelOptions = .init()
    ) throws -> Transcript {
        let model = try Model(path: modelPath, options: modelOptions)
        return try model.session().run(pcm, options: options)
    }
}
