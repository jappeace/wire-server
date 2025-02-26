module Test.Brig where

import API.Brig qualified as Public
import API.BrigInternal qualified as Internal
import API.Common qualified as API
import API.GalleyInternal qualified as Internal
import Data.Aeson qualified as Aeson
import Data.Aeson.Types hiding ((.=))
import Data.Set qualified as Set
import Data.String.Conversions
import Data.UUID qualified as UUID
import Data.UUID.V4 qualified as UUID
import GHC.Stack
import SetupHelpers
import Testlib.Assertions
import Testlib.Prelude

testSearchContactForExternalUsers :: HasCallStack => App ()
testSearchContactForExternalUsers = do
  owner <- randomUser OwnDomain def {Internal.team = True}
  partner <- randomUser OwnDomain def {Internal.team = True}

  bindResponse (Internal.putTeamMember partner (partner %. "team") (API.teamRole "partner")) $ \resp ->
    resp.status `shouldMatchInt` 200

  bindResponse (Public.searchContacts partner (owner %. "name") OwnDomain) $ \resp ->
    resp.status `shouldMatchInt` 403

testCrudFederationRemotes :: HasCallStack => App ()
testCrudFederationRemotes = do
  otherDomain <- asString OtherDomain
  let overrides =
        def
          { brigCfg =
              setField
                "optSettings.setFederationDomainConfigs"
                [object ["domain" .= otherDomain, "search_policy" .= "full_search"]]
          }
  withModifiedBackend overrides $ \ownDomain -> do
    let parseFedConns :: HasCallStack => Response -> App [Value]
        parseFedConns resp =
          -- Pick out the list of federation domain configs
          getJSON 200 resp %. "remotes"
            & asList
            -- Enforce that the values are objects and not something else
            >>= traverse (fmap Object . asObject)

        addOnce :: (MakesValue fedConn, Ord fedConn2, ToJSON fedConn2, MakesValue fedConn2, HasCallStack) => fedConn -> [fedConn2] -> App ()
        addOnce fedConn want = do
          bindResponse (Internal.createFedConn ownDomain fedConn) $ \res -> do
            addFailureContext ("res = " <> show res) $ res.status `shouldMatchInt` 200
            res2 <- parseFedConns =<< Internal.readFedConns ownDomain
            sort res2 `shouldMatch` sort want

        addFail :: HasCallStack => MakesValue fedConn => fedConn -> App ()
        addFail fedConn = do
          bindResponse (Internal.createFedConn' ownDomain fedConn) $ \res -> do
            addFailureContext ("res = " <> show res) $ res.status `shouldMatchInt` 533

        deleteOnce :: (Ord fedConn, ToJSON fedConn, MakesValue fedConn) => String -> [fedConn] -> App ()
        deleteOnce domain want = do
          bindResponse (Internal.deleteFedConn ownDomain domain) $ \res -> do
            addFailureContext ("res = " <> show res) $ res.status `shouldMatchInt` 200
            res2 <- parseFedConns =<< Internal.readFedConns ownDomain
            sort res2 `shouldMatch` sort want

        deleteFail :: HasCallStack => String -> App ()
        deleteFail del = do
          bindResponse (Internal.deleteFedConn' ownDomain del) $ \res -> do
            addFailureContext ("res = " <> show res) $ res.status `shouldMatchInt` 533

        updateOnce :: (MakesValue fedConn, Ord fedConn2, ToJSON fedConn2, MakesValue fedConn2, HasCallStack) => String -> fedConn -> [fedConn2] -> App ()
        updateOnce domain fedConn want = do
          bindResponse (Internal.updateFedConn ownDomain domain fedConn) $ \res -> do
            addFailureContext ("res = " <> show res) $ res.status `shouldMatchInt` 200
            res2 <- parseFedConns =<< Internal.readFedConns ownDomain
            sort res2 `shouldMatch` sort want

        updateFail :: (MakesValue fedConn, HasCallStack) => String -> fedConn -> App ()
        updateFail domain fedConn = do
          bindResponse (Internal.updateFedConn' ownDomain domain fedConn) $ \res -> do
            addFailureContext ("res = " <> show res) $ res.status `shouldMatchInt` 533

    dom1 :: String <- (<> ".example.com") . UUID.toString <$> liftIO UUID.nextRandom
    dom2 :: String <- (<> ".example.com") . UUID.toString <$> liftIO UUID.nextRandom

    let remote1, remote1', remote1'' :: Internal.FedConn
        remote1 = Internal.FedConn dom1 "no_search"
        remote1' = remote1 {Internal.searchStrategy = "full_search"}
        remote1'' = remote1 {Internal.domain = dom2}

        cfgRemotesExpect :: Internal.FedConn
        cfgRemotesExpect = Internal.FedConn (cs otherDomain) "full_search"

    remote1J <- make remote1
    remote1J' <- make remote1'

    resetFedConns ownDomain
    cfgRemotes <- parseFedConns =<< Internal.readFedConns ownDomain
    cfgRemotes `shouldMatch` [cfgRemotesExpect]
    -- entries present in the config file can be idempotently added if identical, but cannot be
    -- updated, deleted or updated.
    addOnce cfgRemotesExpect [cfgRemotesExpect]
    addFail (cfgRemotesExpect {Internal.searchStrategy = "no_search"})
    deleteFail (Internal.domain cfgRemotesExpect)
    updateFail (Internal.domain cfgRemotesExpect) (cfgRemotesExpect {Internal.searchStrategy = "no_search"})
    -- create
    addOnce remote1 $ (remote1J : cfgRemotes)
    addOnce remote1 $ (remote1J : cfgRemotes) -- idempotency
    -- update
    updateOnce (Internal.domain remote1) remote1' (remote1J' : cfgRemotes)
    updateFail (Internal.domain remote1) remote1''
    -- delete
    deleteOnce (Internal.domain remote1) cfgRemotes
    deleteOnce (Internal.domain remote1) cfgRemotes -- idempotency

testCrudOAuthClient :: HasCallStack => App ()
testCrudOAuthClient = do
  user <- randomUser OwnDomain def
  let appName = "foobar"
  let url = "https://example.com/callback.html"
  clientId <- bindResponse (Internal.registerOAuthClient user appName url) $ \resp -> do
    resp.status `shouldMatchInt` 200
    resp.json %. "client_id"
  bindResponse (Internal.getOAuthClient user clientId) $ \resp -> do
    resp.status `shouldMatchInt` 200
    resp.json %. "application_name" `shouldMatch` appName
    resp.json %. "redirect_url" `shouldMatch` url
  let newName = "barfoo"
  let newUrl = "https://example.com/callback2.html"
  bindResponse (Internal.updateOAuthClient user clientId newName newUrl) $ \resp -> do
    resp.status `shouldMatchInt` 200
    resp.json %. "application_name" `shouldMatch` newName
    resp.json %. "redirect_url" `shouldMatch` newUrl
  bindResponse (Internal.deleteOAuthClient user clientId) $ \resp -> do
    resp.status `shouldMatchInt` 200
  bindResponse (Internal.getOAuthClient user clientId) $ \resp -> do
    resp.status `shouldMatchInt` 404

-- | See https://docs.wire.com/understand/api-client-perspective/swagger.html
testSwagger :: HasCallStack => App ()
testSwagger = do
  let existingVersions :: [Int]
      existingVersions = [0, 1, 2, 3, 4, 5]

      internalApis :: [String]
      internalApis = ["brig", "cannon", "cargohold", "cannon", "spar"]

  bindResponse Public.getApiVersions $ \resp -> do
    resp.status `shouldMatchInt` 200
    actualVersions :: [Int] <- do
      sup <- resp.json %. "supported" & asListOf asInt
      dev <- resp.json %. "development" & asListOf asInt
      pure $ sup <> dev
    assertBool ("unexpected actually existing versions: " <> show actualVersions) $
      -- make sure nobody has added a new version without adding it to `existingVersions`.
      -- ("subset" because blocked versions like v3 are not actually existing, but still
      -- documented.)
      Set.fromList actualVersions `Set.isSubsetOf` Set.fromList existingVersions

  bindResponse Public.getSwaggerPublicTOC $ \resp -> do
    resp.status `shouldMatchInt` 200
    cs resp.body `shouldContainString` "<html>"

  forM_ existingVersions $ \v -> do
    bindResponse (Public.getSwaggerPublicAllUI v) $ \resp -> do
      resp.status `shouldMatchInt` 200
      cs resp.body `shouldContainString` "<!DOCTYPE html>"
    bindResponse (Public.getSwaggerPublicAllJson v) $ \resp -> do
      resp.status `shouldMatchInt` 200
      void resp.json

  -- FUTUREWORK: Implement Public.getSwaggerInternalTOC (including the end-point); make sure
  -- newly added internal APIs make this test fail if not added to `internalApis`.

  forM_ internalApis $ \api -> do
    bindResponse (Public.getSwaggerInternalUI api) $ \resp -> do
      resp.status `shouldMatchInt` 200
      cs resp.body `shouldContainString` "<!DOCTYPE html>"
    bindResponse (Public.getSwaggerInternalJson api) $ \resp -> do
      resp.status `shouldMatchInt` 200
      void resp.json

testRemoteUserSearch :: HasCallStack => App ()
testRemoteUserSearch = do
  let overrides =
        setField "optSettings.setFederationStrategy" "allowDynamic"
          >=> removeField "optSettings.setFederationDomainConfigs"
          >=> setField "optSettings.setFederationDomainConfigsUpdateFreq" (Aeson.Number 1)
  startDynamicBackends [def {brigCfg = overrides}, def {brigCfg = overrides}] $ \dynDomains -> do
    domains@[d1, d2] <- pure dynDomains
    connectAllDomainsAndWaitToSync 1 domains
    [u1, u2] <- createAndConnectUsers [d1, d2]
    Internal.refreshIndex d2
    uidD2 <- objId u2
    bindResponse (Public.searchContacts u1 (u2 %. "name") d2) $ \resp -> do
      resp.status `shouldMatchInt` 200
      docs <- resp.json %. "documents" >>= asList
      case docs of
        [] -> assertFailure "Expected a non empty result, but got an empty one"
        doc : _ -> doc %. "id" `shouldMatch` uidD2
