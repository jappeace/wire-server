{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE RecordWildCards #-}
{-# OPTIONS_GHC -Wno-orphans #-}

-- This file is part of the Wire Server implementation.
--
-- Copyright (C) 2020 Wire Swiss GmbH <opensource@wire.com>
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

-- | Servant-based API description types for Spar.
module Spar.API.Types where

import Data.Id
import Data.Proxy
import Data.String.Conversions (ST, cs)
import Data.Swagger hiding (Header (..))
import Imports
import qualified SAML2.WebSSO as SAML
import Servant
import Servant.API.Extended
import Servant.Multipart
import Spar.API.Util
import Spar.Error
import Spar.Scim (APIScim)
import Spar.Types
import qualified URI.ByteString as URI

-- FUTUREWORK (thanks jschaul): Use @Header' '[Strict]@ to avoid the need for the 'Maybe' and the
-- extra checks.

-- FUTUREWORK: use https://hackage.haskell.org/package/servant-0.14.1/docs/Servant-API-Generic.html?

type API =
  "sso" :> APISSO
    :<|> "sso-initiate-bind" :> APIAuthReqPrecheck -- (see comment on 'APIAuthReq')
    :<|> "sso-initiate-bind" :> APIAuthReq -- (see comment on 'APIAuthReq')
    :<|> "identity-providers" :> APIIDP
    :<|> "scim" :> APIScim
    :<|> OmitDocs :> "i" :> APIINTERNAL

-- | API with internal endpoints and so on removed from the docs; see
-- 'OutsideWorld' for more details.
type OutsideWorldAPI = OutsideWorld API

type APISSO =
  OmitDocs :> "api-docs" :> Get '[JSON] Swagger
    :<|> "metadata" :> SAML.APIMeta
    :<|> "initiate-login" :> APIAuthReqPrecheck
    :<|> "initiate-login" :> APIAuthReq
    :<|> APIAuthResp
    :<|> "settings" :> SsoSettingsGet

type CheckOK = Verb 'HEAD 200

type APIAuthReqPrecheck =
  QueryParam "success_redirect" URI.URI
    :> QueryParam "error_redirect" URI.URI
    :> Capture "idp" SAML.IdPId
    :> CheckOK '[PlainText] NoContent

-- | Dual-use route for initiating either login or bind.
--
-- We could distinguish the two cases by the presence or absence of a `Z-User` header.  However, we
-- also need to use this route under two different prefices because nginz only supports mandatory
-- auth and no auth, but not optional auth for any given end-point.  See also: 'DoInitiate'.
--
-- __Binding existing users to SSO__
--
-- A user has an existing account with email address and password, and gets idp credentails.  She
-- now wants to upgrade her password-based login to sso login, or *bind* the existing user to the
-- sso credentials.
--
-- __The Solution__
--
--   0. user logs in with password
--   1. inside the session, she requests `/sso-initiate-bind/<idp>` for an idp of her choice (idp
--      must be registered with her team)
--   2. spar checks the `Z-User` header and sends a short-lived bind cookie with the response that
--      otherwise is the same as for `/sso/initiate-login/<idp>`
--   3. everybody goes through the well-known SAML web sso moves, until:
--   4. the authentication response is sent to `/sso/finalize-login/<idp>` together with the bind
--      cookie
--   5. spar identifies the user both via the bind cookie and via the SAML authentication response,
--      and performs the binding.
--
-- Why a special cookie, and not the cookie already available, or the session token?  The wire cookie
-- gets only sent to `/access`, and we would need to change that; session tokens are hard to handle
-- while switching between app context and browser context.  Having a separate cookie makes both the
-- context switching simple and allows us to set a different cookie recipient end-point and short
-- cookie lifetime.
--
-- This solution is very flexible.  UX variants:
--
--   * team admin posts the initiate-bind link in a group in the wire team.  no new UI components
--     are needed in the frontend.
--   * we add buttons in the settings page somewhere.
--   * we send a link containing a token to the user by email.  when the user clicks on the link,
--     she gets authenticated and redirected to the initiate-bind end-point in step 1 above.
--   * ...?
--
-- __Corner Case: Accidental Creation of new SSO User__
--
-- What happens if the user authenticates via SSO first, creates a new user, and then receives the
-- bind invite?
--
-- Possible solutions:
--
--   * The IdP could create all users via SCIM and we block implicit user creation.
--   * After the fact, the duplicated user deletes the SSO user, loses a little bit of user data,
--     and goes through the bind process.
--   * Block implicit creation for a short time window, and ask all existing users to use that time
--     window to bind.
type APIAuthReq =
  Header "Z-User" UserId
    :> QueryParam "success_redirect" URI.URI
    :> QueryParam "error_redirect" URI.URI
    -- (SAML.APIAuthReq from here on, except for the cookies)
    :> Capture "idp" SAML.IdPId
    :> Get '[SAML.HTML] (WithSetBindCookie (SAML.FormRedirect SAML.AuthnRequest))

data DoInitiate = DoInitiateLogin | DoInitiateBind
  deriving (Eq, Show, Bounded, Enum)

type WithSetBindCookie = Headers '[Servant.Header "Set-Cookie" SetBindCookie]

type APIAuthResp =
  "finalize-login"
    :> Header "Cookie" ST
    -- (SAML.APIAuthResp from here on, except for response)
    :> MultipartForm Mem SAML.AuthnResponseBody
    :> Post '[PlainText] Void

type APIIDP =
  Header "Z-User" UserId :> IdpGet
    :<|> Header "Z-User" UserId :> IdpGetRaw
    :<|> Header "Z-User" UserId :> IdpGetAll
    :<|> Header "Z-User" UserId :> IdpCreate
    :<|> Header "Z-User" UserId :> IdpUpdate
    :<|> Header "Z-User" UserId :> IdpDelete

type IdpGetRaw = Capture "id" SAML.IdPId :> "raw" :> Get '[RawXML] RawIdPMetadata

type IdpGet = Capture "id" SAML.IdPId :> Get '[JSON] IdP

type IdpGetAll = Get '[JSON] IdPList

-- | See also: 'validateNewIdP', 'idpCreate', 'idpCreateXML'.
type IdpCreate =
  ReqBodyCustomError '[RawXML, JSON] "wai-error" IdPMetadataInfo
    :> QueryParam' '[Optional, Strict] "replaces" SAML.IdPId
    :> PostCreated '[JSON] IdP

type IdpUpdate =
  ReqBodyCustomError '[RawXML, JSON] "wai-error" IdPMetadataInfo
    :> Capture "id" SAML.IdPId
    :> Put '[JSON] IdP

type IdpDelete =
  Capture "id" SAML.IdPId
    :> QueryParam' '[Optional, Strict] "purge" Bool
    :> DeleteNoContent

instance MakeCustomError "wai-error" IdPMetadataInfo where
  makeCustomError = sparToServerError . SAML.CustomError . SparNewIdPBadMetadata . cs

type SsoSettingsGet =
  Get '[JSON] SsoSettings

type APIINTERNAL =
  "status" :> Get '[JSON] NoContent
    :<|> "teams" :> Capture "team" TeamId :> DeleteNoContent
    :<|> "sso" :> "settings" :> ReqBody '[JSON] SsoSettings :> Put '[JSON] NoContent

sparSPIssuer :: SAML.HasConfig m => m SAML.Issuer
sparSPIssuer = SAML.Issuer <$> SAML.getSsoURI (Proxy @APISSO) (Proxy @APIAuthResp)

sparResponseURI :: SAML.HasConfig m => m URI.URI
sparResponseURI = SAML.getSsoURI (Proxy @APISSO) (Proxy @APIAuthResp)
