//
// Copyright 2018 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Photos
import SignalServiceKit
import SignalUI

protocol ImagePickerGridControllerDelegate: AnyObject {
    func imagePickerDidComplete(_ imagePicker: ImagePickerGridController)
    func imagePickerDidCancel(_ imagePicker: ImagePickerGridController)

    func imagePicker(_ imagePicker: ImagePickerGridController, didSelectAsset asset: PHAsset, attachmentPromise: Promise<SignalAttachment>)
    func imagePicker(_ imagePicker: ImagePickerGridController, didDeselectAsset asset: PHAsset)

    func imagePickerDidTryToSelectTooMany(_ imagePicker: ImagePickerGridController)
}

protocol ImagePickerGridControllerDataSource: AnyObject {
    func imagePicker(_ imagePicker: ImagePickerGridController, isAssetSelected asset: PHAsset) -> Bool
    func imagePickerCanSelectMoreItems(_ imagePicker: ImagePickerGridController) -> Bool
    var numberOfMediaItems: Int { get }
}

class ImagePickerGridController: UICollectionViewController, PhotoLibraryDelegate, OWSNavigationChildController {

    weak var delegate: ImagePickerGridControllerDelegate?
    weak var dataSource: ImagePickerGridControllerDataSource?

    private let library: PhotoLibrary = PhotoLibrary()
    private var photoAlbum: PhotoAlbum
    private var photoAlbumContents: PhotoAlbumContents
    private let photoMediaSize = PhotoMediaSize()

    private var collectionViewFlowLayout: UICollectionViewFlowLayout
    private lazy var titleView: TitleView = {
        let titleView = TitleView()
        titleView.delegate = self
        titleView.tintColor = .ows_gray05
        titleView.text = photoAlbum.localizedTitle()
        return titleView
    }()

    private lazy var doneButton: MediaDoneButton = {
        let button = MediaDoneButton()
        button.overrideUserInterfaceStyle = .light
        button.addTarget(self, action: #selector(didTapDoneButton), for: .touchUpInside)
        return button
    }()

    init() {
        collectionViewFlowLayout = type(of: self).buildLayout()
        photoAlbum = library.defaultPhotoAlbum()
        photoAlbumContents = photoAlbum.contents()

        super.init(collectionViewLayout: collectionViewFlowLayout)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - View Lifecycle

    override var prefersStatusBarHidden: Bool {
        !UIDevice.current.hasIPhoneXNotch && !UIDevice.current.isIPad && AppEnvironment.shared.callService.callServiceState.currentCall == nil
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .lightContent }

    var preferredNavigationBarStyle: OWSNavigationBarStyle { .alwaysDark }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = Theme.darkThemeBackgroundColor

        library.add(delegate: self)

        collectionView.allowsMultipleSelection = true
        collectionView.backgroundColor = Theme.darkThemeBackgroundColor
        collectionView.register(PhotoGridViewCell.self, forCellWithReuseIdentifier: PhotoGridViewCell.reuseIdentifier)

        navigationItem.titleView = titleView

        let cancelButton: UIBarButtonItem = .cancelButton { [weak self] in
            guard let self else { return }
            self.delegate?.imagePickerDidCancel(self)
        }
        cancelButton.tintColor = Theme.darkThemePrimaryColor
        navigationItem.leftBarButtonItem = cancelButton

        view.addSubview(doneButton)
        doneButton.autoPinBottomToSuperviewMargin(withInset: UIDevice.current.hasIPhoneXNotch ? 8 : 16)
        doneButton.autoPinTrailingToSuperviewMargin()

        let selectionPanGesture = DirectionalPanGestureRecognizer(direction: [.horizontal], target: self, action: #selector(didPanSelection))
        selectionPanGesture.delegate = self
        self.selectionPanGesture = selectionPanGesture
        collectionView.addGestureRecognizer(selectionPanGesture)
    }

    private var selectionPanGesture: UIPanGestureRecognizer?
    private enum BatchSelectionGestureMode {
        case select, deselect
    }
    private var selectionPanGestureMode: BatchSelectionGestureMode = .select

    @objc
    private func didPanSelection(_ selectionPanGesture: UIPanGestureRecognizer) {
        guard let collectionView = collectionView else {
            owsFailDebug("collectionView was unexpectedly nil")
            return
        }

        guard let dataSource = dataSource else {
            owsFailDebug("dataSource was unexpectedly nil")
            return
        }

        switch selectionPanGesture.state {
        case .possible:
            break

        case .began:
            collectionView.isUserInteractionEnabled = false
            collectionView.isScrollEnabled = false

            let location = selectionPanGesture.location(in: collectionView)
            guard let indexPath = collectionView.indexPathForItem(at: location) else {
                return
            }
            let asset = photoAlbumContents.asset(at: indexPath.item)
            if dataSource.imagePicker(self, isAssetSelected: asset) {
                selectionPanGestureMode = .deselect
            } else {
                selectionPanGestureMode = .select
            }

        case .changed:
            let velocity = selectionPanGesture.velocity(in: view)

            // Bulk selection is a horizontal pan, while scrolling content is a vertical pan.
            // There will be some ambiguity since users gestures are not perfectly cardinal.
            //
            // We try to account for that here.
            //
            // If the `alpha` is too low, the user will inadvertently select items while trying to scroll.
            // If the `alpha` is too high, the user will not be able to easily horizontally select items.
            let alpha: CGFloat = 4.0
            let isDecidedlyHorizontal = abs(velocity.x) > abs(velocity.y) * alpha
            guard isDecidedlyHorizontal else {
                return
            }
            let location = selectionPanGesture.location(in: collectionView)
            guard let indexPath = collectionView.indexPathForItem(at: location) else {
                return
            }
            tryToToggleBatchSelect(at: indexPath)

        case .cancelled, .ended, .failed:
            collectionView.isUserInteractionEnabled = true
            collectionView.isScrollEnabled = true

        @unknown default:
            owsFailDebug("unexpected selectionPanGesture.state: \(selectionPanGesture.state)")
        }
    }

    private func tryToToggleBatchSelect(at indexPath: IndexPath) {
        guard let collectionView = collectionView else {
            owsFailDebug("collectionView was unexpectedly nil")
            return
        }

        guard let delegate = delegate, let dataSource = dataSource else {
            owsFailDebug("delegate or dataSource was unexpectedly nil")
            return
        }

        let asset = photoAlbumContents.asset(at: indexPath.item)
        switch selectionPanGestureMode {
        case .select:
            guard !isSelected(indexPath: indexPath) else {
                return
            }

            guard dataSource.imagePickerCanSelectMoreItems(self) else {
                delegate.imagePickerDidTryToSelectTooMany(self)
                return
            }

            let attachmentPromise: Promise<SignalAttachment> = photoAlbumContents.outgoingAttachment(for: asset)
            delegate.imagePicker(self, didSelectAsset: asset, attachmentPromise: attachmentPromise)
            collectionView.selectItem(at: indexPath, animated: true, scrollPosition: [])
            updateDoneButtonAppearance()

        case .deselect:
            guard isSelected(indexPath: indexPath) else {
                return
            }

            delegate.imagePicker(self, didDeselectAsset: asset)
            collectionView.deselectItem(at: indexPath, animated: true)
            updateDoneButtonAppearance()
        }
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        updateLayout()
    }

    private var hasEverAppeared: Bool = false
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        // Determine the size of the thumbnails to request
        let scale = UIScreen.main.scale
        let cellSize: CGSize
        if hasEverAppeared {
            cellSize = collectionViewFlowLayout.itemSize
        } else {
            cellSize = getLayout().itemSize
        }
        photoMediaSize.thumbnailSize = CGSize(width: cellSize.width * scale, height: cellSize.height * scale)

        reloadData()
        if !hasEverAppeared {
            scrollToBottom(animated: false)
        }

        updateDoneButtonAppearance()
    }

    override func viewSafeAreaInsetsDidChange() {
        if !hasEverAppeared {
            // To scroll precisely to the bottom of the content, we have to account for the space
            // taken up by the navbar and any notch.
            //
            // Before iOS11 the system accounts for this by assigning contentInset to the scrollView
            // which is available by the time `viewWillAppear` is called.
            //
            // On iOS11+, contentInsets are not assigned to the scrollView in `viewWillAppear`, but
            // this method, `viewSafeAreaInsetsDidChange` is called *between* `viewWillAppear` and
            // `viewDidAppear` and indicates `safeAreaInsets` have been assigned.
            scrollToBottom(animated: false)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)

        hasEverAppeared = true

        DispatchQueue.main.async {
            // pre-layout collectionPicker for snappier response
            self.collectionPickerController.view.layoutIfNeeded()
        }
    }

    private func updateDoneButtonAppearance() {
        guard let dataSource = dataSource else { return }

        doneButton.badgeNumber = dataSource.numberOfMediaItems
        doneButton.isHidden = doneButton.badgeNumber == 0
    }

    // MARK: - Scrolling

    private var lastPageYOffset: CGFloat {
        let yOffset = collectionView.contentSize.height - collectionView.frame.height + collectionView.contentInset.bottom + view.safeAreaInsets.bottom
        return yOffset
    }

    private func scrollToBottom(animated: Bool) {
        self.view.layoutIfNeeded()

        guard let collectionView = collectionView else {
            owsFailDebug("collectionView was unexpectedly nil")
            return
        }

        let yOffset = lastPageYOffset
        guard yOffset > 0 else {
            // less than 1 page of content. Do not offset.
            return
        }

        collectionView.setContentOffset(CGPoint(x: 0, y: yOffset), animated: animated)
    }

    override func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if !hasEverAppeared, collectionView.contentOffset.y != lastPageYOffset {
            // We initially want the user to be scrolled to the bottom of the media library content.
            // However, at least on iOS12, we were finding that when the view finally presented,
            // the content was not *quite* to the bottom (~20px above it).
            //
            // Debugging shows that initially we have the correct offset, but that *something* is
            // causing the content to adjust *after* viewWillAppear and viewSafeAreaInsetsDidChange.
            // Because that something results in `scrollViewDidScroll` we re-adjust the content
            // insets to the bottom.
            Logger.debug("adjusting scroll offset back to bottom")
            scrollToBottom(animated: false)
        }
    }

    private func reloadData() {
        guard let collectionView = collectionView else {
            owsFailDebug("Missing collectionView.")
            return
        }

        collectionView.reloadData()
        collectionView.layoutIfNeeded()
    }

    // MARK: - Actions

    @objc
    private func didTapDoneButton() {
        delegate?.imagePickerDidComplete(self)
    }

    // MARK: - Layout

    private static let kInterItemSpacing: CGFloat = 2
    private class func buildLayout() -> UICollectionViewFlowLayout {
        let layout = UICollectionViewFlowLayout()

        layout.sectionInsetReference = .fromSafeArea
        layout.minimumInteritemSpacing = kInterItemSpacing
        layout.minimumLineSpacing = kInterItemSpacing
        layout.sectionHeadersPinToVisibleBounds = true

        return layout
    }

    private typealias CellLayout = (itemSize: CGSize, remainingSpace: CGFloat)

    private func getLayout() -> CellLayout {
        let containerWidth = self.view.safeAreaLayoutGuide.layoutFrame.size.width

        let minItemWidth: CGFloat = 100
        let itemCount = floor(containerWidth / minItemWidth)
        let interSpaceWidth = (itemCount - 1) * type(of: self).kInterItemSpacing

        let availableWidth = max(0, containerWidth - interSpaceWidth)

        let itemWidth = floor(availableWidth / CGFloat(itemCount))
        let itemSize = CGSize(square: itemWidth)
        let remainingSpace = availableWidth - (itemCount * itemWidth)

        return (itemSize, remainingSpace)
    }

    private func updateLayout() {
        let (newItemSize, remainingSpace) = getLayout()
        if newItemSize != collectionViewFlowLayout.itemSize {
            collectionViewFlowLayout.itemSize = newItemSize
            // Inset any remaining space around the outside edges to ensure all inter-item spacing is exactly equal, otherwise
            // we may get slightly different gaps between rows vs. columns
            collectionViewFlowLayout.sectionInset = UIEdgeInsets(top: 0, leading: remainingSpace / 2, bottom: 0, trailing: remainingSpace / 2)
            collectionViewFlowLayout.invalidateLayout()
        }
    }

    // MARK: - Batch Selection

    private func isSelected(indexPath: IndexPath) -> Bool {
        guard let selectedIndexPaths = collectionView.indexPathsForSelectedItems else {
            return false
        }

        return selectedIndexPaths.contains(indexPath)
    }

    // MARK: - PhotoLibraryDelegate

    func photoLibraryDidChange(_ photoLibrary: PhotoLibrary) {
        photoAlbumContents = photoAlbum.contents()
        reloadData()
    }

    // MARK: - PhotoCollectionPicker Presentation

    private var isShowingCollectionPickerController: Bool = false

    private lazy var collectionPickerController: UINavigationController = {
        let viewController = PhotoAlbumPickerViewController(library: library, collectionDelegate: self)
        let navigationController = UINavigationController(rootViewController: viewController)
        navigationController.isNavigationBarHidden = true
        return navigationController
    }()

    private func showCollectionPicker() {
        guard let collectionPickerView = collectionPickerController.view else {
            owsFailDebug("collectionView was unexpectedly nil")
            return
        }

        assert(!isShowingCollectionPickerController)
        isShowingCollectionPickerController = true
        addChild(collectionPickerController)

        view.addSubview(collectionPickerView)
        collectionPickerView.autoPinEdgesToSuperviewEdges(with: .zero, excludingEdge: .top)
        collectionPickerView.autoPinEdge(toSuperviewSafeArea: .top)
        collectionPickerView.layoutIfNeeded()

        // Initially position offscreen, we'll animate it in.
        collectionPickerView.frame = collectionPickerView.frame.offsetBy(dx: 0, dy: collectionPickerView.frame.height)

        UIView.animate(withDuration: 0.25, delay: 0, options: .curveEaseInOut) {
            collectionPickerView.superview?.layoutIfNeeded()
            self.titleView.rotateIcon(.up)
        }
    }

    private func hideCollectionPicker() {
        assert(isShowingCollectionPickerController)
        isShowingCollectionPickerController = false

        UIView.animate(withDuration: 0.25, delay: 0, options: .curveEaseInOut) { [self] in
            collectionPickerController.view.frame = collectionPickerController.view.frame.offsetBy(
                dx: 0,
                dy: collectionPickerController.view.height
            )
            titleView.rotateIcon(.down)
        } completion: { [self] _ in
            collectionPickerController.popToRootViewController(animated: false)
            collectionPickerController.view.removeFromSuperview()
            collectionPickerController.removeFromParent()
        }
    }

    // MARK: - UICollectionView

    override func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        guard let delegate = delegate, let dataSource = dataSource else { return false }

        if dataSource.imagePickerCanSelectMoreItems(self) {
            return true
        }

        delegate.imagePickerDidTryToSelectTooMany(self)
        return false
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let delegate = delegate else {
            owsFailDebug("delegate was unexpectedly nil")
            return
        }

        let asset: PHAsset = photoAlbumContents.asset(at: indexPath.item)
        let attachmentPromise: Promise<SignalAttachment> = photoAlbumContents.outgoingAttachment(for: asset)
        delegate.imagePicker(self, didSelectAsset: asset, attachmentPromise: attachmentPromise)
        updateDoneButtonAppearance()
    }

    override func collectionView(_ collectionView: UICollectionView, didDeselectItemAt indexPath: IndexPath) {
        guard let delegate = delegate else {
            owsFailDebug("delegate was unexpectedly nil")
            return
        }

        let asset = photoAlbumContents.asset(at: indexPath.item)
        delegate.imagePicker(self, didDeselectAsset: asset)
        updateDoneButtonAppearance()
    }

    override func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return photoAlbumContents.assetCount
    }

    override func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        guard let cell = collectionView.dequeueReusableCell(withReuseIdentifier: PhotoGridViewCell.reuseIdentifier, for: indexPath) as? PhotoGridViewCell else {
            owsFail("cell was unexpectedly nil")
        }

        cell.loadingColor = UIColor(white: 0.2, alpha: 1)
        let assetItem = photoAlbumContents.assetItem(at: indexPath.item, photoMediaSize: photoMediaSize)
        cell.configure(item: assetItem)
        return cell
    }

    override func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard let dataSource = dataSource else { return }
        guard let photoGridViewCell = cell as? PhotoGridViewCell else {
            owsFailDebug("unexpected cell: \(cell)")
            return
        }
        let assetItem = photoAlbumContents.assetItem(at: indexPath.item, photoMediaSize: photoMediaSize)
        let isSelected = dataSource.imagePicker(self, isAssetSelected: assetItem.asset)
        if isSelected {
            collectionView.selectItem(at: indexPath, animated: false, scrollPosition: [])
        } else {
            collectionView.deselectItem(at: indexPath, animated: false)
        }
        photoGridViewCell.isSelected = isSelected
        photoGridViewCell.allowsMultipleSelection = collectionView.allowsMultipleSelection
    }

    private func updateVisibleCells() {
        guard let dataSource = dataSource else { return }

        for cell in collectionView.visibleCells {
            guard let photoGridViewCell = cell as? PhotoGridViewCell else {
                owsFailDebug("unexpected cell: \(cell)")
                continue
            }

            guard let assetItem = photoGridViewCell.photoGridItem as? PhotoPickerAssetItem else {
                owsFailDebug("unexpected photoGridViewCell.item: \(String(describing: photoGridViewCell.photoGridItem))")
                continue
            }

            photoGridViewCell.isSelected = dataSource.imagePicker(self, isAssetSelected: assetItem.asset)
            photoGridViewCell.allowsMultipleSelection = collectionView.allowsMultipleSelection
        }
    }
}

extension ImagePickerGridController: PhotoAlbumPickerDelegate {

    func photoAlbumPicker(_ picker: PhotoAlbumPickerViewController, didSelectAlbum album: PhotoAlbum) {
        guard photoAlbum != album else {
            hideCollectionPicker()
            return
        }

        photoAlbum = album
        photoAlbumContents = photoAlbum.contents()

        // Any selections are invalid as they refer to indices in a different collection
        reloadData()

        titleView.text = photoAlbum.localizedTitle()

        scrollToBottom(animated: false)
        hideCollectionPicker()
    }
}

extension ImagePickerGridController: UIGestureRecognizerDelegate {

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer == selectionPanGesture else {
            return true
        }

        return ![.changed, .began].contains(collectionView.panGestureRecognizer.state)
    }
}

private protocol TitleViewDelegate: AnyObject {
    func titleViewWasTapped(_ titleView: TitleView)
}

private class TitleView: UIView {

    private let label = UILabel()
    private let iconView = UIImageView()
    private let stackView: UIStackView

    // Returns same font as UIBarButtonItem uses.
    private func titleLabelFont() -> UIFont {
        let fontDescriptor = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .body)
        return UIFont(descriptor: fontDescriptor, size: fontDescriptor.pointSize.clamp(17, 21))
    }

    // MARK: - Initializers

    override init(frame: CGRect) {
        stackView = UIStackView(arrangedSubviews: [label, iconView])

        super.init(frame: frame)

        stackView.axis = .horizontal
        stackView.alignment = .center
        stackView.spacing = 5
        stackView.isUserInteractionEnabled = true
        addSubview(stackView)
        stackView.autoPinEdgesToSuperviewEdges()

        label.textColor = tintColor
        label.font = titleLabelFont()

        iconView.tintColor = tintColor
        iconView.image = UIImage(systemName: "chevron.down", withConfiguration: UIImage.SymbolConfiguration(font: label.font))

        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(titleTapped)))
    }

    @available(*, unavailable, message: "Use init(frame:) instead")
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        label.textColor = tintColor
        iconView.tintColor = tintColor
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.preferredContentSizeCategory != previousTraitCollection?.preferredContentSizeCategory {
            label.font = titleLabelFont()
            iconView.image = UIImage(systemName: "chevron.down", withConfiguration: UIImage.SymbolConfiguration(font: label.font))
        }
    }

    // MARK: - Public

    weak var delegate: TitleViewDelegate?

    var text: String? {
        get {
            return label.text
        }
        set {
            label.text = newValue
        }
    }

    enum TitleViewRotationDirection {
        case up, down
    }

    func rotateIcon(_ direction: TitleViewRotationDirection) {
        switch direction {
        case .up:
            // *slightly* more than `pi` to ensure the chevron animates counter-clockwise
            let chevronRotationAngle = CGFloat.pi + 0.001
            iconView.transform = CGAffineTransform(rotationAngle: chevronRotationAngle)
        case .down:
            iconView.transform = .identity
        }
    }

    // MARK: - Events

    @objc
    private func titleTapped(_ tapGesture: UITapGestureRecognizer) {
        self.delegate?.titleViewWasTapped(self)
    }
}

extension ImagePickerGridController: TitleViewDelegate {
    fileprivate func titleViewWasTapped(_ titleView: TitleView) {
        if isShowingCollectionPickerController {
            hideCollectionPicker()
        } else {
            showCollectionPicker()
        }
    }
}
