{-# OPTIONS_GHC -Wno-unused-matches #-}

module Testlib.RunServices where

import Control.Concurrent
import Control.Monad.Codensity (lowerCodensity)
import SetupHelpers
import System.Directory
import System.Environment (getArgs)
import System.Exit (exitWith)
import System.FilePath
import System.Posix (getWorkingDirectory)
import System.Process
import Testlib.Prelude
import Testlib.ResourcePool
import Testlib.Run (createGlobalEnv)

parentDir :: FilePath -> Maybe FilePath
parentDir path =
  let dirs = splitPath path
   in if null dirs
        then Nothing
        else Just $ joinPath (init dirs)

containsGit :: FilePath -> IO Bool
containsGit path =
  doesDirectoryExist $ joinPath [path, ".git"]

findProjectRoot :: FilePath -> IO (Maybe FilePath)
findProjectRoot path = do
  c <- containsGit path
  if c
    then pure (Just path)
    else case parentDir path of
      Nothing -> pure Nothing
      Just p -> findProjectRoot p

main :: IO ()
main = do
  cwd <- getWorkingDirectory
  mbProjectRoot <- findProjectRoot cwd
  cfg <- case mbProjectRoot of
    Nothing -> error "Could not find project root. Please make sure you call run-services from somewhere in wire-server."
    Just projectRoot ->
      pure $ joinPath [projectRoot, "services/integration.yaml"]

  genv <- createGlobalEnv cfg
  env <- lowerCodensity $ mkEnv genv

  args <- getArgs

  let run = case args of
        [] -> do
          putStrLn "services started"
          forever (threadDelay 1000000000)
        _ -> do
          let cp = proc "sh" (["-c", "exec \"$@\"", "--"] <> args)
          (_, _, _, ph) <- createProcess cp
          exitWith =<< waitForProcess ph

  runAppWithEnv env $ do
    lowerCodensity $ do
      _modifyEnv <-
        traverseConcurrentlyCodensity
          ( \resource ->
              -- We add the 'fullSerachWithAll' overrrides is a hack to get
              -- around https://wearezeta.atlassian.net/browse/WPB-3796
              startDynamicBackend resource fullSearchWithAll
          )
          [backendA, backendB]
      liftIO run
