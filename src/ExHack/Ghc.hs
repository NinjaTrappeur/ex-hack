{-|
Module      : ExHack.Ghc
Description : GHC-API programs.
Copyright   : (c) Félix Baylac-Jacqué, 2018
License     : GPL-3
Stability   : experimental
Portability : POSIX
-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables   #-}
module ExHack.Ghc (
  UnitId(..),
  TypecheckedSource,
  DesugaredModule(..),
  getDesugaredMod,
  getModExports,
  getModImports,
  getModSymbols,
  unLoc,
  collectSymbols
  ) where

import           Avail                   (AvailInfo (..))
import           Control.DeepSeq         (force)
import           Control.Monad           (when, liftM2, forM)
import Control.Monad.State
import           Control.Monad.IO.Class  (MonadIO, liftIO)
import qualified Data.Map as Map
import           Data.Maybe              (fromMaybe, isNothing)
import           Data.Text               (pack)
import qualified Data.Text               as T (pack, unpack)
import Data.Maybe (maybeToList)
import qualified Distribution.Helper     as H (ChComponentName (ChLibName),
                                               components, ghcOptions,
                                               mkQueryEnv, runQuery)
import           Distribution.ModuleName (ModuleName, toFilePath)
import           FastString              (unpackFS)
import           GHC                     (DesugaredModule, GenLocated (..), Ghc,
                                          LoadHowMuch (..), ModSummary,
                                          TypecheckedSource, desugarModule,
                                          dm_core_module, dm_typechecked_module,
                                          findModule, getModSummary,
                                          getSessionDynFlags, getTokenStream,
                                          guessTarget, load, mkModuleName,
                                          moduleNameString, ms_textual_imps,
                                          noLoc, parseDynamicFlags, parseModule,
                                          runGhc, setSessionDynFlags,
                                          setTargets, typecheckModule, unLoc, RealSrcSpan, SrcSpan(RealSrcSpan, UnhelpfulSpan), SrcLoc(RealSrcLoc, UnhelpfulLoc), RealSrcLoc, Name)
import           GHC.Paths               (libdir)
import HieBin
import HieTypes
import HieUtils

import           HscTypes                (ModGuts (..))
import           Lexer                   (Token (ITqvarid, ITvarid))
import           Module                  (UnitId (..), Module(..))
import           Name                    (getOccString, nameModule_maybe)
import           Safe                    (headMay)
import           System.Directory               ( withCurrentDirectory
                                                , listDirectory
                                                , doesPathExist
                                                , doesDirectoryExist
                                                , doesFileExist
                                                , makeAbsolute
                                                )
import           System.FilePath         ((<.>), (</>), isExtensionOf)

import           ExHack.ModulePaths      (modName)
import           ExHack.Types            (ComponentRoot (..), LocatedSym (..),
                                          ModuleNameT (..), MonadLog (..),
                                          Package (..), PackageFilePath (..),
                                          SymName (..), getModName)
import           UniqSupply                     ( mkSplitUniqSupply )
import           NameCache                      ( initNameCache, NameCache )

-- | Retrieves a GHC-API's module after type-checking and desugaring it.
--
-- This function will call GHC to parse, typecheck and desugar the module.
--
-- This will fails if the pointed source code is not valid.
getDesugaredMod :: (MonadIO m, MonadLog m) => PackageFilePath -> ComponentRoot -> ModuleName -> m DesugaredModule
getDesugaredMod pfp cr mn =
    onModSum pfp cr mn (\modSum ->
        parseModule modSum >>= typecheckModule >>= desugarModule)

-- | Retrieves a module's imported symbols.
--
--   This function will call GHC to parse and typecheck the module.
--
--   This will fails if the pointed source code is not valid.
getModImports :: (MonadIO m, MonadLog m) => PackageFilePath -> ComponentRoot -> ModuleName -> m [ModuleNameT]
getModImports pfp cr mn =
    onModSum pfp cr mn (\modSum ->
        pure $ ModuleNameT . pack . moduleNameString . unLoc . snd <$> ms_textual_imps modSum)

-- | Retrieve all the symbols used in the module body.
--
--   This function wil use GHC to generate the tokens of source code.
getModSymbols :: (MonadIO m, MonadLog m) => Package -> PackageFilePath -> ComponentRoot -> ModuleName -> m [LocatedSym]
getModSymbols p pfp cr@(ComponentRoot crt) mn =
    withGhcEnv pfp cr mn $ do
        m <- findModule (mkModuleName $ T.unpack $ getModName mn) Nothing
        ts <- getTokenStream m
        let sns = (SymName . pack . unpackFS . getTNames) <$$> filter filterTokenTypes ts
        pure $ (\sn -> LocatedSym (p, fileName, sn)) <$> sns
        where
            filterTokenTypes (L _ (ITqvarid _)) = True
            filterTokenTypes (L _ (ITvarid _)) = True
            filterTokenTypes _ = False
            getTNames (ITqvarid (_,n)) = n
            getTNames (ITvarid n) = n
            getTNames _ = error "The impossible happened."
            (<$$>) = fmap . fmap
            fileName = crt </> toFilePath mn <.> "hs"

-- TODO: This returns symbols for all modules and components, not just for the given componentRoot and module name
-- We could filter the returned syms or we could just collect everything and make the granularity more coarse
getModSymbolsNew :: (MonadIO m, MonadLog m) => Package -> PackageFilePath -> ComponentRoot -> ModuleName -> m [LocatedSym]
getModSymbolsNew p (PackageFilePath pfp) cr@(ComponentRoot crt) mn = do
    hieFilePaths <- liftIO $ getHieFilesIn pfp
    uniq_supply <- liftIO $ mkSplitUniqSupply 'z'
    let nc = initNameCache uniq_supply []
    hieFiles <- liftIO $ evalStateT (collectHieFiles hieFilePaths) nc
    return $ concatMap (collectSymbols p) hieFiles 
      where
        collectHieFiles :: [FilePath] -> StateT NameCache IO [HieFile]
        collectHieFiles hieFilePaths = forM hieFilePaths $ \p -> do
            nc <- get
            (hf, nc') <- lift $ readHieFile nc p
            put nc' 
            return hf
        getHieFilesIn :: FilePath -> IO [FilePath]
        getHieFilesIn path = do
            exists <- doesPathExist path
            if exists then do
                isFile <- doesFileExist path
                isDir <- doesDirectoryExist path
                if isFile && ("hie" `isExtensionOf` path) then do
                    path' <- makeAbsolute path
                    return [path']
                else if isDir then do
                    cnts <- listDirectory path
                    withCurrentDirectory path $ foldMap getHieFilesIn cnts
                else return []
            else
                return []

collectSymbols :: Package -> HieFile -> [LocatedSym]
collectSymbols p hf = do
    (Right name, occurences) <- Map.toList $ generateReferencesMap $ getAsts $ hie_asts hf
    (sp, _) <- occurences
    (Module _ modName) <- maybeToList $ nameModule_maybe name
    let occName = getOccString name
        modNameString = moduleNameString modName
        symName =  SymName $ T.pack $ modNameString  <> "." <> occName -- TODO: Is this the 'correct' string?
        fp = hie_hs_file hf
    return $ LocatedSym (p, fp, L (RealSrcSpan sp) symName)


getCabalDynFlagsLib :: forall m. (MonadIO m) => FilePath -> m (Maybe [String])
getCabalDynFlagsLib fp = do
    mdir <- getDistDir
    let dist = fromMaybe "dist" mdir
    let qe = H.mkQueryEnv fp (fp </> dist)
    cs <- H.runQuery qe $ H.components $ (,) <$> H.ghcOptions
    pure $ fst <$> headMay (filter getLib cs)
  where
    getDistDir :: m (Maybe FilePath)
    getDistDir = do
        platformDir <- liftIO $ listDirectory $ ".stack-work" </> "dist"
        let mpd = ((".stack-work" </> "dist") </>) <$> headMay platformDir
        cabalInstallDir <- liftIO $ mapM listDirectory mpd
        let mid = headMay =<< cabalInstallDir
        pure $ liftM2 (</>) mpd mid
    getLib (_,H.ChLibName) = True
    getLib _ = False

-- | Retrieves a `DesugaredModule` exported symbols.
getModExports :: DesugaredModule -> [SymName]
getModExports = force $ fmap getAvName . mg_exports . dm_core_module

getAvName :: AvailInfo -> SymName
getAvName (Avail n) = SymName $ pack $ getOccString n
getAvName (AvailTC n _ _) = SymName $ pack $ getOccString n

withGhcEnv :: (MonadIO m, MonadLog m) => PackageFilePath -> ComponentRoot -> ModuleName -> Ghc a -> m a
withGhcEnv (PackageFilePath pfp) (ComponentRoot cr) mn a =
    liftIO $ withCurrentDirectory pfp $ do
        dflagsCM <- getCabalDynFlagsLib pfp
        when (isNothing dflagsCM) . logError $ "Cannot retrieve cabal flags for " <> T.pack pfp <> "."
        let dflagsC = fromMaybe [] dflagsCM
        liftIO . runGhc (Just libdir) $ do
            dflagsS <- getSessionDynFlags
            (dflags, _, _) <- parseDynamicFlags dflagsS (noLoc <$> dflagsC)
            _ <- setSessionDynFlags dflags
            target <- guessTarget fileName Nothing
            setTargets [target]
            _ <- load LoadAllTargets
            a
  where
    fileName = cr </> toFilePath mn

onModSum :: (MonadIO m, MonadLog m) => PackageFilePath -> ComponentRoot -> ModuleName -> (ModSummary -> Ghc a) -> m a
onModSum pfp cr mn f = withGhcEnv pfp cr mn
                        (getModSummary (mkModuleName $ modName mn) >>= f)
