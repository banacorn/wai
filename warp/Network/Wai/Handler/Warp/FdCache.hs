{-# LANGUAGE BangPatterns, FlexibleInstances #-}

module Network.Wai.Handler.Warp.FdCache (
    initialize
  , getFd
  , MutableFdCache
  ) where

import Control.Applicative ((<$>), (<*>))
import Control.Concurrent (forkIO, threadDelay, ThreadId, killThread)
import Control.Exception (mask_)
import Data.Hashable (hash)
import Data.IORef (IORef, newIORef, readIORef, writeIORef, atomicModifyIORef, mkWeakIORef)
import Network.Wai.Handler.Warp.MultiMap
import System.Posix.IO (openFd, defaultFileFlags, OpenMode(ReadOnly), closeFd)
import System.Posix.Types (Fd)

----------------------------------------------------------------

data Status = Active | Inactive

newtype MutableStatus = MutableStatus (IORef Status)

type Refresh = IO ()

status :: MutableStatus -> IO Status
status (MutableStatus ref) = readIORef ref

newActiveStatus :: IO MutableStatus
newActiveStatus = MutableStatus <$> newIORef Active

refresh :: MutableStatus -> Refresh
refresh (MutableStatus ref) = writeIORef ref Active

inactive :: MutableStatus -> IO ()
inactive (MutableStatus ref) = writeIORef ref Inactive

----------------------------------------------------------------

data FdEntry = FdEntry !FilePath !Fd !MutableStatus

newFdEntry :: FilePath -> IO FdEntry
newFdEntry path = FdEntry path
              <$> openFd path ReadOnly Nothing defaultFileFlags
              <*> newActiveStatus

----------------------------------------------------------------

type Hash = Int
type FdCache = MMap Hash FdEntry
newtype MutableFdCache = MutableFdCache { unMutableFdCache :: IORef FdCache }

newMutableFdCache :: IO MutableFdCache
newMutableFdCache = MutableFdCache <$> newIORef empty

fdCache :: MutableFdCache -> IO FdCache
fdCache (MutableFdCache ref) = readIORef ref

swapWithNew :: MutableFdCache -> IO FdCache
swapWithNew (MutableFdCache ref) = atomicModifyIORef ref (\t -> (empty, t))

update :: MutableFdCache -> (FdCache -> FdCache) -> IO ()
update (MutableFdCache ref) f = do
    !_  <- atomicModifyIORef ref $ \t -> let !new = f t in (new, ())
    return ()

look :: MutableFdCache -> FilePath -> Hash -> IO (Maybe FdEntry)
look mfc path key = searchWith key check <$> fdCache mfc
  where
    check (One ent@(FdEntry path' _ _))
      | path == path' = Just ent
      | otherwise     = Nothing
    check (Tom ent@(FdEntry path' _ _) vs)
      | path == path' = Just ent
      | otherwise     = check vs

----------------------------------------------------------------

initialize :: Int -> IO MutableFdCache
initialize duration = do
    mfc <- newMutableFdCache
    tid <- forkIO $ loop mfc
    -- Registering finalizer to this IORef.
    -- When Warp is finished in GHCi, this IORef is GCed.
    -- At that time, we should close all opened file descriptors.
    _ <- mkWeakIORef (unMutableFdCache mfc) $ terminate mfc tid
    return mfc
  where
    loop mfc = do
        mask_ $ do
            old <- swapWithNew mfc
            new <- pruneWith old prune
            update mfc (merge new)
        threadDelay duration
        loop mfc

terminate :: MutableFdCache -> ThreadId -> IO ()
terminate (MutableFdCache icache) tid = do
    killThread tid
    readIORef icache >>= mapM_ go . toList
  where
    go (_, FdEntry _ fd _) = closeFd fd

prune :: t -> Some FdEntry -> IO [(t, Some FdEntry)]
prune k v@(One (FdEntry _ fd mst)) = status mst >>= prune'
  where
    prune' Active   = inactive mst >> return [(k,v)]
    prune' Inactive = closeFd fd   >> return []
prune k (Tom ent@(FdEntry _ fd mst) vs) = status mst >>= prune'
  where
    prune' Active = do
        inactive mst
        zs <- prune k vs
        case zs of
            []        -> return [(k,One ent)]
            [(_,zvs)] -> return [(k,Tom ent zvs)]
            _         -> error "prune"
    prune' Inactive = closeFd fd >> prune k vs

----------------------------------------------------------------

getFd :: MutableFdCache -> FilePath -> IO (Fd, Refresh)
getFd mfc path = look mfc path key >>= getFd'
  where
    key = hash path
    getFd' Nothing = do
        ent@(FdEntry _ fd mst) <- newFdEntry path
        update mfc (insert key ent)
        return (fd, refresh mst)
    getFd' (Just (FdEntry _ fd mst)) = do
        refresh mst
        return (fd, refresh mst)
