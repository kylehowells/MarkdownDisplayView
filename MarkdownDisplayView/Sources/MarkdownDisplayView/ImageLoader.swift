//
//  ImageLoader.swift
//  CallUIKit
//
//  Created by 朱继超 on 2023/9/1.
//

import Foundation
import UIKit
import Combine
import Kingfisher

/**
 private var cancellables = Set<AnyCancellable>()
 let imageURL = URL(string: "https://example.com/image.jpg")!
 
 ImageLoader.shared.loadImage(from: imageURL)
     .sink(receiveValue: { [weak self] image in
         self?.imageView.image = image
     })
     .store(in: &cancellables)
 */

/// An Image loader
public struct ImageLoader {
    public static let shared = ImageLoader()
    
    /// Load image from url.
    /// - Parameter url: image url
    /// - Returns: An
    /// - How to user? See above the ImageLoader.
    public func loadImage(from url: URL) -> AnyPublisher<UIImage?, Never> {
        Deferred {
            let subject = PassthroughSubject<UIImage?, Never>()
            var downloadTask: DownloadTask?
            var hasStarted = false

            return subject
                .handleEvents(
                    receiveCancel: {
                        downloadTask?.cancel()
                    },
                    receiveRequest: { _ in
                        guard !hasStarted else { return }
                        hasStarted = true
                        downloadTask = KingfisherManager.shared.retrieveImage(with: url) { result in
                            let image = try? result.get().image
                            subject.send(image ?? UIImage())
                            subject.send(completion: .finished)
                        }
                    }
                )
                .eraseToAnyPublisher()
        }
        .receive(on: DispatchQueue.main)
        .eraseToAnyPublisher()
    }
}
