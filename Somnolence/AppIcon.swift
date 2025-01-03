import SwiftUI

struct AppIcon: View {
    var body: some View {
        ZStack {
            // Background gradient
            LinearGradient(
                gradient: Gradient(colors: [
                    Color(red: 0.2, green: 0.3, blue: 0.8),  // Deep blue
                    Color(red: 0.4, green: 0.2, blue: 0.8)   // Purple
                ]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            
            // Alarm clock body
            Circle()
                .fill(Color.white)
                .frame(width: 180, height: 180)
                .shadow(color: .black.opacity(0.2), radius: 10, x: 0, y: 5)
            
            // Clock face details
            ZStack {
                // Hour marks
                ForEach(0..<12) { hour in
                    Rectangle()
                        .fill(Color.black)
                        .frame(width: hour % 3 == 0 ? 4 : 2, height: hour % 3 == 0 ? 15 : 10)
                        .offset(y: -75)
                        .rotationEffect(.degrees(Double(hour) * 30))
                }
                
                // Clock hands
                Path { path in
                    path.move(to: CGPoint(x: 0, y: 10))
                    path.addLine(to: CGPoint(x: 0, y: -50))  // Hour hand
                }
                .stroke(Color.black, lineWidth: 4)
                .rotationEffect(.degrees(45))
                
                Path { path in
                    path.move(to: CGPoint(x: 0, y: 10))
                    path.addLine(to: CGPoint(x: 0, y: -70))  // Minute hand
                }
                .stroke(Color.black, lineWidth: 3)
                .rotationEffect(.degrees(-60))
                
                // Center dot
                Circle()
                    .fill(Color.black)
                    .frame(width: 12, height: 12)
                
                // Alarm bells
                HStack(spacing: 130) {
                    Circle()
                        .fill(Color(red: 0.8, green: 0.2, blue: 0.2))  // Red
                        .frame(width: 30, height: 30)
                    Circle()
                        .fill(Color(red: 0.8, green: 0.2, blue: 0.2))  // Red
                        .frame(width: 30, height: 30)
                }
                .offset(y: -100)
            }
            
            // Zzz text
            Text("Z")
                .font(.system(size: 60, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .shadow(color: .black.opacity(0.3), radius: 5, x: 2, y: 2)
                .rotationEffect(.degrees(15))
                .offset(x: 50, y: -60)
            
            Text("z")
                .font(.system(size: 45, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .shadow(color: .black.opacity(0.3), radius: 5, x: 2, y: 2)
                .rotationEffect(.degrees(15))
                .offset(x: 80, y: -40)
            
            Text("z")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .shadow(color: .black.opacity(0.3), radius: 5, x: 2, y: 2)
                .rotationEffect(.degrees(15))
                .offset(x: 100, y: -20)
        }
        .frame(width: 1024, height: 1024)  // App Store size
        .clipShape(RoundedRectangle(cornerRadius: 180))
    }
}

#Preview("iPad Pro Icon (167x167)", traits: .sizeThatFitsLayout) {
    VStack(spacing: 20) {
        // iPad Pro icon size (167x167)
        AppIcon()
            .frame(width: 167, height: 167)
    }
    .padding()
} 