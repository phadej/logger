{-# LANGUAGE BangPatterns #-}

module System.Log.FastLogger (
  -- * Creating a logger set
    LoggerSet
  , BufSize
  , logOpen
  , newLoggerSet
  , renewLoggerSet
  -- * Removing a logger set
  , rmLoggerSet
  -- * Writing a log message
  , pushLogMsg
  , LogMsg
  , fromByteString
  -- * Flushing buffered log messages
  , flushLogMsg
  -- * File rotation
  , module System.Log.FastLogger.File
  ) where

import qualified Blaze.ByteString.Builder as BD
import Blaze.ByteString.Builder.Internal.Types (Builder(..), BuildSignal(..), BufRange(..), runBuildStep, buildStep)
import Control.Applicative ((<$>))
import Control.Concurrent (getNumCapabilities, myThreadId, threadCapability, MVar, newMVar, takeMVar, putMVar)
import Control.Monad (when, replicateM)
import Data.Array (Array, listArray, (!))
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.IORef
import Data.Monoid (Monoid, mempty, mappend, (<>))
import Data.Word (Word8)
import Foreign.Marshal.Alloc (mallocBytes, free)
import Foreign.Ptr (Ptr, minusPtr, plusPtr)
import GHC.IO.Device (close)
import GHC.IO.FD (FD, openFile, writeRawBufferPtr)
import GHC.IO.IOMode (IOMode(..))
import System.Log.FastLogger.File

----------------------------------------------------------------

type Buffer = Ptr Word8
-- | The type for buffer size of each core.
type BufSize = Int

----------------------------------------------------------------

-- | Log message builder. Use ('<>') to append two LogMsg in O(1).
data LogMsg = LogMsg !Int Builder

instance Monoid LogMsg where
    mempty = LogMsg 0 (BD.fromByteString BS.empty)
    LogMsg s1 b1 `mappend` LogMsg s2 b2 = LogMsg (s1 + s2) (b1 <> b2)

-- | Creating 'LogMsg'
fromByteString :: ByteString -> LogMsg
fromByteString bs = LogMsg (BS.length bs) (BD.fromByteString bs)

----------------------------------------------------------------

-- | Writting 'LogMsg' using a buffer in blocking mode.
--   The size of 'LogMsg' must be smaller or equal to
--   the size of buffer.
writeLogMsg :: FD
            -> Buffer
            -> BufSize
            -> LogMsg
            -> IO ()
writeLogMsg fd buf size (LogMsg len builder)
  | size < len = error "writeLogMsg"
  | otherwise  = toBufIOWith buf size (write fd) builder

toBufIOWith :: Buffer -> BufSize -> (Buffer -> Int -> IO a) -> Builder -> IO a
toBufIOWith buf !size io (Builder build) = do
    signal <- runBuildStep step bufRange
    case signal of
        Done ptr _ -> io buf (ptr `minusPtr` buf)
        _          -> error "toBufIOWith"
  where
    !step = build (buildStep finalStep)
    !bufRange = BufRange buf (buf `plusPtr` size)
    finalStep !(BufRange p _) = return $ Done p ()

write :: FD -> Buffer -> Int -> IO ()
write fd buf len' = loop buf (fromIntegral len')
  where
    loop bf !len = do
        written <- writeRawBufferPtr "write" fd bf 0 (fromIntegral len)
        when (written < len) $
            loop (bf `plusPtr` fromIntegral written) (len - written)

----------------------------------------------------------------

data Logger = Logger (MVar Buffer) !BufSize (IORef LogMsg)

newLogger :: BufSize -> IO Logger
newLogger size = do
    buf <- getBuffer size
    mbuf <- newMVar buf
    lref <- newIORef mempty
    return $ Logger mbuf size lref

pushLog :: FD -> Logger -> LogMsg -> IO ()
pushLog fd logger@(Logger  _ size ref) nlogmsg@(LogMsg nlen _) = do
    needFlush <- atomicModifyIORef ref checkBuf
    when needFlush $ do
        flushLog fd logger
        pushLog fd logger nlogmsg
  where
    checkBuf ologmsg@(LogMsg olen _)
      | size < olen + nlen = (ologmsg, True)
      | otherwise          = (ologmsg <> nlogmsg, False)

flushLog :: FD -> Logger -> IO ()
flushLog fd (Logger mbuf size lref) = do
    logmsg <- atomicModifyIORef lref (\old -> (mempty, old))
    -- If a special buffer is prepared for flusher, this MVar could
    -- be removed. But such a code does not contribute logging speed
    -- according to experiment. And even with the special buffer,
    -- there is no grantee that this function is exclusively called
    -- for a buffer. So, we use MVar here.
    -- This is safe and speed penalty can be ignored.
    buf <- takeMVar mbuf
    writeLogMsg fd buf size logmsg
    putMVar mbuf buf

----------------------------------------------------------------

-- | Opening a log file. FIXME: Windows support.
logOpen :: FilePath -> IO FD
logOpen file = fst <$> openFile file AppendMode False -- FIXME blocking

getBuffer :: BufSize -> IO Buffer
getBuffer = mallocBytes

----------------------------------------------------------------

-- | A set of loggers.
--   The number of loggers is the capabilities of GHC RTS.
--   You can specify it with \"+RTS -N\<x\>\".
--   A buffer is prepared for each capability.
data LoggerSet = LoggerSet (IORef FD) (Array Int Logger)

-- | Creating a new 'LoggerSet'.
newLoggerSet :: BufSize -> FD -> IO LoggerSet
newLoggerSet size fd = do
    n <- getNumCapabilities
    loggers <- replicateM n $ newLogger size
    let arr = listArray (0,n-1) loggers
    fref <- newIORef fd
    return $ LoggerSet fref arr

-- | Writing a log message to the corresponding buffer.
pushLogMsg :: LoggerSet -> LogMsg -> IO ()
pushLogMsg (LoggerSet fref arr) logmsg = do
    (i, _) <- myThreadId >>= threadCapability
    let logger = arr ! i
    fd <- readIORef fref
    pushLog fd logger logmsg

-- | Flushing log messages in buffers.
flushLogMsg :: LoggerSet -> IO ()
flushLogMsg (LoggerSet fref arr) = do
    n <- getNumCapabilities
    fd <- readIORef fref
    mapM_ (flushIt fd) [0..n-1]
  where
    flushIt fd i = flushLog fd (arr ! i)

-- | Renewing 'FD' in 'LoggerSet'. Old 'FD' is closed.
renewLoggerSet :: LoggerSet -> FD -> IO ()
renewLoggerSet (LoggerSet fref _) newfd = do
    oldfd <- atomicModifyIORef fref (\fd -> (newfd, fd))
    close oldfd

rmLoggerSet :: LoggerSet -> IO ()
rmLoggerSet (LoggerSet fref arr) = do
    putStrLn "hey"
    n <- getNumCapabilities
    fd <- readIORef fref
    let nums = [0..n-1]
    mapM_ (flushIt fd) nums
    mapM_ freeIt nums
    close fd
    putStrLn "closed"
  where
    flushIt fd i = flushLog fd (arr ! i)
    freeIt i = do
        let (Logger mbuf _ _) = arr ! i
        takeMVar mbuf >>= free
