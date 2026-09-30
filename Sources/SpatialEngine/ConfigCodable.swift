// SpatialEngine/ConfigCodable.swift — forgiving JSON persistence for SpatialConfig.
//
// The synthesized Codable throws the moment a key is missing or an enum raw value is
// unknown, which would mean "add one field in P4 → everybody's settings.json is rejected".
// Every field here therefore decodes independently and falls back to its default, so a
// file written by an older (or newer) build still loads, keeping whatever it understands.

import Foundation

extension SpatialConfig: Codable {
    enum CodingKeys: String, CodingKey {
        case eq, spatialize, sourceMode, outputType, hrtfMode, algorithm, algorithmMode, headTracking
        case azimuth, elevation, distance, gain, stereoWidth
        case interauralDelay, distanceAttenuation, attenuationCurve
        case distanceRef, distanceMax, distanceMaxAtten
        case reverbEnabled, reverbRoomType, reverbBlend, globalReverbGain
    }

    public init(from decoder: Decoder) throws {
        self.init()
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { return }
        eq                  = lenient(c, .eq, eq)
        spatialize          = lenient(c, .spatialize, spatialize)
        sourceMode          = lenient(c, .sourceMode, sourceMode)
        outputType          = lenient(c, .outputType, outputType)
        hrtfMode            = lenient(c, .hrtfMode, hrtfMode)
        algorithm           = lenient(c, .algorithm, algorithm)
        algorithmMode       = lenient(c, .algorithmMode, algorithmMode)
        headTracking        = lenient(c, .headTracking, headTracking)
        azimuth             = lenient(c, .azimuth, azimuth)
        elevation           = lenient(c, .elevation, elevation)
        distance            = lenient(c, .distance, distance)
        gain                = lenient(c, .gain, gain)
        stereoWidth         = lenient(c, .stereoWidth, stereoWidth)
        interauralDelay     = lenient(c, .interauralDelay, interauralDelay)
        distanceAttenuation = lenient(c, .distanceAttenuation, distanceAttenuation)
        attenuationCurve    = lenient(c, .attenuationCurve, attenuationCurve)
        distanceRef         = lenient(c, .distanceRef, distanceRef)
        distanceMax         = lenient(c, .distanceMax, distanceMax)
        distanceMaxAtten    = lenient(c, .distanceMaxAtten, distanceMaxAtten)
        reverbEnabled       = lenient(c, .reverbEnabled, reverbEnabled)
        reverbRoomType      = lenient(c, .reverbRoomType, reverbRoomType)
        reverbBlend         = lenient(c, .reverbBlend, reverbBlend)
        globalReverbGain    = lenient(c, .globalReverbGain, globalReverbGain)

        // Sanity: a hand-edited file must never be able to produce a NaN gain or an
        // out-of-range distance that the AU would reject at render time.
        azimuth          = clampFinite(azimuth, -180, 180, 0)
        elevation        = clampFinite(elevation, -90, 90, 0)
        distance         = clampFinite(distance, 0.1, 20, 1.2)
        gain             = clampFinite(gain, -40, 20, 4)
        stereoWidth      = clampFinite(stereoWidth, 0, 90, 35)
        distanceRef      = clampFinite(distanceRef, 0.1, 20, 1)
        distanceMax      = clampFinite(distanceMax, 0.2, 100, 6)
        distanceMaxAtten = clampFinite(distanceMaxAtten, 0, 60, 30)
        reverbBlend      = clampFinite(reverbBlend, 0, 100, 1)
        globalReverbGain = clampFinite(globalReverbGain, -40, 20, -3)
    }

    // Written out by hand rather than synthesized: Codable synthesis is only available
    // when the conformance is declared in the same file as the type.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(eq, forKey: .eq)
        try c.encode(spatialize, forKey: .spatialize)
        try c.encode(sourceMode, forKey: .sourceMode)
        try c.encode(outputType, forKey: .outputType)
        try c.encode(hrtfMode, forKey: .hrtfMode)
        try c.encode(algorithm, forKey: .algorithm)
        try c.encode(algorithmMode, forKey: .algorithmMode)
        try c.encode(headTracking, forKey: .headTracking)
        try c.encode(azimuth, forKey: .azimuth)
        try c.encode(elevation, forKey: .elevation)
        try c.encode(distance, forKey: .distance)
        try c.encode(gain, forKey: .gain)
        try c.encode(stereoWidth, forKey: .stereoWidth)
        try c.encode(interauralDelay, forKey: .interauralDelay)
        try c.encode(distanceAttenuation, forKey: .distanceAttenuation)
        try c.encode(attenuationCurve, forKey: .attenuationCurve)
        try c.encode(distanceRef, forKey: .distanceRef)
        try c.encode(distanceMax, forKey: .distanceMax)
        try c.encode(distanceMaxAtten, forKey: .distanceMaxAtten)
        try c.encode(reverbEnabled, forKey: .reverbEnabled)
        try c.encode(reverbRoomType, forKey: .reverbRoomType)
        try c.encode(reverbBlend, forKey: .reverbBlend)
        try c.encode(globalReverbGain, forKey: .globalReverbGain)
    }
}

/// Decode one key, or return the fallback — for a missing key, a null, a type mismatch,
/// or an enum raw value this build doesn't know.
@inline(__always)
public func lenient<T: Decodable, K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K, _ fallback: T) -> T {
    ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
}

@inline(__always)
public func clampFinite(_ v: Float, _ lo: Float, _ hi: Float, _ fallback: Float) -> Float {
    guard v.isFinite else { return fallback }
    return min(max(v, lo), hi)
}
