import Foundation
import Postbox
import SwiftSignalKit
import TelegramApi
import MtProtoKit

private typealias SignalKitTimer = SwiftSignalKit.Timer

private final class ManagedAutoremoveMessageOperationsHelper {
    var entry: (TimestampBasedMessageAttributesEntry, MetaDisposable)?
    
    func update(_ head: TimestampBasedMessageAttributesEntry?) -> (disposeOperations: [Disposable], beginOperations: [(TimestampBasedMessageAttributesEntry, MetaDisposable)]) {
        var disposeOperations: [Disposable] = []
        var beginOperations: [(TimestampBasedMessageAttributesEntry, MetaDisposable)] = []
        
        if self.entry?.0.index != head?.index {
            if let (_, disposable) = self.entry {
                self.entry = nil
                disposeOperations.append(disposable)
            }
            if let head = head {
                let disposable = MetaDisposable()
                self.entry = (head, disposable)
                beginOperations.append((head, disposable))
            }
        }
        
        return (disposeOperations, beginOperations)
    }
    
    func reset() -> [Disposable] {
        if let entry = entry {
            return [entry.1]
        } else {
            return []
        }
    }
}

func managedAutoremoveMessageOperations(network: Network, postbox: Postbox, isRemove: Bool) -> Signal<Void, NoError> {
    return Signal { _ in
        let helper = Atomic(value: ManagedAutoremoveMessageOperationsHelper())
        
        let timeOffsetOnce = Signal<Double, NoError> { subscriber in
            subscriber.putNext(network.globalTimeDifference)
            return EmptyDisposable
        }
        
        let timeOffset = (
            timeOffsetOnce
            |> then(
                Signal<Double, NoError>.complete()
                |> delay(1.0, queue: .mainQueue())
            )
        )
        |> restart
        |> map { value -> Double in
            round(value)
        }
        |> distinctUntilChanged

        Logger.shared.log("Autoremove", "starting isRemove: \(isRemove)")

        let tag: UInt16 = isRemove ? 0 : 1

        let disposable = combineLatest(timeOffset, postbox.timestampBasedMessageAttributesView(tag: tag)).start(next: { timeOffset, view in
            let (disposeOperations, beginOperations) = helper.with { helper -> (disposeOperations: [Disposable], beginOperations: [(TimestampBasedMessageAttributesEntry, MetaDisposable)]) in
                return helper.update(view.head)
            }
            
            for disposable in disposeOperations {
                disposable.dispose()
            }
            
            for (entry, disposable) in beginOperations {
                let timestamp = CFAbsoluteTimeGetCurrent() + NSTimeIntervalSince1970 + timeOffset
                let delay = max(0.0, Double(entry.timestamp) - timestamp)
                Logger.shared.log("Autoremove", "Scheduling autoremove for \(entry.messageId) at \(entry.timestamp) (in \(delay) seconds)")
                let signal = Signal<Void, NoError>.complete()
                |> suspendAwareDelay(delay, queue: Queue.concurrentDefaultQueue())
                |> then(postbox.transaction { transaction -> Void in
                    Logger.shared.log("Autoremove", "Performing autoremove for \(entry.messageId), isRemove: \(isRemove)")

                    if let message = transaction.getMessage(entry.messageId) {
                        if message.id.peerId.namespace == Namespaces.Peer.SecretChat || isRemove {
                            _internal_deleteMessages(transaction: transaction, mediaBox: postbox.mediaBox, ids: [entry.messageId])
                        } else {
                            transaction.updateMessage(message.id, update: { currentMessage in
                                var storeForwardInfo: StoreMessageForwardInfo?
                                if let forwardInfo = currentMessage.forwardInfo {
                                    storeForwardInfo = StoreMessageForwardInfo(authorId: forwardInfo.author?.id, sourceId: forwardInfo.source?.id, sourceMessageId: forwardInfo.sourceMessageId, date: forwardInfo.date, authorSignature: forwardInfo.authorSignature, psaType: forwardInfo.psaType, flags: forwardInfo.flags)
                                }
                                var updatedMedia = currentMessage.media
                                for i in 0 ..< updatedMedia.count {
                                    if let _ = updatedMedia[i] as? TelegramMediaImage {
                                        updatedMedia[i] = TelegramMediaExpiredContent(data: .image)
                                    } else if let file = updatedMedia[i] as? TelegramMediaFile {
                                        if file.isInstantVideo {
                                            updatedMedia[i] = TelegramMediaExpiredContent(data: .videoMessage)
                                        } else if file.isVoice {
                                            updatedMedia[i] = TelegramMediaExpiredContent(data: .voiceMessage)
                                        } else {
                                            updatedMedia[i] = TelegramMediaExpiredContent(data: .file)
                                        }
                                    }
                                }
                                var updatedAttributes = currentMessage.attributes
                                for i in 0 ..< updatedAttributes.count {
                                    if let _ = updatedAttributes[i] as? AutoclearTimeoutMessageAttribute {
                                        updatedAttributes.remove(at: i)
                                        break
                                    }
                                }
                                return .update(StoreMessage(id: currentMessage.id, globallyUniqueId: currentMessage.globallyUniqueId, groupingKey: currentMessage.groupingKey, threadId: currentMessage.threadId, timestamp: currentMessage.timestamp, flags: StoreMessageFlags(currentMessage.flags), tags: currentMessage.tags, globalTags: currentMessage.globalTags, localTags: currentMessage.localTags, forwardInfo: storeForwardInfo, authorId: currentMessage.author?.id, text: currentMessage.text, attributes: updatedAttributes, media: updatedMedia))
                            })
                        }
                    } else {
                        transaction.clearTimestampBasedAttribute(id: entry.messageId, tag: tag)
                        Logger.shared.log("Autoremove", "No message to autoremove for \(entry.messageId)")
                    }
                })
                disposable.set(signal.start())
            }
        })
        
        return ActionDisposable {
            disposable.dispose()
            let disposables = helper.with { helper -> [Disposable] in
                return helper.reset()
            }
            for disposable in disposables {
                disposable.dispose()
            }
        }
    }
}

func managedAutoexpireStoryOperations(network: Network, postbox: Postbox) -> Signal<Void, NoError> {
    return Signal { _ in
        let timeOffsetOnce = Signal<Double, NoError> { subscriber in
            subscriber.putNext(network.globalTimeDifference)
            return EmptyDisposable
        }
        
        let timeOffset = (
            timeOffsetOnce
            |> then(
                Signal<Double, NoError>.complete()
                |> delay(1.0, queue: .mainQueue())
            )
        )
        |> restart
        |> map { value -> Double in
            round(value)
        }
        |> distinctUntilChanged

        Logger.shared.log("Autoexpire stories", "starting")
        
        let currentDisposable = MetaDisposable()

        let disposable = combineLatest(timeOffset, postbox.combinedView(keys: [PostboxViewKey.storyExpirationTimeItems])).start(next: { timeOffset, views in
            guard let view = views.views[PostboxViewKey.storyExpirationTimeItems] as? StoryExpirationTimeItemsView, let topItem = view.topEntry else {
                currentDisposable.set(nil)
                return
            }
            
            let timestamp = CFAbsoluteTimeGetCurrent() + NSTimeIntervalSince1970 + timeOffset
            let delay = max(0.0, Double(topItem.expirationTimestamp) - timestamp)
            
            let signal = Signal<Void, NoError>.complete()
            |> suspendAwareDelay(delay, queue: Queue.concurrentDefaultQueue())
            |> then(postbox.transaction { transaction -> Void in
                var idsByPeerId: [PeerId: [Int32]] = [:]
                let timestamp = Int32(CFAbsoluteTimeGetCurrent() + NSTimeIntervalSince1970 + timeOffset)
                
                for id in transaction.getExpiredStoryIds(belowTimestamp: timestamp + 3) {
                    if idsByPeerId[id.peerId] == nil {
                        idsByPeerId[id.peerId] = [id.id]
                    } else {
                        idsByPeerId[id.peerId]?.append(id.id)
                    }
                }
                
                for (peerId, ids) in idsByPeerId {
                    var items = transaction.getStoryItems(peerId: peerId)
                    items.removeAll(where: { ids.contains($0.id) })
                    transaction.setStoryItems(peerId: peerId, items: items)
                }
            })
            
            currentDisposable.set(signal.start())
        })
        
        return ActionDisposable {
            disposable.dispose()
            currentDisposable.dispose()
        }
    }
}

