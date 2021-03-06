{-# LANGUAGE BangPatterns        #-}
{-# LANGUAGE CPP                 #-}
{-# LANGUAGE Rank2Types          #-}
{-# LANGUAGE ScopedTypeVariables #-}
#if !MIN_VERSION_deepseq(1,4,0)
{-# OPTIONS_GHC -fno-warn-orphans #-}
#endif
module Main where

import Prelude ()
import Prelude.Compat
import Distribution.Compat.Semigroup

import Control.Applicative                         (many, (<**>), (<|>))
import Control.DeepSeq                             (NFData (..), force)
import Control.Exception                           (evaluate)
import Control.Monad                               (join, unless, when)
import Data.Foldable                               (for_, traverse_)
import Data.List                                   (isPrefixOf, isSuffixOf, sort)
import Data.Maybe                                  (mapMaybe)
import Data.Monoid                                 (Sum (..))
import Data.String                                 (fromString)
import Distribution.License                        (License (..))
import Distribution.PackageDescription.Check       (PackageCheck (..), checkPackage)
import Distribution.PackageDescription.PrettyPrint (showGenericPackageDescription)
import Distribution.Simple.Utils                   (fromUTF8LBS, ignoreBOM, toUTF8BS)
import System.Directory                            (getAppUserDataDirectory)
import System.Exit                                 (exitFailure)
import System.FilePath                             ((</>))

import Data.Orphans ()

import qualified Codec.Archive.Tar                      as Tar
import qualified Data.ByteString                        as B
import qualified Data.ByteString.Char8                  as B8
import qualified Data.ByteString.Lazy                   as BSL
import qualified Data.Map                               as Map
import qualified Distribution.PackageDescription.Parse  as ReadP
import qualified Distribution.PackageDescription.Parsec as Parsec
import qualified Distribution.Parsec.Common             as Parsec
import qualified Distribution.Parsec.Parser             as Parsec
import qualified Distribution.ParseUtils                as ReadP
import qualified Distribution.SPDX                      as SPDX

import           Distribution.Compat.Lens
import qualified Distribution.Types.BuildInfo.Lens                 as L
import qualified Distribution.Types.Executable.Lens                as L
import qualified Distribution.Types.ForeignLib.Lens                as L
import qualified Distribution.Types.GenericPackageDescription.Lens as L
import qualified Distribution.Types.Library.Lens                   as L
import qualified Distribution.Types.PackageDescription.Lens        as L
import qualified Distribution.Types.SourceRepo.Lens                as L
import qualified Options.Applicative                               as O

#ifdef MIN_VERSION_tree_diff
import Data.TreeDiff      (ansiWlEditExpr, ediff)
import Instances.TreeDiff ()
#endif

parseIndex :: (Monoid a, NFData a) => (FilePath -> Bool) -> (FilePath -> BSL.ByteString -> IO a) -> IO a
parseIndex predicate action = do
    cabalDir  <- getAppUserDataDirectory "cabal"
    cfg       <- B.readFile (cabalDir </> "config")
    cfgFields <- either (fail . show) pure $ Parsec.readFields cfg
    let repos        = reposFromConfig cfgFields
        repoCache    = case lookupInConfig "remote-repo-cache" cfgFields of
            []        -> cabalDir </> "packages"  -- Default
            (rrc : _) -> rrc                      -- User-specified
        tarName repo = repoCache </> repo </> "01-index.tar"
    mconcat <$> traverse (parseIndex' predicate action . tarName) repos

parseIndex' :: (Monoid a, NFData a) => (FilePath -> Bool) -> (FilePath -> BSL.ByteString -> IO a) -> FilePath -> IO a
parseIndex' predicate action path = do
    putStrLn $ "Reading index from: " ++ path
    contents <- BSL.readFile path
    let entries = Tar.read contents
        entries' = Tar.foldEntries cons [] (error . show) entries
    foldIO f entries'

  where
    cons entry entries
        | predicate (Tar.entryPath entry) = entry : entries
        | otherwise = entries

    f entry = case Tar.entryContent entry of
        Tar.NormalFile contents _
            | ".cabal" `isSuffixOf` fpath -> action fpath contents >>= evaluate . force
            | otherwise                   -> return mempty
        Tar.Directory -> return mempty
        _             -> putStrLn ("Unknown content in " ++ fpath) >> return mempty
     where
       fpath = Tar.entryPath entry

readFieldTest :: FilePath -> BSL.ByteString -> IO ()
readFieldTest fpath bsl = case Parsec.readFields $ bslToStrict bsl of
    Right _  -> return ()
    Left err -> putStrLn $ fpath ++ "\n" ++ show err

-- | Map with unionWith monoid
newtype M k v = M (Map.Map k v)
    deriving (Show)
instance (Ord k, Monoid v) => Monoid (M k v) where
    mempty = M Map.empty
    mappend (M a) (M b) = M (Map.unionWith mappend a b)
instance (NFData k, NFData v) => NFData (M k v) where
    rnf (M m) = rnf m

compareTest :: FilePath -> BSL.ByteString -> IO (Sum Int, Sum Int, M Parsec.PWarnType (Sum Int))
compareTest fpath bsl = do
    let str = ignoreBOM $ fromUTF8LBS bsl

    putStrLn $ "::: " ++ fpath
    (readp, readpWarnings)  <- case ReadP.parseGenericPackageDescription str of
        ReadP.ParseOk ws x    -> return (x, ws)
        ReadP.ParseFailed err -> print err >> exitFailure
    traverse_ (putStrLn . ReadP.showPWarning fpath) readpWarnings

    let (warnings, parsec') = Parsec.runParseResult $ Parsec.parseGenericPackageDescription (bslToStrict bsl)
    traverse_ (putStrLn . Parsec.showPWarning fpath) warnings
    parsec <- case parsec' of
        Right x -> return x
        Left (_, errors) -> do
            traverse_ (putStrLn . Parsec.showPError fpath) errors
            print readp
            exitFailure

    let patchLocation (Just "") = Nothing
        patchLocation x         = x

    let unspecifiedToNone (Right UnspecifiedLicense) = Left SPDX.NONE
        unspecifiedToNone x                          = x

    -- Old parser is broken for many descriptions, and other free text fields
    let readp0  = readp
            & L.packageDescription . L.description .~ ""
            & L.packageDescription . L.synopsis    .~ ""
            & L.packageDescription . L.maintainer  .~ ""
            -- ReadP parses @location:@ as @repoLocation = Just ""@
            & L.packageDescription . L.sourceRepos . traverse . L.repoLocation %~ patchLocation
            & L.condExecutables  . traverse . _2 . traverse . L.exeName .~ fromString ""
            -- custom fields: no order
            & L.buildInfos . L.customFieldsBI %~ sort
            -- license UnspecifiedLicense -> NONE
            & L.packageDescription . L.licenseRaw %~ unspecifiedToNone


    let parsec0  = parsec
            & L.packageDescription . L.description .~ ""
            & L.packageDescription . L.synopsis    .~ ""
            & L.packageDescription . L.maintainer  .~ ""
            -- ReadP doesn't (always) parse sublibrary or executable or other component names
            & L.condSubLibraries . traverse . _2 . traverse . L.libName .~ Nothing
            & L.condExecutables  . traverse . _2 . traverse . L.exeName .~ fromString ""
            & L.condForeignLibs  . traverse . _2 . traverse . L.foreignLibName .~ fromString ""
            -- custom fields: no order. TODO: see if we can preserve it.
            & L.buildInfos . L.customFieldsBI %~ sort

    -- hs-source-dirs ".", old parser broken
    -- See e.g. http://hackage.haskell.org/package/hledger-ui-0.27/hledger-ui.cabal executable
    let parsecHsSrcDirs = parsec0 & toListOf (L.buildInfos . L.hsSourceDirs)
    let readpHsSrcDirs  = readp0  & toListOf (L.buildInfos . L.hsSourceDirs)
    let filterDotDirs   = filter (/= ".")

    let parsec1 = if parsecHsSrcDirs /= readpHsSrcDirs && fmap filterDotDirs parsecHsSrcDirs == readpHsSrcDirs
        then parsec0 & L.buildInfos . L.hsSourceDirs %~ filterDotDirs
        else parsec0

    -- Compare two parse results
    -- ixset-1.0.4 has invalid prof-options, it's the only exception!
    unless (readp0 == parsec1 || fpath == "ixset/1.0.4/ixset.cabal") $ do
#ifdef MIN_VERSION_tree_diff
            print $ ansiWlEditExpr $ ediff readp parsec
#else
            putStrLn "<<<<<<"
            print readp
            putStrLn "======"
            print parsec
            putStrLn ">>>>>>"
#endif
            exitFailure

    let readpWarnCount  = Sum (length readpWarnings)
    let parsecWarnCount = Sum (length warnings)

    when (readpWarnCount > parsecWarnCount) $ do
        putStrLn "There are more readpWarnings"
        -- hint has -- in brace syntax, readp thinks it's a section
        -- http://hackage.haskell.org/package/hint-0.3.2.3/revision/0.cabal
        unless ("/hint.cabal" `isSuffixOf` fpath) exitFailure

    let parsecWarnMap   = foldMap (\(Parsec.PWarning t _ _) -> M $ Map.singleton t 1) warnings
    return (readpWarnCount, parsecWarnCount, parsecWarnMap)

parseReadpTest :: FilePath -> BSL.ByteString -> IO (Sum Int)
parseReadpTest fpath bsl = do
    let str = ignoreBOM $ fromUTF8LBS bsl
    case ReadP.parseGenericPackageDescription str of
        ReadP.ParseOk _ _     -> return (Sum 1)
        ReadP.ParseFailed err -> putStrLn fpath >> print err >> exitFailure

parseParsecTest :: FilePath -> BSL.ByteString -> IO (Sum Int)
parseParsecTest fpath bsl = do
    let bs = bslToStrict bsl
    let (_warnings, parsec) = Parsec.runParseResult $ Parsec.parseGenericPackageDescription bs
    case parsec of
        Right _ -> return (Sum 1)
        Left (_, errors) -> do
            traverse_ (putStrLn . Parsec.showPError fpath) errors
            exitFailure

parseCheckTest :: FilePath -> BSL.ByteString -> IO CheckResult
parseCheckTest fpath bsl = do
    let bs = bslToStrict bsl
    let (_warnings, parsec) = Parsec.runParseResult $ Parsec.parseGenericPackageDescription bs
    case parsec of
        Right gpd -> do
            let checks = checkPackage gpd Nothing
            -- one for file, many checks
            return (CheckResult 1 0 0 0 0 0 <> foldMap toCheckResult checks)
        Left (_, errors) -> do
            traverse_ (putStrLn . Parsec.showPError fpath) errors
            exitFailure

data CheckResult = CheckResult !Int !Int !Int !Int !Int !Int

instance NFData CheckResult where
    rnf !_ = ()

instance Semigroup CheckResult where
    CheckResult n a b c d e <> CheckResult n' a' b' c' d' e' =
        CheckResult (n + n') (a + a') (b + b') (c + c') (d + d') (e + e')

instance Monoid CheckResult where
    mempty = CheckResult 0 0 0 0 0 0
    mappend = (<>)

toCheckResult :: PackageCheck -> CheckResult
toCheckResult PackageBuildImpossible {}    = CheckResult 0 1 0 0 0 0
toCheckResult PackageBuildWarning {}       = CheckResult 0 0 1 0 0 0
toCheckResult PackageDistSuspicious {}     = CheckResult 0 0 0 1 0 0
toCheckResult PackageDistSuspiciousWarn {} = CheckResult 0 0 0 0 1 0
toCheckResult PackageDistInexcusable {}    = CheckResult 0 0 0 0 0 1

roundtripTest :: FilePath -> BSL.ByteString -> IO (Sum Int)
roundtripTest fpath bsl = do
    let bs = bslToStrict bsl
    x0 <- parse "1st" bs
    let bs' = showGenericPackageDescription x0
    y0 <- parse "2nd" (toUTF8BS bs')

    -- we mungled license here
    let y1 = y0

    -- license-files: ""
    let stripEmpty = filter (/="")
    let x1 = x0 & L.packageDescription . L.licenseFiles %~ stripEmpty
    let y2 = y1 & L.packageDescription . L.licenseFiles %~ stripEmpty

    let y = y2 & L.packageDescription . L.description .~ ""
    let x = x1 & L.packageDescription . L.description .~ ""

    unless (x == y || fpath == "ixset/1.0.4/ixset.cabal") $ do
        putStrLn fpath
#ifdef MIN_VERSION_tree_diff
        print $ ansiWlEditExpr $ ediff x y
#else
        putStrLn "<<<<<<"
        print x
        putStrLn "======"
        print y
        putStrLn ">>>>>>"
#endif
        putStrLn bs'
        exitFailure

    return (Sum 1)
  where
    parse phase c = do
        let (_, x') = Parsec.runParseResult $ Parsec.parseGenericPackageDescription c
        case x' of
            Right gpd -> pure gpd
            Left (_, errs) -> do
                putStrLn $ fpath ++ " " ++ phase
                traverse_ print errs
                B.putStr c
                fail "parse error"

main :: IO ()
main = join (O.execParser opts)
  where
    opts = O.info (optsP <**> O.helper) $ mconcat
        [ O.fullDesc
        , O.progDesc "tests using Hackage's index"
        ]

    optsP = subparser
        [ command "read-fields" readFieldsP "Parse outer format (to '[Field]', TODO: apply Quirks)"
        , command "parsec"      parsecP     "Parse GPD with parsec"
        , command "roundtrip"   roundtripP  "parse . pretty . parse = parse"
        , command "compare"     compareP    "compare readp and parsec results"
        , command "readp"       readpP      "Parse GPD with readp"
        , command "check"       checkP      "Check GPD"
        ] <|> pure defaultA

    defaultA = do
        putStrLn "Default action: parsec k"
        parsecA (mkPredicate ["k"])

    readFieldsP = readFieldsA <$> prefixP
    readFieldsA pfx = parseIndex pfx readFieldTest

    parsecP = parsecA <$> prefixP
    parsecA pfx = do
        Sum n <- parseIndex pfx parseParsecTest
        putStrLn $ show n ++ " files processed"

    roundtripP = roundtripA <$> prefixP
    roundtripA pfx = do
        Sum n <- parseIndex pfx roundtripTest
        putStrLn $ show n ++ " files processed"

    -- to be removed soon
    compareP = compareA <$> prefixP
    compareA pfx = do
        (Sum readpCount, Sum parsecCount, M warn) <- parseIndex pfx compareTest
        putStrLn $ "readp warnings: " ++ show readpCount
        putStrLn $ "parsec count:   " ++ show parsecCount
        for_ (Map.toList warn) $ \(t, Sum c) ->
            putStrLn $ " - " ++ show t ++ " : " ++ show c

    -- to be removed soon
    readpP = readpA <$> prefixP
    readpA pfx = do
        Sum n <- parseIndex pfx parseReadpTest
        putStrLn $ show n ++ " files processed"

    checkP = checkA <$> prefixP
    checkA pfx = do
        CheckResult n a b c d e <- parseIndex pfx parseCheckTest
        putStrLn $ show n ++ " files processed"
        putStrLn $ show a ++ " build impossible"
        putStrLn $ show b ++ " build warning"
        putStrLn $ show c ++ " build dist suspicious"
        putStrLn $ show d ++ " build dist suspicious warning"
        putStrLn $ show e ++ " build dist inexcusable"

    prefixP = fmap mkPredicate $ many $ O.strArgument $ mconcat
        [ O.metavar "PREFIX"
        , O.help "Check only files starting with a prefix"
        ]

    mkPredicate [] = const True
    mkPredicate pfxs = \n -> any (`isPrefixOf` n) pfxs

    command name p desc = O.command name (O.info (p <**> O.helper) (O.progDesc desc))
    subparser = O.subparser . mconcat

-------------------------------------------------------------------------------
--
-------------------------------------------------------------------------------

bslToStrict :: BSL.ByteString -> B.ByteString
#if MIN_VERSION_bytestring(0,10,0)
bslToStrict = BSL.toStrict
#else
-- Not effective!
bslToStrict = B.concat . BSL.toChunks
#endif

-------------------------------------------------------------------------------
-- Index shuffling
-------------------------------------------------------------------------------

-- TODO: Use 'Cabal' for this?
reposFromConfig :: [Parsec.Field ann] -> [String]
reposFromConfig fields = takeWhile (/= ':') <$> mapMaybe f fields
  where
    f (Parsec.Field (Parsec.Name _ name) fieldLines)
        | B8.unpack name == "remote-repo" =
            Just $ fieldLinesToString fieldLines
    f (Parsec.Section (Parsec.Name _ name) [Parsec.SecArgName _ secName] _fieldLines)
        | B8.unpack name == "repository" =
            Just $ B8.unpack secName
    f _ = Nothing

-- | Looks up the given key in the cabal configuration file
lookupInConfig :: String -> [Parsec.Field ann] -> [String]
lookupInConfig key = mapMaybe f
  where
    f (Parsec.Field (Parsec.Name _ name) fieldLines)
        | B8.unpack name == key =
            Just $ fieldLinesToString fieldLines
    f _ = Nothing

fieldLinesToString :: [Parsec.FieldLine ann] -> String
fieldLinesToString fieldLines =
    B8.unpack $ B.concat $ bsFromFieldLine <$> fieldLines
  where
    bsFromFieldLine (Parsec.FieldLine _ bs) = bs

-------------------------------------------------------------------------------
-- Utilities
-------------------------------------------------------------------------------

foldIO :: (Monoid m, NFData m) => (a -> IO m) -> [a] -> IO m
foldIO f = go mempty where
    go !acc [] = return acc
    go !acc (x : xs) = do
        y <- f x
        go (mappend acc y) xs

-------------------------------------------------------------------------------
-- Orphans
-------------------------------------------------------------------------------

#if !MIN_VERSION_deepseq(1,4,0)
instance NFData a => NFData (Sum a) where
    rnf (Sum a)  = rnf a
#endif
