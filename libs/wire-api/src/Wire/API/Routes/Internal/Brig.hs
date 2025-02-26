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

module Wire.API.Routes.Internal.Brig
  ( API,
    IStatusAPI,
    EJPD_API,
    AccountAPI,
    MLSAPI,
    TeamsAPI,
    UserAPI,
    ClientAPI,
    AuthAPI,
    FederationRemotesAPI,
    EJPDRequest,
    ISearchIndexAPI,
    GetAccountConferenceCallingConfig,
    PutAccountConferenceCallingConfig,
    DeleteAccountConferenceCallingConfig,
    swaggerDoc,
    module Wire.API.Routes.Internal.Brig.EJPD,
    NewKeyPackageRef (..),
    NewKeyPackage (..),
    NewKeyPackageResult (..),
  )
where

import Control.Lens ((.~))
import Data.Aeson (FromJSON, ToJSON)
import Data.Code qualified as Code
import Data.CommaSeparatedList
import Data.Domain (Domain)
import Data.Handle (Handle)
import Data.Id as Id
import Data.Qualified (Qualified)
import Data.Schema hiding (swaggerDoc)
import Data.Swagger (HasInfo (info), HasTitle (title), Swagger)
import Data.Swagger qualified as S
import Imports hiding (head)
import Servant hiding (Handler, WithStatus, addHeader, respond)
import Servant.Swagger (HasSwagger (toSwagger))
import Servant.Swagger.Internal.Orphans ()
import Wire.API.Connection
import Wire.API.Error
import Wire.API.Error.Brig
import Wire.API.MLS.Credential
import Wire.API.MLS.KeyPackage
import Wire.API.MakesFederatedCall
import Wire.API.Routes.FederationDomainConfig
import Wire.API.Routes.Internal.Brig.Connection
import Wire.API.Routes.Internal.Brig.EJPD
import Wire.API.Routes.Internal.Brig.OAuth (OAuthAPI)
import Wire.API.Routes.Internal.Brig.SearchIndex (ISearchIndexAPI)
import Wire.API.Routes.Internal.Galley.TeamFeatureNoConfigMulti qualified as Multi
import Wire.API.Routes.MultiVerb
import Wire.API.Routes.Named
import Wire.API.Routes.Public (ZUser {- yes, this is a bit weird -})
import Wire.API.Team.Feature
import Wire.API.Team.LegalHold.Internal
import Wire.API.User
import Wire.API.User.Auth
import Wire.API.User.Auth.LegalHold
import Wire.API.User.Auth.ReAuth
import Wire.API.User.Auth.Sso
import Wire.API.User.Client
import Wire.API.User.RichInfo

type EJPDRequest =
  Summary
    "Identify users for law enforcement.  Wire has legal requirements to cooperate \
    \with the authorities.  The wire backend operations team uses this to answer \
    \identification requests manually.  It is our best-effort representation of the \
    \minimum required information we need to hand over about targets and (in some \
    \cases) their communication peers.  For more information, consult ejpd.admin.ch."
    :> "ejpd-request"
    :> QueryParam'
         [ Optional,
           Strict,
           Description "Also provide information about all contacts of the identified users"
         ]
         "include_contacts"
         Bool
    :> Servant.ReqBody '[Servant.JSON] EJPDRequestBody
    :> Post '[Servant.JSON] EJPDResponseBody

type GetAccountConferenceCallingConfig =
  Summary
    "Read cassandra field 'brig.user.feature_conference_calling'"
    :> "users"
    :> Capture "uid" UserId
    :> "features"
    :> "conferenceCalling"
    :> Get '[Servant.JSON] (WithStatusNoLock ConferenceCallingConfig)

type PutAccountConferenceCallingConfig =
  Summary
    "Write to cassandra field 'brig.user.feature_conference_calling'"
    :> "users"
    :> Capture "uid" UserId
    :> "features"
    :> "conferenceCalling"
    :> Servant.ReqBody '[Servant.JSON] (WithStatusNoLock ConferenceCallingConfig)
    :> Put '[Servant.JSON] NoContent

type DeleteAccountConferenceCallingConfig =
  Summary
    "Reset cassandra field 'brig.user.feature_conference_calling' to 'null'"
    :> "users"
    :> Capture "uid" UserId
    :> "features"
    :> "conferenceCalling"
    :> Delete '[Servant.JSON] NoContent

type GetAllConnectionsUnqualified =
  Summary "Get all connections of a given user"
    :> "users"
    :> "connections-status"
    :> ReqBody '[Servant.JSON] ConnectionsStatusRequest
    :> QueryParam'
         [ Optional,
           Strict,
           Description "Only returns connections with the given relation, if omitted, returns all connections"
         ]
         "filter"
         Relation
    :> Post '[Servant.JSON] [ConnectionStatus]

type GetAllConnections =
  Summary "Get all connections of a given user"
    :> "users"
    :> "connections-status"
    :> "v2"
    :> ReqBody '[Servant.JSON] ConnectionsStatusRequestV2
    :> Post '[Servant.JSON] [ConnectionStatusV2]

type EJPD_API =
  ( EJPDRequest
      :<|> Named "get-account-conference-calling-config" GetAccountConferenceCallingConfig
      :<|> PutAccountConferenceCallingConfig
      :<|> DeleteAccountConferenceCallingConfig
      :<|> GetAllConnectionsUnqualified
      :<|> GetAllConnections
  )

type AccountAPI =
  -- This endpoint can lead to the following events being sent:
  -- - UserActivated event to created user, if it is a team invitation or user has an SSO ID
  -- - UserIdentityUpdated event to created user, if email or phone get activated
  Named
    "createUserNoVerify"
    ( "users"
        :> MakesFederatedCall 'Brig "on-user-deleted-connections"
        :> ReqBody '[Servant.JSON] NewUser
        :> MultiVerb 'POST '[Servant.JSON] RegisterInternalResponses (Either RegisterError SelfProfile)
    )
    :<|> Named
           "createUserNoVerifySpar"
           ( "users"
               :> "spar"
               :> MakesFederatedCall 'Brig "on-user-deleted-connections"
               :> ReqBody '[Servant.JSON] NewUserSpar
               :> MultiVerb 'POST '[Servant.JSON] CreateUserSparInternalResponses (Either CreateUserSparError SelfProfile)
           )
    :<|> Named
           "putSelfEmail"
           ( Summary
               "internal email activation (used in tests and in spar for validating emails obtained as \
               \SAML user identifiers).  if the validate query parameter is false or missing, only set \
               \the activation timeout, but do not send an email, and do not do anything about \
               \activating the email."
               :> ZUser
               :> "self"
               :> "email"
               :> ReqBody '[Servant.JSON] EmailUpdate
               :> QueryParam' [Optional, Strict, Description "whether to send validation email, or activate"] "validate" Bool
               :> MultiVerb
                    'PUT
                    '[Servant.JSON]
                    '[ Respond 202 "Update accepted and pending activation of the new email" (),
                       Respond 204 "No update, current and new email address are the same" ()
                     ]
                    ChangeEmailResponse
           )
    :<|> Named
           "iDeleteUser"
           ( Summary
               "This endpoint will lead to the following events being sent: UserDeleted event to all of \
               \its contacts, MemberLeave event to members for all conversations the user was in (via galley)"
               :> CanThrow 'UserNotFound
               :> "users"
               :> Capture "uid" UserId
               :> MultiVerb
                    'DELETE
                    '[Servant.JSON]
                    '[ Respond 200 "UserResponseAccountAlreadyDeleted" (),
                       Respond 202 "UserResponseAccountDeleted" ()
                     ]
                    DeleteUserResponse
           )
    :<|> Named
           "iPutUserStatus"
           ( -- FUTUREWORK: `CanThrow ... :>`
             "users"
               :> Capture "uid" UserId
               :> "status"
               :> ReqBody '[Servant.JSON] AccountStatusUpdate
               :> Put '[Servant.JSON] NoContent
           )
    :<|> Named
           "iGetUserStatus"
           ( CanThrow 'UserNotFound
               :> "users"
               :> Capture "uid" UserId
               :> "status"
               :> Get '[Servant.JSON] AccountStatusResp
           )
    :<|> Named
           "iGetUsersByVariousKeys"
           ( "users"
               :> QueryParam' [Optional, Strict] "ids" (CommaSeparatedList UserId)
               :> QueryParam' [Optional, Strict] "handles" (CommaSeparatedList Handle)
               :> QueryParam' [Optional, Strict] "email" (CommaSeparatedList Email) -- don't rename to `emails`, for backwards compat!
               :> QueryParam' [Optional, Strict] "phone" (CommaSeparatedList Phone) -- don't rename to `phones`, for backwards compat!
               :> QueryParam'
                    [ Optional,
                      Strict,
                      Description "Also return new accounts with team invitation pending"
                    ]
                    "includePendingInvitations"
                    Bool
               :> Get '[Servant.JSON] [UserAccount]
           )
    :<|> Named
           "iGetUserContacts"
           ( "users"
               :> Capture "uid" UserId
               :> "contacts"
               :> Get '[Servant.JSON] UserIds
           )
    :<|> Named
           "iGetUserActivationCode"
           ( "users"
               :> "activation-code"
               :> QueryParam' [Optional, Strict] "email" Email
               :> QueryParam' [Optional, Strict] "phone" Phone
               :> Get '[Servant.JSON] GetActivationCodeResp
           )
    :<|> Named
           "iGetUserPasswordResetCode"
           ( "users"
               :> "password-reset-code"
               :> QueryParam' [Optional, Strict] "email" Email
               :> QueryParam' [Optional, Strict] "phone" Phone
               :> Get '[Servant.JSON] GetPasswordResetCodeResp
           )
    :<|> Named
           "iRevokeIdentity"
           ( Summary "This endpoint can lead to the following events being sent: UserIdentityRemoved event to target user"
               :> "users"
               :> "revoke-identity"
               :> QueryParam' [Optional, Strict] "email" Email
               :> QueryParam' [Optional, Strict] "phone" Phone
               :> Post '[Servant.JSON] NoContent
           )
    :<|> Named
           "iHeadBlacklist"
           ( "users"
               :> "blacklist"
               :> QueryParam' [Optional, Strict] "email" Email
               :> QueryParam' [Optional, Strict] "phone" Phone
               :> MultiVerb
                    'HEAD
                    '[Servant.JSON]
                    '[ Respond 404 "Not blacklisted" (),
                       Respond 200 "Yes blacklisted" ()
                     ]
                    CheckBlacklistResponse
           )
    :<|> Named
           "iDeleteBlacklist"
           ( "users"
               :> "blacklist"
               :> QueryParam' [Optional, Strict] "email" Email
               :> QueryParam' [Optional, Strict] "phone" Phone
               :> Delete '[Servant.JSON] NoContent
           )
    :<|> Named
           "iPostBlacklist"
           ( "users"
               :> "blacklist"
               :> QueryParam' [Optional, Strict] "email" Email
               :> QueryParam' [Optional, Strict] "phone" Phone
               :> Post '[Servant.JSON] NoContent
           )
    :<|> Named
           "iGetPhonePrefix"
           ( Summary
               "given a phone number (or phone number prefix), see whether it is blocked \
               \via a prefix (and if so, via which specific prefix)"
               :> "users"
               :> "phone-prefixes"
               :> Capture "prefix" PhonePrefix
               :> MultiVerb
                    'GET
                    '[Servant.JSON]
                    '[ RespondEmpty 404 "PhonePrefixNotFound",
                       Respond 200 "PhonePrefixesFound" [ExcludedPrefix]
                     ]
                    GetPhonePrefixResponse
           )
    :<|> Named
           "iDeletePhonePrefix"
           ( "users"
               :> "phone-prefixes"
               :> Capture "prefix" PhonePrefix
               :> Delete '[Servant.JSON] NoContent
           )
    :<|> Named
           "iPostPhonePrefix"
           ( "users"
               :> "phone-prefixes"
               :> ReqBody '[Servant.JSON] ExcludedPrefix
               :> Post '[Servant.JSON] NoContent
           )
    :<|> Named
           "iPutUserSsoId"
           ( "users"
               :> Capture "uid" UserId
               :> "sso-id"
               :> ReqBody '[Servant.JSON] UserSSOId
               :> MultiVerb
                    'PUT
                    '[Servant.JSON]
                    '[ RespondEmpty 200 "UpdateSSOIdSuccess",
                       RespondEmpty 404 "UpdateSSOIdNotFound"
                     ]
                    UpdateSSOIdResponse
           )
    :<|> Named
           "iDeleteUserSsoId"
           ( "users"
               :> Capture "uid" UserId
               :> "sso-id"
               :> MultiVerb
                    'DELETE
                    '[Servant.JSON]
                    '[ RespondEmpty 200 "UpdateSSOIdSuccess",
                       RespondEmpty 404 "UpdateSSOIdNotFound"
                     ]
                    UpdateSSOIdResponse
           )
    :<|> Named
           "iPutManagedBy"
           ( "users"
               :> Capture "uid" UserId
               :> "managed-by"
               :> ReqBody '[Servant.JSON] ManagedByUpdate
               :> Put '[Servant.JSON] NoContent
           )
    :<|> Named
           "iPutRichInfo"
           ( "users"
               :> Capture "uid" UserId
               :> "rich-info"
               :> ReqBody '[Servant.JSON] RichInfoUpdate
               :> Put '[Servant.JSON] NoContent
           )
    :<|> Named
           "iPutHandle"
           ( "users"
               :> Capture "uid" UserId
               :> "handle"
               :> ReqBody '[Servant.JSON] HandleUpdate
               :> Put '[Servant.JSON] NoContent
           )
    :<|> Named
           "iPutHandle"
           ( "users"
               :> Capture "uid" UserId
               :> "name"
               :> ReqBody '[Servant.JSON] NameUpdate
               :> Put '[Servant.JSON] NoContent
           )
    :<|> Named
           "iGetRichInfo"
           ( "users"
               :> Capture "uid" UserId
               :> "rich-info"
               :> Get '[Servant.JSON] RichInfo
           )
    :<|> Named
           "iGetRichInfoMulti"
           ( "users"
               :> "rich-info"
               :> QueryParam' '[Optional, Strict] "ids" (CommaSeparatedList UserId)
               :> Get '[Servant.JSON] [(UserId, RichInfo)]
           )
    :<|> Named
           "iHeadHandle"
           ( CanThrow 'InvalidHandle
               :> "users"
               :> "handles"
               :> Capture "handle" Handle
               :> MultiVerb
                    'HEAD
                    '[Servant.JSON]
                    '[ RespondEmpty 200 "CheckHandleResponseFound",
                       RespondEmpty 404 "CheckHandleResponseNotFound"
                     ]
                    CheckHandleResponse
           )
    :<|> Named
           "iConnectionUpdate"
           ( "connections"
               :> "connection-update"
               :> ReqBody '[Servant.JSON] UpdateConnectionsInternal
               :> Put '[Servant.JSON] NoContent
           )
    :<|> Named
           "iListClients"
           ( "clients"
               :> ReqBody '[Servant.JSON] UserSet
               :> Post '[Servant.JSON] UserClients
           )
    :<|> Named
           "iListClientsFull"
           ( "clients"
               :> "full"
               :> ReqBody '[Servant.JSON] UserSet
               :> Post '[Servant.JSON] UserClientsFull
           )
    :<|> Named
           "iAddClient"
           ( Summary
               "This endpoint can lead to the following events being sent: ClientAdded event to the user; \
               \ClientRemoved event to the user, if removing old clients due to max number of clients; \
               \UserLegalHoldEnabled event to contacts of the user, if client type is legalhold."
               :> "clients"
               :> Capture "uid" UserId
               :> QueryParam' [Optional, Strict] "skip_reauth" Bool
               :> ReqBody '[Servant.JSON] NewClient
               :> Header' [Optional, Strict] "Z-Connection" ConnId
               :> Verb 'POST 201 '[Servant.JSON] Client
           )
    :<|> Named
           "iLegalholdAddClient"
           ( Summary
               "This endpoint can lead to the following events being sent: \
               \LegalHoldClientRequested event to contacts of the user"
               :> "clients"
               :> "legalhold"
               :> Capture "uid" UserId
               :> "request"
               :> ReqBody '[Servant.JSON] LegalHoldClientRequest
               :> Post '[Servant.JSON] NoContent
           )
    :<|> Named
           "iLegalholdDeleteClient"
           ( Summary
               "This endpoint can lead to the following events being sent: \
               \ClientRemoved event to the user; UserLegalHoldDisabled event \
               \to contacts of the user"
               :> "clients"
               :> "legalhold"
               :> Capture "uid" UserId
               :> Delete '[Servant.JSON] NoContent
           )

-- | The missing ref is implicit by the capture
data NewKeyPackageRef = NewKeyPackageRef
  { nkprUserId :: Qualified UserId,
    nkprClientId :: ClientId,
    nkprConversation :: Qualified ConvId
  }
  deriving stock (Eq, Show, Generic)
  deriving (ToJSON, FromJSON, S.ToSchema) via (Schema NewKeyPackageRef)

instance ToSchema NewKeyPackageRef where
  schema =
    object "NewKeyPackageRef" $
      NewKeyPackageRef
        <$> nkprUserId .= field "user_id" schema
        <*> nkprClientId .= field "client_id" schema
        <*> nkprConversation .= field "conversation" schema

data NewKeyPackage = NewKeyPackage
  { nkpConversation :: Qualified ConvId,
    nkpKeyPackage :: KeyPackageData
  }
  deriving stock (Eq, Show, Generic)
  deriving (ToJSON, FromJSON, S.ToSchema) via (Schema NewKeyPackage)

instance ToSchema NewKeyPackage where
  schema =
    object "NewKeyPackage" $
      NewKeyPackage
        <$> nkpConversation .= field "conversation" schema
        <*> nkpKeyPackage .= field "key_package" schema

data NewKeyPackageResult = NewKeyPackageResult
  { nkpresClientIdentity :: ClientIdentity,
    nkpresKeyPackageRef :: KeyPackageRef
  }
  deriving stock (Eq, Show, Generic)
  deriving (ToJSON, FromJSON, S.ToSchema) via (Schema NewKeyPackageResult)

instance ToSchema NewKeyPackageResult where
  schema =
    object "NewKeyPackageResult" $
      NewKeyPackageResult
        <$> nkpresClientIdentity .= field "client_identity" schema
        <*> nkpresKeyPackageRef .= field "key_package_ref" schema

type MLSAPI =
  "mls"
    :> ( ( "key-packages"
             :> Capture "ref" KeyPackageRef
             :> ( Named
                    "get-client-by-key-package-ref"
                    ( Summary "Resolve an MLS key package ref to a qualified client ID"
                        :> MultiVerb
                             'GET
                             '[Servant.JSON]
                             '[ RespondEmpty 404 "Key package ref not found",
                                Respond 200 "Key package ref found" ClientIdentity
                              ]
                             (Maybe ClientIdentity)
                    )
                    :<|> ( "conversation"
                             :> ( PutConversationByKeyPackageRef
                                    :<|> GetConversationByKeyPackageRef
                                )
                         )
                    :<|> Named
                           "put-key-package-ref"
                           ( Summary "Create a new KeyPackageRef mapping"
                               :> ReqBody '[Servant.JSON] NewKeyPackageRef
                               :> MultiVerb
                                    'PUT
                                    '[Servant.JSON]
                                    '[RespondEmpty 201 "Key package ref mapping created"]
                                    ()
                           )
                    :<|> Named
                           "post-key-package-ref"
                           ( Summary "Update a KeyPackageRef in mapping"
                               :> ReqBody '[Servant.JSON] KeyPackageRef
                               :> MultiVerb
                                    'POST
                                    '[Servant.JSON]
                                    '[RespondEmpty 201 "Key package ref mapping updated"]
                                    ()
                           )
                )
         )
           :<|> GetMLSClients
           :<|> MapKeyPackageRefs
           :<|> Named
                  "put-key-package-add"
                  ( "key-package-add"
                      :> ReqBody '[Servant.JSON] NewKeyPackage
                      :> MultiVerb1
                           'PUT
                           '[Servant.JSON]
                           (Respond 200 "Key package ref mapping updated" NewKeyPackageResult)
                  )
       )

type PutConversationByKeyPackageRef =
  Named
    "put-conversation-by-key-package-ref"
    ( Summary "Associate a conversation with a key package"
        :> ReqBody '[Servant.JSON] (Qualified ConvId)
        :> MultiVerb
             'PUT
             '[Servant.JSON]
             [ RespondEmpty 404 "No key package found by reference",
               RespondEmpty 204 "Converstaion associated"
             ]
             Bool
    )

type GetConversationByKeyPackageRef =
  Named
    "get-conversation-by-key-package-ref"
    ( Summary
        "Retrieve the conversation associated with a key package"
        :> MultiVerb
             'GET
             '[Servant.JSON]
             [ RespondEmpty 404 "No associated conversation or bad key package",
               Respond 200 "Conversation found" (Qualified ConvId)
             ]
             (Maybe (Qualified ConvId))
    )

type GetMLSClients =
  Summary "Return all clients and all MLS-capable clients of a user"
    :> "clients"
    :> CanThrow 'UserNotFound
    :> Capture "user" UserId
    :> QueryParam' '[Required, Strict] "sig_scheme" SignatureSchemeTag
    :> MultiVerb1
         'GET
         '[Servant.JSON]
         (Respond 200 "MLS clients" (Set ClientInfo))

type MapKeyPackageRefs =
  Summary "Insert bundle into the KeyPackage ref mapping. Only for tests."
    :> "key-package-refs"
    :> ReqBody '[Servant.JSON] KeyPackageBundle
    :> MultiVerb 'PUT '[Servant.JSON] '[RespondEmpty 204 "Mapping was updated"] ()

type GetVerificationCode =
  Summary "Get verification code for a given email and action"
    :> "users"
    :> Capture "uid" UserId
    :> "verification-code"
    :> Capture "action" VerificationAction
    :> Get '[Servant.JSON] (Maybe Code.Value)

type API =
  "i"
    :> ( IStatusAPI
           :<|> EJPD_API
           :<|> AccountAPI
           :<|> MLSAPI
           :<|> GetVerificationCode
           :<|> TeamsAPI
           :<|> UserAPI
           :<|> ClientAPI
           :<|> AuthAPI
           :<|> OAuthAPI
           :<|> ISearchIndexAPI
           :<|> FederationRemotesAPI
       )

type IStatusAPI =
  Named
    "get-status"
    ( Summary "do nothing, just check liveness (NB: this works for both get, head)"
        :> "status"
        :> Get '[Servant.JSON] NoContent
    )

type TeamsAPI =
  Named
    "updateSearchVisibilityInbound"
    ( "teams"
        :> ReqBody '[Servant.JSON] (Multi.TeamStatus SearchVisibilityInboundConfig)
        :> Post '[Servant.JSON] ()
    )

type UserAPI =
  UpdateUserLocale
    :<|> DeleteUserLocale
    :<|> GetDefaultLocale

type UpdateUserLocale =
  Summary
    "Set the user's locale"
    :> "users"
    :> Capture "uid" UserId
    :> "locale"
    :> ReqBody '[Servant.JSON] LocaleUpdate
    :> Put '[Servant.JSON] LocaleUpdate

type DeleteUserLocale =
  Summary
    "Delete the user's locale"
    :> "users"
    :> Capture "uid" UserId
    :> "locale"
    :> Delete '[Servant.JSON] NoContent

type GetDefaultLocale =
  Summary "Get the default locale"
    :> "users"
    :> "locale"
    :> Get '[Servant.JSON] LocaleUpdate

type ClientAPI =
  Named
    "update-client-last-active"
    ( Summary "Update last_active field of a client"
        :> "clients"
        :> Capture "uid" UserId
        :> Capture "client" ClientId
        :> "activity"
        :> MultiVerb1 'POST '[Servant.JSON] (RespondEmpty 200 "OK")
    )

type AuthAPI =
  Named
    "legalhold-login"
    ( "legalhold-login"
        :> MakesFederatedCall 'Brig "on-user-deleted-connections"
        :> ReqBody '[JSON] LegalHoldLogin
        :> MultiVerb1 'POST '[JSON] TokenResponse
    )
    :<|> Named
           "sso-login"
           ( "sso-login"
               :> MakesFederatedCall 'Brig "on-user-deleted-connections"
               :> ReqBody '[JSON] SsoLogin
               :> QueryParam' [Optional, Strict] "persist" Bool
               :> MultiVerb1 'POST '[JSON] TokenResponse
           )
    :<|> Named
           "login-code"
           ( "users"
               :> "login-code"
               :> QueryParam' [Required, Strict] "phone" Phone
               :> MultiVerb1 'GET '[JSON] (Respond 200 "Login code" PendingLoginCode)
           )
    :<|> Named
           "reauthenticate"
           ( "users"
               :> Capture "uid" UserId
               :> "reauthenticate"
               :> ReqBody '[JSON] ReAuthUser
               :> MultiVerb1 'GET '[JSON] (RespondEmpty 200 "OK")
           )

-- | This is located in brig, not in federator, because brig has a cassandra instance.  This
-- is not ideal, and other services could keep their local in-ram copy of this table up to date
-- via rabbitmq, but FUTUREWORK.
type FederationRemotesAPI =
  Named
    "add-federation-remotes"
    ( Description FederationRemotesAPIDescription
        :> "federation"
        :> "remotes"
        :> ReqBody '[JSON] FederationDomainConfig
        :> Post '[JSON] ()
    )
    :<|> Named
           "get-federation-remotes"
           ( Description FederationRemotesAPIDescription
               :> "federation"
               :> "remotes"
               :> Get '[JSON] FederationDomainConfigs
           )
    :<|> Named
           "update-federation-remotes"
           ( Description FederationRemotesAPIDescription
               :> "federation"
               :> "remotes"
               :> Capture "domain" Domain
               :> ReqBody '[JSON] FederationDomainConfig
               :> Put '[JSON] ()
           )
    :<|> Named
           "delete-federation-remotes"
           ( Description FederationRemotesAPIDescription
               :> Description FederationRemotesAPIDeleteDescription
               :> "federation"
               :> "remotes"
               :> Capture "domain" Domain
               :> Delete '[JSON] ()
           )
    -- This is nominally similar to delete-federation-remotes,
    -- but is called from Galley to delete the one-on-one coversations.
    -- This is needed as Galley doesn't have access to the tables
    -- that hold these values. We don't want these deletes to happen
    -- in delete-federation-remotes as brig might fall over and leave
    -- some records hanging around. Galley uses a Rabbit queue to track
    -- what is has done and can recover from a service falling over.
    :<|> Named
           "delete-federation-remote-from-galley"
           ( Description FederationRemotesAPIDescription
               :> Description FederationRemotesAPIDeleteDescription
               :> "federation"
               :> "remote"
               :> Capture "domain" Domain
               :> "galley"
               :> Delete '[JSON] ()
           )

type FederationRemotesAPIDescription =
  "See https://docs.wire.com/understand/federation/backend-communication.html#configuring-remote-connections for background. "

type FederationRemotesAPIDeleteDescription =
  "**WARNING!** If you remove a remote connection, all users from that remote will be removed from local conversations, and all \
  \group conversations hosted by that remote will be removed from the local backend. This cannot be reverted! "

swaggerDoc :: Swagger
swaggerDoc =
  toSwagger (Proxy @API)
    & info . title .~ "Wire-Server internal brig API"
