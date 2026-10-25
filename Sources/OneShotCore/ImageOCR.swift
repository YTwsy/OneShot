import Foundation
import ImageIO
import Vision

/// Vision coordinates are normalized to the image, with a lower-left origin.
/// These are image-space OCR boxes, not AX element bounds or desktop coordinates.
public struct OCRNormalizedBounds: Codable, Equatable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
}

public struct OCRTextObservation: Codable {
    public var text: String
    public var confidence: Float
    public var normalizedBounds: OCRNormalizedBounds
}

public struct OCRResult: Codable {
    public var imagePath: String
    public var source: String
    public var revision: Int
    public var recognitionLanguages: [String]
    public var usesLanguageCorrection: Bool
    public var coordinateSystem: String
    public var startedAt: Date
    public var completedAt: Date
    public var observations: [OCRTextObservation]
    /// Preserves Vision's observation order; complex columns may require separate interpretation.
    public var plainText: String
}

public enum ImageOCRError: LocalizedError {
    case imageUnreadable
    case recognitionLanguagesUnavailable
    case recognitionFailed(domain: String, code: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .imageUnreadable: return "The image could not be decoded for OCR."
        case .recognitionLanguagesUnavailable: return "Vision does not expose any of the requested Chinese or English recognition languages."
        case .recognitionFailed(let domain, let code, let message):
            return "Apple Vision OCR failed (\(domain), code \(code)): \(message)"
        }
    }
}

public enum ImageOCR {
    /// OCR is derived only from the frozen image and remains distinct from AX data.
    public static func recognize(imageURL: URL) throws -> OCRResult {
        let startedAt = Date()
        guard let imageSource = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw ImageOCRError.imageUnreadable
        }
        let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any]
        let rawOrientation = (properties?[kCGImagePropertyOrientation as String] as? NSNumber)?.uint32Value ?? 1
        let orientation = CGImagePropertyOrientation(rawValue: rawOrientation) ?? .up
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let available = Set(try request.supportedRecognitionLanguages())
        let languages = ["zh-Hans", "zh-Hant", "en-US"].filter { available.contains($0) }
        guard !languages.isEmpty else { throw ImageOCRError.recognitionLanguagesUnavailable }
        request.recognitionLanguages = languages
        let handler = VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:])
        do {
            try handler.perform([request])
        } catch {
            let error = error as NSError
            throw ImageOCRError.recognitionFailed(domain: error.domain, code: error.code,
                                                  message: error.localizedDescription)
        }
        let observations: [OCRTextObservation] = (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox
            return OCRTextObservation(text: candidate.string, confidence: candidate.confidence,
                                      normalizedBounds: OCRNormalizedBounds(x: box.minX, y: box.minY,
                                                                            width: box.width, height: box.height))
        }
        return OCRResult(imagePath: imageURL.path, source: "Apple Vision.VNRecognizeTextRequest",
                         revision: request.revision, recognitionLanguages: languages,
                         usesLanguageCorrection: request.usesLanguageCorrection,
                         coordinateSystem: "normalized-image-bottom-left",
                         startedAt: startedAt, completedAt: Date(), observations: observations,
                         plainText: observations.map(\.text).joined(separator: "\n"))
    }
}
