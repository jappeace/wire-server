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

module Brig.Provider.API
  ( -- * Main stuff
    routesPublic,
    routesInternal,
    botAPI,

    -- * Event handlers
    finishDeleteService,
  )
where

import Bilge.IO (MonadHttp)
import Bilge.RPC (HasRequestId)
import Brig.API.Client qualified as Client
import Brig.API.Error
import Brig.API.Handler
import Brig.API.Types (PasswordResetError (..), VerificationCodeThrottledError (VerificationCodeThrottled))
import Brig.API.Util
import Brig.App
import Brig.Code qualified as Code
import Brig.Data.Client qualified as User
import Brig.Data.User qualified as User
import Brig.Effects.GalleyProvider (GalleyProvider)
import Brig.Effects.GalleyProvider qualified as GalleyProvider
import Brig.Email (mkEmailKey)
import Brig.InternalEvent.Types qualified as Internal
import Brig.Options (Settings (..))
import Brig.Options qualified as Opt
import Brig.Provider.DB (ServiceConn (..))
import Brig.Provider.DB qualified as DB
import Brig.Provider.Email
import Brig.Provider.RPC qualified as RPC
import Brig.Queue qualified as Queue
import Brig.Team.Util
import Brig.Types.User
import Brig.ZAuth qualified as ZAuth
import Cassandra (MonadClient)
import Control.Error (throwE)
import Control.Exception.Enclosed (handleAny)
import Control.Lens (view, (^.))
import Control.Monad.Catch (MonadMask)
import Control.Monad.Except
import Data.Aeson hiding (json)
import Data.ByteString.Conversion
import Data.ByteString.Lazy.Char8 qualified as LC8
import Data.CommaSeparatedList (CommaSeparatedList (fromCommaSeparatedList))
import Data.Conduit (runConduit, (.|))
import Data.Conduit.List qualified as C
import Data.Hashable (hash)
import Data.Id
import Data.LegalHold
import Data.List qualified as List
import Data.List1 (maybeList1)
import Data.Map.Strict qualified as Map
import Data.Misc (Fingerprint (..), FutureWork (FutureWork), Rsa)
import Data.Predicate
import Data.Qualified
import Data.Range
import Data.Set qualified as Set
import Data.Text.Ascii qualified as Ascii
import Data.Text.Encoding qualified as Text
import Data.ZAuth.Token qualified as ZAuth
import GHC.TypeNats
import Imports
import Network.HTTP.Types.Status
import Network.Wai (Response)
import Network.Wai.Predicate (accept, def, opt, query)
import Network.Wai.Routing
import Network.Wai.Utilities.Error ((!>>))
import Network.Wai.Utilities.Error qualified as Wai
import Network.Wai.Utilities.Request (JsonRequest, jsonRequest)
import Network.Wai.Utilities.Response (addHeader, empty, json, setStatus)
import Network.Wai.Utilities.ZAuth
import OpenSSL.EVP.Digest qualified as SSL
import OpenSSL.EVP.PKey qualified as SSL
import OpenSSL.PEM qualified as SSL
import OpenSSL.RSA qualified as SSL
import OpenSSL.Random (randBytes)
import Polysemy
import Servant (ServerT, (:<|>) (..))
import Ssl.Util qualified as SSL
import System.Logger.Class (MonadLogger)
import UnliftIO.Async (pooledMapConcurrentlyN_)
import Web.Cookie qualified as Cookie
import Wire.API.Conversation hiding (Member)
import Wire.API.Conversation.Bot
import Wire.API.Conversation.Bot qualified as Public
import Wire.API.Conversation.Role
import Wire.API.Error
import Wire.API.Error.Brig qualified as E
import Wire.API.Event.Conversation qualified as Public (Event)
import Wire.API.Password
import Wire.API.Provider
import Wire.API.Provider qualified as Public
import Wire.API.Provider.Bot qualified as Ext
import Wire.API.Provider.Bot qualified as Public (BotUserView)
import Wire.API.Provider.External
import Wire.API.Provider.External qualified as Ext
import Wire.API.Provider.Service
import Wire.API.Provider.Service qualified as Public
import Wire.API.Provider.Service.Tag qualified as Public
import Wire.API.Routes.Named (Named (Named))
import Wire.API.Routes.Public.Brig.Bot (BotAPI)
import Wire.API.Team.Feature qualified as Feature
import Wire.API.Team.LegalHold (LegalholdProtectee (UnprotectedBot))
import Wire.API.Team.Permission
import Wire.API.User hiding (cpNewPassword, cpOldPassword)
import Wire.API.User qualified as Public (UserProfile, publicProfile)
import Wire.API.User.Client
import Wire.API.User.Client qualified as Public (Client, ClientCapability (ClientSupportsLegalholdImplicitConsent), PubClient (..), UserClientPrekeyMap, UserClients, userClients)
import Wire.API.User.Client.Prekey qualified as Public (PrekeyId)
import Wire.API.User.Identity qualified as Public (Email)
import Wire.Sem.Concurrency (Concurrency, ConcurrencySafety (Unsafe))

botAPI ::
  ( Member GalleyProvider r,
    Member (Concurrency 'Unsafe) r
  ) =>
  ServerT BotAPI (Handler r)
botAPI =
  Named @"add-bot" addBot
    :<|> Named @"remove-bot" removeBot
    :<|> Named @"bot-get-self" botGetSelf
    :<|> Named @"bot-delete-self" botDeleteSelf
    :<|> Named @"bot-list-prekeys" botListPrekeys
    :<|> Named @"bot-update-prekeys" botUpdatePrekeys
    :<|> Named @"bot-get-client" botGetClient
    :<|> Named @"bot-claim-users-prekeys" botClaimUsersPrekeys
    :<|> Named @"bot-list-users" botListUserProfiles
    :<|> Named @"bot-get-user-clients" botGetUserClients

routesPublic ::
  ( Member GalleyProvider r
  ) =>
  Routes () (Handler r) ()
routesPublic = do
  -- Public API (Unauthenticated) --------------------------------------------

  post "/provider/register" (continue newAccountH) $
    accept "application" "json"
      .&> jsonRequest @Public.NewProvider

  get "/provider/activate" (continue activateAccountKeyH) $
    accept "application" "json"
      .&> query "key"
        .&. query "code"

  get "/provider/approve" (continue approveAccountKeyH) $
    accept "application" "json"
      .&> query "key"
        .&. query "code"

  post "/provider/login" (continue loginH) $
    jsonRequest @Public.ProviderLogin

  post "/provider/password-reset" (continue beginPasswordResetH) $
    accept "application" "json"
      .&> jsonRequest @Public.PasswordReset

  post "/provider/password-reset/complete" (continue completePasswordResetH) $
    accept "application" "json"
      .&> jsonRequest @Public.CompletePasswordReset

  -- Provider API ------------------------------------------------------------

  delete "/provider" (continue deleteAccountH) $
    zauth ZAuthProvider
      .&> zauthProviderId
        .&. jsonRequest @Public.DeleteProvider

  put "/provider" (continue updateAccountProfileH) $
    accept "application" "json"
      .&> zauth ZAuthProvider
      .&> zauthProviderId
        .&. jsonRequest @Public.UpdateProvider

  put "/provider/email" (continue updateAccountEmailH) $
    zauth ZAuthProvider
      .&> zauthProviderId
        .&. jsonRequest @Public.EmailUpdate

  put "/provider/password" (continue updateAccountPasswordH) $
    zauth ZAuthProvider
      .&> zauthProviderId
        .&. jsonRequest @Public.PasswordChange

  get "/provider" (continue getAccountH) $
    accept "application" "json"
      .&> zauth ZAuthProvider
      .&> zauthProviderId

  post "/provider/services" (continue addServiceH) $
    accept "application" "json"
      .&> zauth ZAuthProvider
      .&> zauthProviderId
        .&. jsonRequest @Public.NewService

  get "/provider/services" (continue listServicesH) $
    accept "application" "json"
      .&> zauth ZAuthProvider
      .&> zauthProviderId

  get "/provider/services/:sid" (continue getServiceH) $
    accept "application" "json"
      .&> zauth ZAuthProvider
      .&> zauthProviderId
        .&. capture "sid"

  put "/provider/services/:sid" (continue updateServiceH) $
    zauth ZAuthProvider
      .&> zauthProviderId
        .&. capture "sid"
        .&. jsonRequest @Public.UpdateService

  put "/provider/services/:sid/connection" (continue updateServiceConnH) $
    zauth ZAuthProvider
      .&> zauthProviderId
        .&. capture "sid"
        .&. jsonRequest @Public.UpdateServiceConn

  -- TODO
  --     post "/provider/services/:sid/token" (continue genServiceTokenH) $
  --         accept "application" "json"
  --         .&. zauthProvider

  delete "/provider/services/:sid" (continue deleteServiceH) $
    zauth ZAuthProvider
      .&> zauthProviderId
        .&. capture "sid"
        .&. jsonRequest @Public.DeleteService

  -- User API ----------------------------------------------------------------

  get "/providers/:pid" (continue getProviderProfileH) $
    accept "application" "json"
      .&> zauth ZAuthAccess
      .&> capture "pid"

  get "/providers/:pid/services" (continue listServiceProfilesH) $
    accept "application" "json"
      .&> zauth ZAuthAccess
      .&> capture "pid"

  get "/providers/:pid/services/:sid" (continue getServiceProfileH) $
    accept "application" "json"
      .&> zauth ZAuthAccess
      .&> capture "pid"
        .&. capture "sid"

  get "/services" (continue searchServiceProfilesH) $
    accept "application" "json"
      .&> zauth ZAuthAccess
      .&> opt (query "tags")
        .&. opt (query "start")
        .&. def (unsafeRange 20) (query "size")

  get "/services/tags" (continue getServiceTagListH) $
    accept "application" "json"
      .&> zauth ZAuthAccess

  get "/teams/:tid/services/whitelisted" (continue searchTeamServiceProfilesH) $
    accept "application" "json"
      .&> zauthUserId
        .&. capture "tid"
        .&. opt (query "prefix")
        .&. def True (query "filter_disabled")
        .&. def (unsafeRange 20) (query "size")

  post "/teams/:tid/services/whitelist" (continue updateServiceWhitelistH) $
    accept "application" "json"
      .&> zauth ZAuthAccess
      .&> zauthUserId
        .&. zauthConnId
        .&. capture "tid"
        .&. jsonRequest @Public.UpdateServiceWhitelist

routesInternal :: Member GalleyProvider r => Routes a (Handler r) ()
routesInternal = do
  get "/i/provider/activation-code" (continue getActivationCodeH) $
    accept "application" "json"
      .&> param "email"

--------------------------------------------------------------------------------
-- Public API (Unauthenticated)

newAccountH :: Member GalleyProvider r => JsonRequest Public.NewProvider -> (Handler r) Response
newAccountH req = do
  guardSecondFactorDisabled Nothing
  setStatus status201 . json <$> (newAccount =<< parseJsonBody req)

newAccount :: Public.NewProvider -> (Handler r) Public.NewProviderResponse
newAccount new = do
  email <- case validateEmail (Public.newProviderEmail new) of
    Right em -> pure em
    Left _ -> throwStd (errorToWai @'E.InvalidEmail)
  let name = Public.newProviderName new
  let pass = Public.newProviderPassword new
  let descr = fromRange (Public.newProviderDescr new)
  let url = Public.newProviderUrl new
  let emailKey = mkEmailKey email
  wrapClientE (DB.lookupKey emailKey) >>= mapM_ (const $ throwStd emailExists)
  (safePass, newPass) <- case pass of
    Just newPass -> (,Nothing) <$> mkSafePassword newPass
    Nothing -> do
      newPass <- genPassword
      safePass <- mkSafePassword newPass
      pure (safePass, Just newPass)
  pid <- wrapClientE $ DB.insertAccount name safePass url descr
  gen <- Code.mkGen (Code.ForEmail email)
  code <-
    Code.generate
      gen
      Code.IdentityVerification
      (Code.Retries 3)
      (Code.Timeout (3600 * 24)) -- 24h
      (Just (toUUID pid))
  tryInsertVerificationCode code $ verificationCodeThrottledError . VerificationCodeThrottled
  let key = Code.codeKey code
  let val = Code.codeValue code
  lift $ sendActivationMail name email key val False
  pure $ Public.NewProviderResponse pid newPass

activateAccountKeyH :: Member GalleyProvider r => Code.Key ::: Code.Value -> (Handler r) Response
activateAccountKeyH (key ::: val) = do
  guardSecondFactorDisabled Nothing
  maybe (setStatus status204 empty) json <$> activateAccountKey key val

activateAccountKey :: Code.Key -> Code.Value -> (Handler r) (Maybe Public.ProviderActivationResponse)
activateAccountKey key val = do
  c <- wrapClientE (Code.verify key Code.IdentityVerification val) >>= maybeInvalidCode
  (pid, email) <- case (Code.codeAccount c, Code.codeForEmail c) of
    (Just p, Just e) -> pure (Id p, e)
    _ -> throwStd (errorToWai @'E.InvalidCode)
  (name, memail, _url, _descr) <- wrapClientE (DB.lookupAccountData pid) >>= maybeInvalidCode
  case memail of
    Just email' | email == email' -> pure Nothing
    Just email' -> do
      -- Ensure we remove any pending password reset
      gen <- Code.mkGen (Code.ForEmail email')
      lift $ wrapClient $ Code.delete (Code.genKey gen) Code.PasswordReset
      -- Activate the new and remove the old key
      activate pid (Just email') email
      pure . Just $ Public.ProviderActivationResponse email
    -- Immediate approval for everybody (for now).
    Nothing -> do
      activate pid Nothing email
      lift $ sendApprovalConfirmMail name email
      pure . Just $ Public.ProviderActivationResponse email

getActivationCodeH :: Member GalleyProvider r => Public.Email -> (Handler r) Response
getActivationCodeH e = do
  guardSecondFactorDisabled Nothing
  json <$> getActivationCode e

getActivationCode :: Public.Email -> (Handler r) FoundActivationCode
getActivationCode e = do
  email <- case validateEmail e of
    Right em -> pure em
    Left _ -> throwStd (errorToWai @'E.InvalidEmail)
  gen <- Code.mkGen (Code.ForEmail email)
  code <- wrapClientE $ Code.lookup (Code.genKey gen) Code.IdentityVerification
  maybe (throwStd activationKeyNotFound) (pure . FoundActivationCode) code

newtype FoundActivationCode = FoundActivationCode Code.Code

instance ToJSON FoundActivationCode where
  toJSON (FoundActivationCode vcode) =
    toJSON $
      Code.KeyValuePair (Code.codeKey vcode) (Code.codeValue vcode)

approveAccountKeyH :: Member GalleyProvider r => Code.Key ::: Code.Value -> (Handler r) Response
approveAccountKeyH (key ::: val) = do
  guardSecondFactorDisabled Nothing
  empty <$ approveAccountKey key val

approveAccountKey :: Code.Key -> Code.Value -> (Handler r) ()
approveAccountKey key val = do
  c <- wrapClientE (Code.verify key Code.AccountApproval val) >>= maybeInvalidCode
  case (Code.codeAccount c, Code.codeForEmail c) of
    (Just pid, Just email) -> do
      (name, _, _, _) <- wrapClientE (DB.lookupAccountData (Id pid)) >>= maybeInvalidCode
      activate (Id pid) Nothing email
      lift $ sendApprovalConfirmMail name email
    _ -> throwStd (errorToWai @'E.InvalidCode)

loginH :: Member GalleyProvider r => JsonRequest Public.ProviderLogin -> (Handler r) Response
loginH req = do
  guardSecondFactorDisabled Nothing
  tok <- login =<< parseJsonBody req
  setProviderCookie tok empty

login :: Public.ProviderLogin -> Handler r (ZAuth.Token ZAuth.Provider)
login l = do
  pid <- wrapClientE (DB.lookupKey (mkEmailKey (providerLoginEmail l))) >>= maybeBadCredentials
  pass <- wrapClientE (DB.lookupPassword pid) >>= maybeBadCredentials
  unless (verifyPassword (providerLoginPassword l) pass) $
    throwStd (errorToWai @'E.BadCredentials)
  ZAuth.newProviderToken pid

beginPasswordResetH :: Member GalleyProvider r => JsonRequest Public.PasswordReset -> (Handler r) Response
beginPasswordResetH req = do
  guardSecondFactorDisabled Nothing
  setStatus status201 empty <$ (beginPasswordReset =<< parseJsonBody req)

beginPasswordReset :: Public.PasswordReset -> (Handler r) ()
beginPasswordReset (Public.PasswordReset target) = do
  pid <- wrapClientE (DB.lookupKey (mkEmailKey target)) >>= maybeBadCredentials
  gen <- Code.mkGen (Code.ForEmail target)
  pending <- lift . wrapClient $ Code.lookup (Code.genKey gen) Code.PasswordReset
  code <- case pending of
    Just p -> throwE $ pwResetError (PasswordResetInProgress . Just $ Code.codeTTL p)
    Nothing ->
      Code.generate
        gen
        Code.PasswordReset
        (Code.Retries 3)
        (Code.Timeout 3600) -- 1h
        (Just (toUUID pid))
  tryInsertVerificationCode code $ verificationCodeThrottledError . VerificationCodeThrottled
  lift $ sendPasswordResetMail target (Code.codeKey code) (Code.codeValue code)

completePasswordResetH :: Member GalleyProvider r => JsonRequest Public.CompletePasswordReset -> (Handler r) Response
completePasswordResetH req = do
  guardSecondFactorDisabled Nothing
  empty <$ (completePasswordReset =<< parseJsonBody req)

completePasswordReset :: Public.CompletePasswordReset -> (Handler r) ()
completePasswordReset (Public.CompletePasswordReset key val newpwd) = do
  code <- wrapClientE (Code.verify key Code.PasswordReset val) >>= maybeInvalidCode
  case Id <$> Code.codeAccount code of
    Nothing -> throwE $ pwResetError InvalidPasswordResetCode
    Just pid -> do
      oldpass <- wrapClientE (DB.lookupPassword pid) >>= maybeBadCredentials
      when (verifyPassword newpwd oldpass) $ do
        throwStd newPasswordMustDiffer
      wrapClientE $ do
        DB.updateAccountPassword pid newpwd
        Code.delete key Code.PasswordReset

--------------------------------------------------------------------------------
-- Provider API

getAccountH :: Member GalleyProvider r => ProviderId -> (Handler r) Response
getAccountH pid = do
  guardSecondFactorDisabled Nothing
  getAccount pid <&> \case
    Just p -> json p
    Nothing -> setStatus status404 empty

getAccount :: ProviderId -> (Handler r) (Maybe Public.Provider)
getAccount = wrapClientE . DB.lookupAccount

updateAccountProfileH :: Member GalleyProvider r => ProviderId ::: JsonRequest Public.UpdateProvider -> (Handler r) Response
updateAccountProfileH (pid ::: req) = do
  guardSecondFactorDisabled Nothing
  empty <$ (updateAccountProfile pid =<< parseJsonBody req)

updateAccountProfile :: ProviderId -> Public.UpdateProvider -> (Handler r) ()
updateAccountProfile pid upd = do
  _ <- wrapClientE (DB.lookupAccount pid) >>= maybeInvalidProvider
  wrapClientE $
    DB.updateAccountProfile
      pid
      (updateProviderName upd)
      (updateProviderUrl upd)
      (updateProviderDescr upd)

updateAccountEmailH :: Member GalleyProvider r => ProviderId ::: JsonRequest Public.EmailUpdate -> (Handler r) Response
updateAccountEmailH (pid ::: req) = do
  guardSecondFactorDisabled Nothing
  setStatus status202 empty <$ (updateAccountEmail pid =<< parseJsonBody req)

updateAccountEmail :: ProviderId -> Public.EmailUpdate -> (Handler r) ()
updateAccountEmail pid (Public.EmailUpdate new) = do
  email <- case validateEmail new of
    Right em -> pure em
    Left _ -> throwStd (errorToWai @'E.InvalidEmail)
  let emailKey = mkEmailKey email
  wrapClientE (DB.lookupKey emailKey) >>= mapM_ (const $ throwStd emailExists)
  gen <- Code.mkGen (Code.ForEmail email)
  code <-
    Code.generate
      gen
      Code.IdentityVerification
      (Code.Retries 3)
      (Code.Timeout (3600 * 24)) -- 24h
      (Just (toUUID pid))
  tryInsertVerificationCode code $ verificationCodeThrottledError . VerificationCodeThrottled
  lift $ sendActivationMail (Name "name") email (Code.codeKey code) (Code.codeValue code) True

updateAccountPasswordH :: Member GalleyProvider r => ProviderId ::: JsonRequest Public.PasswordChange -> (Handler r) Response
updateAccountPasswordH (pid ::: req) = do
  guardSecondFactorDisabled Nothing
  empty <$ (updateAccountPassword pid =<< parseJsonBody req)

updateAccountPassword :: ProviderId -> Public.PasswordChange -> (Handler r) ()
updateAccountPassword pid upd = do
  pass <- wrapClientE (DB.lookupPassword pid) >>= maybeBadCredentials
  unless (verifyPassword (oldPassword upd) pass) $
    throwStd (errorToWai @'E.BadCredentials)
  when (verifyPassword (newPassword upd) pass) $
    throwStd newPasswordMustDiffer
  wrapClientE $ DB.updateAccountPassword pid (newPassword upd)

addServiceH :: Member GalleyProvider r => ProviderId ::: JsonRequest Public.NewService -> (Handler r) Response
addServiceH (pid ::: req) = do
  guardSecondFactorDisabled Nothing
  setStatus status201 . json <$> (addService pid =<< parseJsonBody req)

addService :: ProviderId -> Public.NewService -> (Handler r) Public.NewServiceResponse
addService pid new = do
  _ <- wrapClientE (DB.lookupAccount pid) >>= maybeInvalidProvider
  let name = newServiceName new
  let summary = fromRange (newServiceSummary new)
  let descr = fromRange (newServiceDescr new)
  let baseUrl = newServiceUrl new
  let pubkey = newServiceKey new
  let assets = newServiceAssets new
  let tags = fromRange (newServiceTags new)
  (pk, fp) <- validateServiceKey pubkey >>= maybeInvalidServiceKey
  token <- maybe randServiceToken pure (newServiceToken new)
  sid <- wrapClientE $ DB.insertService pid name summary descr baseUrl token pk fp assets tags
  let rstoken = maybe (Just token) (const Nothing) (newServiceToken new)
  pure $ Public.NewServiceResponse sid rstoken

listServicesH :: Member GalleyProvider r => ProviderId -> (Handler r) Response
listServicesH pid = do
  guardSecondFactorDisabled Nothing
  json <$> listServices pid

listServices :: ProviderId -> (Handler r) [Public.Service]
listServices = wrapClientE . DB.listServices

getServiceH :: Member GalleyProvider r => ProviderId ::: ServiceId -> (Handler r) Response
getServiceH (pid ::: sid) = do
  guardSecondFactorDisabled Nothing
  json <$> getService pid sid

getService :: ProviderId -> ServiceId -> (Handler r) Public.Service
getService pid sid =
  wrapClientE (DB.lookupService pid sid) >>= maybeServiceNotFound

updateServiceH :: Member GalleyProvider r => ProviderId ::: ServiceId ::: JsonRequest Public.UpdateService -> (Handler r) Response
updateServiceH (pid ::: sid ::: req) = do
  guardSecondFactorDisabled Nothing
  empty <$ (updateService pid sid =<< parseJsonBody req)

updateService :: ProviderId -> ServiceId -> Public.UpdateService -> (Handler r) ()
updateService pid sid upd = do
  _ <- wrapClientE (DB.lookupAccount pid) >>= maybeInvalidProvider
  -- Update service profile
  svc <- wrapClientE (DB.lookupService pid sid) >>= maybeServiceNotFound
  let name = serviceName svc
  let newName = updateServiceName upd
  let nameChange = fmap (name,) newName
  let tags = unsafeRange (serviceTags svc)
  let newTags = updateServiceTags upd
  let tagsChange = fmap (tags,) (rcast <$> newTags)
  let newSummary = fromRange <$> updateServiceSummary upd
  let newDescr = fromRange <$> updateServiceDescr upd
  let newAssets = updateServiceAssets upd
  -- Update service, tags/prefix index if the service is enabled
  wrapClientE $
    DB.updateService
      pid
      sid
      name
      tags
      nameChange
      newSummary
      newDescr
      newAssets
      tagsChange
      (serviceEnabled svc)

updateServiceConnH :: Member GalleyProvider r => ProviderId ::: ServiceId ::: JsonRequest Public.UpdateServiceConn -> (Handler r) Response
updateServiceConnH (pid ::: sid ::: req) = do
  guardSecondFactorDisabled Nothing
  empty <$ (updateServiceConn pid sid =<< parseJsonBody req)

updateServiceConn :: ProviderId -> ServiceId -> Public.UpdateServiceConn -> (Handler r) ()
updateServiceConn pid sid upd = do
  pass <- wrapClientE (DB.lookupPassword pid) >>= maybeBadCredentials
  unless (verifyPassword (updateServiceConnPassword upd) pass) $
    throwStd (errorToWai @'E.BadCredentials)
  scon <- wrapClientE (DB.lookupServiceConn pid sid) >>= maybeServiceNotFound
  svc <- wrapClientE (DB.lookupServiceProfile pid sid) >>= maybeServiceNotFound
  let newBaseUrl = updateServiceConnUrl upd
  let newTokens = maybeList1 . fromRange =<< updateServiceConnTokens upd
  let newEnabled = updateServiceConnEnabled upd
  let newKeyPems = fromRange <$> updateServiceConnKeys upd
  keys <- forM newKeyPems (mapM (validateServiceKey >=> maybeInvalidServiceKey))
  let newKeys = keys >>= maybeList1
  let newFps = fmap snd <$> newKeys
  wrapClientE $ DB.updateServiceConn pid sid newBaseUrl newTokens newKeys newEnabled
  let scon' =
        scon
          { sconBaseUrl = fromMaybe (sconBaseUrl scon) newBaseUrl,
            sconAuthTokens = fromMaybe (sconAuthTokens scon) newTokens,
            sconFingerprints = fromMaybe (sconFingerprints scon) newFps,
            sconEnabled = fromMaybe (sconEnabled scon) newEnabled
          }
  when (sconEnabled scon || sconEnabled scon') $ do
    lift $ RPC.setServiceConn scon'
    -- If the service got enabled or disabled, update the tag index.
    unless (sconEnabled scon && sconEnabled scon') $ do
      let name = serviceProfileName svc
      let tags = unsafeRange (serviceProfileTags svc)
      -- Update index, make it visible over search
      wrapClientE $
        if sconEnabled scon
          then DB.deleteServiceIndexes pid sid name tags
          else DB.insertServiceIndexes pid sid name tags

-- TODO: Send informational email to provider.

-- | Member GalleyProvider r => The endpoint that is called to delete a service.
--
-- Since deleting a service can be costly, it just marks the service as
-- disabled and then creates an event that will, when processed, actually
-- delete the service. See 'finishDeleteService'.
deleteServiceH :: Member GalleyProvider r => ProviderId ::: ServiceId ::: JsonRequest Public.DeleteService -> (Handler r) Response
deleteServiceH (pid ::: sid ::: req) = do
  guardSecondFactorDisabled Nothing
  setStatus status202 empty <$ (deleteService pid sid =<< parseJsonBody req)

-- | The endpoint that is called to delete a service.
--
-- Since deleting a service can be costly, it just marks the service as
-- disabled and then creates an event that will, when processed, actually
-- delete the service. See 'finishDeleteService'.
deleteService :: ProviderId -> ServiceId -> Public.DeleteService -> (Handler r) ()
deleteService pid sid del = do
  pass <- wrapClientE (DB.lookupPassword pid) >>= maybeBadCredentials
  unless (verifyPassword (deleteServicePassword del) pass) $
    throwStd (errorToWai @'E.BadCredentials)
  _ <- wrapClientE (DB.lookupService pid sid) >>= maybeServiceNotFound
  -- Disable the service
  wrapClientE $ DB.updateServiceConn pid sid Nothing Nothing Nothing (Just False)
  -- Create an event
  queue <- view internalEvents
  lift $ Queue.enqueue queue (Internal.DeleteService pid sid)

finishDeleteService ::
  ( MonadReader Env m,
    MonadMask m,
    MonadHttp m,
    HasRequestId m,
    MonadLogger m,
    MonadClient m,
    MonadUnliftIO m
  ) =>
  ProviderId ->
  ServiceId ->
  m ()
finishDeleteService pid sid = do
  mbSvc <- DB.lookupService pid sid
  for_ mbSvc $ \svc -> do
    let tags = unsafeRange (serviceTags svc)
        name = serviceName svc
    runConduit $
      User.lookupServiceUsers pid sid
        .| C.mapM_ (pooledMapConcurrentlyN_ 16 kick)
    RPC.removeServiceConn pid sid
    DB.deleteService pid sid name tags
  where
    kick (bid, cid, _) = deleteBot (botUserId bid) Nothing bid cid

deleteAccountH ::
  Member GalleyProvider r =>
  ProviderId ::: JsonRequest Public.DeleteProvider ->
  ExceptT Error (AppT r) Response
deleteAccountH (pid ::: req) = do
  guardSecondFactorDisabled Nothing
  empty
    <$ mapExceptT
      wrapHttpClient
      ( deleteAccount pid
          =<< parseJsonBody req
      )

deleteAccount ::
  ( MonadReader Env m,
    MonadMask m,
    MonadHttp m,
    MonadClient m,
    HasRequestId m,
    MonadLogger m
  ) =>
  ProviderId ->
  Public.DeleteProvider ->
  ExceptT Error m ()
deleteAccount pid del = do
  prov <- DB.lookupAccount pid >>= maybeInvalidProvider
  pass <- DB.lookupPassword pid >>= maybeBadCredentials
  unless (verifyPassword (deleteProviderPassword del) pass) $
    throwStd (errorToWai @'E.BadCredentials)
  svcs <- DB.listServices pid
  forM_ svcs $ \svc -> do
    let sid = serviceId svc
    let tags = unsafeRange (serviceTags svc)
        name = serviceName svc
    lift $ RPC.removeServiceConn pid sid
    DB.deleteService pid sid name tags
  DB.deleteKey (mkEmailKey (providerEmail prov))
  DB.deleteAccount pid

--------------------------------------------------------------------------------
-- User API

getProviderProfileH :: Member GalleyProvider r => ProviderId -> (Handler r) Response
getProviderProfileH pid = do
  guardSecondFactorDisabled Nothing
  json <$> getProviderProfile pid

getProviderProfile :: ProviderId -> (Handler r) Public.ProviderProfile
getProviderProfile pid =
  wrapClientE (DB.lookupAccountProfile pid) >>= maybeProviderNotFound

listServiceProfilesH :: Member GalleyProvider r => ProviderId -> (Handler r) Response
listServiceProfilesH pid = do
  guardSecondFactorDisabled Nothing
  json <$> listServiceProfiles pid

listServiceProfiles :: ProviderId -> (Handler r) [Public.ServiceProfile]
listServiceProfiles = wrapClientE . DB.listServiceProfiles

getServiceProfileH :: Member GalleyProvider r => ProviderId ::: ServiceId -> (Handler r) Response
getServiceProfileH (pid ::: sid) = do
  guardSecondFactorDisabled Nothing
  json <$> getServiceProfile pid sid

getServiceProfile :: ProviderId -> ServiceId -> (Handler r) Public.ServiceProfile
getServiceProfile pid sid =
  wrapClientE (DB.lookupServiceProfile pid sid) >>= maybeServiceNotFound

searchServiceProfilesH :: Member GalleyProvider r => Maybe (Public.QueryAnyTags 1 3) ::: Maybe Text ::: Range 10 100 Int32 -> (Handler r) Response
searchServiceProfilesH (qt ::: start ::: size) = do
  guardSecondFactorDisabled Nothing
  json <$> searchServiceProfiles qt start size

-- TODO: in order to actually make it possible for clients to implement
-- pagination here, we need both 'start' and 'prefix'.
--
-- Also see Note [buggy pagination].
searchServiceProfiles :: Maybe (Public.QueryAnyTags 1 3) -> Maybe Text -> Range 10 100 Int32 -> (Handler r) Public.ServiceProfilePage
searchServiceProfiles Nothing (Just start) size = do
  prefix :: Range 1 128 Text <- rangeChecked start
  wrapClientE . DB.paginateServiceNames (Just prefix) (fromRange size) . setProviderSearchFilter =<< view settings
searchServiceProfiles (Just tags) start size = do
  (wrapClientE . DB.paginateServiceTags tags start (fromRange size)) . setProviderSearchFilter =<< view settings
searchServiceProfiles Nothing Nothing _ = do
  throwStd $ badRequest "At least `tags` or `start` must be provided."

searchTeamServiceProfilesH ::
  Member GalleyProvider r =>
  UserId ::: TeamId ::: Maybe (Range 1 128 Text) ::: Bool ::: Range 10 100 Int32 ->
  (Handler r) Response
searchTeamServiceProfilesH (uid ::: tid ::: prefix ::: filterDisabled ::: size) = do
  guardSecondFactorDisabled (Just uid)
  json <$> searchTeamServiceProfiles uid tid prefix filterDisabled size

-- NB: unlike 'searchServiceProfiles', we don't filter by service provider here
searchTeamServiceProfiles ::
  UserId ->
  TeamId ->
  Maybe (Range 1 128 Text) ->
  Bool ->
  Range 10 100 Int32 ->
  (Handler r) Public.ServiceProfilePage
searchTeamServiceProfiles uid tid prefix filterDisabled size = do
  -- Check that the user actually belong to the team they claim they
  -- belong to. (Note: the 'tid' team might not even exist but we'll throw
  -- 'insufficientTeamPermissions' anyway)
  teamId <- lift $ wrapClient $ User.lookupUserTeam uid
  unless (Just tid == teamId) $
    throwStd insufficientTeamPermissions
  -- Get search results
  wrapClientE $ DB.paginateServiceWhitelist tid prefix filterDisabled (fromRange size)

getServiceTagListH :: Member GalleyProvider r => () -> (Handler r) Response
getServiceTagListH () = do
  guardSecondFactorDisabled Nothing
  json <$> getServiceTagList ()

getServiceTagList :: () -> Monad m => m Public.ServiceTagList
getServiceTagList () = pure (Public.ServiceTagList allTags)
  where
    allTags = [(minBound :: Public.ServiceTag) ..]

updateServiceWhitelistH :: Member GalleyProvider r => UserId ::: ConnId ::: TeamId ::: JsonRequest Public.UpdateServiceWhitelist -> (Handler r) Response
updateServiceWhitelistH (uid ::: con ::: tid ::: req) = do
  guardSecondFactorDisabled (Just uid)
  resp <- updateServiceWhitelist uid con tid =<< parseJsonBody req
  let status = case resp of
        UpdateServiceWhitelistRespChanged -> status200
        UpdateServiceWhitelistRespUnchanged -> status204
  pure $ setStatus status empty

data UpdateServiceWhitelistResp
  = UpdateServiceWhitelistRespChanged
  | UpdateServiceWhitelistRespUnchanged

updateServiceWhitelist :: Member GalleyProvider r => UserId -> ConnId -> TeamId -> Public.UpdateServiceWhitelist -> (Handler r) UpdateServiceWhitelistResp
updateServiceWhitelist uid con tid upd = do
  let pid = updateServiceWhitelistProvider upd
      sid = updateServiceWhitelistService upd
      newWhitelisted = updateServiceWhitelistStatus upd
  -- Preconditions
  ensurePermissions uid tid (Set.toList serviceWhitelistPermissions)
  _ <- wrapClientE (DB.lookupService pid sid) >>= maybeServiceNotFound
  -- Add to various tables
  whitelisted <- wrapClientE $ DB.getServiceWhitelistStatus tid pid sid
  case (whitelisted, newWhitelisted) of
    (False, False) -> pure UpdateServiceWhitelistRespUnchanged
    (True, True) -> pure UpdateServiceWhitelistRespUnchanged
    (False, True) -> do
      wrapClientE $ DB.insertServiceWhitelist tid pid sid
      pure UpdateServiceWhitelistRespChanged
    (True, False) -> do
      -- When the service is de-whitelisted, remove its bots from team
      -- conversations
      lift
        $ fmap
          wrapHttpClient
          runConduit
        $ User.lookupServiceUsersForTeam pid sid tid
          .| C.mapM_
            ( pooledMapConcurrentlyN_
                16
                ( uncurry (deleteBot uid (Just con))
                )
            )
      wrapClientE $ DB.deleteServiceWhitelist (Just tid) pid sid
      pure UpdateServiceWhitelistRespChanged

--------------------------------------------------------------------------------
-- Bot API

addBot :: Member GalleyProvider r => UserId -> ConnId -> ConvId -> Public.AddBot -> (Handler r) Public.AddBotResponse
addBot zuid zcon cid add = do
  guardSecondFactorDisabled (Just zuid)
  zusr <- lift (wrapClient $ User.lookupUser NoPendingInvitations zuid) >>= maybeInvalidUser
  let pid = addBotProvider add
  let sid = addBotService add
  -- Get the conversation and check preconditions
  lcid <- qualifyLocal cid
  cnv <- lift (liftSem $ GalleyProvider.getConv zuid lcid) >>= maybeConvNotFound
  -- Check that the user is a conversation admin and therefore is allowed to add a bot to this conversation.
  -- Note that this precondition is also checked in the internal galley API,
  -- but by having this check here we prevent any (useless) data to be written to the database
  -- as well as the unnecessary creation of the bot via the external service API call.
  -- However, in case we refine the roles model in the future, this check might not be granular enough.
  -- In that case we should rather do an internal call to galley to check for the correct permissions.
  -- Also see `removeBot` for a similar check.
  guardConvAdmin cnv
  let mems = cnvMembers cnv
  unless (cnvType cnv == RegularConv) $
    throwStd (errorToWai @'E.InvalidConversation)
  maxSize <- fromIntegral . setMaxConvSize <$> view settings
  unless (length (cmOthers mems) < maxSize - 1) $
    throwStd (errorToWai @'E.TooManyConversationMembers)
  -- For team conversations: bots are not allowed in
  -- team-only conversations
  unless (Set.member ServiceAccessRole (cnvAccessRoles cnv)) $
    throwStd (errorToWai @'E.InvalidConversation)
  -- Lookup the relevant service data
  scon <- wrapClientE (DB.lookupServiceConn pid sid) >>= maybeServiceNotFound
  unless (sconEnabled scon) $
    throwStd (errorToWai @'E.ServiceDisabled)
  svp <- wrapClientE (DB.lookupServiceProfile pid sid) >>= maybeServiceNotFound
  for_ (cnvTeam cnv) $ \tid -> do
    whitelisted <- wrapClientE $ DB.getServiceWhitelistStatus tid pid sid
    unless whitelisted $
      throwStd serviceNotWhitelisted
  -- Prepare a user ID, client ID and token for the bot.
  bid <- BotId <$> randomId
  domain <- viewFederationDomain
  btk <- Text.decodeLatin1 . toByteString' <$> ZAuth.newBotToken pid bid cid
  let bcl = newClientId (fromIntegral (hash bid))
  -- Ask the external service to create a bot
  let zQualifiedUid = Qualified zuid domain
  let origmem = OtherMember zQualifiedUid Nothing roleNameWireAdmin
  let members = origmem : cmOthers mems
  let bcnv = Ext.botConvView (qUnqualified . cnvQualifiedId $ cnv) (cnvName cnv) members
  let busr = mkBotUserView zusr
  let bloc = fromMaybe (userLocale zusr) (addBotLocale add)
  let botReq = NewBotRequest bid bcl busr bcnv btk bloc
  rs <- RPC.createBot scon botReq !>> StdError . serviceError
  -- Insert the bot user and client
  locale <- Opt.setDefaultUserLocale <$> view settings
  let name = fromMaybe (serviceProfileName svp) (Ext.rsNewBotName rs)
  let assets = fromMaybe (serviceProfileAssets svp) (Ext.rsNewBotAssets rs)
  let colour = fromMaybe defaultAccentId (Ext.rsNewBotColour rs)
  let pict = Pict [] -- Legacy
  let sref = newServiceRef sid pid
  let usr = User (botUserId bid) (Qualified (botUserId bid) domain) Nothing name pict assets colour False locale (Just sref) Nothing Nothing Nothing ManagedByWire defSupportedProtocols
  let newClt =
        (newClient PermanentClientType (Ext.rsNewBotLastPrekey rs))
          { newClientPrekeys = Ext.rsNewBotPrekeys rs
          }
  lift $ wrapClient $ User.insertAccount (UserAccount usr Active) (Just (cid, cnvTeam cnv)) Nothing True
  maxPermClients <- fromMaybe Opt.defUserMaxPermClients . Opt.setUserMaxPermClients <$> view settings
  (clt, _, _) <- do
    _ <- do
      -- if we want to protect bots against lh, 'addClient' cannot just send lh capability
      -- implicitly in the next line.
      pure $ FutureWork @'UnprotectedBot undefined
    wrapClientE (User.addClient (botUserId bid) bcl newClt maxPermClients Nothing (Just $ Set.singleton Public.ClientSupportsLegalholdImplicitConsent))
      !>> const (StdError badGateway) -- MalformedPrekeys

  -- Add the bot to the conversation
  ev <- lift $ RPC.addBotMember zuid zcon cid bid (clientId clt) pid sid
  pure $
    Public.AddBotResponse
      { Public.rsAddBotId = bid,
        Public.rsAddBotClient = bcl,
        Public.rsAddBotName = name,
        Public.rsAddBotColour = colour,
        Public.rsAddBotAssets = assets,
        Public.rsAddBotEvent = ev
      }

removeBot :: Member GalleyProvider r => UserId -> ConnId -> ConvId -> BotId -> (Handler r) (Maybe Public.RemoveBotResponse)
removeBot zusr zcon cid bid = do
  guardSecondFactorDisabled (Just zusr)
  -- Get the conversation and check preconditions
  lcid <- qualifyLocal cid
  cnv <- lift (liftSem $ GalleyProvider.getConv zusr lcid) >>= maybeConvNotFound
  -- Check that the user is a conversation admin and therefore is allowed to remove a bot from the conversation.
  -- Note that this precondition is also checked in the internal galley API.
  -- However, in case we refine the roles model in the future, this check might not be granular enough.
  -- In that case we should rather do an internal call to galley to check for the correct permissions.
  -- Also see `addBot` for a similar check.
  guardConvAdmin cnv
  let mems = cnvMembers cnv
  unless (cnvType cnv == RegularConv) $
    (throwStd (errorToWai @'E.InvalidConversation))
  -- Find the bot in the member list and delete it
  let busr = botUserId bid
  let bot = List.find ((== busr) . qUnqualified . omQualifiedId) (cmOthers mems)
  case bot >>= omService of
    Nothing -> pure Nothing
    Just _ -> do
      lift $ Public.RemoveBotResponse <$$> wrapHttpClient (deleteBot zusr (Just zcon) bid cid)

guardConvAdmin :: Conversation -> ExceptT Error (AppT r) ()
guardConvAdmin conv = do
  let selfMember = cmSelf . cnvMembers $ conv
  unless (memConvRoleName selfMember == roleNameWireAdmin) $ (throwStd (errorToWai @'E.AccessDenied))

botGetSelf :: BotId -> (Handler r) Public.UserProfile
botGetSelf bot = do
  p <- lift $ wrapClient $ User.lookupUser NoPendingInvitations (botUserId bot)
  maybe (throwStd (errorToWai @'E.UserNotFound)) (pure . (`Public.publicProfile` UserLegalHoldNoConsent)) p

botGetClient :: Member GalleyProvider r => BotId -> (Handler r) (Maybe Public.Client)
botGetClient bot = do
  guardSecondFactorDisabled (Just (botUserId bot))
  lift $ listToMaybe <$> wrapClient (User.lookupClients (botUserId bot))

botListPrekeys :: Member GalleyProvider r => BotId -> (Handler r) [Public.PrekeyId]
botListPrekeys bot = do
  guardSecondFactorDisabled (Just (botUserId bot))
  clt <- lift $ listToMaybe <$> wrapClient (User.lookupClients (botUserId bot))
  case clientId <$> clt of
    Nothing -> pure []
    Just ci -> lift (wrapClient $ User.lookupPrekeyIds (botUserId bot) ci)

botUpdatePrekeys :: Member GalleyProvider r => BotId -> Public.UpdateBotPrekeys -> (Handler r) ()
botUpdatePrekeys bot upd = do
  guardSecondFactorDisabled (Just (botUserId bot))
  clt <- lift $ listToMaybe <$> wrapClient (User.lookupClients (botUserId bot))
  case clt of
    Nothing -> throwStd (errorToWai @'E.ClientNotFound)
    Just c -> do
      let pks = updateBotPrekeyList upd
      wrapClientE (User.updatePrekeys (botUserId bot) (clientId c) pks) !>> clientDataError

botClaimUsersPrekeys ::
  (Member (Concurrency 'Unsafe) r, Member GalleyProvider r) =>
  BotId ->
  Public.UserClients ->
  Handler r Public.UserClientPrekeyMap
botClaimUsersPrekeys _ body = do
  guardSecondFactorDisabled Nothing
  maxSize <- fromIntegral . setMaxConvSize <$> view settings
  when (Map.size (Public.userClients body) > maxSize) $
    throwStd (errorToWai @'E.TooManyClients)
  Client.claimLocalMultiPrekeyBundles UnprotectedBot body !>> clientError

botListUserProfiles :: Member GalleyProvider r => BotId -> (CommaSeparatedList UserId) -> (Handler r) [Public.BotUserView]
botListUserProfiles _ uids = do
  guardSecondFactorDisabled Nothing -- should we check all user ids?
  us <- lift . wrapClient $ User.lookupUsers NoPendingInvitations (fromCommaSeparatedList uids)
  pure (map mkBotUserView us)

botGetUserClients :: Member GalleyProvider r => BotId -> UserId -> (Handler r) [Public.PubClient]
botGetUserClients _ uid = do
  guardSecondFactorDisabled (Just uid)
  lift $ pubClient <$$> wrapClient (User.lookupClients uid)
  where
    pubClient c = Public.PubClient (clientId c) (clientClass c)

botDeleteSelf :: Member GalleyProvider r => BotId -> ConvId -> (Handler r) ()
botDeleteSelf bid cid = do
  guardSecondFactorDisabled (Just (botUserId bid))
  bot <- lift . wrapClient $ User.lookupUser NoPendingInvitations (botUserId bid)
  _ <- maybe (throwStd (errorToWai @'E.InvalidBot)) pure $ (userService =<< bot)
  _ <- lift $ wrapHttpClient $ deleteBot (botUserId bid) Nothing bid cid
  pure ()

--------------------------------------------------------------------------------
-- Utilities

-- | If second factor auth is enabled, make sure that end-points that don't support it, but should, are blocked completely.
-- (This is a workaround until we have 2FA for those end-points as well.)
guardSecondFactorDisabled ::
  Member GalleyProvider r =>
  Maybe UserId ->
  ExceptT Error (AppT r) ()
guardSecondFactorDisabled mbUserId = do
  enabled <- lift $ liftSem $ (==) Feature.FeatureStatusEnabled . Feature.wsStatus . Feature.afcSndFactorPasswordChallenge <$> GalleyProvider.getAllFeatureConfigsForUser mbUserId
  when enabled $ (throwStd (errorToWai @'E.AccessDenied))

minRsaKeySize :: Int
minRsaKeySize = 256 -- Bytes (= 2048 bits)

activate :: ProviderId -> Maybe Public.Email -> Public.Email -> (Handler r) ()
activate pid old new = do
  let emailKey = mkEmailKey new
  taken <- maybe False (/= pid) <$> wrapClientE (DB.lookupKey emailKey)
  when taken $
    throwStd emailExists
  wrapClientE $ DB.insertKey pid (mkEmailKey <$> old) emailKey

deleteBot ::
  ( MonadHttp m,
    MonadReader Env m,
    MonadMask m,
    HasRequestId m,
    MonadLogger m,
    MonadClient m
  ) =>
  UserId ->
  Maybe ConnId ->
  BotId ->
  ConvId ->
  m (Maybe Public.Event)
deleteBot zusr zcon bid cid = do
  -- Remove the bot from the conversation
  ev <- RPC.removeBotMember zusr zcon cid bid
  -- Delete the bot user and client
  let buid = botUserId bid
  mbUser <- User.lookupUser NoPendingInvitations buid
  User.lookupClients buid >>= mapM_ (User.rmClient buid . clientId)
  for_ (userService =<< mbUser) $ \sref -> do
    let pid = sref ^. serviceRefProvider
        sid = sref ^. serviceRefId
    User.deleteServiceUser pid sid bid
  -- TODO: Consider if we can actually delete the bot user entirely,
  -- i.e. not just marking the account as deleted.
  void $ runExceptT $ User.updateStatus buid Deleted
  pure ev

validateServiceKey :: MonadIO m => Public.ServiceKeyPEM -> m (Maybe (Public.ServiceKey, Fingerprint Rsa))
validateServiceKey pem =
  liftIO $
    readPublicKey >>= \pk ->
      case SSL.toPublicKey =<< pk of
        Nothing -> pure Nothing
        Just pk' -> do
          Just sha <- SSL.getDigestByName "SHA256"
          let size = SSL.rsaSize (pk' :: SSL.RSAPubKey)
          if size < minRsaKeySize
            then pure Nothing
            else do
              fpr <- Fingerprint <$> SSL.rsaFingerprint sha pk'
              let bits = fromIntegral size * 8
              let key = Public.ServiceKey Public.RsaServiceKey bits pem
              pure $ Just (key, fpr)
  where
    readPublicKey =
      handleAny
        (const $ pure Nothing)
        (SSL.readPublicKey (LC8.unpack (toByteString pem)) <&> Just)

mkBotUserView :: User -> Public.BotUserView
mkBotUserView u =
  Ext.BotUserView
    { Ext.botUserViewId = userId u,
      Ext.botUserViewName = userDisplayName u,
      Ext.botUserViewColour = userAccentId u,
      Ext.botUserViewHandle = userHandle u,
      Ext.botUserViewTeam = userTeam u
    }

setProviderCookie :: ZAuth.Token ZAuth.Provider -> Response -> (Handler r) Response
setProviderCookie t r = do
  s <- view settings
  let hdr = toByteString' (Cookie.renderSetCookie (cookie s))
  pure (addHeader "Set-Cookie" hdr r)
  where
    cookie s =
      Cookie.def
        { Cookie.setCookieName = "zprovider",
          Cookie.setCookieValue = toByteString' t,
          Cookie.setCookiePath = Just "/provider",
          Cookie.setCookieExpires = Just (ZAuth.tokenExpiresUTC t),
          Cookie.setCookieSecure = not (setCookieInsecure s),
          Cookie.setCookieHttpOnly = True
        }

maybeInvalidProvider :: Monad m => Maybe a -> (ExceptT Error m) a
maybeInvalidProvider = maybe (throwStd invalidProvider) pure

maybeInvalidCode :: Monad m => Maybe a -> (ExceptT Error m) a
maybeInvalidCode = maybe (throwStd (errorToWai @'E.InvalidCode)) pure

maybeServiceNotFound :: Monad m => Maybe a -> (ExceptT Error m) a
maybeServiceNotFound = maybe (throwStd (notFound "Service not found")) pure

maybeProviderNotFound :: Monad m => Maybe a -> (ExceptT Error m) a
maybeProviderNotFound = maybe (throwStd (notFound "Provider not found")) pure

maybeConvNotFound :: Monad m => Maybe a -> (ExceptT Error m) a
maybeConvNotFound = maybe (throwStd (notFound "Conversation not found")) pure

maybeBadCredentials :: Monad m => Maybe a -> (ExceptT Error m) a
maybeBadCredentials = maybe (throwStd (errorToWai @'E.BadCredentials)) pure

maybeInvalidServiceKey :: Monad m => Maybe a -> (ExceptT Error m) a
maybeInvalidServiceKey = maybe (throwStd invalidServiceKey) pure

maybeInvalidUser :: Monad m => Maybe a -> (ExceptT Error m) a
maybeInvalidUser = maybe (throwStd (errorToWai @'E.InvalidUser)) pure

rangeChecked :: (KnownNat n, KnownNat m, Within a n m, Monad monad) => a -> (ExceptT Error monad) (Range n m a)
rangeChecked = either (throwStd . invalidRange . fromString) pure . checkedEither

invalidServiceKey :: Wai.Error
invalidServiceKey = Wai.mkError status400 "invalid-service-key" "Invalid service key."

invalidProvider :: Wai.Error
invalidProvider = Wai.mkError status403 "invalid-provider" "The provider does not exist."

badGateway :: Wai.Error
badGateway = Wai.mkError status502 "bad-gateway" "The upstream service returned an invalid response."

tooManyBots :: Wai.Error
tooManyBots = Wai.mkError status409 "too-many-bots" "Maximum number of bots for the service reached."

serviceNotWhitelisted :: Wai.Error
serviceNotWhitelisted = Wai.mkError status403 "service-not-whitelisted" "The desired service is not on the whitelist of allowed services for this team."

serviceError :: RPC.ServiceError -> Wai.Error
serviceError RPC.ServiceUnavailable = badGateway
serviceError RPC.ServiceBotConflict = tooManyBots

randServiceToken :: MonadIO m => m Public.ServiceToken
randServiceToken = ServiceToken . Ascii.encodeBase64Url <$> liftIO (randBytes 18)
