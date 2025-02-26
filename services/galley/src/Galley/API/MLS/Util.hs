-- This file is part of the Wire Server implementation.
--
-- Copyright (C) 2022 Wire Swiss GmbH <opensource@wire.com>
--
-- This program is free software: you can redistribute it and/or modify it under
-- the terms of the GNU Affero General Public License as published by the Free
-- Software Foundation, either version 3 of the License, or (at your option) any
-- later version.
--
-- This program is distributed in the hope that it will be useful, but WITHOUT
-- ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
-- FOR A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
-- details.
--
-- You should have received a copy of the GNU Affero General Public License along
-- with this program. If not, see <https://www.gnu.org/licenses/>.

module Galley.API.MLS.Util where

import Control.Comonad
import Data.Id
import Data.Qualified
import Galley.Data.Conversation.Types hiding (Conversation)
import Galley.Data.Conversation.Types qualified as Data
import Galley.Effects
import Galley.Effects.ConversationStore
import Galley.Effects.MemberStore
import Galley.Effects.ProposalStore
import Imports
import Polysemy
import Polysemy.TinyLog (TinyLog)
import Polysemy.TinyLog qualified as TinyLog
import System.Logger qualified as Log
import Wire.API.Error
import Wire.API.Error.Galley
import Wire.API.MLS.Epoch
import Wire.API.MLS.Group
import Wire.API.MLS.KeyPackage
import Wire.API.MLS.Proposal
import Wire.API.MLS.Serialisation

getLocalConvForUser ::
  ( Member (ErrorS 'ConvNotFound) r,
    Member ConversationStore r,
    Member MemberStore r
  ) =>
  Qualified UserId ->
  Local ConvId ->
  Sem r Data.Conversation
getLocalConvForUser qusr lcnv = do
  conv <- getConversation (tUnqualified lcnv) >>= noteS @'ConvNotFound

  -- check that sender is part of conversation
  isMember' <-
    foldQualified
      lcnv
      ( fmap isJust
          . getLocalMember (convId conv)
          . tUnqualified
      )
      (fmap isJust . getRemoteMember (convId conv))
      qusr
  unless isMember' $ throwS @'ConvNotFound

  pure conv

getPendingBackendRemoveProposals ::
  ( Member ProposalStore r,
    Member TinyLog r
  ) =>
  GroupId ->
  Epoch ->
  Sem r [KeyPackageRef]
getPendingBackendRemoveProposals gid epoch = do
  proposals <- getAllPendingProposals gid epoch
  catMaybes
    <$> for
      proposals
      ( \case
          (Just ProposalOriginBackend, proposal) -> case rmValue proposal of
            RemoveProposal kp -> pure . Just $ kp
            _ -> pure Nothing
          (Just ProposalOriginClient, _) -> pure Nothing
          (Nothing, _) -> do
            TinyLog.warn $ Log.msg ("found pending proposal without origin, ignoring" :: ByteString)
            pure Nothing
      )
