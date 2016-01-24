{-# LANGUAGE OverloadedStrings #-}
module SettingsTypes
    ( L10n
    , Settings
        -- Export everything EXCEPT L10n
        ( steamDir
        , steamApps
        , game
        , language
        , gameVersion
        , currentFile
        , currentIndent
        , info
        )
    , emptySettings
    , setGameL10n
    , PP, PPT
    , indentUp, indentDown
    , withCurrentIndent, withCurrentIndentZero
    , alsoIndent, alsoIndent'
    , getGameL10n
    , getGameL10nDefault
    , getGameL10nIfPresent
    , withCurrentFile
    , getLangs
    , unfoldM, concatMapM 
    , fromReaderT, toReaderT
    ) where

import Debug.Trace

import Control.Monad.Identity (runIdentity)
import Control.Monad.Reader

import Data.Foldable (fold)
import Data.Maybe

import Data.Text (Text)
import Text.Shakespeare.I18N (Lang)

import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HM

type L10n = HashMap Text Text

data Settings a = Settings {
        steamDir    :: FilePath
    ,   steamApps   :: FilePath
    ,   game        :: String
    ,   language    :: String
    ,   gameVersion :: Text
    ,   gameL10n    :: L10n
    ,   langs       :: [Lang]
    -- Local state
    ,   currentFile :: Maybe FilePath
    ,   currentIndent :: Maybe Int
    -- Extra information
    ,   info :: Maybe a
    } deriving (Show)

-- All undefined/Nothing settings, except langs.
emptySettings :: Settings a
emptySettings = Settings
    { steamDir = undefined
    , steamApps = undefined
    , game = undefined
    , language = undefined
    , gameVersion = undefined
    , gameL10n = undefined
    , currentFile = Nothing
    , currentIndent = Nothing
    , langs = ["en"]
    , info = Nothing
    }

setGameL10n :: Settings a -> L10n -> Settings a
setGameL10n settings l10n = settings { gameL10n = l10n }

-- Pretty-printing monad, and its transformer version
type PP extra a = Reader (Settings extra) a -- equal to PPT extra Identity a
type PPT extra m a = ReaderT (Settings extra) m a

-- Increase current indentation by 1 for the given action.
-- If there is no current indentation, set it to 1.
indentUp :: PP extra a -> PP extra a
indentUp go = do
    mindent <- asks currentIndent
    let mindent' = Just (maybe 1 succ mindent)
    local (\s -> s { currentIndent = mindent' }) go

-- Decrease current indent level by 1 for the given action.
-- For use where a level of indentation should be skipped.
indentDown :: PP extra a -> PP extra a
indentDown go = do
    mindent <- asks currentIndent
    let mindent' = Just (maybe 0 pred mindent)
    local (\s -> s { currentIndent = mindent' }) go

-- | Pass the current indent to the action.
-- If there is no current indent, set it to 1.
withCurrentIndent :: (Int -> PP extra a) -> PP extra a
withCurrentIndent = withCurrentIndentBaseline 1

-- | Pass the current indent to the action.
-- If there is no current indent, set it to 0.
withCurrentIndentZero :: (Int -> PP extra a) -> PP extra a
withCurrentIndentZero = withCurrentIndentBaseline 0

withCurrentIndentBaseline :: Int -> (Int -> PP extra a) -> PP extra a
withCurrentIndentBaseline base go = do
    mindent <- asks currentIndent
    local (\s ->
            if isNothing mindent
            then s { currentIndent = Just base }
            else s)
          (go . fromJust =<< asks currentIndent)

-- Bundle a value with the current indentation level.
alsoIndent :: PP extra a -> PP extra (Int, a)
alsoIndent mx = withCurrentIndent $ \i -> mx >>= \x -> return (i,x)
alsoIndent' :: a -> PP extra (Int, a)
alsoIndent' x = withCurrentIndent $ \i -> return (i,x)

getGameL10n :: Text -> PP extra Text
getGameL10n key = HM.lookupDefault key key <$> asks gameL10n

getGameL10nDefault :: Text -> Text -> PP extra Text
getGameL10nDefault def key = HM.lookupDefault def key <$> asks gameL10n

getGameL10nIfPresent :: Text -> PP extra (Maybe Text)
getGameL10nIfPresent key = HM.lookup key <$> asks gameL10n

-- Pass the current file to the action.
-- If there is no current file, set it to "(unknown)".
withCurrentFile :: (String -> PP extra a) -> PP extra a
withCurrentFile go = do
    mfile <- asks currentFile
    local (\s -> if isNothing mfile
                    then s { currentFile = Just "(unknown)" }
                    else s)
          (go . fromJust =<< asks currentFile)

-- Get the list of output languages.
getLangs :: PP extra [Lang]
getLangs = asks langs

-- Misc. utilities

-- As unfoldr, but argument is monadic
unfoldM :: Monad m => (a -> m (Maybe (b, a))) -> a -> m [b]
unfoldM f = go where
    go x = do
        res <- f x
        case res of
            Nothing -> return []
            Just (next, x') -> do
                rest <- go x'
                return (next:rest)

concatMapM :: (Monad m, Traversable t, Monoid (t b)) => (a -> m (t b)) -> t a -> m (t b)
concatMapM f xs = liftM fold . mapM f $ xs

fromReaderT :: ReaderT r m a -> Reader r (m a)
fromReaderT mx = runReaderT mx <$> ask

toReaderT :: Reader r (m a) -> ReaderT r m a
toReaderT mx = ReaderT (runIdentity . runReaderT mx)