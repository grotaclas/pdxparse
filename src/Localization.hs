module Localization
        ( readL10n -- :: Settings -> IO L10n
        , module SettingsTypes
        ) where

import Control.Monad

import Data.List
import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HM
import Data.Text (Text)
import qualified Data.Text as T

import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as B8

import qualified Data.Yaml as Y

import System.Directory
import System.FilePath
import System.IO (hPutStrLn, stderr)

import SettingsTypes

readL10n :: Settings a -> IO L10n
readL10n settings = do
    let dir = steamDir settings
              </> steamApps settings
              </> game settings
              </> "localisation"
    files <- filterM doesFileExist
                . map (dir </>)
                . filter (language settings `isInfixOf`)
                    =<< getDirectoryContents dir
    liftM HM.unions . forM files $ \file -> do
        fileContents <- B.readFile file
        let fileContentsDoctored = B8.unlines . drop 1 . B8.lines $ fileContents
            parseResult = Y.decodeEither fileContentsDoctored
        case parseResult of
            Left exc -> do
                hPutStrLn stderr $ "Parsing localisation file " ++ file ++ " failed: " ++ show exc
                return HM.empty
            Right contents -> return contents
