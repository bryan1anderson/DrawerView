//
//  DrawerView.swift
//  DrawerView
//
//  Created by Mikko Välimäki on 28/10/2017.
//  Copyright © 2017 Mikko Välimäki. All rights reserved.
//

import UIKit

@objc public enum DrawerPosition: Int {
    case open = 1
    case partiallyOpen = 2
    case collapsed = 3
}

private extension DrawerPosition {
    static let positions: [DrawerPosition] = [
        .open,
        .partiallyOpen,
        .collapsed
    ]

    var visibleName: String {
        switch self {
        case .open: return "open"
        case .partiallyOpen: return "partiallyOpen"
        case .collapsed: return "collapsed"
        }
    }
}

let kVelocityTreshold: CGFloat = 0

let kVerticalLeeway: CGFloat = 100.0

let defaultBackgroundEffect = UIBlurEffect(style: .extraLight)

@objc public protocol DrawerViewDelegate {

    @objc optional func canScrollContent(drawerView: DrawerView) -> Bool

    @objc optional func drawer(_ drawerView: DrawerView, willTransitionFrom position: DrawerPosition)

    @objc optional func drawer(_ drawerView: DrawerView, didTransitionTo position: DrawerPosition)

    @objc optional func drawerDidMove(_ drawerView: DrawerView, verticalPosition: CGFloat)
}

public class DrawerView: UIView {

    // MARK: - Private properties

    private var panGesture: UIPanGestureRecognizer! = nil

    private var panOrigin: CGFloat = 0.0

    private var isDragging: Bool = false

    private var animator: UIViewPropertyAnimator? = nil

    private var currentPosition: DrawerPosition = .collapsed

    private var topConstraint: NSLayoutConstraint? = nil

    private var heightConstraint: NSLayoutConstraint? = nil

    private var childScrollView: UIScrollView? = nil

    private var childScrollWasEnabled: Bool = true

    private var otherGestureRecognizer: UIGestureRecognizer? = nil

    private var overlay: UIView?

    private let border = CALayer()

    // MARK: - Public properties

    @IBOutlet
    public var delegate: DrawerViewDelegate?

    // IB support, not intended to be used otherwise.
    @IBOutlet
    public var containerView: UIView? {
        willSet {
            if self.superview != nil {
                abort(reason: "Superview already set, use normal UIView methods to set up the view hierarcy")
            }
        }
        didSet {
            if let containerView = containerView {
                self.attachTo(view: containerView)
            }
        }
    }

    public func attachTo(view: UIView) {

        self.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(self)

        topConstraint = self.topAnchor.constraint(equalTo: view.topAnchor, constant: self.topMargin)
        heightConstraint = self.heightAnchor.constraint(equalTo: view.heightAnchor, constant: -self.topMargin)

        let constraints = [
            self.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            self.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topConstraint,
            heightConstraint
        ];

        for constraint in constraints {
            constraint?.isActive = true
        }
    }

    public let backgroundView = UIVisualEffectView(effect: defaultBackgroundEffect)

    // TODO: Use size classes with the positions.

    public var topMargin: CGFloat = 68.0 {
        didSet {
            self.updateSnapPosition(animated: false)
        }
    }

    public var collapsedHeight: CGFloat = 68.0 {
        didSet {
            self.updateSnapPosition(animated: false)
        }
    }

    public var partiallyOpenHeight: CGFloat = 264.0 {
        didSet {
            self.updateSnapPosition(animated: false)
        }
    }

    public var position: DrawerPosition {
        get {
            return currentPosition
        }
        set {
            self.setPosition(newValue, animated: false)
        }
    }

    public var supportedPositions: [DrawerPosition] = DrawerPosition.positions {
        didSet {
            if !supportedPositions.contains(self.position) {
                // Current position is not in the given list, default to the most closed one.
                self.setInitialPosition()
            }
        }
    }

    // MARK: - Initialization

    override init(frame: CGRect) {
        super.init(frame: frame)
        self.setup()
    }

    required public init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        self.setup()
    }

    private func setup() {
        panGesture = UIPanGestureRecognizer(target: self, action: #selector(onPan))
        panGesture.maximumNumberOfTouches = 2
        panGesture.minimumNumberOfTouches = 1
        panGesture.delegate = self
        self.addGestureRecognizer(panGesture)

        // Using a setup similar to Maps.app.
        self.layer.cornerRadius = 10
        self.layer.shadowRadius = 5
        self.layer.shadowOpacity = 0.1

        self.translatesAutoresizingMaskIntoConstraints = false

        setupBorder()
        addBlurEffect()
    }

    func setupBorder() {
        border.cornerRadius = self.layer.cornerRadius
        border.frame = self.bounds.insetBy(dx: -0.5, dy: -0.5)
        border.borderColor = UIColor(white: 0.2, alpha: 0.2).cgColor
        border.borderWidth = 0.5
        self.layer.addSublayer(border)
    }

    func addBlurEffect() {
        backgroundView.frame = self.bounds
        backgroundView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        backgroundView.translatesAutoresizingMaskIntoConstraints = true
        backgroundView.layer.cornerRadius = 8
        backgroundView.clipsToBounds = true

        self.insertSubview(backgroundView, at: 0)
        self.backgroundColor = UIColor.clear
    }

    // MARK: - View methods

    public override func willMove(toSuperview newSuperview: UIView?) {
        if let view = newSuperview {
            self.frame = view.bounds.insetBy(top: topMargin)
        }
    }

    public override func didMoveToSuperview() {
        self.setPosition(currentPosition, animated: false)
    }

    public override func layoutSubviews() {
        // Update snap position, if not dragging.
        let animatorRunning = animator?.isRunning ?? false
        if !animatorRunning && !isDragging {
            // Handle possible layout changes, e.g. rotation.
            self.updateSnapPosition(animated: false)
        }
    }

    public override func layoutSublayers(of layer: CALayer) {
        super.layoutSublayers(of: layer)
        if layer == self.layer {
            border.frame = self.bounds.insetBy(dx: -0.5, dy: -0.5)
        }
    }

    // MARK: - Public methods

    public func setPosition(_ position: DrawerPosition, animated: Bool) {
        self.setPosition(position, withVelocity: CGPoint(), animated: animated)
    }

    public func setPosition(_ position: DrawerPosition, withVelocity velocity: CGPoint, animated: Bool) {

        currentPosition = position

        guard let snapPosition = snapPosition(for: position) else {
            print("Could not evaluate snap position for \(position.visibleName)")
            return
        }

        guard let heightConstraint = self.heightConstraint else {
            print("No height constraint set")
            return
        }

        if animated {
            // Add extra height to make sure that bottom doesn't show up.

            heightConstraint.constant = heightConstraint.constant + kVerticalLeeway

            self.animator?.stopAnimation(true)

            let velocityVector = CGVector(dx: velocity.x / 100, dy: velocity.y / 100);
            let springParameters = UISpringTimingParameters(dampingRatio: 0.8, initialVelocity: velocityVector)

            self.animator = UIViewPropertyAnimator(duration: 0.5, timingParameters: springParameters)
            self.animator?.addAnimations {
                self.topConstraint?.constant = snapPosition
                self.superview?.layoutIfNeeded()
            }
            self.animator?.addCompletion({ position in
                heightConstraint.constant = -self.topMargin
                self.superview?.layoutIfNeeded()
            })

            self.animator?.startAnimation()
        } else {
            self.topConstraint?.constant = snapPosition
            self.superview?.layoutIfNeeded()
        }
    }

    // MARK: - Private methods

    private func positionsSorted() -> [DrawerPosition] {
        return self.sorted(positions: self.supportedPositions)
    }

    private func setInitialPosition() {
        self.position = self.positionsSorted().last ?? .collapsed
    }

    private func shouldScrollChildView() -> Bool {
        if let canScrollContent = self.delegate?.canScrollContent {
            return canScrollContent(self)
        }
        // By default, child scrolling is enabled only when fully open.
        return self.position == .open
    }

    @objc private func onPan(_ sender: UIPanGestureRecognizer) {
        switch sender.state {
        case .began:
            isDragging = true

            self.delegate?.drawer?(self, willTransitionFrom: self.position)

            self.animator?.stopAnimation(true)

            let frame = self.layer.presentation()?.frame ?? self.frame
            self.panOrigin = frame.origin.y
            setPosition(forDragPoint: panOrigin)

            break
        case .changed:

            let translation = sender.translation(in: self)
            // If scrolling upwards a scroll view, ignore the events.
            if let childScrollView = self.childScrollView {

                let shouldCancelChildViewScroll = (childScrollView.contentOffset.y < 0)
                let shouldScrollChildView = !childScrollView.isScrollEnabled ?
                    false : (!shouldCancelChildViewScroll && self.shouldScrollChildView())

                if !shouldScrollChildView || childScrollView.contentOffset.y < 0 {
                    // Scrolling downwards and content was consumed, so disable
                    // child scrolling and catch up with the offset.
                    self.panOrigin = self.panOrigin - childScrollView.contentOffset.y
                    childScrollView.isScrollEnabled = false
                    //print("Disabled child scrolling")

                    // Also animate to the proper scroll position.
                    //print("Animating to target position...")

                    self.animator?.stopAnimation(true)
                    self.animator = UIViewPropertyAnimator.runningPropertyAnimator(withDuration: 0.5, delay: 0.0, options: [.allowUserInteraction, .beginFromCurrentState], animations: {
                        childScrollView.contentOffset.y = 0
                        self.setPosition(forDragPoint: self.panOrigin + translation.y)
                    }, completion: nil)
                } else {
                    //print("Let it scroll...")
                }

                // Scroll only if we're not scrolling the subviews.
                if !shouldScrollChildView {
                    setPosition(forDragPoint: panOrigin + translation.y)
                }
            } else {
                setPosition(forDragPoint: panOrigin + translation.y)
            }

            self.delegate?.drawerDidMove?(self, verticalPosition: panOrigin + translation.y)

        case.failed:
            print("ERROR: UIPanGestureRecognizer failed")
            fallthrough
        case .ended:
            let velocity = sender.velocity(in: self)
            //print("Ending with vertical velocity \(velocity.y)")

            if let childScrollView = self.childScrollView,
                childScrollView.contentOffset.y > 0 && self.shouldScrollChildView() {
                // Let it scroll.
                print("Let it scroll.")
            } else {
                // Check velocity and snap position separately:
                // 1) A treshold for velocity that makes drawer slide to the next state
                // 2) A prediction that estimates the next position based on target offset.
                // If 2 doesn't evaluate to the current position, use that.
                let targetOffset = self.frame.origin.y + velocity.y * 0.15
                let targetPosition = positionFor(offset: targetOffset)

                // The positions are reversed, reverse the sign.
                let advancement = velocity.y > 0 ? -1 : 1

                let nextPosition: DrawerPosition
                if targetPosition == self.position && abs(velocity.y) > kVelocityTreshold {
                    nextPosition = targetPosition.advance(by: advancement, inPositions: self.positionsSorted())
                } else {
                    nextPosition = targetPosition
                }
                self.setPosition(nextPosition, withVelocity: velocity, animated: true)
            }

            self.childScrollView?.isScrollEnabled = childScrollWasEnabled
            self.childScrollView = nil

            isDragging = false

        default:
            break
        }
    }

    @objc private func onTapOverlay(_ sender: UITapGestureRecognizer) {
        if sender.state == .ended {
            self.delegate?.drawer?(self, willTransitionFrom: currentPosition)

            let prevPosition = self.position.advance(by: -1, inPositions: self.positionsSorted())
            self.setPosition(prevPosition, animated: true)

            // Notify
            self.delegate?.drawer?(self, didTransitionTo: prevPosition)
        }
    }

    private func sorted(positions: [DrawerPosition]) -> [DrawerPosition] {
        return positions
            .flatMap { pos in snapPosition(for: pos).map { (pos: pos, y: $0) } }
            .sorted { $0.y > $1.y }
            .map { $0.pos }
    }

    private func snapPosition(for position: DrawerPosition) -> CGFloat? {
        guard let superview = self.superview else {
            return nil
        }

        switch position {
        case .open:
            return self.topMargin
        case .partiallyOpen:
            return superview.bounds.height - self.partiallyOpenHeight
        case .collapsed:
            return superview.bounds.height - self.collapsedHeight
        }
    }

    private func opacity(for position: DrawerPosition) -> CGFloat {
        switch position {
        case .open:
            return 1
        case .partiallyOpen:
            return 0
        case .collapsed:
            return 0
        }
    }

    private func snapPositionForHidden() -> CGFloat {
        return superview?.bounds.height ?? 0
    }

    private func positionFor(offset: CGFloat) -> DrawerPosition {
        let distances = self.supportedPositions
            .flatMap { pos in snapPosition(for: pos).map { (pos: pos, y: $0) } }
            .sorted { (p1, p2) -> Bool in
                return abs(p1.y - offset) < abs(p2.y - offset)
        }

        return distances.first.map { $0.pos } ?? DrawerPosition.collapsed
    }

    private func setPosition(forDragPoint dragPoint: CGFloat) {
        let positions = self.supportedPositions
            .flatMap(snapPosition)
            .sorted()

        let position: CGFloat
        if let lowerBound = positions.first, dragPoint < lowerBound {
            let stretch = damp(value: lowerBound - dragPoint, factor: 50)
            position = lowerBound - damp(value: lowerBound - dragPoint, factor: 50)
            self.heightConstraint?.constant = -self.topMargin + stretch
        } else if let upperBound = positions.last, dragPoint > upperBound {
            position = upperBound + damp(value: dragPoint - upperBound, factor: 50)
        } else {
            position = dragPoint
        }
        self.topConstraint?.constant = position
        self.layoutIfNeeded()

        //self.setOverlayOpacityForPoint(point: position)
    }

    private func updateSnapPosition(animated: Bool) {
        if let topConstraint = self.topConstraint,
            let expectedPos = self.snapPosition(for: currentPosition),
            expectedPos != topConstraint.constant
        {
            self.setPosition(currentPosition, animated: animated)
        }
    }

    private func setOverlayOpacityForPoint(point: CGFloat) {
        guard let superview = self.superview else {
            return
        }

        let opacity = getOverlayOpacityForPoint(point: point)

        if opacity > 0 {
            self.overlay = self.overlay ?? {
                let overlay = createOverlay()
                superview.insertSubview(overlay, belowSubview: self)
                return overlay
            }()
            self.overlay?.backgroundColor = UIColor.black
            self.overlay?.alpha = opacity * 0.5
        } else if let overlay = self.overlay {
            overlay.removeFromSuperview()
            self.overlay = nil
        }
    }

    private func createOverlay() -> UIView {
        let overlay = UIView(frame: superview?.bounds ?? CGRect())
        overlay.backgroundColor = UIColor.black
        overlay.alpha = 0
        let tap = UITapGestureRecognizer(target: self, action: #selector(onTapOverlay))
        overlay.addGestureRecognizer(tap)
        return overlay
    }

    private func getOverlayOpacityForPoint(point: CGFloat) -> CGFloat {
        let positions = self.supportedPositions
            // Group the info on position together. For increased
            // robustness, hide the ones without snap position.
            .flatMap { p in self.snapPosition(for: p).map {(
                snapPosition: $0,
                opacity: opacity(for: p)
                )}
            }
            .sorted { (p1, p2) -> Bool in p1.snapPosition < p2.snapPosition }

        let prev = positions.last(where: { $0.snapPosition <= point })
        let next = positions.first(where: { $0.snapPosition > point })

        if let a = prev, let b = next {
            let n = (point - a.snapPosition) / (b.snapPosition - a.snapPosition)
            return a.opacity + (b.opacity - a.opacity) * n
        } else if let a = prev ?? next {
            return a.opacity
        } else {
            return 0
        }
    }

    private func damp(value: CGFloat, factor: CGFloat) -> CGFloat {
        return factor * (log10(value + factor/log(10)) - log10(factor/log(10)))
    }
}

extension DrawerView: UIGestureRecognizerDelegate {

    override public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }

    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        if let sv = otherGestureRecognizer.view as? UIScrollView {
            self.otherGestureRecognizer = otherGestureRecognizer
            self.childScrollView = sv
            self.childScrollWasEnabled = sv.isScrollEnabled
        }
        return true
    }

    public func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        if self.position == .open {
            return false
        } else {
            return !self.shouldScrollChildView() && otherGestureRecognizer.view is UIScrollView
        }
    }
}

extension CGRect {

    func insetBy(top: CGFloat = 0, bottom: CGFloat = 0, left: CGFloat = 0, right: CGFloat = 0) -> CGRect {
        return CGRect(
            x: self.origin.x + left,
            y: self.origin.y + top,
            width: self.size.width - left - right,
            height: self.size.height - top - bottom)
    }
}

extension Array {

    public func last(where predicate: (Element) throws -> Bool) rethrows -> Element? {
        return try self.filter(predicate).last
    }
}

extension DrawerPosition {

    func advance(by: Int, inPositions positions: [DrawerPosition]) -> DrawerPosition {
        guard !positions.isEmpty else {
            return self
        }

        let index = (positions.index(of: self) ?? 0)
        let nextIndex = max(0, min(positions.count - 1, index + by))

        return positions[nextIndex]
    }
}

func abort(reason: String) -> Never  {
    print(reason)
    abort()
}
