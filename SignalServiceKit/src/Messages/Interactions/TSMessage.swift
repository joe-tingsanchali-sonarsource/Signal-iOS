//
//  Copyright (c) 2019 Open Whisper Systems. All rights reserved.
//

import Foundation

public extension TSMessage {
    var reactionFinder: ReactionFinder {
        return ReactionFinder(uniqueMessageId: uniqueId)
    }

    @objc
    func hasReactions(transaction: SDSAnyReadTransaction) -> Bool {
        return reactionFinder.existsReaction(transaction: transaction)
    }

    @objc
    func removeAllReactions(transaction: SDSAnyWriteTransaction) throws {
        try reactionFinder.deleteAllReactions(transaction: transaction)
    }

    @objc
    func allReactionIds(transaction: SDSAnyReadTransaction) -> [String]? {
        return reactionFinder.allUniqueIds(transaction: transaction)
    }

    @objc
    func reaction(forReactor reactor: SignalServiceAddress, transaction: SDSAnyReadTransaction) -> OWSReaction? {
        return reactionFinder.reaction(for: reactor, transaction: transaction)
    }

    @objc
    func recordReaction(forReactor reactor: SignalServiceAddress,
                        emoji: String,
                        sentAtTimestamp: UInt64,
                        receivedAtTimestamp: UInt64,
                        transaction: SDSAnyWriteTransaction) {

        Logger.info("")

        // Remove any previous reaction, there can only be one
        removeReaction(forReactor: reactor, transaction: transaction)

        let reaction = OWSReaction(
            uniqueMessageId: uniqueId,
            emoji: emoji,
            reactor: reactor,
            sentAtTimestamp: sentAtTimestamp,
            receivedAtTimestamp: receivedAtTimestamp
        )

        reaction.anyInsert(transaction: transaction)
        databaseStorage.touch(interaction: self, transaction: transaction)
    }

    @objc
    func removeReaction(forReactor reactor: SignalServiceAddress, transaction: SDSAnyWriteTransaction) {
        Logger.info("")

        guard let reaction = reaction(forReactor: reactor, transaction: transaction) else { return }

        reaction.anyRemove(transaction: transaction)
        databaseStorage.touch(interaction: self, transaction: transaction)
    }

    @objc
    class func findMessage(
        withTimestamp timestamp: UInt64,
        threadId: String,
        author: SignalServiceAddress,
        transaction: SDSAnyReadTransaction
    ) -> TSMessage? {
        guard timestamp > 0 else {
            owsFailDebug("invalid timestamp: \(timestamp)")
            return nil
        }

        guard !threadId.isEmpty else {
            owsFailDebug("invalid thread")
            return nil
        }

        guard author.isValid else {
            owsFailDebug("Invalid author \(author)")
            return nil
        }

        let interactions: [TSInteraction]

        do {
            interactions = try InteractionFinder.interactions(
                withTimestamp: timestamp,
                filter: { $0 is TSMessage },
                transaction: transaction
            )
        } catch {
            owsFailDebug("Error loading interactions \(error.localizedDescription)")
            return nil
        }

        for interaction in interactions {
            guard let message = interaction as? TSMessage else {
                owsFailDebug("received unexpected non-message interaction")
                continue
            }

            guard message.uniqueThreadId == threadId else { continue }

            if let incomingMessage = message as? TSIncomingMessage,
                incomingMessage.authorAddress.isEqualToAddress(author) {
                return incomingMessage
            }

            if let outgoingMessage = message as? TSOutgoingMessage,
                author.isLocalAddress {
                return outgoingMessage
            }
        }

        return nil
    }
}
