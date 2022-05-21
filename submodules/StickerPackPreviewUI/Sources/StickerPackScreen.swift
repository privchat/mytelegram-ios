import Foundation
import UIKit
import Display
import AsyncDisplayKit
import Postbox
import TelegramCore
import SwiftSignalKit
import AccountContext
import TelegramPresentationData
import TelegramUIPreferences
import MergeLists
import ShimmerEffect
import ContextUI
import MoreButtonNode
import UndoUI
import ShareController
import PremiumUI

private enum StickerPackPreviewGridEntry: Comparable, Identifiable {
    case sticker(index: Int, stableId: Int, stickerItem: StickerPackItem?, isEmpty: Bool, isPremium: Bool, isLocked: Bool)
    case premiumHeader(index: Int, stableId: Int, count: Int32)
    
    var stableId: Int {
        switch self {
            case let .sticker(_, stableId, _, _, _, _):
                return stableId
            case let .premiumHeader(_, stableId, _):
                return stableId
        }
    }
    
    var index: Int {
        switch self {
            case let .sticker(index, _, _, _, _, _):
                return index
            case let .premiumHeader(index, _, _):
                return index
        }
    }
    
    static func <(lhs: StickerPackPreviewGridEntry, rhs: StickerPackPreviewGridEntry) -> Bool {
        return lhs.index < rhs.index
    }
    
    func item(account: Account, interaction: StickerPackPreviewInteraction, theme: PresentationTheme, strings: PresentationStrings) -> GridItem {
        switch self {
            case let .sticker(_, _, stickerItem, isEmpty, isPremium, isLocked):
                return StickerPackPreviewGridItem(account: account, stickerItem: stickerItem, interaction: interaction, theme: theme, isPremium: isPremium, isLocked: isLocked, isEmpty: isEmpty)
            case let .premiumHeader(_, _, count):
                return StickerPackPreviewPremiumHeaderItem(theme: theme, strings: strings, count: count)
        }
    }
}

private struct StickerPackPreviewGridTransaction {
    let deletions: [Int]
    let insertions: [GridNodeInsertItem]
    let updates: [GridNodeUpdateItem]
    let scrollToItem: GridNodeScrollToItem?
    
    init(previousList: [StickerPackPreviewGridEntry], list: [StickerPackPreviewGridEntry], account: Account, interaction: StickerPackPreviewInteraction, theme: PresentationTheme, strings: PresentationStrings, scrollToItem: GridNodeScrollToItem?) {
         let (deleteIndices, indicesAndItems, updateIndices) = mergeListsStableWithUpdates(leftList: previousList, rightList: list)
        
        self.deletions = deleteIndices
        self.insertions = indicesAndItems.map { GridNodeInsertItem(index: $0.0, item: $0.1.item(account: account, interaction: interaction, theme: theme, strings: strings), previousIndex: $0.2) }
        self.updates = updateIndices.map { GridNodeUpdateItem(index: $0.0, previousIndex: $0.2, item: $0.1.item(account: account, interaction: interaction, theme: theme, strings: strings)) }
        
        self.scrollToItem = scrollToItem
    }
}

private enum StickerPackAction {
    case add
    case remove
}

private enum StickerPackNextAction {
    case navigatedNext
    case dismiss
    case ignored
}

private final class StickerPackContainer: ASDisplayNode {
    let index: Int
    private let context: AccountContext
    private weak var controller: StickerPackScreenImpl?
    private var presentationData: PresentationData
    private let stickerPack: StickerPackReference
    private let decideNextAction: (StickerPackContainer, StickerPackAction) -> StickerPackNextAction
    private let requestDismiss: () -> Void
    private let presentInGlobalOverlay: (ViewController, Any?) -> Void
    private let sendSticker: ((FileMediaReference, ASDisplayNode, CGRect) -> Bool)?
    private let backgroundNode: ASImageNode
    private let gridNode: GridNode
    private let actionAreaBackgroundNode: NavigationBackgroundNode
    private let actionAreaSeparatorNode: ASDisplayNode
    private let buttonNode: HighlightableButtonNode
    private let titleBackgroundnode: NavigationBackgroundNode
    private let titleNode: ImmediateTextNode
    private var titlePlaceholderNode: ShimmerEffectNode?
    private let titleContainer: ASDisplayNode
    private let titleSeparatorNode: ASDisplayNode
    
    private let topContainerNode: ASDisplayNode
    private let cancelButtonNode: HighlightableButtonNode
    private let moreButtonNode: MoreButtonNode
    
    private(set) var validLayout: (ContainerViewLayout, CGRect, CGFloat, UIEdgeInsets)?
    
    private var nextStableId: Int = 1
    private var currentEntries: [StickerPackPreviewGridEntry] = []
    private var enqueuedTransactions: [StickerPackPreviewGridTransaction] = []
    
    private var itemsDisposable: Disposable?
    private(set) var currentStickerPack: (StickerPackCollectionInfo, [StickerPackItem], Bool)?
    private var didReceiveStickerPackResult = false
    
    private let isReadyValue = Promise<Bool>()
    private var didSetReady = false
    var isReady: Signal<Bool, NoError> {
        return self.isReadyValue.get()
    }
    
    var expandProgress: CGFloat = 0.0
    var expandScrollProgress: CGFloat = 0.0
    var modalProgress: CGFloat = 0.0
    var isAnimatingAutoscroll: Bool = false
    let expandProgressUpdated: (StickerPackContainer, ContainedViewLayoutTransition, ContainedViewLayoutTransition) -> Void
    
    private var isDismissed: Bool = false
    
    private let interaction: StickerPackPreviewInteraction
    
    private weak var peekController: PeekController?
    
    init(index: Int, context: AccountContext, presentationData: PresentationData, stickerPack: StickerPackReference, decideNextAction: @escaping (StickerPackContainer, StickerPackAction) -> StickerPackNextAction, requestDismiss: @escaping () -> Void, expandProgressUpdated: @escaping (StickerPackContainer, ContainedViewLayoutTransition, ContainedViewLayoutTransition) -> Void, presentInGlobalOverlay: @escaping (ViewController, Any?) -> Void, sendSticker: ((FileMediaReference, ASDisplayNode, CGRect) -> Bool)?, controller: StickerPackScreenImpl?) {
        self.index = index
        self.context = context
        self.controller = controller
        self.presentationData = presentationData
        self.stickerPack = stickerPack
        self.decideNextAction = decideNextAction
        self.requestDismiss = requestDismiss
        self.presentInGlobalOverlay = presentInGlobalOverlay
        self.expandProgressUpdated = expandProgressUpdated
        self.sendSticker = sendSticker
        
        self.backgroundNode = ASImageNode()
        self.backgroundNode.displaysAsynchronously = true
        self.backgroundNode.displayWithoutProcessing = true
        self.backgroundNode.image = generateStretchableFilledCircleImage(diameter: 20.0, color: self.presentationData.theme.actionSheet.opaqueItemBackgroundColor)
        
        self.gridNode = GridNode()
        self.gridNode.scrollView.alwaysBounceVertical = true
        self.gridNode.scrollView.showsVerticalScrollIndicator = false
        
        self.titleBackgroundnode = NavigationBackgroundNode(color: self.presentationData.theme.rootController.navigationBar.blurredBackgroundColor)
        
        self.actionAreaBackgroundNode = NavigationBackgroundNode(color: self.presentationData.theme.rootController.tabBar.backgroundColor)
        
        self.actionAreaSeparatorNode = ASDisplayNode()
        self.actionAreaSeparatorNode.backgroundColor = self.presentationData.theme.rootController.tabBar.separatorColor
        
        self.buttonNode = HighlightableButtonNode()
        self.titleNode = ImmediateTextNode()
        self.titleContainer = ASDisplayNode()
        self.titleSeparatorNode = ASDisplayNode()
        self.titleSeparatorNode.backgroundColor = self.presentationData.theme.rootController.navigationBar.separatorColor
        
        self.topContainerNode = ASDisplayNode()
        self.cancelButtonNode = HighlightableButtonNode()
        self.moreButtonNode = MoreButtonNode(theme: self.presentationData.theme)
        self.moreButtonNode.iconNode.enqueueState(.more, animated: false)
        
        self.interaction = StickerPackPreviewInteraction(playAnimatedStickers: true)
        
        super.init()
        
        self.addSubnode(self.backgroundNode)
        self.addSubnode(self.gridNode)
        self.addSubnode(self.actionAreaBackgroundNode)
        self.addSubnode(self.actionAreaSeparatorNode)
        self.addSubnode(self.buttonNode)
        
        self.addSubnode(self.titleBackgroundnode)
        self.titleContainer.addSubnode(self.titleNode)
        self.addSubnode(self.titleContainer)
        self.addSubnode(self.titleSeparatorNode)
        
        self.addSubnode(self.topContainerNode)
        self.topContainerNode.addSubnode(self.cancelButtonNode)
        self.topContainerNode.addSubnode(self.moreButtonNode)
                
        self.gridNode.presentationLayoutUpdated = { [weak self] presentationLayout, transition in
            self?.gridPresentationLayoutUpdated(presentationLayout, transition: transition)
        }
        
        self.gridNode.interactiveScrollingEnded = { [weak self] in
            guard let strongSelf = self, !strongSelf.isDismissed else {
                return
            }
            let contentOffset = strongSelf.gridNode.scrollView.contentOffset
            let insets = strongSelf.gridNode.scrollView.contentInset
            
            if contentOffset.y <= -insets.top - 30.0 {
                strongSelf.isDismissed = true
                DispatchQueue.main.async {
                    self?.requestDismiss()
                }
            }
        }
        
//        self.gridNode.visibleContentOffsetChanged = { [weak self] offset in
//            guard let strongSelf = self else {
//                return
//            }
//            
//        }
        
        self.gridNode.interactiveScrollingWillBeEnded = { [weak self] contentOffset, velocity, targetOffset -> CGPoint in
            guard let strongSelf = self, !strongSelf.isDismissed else {
                return targetOffset
            }
            
            let insets = strongSelf.gridNode.scrollView.contentInset
            var modalProgress: CGFloat = 0.0
            
            var updatedOffset = targetOffset
            var resetOffset = false
            
            if targetOffset.y < 0.0 && targetOffset.y >= -insets.top {
                if contentOffset.y > 0.0 {
                    updatedOffset = CGPoint(x: 0.0, y: 0.0)
                    modalProgress = 1.0
                } else {
                    if targetOffset.y > -insets.top / 2.0 || velocity.y <= -100.0 {
                        modalProgress = 1.0
                        resetOffset = true
                    } else {
                        modalProgress = 0.0
                        if contentOffset.y > -insets.top {
                            resetOffset = true
                        }
                    }
                }
            } else if targetOffset.y >= 0.0 {
                modalProgress = 1.0
            }
            
            if abs(strongSelf.modalProgress - modalProgress) > CGFloat.ulpOfOne {
                if contentOffset.y > 0.0 && targetOffset.y > 0.0 {
                } else {
                    resetOffset = true
                }
                strongSelf.modalProgress = modalProgress
                strongSelf.expandProgressUpdated(strongSelf, .animated(duration: 0.4, curve: .spring), .immediate)
            }
            
            if resetOffset {
                let offset: CGPoint
                let isVelocityAligned: Bool
                if modalProgress.isZero {
                    offset = CGPoint(x: 0.0, y: -insets.top)
                    isVelocityAligned = velocity.y < 0.0
                } else {
                    offset = CGPoint(x: 0.0, y: 0.0)
                    isVelocityAligned = velocity.y > 0.0
                }
                
                DispatchQueue.main.async {
                    let duration: Double
                    if isVelocityAligned {
                        let minVelocity: CGFloat = 400.0
                        let maxVelocity: CGFloat = 1000.0
                        let clippedVelocity = max(minVelocity, min(maxVelocity, abs(velocity.y * 500.0)))
                        
                        let distance = abs(offset.y - contentOffset.y)
                        duration = Double(distance / clippedVelocity)
                    } else {
                        duration = 0.5
                    }
                    
                    strongSelf.isAnimatingAutoscroll = true
                    strongSelf.gridNode.autoscroll(toOffset: offset, duration: duration)
                    strongSelf.isAnimatingAutoscroll = false
                }
                updatedOffset = contentOffset
            }
            
            return updatedOffset
        }
        
        self.itemsDisposable = combineLatest(queue: Queue.mainQueue(), context.engine.stickers.loadedStickerPack(reference: stickerPack, forceActualized: false), context.engine.data.get(TelegramEngine.EngineData.Item.Peer.Peer(id: context.account.peerId))).start(next: { [weak self] contents, peer in
            guard let strongSelf = self else {
                return
            }
            var hasPremium = false
            if let peer = peer, peer.isPremium {
                hasPremium = true
            }
            strongSelf.updateStickerPackContents(contents, hasPremium: hasPremium)
        })
        
        self.buttonNode.addTarget(self, action: #selector(self.buttonPressed), forControlEvents: .touchUpInside)
        self.buttonNode.highligthedChanged = { [weak self] highlighted in
            if let strongSelf = self {
                if highlighted {
                    strongSelf.buttonNode.layer.removeAnimation(forKey: "opacity")
                    strongSelf.buttonNode.alpha = 0.8
                } else {
                    strongSelf.buttonNode.alpha = 1.0
                    strongSelf.buttonNode.layer.animateAlpha(from: 0.8, to: 1.0, duration: 0.3)
                }
            }
        }
        
        self.cancelButtonNode.setTitle(self.presentationData.strings.Common_Cancel, with: Font.regular(17.0), with: self.presentationData.theme.actionSheet.controlAccentColor, for: .normal)
        self.cancelButtonNode.addTarget(self, action: #selector(self.cancelPressed), forControlEvents: .touchUpInside)
        
        self.moreButtonNode.action = { [weak self] _, gesture in
            if let strongSelf = self {
                strongSelf.morePressed(node: strongSelf.moreButtonNode.contextSourceNode, gesture: gesture)
            }
        }
    }
    
    deinit {
        self.itemsDisposable?.dispose()
    }
    
    override func didLoad() {
        super.didLoad()
        
        self.gridNode.view.addGestureRecognizer(PeekControllerGestureRecognizer(contentAtPoint: { [weak self] point -> Signal<(ASDisplayNode, PeekControllerContent)?, NoError>? in
            if let strongSelf = self {
                if let itemNode = strongSelf.gridNode.itemNodeAtPoint(point) as? StickerPackPreviewGridItemNode, let item = itemNode.stickerPackItem {
                    let accountPeerId = strongSelf.context.account.peerId
                    return strongSelf.context.account.postbox.transaction { transaction -> (Bool, Bool) in
                        let isStarred = getIsStickerSaved(transaction: transaction, fileId: item.file.fileId)
                        var hasPremium = false
                        if let peer = transaction.getPeer(accountPeerId) as? TelegramUser, peer.isPremium {
                            hasPremium = true
                        }
                        return (isStarred, hasPremium)
                    }
                    |> deliverOnMainQueue
                    |> map { isStarred, hasPremium -> (ASDisplayNode, PeekControllerContent)? in
                        if let strongSelf = self {
                            var menuItems: [ContextMenuItem] = []
                            if let (info, _, _) = strongSelf.currentStickerPack, info.id.namespace == Namespaces.ItemCollection.CloudStickerPacks {
                                if strongSelf.sendSticker != nil {
                                    menuItems.append(.action(ContextMenuActionItem(text: strongSelf.presentationData.strings.StickerPack_Send, icon: { theme in generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Resend"), color: theme.contextMenu.primaryColor) }, action: { _, f in
                                        if let strongSelf = self, let peekController = strongSelf.peekController {
                                            if let animationNode = (peekController.contentNode as? StickerPreviewPeekContentNode)?.animationNode {
                                                let _ = strongSelf.sendSticker?(.standalone(media: item.file), animationNode, animationNode.bounds)
                                            } else if let imageNode = (peekController.contentNode as? StickerPreviewPeekContentNode)?.imageNode {
                                                let _ = strongSelf.sendSticker?(.standalone(media: item.file), imageNode, imageNode.bounds)
                                            }
                                        }
                                        f(.default)
                                    })))
                                }
                                menuItems.append(.action(ContextMenuActionItem(text: isStarred ? strongSelf.presentationData.strings.Stickers_RemoveFromFavorites : strongSelf.presentationData.strings.Stickers_AddToFavorites, icon: { theme in generateTintedImage(image: isStarred ? UIImage(bundleImageName: "Chat/Context Menu/Unfave") : UIImage(bundleImageName: "Chat/Context Menu/Fave"), color: theme.contextMenu.primaryColor) }, action: { [weak self] _, f in
                                    f(.default)
                                    
                                    if let strongSelf = self {
                                        let _ = strongSelf.context.engine.stickers.toggleStickerSaved(file: item.file, saved: !isStarred).start(next: { _ in
                                            
                                        })
                                    }
                                })))
                            }
                            return (itemNode, StickerPreviewPeekContent(account: strongSelf.context.account, theme: strongSelf.presentationData.theme, strings: strongSelf.presentationData.strings, item: .pack(item), isLocked: item.file.isPremiumSticker && !hasPremium, menu: menuItems, openPremiumIntro: { [weak self] in
                                guard let strongSelf = self else {
                                    return
                                }
                                let controller = PremiumIntroScreen(context: strongSelf.context, source: .stickers)
                                let navigationController = strongSelf.controller?.parentNavigationController
                                strongSelf.controller?.dismiss(animated: false, completion: nil)
                                navigationController?.pushViewController(controller)
                            }))
                        } else {
                            return nil
                        }
                    }
                }
            }
            return nil
        }, present: { [weak self] content, sourceNode in
            if let strongSelf = self {
                let controller = PeekController(presentationData: strongSelf.presentationData, content: content, sourceNode: {
                    return sourceNode
                })
                strongSelf.peekController = controller
                strongSelf.presentInGlobalOverlay(controller, nil)
                return controller
            }
            return nil
        }, updateContent: { [weak self] content in
            if let strongSelf = self {
                var item: StickerPreviewPeekItem?
                if let content = content as? StickerPreviewPeekContent {
                    item = content.item
                }
                strongSelf.updatePreviewingItem(item: item, animated: true)
            }
        }, activateBySingleTap: true))
    }
    
    func updatePresentationData(_ presentationData: PresentationData) {
        self.presentationData = presentationData
        
        self.backgroundNode.image = generateStretchableFilledCircleImage(diameter: 20.0, color: self.presentationData.theme.actionSheet.opaqueItemBackgroundColor)
        
        self.titleBackgroundnode.updateColor(color: self.presentationData.theme.rootController.navigationBar.blurredBackgroundColor, transition: .immediate)
        self.actionAreaBackgroundNode.updateColor(color: self.presentationData.theme.rootController.tabBar.backgroundColor, transition: .immediate)
        self.actionAreaSeparatorNode.backgroundColor = self.presentationData.theme.rootController.tabBar.separatorColor
        self.titleSeparatorNode.backgroundColor = self.presentationData.theme.rootController.navigationBar.separatorColor
        
        self.cancelButtonNode.setTitle(self.presentationData.strings.Common_Cancel, with: Font.regular(17.0), with: self.presentationData.theme.actionSheet.controlAccentColor, for: .normal)
        self.moreButtonNode.theme = self.presentationData.theme
        
        if let currentContents = self.currentContents {
            let buttonColor: UIColor
            switch currentContents {
                case .fetching:
                    buttonColor = self.presentationData.theme.list.itemDisabledTextColor
                case .none:
                    buttonColor = self.presentationData.theme.list.itemAccentColor
                case let .result(_, _, installed):
                    buttonColor = installed ? self.presentationData.theme.list.itemDestructiveColor : self.presentationData.theme.list.itemAccentColor
            }
            self.buttonNode.setTitle(self.buttonNode.attributedTitle(for: .normal)?.string ?? "", with: Font.semibold(17.0), with: buttonColor, for: .normal)
        }
                
        if !self.currentEntries.isEmpty {
            let transaction = StickerPackPreviewGridTransaction(previousList: self.currentEntries, list: self.currentEntries, account: self.context.account, interaction: self.interaction, theme: self.presentationData.theme, strings: self.presentationData.strings, scrollToItem: nil)
            self.enqueueTransaction(transaction)
        }
        
        self.titleNode.attributedText = NSAttributedString(string: self.titleNode.attributedText?.string ?? "", font: Font.semibold(17.0), textColor: self.presentationData.theme.actionSheet.primaryTextColor)
        if let (layout, _, _, _) = self.validLayout {
            let _ = self.titleNode.updateLayout(CGSize(width: layout.size.width - 12.0 * 2.0, height: .greatestFiniteMagnitude))
            self.updateLayout(layout: layout, transition: .immediate)
        }
    }
    
    @objc private func morePressed(node: ContextReferenceContentNode, gesture: ContextGesture?) {
        guard let controller = self.controller, let (info, _, _) = self.currentStickerPack else {
            return
        }
        let strings = self.presentationData.strings

        let link = "https://t.me/addstickers/\(info.shortName)"
           
        var items: [ContextMenuItem] = []
        items.append(.action(ContextMenuActionItem(text: strings.StickerPack_Share, icon: { theme in
            return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Share"), color: theme.contextMenu.primaryColor)
        }, action: { [weak self] _, f in
            f(.default)
            
            if let strongSelf = self {
                let parentNavigationController = strongSelf.controller?.parentNavigationController
                let shareController = ShareController(context: strongSelf.context, subject: .url(link))
                shareController.actionCompleted = { [weak parentNavigationController] in
                    if let parentNavigationController = parentNavigationController, let controller = parentNavigationController.topViewController as? ViewController {
                        let presentationData = strongSelf.context.sharedContext.currentPresentationData.with { $0 }
                        controller.present(UndoOverlayController(presentationData: presentationData, content: .linkCopied(text: presentationData.strings.Conversation_LinkCopied), elevatedLayout: false, animateInAsReplacement: false, action: { _ in return false }), in: .window(.root))
                    }
                }
                strongSelf.controller?.present(shareController, in: .window(.root))
            }
        })))
        items.append(.action(ContextMenuActionItem(text: strings.StickerPack_CopyLink, icon: { theme in
            return generateTintedImage(image: UIImage(bundleImageName: "Chat/Context Menu/Link"), color: theme.contextMenu.primaryColor)
        }, action: {  [weak self] _, f in
            f(.default)
            
            UIPasteboard.general.string = link
            
            if let strongSelf = self {
                let presentationData = strongSelf.context.sharedContext.currentPresentationData.with { $0 }
                strongSelf.controller?.present(UndoOverlayController(presentationData: presentationData, content: .linkCopied(text: presentationData.strings.Conversation_LinkCopied), elevatedLayout: false, animateInAsReplacement: false, action: { _ in return false }), in: .window(.root))
            }
        })))
        
        let contextController = ContextController(account: self.context.account, presentationData: self.presentationData, source: .reference(StickerPackContextReferenceContentSource(controller: controller, sourceNode: node)), items: .single(ContextController.Items(content: .list(items))), gesture: gesture)
        self.presentInGlobalOverlay(contextController, nil)
    }
    
    @objc func cancelPressed() {
        self.requestDismiss()
    }
    
    @objc func buttonPressed() {
        guard let (info, items, installed) = self.currentStickerPack else {
            self.requestDismiss()
            return
        }
        
        let _ = (self.context.sharedContext.accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.stickerSettings])
        |> take(1)
        |> deliverOnMainQueue).start(next: { [weak self] sharedData in
            guard let strongSelf = self else {
                return
            }
            
            var dismissed = false
            switch strongSelf.decideNextAction(strongSelf, installed ? .remove : .add) {
                case .dismiss:
                    strongSelf.requestDismiss()
                    dismissed = true
                case .navigatedNext, .ignored:
                    strongSelf.updateStickerPackContents(.result(info: info, items: items, installed: !installed), hasPremium: false)
            }
            
            let actionPerformed = strongSelf.controller?.actionPerformed
            if installed {
                let _ = (strongSelf.context.engine.stickers.removeStickerPackInteractively(id: info.id, option: .delete)
                |> deliverOnMainQueue).start(next: { indexAndItems in
                    guard let (positionInList, _) = indexAndItems else {
                        return
                    }
                    if dismissed {
                        actionPerformed?(info, items, .remove(positionInList: positionInList))
                    }
                })
            } else {
                let _ = strongSelf.context.engine.stickers.addStickerPackInteractively(info: info, items: items).start()
                if dismissed {
                    actionPerformed?(info, items, .add)
                }
            }
        })
    }
    
    private var currentContents: LoadedStickerPack?
    private func updateStickerPackContents(_ contents: LoadedStickerPack, hasPremium: Bool) {
        self.currentContents = contents
        self.didReceiveStickerPackResult = true
        
        var entries: [StickerPackPreviewGridEntry] = []
        
        var updateLayout = false
        
        var scrollToItem: GridNodeScrollToItem?
        
        switch contents {
        case .fetching:
            entries = []
            self.buttonNode.setTitle(self.presentationData.strings.Channel_NotificationLoading, with: Font.semibold(17.0), with: self.presentationData.theme.list.itemDisabledTextColor, for: .normal)
            self.buttonNode.setBackgroundImage(nil, for: [])
            
            for _ in 0 ..< 16 {
                var stableId: Int?
                inner: for entry in self.currentEntries {
                    if case let .sticker(index, currentStableId, stickerItem, _, _, _) = entry, stickerItem == nil, index == entries.count {
                        stableId = currentStableId
                        break inner
                    }
                }
                
                let resolvedStableId: Int
                if let stableId = stableId {
                    resolvedStableId = stableId
                } else {
                    resolvedStableId = self.nextStableId
                    self.nextStableId += 1
                }
                
                self.nextStableId += 1
                entries.append(.sticker(index: entries.count, stableId: resolvedStableId, stickerItem: nil, isEmpty: false, isPremium: false, isLocked: false))
            }
            if self.titlePlaceholderNode == nil {
                let titlePlaceholderNode = ShimmerEffectNode()
                self.titlePlaceholderNode = titlePlaceholderNode
                self.titleContainer.addSubnode(titlePlaceholderNode)
            }
        case .none:
            entries = []
            self.buttonNode.setTitle(self.presentationData.strings.Common_Close, with: Font.semibold(17.0), with: self.presentationData.theme.list.itemAccentColor, for: .normal)
            self.buttonNode.setBackgroundImage(nil, for: [])
            
            for _ in 0 ..< 16 {
                let resolvedStableId = self.nextStableId
                self.nextStableId += 1
                entries.append(.sticker(index: entries.count, stableId: resolvedStableId, stickerItem: nil, isEmpty: true, isPremium: false, isLocked: false))
            }
            if let titlePlaceholderNode = self.titlePlaceholderNode {
                self.titlePlaceholderNode = nil
                titlePlaceholderNode.removeFromSupernode()
            }
        case let .result(info, items, installed):
            if !items.isEmpty && self.currentStickerPack == nil {
                if let _ = self.validLayout, abs(self.expandScrollProgress - 1.0) < .ulpOfOne {
                    scrollToItem = GridNodeScrollToItem(index: 0, position: .top(0.0), transition: .immediate, directionHint: .up, adjustForSection: false)
                }
            }
            
            self.currentStickerPack = (info, items, installed)
            
            if installed {
                let text: String
                if info.id.namespace == Namespaces.ItemCollection.CloudStickerPacks {
                    text = self.presentationData.strings.StickerPack_RemoveStickerCount(info.count)
                } else {
                    text = self.presentationData.strings.StickerPack_RemoveMaskCount(info.count)
                }
                self.buttonNode.setTitle(text, with: Font.regular(17.0), with: self.presentationData.theme.list.itemDestructiveColor, for: .normal)
                self.buttonNode.setBackgroundImage(nil, for: [])
            } else {
                let text: String
                if info.id.namespace == Namespaces.ItemCollection.CloudStickerPacks {
                    text = self.presentationData.strings.StickerPack_AddStickerCount(info.count)
                } else {
                    text = self.presentationData.strings.StickerPack_AddMaskCount(info.count)
                }
                self.buttonNode.setTitle(text, with: Font.semibold(17.0), with: self.presentationData.theme.list.itemCheckColors.foregroundColor, for: .normal)
                let roundedAccentBackground = generateImage(CGSize(width: 22.0, height: 22.0), rotatedContext: { size, context in
                    context.clear(CGRect(origin: CGPoint(), size: size))
                    context.setFillColor(self.presentationData.theme.list.itemCheckColors.fillColor.cgColor)
                    context.fillEllipse(in: CGRect(origin: CGPoint(), size: CGSize(width: size.width, height: size.height)))
                })?.stretchableImage(withLeftCapWidth: 11, topCapHeight: 11)
                self.buttonNode.setBackgroundImage(roundedAccentBackground, for: [])
            }
            
            if self.titleNode.attributedText == nil {
                if let titlePlaceholderNode = self.titlePlaceholderNode {
                    self.titlePlaceholderNode = nil
                    titlePlaceholderNode.removeFromSupernode()
                }
            }
            
            self.titleNode.attributedText = NSAttributedString(string: info.title, font: Font.semibold(17.0), textColor: self.presentationData.theme.actionSheet.primaryTextColor)
            updateLayout = true
            
            var generalItems: [StickerPackItem] = []
            var premiumItems: [StickerPackItem] = []
            
            for item in items {
                if item.file.isPremiumSticker {
                    premiumItems.append(item)
                } else {
                    generalItems.append(item)
                }
            }
            
            let addItem: (StickerPackItem, Bool, Bool) -> Void = { item, isPremium, isLocked in
                var stableId: Int?
                inner: for entry in self.currentEntries {
                    if case let .sticker(_, currentStableId, stickerItem, _, _, _) = entry, let stickerItem = stickerItem, stickerItem.file.fileId == item.file.fileId {
                        stableId = currentStableId
                        break inner
                    }
                }
                let resolvedStableId: Int
                if let stableId = stableId {
                    resolvedStableId = stableId
                } else {
                    resolvedStableId = self.nextStableId
                    self.nextStableId += 1
                }
                entries.append(.sticker(index: entries.count, stableId: resolvedStableId, stickerItem: item, isEmpty: false, isPremium: isPremium, isLocked: isLocked))
            }
            
            for item in generalItems {
                addItem(item, false, false)
            }
            
            if !premiumItems.isEmpty {
                for item in premiumItems {
                    addItem(item, true, !hasPremium)
                }
            }
        }
        let previousEntries = self.currentEntries
        self.currentEntries = entries
        
        if let titlePlaceholderNode = self.titlePlaceholderNode {
            let fakeTitleSize = CGSize(width: 160.0, height: 22.0)
            let titlePlaceholderFrame = CGRect(origin: CGPoint(x: floor((-fakeTitleSize.width) / 2.0), y: floor((-fakeTitleSize.height) / 2.0)), size: fakeTitleSize)
            titlePlaceholderNode.frame = titlePlaceholderFrame
            let theme = self.presentationData.theme
            titlePlaceholderNode.update(backgroundColor: theme.list.itemBlocksBackgroundColor, foregroundColor: theme.list.mediaPlaceholderColor, shimmeringColor: theme.list.itemBlocksBackgroundColor.withAlphaComponent(0.4), shapes: [.roundedRect(rect: CGRect(origin: CGPoint(), size: titlePlaceholderFrame.size), cornerRadius: 4.0)], size: titlePlaceholderFrame.size)
            updateLayout = true
        }
        
        if updateLayout, let (layout, _, _, _) = self.validLayout {
            let titleSize = self.titleNode.updateLayout(CGSize(width: layout.size.width - 12.0 * 2.0, height: .greatestFiniteMagnitude))
            self.titleNode.frame = CGRect(origin: CGPoint(x: floor((-titleSize.width) / 2.0), y: floor((-titleSize.height) / 2.0)), size: titleSize)
            
            let cancelSize = self.cancelButtonNode.measure(CGSize(width: layout.size.width, height: .greatestFiniteMagnitude))
            self.cancelButtonNode.frame = CGRect(origin: CGPoint(x: layout.safeInsets.left + 16.0, y: 18.0), size: cancelSize)
            
            self.moreButtonNode.frame = CGRect(origin: CGPoint(x: layout.size.width - layout.safeInsets.right - 46.0, y: 5.0), size: CGSize(width: 44.0, height: 44.0))
            
            self.updateLayout(layout: layout, transition: .immediate)
        }
        
        let transaction = StickerPackPreviewGridTransaction(previousList: previousEntries, list: entries, account: self.context.account, interaction: self.interaction, theme: self.presentationData.theme, strings: self.presentationData.strings, scrollToItem: scrollToItem)
        self.enqueueTransaction(transaction)
    }
    
    var topContentInset: CGFloat {
        guard let (_, gridFrame, titleAreaInset, gridInsets) = self.validLayout else {
            return 0.0
        }
        return min(self.backgroundNode.frame.minY, gridFrame.minY + gridInsets.top - titleAreaInset)
    }
    
    func syncExpandProgress(expandScrollProgress: CGFloat, expandProgress: CGFloat, modalProgress: CGFloat, transition: ContainedViewLayoutTransition) {
        guard let (_, _, _, gridInsets) = self.validLayout else {
            return
        }
        
        let contentOffset = (1.0 - expandScrollProgress) * (-gridInsets.top)
        if case let .animated(duration, _) = transition {
            self.gridNode.autoscroll(toOffset: CGPoint(x: 0.0, y: contentOffset), duration: duration)
        } else {
            if expandScrollProgress.isZero {
            }
            self.gridNode.scrollView.setContentOffset(CGPoint(x: 0.0, y: contentOffset), animated: false)
        }
        
        self.expandScrollProgress = expandScrollProgress
        self.expandProgress = expandProgress
        self.modalProgress = modalProgress
    }
    
    func updateLayout(layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        var insets = layout.insets(options: [.statusBar])
        if case .compact = layout.metrics.widthClass, layout.size.width > layout.size.height {
            insets.top = 0.0
        } else {
            insets.top += 10.0
        }
        
        var buttonHeight: CGFloat = 50.0
        var actionAreaTopInset: CGFloat = 8.0
        var actionAreaBottomInset: CGFloat = 16.0
        if let (_, _, isInstalled) = self.currentStickerPack, isInstalled {
            buttonHeight = 42.0
            actionAreaTopInset = 1.0
            actionAreaBottomInset = 2.0
        }
        
        let buttonSideInset: CGFloat = 16.0
        let titleAreaInset: CGFloat = 56.0
        
        var actionAreaHeight: CGFloat = buttonHeight
        actionAreaHeight += insets.bottom + actionAreaBottomInset
        
        transition.updateFrame(node: self.buttonNode, frame: CGRect(origin: CGPoint(x: layout.safeInsets.left + buttonSideInset, y: layout.size.height - actionAreaHeight + actionAreaTopInset), size: CGSize(width: layout.size.width - buttonSideInset * 2.0 - layout.safeInsets.left - layout.safeInsets.right, height: buttonHeight)))

        transition.updateFrame(node: self.actionAreaBackgroundNode, frame: CGRect(origin: CGPoint(x: 0.0, y: layout.size.height - actionAreaHeight), size: CGSize(width: layout.size.width, height: actionAreaHeight)))
        self.actionAreaBackgroundNode.update(size: CGSize(width: layout.size.width, height: actionAreaHeight), transition: .immediate)
        transition.updateFrame(node: self.actionAreaSeparatorNode, frame: CGRect(origin: CGPoint(x: 0.0, y: layout.size.height - actionAreaHeight), size: CGSize(width: layout.size.width, height: UIScreenPixel)))
        
        let gridFrame = CGRect(origin: CGPoint(x: 0.0, y: insets.top + titleAreaInset), size: CGSize(width: layout.size.width, height: layout.size.height - insets.top - titleAreaInset))
        
        let itemsPerRow = 5
        let fillingWidth = horizontalContainerFillingSizeForLayout(layout: layout, sideInset: 0.0)
        let itemWidth = floor(fillingWidth / CGFloat(itemsPerRow))
        let gridLeftInset = floor((layout.size.width - fillingWidth) / 2.0)
        let contentHeight: CGFloat
        if let (_, items, _) = self.currentStickerPack {
            let rowCount = items.count / itemsPerRow + ((items.count % itemsPerRow) == 0 ? 0 : 1)
            contentHeight = itemWidth * CGFloat(rowCount)
        } else {
            contentHeight = gridFrame.size.height
        }
        
        let initialRevealedRowCount: CGFloat = 4.5
        
        let topInset = max(0.0, layout.size.height - floor(initialRevealedRowCount * itemWidth) - insets.top - actionAreaHeight - titleAreaInset)
        
        let additionalGridBottomInset = max(0.0, gridFrame.size.height - actionAreaHeight - contentHeight)
        
        let gridInsets = UIEdgeInsets(top: insets.top + topInset, left: gridLeftInset, bottom: actionAreaHeight + additionalGridBottomInset, right: layout.size.width - fillingWidth - gridLeftInset)
        
        let firstTime = self.validLayout == nil
        self.validLayout = (layout, gridFrame, titleAreaInset, gridInsets)
        
        transition.updateFrame(node: self.gridNode, frame: gridFrame)
        self.gridNode.transaction(GridNodeTransaction(deleteItems: [], insertItems: [], updateItems: [], scrollToItem: nil, updateLayout: GridNodeUpdateLayout(layout: GridNodeLayout(size: gridFrame.size, insets: gridInsets, scrollIndicatorInsets: nil, preloadSize: 200.0, type: .fixed(itemSize: CGSize(width: itemWidth, height: itemWidth), fillWidth: nil, lineSpacing: 0.0, itemSpacing: nil)), transition: transition), itemTransition: .immediate, stationaryItems: .none, updateFirstIndexInSectionOffset: nil, updateOpaqueState: nil, synchronousLoads: false), completion: { [weak self] _ in
            guard let strongSelf = self else {
                return
            }
            if strongSelf.didReceiveStickerPackResult {
                if !strongSelf.didSetReady {
                    strongSelf.didSetReady = true
                    strongSelf.isReadyValue.set(.single(true))
                }
            }
        })
        
        if let titlePlaceholderNode = self.titlePlaceholderNode {
            titlePlaceholderNode.updateAbsoluteRect(titlePlaceholderNode.frame.offsetBy(dx: self.titleContainer.frame.minX, dy: self.titleContainer.frame.minY - gridInsets.top - gridFrame.minY), within: gridFrame.size)
        }
        
        if firstTime {
            while !self.enqueuedTransactions.isEmpty {
                self.dequeueTransaction()
            }
        }
    }
    
    private func gridPresentationLayoutUpdated(_ presentationLayout: GridNodeCurrentPresentationLayout, transition: ContainedViewLayoutTransition) {
        guard let (layout, gridFrame, titleAreaInset, gridInsets) = self.validLayout else {
            return
        }
        
        let minBackgroundY = gridFrame.minY - titleAreaInset
        let unclippedBackgroundY = gridFrame.minY - presentationLayout.contentOffset.y - titleAreaInset
        
        let offsetFromInitialPosition = presentationLayout.contentOffset.y + gridInsets.top
        let expandHeight: CGFloat = 100.0
        let expandProgress = max(0.0, min(1.0, offsetFromInitialPosition / expandHeight))
        let expandScrollProgress = 1.0 - max(0.0, min(1.0, presentationLayout.contentOffset.y / (-gridInsets.top)))
        let modalProgress = max(0.0, min(1.0, expandScrollProgress))
        
        let expandProgressTransition = transition
        var expandUpdated = false
        
        if abs(self.expandScrollProgress - expandScrollProgress) > CGFloat.ulpOfOne {
            self.expandScrollProgress = expandScrollProgress
            expandUpdated = true
        }
        
        if abs(self.expandProgress - expandProgress) > CGFloat.ulpOfOne {
            self.expandProgress = expandProgress
            expandUpdated = true
        }
        
        if abs(self.modalProgress - modalProgress) > CGFloat.ulpOfOne {
            self.modalProgress = modalProgress
            expandUpdated = true
        }
        
        if expandUpdated {
            self.expandProgressUpdated(self, expandProgressTransition, self.isAnimatingAutoscroll ? transition : .immediate)
        }
        
        if !transition.isAnimated {
            self.backgroundNode.layer.removeAllAnimations()
            self.titleContainer.layer.removeAllAnimations()
            self.titleSeparatorNode.layer.removeAllAnimations()
        }
        
        let backgroundFrame = CGRect(origin: CGPoint(x: 0.0, y: max(minBackgroundY, unclippedBackgroundY)), size: CGSize(width: layout.size.width, height: layout.size.height))
        transition.updateFrame(node: self.backgroundNode, frame: backgroundFrame)
        transition.updateFrame(node: self.titleContainer, frame: CGRect(origin: CGPoint(x: backgroundFrame.minX + floor((backgroundFrame.width) / 2.0), y: backgroundFrame.minY + floor((56.0) / 2.0)), size: CGSize()))
        transition.updateFrame(node: self.titleSeparatorNode, frame: CGRect(origin: CGPoint(x: backgroundFrame.minX, y: backgroundFrame.minY + 56.0 - UIScreenPixel), size: CGSize(width: backgroundFrame.width, height: UIScreenPixel)))
                
        transition.updateFrame(node: self.topContainerNode, frame: CGRect(origin: CGPoint(x: backgroundFrame.minX, y: backgroundFrame.minY), size: CGSize(width: backgroundFrame.width, height: 56.0)))
        
        let transition = ContainedViewLayoutTransition.animated(duration: 0.2, curve: .easeInOut)
        transition.updateAlpha(node: self.titleSeparatorNode, alpha: unclippedBackgroundY < minBackgroundY ? 1.0 : 0.0)
    }
    
    private func enqueueTransaction(_ transaction: StickerPackPreviewGridTransaction) {
        self.enqueuedTransactions.append(transaction)
        
        if let _ = self.validLayout {
            self.dequeueTransaction()
        }
    }
    
    private func dequeueTransaction() {
        if self.enqueuedTransactions.isEmpty {
            return
        }
        let transaction = self.enqueuedTransactions.removeFirst()
        
        self.gridNode.transaction(GridNodeTransaction(deleteItems: transaction.deletions, insertItems: transaction.insertions, updateItems: transaction.updates, scrollToItem: transaction.scrollToItem, updateLayout: nil, itemTransition: .immediate, stationaryItems: .none, updateFirstIndexInSectionOffset: nil), completion: { _ in })
    }
    
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if self.bounds.contains(point) {
            if !self.backgroundNode.bounds.contains(self.convert(point, to: self.backgroundNode)) {
                return nil
            }
        }
        
        let result = super.hitTest(point, with: event)
        return result
    }
    
    private func updatePreviewingItem(item: StickerPreviewPeekItem?, animated: Bool) {
        if self.interaction.previewedItem != item {
            self.interaction.previewedItem = item
            
            self.gridNode.forEachItemNode { itemNode in
                if let itemNode = itemNode as? StickerPackPreviewGridItemNode {
                    itemNode.updatePreviewing(animated: animated)
                }
            }
        }
    }
}

private final class StickerPackScreenNode: ViewControllerTracingNode {
    private let context: AccountContext
    private weak var controller: StickerPackScreenImpl?
    private var presentationData: PresentationData
    private let stickerPacks: [StickerPackReference]
    private let modalProgressUpdated: (CGFloat, ContainedViewLayoutTransition) -> Void
    private let dismissed: () -> Void
    private let presentInGlobalOverlay: (ViewController, Any?) -> Void
    private let sendSticker: ((FileMediaReference, ASDisplayNode, CGRect) -> Bool)?
    
    private let dimNode: ASDisplayNode
    private let containerContainingNode: ASDisplayNode
    
    private var containers: [Int: StickerPackContainer] = [:]
    private var selectedStickerPackIndex: Int
    private var relativeToSelectedStickerPackTransition: CGFloat = 0.0
    
    private var validLayout: ContainerViewLayout?
    private var isDismissed: Bool = false
    
    private let _ready = Promise<Bool>()
    var ready: Promise<Bool> {
        return self._ready
    }
    
    init(context: AccountContext, controller: StickerPackScreenImpl, stickerPacks: [StickerPackReference], initialSelectedStickerPackIndex: Int, modalProgressUpdated: @escaping (CGFloat, ContainedViewLayoutTransition) -> Void, dismissed: @escaping () -> Void, presentInGlobalOverlay: @escaping (ViewController, Any?) -> Void, sendSticker: ((FileMediaReference, ASDisplayNode, CGRect) -> Bool)?) {
        self.context = context
        self.controller = controller
        self.presentationData = controller.presentationData
        self.stickerPacks = stickerPacks
        self.selectedStickerPackIndex = initialSelectedStickerPackIndex
        self.modalProgressUpdated = modalProgressUpdated
        self.dismissed = dismissed
        self.presentInGlobalOverlay = presentInGlobalOverlay
        self.sendSticker = sendSticker
        
        self.dimNode = ASDisplayNode()
        self.dimNode.backgroundColor = UIColor(white: 0.0, alpha: 0.25)
        self.dimNode.alpha = 0.0
        
        self.containerContainingNode = ASDisplayNode()
        
        super.init()
        
        self.addSubnode(self.dimNode)
        
        self.addSubnode(self.containerContainingNode)
    }
    
    override func didLoad() {
        super.didLoad()
        
        self.dimNode.view.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(self.dimNodeTapGesture(_:))))
        self.containerContainingNode.view.addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(self.panGesture(_:))))
    }
    
    func updatePresentationData(_ presentationData: PresentationData) {
        for (_, container) in self.containers {
            container.updatePresentationData(presentationData)
        }
    }
    
    func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        let firstTime = self.validLayout == nil
        
        self.validLayout = layout
        
        transition.updateFrame(node: self.dimNode, frame: CGRect(origin: CGPoint(), size: layout.size))
        transition.updateFrame(node: self.containerContainingNode, frame: CGRect(origin: CGPoint(), size: layout.size))
        
        let expandProgress: CGFloat
        if self.stickerPacks.count == 1 {
            expandProgress = 1.0
        } else {
            expandProgress = self.containers[self.selectedStickerPackIndex]?.expandProgress ?? 0.0
        }
        let scaledInset: CGFloat = 12.0
        let scaledDistance: CGFloat = 4.0
        let minScale = (layout.size.width - scaledInset * 2.0) / layout.size.width
        let containerScale = expandProgress * 1.0 + (1.0 - expandProgress) * minScale
        
        let containerVerticalOffset: CGFloat = (1.0 - expandProgress) * scaledInset * 2.0
        
        for i in 0 ..< self.stickerPacks.count {
            let indexOffset = i - self.selectedStickerPackIndex
            var scaledOffset: CGFloat = 0.0
            scaledOffset = -CGFloat(indexOffset) * (1.0 - expandProgress) * (scaledInset * 2.0) + CGFloat(indexOffset) * scaledDistance
            
            if abs(indexOffset) <= 1 {
                let containerTransition: ContainedViewLayoutTransition
                let container: StickerPackContainer
                var wasAdded = false
                if let current = self.containers[i] {
                    containerTransition = transition
                    container = current
                } else {
                    wasAdded = true
                    containerTransition = .immediate
                    let index = i
                    container = StickerPackContainer(index: index, context: context, presentationData: self.presentationData, stickerPack: self.stickerPacks[i], decideNextAction: { [weak self] container, action in
                        guard let strongSelf = self, let layout = strongSelf.validLayout else {
                            return .dismiss
                        }
                        if index == strongSelf.stickerPacks.count - 1 {
                            return .dismiss
                        } else {
                            switch action {
                            case .add:
                                var allAdded = true
                                for _ in index + 1 ..< strongSelf.stickerPacks.count {
                                    if let container = strongSelf.containers[index], let (_, _, installed) = container.currentStickerPack {
                                        if !installed {
                                            allAdded = false
                                        }
                                    } else {
                                        allAdded = false
                                    }
                                }
                                if allAdded {
                                    return .dismiss
                                }
                            case .remove:
                                if strongSelf.stickerPacks.count == 1 {
                                    return .dismiss
                                } else {
                                    return .ignored
                                }
                            }
                        }
                        
                        strongSelf.selectedStickerPackIndex = strongSelf.selectedStickerPackIndex + 1
                        strongSelf.containerLayoutUpdated(layout, transition: .animated(duration: 0.3, curve: .spring))
                        return .navigatedNext
                    }, requestDismiss: { [weak self] in
                        self?.dismiss()
                    }, expandProgressUpdated: { [weak self] container, transition, expandTransition in
                        guard let strongSelf = self, let layout = strongSelf.validLayout else {
                            return
                        }
                        if index == strongSelf.selectedStickerPackIndex, let container = strongSelf.containers[strongSelf.selectedStickerPackIndex] {
                            let modalProgress = container.modalProgress
                            strongSelf.modalProgressUpdated(modalProgress, transition)
                            strongSelf.containerLayoutUpdated(layout, transition: expandTransition)
                            for (_, otherContainer) in strongSelf.containers {
                                if otherContainer !== container {
                                    otherContainer.syncExpandProgress(expandScrollProgress: container.expandScrollProgress, expandProgress: container.expandProgress, modalProgress: container.modalProgress, transition: expandTransition)
                                }
                            }
                        }
                    }, presentInGlobalOverlay: presentInGlobalOverlay,
                    sendSticker: sendSticker, controller: self.controller)
                    self.containerContainingNode.addSubnode(container)
                    self.containers[i] = container
                }
                
                let containerFrame = CGRect(origin: CGPoint(x: CGFloat(indexOffset) * layout.size.width + self.relativeToSelectedStickerPackTransition + scaledOffset, y: containerVerticalOffset), size: layout.size)
                containerTransition.updateFrame(node: container, frame: containerFrame, beginWithCurrentState: true)
                containerTransition.updateSublayerTransformScaleAndOffset(node: container, scale: containerScale, offset: CGPoint(), beginWithCurrentState: true)
                if container.validLayout?.0 != layout {
                    container.updateLayout(layout: layout, transition: containerTransition)
                }
                
                if wasAdded {
                    if let selectedContainer = self.containers[self.selectedStickerPackIndex] {
                        if selectedContainer !== container {
                            container.syncExpandProgress(expandScrollProgress: selectedContainer.expandScrollProgress, expandProgress: selectedContainer.expandProgress, modalProgress: selectedContainer.modalProgress, transition: .immediate)
                        }
                    }
                }
            } else {
                if let container = self.containers[i] {
                    container.removeFromSupernode()
                    self.containers.removeValue(forKey: i)
                }
            }
        }
        
        if firstTime {
            if !self.containers.isEmpty {
                self._ready.set(combineLatest(self.containers.map { (_, container) in container.isReady })
                |> map { values -> Bool in
                    for value in values {
                        if !value {
                            return false
                        }
                    }
                    return true
                })
            } else {
                self._ready.set(.single(true))
            }
        }
    }
    
    @objc private func panGesture(_ recognizer: UIPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            break
        case .changed:
            let translation = recognizer.translation(in: self.view)
            self.relativeToSelectedStickerPackTransition = translation.x
            if self.selectedStickerPackIndex == 0 {
                self.relativeToSelectedStickerPackTransition = min(0.0, self.relativeToSelectedStickerPackTransition)
            }
            if self.selectedStickerPackIndex == self.stickerPacks.count - 1 {
                self.relativeToSelectedStickerPackTransition = max(0.0, self.relativeToSelectedStickerPackTransition)
            }
            if let layout = self.validLayout {
                self.containerLayoutUpdated(layout, transition: .immediate)
            }
        case .ended, .cancelled:
            let translation = recognizer.translation(in: self.view)
            let velocity = recognizer.velocity(in: self.view)
            if abs(translation.x) > 30.0 {
                let deltaIndex = translation.x > 0 ? -1 : 1
                self.selectedStickerPackIndex = max(0, min(self.stickerPacks.count - 1, Int(self.selectedStickerPackIndex + deltaIndex)))
            } else if abs(velocity.x) > 100.0 {
                let deltaIndex = velocity.x > 0 ? -1 : 1
                self.selectedStickerPackIndex = max(0, min(self.stickerPacks.count - 1, Int(self.selectedStickerPackIndex + deltaIndex)))
            }
            let deltaOffset = self.relativeToSelectedStickerPackTransition
            self.relativeToSelectedStickerPackTransition = 0.0
            if let layout = self.validLayout {
                var previousFrames: [Int: CGRect] = [:]
                for (key, container) in self.containers {
                    previousFrames[key] = container.frame
                }
                let transition: ContainedViewLayoutTransition = .animated(duration: 0.35, curve: .spring)
                self.containerLayoutUpdated(layout, transition: .immediate)
                for (key, container) in self.containers {
                    if let previousFrame = previousFrames[key] {
                        transition.animatePositionAdditive(node: container, offset: CGPoint(x: previousFrame.minX - container.frame.minX, y: 0.0))
                    } else {
                        transition.animatePositionAdditive(node: container, offset: CGPoint(x: -deltaOffset, y: 0.0))
                    }
                }
            }
        default:
            break
        }
    }
    
    func animateIn() {
        self.dimNode.alpha = 1.0
        self.dimNode.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.3)
        
        let minInset: CGFloat = (self.containers.map { (_, container) -> CGFloat in container.topContentInset }).max() ?? 0.0
        self.containerContainingNode.layer.animatePosition(from: CGPoint(x: 0.0, y: self.containerContainingNode.bounds.height - minInset), to: CGPoint(), duration: 0.5, timingFunction: kCAMediaTimingFunctionSpring, additive: true)
    }
    
    func animateOut(completion: @escaping () -> Void) {
        self.dimNode.alpha = 0.0
        self.dimNode.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.2)
        
        let minInset: CGFloat = (self.containers.map { (_, container) -> CGFloat in container.topContentInset }).max() ?? 0.0
        self.containerContainingNode.layer.animatePosition(from: CGPoint(), to: CGPoint(x: 0.0, y: self.containerContainingNode.bounds.height - minInset), duration: 0.2, timingFunction: CAMediaTimingFunctionName.easeInEaseOut.rawValue, removeOnCompletion: false, additive: true, completion: { _ in
            completion()
        })
        
        self.modalProgressUpdated(0.0, .animated(duration: 0.2, curve: .easeInOut))
    }
    
    func dismiss() {
        if self.isDismissed {
            return
        }
        self.isDismissed = true
        self.animateOut(completion: { [weak self] in
            self?.dismissed()
        })
        
        self.dismissAllTooltips()
    }
    
    private func dismissAllTooltips() {
        guard let controller = self.controller else {
            return
        }

        controller.window?.forEachController({ controller in
            if let controller = controller as? UndoOverlayController, !controller.keepOnParentDismissal {
                controller.dismissWithCommitAction()
            }
        })
        controller.forEachController({ controller in
            if let controller = controller as? UndoOverlayController, !controller.keepOnParentDismissal {
                controller.dismissWithCommitAction()
            }
            return true
        })
    }
    
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if !self.bounds.contains(point) {
            return nil
        }
        
        if let selectedContainer = self.containers[self.selectedStickerPackIndex] {
            if selectedContainer.hitTest(self.view.convert(point, to: selectedContainer.view), with: event) == nil {
                return self.dimNode.view
            }
        }
        
        if let result = super.hitTest(point, with: event) {
            for (index, container) in self.containers {
                if result.isDescendant(of: container.view) {
                    if index != self.selectedStickerPackIndex {
                        return self.containerContainingNode.view
                    }
                }
            }
            return result
        } else {
            return nil
        }
    }
    
    @objc private func dimNodeTapGesture(_ recognizer: UITapGestureRecognizer) {
        if case .ended = recognizer.state {
            self.dismiss()
        }
    }
}

public final class StickerPackScreenImpl: ViewController {
    private let context: AccountContext
    fileprivate var presentationData: PresentationData
    private var presentationDataDisposable: Disposable?
    
    private let stickerPacks: [StickerPackReference]
    private let initialSelectedStickerPackIndex: Int
    fileprivate weak var parentNavigationController: NavigationController?
    private let sendSticker: ((FileMediaReference, ASDisplayNode, CGRect) -> Bool)?
    
    private var controllerNode: StickerPackScreenNode {
        return self.displayNode as! StickerPackScreenNode
    }
    
    public var dismissed: (() -> Void)?
    public var actionPerformed: ((StickerPackCollectionInfo, [StickerPackItem], StickerPackScreenPerformedAction) -> Void)?
    
    private let _ready = Promise<Bool>()
    override public var ready: Promise<Bool> {
        return self._ready
    }
    
    private var alreadyDidAppear: Bool = false
    
    public init(context: AccountContext, updatedPresentationData: (initial: PresentationData, signal: Signal<PresentationData, NoError>)? = nil, stickerPacks: [StickerPackReference], selectedStickerPackIndex: Int = 0, parentNavigationController: NavigationController? = nil, sendSticker: ((FileMediaReference, ASDisplayNode, CGRect) -> Bool)? = nil, actionPerformed: ((StickerPackCollectionInfo, [StickerPackItem], StickerPackScreenPerformedAction) -> Void)? = nil) {
        self.context = context
        self.presentationData = updatedPresentationData?.initial ?? context.sharedContext.currentPresentationData.with { $0 }
        self.stickerPacks = stickerPacks
        self.initialSelectedStickerPackIndex = selectedStickerPackIndex
        self.parentNavigationController = parentNavigationController
        self.sendSticker = sendSticker
        self.actionPerformed = actionPerformed
        
        super.init(navigationBarPresentationData: nil)
        
        self.statusBar.statusBarStyle = .Ignore
        
        self.presentationDataDisposable = ((updatedPresentationData?.signal ?? context.sharedContext.presentationData)
        |> deliverOnMainQueue).start(next: { [weak self] presentationData in
            if let strongSelf = self, strongSelf.isNodeLoaded {
                strongSelf.presentationData = presentationData
                strongSelf.controllerNode.updatePresentationData(presentationData)
            }
        })
    }
    
    required init(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    deinit {
        self.presentationDataDisposable?.dispose()
    }
    
    override public func loadDisplayNode() {
        self.displayNode = StickerPackScreenNode(context: self.context, controller: self, stickerPacks: self.stickerPacks, initialSelectedStickerPackIndex: self.initialSelectedStickerPackIndex, modalProgressUpdated: { [weak self] value, transition in
            DispatchQueue.main.async {
                guard let strongSelf = self else {
                    return
                }
                strongSelf.updateModalStyleOverlayTransitionFactor(value, transition: transition)
            }
        }, dismissed: { [weak self] in
            self?.dismissed?()
            self?.dismiss()
        }, presentInGlobalOverlay: { [weak self] c, a in
            self?.presentInGlobalOverlay(c, with: a)
        }, sendSticker: self.sendSticker.flatMap { [weak self] sendSticker in
            return { file, sourceNode, sourceRect in
                if sendSticker(file, sourceNode, sourceRect) {
                    self?.dismiss()
                    return true
                } else {
                    return false
                }
            }
        })
        
        self._ready.set(self.controllerNode.ready.get())
        
        super.displayNodeDidLoad()
    }
    
    override public func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        if !self.alreadyDidAppear {
            self.alreadyDidAppear = true
            self.controllerNode.animateIn()
        }
    }
    
    override public func containerLayoutUpdated(_ layout: ContainerViewLayout, transition: ContainedViewLayoutTransition) {
        super.containerLayoutUpdated(layout, transition: transition)
        
        self.controllerNode.containerLayoutUpdated(layout, transition: transition)
    }
}

public enum StickerPackScreenPerformedAction {
    case add
    case remove(positionInList: Int)
}

public func StickerPackScreen(context: AccountContext, updatedPresentationData: (initial: PresentationData, signal: Signal<PresentationData, NoError>)? = nil, mode: StickerPackPreviewControllerMode = .default, mainStickerPack: StickerPackReference, stickerPacks: [StickerPackReference], parentNavigationController: NavigationController? = nil, sendSticker: ((FileMediaReference, ASDisplayNode, CGRect) -> Bool)? = nil, actionPerformed: ((StickerPackCollectionInfo, [StickerPackItem], StickerPackScreenPerformedAction) -> Void)? = nil, dismissed: (() -> Void)? = nil) -> ViewController {
    let stickerPacks = [mainStickerPack]
    let controller = StickerPackScreenImpl(context: context, stickerPacks: stickerPacks, selectedStickerPackIndex: stickerPacks.firstIndex(of: mainStickerPack) ?? 0, parentNavigationController: parentNavigationController, sendSticker: sendSticker, actionPerformed: actionPerformed)
    controller.dismissed = dismissed
    return controller
    
//    let controller = StickerPackPreviewController(context: context, updatedPresentationData: updatedPresentationData, stickerPack: mainStickerPack, mode: mode, parentNavigationController: parentNavigationController, actionPerformed: actionPerformed)
//    controller.dismissed = dismissed
//    controller.sendSticker = sendSticker
//    return controller
}


private final class StickerPackContextReferenceContentSource: ContextReferenceContentSource {
    private let controller: ViewController
    private let sourceNode: ContextReferenceContentNode
    
    init(controller: ViewController, sourceNode: ContextReferenceContentNode) {
        self.controller = controller
        self.sourceNode = sourceNode
    }
    
    func transitionInfo() -> ContextControllerReferenceViewInfo? {
        return ContextControllerReferenceViewInfo(referenceView: self.sourceNode.view, contentAreaInScreenSpace: UIScreen.main.bounds)
    }
}
