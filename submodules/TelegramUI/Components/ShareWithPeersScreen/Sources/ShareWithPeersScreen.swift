import Foundation
import UIKit
import Display
import AsyncDisplayKit
import ComponentFlow
import SwiftSignalKit
import ViewControllerComponent
import ComponentDisplayAdapters
import TelegramPresentationData
import AccountContext
import TelegramCore
import MultilineTextComponent
import SolidRoundedButtonComponent
import PresentationDataUtils
import ButtonComponent
import PlainButtonComponent
import AnimatedCounterComponent
import TokenListTextField
import AvatarNode
import LocalizedPeerData
import PeerListItemComponent
import LottieComponent

final class ShareWithPeersScreenComponent: Component {
    typealias EnvironmentType = ViewControllerComponentContainer.Environment
    
    let context: AccountContext
    let stateContext: ShareWithPeersScreen.StateContext
    let initialPrivacy: EngineStoryPrivacy
    let timeout: Int
    let categoryItems: [CategoryItem]
    let completion: (EngineStoryPrivacy) -> Void
    let editCategory: (EngineStoryPrivacy) -> Void
    let secondaryAction: () -> Void
    
    init(
        context: AccountContext,
        stateContext: ShareWithPeersScreen.StateContext,
        initialPrivacy: EngineStoryPrivacy,
        timeout: Int,
        categoryItems: [CategoryItem],
        completion: @escaping (EngineStoryPrivacy) -> Void,
        editCategory: @escaping (EngineStoryPrivacy) -> Void,
        secondaryAction: @escaping () -> Void
    ) {
        self.context = context
        self.stateContext = stateContext
        self.initialPrivacy = initialPrivacy
        self.timeout = timeout
        self.categoryItems = categoryItems
        self.completion = completion
        self.editCategory = editCategory
        self.secondaryAction = secondaryAction
    }
    
    static func ==(lhs: ShareWithPeersScreenComponent, rhs: ShareWithPeersScreenComponent) -> Bool {
        if lhs.context !== rhs.context {
            return false
        }
        if lhs.stateContext !== rhs.stateContext {
            return false
        }
        if lhs.initialPrivacy != rhs.initialPrivacy {
            return false
        }
        if lhs.timeout != rhs.timeout {
            return false
        }
        if lhs.categoryItems != rhs.categoryItems {
            return false
        }
        
        return true
    }
    
    private struct ItemLayout: Equatable {
        struct Section: Equatable {
            var id: Int
            var insets: UIEdgeInsets
            var itemHeight: CGFloat
            var itemCount: Int
            
            var totalHeight: CGFloat
            
            init(
                id: Int,
                insets: UIEdgeInsets,
                itemHeight: CGFloat,
                itemCount: Int
            ) {
                self.id = id
                self.insets = insets
                self.itemHeight = itemHeight
                self.itemCount = itemCount
                
                self.totalHeight = insets.top + itemHeight * CGFloat(itemCount)
            }
        }
        
        var containerSize: CGSize
        var containerInset: CGFloat
        var bottomInset: CGFloat
        var topInset: CGFloat
        var sideInset: CGFloat
        var navigationHeight: CGFloat
        var sections: [Section]
        
        var contentHeight: CGFloat
        
        init(containerSize: CGSize, containerInset: CGFloat, bottomInset: CGFloat, topInset: CGFloat, sideInset: CGFloat, navigationHeight: CGFloat, sections: [Section]) {
            self.containerSize = containerSize
            self.containerInset = containerInset
            self.bottomInset = bottomInset
            self.topInset = topInset
            self.sideInset = sideInset
            self.navigationHeight = navigationHeight
            self.sections = sections
            
            var contentHeight: CGFloat = 0.0
            contentHeight += navigationHeight
            for section in sections {
                contentHeight += section.totalHeight
            }
            contentHeight += bottomInset
            self.contentHeight = contentHeight
        }
    }
    
    private final class ScrollView: UIScrollView {
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            return super.hitTest(point, with: event)
        }
        
        override func touchesShouldCancel(in view: UIView) -> Bool {
            return true
        }
    }
    
    final class AnimationHint {
        let contentReloaded: Bool
        
        init(
            contentReloaded: Bool
        ) {
            self.contentReloaded = contentReloaded
        }
    }
    
    enum CategoryColor {
        case blue
        case yellow
        case green
        case purple
        case red
        case violet
    }
    
    final class CategoryItem: Equatable {
        let id: CategoryId
        let title: String
        let icon: String?
        let iconColor: CategoryColor
        let actionTitle: String?
        
        init(
            id: CategoryId,
            title: String,
            icon: String?,
            iconColor: CategoryColor,
            actionTitle: String?
        ) {
            self.id = id
            self.title = title
            self.icon = icon
            self.iconColor = iconColor
            self.actionTitle = actionTitle
        }
        
        static func ==(lhs: CategoryItem, rhs: CategoryItem) -> Bool {
            if lhs === rhs {
                return true
            }
            return false
        }
    }
    
    final class PeerItem: Equatable {
        let id: EnginePeer.Id
        let peer: EnginePeer?
        
        init(
            id: EnginePeer.Id,
            peer: EnginePeer?
        ) {
            self.id = id
            self.peer = peer
        }
        
        static func ==(lhs: PeerItem, rhs: PeerItem) -> Bool {
            if lhs === rhs {
                return true
            }
            return false
        }
    }
    
    enum CategoryId: Int, Hashable {
        case everyone = 0
        case contacts = 1
        case closeFriends = 2
        case selectedContacts = 3
    }
    
    final class View: UIView, UIScrollViewDelegate {
        private let dimView: UIView
        private let backgroundView: UIImageView
        
        private let navigationContainerView: UIView
        private let navigationBackgroundView: BlurredBackgroundView
        private let navigationTitle = ComponentView<Empty>()
        private let navigationLeftButton = ComponentView<Empty>()
        private let navigationRightButton = ComponentView<Empty>()
        private let navigationSeparatorLayer: SimpleLayer
        private let navigationTextFieldState = TokenListTextField.ExternalState()
        private let navigationTextField = ComponentView<Empty>()
        private let textFieldSeparatorLayer: SimpleLayer
        
        private let emptyResultsTitle = ComponentView<Empty>()
        private let emptyResultsText = ComponentView<Empty>()
        private let emptyResultsAnimation = ComponentView<Empty>()
        
        private let scrollView: ScrollView
        private let scrollContentClippingView: SparseContainerView
        private let scrollContentView: UIView
        
        private let bottomBackgroundView: BlurredBackgroundView
        private let bottomSeparatorLayer: SimpleLayer
        private let actionButton = ComponentView<Empty>()
        
        private let categoryTemplateItem = ComponentView<Empty>()
        private let peerTemplateItem = ComponentView<Empty>()
        
        private let itemContainerView: UIView
        private var visibleSectionHeaders: [Int: ComponentView<Empty>] = [:]
        private var visibleItems: [AnyHashable: ComponentView<Empty>] = [:]
        
        private var ignoreScrolling: Bool = false
        private var isDismissed: Bool = false
        
        private var selectedPeers: [EnginePeer.Id] = []
        private var selectedCategories = Set<CategoryId>()
        private var selectedPeersByCategory: [CategoryId: [EnginePeer.Id]] = [:]
        
        private var component: ShareWithPeersScreenComponent?
        private weak var state: EmptyComponentState?
        private var environment: ViewControllerComponentContainer.Environment?
        private var itemLayout: ItemLayout?
        
        private var topOffsetDistance: CGFloat?
        
        private var defaultStateValue: ShareWithPeersScreen.State?
        private var stateDisposable: Disposable?
        
        private var searchStateContext: ShareWithPeersScreen.StateContext?
        private var searchStateDisposable: Disposable?
        
        private var effectiveStateValue: ShareWithPeersScreen.State? {
            return self.searchStateContext?.stateValue ?? self.defaultStateValue
        }
        
        override init(frame: CGRect) {
            self.dimView = UIView()
            
            self.backgroundView = UIImageView()
            
            self.navigationContainerView = SparseContainerView()
            self.navigationBackgroundView = BlurredBackgroundView(color: .clear, enableBlur: true)
            self.navigationSeparatorLayer = SimpleLayer()
            self.textFieldSeparatorLayer = SimpleLayer()
            
            self.bottomBackgroundView = BlurredBackgroundView(color: .clear, enableBlur: true)
            self.bottomSeparatorLayer = SimpleLayer()
            
            self.scrollView = ScrollView()
            
            self.scrollContentClippingView = SparseContainerView()
            self.scrollContentClippingView.clipsToBounds = true
            
            self.scrollContentView = UIView()
            
            self.itemContainerView = UIView()
            self.itemContainerView.clipsToBounds = true
            self.itemContainerView.layer.cornerRadius = 10.0
            
            super.init(frame: frame)
            
            self.addSubview(self.dimView)
            self.addSubview(self.backgroundView)
            
            self.scrollView.delaysContentTouches = true
            self.scrollView.canCancelContentTouches = true
            self.scrollView.clipsToBounds = false
            if #available(iOSApplicationExtension 11.0, iOS 11.0, *) {
                self.scrollView.contentInsetAdjustmentBehavior = .never
            }
            if #available(iOS 13.0, *) {
                self.scrollView.automaticallyAdjustsScrollIndicatorInsets = false
            }
            self.scrollView.showsVerticalScrollIndicator = false
            self.scrollView.showsHorizontalScrollIndicator = false
            self.scrollView.alwaysBounceHorizontal = false
            self.scrollView.alwaysBounceVertical = true
            self.scrollView.scrollsToTop = false
            self.scrollView.delegate = self
            self.scrollView.clipsToBounds = true
            
            self.addSubview(self.scrollContentClippingView)
            self.scrollContentClippingView.addSubview(self.scrollView)
            
            self.scrollView.addSubview(self.scrollContentView)
            
            self.scrollContentView.addSubview(self.itemContainerView)
            
            self.addSubview(self.navigationContainerView)
            self.navigationContainerView.addSubview(self.navigationBackgroundView)
            self.navigationContainerView.layer.addSublayer(self.navigationSeparatorLayer)
            
            self.addSubview(self.bottomBackgroundView)
            self.layer.addSublayer(self.bottomSeparatorLayer)
            
            self.dimView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.dimTapGesture(_:))))
        }
        
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
        
        deinit {
            self.stateDisposable?.dispose()
        }
        
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            if !self.ignoreScrolling {
                self.updateScrolling(transition: .immediate)
            }
        }
        
        func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
            guard let itemLayout = self.itemLayout, let topOffsetDistance = self.topOffsetDistance else {
                return
            }
            
            if scrollView.contentOffset.y <= -100.0 && velocity.y <= -2.0 {
            } else {
                var topOffset = -self.scrollView.bounds.minY + itemLayout.topInset
                if topOffset > 0.0 {
                    topOffset = max(0.0, topOffset)
                    
                    if topOffset < topOffsetDistance {
                        //targetContentOffset.pointee.y = scrollView.contentOffset.y
                        //scrollView.setContentOffset(CGPoint(x: 0.0, y: itemLayout.topInset), animated: true)
                    }
                }
            }
        }
        
        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
            if !self.bounds.contains(point) {
                return nil
            }
            if !self.backgroundView.frame.contains(point) {
                return self.dimView
            }
            
            if let result = self.navigationContainerView.hitTest(self.convert(point, to: self.navigationContainerView), with: event) {
                return result
            }
            
            let result = super.hitTest(point, with: event)
            return result
        }
        
        @objc private func dimTapGesture(_ recognizer: UITapGestureRecognizer) {
            if case .ended = recognizer.state {
                guard let environment = self.environment, let controller = environment.controller() as? ShareWithPeersScreen else {
                    return
                }
                controller.requestDismiss()
            }
        }
        
        private func updateScrolling(transition: Transition) {
            guard let component = self.component, let environment = self.environment, let controller = environment.controller(), let itemLayout = self.itemLayout else {
                return
            }
            guard let stateValue = self.effectiveStateValue else {
                return
            }
            
            var topOffset = -self.scrollView.bounds.minY + itemLayout.topInset
            topOffset = max(0.0, topOffset)
            transition.setTransform(layer: self.backgroundView.layer, transform: CATransform3DMakeTranslation(0.0, topOffset + itemLayout.containerInset, 0.0))
            transition.setPosition(view: self.navigationContainerView, position: CGPoint(x: 0.0, y: topOffset + itemLayout.containerInset))
            
            let bottomDistance = itemLayout.contentHeight - self.scrollView.bounds.maxY
            let bottomAlphaDistance: CGFloat = 30.0
            var bottomAlpha: CGFloat = bottomDistance / bottomAlphaDistance
            bottomAlpha = max(0.0, min(1.0, bottomAlpha))
            
            let topOffsetDistance: CGFloat = min(200.0, floor(itemLayout.containerSize.height * 0.25))
            self.topOffsetDistance = topOffsetDistance
            var topOffsetFraction = topOffset / topOffsetDistance
            topOffsetFraction = max(0.0, min(1.0, topOffsetFraction))
            
            let transitionFactor: CGFloat = 1.0 - topOffsetFraction
            let _ = transitionFactor
            let _ = controller
            //controller.updateModalStyleOverlayTransitionFactor(transitionFactor, transition: transition.containedViewLayoutTransition)
            
            var visibleBounds = self.scrollView.bounds
            visibleBounds.origin.y -= itemLayout.topInset
            visibleBounds.size.height += itemLayout.topInset
            
            var visibleFrame = self.scrollView.frame
            visibleFrame.origin.y -= itemLayout.topInset
            visibleFrame.size.height += itemLayout.topInset
            
            var validIds: [AnyHashable] = []
            var validSectionHeaders: [AnyHashable] = []
            var sectionOffset: CGFloat = itemLayout.navigationHeight
            for sectionIndex in 0 ..< itemLayout.sections.count {
                let section = itemLayout.sections[sectionIndex]
                
                var minSectionHeader: UIView?
                
                do {
                    var sectionHeaderFrame = CGRect(origin: CGPoint(x: visibleFrame.minX, y: itemLayout.containerInset + sectionOffset - self.scrollView.bounds.minY + itemLayout.topInset), size: CGSize(width: itemLayout.containerSize.width, height: section.insets.top))
                    
                    let sectionHeaderMinY = topOffset + itemLayout.containerInset + itemLayout.navigationHeight
                    let sectionHeaderMaxY = itemLayout.containerInset + sectionOffset - self.scrollView.bounds.minY + itemLayout.topInset + section.totalHeight - 28.0
                    
                    sectionHeaderFrame.origin.y = max(sectionHeaderFrame.origin.y, sectionHeaderMinY)
                    sectionHeaderFrame.origin.y = min(sectionHeaderFrame.origin.y, sectionHeaderMaxY)
                    
                    if visibleFrame.intersects(sectionHeaderFrame) {
                        validSectionHeaders.append(section.id)
                        let sectionHeader: ComponentView<Empty>
                        var sectionHeaderTransition = transition
                        if let current = self.visibleSectionHeaders[section.id] {
                            sectionHeader = current
                        } else {
                            if !transition.animation.isImmediate {
                                sectionHeaderTransition = .immediate
                            }
                            sectionHeader = ComponentView()
                            self.visibleSectionHeaders[section.id] = sectionHeader
                        }
                        
                        let sectionTitle: String
                        if section.id == 0 {
                            let hours = component.timeout / 3600
                            sectionTitle = "WHO CAN VIEW FOR \(hours) HOURS"
                        } else {
                            if case .chats = component.stateContext.subject {
                                sectionTitle = "CHATS"
                            } else {
                                sectionTitle = "CONTACTS"
                            }
                        }
                        
                        let _ = sectionHeader.update(
                            transition: sectionHeaderTransition,
                            component: AnyComponent(SectionHeaderComponent(
                                theme: environment.theme,
                                sideInset: 16.0,
                                title: sectionTitle
                            )),
                            environment: {},
                            containerSize: sectionHeaderFrame.size
                        )
                        if let sectionHeaderView = sectionHeader.view {
                            if sectionHeaderView.superview == nil {
                                sectionHeaderView.isUserInteractionEnabled = false
                                self.scrollContentClippingView.addSubview(sectionHeaderView)
                            }
                            if minSectionHeader == nil {
                                minSectionHeader = sectionHeaderView
                            }
                            sectionHeaderTransition.setFrame(view: sectionHeaderView, frame: sectionHeaderFrame)
                        }
                    }
                }
                
                if section.id == 0 {
                    for i in 0 ..< component.categoryItems.count {
                        let itemFrame = CGRect(origin: CGPoint(x: 0.0, y: sectionOffset + section.insets.top + CGFloat(i) * section.itemHeight), size: CGSize(width: itemLayout.containerSize.width, height: section.itemHeight))
                        if !visibleBounds.intersects(itemFrame) {
                            continue
                        }
                        
                        let item = component.categoryItems[i]
                        let categoryId = item.id
                        let itemId = AnyHashable(item.id)
                        validIds.append(itemId)
                        
                        var itemTransition = transition
                        let visibleItem: ComponentView<Empty>
                        if let current = self.visibleItems[itemId] {
                            visibleItem = current
                        } else {
                            visibleItem = ComponentView()
                            if !transition.animation.isImmediate {
                                itemTransition = .immediate
                            }
                            self.visibleItems[itemId] = visibleItem
                        }
                        
                        let _ = visibleItem.update(
                            transition: itemTransition,
                            component: AnyComponent(CategoryListItemComponent(
                                context: component.context,
                                theme: environment.theme,
                                sideInset: itemLayout.sideInset,
                                title: item.title,
                                color: item.iconColor,
                                iconName: item.icon,
                                subtitle: item.actionTitle,
                                selectionState: .editing(isSelected: self.selectedCategories.contains(item.id), isTinted: false),
                                hasNext: i != component.categoryItems.count - 1,
                                action: { [weak self] in
                                    guard let self else {
                                        return
                                    }
                                    if self.selectedCategories.contains(categoryId) {
                                    } else {
                                        self.selectedPeers = []
                                        
                                        self.selectedCategories.removeAll()
                                        self.selectedCategories.insert(categoryId)
                                        
                                        if self.selectedPeers.isEmpty && categoryId == .selectedContacts {
                                            component.editCategory(EngineStoryPrivacy(base: .nobody, additionallyIncludePeers: []))
                                            controller.dismiss()
                                        }
                                    }
                                    self.state?.updated(transition: Transition(animation: .curve(duration: 0.35, curve: .spring)))
                                },
                                secondaryAction: { [weak self] in
                                    guard let self, let environment = self.environment, let controller = environment.controller() else {
                                        return
                                    }
                                    let base: EngineStoryPrivacy.Base?
                                    switch categoryId {
                                    case .everyone:
                                        base = nil
                                    case .contacts:
                                        base = .contacts
                                    case .closeFriends:
                                        base = .closeFriends
                                    case .selectedContacts:
                                        base = .nobody
                                    }
                                    if let base {
                                        component.editCategory(EngineStoryPrivacy(base: base, additionallyIncludePeers: self.selectedPeers))
                                        controller.dismiss()
                                    }
                                }
                            )),
                            environment: {},
                            containerSize: itemFrame.size
                        )
                        if let itemView = visibleItem.view {
                            if itemView.superview == nil {
                                if let minSectionHeader {
                                    self.itemContainerView.insertSubview(itemView, belowSubview: minSectionHeader)
                                } else {
                                    self.itemContainerView.addSubview(itemView)
                                }
                            }
                            itemTransition.setFrame(view: itemView, frame: itemFrame)
                        }
                    }
                } else if section.id == 1 {
                    for i in 0 ..< stateValue.peers.count {
                        let itemFrame = CGRect(origin: CGPoint(x: 0.0, y: sectionOffset + section.insets.top + CGFloat(i) * section.itemHeight), size: CGSize(width: itemLayout.containerSize.width, height: section.itemHeight))
                        if !visibleBounds.intersects(itemFrame) {
                            continue
                        }
                        
                        let peer = stateValue.peers[i]
                        let itemId = AnyHashable(peer.id)
                        validIds.append(itemId)
                        
                        var itemTransition = transition
                        let visibleItem: ComponentView<Empty>
                        if let current = self.visibleItems[itemId] {
                            visibleItem = current
                        } else {
                            visibleItem = ComponentView()
                            if !transition.animation.isImmediate {
                                itemTransition = .immediate
                            }
                            self.visibleItems[itemId] = visibleItem
                        }
                        
                        let _ = visibleItem.update(
                            transition: itemTransition,
                            component: AnyComponent(PeerListItemComponent(
                                context: component.context,
                                theme: environment.theme,
                                strings: environment.strings,
                                style: .generic,
                                sideInset: itemLayout.sideInset,
                                title: peer.displayTitle(strings: environment.strings, displayOrder: .firstLast),
                                peer: peer,
                                subtitle: nil,
                                subtitleAccessory: .none,
                                presence: stateValue.presences[peer.id],
                                selectionState: .editing(isSelected: self.selectedPeers.contains(peer.id), isTinted: false),
                                hasNext: true,
                                action: { [weak self] peer in
                                    guard let self else {
                                        return
                                    }
                                    if let index = self.selectedPeers.firstIndex(of: peer.id) {
                                        self.selectedPeers.remove(at: index)
                                    } else {
                                        self.selectedPeers.append(peer.id)
                                    }
                                    
                                    let transition = Transition(animation: .curve(duration: 0.35, curve: .spring))
                                    self.state?.updated(transition: transition)
                                    
                                    if self.searchStateContext != nil {
                                        if let navigationTextFieldView = self.navigationTextField.view as? TokenListTextField.View {
                                            navigationTextFieldView.clearText()
                                        }
                                    }
                                }
                            )),
                            environment: {},
                            containerSize: itemFrame.size
                        )
                        if let itemView = visibleItem.view {
                            if itemView.superview == nil {
                                self.itemContainerView.addSubview(itemView)
                            }
                            itemTransition.setFrame(view: itemView, frame: itemFrame)
                        }
                    }
                }
                
                sectionOffset += section.totalHeight
            }
            
            var removeIds: [AnyHashable] = []
            for (id, item) in self.visibleItems {
                if !validIds.contains(id) {
                    removeIds.append(id)
                    if let itemView = item.view {
                        itemView.removeFromSuperview()
                    }
                }
            }
            for id in removeIds {
                self.visibleItems.removeValue(forKey: id)
            }
            
            var removeSectionHeaderIds: [Int] = []
            for (id, item) in self.visibleSectionHeaders {
                if !validSectionHeaders.contains(id) {
                    removeSectionHeaderIds.append(id)
                    if let itemView = item.view {
                        itemView.removeFromSuperview()
                    }
                }
            }
            for id in removeSectionHeaderIds {
                self.visibleSectionHeaders.removeValue(forKey: id)
            }
            
            let fadeTransition = Transition.easeInOut(duration: 0.25)
            if let searchStateContext = self.searchStateContext, case let .search(query) = searchStateContext.subject, let value = searchStateContext.stateValue, value.peers.isEmpty {
                let sideInset: CGFloat = 44.0
                let emptyAnimationHeight = 148.0
                let topInset: CGFloat = topOffset + itemLayout.containerInset + 40.0
                let bottomInset: CGFloat = max(environment.safeInsets.bottom, environment.inputHeight)
                let visibleHeight = visibleFrame.height
                let emptyAnimationSpacing: CGFloat = 8.0
                let emptyTextSpacing: CGFloat = 8.0
                
                let emptyResultsTitleSize = self.emptyResultsTitle.update(
                    transition: .immediate,
                    component: AnyComponent(
                        MultilineTextComponent(
                            text: .plain(NSAttributedString(string: environment.strings.Contacts_Search_NoResults, font: Font.semibold(17.0), textColor: environment.theme.list.itemSecondaryTextColor)),
                            horizontalAlignment: .center
                        )
                    ),
                    environment: {},
                    containerSize: visibleFrame.size
                )
                let emptyResultsTextSize = self.emptyResultsText.update(
                    transition: .immediate,
                    component: AnyComponent(
                        MultilineTextComponent(
                            text: .plain(NSAttributedString(string: environment.strings.Contacts_Search_NoResultsQueryDescription(query).string, font: Font.regular(15.0), textColor: environment.theme.list.itemSecondaryTextColor)),
                            horizontalAlignment: .center,
                            maximumNumberOfLines: 0
                        )
                    ),
                    environment: {},
                    containerSize: CGSize(width: visibleFrame.width - sideInset * 2.0, height: visibleFrame.height)
                )
                let emptyResultsAnimationSize = self.emptyResultsAnimation.update(
                    transition: .immediate,
                    component: AnyComponent(LottieComponent(
                        content: LottieComponent.AppBundleContent(name: "ChatListNoResults")
                    )),
                    environment: {},
                    containerSize: CGSize(width: emptyAnimationHeight, height: emptyAnimationHeight)
                )
      
                let emptyTotalHeight = emptyAnimationHeight + emptyAnimationSpacing + emptyResultsTitleSize.height + emptyResultsTextSize.height + emptyTextSpacing
                let emptyAnimationY = topInset + floorToScreenPixels((visibleHeight - topInset - bottomInset - emptyTotalHeight) / 2.0)
                
                let emptyResultsAnimationFrame = CGRect(origin: CGPoint(x: floorToScreenPixels((visibleFrame.width - emptyResultsAnimationSize.width) / 2.0), y: emptyAnimationY), size: emptyResultsAnimationSize)
                
                let emptyResultsTitleFrame = CGRect(origin: CGPoint(x: floorToScreenPixels((visibleFrame.width - emptyResultsTitleSize.width) / 2.0), y: emptyResultsAnimationFrame.maxY + emptyAnimationSpacing), size: emptyResultsTitleSize)
                
                let emptyResultsTextFrame = CGRect(origin: CGPoint(x: floorToScreenPixels((visibleFrame.width - emptyResultsTextSize.width) / 2.0), y: emptyResultsTitleFrame.maxY + emptyTextSpacing), size: emptyResultsTextSize)
                
                if let view = self.emptyResultsAnimation.view as? LottieComponent.View {
                    if view.superview == nil {
                        view.alpha = 0.0
                        fadeTransition.setAlpha(view: view, alpha: 1.0)
                        self.scrollView.addSubview(view)
                        view.playOnce()
                    }
                    view.bounds = CGRect(origin: .zero, size: emptyResultsAnimationFrame.size)
                    transition.setPosition(view: view, position: emptyResultsAnimationFrame.center)
                }
                if let view = self.emptyResultsTitle.view {
                    if view.superview == nil {
                        view.alpha = 0.0
                        fadeTransition.setAlpha(view: view, alpha: 1.0)
                        self.scrollView.addSubview(view)
                    }
                    view.bounds = CGRect(origin: .zero, size: emptyResultsTitleFrame.size)
                    transition.setPosition(view: view, position: emptyResultsTitleFrame.center)
                }
                if let view = self.emptyResultsText.view {
                    if view.superview == nil {
                        view.alpha = 0.0
                        fadeTransition.setAlpha(view: view, alpha: 1.0)
                        self.scrollView.addSubview(view)
                    }
                    view.bounds = CGRect(origin: .zero, size: emptyResultsTextFrame.size)
                    transition.setPosition(view: view, position: emptyResultsTextFrame.center)
                }
            } else {
                if let view = self.emptyResultsAnimation.view {
                    fadeTransition.setAlpha(view: view, alpha: 0.0, completion: { _ in
                        view.removeFromSuperview()
                    })
                }
                if let view = self.emptyResultsTitle.view {
                    fadeTransition.setAlpha(view: view, alpha: 0.0, completion: { _ in
                        view.removeFromSuperview()
                    })
                }
                if let view = self.emptyResultsText.view {
                    fadeTransition.setAlpha(view: view, alpha: 0.0, completion: { _ in
                        view.removeFromSuperview()
                    })
                }
            }
        }
        
        func animateIn() {
            self.dimView.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.3)
            let animateOffset: CGFloat = self.bounds.height - self.backgroundView.frame.minY
            self.scrollContentClippingView.layer.animatePosition(from: CGPoint(x: 0.0, y: animateOffset), to: CGPoint(), duration: 0.5, timingFunction: kCAMediaTimingFunctionSpring, additive: true)
            self.backgroundView.layer.animatePosition(from: CGPoint(x: 0.0, y: animateOffset), to: CGPoint(), duration: 0.5, timingFunction: kCAMediaTimingFunctionSpring, additive: true)
            self.navigationContainerView.layer.animatePosition(from: CGPoint(x: 0.0, y: animateOffset), to: CGPoint(), duration: 0.5, timingFunction: kCAMediaTimingFunctionSpring, additive: true)
            self.bottomBackgroundView.layer.animatePosition(from: CGPoint(x: 0.0, y: animateOffset), to: CGPoint(), duration: 0.5, timingFunction: kCAMediaTimingFunctionSpring, additive: true)
            self.bottomSeparatorLayer.animatePosition(from: CGPoint(x: 0.0, y: animateOffset), to: CGPoint(), duration: 0.5, timingFunction: kCAMediaTimingFunctionSpring, additive: true)
            if let actionButtonView = self.actionButton.view {
                actionButtonView.layer.animatePosition(from: CGPoint(x: 0.0, y: animateOffset), to: CGPoint(), duration: 0.5, timingFunction: kCAMediaTimingFunctionSpring, additive: true)
            }
        }
        
        func animateOut(completion: @escaping () -> Void) {
            self.isDismissed = true
            
            if let controller = self.environment?.controller() {
                controller.updateModalStyleOverlayTransitionFactor(0.0, transition: .animated(duration: 0.3, curve: .easeInOut))
            }
            
            var animateOffset: CGFloat = self.bounds.height - self.backgroundView.frame.minY
            if self.scrollView.contentOffset.y < 0.0 {
                animateOffset += -self.scrollView.contentOffset.y
            }
            
            self.dimView.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.3, removeOnCompletion: false)
            self.scrollContentClippingView.layer.animatePosition(from: CGPoint(), to: CGPoint(x: 0.0, y: animateOffset), duration: 0.3, timingFunction: CAMediaTimingFunctionName.easeInEaseOut.rawValue, removeOnCompletion: false, additive: true, completion: { _ in
                completion()
            })
            self.backgroundView.layer.animatePosition(from: CGPoint(), to: CGPoint(x: 0.0, y: animateOffset), duration: 0.3, timingFunction: CAMediaTimingFunctionName.easeInEaseOut.rawValue, removeOnCompletion: false, additive: true)
            self.navigationContainerView.layer.animatePosition(from: CGPoint(), to: CGPoint(x: 0.0, y: animateOffset), duration: 0.3, timingFunction: CAMediaTimingFunctionName.easeInEaseOut.rawValue, removeOnCompletion: false, additive: true)
            self.bottomBackgroundView.layer.animatePosition(from: CGPoint(), to: CGPoint(x: 0.0, y: animateOffset), duration: 0.3, timingFunction: CAMediaTimingFunctionName.easeInEaseOut.rawValue, removeOnCompletion: false, additive: true)
            self.bottomSeparatorLayer.animatePosition(from: CGPoint(), to: CGPoint(x: 0.0, y: animateOffset), duration: 0.3, timingFunction: CAMediaTimingFunctionName.easeInEaseOut.rawValue, removeOnCompletion: false, additive: true)
            if let actionButtonView = self.actionButton.view {
                actionButtonView.layer.animatePosition(from: CGPoint(), to: CGPoint(x: 0.0, y: animateOffset), duration: 0.3, timingFunction: CAMediaTimingFunctionName.easeInEaseOut.rawValue, removeOnCompletion: false, additive: true)
            }
        }
        
        func update(component: ShareWithPeersScreenComponent, availableSize: CGSize, state: EmptyComponentState, environment: Environment<ViewControllerComponentContainer.Environment>, transition: Transition) -> CGSize {
            guard !self.isDismissed else {
                return availableSize
            }
            let animationHint = transition.userData(AnimationHint.self)
            
            var contentTransition = transition
            if let animationHint, animationHint.contentReloaded, !transition.animation.isImmediate {
                contentTransition = .immediate
            }
            
            let environment = environment[ViewControllerComponentContainer.Environment.self].value
            let themeUpdated = self.environment?.theme !== environment.theme
            
            let resetScrolling = self.scrollView.bounds.width != availableSize.width
            
            let sideInset: CGFloat = 0.0
            let containerWidth: CGFloat
            if case .regular = environment.metrics.widthClass {
                containerWidth = 390.0
            } else {
                containerWidth = availableSize.width
            }
            let containerSideInset = floorToScreenPixels((availableSize.width - containerWidth) / 2.0)
            
            if self.component == nil {
                switch component.initialPrivacy.base {
                case .everyone:
                    self.selectedCategories.insert(.everyone)
                case .closeFriends:
                    self.selectedCategories.insert(.closeFriends)
                case .contacts:
                    self.selectedCategories.insert(.contacts)
                case .nobody:
                    self.selectedCategories.insert(.selectedContacts)
                }
                
                var applyState = false
                self.defaultStateValue = component.stateContext.stateValue
                self.selectedPeers = Array(component.stateContext.initialPeerIds)
                
                self.stateDisposable = (component.stateContext.state
                |> deliverOnMainQueue).start(next: { [weak self] stateValue in
                    guard let self else {
                        return
                    }
                    self.defaultStateValue = stateValue
                    if applyState {
                        self.state?.updated(transition: .immediate)
                    }
                })
                applyState = true
            }
            
            self.component = component
            self.state = state
            self.environment = environment
            
            if themeUpdated {
                self.dimView.backgroundColor = UIColor(white: 0.0, alpha: 0.5)
                
                self.scrollView.indicatorStyle = environment.theme.overallDarkAppearance ? .white : .black
                
                self.backgroundView.image = generateImage(CGSize(width: 20.0, height: 20.0), rotatedContext: { size, context in
                    context.clear(CGRect(origin: CGPoint(), size: size))
                    
                    context.setFillColor(environment.theme.list.plainBackgroundColor.cgColor)
                    context.fillEllipse(in: CGRect(origin: CGPoint(), size: size))
                    context.fill(CGRect(origin: CGPoint(x: 0.0, y: size.height * 0.5), size: CGSize(width: size.width, height: size.height * 0.5)))
                })?.stretchableImage(withLeftCapWidth: 10, topCapHeight: 19)
                
                self.navigationBackgroundView.updateColor(color: environment.theme.rootController.navigationBar.blurredBackgroundColor, transition: .immediate)
                self.navigationSeparatorLayer.backgroundColor = environment.theme.rootController.navigationBar.separatorColor.cgColor
                self.textFieldSeparatorLayer.backgroundColor = environment.theme.rootController.navigationBar.separatorColor.cgColor
                
                self.bottomBackgroundView.updateColor(color: environment.theme.rootController.navigationBar.blurredBackgroundColor, transition: .immediate)
                self.bottomSeparatorLayer.backgroundColor = environment.theme.rootController.navigationBar.separatorColor.cgColor
            }
            
            let navigationTextFieldSize: CGSize
            if case .stories = component.stateContext.subject {
                navigationTextFieldSize = .zero
            } else {
                var tokens: [TokenListTextField.Token] = []
                for peerId in self.selectedPeers {
                    guard let stateValue = self.defaultStateValue, let peer = stateValue.peers.first(where: { $0.id == peerId }) else {
                        continue
                    }
                    tokens.append(TokenListTextField.Token(
                        id: AnyHashable(peerId),
                        title: peer.compactDisplayTitle,
                        fixedPosition: nil,
                        content: .peer(peer)
                    ))
                }
                
                let placeholder: String
                switch component.stateContext.subject {
                case .chats:
                    placeholder = "Search Chats"
                default:
                    placeholder = "Search Contacts"
                }
                self.navigationTextField.parentState = state
                navigationTextFieldSize = self.navigationTextField.update(
                    transition: transition,
                    component: AnyComponent(TokenListTextField(
                        externalState: self.navigationTextFieldState,
                        context: component.context,
                        theme: environment.theme,
                        placeholder: placeholder,
                        tokens: tokens,
                        sideInset: sideInset,
                        deleteToken: { [weak self] tokenId in
                            guard let self else {
                                return
                            }
                            if let categoryId = tokenId.base as? CategoryId {
                                self.selectedCategories.remove(categoryId)
                            } else if let peerId = tokenId.base as? EnginePeer.Id {
                                self.selectedPeers.removeAll(where: { $0 == peerId })
                            }
                            if self.selectedCategories.isEmpty {
                                self.selectedCategories.insert(.everyone)
                            }
                            self.state?.updated(transition: Transition(animation: .curve(duration: 0.35, curve: .spring)))
                        }
                    )),
                    environment: {},
                    containerSize: CGSize(width: containerWidth, height: 1000.0)
                )
                
                if !self.navigationTextFieldState.text.isEmpty {
                    if let searchStateContext = self.searchStateContext, searchStateContext.subject == .search(self.navigationTextFieldState.text) {
                    } else {
                        self.searchStateDisposable?.dispose()
                        let searchStateContext = ShareWithPeersScreen.StateContext(context: component.context, subject: .search(self.navigationTextFieldState.text))
                        var applyState = false
                        self.searchStateDisposable = (searchStateContext.ready |> filter { $0 } |> take(1) |> deliverOnMainQueue).start(next: { [weak self] _ in
                            guard let self else {
                                return
                            }
                            self.searchStateContext = searchStateContext
                            if applyState {
                                self.state?.updated(transition: Transition(animation: .none).withUserData(AnimationHint(contentReloaded: true)))
                            }
                        })
                        applyState = true
                    }
                } else if let _ = self.searchStateContext {
                    self.searchStateContext = nil
                    self.searchStateDisposable?.dispose()
                    self.searchStateDisposable = nil
                    
                    contentTransition = contentTransition.withUserData(AnimationHint(contentReloaded: true))
                }
            }
                
            transition.setFrame(view: self.dimView, frame: CGRect(origin: CGPoint(), size: availableSize))
            
            let categoryItemSize = self.categoryTemplateItem.update(
                transition: .immediate,
                component: AnyComponent(CategoryListItemComponent(
                    context: component.context,
                    theme: environment.theme,
                    sideInset: sideInset,
                    title: "Title",
                    color: .blue,
                    iconName: nil,
                    subtitle: nil,
                    selectionState: .editing(isSelected: false, isTinted: false),
                    hasNext: true,
                    action: {},
                    secondaryAction: {}
                )),
                environment: {},
                containerSize: CGSize(width: containerWidth, height: 1000.0)
            )
            let peerItemSize = self.peerTemplateItem.update(
                transition: transition,
                component: AnyComponent(PeerListItemComponent(
                    context: component.context,
                    theme: environment.theme,
                    strings: environment.strings,
                    style: .generic,
                    sideInset: sideInset,
                    title: "Name",
                    peer: nil,
                    subtitle: nil,
                    subtitleAccessory: .none,
                    presence: nil,
                    selectionState: .editing(isSelected: false, isTinted: false),
                    hasNext: true,
                    action: { _ in
                    }
                )),
                environment: {},
                containerSize: CGSize(width: containerWidth, height: 1000.0)
            )
            
            var sections: [ItemLayout.Section] = []
            if let stateValue = self.effectiveStateValue {
                if case .stories = component.stateContext.subject {
                    sections.append(ItemLayout.Section(
                        id: 0,
                        insets: UIEdgeInsets(top: 28.0, left: 0.0, bottom: 0.0, right: 0.0),
                        itemHeight: categoryItemSize.height,
                        itemCount: component.categoryItems.count
                    ))
                } else {
                    sections.append(ItemLayout.Section(
                        id: 1,
                        insets: UIEdgeInsets(top: 28.0, left: 0.0, bottom: 0.0, right: 0.0),
                        itemHeight: peerItemSize.height,
                        itemCount: stateValue.peers.count
                    ))
                }
            }
            
            let containerInset: CGFloat = environment.statusBarHeight + 10.0
            
            var navigationHeight: CGFloat = 56.0
            let navigationSideInset: CGFloat = 16.0
            var navigationButtonsWidth: CGFloat = 0.0
            
            let navigationLeftButtonSize = self.navigationLeftButton.update(
                transition: transition,
                component: AnyComponent(Button(
                    content: AnyComponent(Text(text: "Cancel", font: Font.regular(17.0), color: environment.theme.rootController.navigationBar.accentTextColor)),
                    action: { [weak self] in
                        guard let self, let environment = self.environment, let controller = environment.controller() as? ShareWithPeersScreen else {
                            return
                        }
                        controller.requestDismiss()
                    }
                ).minSize(CGSize(width: navigationHeight, height: navigationHeight))),
                environment: {},
                containerSize: CGSize(width: availableSize.width, height: navigationHeight)
            )
            let navigationLeftButtonFrame = CGRect(origin: CGPoint(x: containerSideInset + navigationSideInset, y: floor((navigationHeight - navigationLeftButtonSize.height) * 0.5)), size: navigationLeftButtonSize)
            if let navigationLeftButtonView = self.navigationLeftButton.view {
                if navigationLeftButtonView.superview == nil {
                    self.navigationContainerView.addSubview(navigationLeftButtonView)
                }
                transition.setFrame(view: navigationLeftButtonView, frame: navigationLeftButtonFrame)
            }
            navigationButtonsWidth += navigationLeftButtonSize.width + navigationSideInset
            
            let title: String
            switch component.stateContext.subject {
            case .stories:
                title = "Share Story"
            case .chats:
                title = "Send as a Message"
            case let .contacts(category):
                switch category {
                case .closeFriends:
                    title = "Close Friends"
                case .contacts:
                    title = "Excluded People"
                case .nobody:
                    title = "Selected Contacts"
                case .everyone:
                    title = ""
                }
            case .search:
                title = ""
            }
            let navigationTitleSize = self.navigationTitle.update(
                transition: .immediate,
                component: AnyComponent(Text(text: title, font: Font.semibold(17.0), color: environment.theme.rootController.navigationBar.primaryTextColor)),
                environment: {},
                containerSize: CGSize(width: containerWidth - navigationButtonsWidth, height: navigationHeight)
            )
            let navigationTitleFrame = CGRect(origin: CGPoint(x: containerSideInset + floor((containerWidth - navigationTitleSize.width) * 0.5), y: floor((navigationHeight - navigationTitleSize.height) * 0.5)), size: navigationTitleSize)
            if let navigationTitleView = self.navigationTitle.view {
                if navigationTitleView.superview == nil {
                    self.navigationContainerView.addSubview(navigationTitleView)
                }
                transition.setPosition(view: navigationTitleView, position: navigationTitleFrame.center)
                navigationTitleView.bounds = CGRect(origin: CGPoint(), size: navigationTitleFrame.size)
            }
            
            let navigationTextFieldFrame = CGRect(origin: CGPoint(x: containerSideInset, y: navigationHeight), size: navigationTextFieldSize)
            if let navigationTextFieldView = self.navigationTextField.view {
                if navigationTextFieldView.superview == nil {
                    self.navigationContainerView.addSubview(navigationTextFieldView)
                    self.navigationContainerView.layer.addSublayer(self.textFieldSeparatorLayer)
                }
                transition.setFrame(view: navigationTextFieldView, frame: navigationTextFieldFrame)
                transition.setFrame(layer: self.textFieldSeparatorLayer, frame: CGRect(origin: CGPoint(x: containerSideInset, y: navigationTextFieldFrame.maxY), size: CGSize(width: navigationTextFieldFrame.width, height: UIScreenPixel)))
            }
            navigationHeight += navigationTextFieldFrame.height
            
            let topInset: CGFloat
            if environment.inputHeight != 0.0 || !self.navigationTextFieldState.text.isEmpty {
                topInset = 0.0
            } else {
                if case .stories = component.stateContext.subject {
                    topInset = max(0.0, availableSize.height - containerInset - 427.0)
                } else {
                    topInset = max(0.0, availableSize.height - containerInset - 600.0)
                }
            }
            
            self.navigationBackgroundView.update(size: CGSize(width: containerWidth, height: navigationHeight), cornerRadius: 10.0, maskedCorners: [.layerMinXMinYCorner, .layerMaxXMinYCorner], transition: transition.containedViewLayoutTransition)
            transition.setFrame(view: self.navigationBackgroundView, frame: CGRect(origin: CGPoint(x: containerSideInset, y: 0.0), size: CGSize(width: containerWidth, height: navigationHeight)))
            
            transition.setFrame(layer: self.navigationSeparatorLayer, frame: CGRect(origin: CGPoint(x: containerSideInset, y: navigationHeight), size: CGSize(width: containerWidth, height: UIScreenPixel)))
            
            let actionButtonTitle: String = "Save Settings"
            let actionButtonSize = self.actionButton.update(
                transition: transition,
                component: AnyComponent(ButtonComponent(
                    background: ButtonComponent.Background(
                        color: environment.theme.list.itemCheckColors.fillColor,
                        foreground: environment.theme.list.itemCheckColors.foregroundColor,
                        pressedColor: environment.theme.list.itemCheckColors.fillColor.withMultipliedAlpha(0.9)
                    ),
                    content: AnyComponentWithIdentity(
                        id: actionButtonTitle,
                        component: AnyComponent(ButtonTextContentComponent(
                            text: actionButtonTitle,
                            badge: 0,
                            textColor: environment.theme.list.itemCheckColors.foregroundColor,
                            badgeBackground: environment.theme.list.itemCheckColors.foregroundColor,
                            badgeForeground: environment.theme.list.itemCheckColors.fillColor
                        ))
                    ),
                    isEnabled: true,
                    displaysProgress: false,
                    action: { [weak self] in
                        guard let self, let component = self.component, let controller = self.environment?.controller() else {
                            return
                        }
                                                
                        let base: EngineStoryPrivacy.Base
                        if self.selectedCategories.contains(.everyone) {
                            base = .everyone
                        } else if self.selectedCategories.contains(.closeFriends) {
                            base = .closeFriends
                        } else if self.selectedCategories.contains(.contacts) {
                            base = .contacts
                        } else if self.selectedCategories.contains(.selectedContacts) {
                            base = .nobody
                        } else {
                            base = .nobody
                        }
                        
                        component.completion(EngineStoryPrivacy(
                            base: base,
                            additionallyIncludePeers: self.selectedPeers
                        ))

                        controller.dismiss()
                    }
                )),
                environment: {},
                containerSize: CGSize(width: containerWidth - navigationSideInset * 2.0, height: 50.0)
            )
            
            var bottomPanelHeight: CGFloat = 0.0
            if environment.inputHeight != 0.0 {
                bottomPanelHeight += environment.inputHeight + 8.0 + actionButtonSize.height
            } else {
                bottomPanelHeight += 10.0 + environment.safeInsets.bottom + actionButtonSize.height
            }
            let actionButtonFrame = CGRect(origin: CGPoint(x: containerSideInset + navigationSideInset, y: availableSize.height - bottomPanelHeight), size: actionButtonSize)
            if let actionButtonView = self.actionButton.view {
                if actionButtonView.superview == nil {
                    self.addSubview(actionButtonView)
                }
                transition.setFrame(view: actionButtonView, frame: actionButtonFrame)
            }
                        
            transition.setFrame(view: self.bottomBackgroundView, frame: CGRect(origin: CGPoint(x: containerSideInset, y: availableSize.height - bottomPanelHeight - 8.0), size: CGSize(width: containerWidth, height: bottomPanelHeight + 8.0)))
            self.bottomBackgroundView.update(size: self.bottomBackgroundView.bounds.size, transition: transition.containedViewLayoutTransition)
            transition.setFrame(layer: self.bottomSeparatorLayer, frame: CGRect(origin: CGPoint(x: containerSideInset + sideInset, y: availableSize.height - bottomPanelHeight - 8.0 - UIScreenPixel), size: CGSize(width: containerWidth, height: UIScreenPixel)))
                        
            let itemContainerSize = CGSize(width: containerWidth, height: availableSize.height)
            let itemLayout = ItemLayout(containerSize: itemContainerSize, containerInset: containerInset, bottomInset: bottomPanelHeight, topInset: topInset, sideInset: sideInset, navigationHeight: navigationHeight, sections: sections)
            let previousItemLayout = self.itemLayout
            self.itemLayout = itemLayout
            
            contentTransition.setFrame(view: self.itemContainerView, frame: CGRect(origin: CGPoint(x: sideInset, y: 0.0), size: CGSize(width: containerWidth, height: itemLayout.contentHeight)))
            
            let scrollContentHeight = max(topInset + itemLayout.contentHeight + containerInset, availableSize.height - containerInset)
            
            transition.setFrame(view: self.scrollContentView, frame: CGRect(origin: CGPoint(x: 0.0, y: topInset + containerInset), size: CGSize(width: containerWidth, height: itemLayout.contentHeight)))
            
            transition.setPosition(view: self.backgroundView, position: CGPoint(x: availableSize.width / 2.0, y: availableSize.height / 2.0))
            transition.setBounds(view: self.backgroundView, bounds: CGRect(origin: CGPoint(x: containerSideInset, y: 0.0), size: CGSize(width: containerWidth, height: availableSize.height)))
            
            let scrollClippingFrame = CGRect(origin: CGPoint(x: sideInset, y: containerInset + 10.0), size: CGSize(width: availableSize.width, height: availableSize.height - 10.0))
            transition.setPosition(view: self.scrollContentClippingView, position: scrollClippingFrame.center)
            transition.setBounds(view: self.scrollContentClippingView, bounds: CGRect(origin: CGPoint(x: scrollClippingFrame.minX, y: scrollClippingFrame.minY), size: scrollClippingFrame.size))
            
            self.ignoreScrolling = true
            transition.setFrame(view: self.scrollView, frame: CGRect(origin: CGPoint(x: containerSideInset, y: 0.0), size: CGSize(width: containerWidth, height: availableSize.height)))
            let contentSize = CGSize(width: containerWidth, height: scrollContentHeight)
            if contentSize != self.scrollView.contentSize {
                self.scrollView.contentSize = contentSize
            }
            let indicatorInsets = UIEdgeInsets(top: max(itemLayout.containerInset, environment.safeInsets.top + navigationHeight), left: 0.0, bottom: environment.safeInsets.bottom, right: 0.0)
            if indicatorInsets != self.scrollView.scrollIndicatorInsets {
                self.scrollView.scrollIndicatorInsets = indicatorInsets
            }
            if resetScrolling {
                self.scrollView.bounds = CGRect(origin: CGPoint(x: 0.0, y: 0.0), size: CGSize(width: containerWidth, height: availableSize.height))
            } else if let previousItemLayout, previousItemLayout.topInset != topInset {
                let topInsetDifference = previousItemLayout.topInset - topInset
                var scrollBounds = self.scrollView.bounds
                scrollBounds.origin.y += -topInsetDifference
                scrollBounds.origin.y = max(0.0, min(scrollBounds.origin.y, self.scrollView.contentSize.height - scrollBounds.height))
                let visibleDifference = self.scrollView.bounds.origin.y - scrollBounds.origin.y
                self.scrollView.bounds = scrollBounds
                transition.animateBoundsOrigin(view: self.scrollView, from: CGPoint(x: 0.0, y: visibleDifference), to: CGPoint(), additive: true)
            }
            self.ignoreScrolling = false
            self.updateScrolling(transition: contentTransition)
             
            return availableSize
        }
    }
    
    func makeView() -> View {
        return View(frame: CGRect())
    }
    
    func update(view: View, availableSize: CGSize, state: EmptyComponentState, environment: Environment<ViewControllerComponentContainer.Environment>, transition: Transition) -> CGSize {
        return view.update(component: self, availableSize: availableSize, state: state, environment: environment, transition: transition)
    }
}

public class ShareWithPeersScreen: ViewControllerComponentContainer {
    public final class State {
        let peers: [EnginePeer]
        let presences: [EnginePeer.Id: EnginePeer.Presence]
        
        fileprivate init(
            peers: [EnginePeer],
            presences: [EnginePeer.Id: EnginePeer.Presence]
        ) {
            self.peers = peers
            self.presences = presences
        }
    }
    
    public final class StateContext {
        public enum Subject: Equatable {
            case stories
            case chats
            case contacts(EngineStoryPrivacy.Base)
            case search(String)
        }
        
        fileprivate var stateValue: State?
        
        public let subject: Subject
        public private(set) var initialPeerIds: Set<EnginePeer.Id> = Set()
        
        private var stateDisposable: Disposable?
        private let stateSubject = Promise<State>()
        public var state: Signal<State, NoError> {
            return self.stateSubject.get()
        }
        private let readySubject = ValuePromise<Bool>(false, ignoreRepeated: true)
        public var ready: Signal<Bool, NoError> {
            return self.readySubject.get()
        }
        
        public init(
            context: AccountContext,
            subject: Subject = .chats,
            initialPeerIds: Set<EnginePeer.Id> = Set()
        ) {
            self.subject = subject
            self.initialPeerIds = initialPeerIds
            
            switch subject {
            case .stories:
                let state = State(peers: [], presences: [:])
                self.stateValue = state
                self.stateSubject.set(.single(state))
                self.readySubject.set(true)
                self.initialPeerIds = initialPeerIds
            case .chats:
                self.stateDisposable = (context.engine.messages.chatList(group: .root, count: 200)
                |> deliverOnMainQueue).start(next: { [weak self] chatList in
                    guard let self else {
                        return
                    }
                    
                    var selectedPeers: [EnginePeer] = []
                    for item in chatList.items.reversed() {
                        if self.initialPeerIds.contains(item.renderedPeer.peerId), let peer = item.renderedPeer.peer {
                            selectedPeers.append(peer)
                        }
                    }
                    
                    var presences: [EnginePeer.Id: EnginePeer.Presence] = [:]
                    for item in chatList.items {
                        presences[item.renderedPeer.peerId] = item.presence
                    }
                    
                    var peers: [EnginePeer] = []
                    peers = chatList.items.filter { !self.initialPeerIds.contains($0.renderedPeer.peerId) && $0.renderedPeer.peerId != context.account.peerId }.reversed().compactMap { $0.renderedPeer.peer }
                    peers.insert(contentsOf: selectedPeers, at: 0)
                    
                    let state = State(
                        peers: peers,
                        presences: presences
                    )
                    self.stateValue = state
                    self.stateSubject.set(.single(state))
                    
                    self.readySubject.set(true)
                })
            case let .contacts(base):
                self.stateDisposable = (context.engine.data.subscribe(
                    TelegramEngine.EngineData.Item.Contacts.List(includePresences: true)
                )
                |> deliverOnMainQueue).start(next: { [weak self] contactList in
                    guard let self else {
                        return
                    }
                    
                    var selectedPeers: [EnginePeer] = []
                    if case .closeFriends = base {
                        for peer in contactList.peers {
                            if case let .user(user) = peer, user.flags.contains(.isCloseFriend) {
                                selectedPeers.append(peer)
                            }
                        }
                        self.initialPeerIds = Set(selectedPeers.map { $0.id })
                    } else {
                        for peer in contactList.peers {
                            if case let .user(user) = peer, initialPeerIds.contains(user.id), !user.isDeleted {
                                selectedPeers.append(peer)
                            }
                        }
                        self.initialPeerIds = initialPeerIds
                    }
                    selectedPeers = selectedPeers.sorted(by: { lhs, rhs in
                        let result = lhs.indexName.isLessThan(other: rhs.indexName, ordering: .firstLast)
                        if result == .orderedSame {
                            return lhs.id < rhs.id
                        } else {
                            return result == .orderedAscending
                        }
                    })
                    
                    var peers: [EnginePeer] = []
                    peers = contactList.peers.filter { !self.initialPeerIds.contains($0.id) && $0.id != context.account.peerId && !$0.isDeleted }.sorted(by: { lhs, rhs in
                        let result = lhs.indexName.isLessThan(other: rhs.indexName, ordering: .firstLast)
                        if result == .orderedSame {
                            return lhs.id < rhs.id
                        } else {
                            return result == .orderedAscending
                        }
                    })
                    peers.insert(contentsOf: selectedPeers, at: 0)
                    
                    let state = State(
                        peers: peers,
                        presences: contactList.presences
                    )
                                        
                    self.stateValue = state
                    self.stateSubject.set(.single(state))
                    
                    self.readySubject.set(true)
                })
            case let .search(query):
                self.stateDisposable = (context.engine.contacts.searchLocalPeers(query: query)
                |> deliverOnMainQueue).start(next: { [weak self] peers in
                    guard let self else {
                        return
                    }
                                        
                    let state = State(
                        peers: peers.compactMap { $0.peer }.filter { peer in
                            if case let .user(user) = peer {
                                if user.id == context.account.peerId {
                                    return false
                                } else if user.botInfo != nil {
                                    return false
                                } else {
                                    return true
                                }
                            } else {
                                return false
                            }
                        },
                        presences: [:]
                    )
                    self.stateValue = state
                    self.stateSubject.set(.single(state))
                    
                    self.readySubject.set(true)
                })
            }
        }
        
        deinit {
            self.stateDisposable?.dispose()
        }
    }
    
    private let context: AccountContext
    
    private var isDismissed: Bool = false
    
    public var dismissed: () -> Void = {}
    
    public init(context: AccountContext, initialPrivacy: EngineStoryPrivacy, timeout: Int, stateContext: StateContext, completion: @escaping (EngineStoryPrivacy) -> Void, editCategory: @escaping (EngineStoryPrivacy) -> Void, secondaryAction: @escaping () -> Void = {}) {
        self.context = context
        
        var categoryItems: [ShareWithPeersScreenComponent.CategoryItem] = []
        if case .stories = stateContext.subject {
            categoryItems.append(ShareWithPeersScreenComponent.CategoryItem(
                id: .everyone,
                title: "Everyone",
                icon: "Chat List/Filters/Channel",
                iconColor: .blue,
                actionTitle: nil
            ))
            
            var contactsSubtitle = "exclude people"
            if initialPrivacy.base == .contacts, initialPrivacy.additionallyIncludePeers.count > 0 {
                if initialPrivacy.additionallyIncludePeers.count == 1 {
                    contactsSubtitle = "except 1 person"
                } else {
                    contactsSubtitle = "except \(initialPrivacy.additionallyIncludePeers.count) people"
                }
            }
            categoryItems.append(ShareWithPeersScreenComponent.CategoryItem(
                id: .contacts,
                title: "Contacts",
                icon: "Chat List/Tabs/IconContacts",
                iconColor: .yellow,
                actionTitle: contactsSubtitle
            ))
            
            categoryItems.append(ShareWithPeersScreenComponent.CategoryItem(
                id: .closeFriends,
                title: "Close Friends",
                icon: "Call/StarHighlighted",
                iconColor: .green,
                actionTitle: "edit list"
            ))
            
            var selectedContactsSubtitle = "choose"
            if initialPrivacy.base == .nobody, initialPrivacy.additionallyIncludePeers.count > 0 {
                if initialPrivacy.additionallyIncludePeers.count == 1 {
                    selectedContactsSubtitle = "1 person"
                } else {
                    selectedContactsSubtitle = "\(initialPrivacy.additionallyIncludePeers.count) people"
                }
            }
            categoryItems.append(ShareWithPeersScreenComponent.CategoryItem(
                id: .selectedContacts,
                title: "Selected Contacts",
                icon: "Chat List/Filters/Group",
                iconColor: .violet,
                actionTitle: selectedContactsSubtitle
            ))
        }
        
        super.init(context: context, component: ShareWithPeersScreenComponent(
            context: context,
            stateContext: stateContext,
            initialPrivacy: initialPrivacy,
            timeout: timeout,
            categoryItems: categoryItems,
            completion: completion,
            editCategory: editCategory,
            secondaryAction: secondaryAction
        ), navigationBarAppearance: .none, theme: .dark)
        
        self.statusBar.statusBarStyle = .Ignore
        self.navigationPresentation = .flatModal
        self.blocksBackgroundWhenInOverlay = true
        self.automaticallyControlPresentationContextLayout = false
        self.lockOrientation = true
    }
    
    required public init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
    }
    
    override public func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
    }
    
    override public func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        self.view.disablesInteractiveModalDismiss = true
        
        if let componentView = self.node.hostView.componentView as? ShareWithPeersScreenComponent.View {
            componentView.animateIn()
        }
    }
    
    func requestDismiss() {
        self.dismissed()
        self.dismiss()
    }
    
    override public func dismiss(completion: (() -> Void)? = nil) {
        if !self.isDismissed {
            self.isDismissed = true
            
            self.view.endEditing(true)
            
            if let componentView = self.node.hostView.componentView as? ShareWithPeersScreenComponent.View {
                componentView.animateOut(completion: { [weak self] in
                    completion?()
                    self?.dismiss(animated: false)
                })
            } else {
                self.dismiss(animated: false)
            }
        }
    }
}
