{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleContexts #-}
module Main where

import Prelude as P
import Conduit
import Control.Monad (void, when, zipWithM_)
import Data.Conduit.List
import Test.Hspec
import Data.Conduit.Tar
import System.Directory
import Data.ByteString as S
import Data.ByteString.Char8 as S8
import Data.Int
import System.IO
import System.FilePath
import Control.Exception

main :: IO ()
main = do
    let baseTmp = "tar-conduit-tests"
    isStack <- doesDirectoryExist ".stack-work"
    let testPaths =
            ["src", "./tests", "README.md", "ChangeLog.md", "LICENSE"] ++
            if isStack
                then [".stack-work", "./sample"]
                else []
    hspec $ do
        describe "tar/untar" $ do
            let tarUntarContent dir =
                    runConduitRes $
                    yield dir .| void tarFilePath .| untar (const (foldC >>= yield)) .| foldC
            it "content" $ do
                c <- collectContent "src"
                tarUntarContent "src" `shouldReturn` c
        describe "tar/untar/tar" $ do
            around (withTempTarFiles baseTmp) $
                it "structure" $ \(fpIn, hIn, outDir, fpOut) -> do
                    writeTarball hIn testPaths
                    hClose hIn
                    extractTarball fpIn (Just outDir)
                    curDir <- getCurrentDirectory
                    finally
                        (setCurrentDirectory outDir >> createTarball fpOut testPaths)
                        (setCurrentDirectory curDir)
                    tb1 <- readTarball fpIn
                    tb2 <- readTarball fpOut
                    P.length tb1 `shouldBe` P.length tb2
                    zipWithM_ shouldBe (fmap fst tb2) (fmap fst tb1)
                    zipWithM_ shouldBe (fmap snd tb2) (fmap snd tb1)
        describe "ustar" ustarSpec
        describe "GNUtar" gnutarSpec

defFileInfo :: FileInfo
defFileInfo =
    FileInfo
    { filePath = "test-file-name"
    , fileUserId = 1000
    , fileUserName = "test-user-name"
    , fileGroupId = 1000
    , fileGroupName = "test-group-name"
    , fileMode = 0o644
    , fileSize = 0
    , fileType = FTNormal
    , fileModTime = 123456789
    }


fileInfoExpectation :: [(FileInfo, ByteString)] -> IO ()
fileInfoExpectation files = do
    let source = P.concat [[Left fi, Right content] | (fi, content) <- files]
        collect fi = do
            content <- foldC
            yield (fi, content)
    result <- runConduit $ sourceList source .| void tar .| untar collect .| sinkList
    result `shouldBe` files


emptyFileInfoExpectation :: FileInfo -> IO ()
emptyFileInfoExpectation fi = fileInfoExpectation [(fi, "")]

ustarSpec :: Spec
ustarSpec = do
    it "minimal" $ do
        emptyFileInfoExpectation defFileInfo
    it "long file name <255" $ do
        emptyFileInfoExpectation $
            defFileInfo {filePath = S8.pack (P.replicate 99 'f' </> P.replicate 99 'o')}


gnutarSpec :: Spec
gnutarSpec = do
    it "LongLink - a file with long file name" $ do
        emptyFileInfoExpectation $
            defFileInfo
            { filePath =
                  S8.pack (P.replicate 100 'f' </> P.replicate 100 'o' </> P.replicate 99 'b')
            }
    it "LongLink - multiple files with long file names" $ do
        fileInfoExpectation
            [ ( defFileInfo
                { filePath =
                      S8.pack (P.replicate 100 'f' </> P.replicate 100 'o' </> P.replicate 99 'b')
                , fileSize = 10
                }
              , "1234567890")
            , ( defFileInfo
                { filePath =
                      S8.pack (P.replicate 1000 'g' </> P.replicate 1000 'o' </> P.replicate 99 'b')
                , fileSize = 11
                }
              , "abcxdefghij")
            ]
    it "Large User Id" $ do emptyFileInfoExpectation $ defFileInfo {fileUserId = 0o777777777}
    it "All Large Numeric Values" $ do
        emptyFileInfoExpectation $
            defFileInfo
            { fileUserId = 0x7FFFFFFFFFFFFFFF
            , fileGroupId = 0x7FFFFFFFFFFFFFFF
            , fileModTime = fromIntegral (maxBound :: Int64)
            }
    it "Negative Mod Time" $ do
        emptyFileInfoExpectation $
            defFileInfo
            { fileModTime = fromIntegral (minBound :: Int64)
            }



withTempTarFiles :: FilePath -> ((FilePath, Handle, FilePath, FilePath) -> IO c) -> IO c
withTempTarFiles base =
    bracket
        (do tmpDir <- getTemporaryDirectory
            (fp1, h1) <- openBinaryTempFile tmpDir (addExtension base ".tar")
            let outPath = dropExtension fp1 ++ ".out"
            return (fp1, h1, outPath, addExtension outPath ".tar")
        )
        (\(fp, h, dirOut, fpOut) -> do
             hClose h
             removeFile fp
             doesDirectoryExist dirOut >>= (`when` removeDirectoryRecursive dirOut)
             doesFileExist fpOut >>= (`when` removeFile fpOut)
        )


readTarball
  :: (MonadIO m, MonadThrow m, MonadBaseControl IO m) =>
     FilePath -> m [(FileInfo, Maybe ByteString)]
readTarball fp = runConduitRes $ sourceFileBS fp .| untar grabBoth .| sinkList
  where
    grabBoth fi =
        case fileType fi of
            FTNormal -> do
                content <- foldC
                yield (fi, Just content)
            _ -> yield (fi, Nothing)


collectContent :: FilePath -> IO (ByteString)
collectContent dir =
    runConduitRes $
    sourceDirectoryDeep False dir .| mapMC (\fp -> runConduit (sourceFileBS fp .| foldC)) .| foldC

