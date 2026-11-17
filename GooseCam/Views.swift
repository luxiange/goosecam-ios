import SwiftUI
import CoreMotion

/// 陀螺仪 roll 角提供者（水平仪数据源）。
final class MotionRoll: ObservableObject {
    private let manager = CMMotionManager()
    @Published var roll: Double = 0

    func start() {
        guard manager.isDeviceMotionAvailable else { return }
        manager.deviceMotionUpdateInterval = 0.1
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let self, let motion else { return }
            self.roll = motion.attitude.roll
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
    }
}

/// 水平仪：竖持手机时 roll≈0，线变黄提示已水平。
struct LevelView: View {
    @ObservedObject var motion: MotionRoll

    private var isLevel: Bool { abs(motion.roll) < 0.015 }

    var body: some View {
        ZStack {
            Capsule()
                .fill(Color.white.opacity(0.22))
                .frame(width: 150, height: 1.5)
            Capsule()
                .fill(isLevel ? Color(red: 1.0, green: 0.82, blue: 0.29) : Color.white.opacity(0.85))
                .frame(width: 46, height: 3)
        }
        .frame(width: 240, height: 24)
        .rotationEffect(Angle(radians: -motion.roll))
        .animation(.easeOut(duration: 0.12), value: motion.roll)
        .allowsHitTesting(false)
    }
}

/// 三分线网格
struct GridLinesView: View {
    var body: some View {
        GeometryReader { geo in
            Path { path in
                let w = geo.size.width
                let h = geo.size.height
                for i in 1...2 {
                    let x = w * CGFloat(i) / 3.0
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: h))
                    let y = h * CGFloat(i) / 3.0
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: w, y: y))
                }
            }
            .stroke(Color.white.opacity(0.22), lineWidth: 0.7)
        }
        .allowsHitTesting(false)
    }
}

/// 对焦框
struct FocusBox: View {
    var color: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .stroke(color, lineWidth: 1.2)
            .frame(width: 56, height: 56)
            .allowsHitTesting(false)
    }
}
