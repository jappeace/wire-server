{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}

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

-- | Given a servant API type, this module gives you a 'Paths' for 'withPathTemplate'.
module Data.Metrics.Servant where

import Data.Metrics.Middleware.Prometheus (normalizeWaiRequestRoute)
import Data.Metrics.Types
import Data.Metrics.Types qualified as Metrics
import Data.Metrics.WaiRoute (treeToPaths)
import Data.Proxy
import Data.Tree
import GHC.TypeLits
import Imports
import Network.Wai qualified as Wai
import Network.Wai.Middleware.Prometheus
import Network.Wai.Middleware.Prometheus qualified as Promth
import Network.Wai.Routing (Routes, prepare)
import Servant.API
import Servant.Multipart

-- | This does not catch errors, so it must be called outside of 'WU.catchErrors'.
servantPrometheusMiddleware :: forall proxy api. (RoutesToPaths api) => proxy api -> Wai.Middleware
servantPrometheusMiddleware _ = Promth.prometheus conf . instrument promthNormalize
  where
    promthNormalize :: Wai.Request -> Text
    promthNormalize req = pathInfo
      where
        mPathInfo = Metrics.treeLookup (routesToPaths @api) $ cs <$> Wai.pathInfo req
        pathInfo = cs $ fromMaybe "N/A" mPathInfo

    -- See Note [Raw Response]
    instrument = Promth.instrumentHandlerValueWithFilter Promth.ignoreRawResponses

servantPlusWAIPrometheusMiddleware :: forall proxy api a m b. (RoutesToPaths api, Monad m) => Routes a m b -> proxy api -> Wai.Middleware
servantPlusWAIPrometheusMiddleware routes _ = do
  Promth.prometheus conf . instrument (normalizeWaiRequestRoute paths)
  where
    -- See Note [Raw Response]
    instrument = Promth.instrumentHandlerValueWithFilter Promth.ignoreRawResponses

    paths =
      let Paths servantPaths = routesToPaths @api
          Paths waiPaths = treeToPaths (prepare routes)
       in Paths (meltTree (servantPaths <> waiPaths))

conf :: PrometheusSettings
conf =
  Promth.def
    { Promth.prometheusEndPoint = ["i", "metrics"],
      -- We provide our own instrumentation so we can normalize routes
      Promth.prometheusInstrumentApp = False
    }

routesToPaths :: forall routes. RoutesToPaths routes => Paths
routesToPaths = Paths (meltTree (getRoutes @routes))

class RoutesToPaths routes where
  getRoutes :: Forest PathSegment

-- "seg" :> routes
instance
  (KnownSymbol seg, RoutesToPaths segs) =>
  RoutesToPaths (seg :> segs)
  where
  getRoutes = [Node (Right . cs $ symbolVal (Proxy @seg)) (getRoutes @segs)]

-- <capture> :> routes
instance
  (KnownSymbol capture, RoutesToPaths segs) =>
  RoutesToPaths (Capture' mods capture a :> segs)
  where
  getRoutes = [Node (Left (cs (":" <> symbolVal (Proxy @capture)))) (getRoutes @segs)]

instance
  (RoutesToPaths rest) =>
  RoutesToPaths (Header' mods name a :> rest)
  where
  getRoutes = getRoutes @rest

instance
  (RoutesToPaths rest) =>
  RoutesToPaths (ReqBody' mods cts a :> rest)
  where
  getRoutes = getRoutes @rest

instance
  (RoutesToPaths rest) =>
  RoutesToPaths (StreamBody' opts framing ct a :> rest)
  where
  getRoutes = getRoutes @rest

instance
  (RoutesToPaths rest) =>
  RoutesToPaths (Summary summary :> rest)
  where
  getRoutes = getRoutes @rest

instance
  RoutesToPaths rest =>
  RoutesToPaths (QueryParam' mods name a :> rest)
  where
  getRoutes = getRoutes @rest

instance RoutesToPaths rest => RoutesToPaths (MultipartForm tag a :> rest) where
  getRoutes = getRoutes @rest

instance RoutesToPaths api => RoutesToPaths (QueryFlag a :> api) where
  getRoutes = getRoutes @api

instance
  RoutesToPaths rest =>
  RoutesToPaths (Description desc :> rest)
  where
  getRoutes = getRoutes @rest

instance RoutesToPaths (Verb method status cts a) where
  getRoutes = []

instance RoutesToPaths (NoContentVerb method) where
  getRoutes = []

instance RoutesToPaths (Stream method status framing ct a) where
  getRoutes = []

-- route :<|> routes
instance
  ( RoutesToPaths route,
    RoutesToPaths routes
  ) =>
  RoutesToPaths (route :<|> routes)
  where
  getRoutes = getRoutes @route <> getRoutes @routes

instance RoutesToPaths Raw where
  getRoutes = []
