import UIKit

class StickersCollectionViewController: UIViewController, ConversationAccessible {
    
    let cellReuseId = "StickerCell"
    
    var index = NSNotFound
    
    var layoutClass: TilingCollectionViewFlowLayout.Type {
        return TilingCollectionViewFlowLayout.self
    }
    
    var collectionView: UICollectionView {
        return view as! UICollectionView
    }
    
    var updateUsedAtAfterSent: Bool {
        return true
    }
    
    var isEmpty: Bool {
        return true
    }
    
    var animated: Bool = false {
        didSet {
            for case let cell as AnimatedImageCollectionViewCell in collectionView.visibleCells {
                cell.imageView.autoPlayAnimatedImage = animated
                if animated {
                    cell.imageView.startAnimating()
                } else {
                    cell.imageView.stopAnimating()
                }
            }
        }
    }
    
    override func loadView() {
        let frame = CGRect(x: 0, y: 0, width: 375, height: 200)
        let layout = layoutClass.init(numberOfItemsPerRow: StickerInputModelController.numberOfItemsPerRow, spacing: 8)
        let view = UICollectionView(frame: frame, collectionViewLayout: layout)
        self.view = view
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.showsHorizontalScrollIndicator = false
        collectionView.showsVerticalScrollIndicator = false
        collectionView.backgroundColor = .white
        collectionView.alwaysBounceVertical = true
        collectionView.register(AnimatedImageCollectionViewCell.self, forCellWithReuseIdentifier: cellReuseId)
        collectionView.dataSource = self
        collectionView.delegate = self
    }
    
}

extension StickersCollectionViewController: UICollectionViewDataSource {
    
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return 0
    }
    
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        fatalError()
    }
    
}

extension StickersCollectionViewController: UICollectionViewDelegate {
    
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        
    }
    
    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard let cell = cell as? AnimatedImageCollectionViewCell else {
            return
        }
        if animated {
            cell.imageView.autoPlayAnimatedImage = true
            cell.imageView.startAnimating()
        }
    }
    
    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard let cell = cell as? AnimatedImageCollectionViewCell else {
            return
        }
        cell.imageView.autoPlayAnimatedImage = false
        cell.imageView.stopAnimating()
    }
    
}
