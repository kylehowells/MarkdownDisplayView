import Combine
import UIKit

/// Supplies images for Markdown sources that need application-specific loading.
///
/// Return `nil` when the source is not handled so MarkdownDisplayView can use its
/// built-in HTTP(S) loader. Publishers must deliver at most one image and finish.
@available(iOS 15.0, *)
public protocol MarkdownImageLoading: AnyObject {
    func loadMarkdownImage(from source: String) -> AnyPublisher<UIImage?, Never>?
}

@available(iOS 15.0, *)
extension MarkdownViewTextKit {
    func imagePublisher(for source: String) -> AnyPublisher<UIImage?, Never> {
        if let publisher = imageLoader?.loadMarkdownImage(from: source) {
            return publisher
                .receive(on: DispatchQueue.main)
                .eraseToAnyPublisher()
        }

        guard let url = ImageView.normalizedImageURL(from: source) else {
            return Just(nil).eraseToAnyPublisher()
        }

        return ImageLoader.shared.loadImage(from: url)
    }
}
