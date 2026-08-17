import CoreML
import Foundation

actor CLIPEncoder {
    static let embeddingDimension = 512
    private static let frameBatchSize = 16

    private let imageModel: MLModel
    private let textModel: MLModel
    private let tokenizer: CLIPTokenizer

    init() throws {
        guard let imageURL = Bundle.main.url(forResource: "mobileclip_s2_image", withExtension: "mlmodelc"),
              let textURL = Bundle.main.url(forResource: "mobileclip_s2_text", withExtension: "mlmodelc"),
              let tokenizerURL = Bundle.main.url(forResource: "tokenizer", withExtension: "json") else {
            throw CLIPError.modelsMissing
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndNeuralEngine
        self.imageModel = try MLModel(contentsOf: imageURL, configuration: configuration)
        self.textModel = try MLModel(contentsOf: textURL, configuration: configuration)
        self.tokenizer = try CLIPTokenizer(contentsOf: tokenizerURL)
    }

    func encodeText(_ text: String) throws -> [Float] {
        let tokens = tokenizer.encode(text)
        let array = try MLMultiArray(shape: [1, NSNumber(value: CLIPTokenizer.contextLength)], dataType: .int32)
        for (index, token) in tokens.enumerated() {
            array[index] = NSNumber(value: token)
        }
        let input = try MLDictionaryFeatureProvider(dictionary: ["text": MLFeatureValue(multiArray: array)])
        let output = try textModel.prediction(from: input)
        return Self.normalized(Self.floats(from: output))
    }

    func encodeImages(_ images: [DecodedImage]) throws -> [[Float]?] {
        var providers: [MLFeatureProvider] = []
        var slots: [Int] = []
        for (index, image) in images.enumerated() {
            guard let buffer = image.buffer else {
                continue
            }
            providers.append(try MLDictionaryFeatureProvider(
                dictionary: ["image": MLFeatureValue(pixelBuffer: buffer)]
            ))
            slots.append(index)
        }
        guard !providers.isEmpty else {
            return Array(repeating: nil, count: images.count)
        }
        let outputs = try imageModel.predictions(fromBatch: MLArrayBatchProvider(array: providers))
        var results = [[Float]?](repeating: nil, count: images.count)
        for position in 0..<outputs.count {
            results[slots[position]] = Self.normalized(Self.floats(from: outputs.features(at: position)))
        }
        return results
    }

    func encodeFrames(_ frames: [DecodedVideoFrame]) throws -> [VideoKeyframe] {
        guard !frames.isEmpty else {
            return []
        }
        var keyframes: [VideoKeyframe] = []
        keyframes.reserveCapacity(frames.count)
        for start in stride(from: 0, to: frames.count, by: Self.frameBatchSize) {
            let end = min(start + Self.frameBatchSize, frames.count)
            let providers = try frames[start..<end].map {
                try MLDictionaryFeatureProvider(dictionary: ["image": MLFeatureValue(pixelBuffer: $0.buffer)])
            }
            let outputs = try imageModel.predictions(fromBatch: MLArrayBatchProvider(array: providers))
            for position in 0..<outputs.count {
                keyframes.append(VideoKeyframe(
                    time: frames[start + position].time,
                    embedding: Self.normalized(Self.floats(from: outputs.features(at: position)))
                ))
            }
        }
        return keyframes
    }

    private static func floats(from provider: MLFeatureProvider) -> [Float] {
        guard let array = provider.featureValue(for: "final_emb_1")?.multiArrayValue else {
            return []
        }
        return (0..<array.count).map { array[$0].floatValue }
    }

    private static func normalized(_ vector: [Float]) -> [Float] {
        let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else {
            return vector
        }
        return vector.map { $0 / norm }
    }
}

struct VideoKeyframe: Sendable {
    let time: Double
    let embedding: [Float]
}

enum CLIPError: LocalizedError {
    case modelsMissing
    case malformedTokenizer

    var errorDescription: String? {
        switch self {
        case .modelsMissing:
            "The MobileCLIP models are missing from the app bundle."
        case .malformedTokenizer:
            "tokenizer.json is missing or not in the expected format."
        }
    }
}
