import UIKit

extension UIImage {
    // ужать так, чтобы большая сторона была не больше maxDimension (в ПИКСЕЛЯХ).
    // Важно: scale=1, иначе UIGraphicsImageRenderer берёт scale экрана (2x/3x)
    // и 1024pt превращаются в 2048/3072 реальных пикселей.
    func resized(maxDimension: CGFloat) -> UIImage {
        let scale = min(maxDimension / size.width, maxDimension / size.height, 1)
        let newSize = CGSize(width: (size.width * scale).rounded(),
                             height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1                         // 1 пункт = 1 пиксель
        format.opaque = true                     // аватар без альфы → меньше вес
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    // JPEG не больше заданного бюджета: при необходимости снижаем качество,
    // а если и на минимальном качестве не лезет — дополнительно ужимаем размер.
    func jpegData(maxDimension: CGFloat, maxBytes: Int) -> Data? {
        var image = resized(maxDimension: maxDimension)
        var dimension = maxDimension
        for _ in 0..<4 {
            for quality in stride(from: 0.8, through: 0.4, by: -0.1) {
                guard let data = image.jpegData(compressionQuality: quality) else { return nil }
                if data.count <= maxBytes { return data }
            }
            // всё ещё велико — режем размер на 25% и пробуем заново
            dimension *= 0.75
            image = resized(maxDimension: dimension)
        }
        return image.jpegData(compressionQuality: 0.4)
    }
}
