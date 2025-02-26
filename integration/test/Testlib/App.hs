module Testlib.App where

import Control.Monad.Reader
import Control.Retry qualified as Retry
import Data.Aeson hiding ((.=))
import Data.Functor ((<&>))
import Data.IORef
import Data.Text qualified as T
import Data.Yaml qualified as Yaml
import GHC.Exception
import GHC.Stack (HasCallStack)
import System.FilePath
import Testlib.Env
import Testlib.JSON
import Testlib.Service
import Testlib.Types
import Prelude

failApp :: HasCallStack => String -> App a
failApp msg = throw (AppFailure msg)

getPrekey :: App Value
getPrekey = App $ do
  pks <- asks (.prekeys)
  (i, pk) <- liftIO $ atomicModifyIORef pks getPK
  pure $ object ["id" .= i, "key" .= pk]
  where
    getPK [] = error "Out of prekeys"
    getPK (k : ks) = (ks, k)

getLastPrekey :: App Value
getLastPrekey = App $ do
  pks <- asks (.lastPrekeys)
  lpk <- liftIO $ atomicModifyIORef pks getPK
  pure $ object ["id" .= lastPrekeyId, "key" .= lpk]
  where
    getPK [] = error "Out of prekeys"
    getPK (k : ks) = (ks, k)

    lastPrekeyId :: Int
    lastPrekeyId = 65535

readServiceConfig :: Service -> App Value
readServiceConfig = readServiceConfig' . configName

readServiceConfig' :: String -> App Value
readServiceConfig' srvName = do
  cfgFile <-
    asks (.servicesCwdBase) <&> \case
      Nothing -> "/etc/wire" </> srvName </> "conf" </> (srvName <> ".yaml")
      Just p -> p </> srvName </> (srvName <> ".integration.yaml")

  eith <- liftIO (Yaml.decodeFileEither cfgFile)
  case eith of
    Left err -> failApp ("Error while parsing " <> cfgFile <> ": " <> Yaml.prettyPrintParseException err)
    Right value -> pure value

data Domain = OwnDomain | OtherDomain

instance MakesValue Domain where
  make OwnDomain = asks (String . T.pack . (.domain1))
  make OtherDomain = asks (String . T.pack . (.domain2))

-- | Run an action, `recoverAll`ing with exponential backoff (min step 8ms, total timeout
-- ~15s).  Search this package for examples how to use it.
--
-- Ideally, this will be the only thing you'll ever need from the retry package when writing
-- integration tests.  If you are unhappy with it, please consider making it more general in a
-- backwards-compatible way so everybody can benefit.
retryT :: App a -> App a
retryT action = Retry.recoverAll (Retry.exponentialBackoff 8000 <> Retry.limitRetries 10) (const action)
