{-# LANGUAGE OverloadedLabels #-}
{-# OPTIONS_GHC -Wno-incomplete-uni-patterns #-}

module Test.Federation where

import API.Brig qualified as API
import API.Galley
import Control.Lens
import Control.Monad.Codensity
import Control.Monad.Reader
import Data.ProtoLens qualified as Proto
import Data.ProtoLens.Labels ()
import Notifications
import Numeric.Lens
import Proto.Otr qualified as Proto
import Proto.Otr_Fields qualified as Proto
import SetupHelpers
import Testlib.Prelude
import Testlib.ResourcePool

testNotificationsForOfflineBackends :: HasCallStack => App ()
testNotificationsForOfflineBackends = do
  resourcePool <- asks (.resourcePool)
  -- `delUser` will eventually get deleted.
  [delUser, otherUser, otherUser2] <- createAndConnectUsers [OwnDomain, OtherDomain, OtherDomain]
  delClient <- objId $ bindResponse (API.addClient delUser def) $ getJSON 201
  otherClient <- objId $ bindResponse (API.addClient otherUser def) $ getJSON 201
  otherClient2 <- objId $ bindResponse (API.addClient otherUser2 def) $ getJSON 201

  -- We call it 'downBackend' because it is down for the most of this test
  -- except for setup and assertions. Perhaps there is a better name.
  runCodensity (acquireResources 1 resourcePool) $ \[downBackend] -> do
    (downUser1, downClient1, downUser2, upBackendConv, downBackendConv) <- runCodensity (startDynamicBackend downBackend mempty) $ \_ -> do
      downUser1 <- randomUser downBackend.berDomain def
      downUser2 <- randomUser downBackend.berDomain def
      downClient1 <- objId $ bindResponse (API.addClient downUser1 def) $ getJSON 201
      connectUsers delUser downUser1
      connectUsers delUser downUser2
      connectUsers otherUser downUser1
      upBackendConv <- bindResponse (postConversation delUser (defProteus {qualifiedUsers = [otherUser, otherUser2, downUser1]})) $ getJSON 201
      downBackendConv <- bindResponse (postConversation downUser1 (defProteus {qualifiedUsers = [otherUser, delUser]})) $ getJSON 201
      pure (downUser1, downClient1, downUser2, upBackendConv, downBackendConv)

    -- Even when a participating backend is down, messages to conversations
    -- owned by other backends should go.
    successfulMsgForOtherUsers <- mkProteusRecipients otherUser [(otherUser, [otherClient]), (otherUser2, [otherClient2])] "success message for other user"
    successfulMsgForDownUser <- mkProteusRecipient downUser1 downClient1 "success message for down user"
    let successfulMsg =
          Proto.defMessage @Proto.QualifiedNewOtrMessage
            & #sender . Proto.client .~ (delClient ^?! hex)
            & #recipients .~ [successfulMsgForOtherUsers, successfulMsgForDownUser]
            & #reportAll .~ Proto.defMessage
    bindResponse (postProteusMessage delUser upBackendConv successfulMsg) assertSuccess

    -- When conversation owning backend is down, messages will fail to be sent.
    failedMsgForOtherUser <- mkProteusRecipient otherUser otherClient "failed message for other user"
    failedMsgForDownUser <- mkProteusRecipient downUser1 downClient1 "failed message for down user"
    let failedMsg =
          Proto.defMessage @Proto.QualifiedNewOtrMessage
            & #sender . Proto.client .~ (delClient ^?! hex)
            & #recipients .~ [failedMsgForOtherUser, failedMsgForDownUser]
            & #reportAll .~ Proto.defMessage
    bindResponse (postProteusMessage delUser downBackendConv failedMsg) $ \resp ->
      -- Due to the way federation breaks in local env vs K8s, it can return 521
      -- (local) or 533 (K8s).
      resp.status `shouldMatchOneOf` [Number 521, Number 533]

    -- Conversation creation with people from down backend should fail
    bindResponse (postConversation delUser (defProteus {qualifiedUsers = [otherUser, downUser1]})) $ \resp ->
      resp.status `shouldMatchInt` 533

    -- Adding users to an up backend conversation should not work when one of
    -- the participating backends is down. This is due to not being able to
    -- check non-fully connected graph between all participating backends
    otherUser3 <- randomUser OtherDomain def
    connectUsers delUser otherUser3
    bindResponse (addMembers delUser upBackendConv [otherUser3]) $ \resp ->
      resp.status `shouldMatchInt` 533

    -- Adding users from down backend to a conversation should also fail
    bindResponse (addMembers delUser upBackendConv [downUser2]) $ \resp ->
      resp.status `shouldMatchInt` 533

    -- Removing users from an up backend conversation should work even when one
    -- of the participating backends is down.
    bindResponse (removeMember delUser upBackendConv otherUser2) $ \resp ->
      resp.status `shouldMatchInt` 200

    -- User deletions should eventually make it to the other backend.
    deleteUser delUser

    let isOtherUser2LeaveUpConvNotif = allPreds [isConvLeaveNotif, isNotifConv upBackendConv, isNotifForUser otherUser2]
        isDelUserLeaveUpConvNotif = allPreds [isConvLeaveNotif, isNotifConv upBackendConv, isNotifForUser delUser]

    do
      newMsgNotif <- awaitNotification otherUser otherClient noValue 1 isNewMessageNotif
      newMsgNotif %. "payload.0.qualified_conversation" `shouldMatch` objQidObject upBackendConv
      newMsgNotif %. "payload.0.data.text" `shouldMatchBase64` "success message for other user"

      void $ awaitNotification otherUser otherClient (Just newMsgNotif) 1 isOtherUser2LeaveUpConvNotif
      void $ awaitNotification otherUser otherClient (Just newMsgNotif) 1 isDelUserLeaveUpConvNotif

      delUserDeletedNotif <- nPayload $ awaitNotification otherUser otherClient (Just newMsgNotif) 1 isDeleteUserNotif
      objQid delUserDeletedNotif `shouldMatch` objQid delUser

    runCodensity (startDynamicBackend downBackend mempty) $ \_ -> do
      newMsgNotif <- awaitNotification downUser1 downClient1 noValue 5 isNewMessageNotif
      newMsgNotif %. "payload.0.qualified_conversation" `shouldMatch` objQidObject upBackendConv
      newMsgNotif %. "payload.0.data.text" `shouldMatchBase64` "success message for down user"

      let isDelUserLeaveDownConvNotif =
            allPreds
              [ isConvLeaveNotif,
                isNotifConv downBackendConv,
                isNotifForUser delUser
              ]
      void $ awaitNotification downUser1 downClient1 (Just newMsgNotif) 1 isDelUserLeaveDownConvNotif

      -- FUTUREWORK: Uncomment after fixing this bug: https://wearezeta.atlassian.net/browse/WPB-3664
      -- void $ awaitNotification downUser1 downClient1 (Just newMsgNotif) 1 isOtherUser2LeaveUpConvNotif
      -- void $ awaitNotification otherUser otherClient (Just newMsgNotif) 1 isDelUserLeaveDownConvNotif

      delUserDeletedNotif <- nPayload $ awaitNotification downUser1 downClient1 (Just newMsgNotif) 1 isDeleteUserNotif
      objQid delUserDeletedNotif `shouldMatch` objQid delUser

allPreds :: (Applicative f) => [a -> f Bool] -> a -> f Bool
allPreds [] _ = pure True
allPreds [p] x = p x
allPreds (p1 : ps) x = (&&) <$> p1 x <*> allPreds ps x
