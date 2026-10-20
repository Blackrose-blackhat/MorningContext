import SwiftUI
import AppKit
import MetalKit
import AVFoundation

// Native SwiftUI ports of ElevenLabs UI components (https://ui.elevenlabs.io), MIT License,
// Copyright (c) 2025 Eleven Labs Inc. Orb, ShimmeringText, BarVisualizer, LiveWaveform, Message, ConversationBar
// and VoicePicker follow the originals' designs and animation logic; the Orb's GLSL is ported to Metal.

// MARK: - Orb

enum OrbState: Equatable { case idle, thinking, listening, talking }

/// ElevenLabs' Orb: an animated, audio-reactive gradient sphere. Rendered with Metal; the shader is compiled
/// at runtime so building the app never needs the Metal toolchain.
struct OrbView: NSViewRepresentable {
    var state: OrbState = .idle
    /// Real levels (0…1) when available; the orb falls back to state-driven motion like the original's "auto" mode.
    var inputLevel: Float = 0
    var outputLevel: Float = 0
    var colors: (Color, Color) = (Color(hex: 0xCADCFC), Color(hex: 0xA0B9D1))
    var seed: Int = 0
    var fps: Int = 60

    func makeNSView(context: Context) -> NSView {
        guard let renderer = OrbRenderer(seed: seed) else { return OrbFallbackView() }
        let v = MTKView(frame: .zero, device: renderer.device)
        v.colorPixelFormat = .bgra8Unorm
        v.framebufferOnly = true
        v.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        v.layer?.isOpaque = false
        v.preferredFramesPerSecond = fps
        v.delegate = renderer
        context.coordinator.renderer = renderer
        apply(to: renderer, in: v)
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let r = context.coordinator.renderer else { return }
        apply(to: r, in: nsView)
    }

    private func apply(to r: OrbRenderer, in view: NSView) {
        r.state = state
        r.realInput = inputLevel
        r.realOutput = outputLevel
        r.targetColor1 = colors.0.rgb
        r.targetColor2 = colors.1.rgb
        // The original inverts in dark mode; on frosted glass the light palette reads far cleaner, so keep it.
        r.inverted = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var renderer: OrbRenderer? }
}

/// Used only if Metal isn't available.
private final class OrbFallbackView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1))
        NSGradient(colors: [NSColor(calibratedRed: 0.79, green: 0.86, blue: 0.99, alpha: 1),
                            NSColor(calibratedRed: 0.63, green: 0.73, blue: 0.82, alpha: 1)])?.draw(in: path, angle: -60)
    }
}

/// Mirrors the original's per-frame logic (useFrame): time, smoothed volumes, animation speed, colour lerp.
final class OrbRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let noise: MTLTexture

    var state: OrbState = .idle
    var realInput: Float = 0
    var realOutput: Float = 0
    var targetColor1 = SIMD3<Float>(0.79, 0.86, 0.99)
    var targetColor2 = SIMD3<Float>(0.63, 0.73, 0.82)
    var inverted = false

    private var u = OrbUniforms()
    private var curIn: Float = 0, curOut: Float = 0, animSpeed: Float = 0.1
    private var last = CACurrentMediaTime()

    init?(seed: Int) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let pipeline = OrbRenderer.pipeline(device), let noise = OrbRenderer.noiseTexture(device) else { return nil }
        self.device = device; self.queue = queue; self.pipeline = pipeline; self.noise = noise
        super.init()
        var rng = SeededRandom(seed: UInt64(truncatingIfNeeded: seed &* 7919 &+ 17))
        withUnsafeMutableBytes(of: &u.offsets) { raw in
            let f = raw.bindMemory(to: Float.self)
            for i in 0..<7 { f[i] = Float(rng.next01()) * 2 * .pi }
        }
        u.color1 = SIMD4(targetColor1, 1); u.color2 = SIMD4(targetColor2, 1)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        let dt = Float(min(0.1, now - last)); last = now
        step(dt)
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let cmd = queue.makeCommandBuffer(), let enc = cmd.makeRenderCommandEncoder(descriptor: pass) else { return }
        enc.setRenderPipelineState(pipeline)
        var uniforms = u
        enc.setFragmentBytes(&uniforms, length: MemoryLayout<OrbUniforms>.stride, index: 0)
        enc.setFragmentTexture(noise, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()
        cmd.present(drawable)
        cmd.commit()
    }

    private func step(_ dt: Float) {
        u.time += dt * 0.5
        if u.opacity < 1 { u.opacity = min(1, u.opacity + dt * 2) }
        let t = u.time * 2
        var targetIn: Float, targetOut: Float
        switch state {
        case .idle: targetIn = 0; targetOut = 0.3
        case .listening:
            targetIn = clamp01(0.55 + sin(t * 3.2) * 0.35); targetOut = 0.45
            if realInput > 0.05 { targetIn = clamp01(max(targetIn * 0.5, realInput)) }
        case .talking:
            targetIn = clamp01(0.65 + sin(t * 4.8) * 0.22); targetOut = clamp01(0.75 + sin(t * 3.6) * 0.22)
            if realOutput > 0.02 { targetOut = clamp01(0.45 + realOutput * 0.6) }
        case .thinking:
            let base = 0.38 + 0.07 * sin(t * 0.7)
            let wander = 0.05 * sin(t * 2.1) * sin(t * 0.37 + 1.2)
            targetIn = clamp01(base + wander); targetOut = clamp01(0.48 + 0.12 * sin(t * 1.05 + 0.6))
        }
        curIn += (targetIn - curIn) * 0.2
        curOut += (targetOut - curOut) * 0.2
        let targetSpeed = 0.1 + (1 - pow(curOut - 1, 2)) * 0.9
        animSpeed += (targetSpeed - animSpeed) * 0.12
        u.animation += dt * animSpeed
        u.inputVolume = curIn
        u.outputVolume = curOut
        u.inverted = inverted ? 1 : 0
        let c1 = SIMD3(u.color1.x, u.color1.y, u.color1.z), c2 = SIMD3(u.color2.x, u.color2.y, u.color2.z)
        u.color1 = SIMD4(c1 + (targetColor1 - c1) * 0.08, 1)
        u.color2 = SIMD4(c2 + (targetColor2 - c2) * 0.08, 1)
    }

    private func clamp01(_ x: Float) -> Float { min(1, max(0, x)) }

    // MARK: Shared GPU resources

    private static var cachedPipeline: MTLRenderPipelineState?
    private static var cachedNoise: MTLTexture?

    private static func pipeline(_ device: MTLDevice) -> MTLRenderPipelineState? {
        if let p = cachedPipeline { return p }
        do {
            let lib = try device.makeLibrary(source: orbShaderSource, options: nil)
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = lib.makeFunction(name: "orb_vertex")
            d.fragmentFunction = lib.makeFunction(name: "orb_fragment")
            let a = d.colorAttachments[0]!
            a.pixelFormat = .bgra8Unorm
            a.isBlendingEnabled = true
            a.sourceRGBBlendFactor = .one; a.sourceAlphaBlendFactor = .one          // premultiplied alpha
            a.destinationRGBBlendFactor = .oneMinusSourceAlpha; a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            let p = try device.makeRenderPipelineState(descriptor: d)
            cachedPipeline = p
            return p
        } catch {
            AppLog().info("orb shader failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Tileable Perlin noise, standing in for the original's perlin-noise.png (generated here, nothing downloaded).
    private static func noiseTexture(_ device: MTLDevice) -> MTLTexture? {
        if let t = cachedNoise { return t }
        let n = 256
        var pixels = [UInt8](repeating: 0, count: n * n)
        var rng = SeededRandom(seed: 42)
        let period = 8
        var grads = [SIMD2<Float>](repeating: .zero, count: period * period * 4)
        for i in grads.indices { let a = Float(rng.next01()) * 2 * .pi; grads[i] = SIMD2(cos(a), sin(a)) }
        func perlin(_ x: Float, _ y: Float, _ p: Int) -> Float {
            let xi = Int(floor(x)), yi = Int(floor(y))
            let xf = x - Float(xi), yf = y - Float(yi)
            func g(_ ix: Int, _ iy: Int) -> SIMD2<Float> { grads[((((iy % p) + p) % p) * p + (((ix % p) + p) % p)) % grads.count] }
            func fade(_ t: Float) -> Float { t * t * t * (t * (t * 6 - 15) + 10) }
            let n00 = simd_dot(g(xi, yi), SIMD2(xf, yf)), n10 = simd_dot(g(xi + 1, yi), SIMD2(xf - 1, yf))
            let n01 = simd_dot(g(xi, yi + 1), SIMD2(xf, yf - 1)), n11 = simd_dot(g(xi + 1, yi + 1), SIMD2(xf - 1, yf - 1))
            let u = fade(xf), v = fade(yf)
            return (n00 * (1 - u) + n10 * u) * (1 - v) + (n01 * (1 - u) + n11 * u) * v
        }
        for y in 0..<n {
            for x in 0..<n {
                var value: Float = 0, amp: Float = 0.5, freq = 1
                for _ in 0..<4 {
                    let p = period * freq
                    value += amp * perlin(Float(x) / Float(n) * Float(p), Float(y) / Float(n) * Float(p), p)
                    amp *= 0.5; freq *= 2
                }
                pixels[y * n + x] = UInt8(max(0, min(255, (value * 0.9 + 0.5) * 255)))
            }
        }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: n, height: n, mipmapped: false)
        d.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: d) else { return nil }
        tex.replace(region: MTLRegionMake2D(0, 0, n, n), mipmapLevel: 0, withBytes: pixels, bytesPerRow: n)
        cachedNoise = tex
        return tex
    }
}

private struct OrbUniforms {
    var time: Float = 0, animation: Float = 0, inverted: Float = 0, inputVolume: Float = 0
    var outputVolume: Float = 0.3, opacity: Float = 0, pad0: Float = 0, pad1: Float = 0
    var color1 = SIMD4<Float>(0.79, 0.86, 0.99, 1)
    var color2 = SIMD4<Float>(0.63, 0.73, 0.82, 1)
    var offsets: (Float, Float, Float, Float, Float, Float, Float, Float) = (0, 0, 0, 0, 0, 0, 0, 0)
}

private struct SeededRandom {
    var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func next01() -> Double {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return Double(state % 1_000_000) / 1_000_000
    }
}

private let orbShaderSource = """
#include <metal_stdlib>
using namespace metal;

constant float PI = 3.14159265358979323846;

struct VOut { float4 pos [[position]]; float2 uv; };

vertex VOut orb_vertex(uint vid [[vertex_id]]) {
    float2 p[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
    VOut o; o.pos = float4(p[vid], 0, 1); o.uv = p[vid] * 0.5 + 0.5; return o;
}

struct OrbUniforms {
    float time; float animation; float inverted; float inputVolume;
    float outputVolume; float opacity; float pad0; float pad1;
    float4 color1; float4 color2; float offsets[8];
};

float gmod(float x, float y) { return x - y * floor(x / y); }

bool drawOval(float2 polarUv, float a, float b, bool reverseGradient, float softness, thread float4 &color) {
    float2 p = polarUv;
    float oval = (p.x * p.x) / (a * a) + (p.y * p.y) / (b * b);
    float edge = smoothstep(1.0, 1.0 - softness, oval);
    if (edge > 0.0) {
        float gradient = reverseGradient ? (1.0 - (p.x / a + 1.0) / 2.0) : ((p.x / a + 1.0) / 2.0);
        gradient = mix(0.5, gradient, 0.1);
        color = float4(float3(gradient), 0.85 * edge);
        return true;
    }
    return false;
}

float3 colorRamp(float g, float3 c1, float3 c2, float3 c3, float3 c4) {
    if (g < 0.33) return mix(c1, c2, g * 3.0);
    if (g < 0.66) return mix(c2, c3, (g - 0.33) * 3.0);
    return mix(c3, c4, (g - 0.66) * 3.0);
}

float2 hash2(float2 p) {
    return fract(sin(float2(dot(p, float2(127.1, 311.7)), dot(p, float2(269.5, 183.3)))) * 43758.5453);
}

float noise2D(float2 p) {
    float2 i = floor(p); float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float n = mix(mix(dot(hash2(i), f), dot(hash2(i + float2(1, 0)), f - float2(1, 0)), u.x),
                  mix(dot(hash2(i + float2(0, 1)), f - float2(0, 1)), dot(hash2(i + float2(1, 1)), f - float2(1, 1)), u.x), u.y);
    return 0.5 + 0.5 * n;
}

float sharpRing(float3 d, float time) {
    float n = mix(noise2D(float2(d.x, time) * 5.0), noise2D(float2(d.y, time) * 5.0), d.z);
    n = (n - 0.5) * 2.5;
    return 1.0 + n * 0.3 * 1.5;
}

float smoothRing(float3 d, float time) {
    float n = mix(noise2D(float2(d.x, time) * 6.0), noise2D(float2(d.y, time) * 6.0), d.z);
    n = (n - 0.5) * 5.0;
    return 0.9 + n * 0.2;
}

fragment float4 orb_fragment(VOut in [[stage_in]], constant OrbUniforms &u [[buffer(0)]], texture2d<float> perlin [[texture(0)]]) {
    constexpr sampler smp(address::repeat, filter::linear);
    float2 uv = in.uv * 2.0 - 1.0;
    float radius = length(uv);
    if (radius > 1.0) return float4(0.0);
    float theta = atan2(uv.y, uv.x);
    if (theta < 0.0) theta += 2.0 * PI;

    float3 decomposed = float3(theta / (2.0 * PI), gmod(theta / (2.0 * PI) + 0.5, 1.0) + 1.0, abs(theta / PI - 1.0));

    float ft = radius * 0.03 - u.animation * 0.2;
    float flowN = mix(perlin.sample(smp, float2(ft, decomposed.x / 2.0)).r,
                      perlin.sample(smp, float2(ft, decomposed.y / 2.0)).r, decomposed.z) - 0.5;
    theta += flowN * mix(0.08, 0.25, u.outputVolume);

    float4 color = float4(1.0);
    float originalCenters[7] = { 0.0, 0.5 * PI, 1.0 * PI, 1.5 * PI, 2.0 * PI, 2.5 * PI, 3.0 * PI };
    for (int i = 0; i < 7; i++) {
        float center = originalCenters[i] + 0.5 * sin(u.time / 20.0 + u.offsets[i]);
        float n = perlin.sample(smp, float2(gmod(center + u.time * 0.05, 1.0), 0.5)).r;
        float a = 0.5 + n * 0.3;
        float b = n * mix(3.5, 2.5, u.inputVolume);
        float distTheta = min(abs(theta - center), min(abs(theta + 2.0 * PI - center), abs(theta - 2.0 * PI - center)));
        float4 ovalColor;
        if (drawOval(float2(distTheta, radius), a, b, (i % 2 == 1), 0.6, ovalColor)) {
            color.rgb = mix(color.rgb, ovalColor.rgb, ovalColor.a);
            color.a = max(color.a, ovalColor.a);
        }
    }

    float ring1 = sharpRing(decomposed, u.time * 0.1);
    float ring2 = smoothRing(decomposed, u.time * 0.1);
    float inputRadius1 = radius + u.inputVolume * 0.2;
    float inputRadius2 = radius + u.inputVolume * 0.15;
    float opacity1 = mix(0.2, 0.6, u.inputVolume);
    float opacity2 = mix(0.15, 0.45, u.inputVolume);
    float ringAlpha1 = (inputRadius2 >= ring1) ? opacity1 : 0.0;
    float ringAlpha2 = smoothstep(ring2 - 0.05, ring2 + 0.05, inputRadius1) * opacity2;
    float totalRing = max(ringAlpha1, ringAlpha2);
    color.rgb = 1.0 - (1.0 - color.rgb) * (1.0 - float3(1.0) * totalRing);

    float luminance = mix(color.r, 1.0 - color.r, u.inverted);
    float3 rgb = colorRamp(luminance, float3(0.0), u.color1.rgb, u.color2.rgb, float3(1.0));
    float alpha = color.a * u.opacity * smoothstep(1.0, 0.975, radius);
    return float4(rgb * alpha, alpha);
}
"""

// MARK: - Shimmering text

/// ElevenLabs' ShimmeringText: muted text with a brighter band sweeping left → right (2 s, then a 0.5 s pause).
struct ShimmeringText: View {
    let text: String
    var font: Font = .system(size: 13, weight: .medium)
    var duration: Double = 2
    var repeatDelay: Double = 0.5
    var spread: CGFloat = 2

    var body: some View {
        TimelineView(.animation) { ctx in
            let cycle = duration + repeatDelay
            let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle)
            let p = CGFloat(min(1, t / duration))
            Text(text).font(font).foregroundStyle(.secondary)
                .overlay {
                    GeometryReader { g in
                        let band = max(24, CGFloat(text.count) * spread * 2)
                        LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .primary, location: 0.5), .init(color: .clear, location: 1)],
                                       startPoint: .leading, endPoint: .trailing)
                            .frame(width: band)
                            .offset(x: -band + (g.size.width + band) * p)
                    }
                    .mask(Text(text).font(font))
                }
                .lineLimit(1)
        }
    }
}

// MARK: - Bar visualizer

enum BarState: Equatable { case idle, connecting, listening, thinking, speaking }

/// ElevenLabs' BarVisualizer: rounded bars that sweep while connecting, blink the centre while listening or thinking,
/// and follow the voice while speaking.
struct BarVisualizer: View {
    var state: BarState
    /// Recent levels (0…1); when empty, speaking/listening use the original's demo wave.
    var levels: [Float] = []
    var barCount = 15
    var height: CGFloat = 32
    var barWidth: CGFloat = 4
    var gap: CGFloat = 3

    var body: some View {
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: gap) {
                ForEach(0..<barCount, id: \.self) { i in
                    let lit = highlighted(i, t)
                    Capsule()
                        .fill(state == .speaking || lit ? Color.primary : Color.primary.opacity(0.18))
                        .frame(width: barWidth, height: max(barWidth, height * barHeight(i, t)))
                        .opacity(state == .thinking && lit ? 0.55 + 0.45 * abs(sin(t * .pi / 0.3)) : 1)
                }
            }
            .frame(height: height)
            .animation(.easeOut(duration: 0.15), value: state)
        }
    }

    private func barHeight(_ i: Int, _ t: Double) -> CGFloat {
        guard state == .speaking || state == .listening else { return 0.2 }
        if !levels.isEmpty {
            let idx = Int(Double(i) / Double(barCount) * Double(levels.count))
            let v = levels[min(levels.count - 1, max(0, idx))]
            let shaped = v * Float(0.55 + 0.45 * sin(Double(i) * 0.9 + t * 6))
            return CGFloat(min(1, max(0.2, Double(shaped) * 1.3 + 0.05)))
        }
        let base = sin(t * 2 + Double(i) * 0.5) * 0.3 + 0.5
        let jitter = 0.1 * sin(t * 13 + Double(i) * 2.7)
        return CGFloat(min(1, max(0.1, base + jitter)))
    }

    private func highlighted(_ i: Int, _ t: Double) -> Bool {
        let center = barCount / 2
        switch state {
        case .connecting:
            let step = Int(t / (2.0 / Double(barCount))) % barCount
            return i == step || i == barCount - 1 - step
        case .listening: return Int(t / 0.5) % 2 == 0 && i == center
        case .thinking: return Int(t / 0.15) % 2 == 0 && i == center
        case .speaking, .idle: return false
        }
    }
}

// MARK: - Live waveform

/// ElevenLabs' LiveWaveform (static mode): thin bars of recent levels with faded edges.
struct LiveWaveform: View {
    var levels: [Float]
    var active: Bool
    var barWidth: CGFloat = 3
    var gap: CGFloat = 1

    var body: some View {
        Canvas { ctx, size in
            let step = barWidth + gap
            let count = max(1, Int(size.width / step))
            let data = levels.suffix(count)
            let start = count - data.count
            for (k, v) in data.enumerated() {
                let x = CGFloat(start + k) * step
                let h = max(2, CGFloat(active ? v : 0.05) * size.height * 0.9)
                let rect = CGRect(x: x, y: (size.height - h) / 2, width: barWidth, height: h)
                let edge = min(x, size.width - x) / 24
                ctx.opacity = Double(min(1, edge))
                ctx.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(.primary.opacity(0.7)))
            }
        }
    }
}

// MARK: - Message

enum ChatRole { case user, assistant }

/// ElevenLabs' Message: your words in a filled bubble on the right; the assistant's flat, on the left, with an orb avatar.
struct MessageBubble: View {
    let role: ChatRole
    let text: String
    var orbState: OrbState = .idle

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if role == .user {
                Spacer(minLength: 48)
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.primary.opacity(0.92), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                OrbView(state: orbState, seed: 7, fps: 30)
                    .frame(width: 22, height: 22)
                    .overlay(Circle().strokeBorder(.primary.opacity(0.12), lineWidth: 1))
                Text(text)
                    .font(.system(size: 13.5))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Conversation bar

/// ElevenLabs' ConversationBar: waveform pill · mute · keyboard · end; the keyboard opens a text box with a send arrow.
struct ConversationBar: View {
    var levels: [Float]
    var active: Bool
    var label: String
    @Binding var muted: Bool
    @Binding var text: String
    var onSend: () -> Void
    var onEnd: () -> Void
    @State private var keyboardOpen = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if keyboardOpen {
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Type a message…", text: $text, axis: .vertical)
                        .textFieldStyle(.plain).font(.system(size: 13))
                        .lineLimit(1...4)
                        .focused($focused)
                        .onSubmit(onSend)
                    Button(action: onSend) {
                        Image(systemName: "arrow.up").font(.system(size: 12, weight: .bold))
                            .frame(width: 26, height: 26)
                            .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                            .background(Color.primary.opacity(text.isEmpty ? 0.3 : 0.92), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }
                    .buttonStyle(.plain).disabled(text.isEmpty)
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                Divider().opacity(0.5)
            }
            HStack(spacing: 6) {
                ZStack {
                    LiveWaveform(levels: levels, active: active && !muted)
                        .opacity(active && !muted ? 1 : 0)
                    if !active || muted {
                        Text(muted ? "Muted" : label).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 120, height: 30)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                Spacer()
                iconButton(muted ? "mic.slash" : "mic", on: muted, help: muted ? "Unmute" : "Mute (stop listening while it talks)") { muted.toggle() }
                iconButton("keyboard", on: keyboardOpen, help: "Type instead") {
                    keyboardOpen.toggle()
                    if keyboardOpen { DispatchQueue.main.async { focused = true } }
                }
                Divider().frame(height: 20).padding(.horizontal, 2)
                iconButton("xmark", on: false, help: "End (Esc)", action: onEnd)
            }
            .padding(6)
        }
        .glass(RoundedRectangle(cornerRadius: 12, style: .continuous), interactive: false)
    }

    private func iconButton(_ symbol: String, on: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14, weight: .medium))
                .frame(width: 30, height: 30)
                .background(on ? Color.primary.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).help(help)
    }
}

// MARK: - Voice picker

/// ElevenLabs' VoicePicker: a button with an orb and the voice's name, opening a searchable list with an orb per voice
/// and hover-to-preview.
struct VoicePicker: View {
    let voices: [ElevenLabs.Voice]
    @Binding var selection: String
    var placeholder = "Choose a voice"
    @State private var open = false
    @State private var query = ""
    @State private var hovered: String?
    @State private var playing: String?
    @State private var player: AVPlayer?

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 8) {
                OrbView(state: .thinking, seed: seed(selection), fps: 30).frame(width: 22, height: 22)
                Text(voices.first { $0.id == selection }?.name ?? placeholder).lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(minWidth: 240)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.primary.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .disabled(voices.isEmpty)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search voices…", text: $query).textFieldStyle(.plain)
                }
                .padding(10)
                Divider()
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(filtered) { v in row(v) }
                        if filtered.isEmpty { Text("No voice found.").foregroundStyle(.secondary).padding() }
                    }
                    .padding(6)
                }
            }
            .frame(width: 340, height: 380)
            .onDisappear { player?.pause(); playing = nil }
        }
    }

    private var filtered: [ElevenLabs.Voice] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? voices : voices.filter { ($0.name + " " + $0.detail).lowercased().contains(q) }
    }

    private func row(_ v: ElevenLabs.Voice) -> some View {
        HStack(spacing: 10) {
            ZStack {
                OrbView(state: playing == v.id ? .talking : .thinking, seed: seed(v.id), fps: hovered == v.id || playing == v.id ? 30 : 12)
                    .frame(width: 30, height: 30)
                if v.previewURL != nil, hovered == v.id || playing == v.id {
                    Circle().fill(.black.opacity(0.4)).frame(width: 30, height: 30)
                    Image(systemName: playing == v.id ? "pause.fill" : "play.fill").font(.system(size: 10)).foregroundStyle(.white)
                }
            }
            .onTapGesture { togglePreview(v) }
            VStack(alignment: .leading, spacing: 1) {
                Text(v.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                if !v.detail.isEmpty { Text(v.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer()
            if v.id == selection { Image(systemName: "checkmark").font(.caption.weight(.bold)) }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(hovered == v.id ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovered = $0 ? v.id : (hovered == v.id ? nil : hovered) }
        .onTapGesture { selection = v.id; open = false }
    }

    private func togglePreview(_ v: ElevenLabs.Voice) {
        if playing == v.id { player?.pause(); playing = nil; return }
        guard let url = v.previewURL else { return }
        player?.pause()
        let p = AVPlayer(url: url)
        player = p; playing = v.id
        p.play()
        NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: p.currentItem, queue: .main) { _ in
            if playing == v.id { playing = nil }
        }
    }

    private func seed(_ id: String) -> Int { id.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) } }
}

// MARK: - Helpers

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
    var rgb: SIMD3<Float> {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .white
        return SIMD3(Float(c.redComponent), Float(c.greenComponent), Float(c.blueComponent))
    }
}
