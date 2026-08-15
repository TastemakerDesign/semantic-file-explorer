import SwiftUI

enum AppFont {
    static let title = Font.system(size: 17, weight: .semibold)
    static let body = Font.system(size: 15)
    static let detail = Font.system(size: 14)
    static let caption = Font.system(size: 13)
}

extension ShapeStyle where Self == Color {
    static var supporting: Color { Color.primary.opacity(0.8) }
}
