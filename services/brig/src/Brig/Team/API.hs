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

module Brig.Team.API
  ( servantAPI,
    routesInternal,
  )
where

import Brig.API.Error
import Brig.API.Handler
import Brig.API.User (createUserInviteViaScim, fetchUserIdentity)
import Brig.API.User qualified as API
import Brig.API.Util (logEmail, logInvitationCode)
import Brig.App
import Brig.Data.UserKey
import Brig.Data.UserKey qualified as Data
import Brig.Effects.BlacklistStore (BlacklistStore)
import Brig.Effects.BlacklistStore qualified as BlacklistStore
import Brig.Effects.GalleyProvider (GalleyProvider)
import Brig.Effects.GalleyProvider qualified as GalleyProvider
import Brig.Effects.UserPendingActivationStore (UserPendingActivationStore)
import Brig.Email qualified as Email
import Brig.Options (setMaxTeamSize, setTeamInvitationTimeout)
import Brig.Phone qualified as Phone
import Brig.Team.DB qualified as DB
import Brig.Team.Email
import Brig.Team.Types (ShowOrHideInvitationUrl (..))
import Brig.Team.Util (ensurePermissionToAddUser, ensurePermissions)
import Brig.Types.Team (TeamSize)
import Brig.User.Search.TeamSize qualified as TeamSize
import Control.Lens (view, (^.))
import Control.Monad.Trans.Except (mapExceptT)
import Data.Aeson hiding (json)
import Data.ByteString.Conversion (toByteString')
import Data.Id
import Data.List1 qualified as List1
import Data.Range
import Galley.Types.Teams qualified as Team
import Imports hiding (head)
import Network.HTTP.Types.Status
import Network.Wai (Response)
import Network.Wai.Predicate hiding (and, result, setStatus)
import Network.Wai.Routing
import Network.Wai.Utilities hiding (code, message)
import Polysemy (Member)
import Servant hiding (Handler, JSON, addHeader)
import System.Logger (Msg)
import System.Logger.Class qualified as Log
import Util.Logging (logFunction, logTeam)
import Wire.API.Error
import Wire.API.Error.Brig qualified as E
import Wire.API.Routes.Internal.Galley.TeamsIntra qualified as Team
import Wire.API.Routes.Named
import Wire.API.Routes.Public.Brig
import Wire.API.Team
import Wire.API.Team.Invitation
import Wire.API.Team.Invitation qualified as Public
import Wire.API.Team.Member (teamMembers)
import Wire.API.Team.Member qualified as Teams
import Wire.API.Team.Permission (Perm (AddTeamMember))
import Wire.API.Team.Role
import Wire.API.Team.Role qualified as Public
import Wire.API.User hiding (fromEmail)
import Wire.API.User qualified as Public

servantAPI ::
  ( Member BlacklistStore r,
    Member GalleyProvider r
  ) =>
  ServerT TeamsAPI (Handler r)
servantAPI =
  Named @"send-team-invitation" createInvitationPublicH
    :<|> Named @"get-team-invitations" listInvitations
    :<|> Named @"get-team-invitation" getInvitation
    :<|> Named @"delete-team-invitation" deleteInvitation
    :<|> Named @"get-team-invitation-info" getInvitationByCode
    :<|> Named @"head-team-invitations" headInvitationByEmail
    :<|> Named @"get-team-size" teamSizePublic

routesInternal ::
  ( Member BlacklistStore r,
    Member GalleyProvider r,
    Member (UserPendingActivationStore p) r
  ) =>
  Routes a (Handler r) ()
routesInternal = do
  get "/i/teams/invitations/by-email" (continue getInvitationByEmailH) $
    accept "application" "json"
      .&. query "email"

  get "/i/teams/invitation-code" (continue getInvitationCodeH) $
    accept "application" "json"
      .&. param "team"
      .&. param "invitation_id"

  post "/i/teams/:tid/suspend" (continue suspendTeamH) $
    accept "application" "json"
      .&. capture "tid"

  post "/i/teams/:tid/unsuspend" (continue unsuspendTeamH) $
    accept "application" "json"
      .&. capture "tid"

  get "/i/teams/:tid/size" (continue teamSizeH) $
    accept "application" "json"
      .&. capture "tid"

  post "/i/teams/:tid/invitations" (continue createInvitationViaScimH) $
    accept "application" "json"
      .&. jsonRequest @NewUserScimInvitation

teamSizePublic :: Member GalleyProvider r => UserId -> TeamId -> (Handler r) TeamSize
teamSizePublic uid tid = do
  ensurePermissions uid tid [AddTeamMember] -- limit this to team admins to reduce risk of involuntary DOS attacks
  teamSize tid

teamSizeH :: JSON ::: TeamId -> (Handler r) Response
teamSizeH (_ ::: t) = json <$> teamSize t

teamSize :: TeamId -> (Handler r) TeamSize
teamSize t = lift $ TeamSize.teamSize t

getInvitationCodeH :: JSON ::: TeamId ::: InvitationId -> (Handler r) Response
getInvitationCodeH (_ ::: t ::: r) = do
  json <$> getInvitationCode t r

getInvitationCode :: TeamId -> InvitationId -> (Handler r) FoundInvitationCode
getInvitationCode t r = do
  code <- lift . wrapClient $ DB.lookupInvitationCode t r
  maybe (throwStd $ errorToWai @'E.InvalidInvitationCode) (pure . FoundInvitationCode) code

newtype FoundInvitationCode = FoundInvitationCode InvitationCode
  deriving (Eq, Show, Generic)

instance ToJSON FoundInvitationCode where
  toJSON (FoundInvitationCode c) = object ["code" .= c]

createInvitationPublicH ::
  ( Member BlacklistStore r,
    Member GalleyProvider r
  ) =>
  UserId ->
  TeamId ->
  Public.InvitationRequest ->
  Handler r (Public.Invitation, Public.InvitationLocation)
createInvitationPublicH uid tid body = do
  inv <- createInvitationPublic uid tid body
  pure (inv, loc inv)
  where
    loc :: Invitation -> InvitationLocation
    loc inv =
      InvitationLocation $ "/teams/" <> toByteString' tid <> "/invitations/" <> toByteString' (inInvitation inv)

data CreateInvitationInviter = CreateInvitationInviter
  { inviterUid :: UserId,
    inviterEmail :: Email
  }
  deriving (Eq, Show)

createInvitationPublic ::
  ( Member BlacklistStore r,
    Member GalleyProvider r
  ) =>
  UserId ->
  TeamId ->
  Public.InvitationRequest ->
  Handler r Public.Invitation
createInvitationPublic uid tid body = do
  let inviteeRole = fromMaybe defaultRole . irRole $ body
  inviter <- do
    let inviteePerms = Team.rolePermissions inviteeRole
    idt <- maybe (throwStd (errorToWai @'E.NoIdentity)) pure =<< lift (fetchUserIdentity uid)
    from <- maybe (throwStd (errorToWai @'E.NoEmail)) pure (emailIdentity idt)
    ensurePermissionToAddUser uid tid inviteePerms
    pure $ CreateInvitationInviter uid from

  let context =
        logFunction "Brig.Team.API.createInvitationPublic"
          . logTeam tid
          . logEmail (irInviteeEmail body)

  fst
    <$> logInvitationRequest
      context
      (createInvitation' tid inviteeRole (Just (inviterUid inviter)) (inviterEmail inviter) body)

createInvitationViaScimH ::
  ( Member BlacklistStore r,
    Member GalleyProvider r,
    Member (UserPendingActivationStore p) r
  ) =>
  JSON ::: JsonRequest NewUserScimInvitation ->
  (Handler r) Response
createInvitationViaScimH (_ ::: req) = do
  body <- parseJsonBody req
  setStatus status201 . json <$> createInvitationViaScim body

createInvitationViaScim ::
  ( Member BlacklistStore r,
    Member GalleyProvider r,
    Member (UserPendingActivationStore p) r
  ) =>
  NewUserScimInvitation ->
  (Handler r) UserAccount
createInvitationViaScim newUser@(NewUserScimInvitation tid loc name email role) = do
  env <- ask
  let inviteeRole = role
      fromEmail = env ^. emailSender
      invreq =
        InvitationRequest
          { irLocale = loc,
            irRole = Nothing, -- (unused, it's in the type for 'createInvitationPublicH')
            irInviteeName = Just name,
            irInviteeEmail = email,
            irInviteePhone = Nothing
          }

      context =
        logFunction "Brig.Team.API.createInvitationViaScim"
          . logTeam tid
          . logEmail email

  (inv, _) <-
    logInvitationRequest context $
      createInvitation' tid inviteeRole Nothing fromEmail invreq
  let uid = Id (toUUID (inInvitation inv))

  createUserInviteViaScim uid newUser

logInvitationRequest :: (Msg -> Msg) -> (Handler r) (Invitation, InvitationCode) -> (Handler r) (Invitation, InvitationCode)
logInvitationRequest context action =
  flip mapExceptT action $ \action' -> do
    eith <- action'
    case eith of
      Left err' -> do
        Log.warn $ context . Log.msg @Text ("Failed to create invitation, label: " <> (cs . errorLabel) err')
        pure (Left err')
      Right result@(_, code) -> do
        Log.info $ (context . logInvitationCode code) . Log.msg @Text "Successfully created invitation"
        pure (Right result)

createInvitation' ::
  ( Member BlacklistStore r,
    Member GalleyProvider r
  ) =>
  TeamId ->
  Public.Role ->
  Maybe UserId ->
  Email ->
  Public.InvitationRequest ->
  Handler r (Public.Invitation, Public.InvitationCode)
createInvitation' tid inviteeRole mbInviterUid fromEmail body = do
  -- FUTUREWORK: These validations are nearly copy+paste from accountCreation and
  --             sendActivationCode. Refactor this to a single place

  -- Validate e-mail
  inviteeEmail <- either (const $ throwStd (errorToWai @'E.InvalidEmail)) pure (Email.validateEmail (irInviteeEmail body))
  let uke = userEmailKey inviteeEmail
  blacklistedEm <- lift $ liftSem $ BlacklistStore.exists uke
  when blacklistedEm $
    throwStd blacklistedEmail
  emailTaken <- lift $ isJust <$> wrapClient (Data.lookupKey uke)
  when emailTaken $
    throwStd emailExists

  -- Validate phone
  inviteePhone <- for (irInviteePhone body) $ \p -> do
    validatedPhone <- maybe (throwStd (errorToWai @'E.InvalidPhone)) pure =<< lift (wrapClient $ Phone.validatePhone p)
    let ukp = userPhoneKey validatedPhone
    blacklistedPh <- lift $ liftSem $ BlacklistStore.exists ukp
    when blacklistedPh $
      throwStd (errorToWai @'E.BlacklistedPhone)
    phoneTaken <- lift $ isJust <$> wrapClient (Data.lookupKey ukp)
    when phoneTaken $
      throwStd phoneExists
    pure validatedPhone
  maxSize <- setMaxTeamSize <$> view settings
  pending <- lift $ wrapClient $ DB.countInvitations tid
  when (fromIntegral pending >= maxSize) $
    throwStd (errorToWai @'E.TooManyTeamInvitations)

  let locale = irLocale body
  let inviteeName = irInviteeName body
  showInvitationUrl <- lift $ liftSem $ GalleyProvider.getExposeInvitationURLsToTeamAdmin tid

  lift $ do
    iid <- liftIO DB.mkInvitationId
    now <- liftIO =<< view currentTime
    timeout <- setTeamInvitationTimeout <$> view settings
    (newInv, code) <-
      wrapClient $
        DB.insertInvitation
          showInvitationUrl
          iid
          tid
          inviteeRole
          now
          mbInviterUid
          inviteeEmail
          inviteeName
          inviteePhone
          timeout
    (newInv, code) <$ sendInvitationMail inviteeEmail tid fromEmail code locale

deleteInvitation :: Member GalleyProvider r => UserId -> TeamId -> InvitationId -> (Handler r) ()
deleteInvitation uid tid iid = do
  ensurePermissions uid tid [AddTeamMember]
  lift $ wrapClient $ DB.deleteInvitation tid iid

listInvitations :: Member GalleyProvider r => UserId -> TeamId -> Maybe InvitationId -> Maybe (Range 1 500 Int32) -> (Handler r) Public.InvitationList
listInvitations uid tid start mSize = do
  ensurePermissions uid tid [AddTeamMember]
  showInvitationUrl <- lift $ liftSem $ GalleyProvider.getExposeInvitationURLsToTeamAdmin tid
  rs <- lift $ wrapClient $ DB.lookupInvitations showInvitationUrl tid start (fromMaybe (unsafeRange 100) mSize)
  pure $! Public.InvitationList (DB.resultList rs) (DB.resultHasMore rs)

getInvitation :: Member GalleyProvider r => UserId -> TeamId -> InvitationId -> (Handler r) (Maybe Public.Invitation)
getInvitation uid tid iid = do
  ensurePermissions uid tid [AddTeamMember]
  showInvitationUrl <- lift $ liftSem $ GalleyProvider.getExposeInvitationURLsToTeamAdmin tid
  lift $ wrapClient $ DB.lookupInvitation showInvitationUrl tid iid

getInvitationByCode :: Public.InvitationCode -> (Handler r) Public.Invitation
getInvitationByCode c = do
  inv <- lift . wrapClient $ DB.lookupInvitationByCode HideInvitationUrl c
  maybe (throwStd $ errorToWai @'E.InvalidInvitationCode) pure inv

headInvitationByEmail :: Email -> (Handler r) Public.HeadInvitationByEmailResult
headInvitationByEmail e = do
  lift $
    wrapClient $
      DB.lookupInvitationInfoByEmail e <&> \case
        DB.InvitationByEmail _ -> Public.InvitationByEmail
        DB.InvitationByEmailNotFound -> Public.InvitationByEmailNotFound
        DB.InvitationByEmailMoreThanOne -> Public.InvitationByEmailMoreThanOne

-- | FUTUREWORK: This should also respond with status 409 in case of
-- @DB.InvitationByEmailMoreThanOne@.  Refactor so that 'headInvitationByEmailH' and
-- 'getInvitationByEmailH' are almost the same thing.
getInvitationByEmailH :: JSON ::: Email -> (Handler r) Response
getInvitationByEmailH (_ ::: email) =
  json <$> getInvitationByEmail email

getInvitationByEmail :: Email -> (Handler r) Public.Invitation
getInvitationByEmail email = do
  inv <- lift $ wrapClient $ DB.lookupInvitationByEmail HideInvitationUrl email
  maybe (throwStd (notFound "Invitation not found")) pure inv

suspendTeamH :: (Member GalleyProvider r) => JSON ::: TeamId -> (Handler r) Response
suspendTeamH (_ ::: tid) = do
  empty <$ suspendTeam tid

suspendTeam :: (Member GalleyProvider r) => TeamId -> (Handler r) ()
suspendTeam tid = do
  changeTeamAccountStatuses tid Suspended
  lift $ wrapClient $ DB.deleteInvitations tid
  lift $ liftSem $ GalleyProvider.changeTeamStatus tid Team.Suspended Nothing

unsuspendTeamH ::
  (Member GalleyProvider r) =>
  JSON ::: TeamId ->
  (Handler r) Response
unsuspendTeamH (_ ::: tid) = do
  empty <$ unsuspendTeam tid

unsuspendTeam ::
  (Member GalleyProvider r) =>
  TeamId ->
  (Handler r) ()
unsuspendTeam tid = do
  changeTeamAccountStatuses tid Active
  lift $ liftSem $ GalleyProvider.changeTeamStatus tid Team.Active Nothing

-------------------------------------------------------------------------------
-- Internal

changeTeamAccountStatuses ::
  (Member GalleyProvider r) =>
  TeamId ->
  AccountStatus ->
  (Handler r) ()
changeTeamAccountStatuses tid s = do
  team <- Team.tdTeam <$> lift (liftSem $ GalleyProvider.getTeam tid)
  unless (team ^. teamBinding == Binding) $
    throwStd noBindingTeam
  uids <- toList1 =<< lift (fmap (view Teams.userId) . view teamMembers <$> liftSem (GalleyProvider.getTeamMembers tid))
  wrapHttpClientE (API.changeAccountStatus uids s) !>> accountStatusError
  where
    toList1 (x : xs) = pure $ List1.list1 x xs
    toList1 [] = throwStd (notFound "Team not found or no members")
