{-# LANGUAGE CPP #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE UnboxedTuples, MagicHash #-}
module Network.Wai.Handler.Warp.Timeout (
    Manager
  , Handle
  , TimeoutAction
  , initialize
  , stopManager
  , register
  , registerKillThread
  , tickle
  , pause
  , resume
  , cancel
  , withManager
  , dummyHandle
  ) where

#if MIN_VERSION_base(4,6,0)
import Control.Concurrent (mkWeakThreadId, ThreadId)
#else
import GHC.Conc (ThreadId(..))
import GHC.Exts (mkWeak#)
import GHC.IO (IO (IO))
#endif
import GHC.Weak (Weak (..))
import Control.Concurrent (forkIO, threadDelay, myThreadId, killThread)
import qualified Control.Exception as E
import Control.Monad (forever, void)
import Data.IORef (IORef)
import qualified Data.IORef as I
import Data.Typeable (Typeable)
import System.IO.Unsafe (unsafePerformIO)
import System.Mem.Weak (deRefWeak)

----------------------------------------------------------------

-- | A timeout manager
newtype Manager = Manager (IORef [Handle])

-- | An action to be performed on timeout.
type TimeoutAction = IO ()

-- | A handle used by 'Manager'
data Handle = Handle TimeoutAction (IORef State)

data State = Active    -- Manager turns it to Inactive.
           | Inactive  -- Manager removes it with timeout action.
           | Paused    -- Manager does not change it.
           | Canceled  -- Manager removes it without timeout action.

----------------------------------------------------------------

-- | A dummy @Handle@.
dummyHandle :: Handle
dummyHandle = Handle (return ()) (unsafePerformIO $ I.newIORef Active)

----------------------------------------------------------------

data TimeoutManagerStopped = TimeoutManagerStopped
    deriving (Show, Typeable)
instance E.Exception TimeoutManagerStopped

----------------------------------------------------------------

-- | Creating timeout manager which works every N micro seconds
--   where N is the first argument.
initialize :: Int -> IO Manager
initialize timeout = do
    ref <- I.newIORef []
    void . forkIO $ E.handle ignoreStop $ forever $ do
        threadDelay timeout
        -- FIXME: isn't mask_ necessary?
        old <- I.atomicModifyIORef ref (\x -> ([], x))
        merge <- prune old id
        I.atomicModifyIORef ref (\new -> (merge new, ()))
    return $ Manager ref
  where
    ignoreStop TimeoutManagerStopped = return ()

    prune [] front = return front
    prune (m@(Handle onTimeout iactive):rest) front = do
        state <- I.atomicModifyIORef iactive (\x -> (inactivate x, x))
        case state of
            Inactive -> do
                onTimeout `E.catch` ignoreAll
                prune rest front
            Canceled -> prune rest front
            _        -> prune rest (front . (:) m)
    inactivate Active = Inactive
    inactivate x = x

----------------------------------------------------------------

stopManager :: Manager -> IO ()
stopManager (Manager ihandles) = E.mask_ $ do
    -- Put an undefined value in the IORef to kill the worker thread (yes, it's
    -- a bit of a hack)
    !handles <- I.atomicModifyIORef ihandles $ \h -> (E.throw TimeoutManagerStopped, h)
    mapM_ fire handles
  where
    fire (Handle onTimeout _) = onTimeout `E.catch` ignoreAll

ignoreAll :: E.SomeException -> IO ()
ignoreAll _ = return ()

----------------------------------------------------------------

-- | Registering a timeout action.
register :: Manager -> TimeoutAction -> IO Handle
register (Manager ref) onTimeout = do
    iactive <- I.newIORef Active
    let h = Handle onTimeout iactive
    I.atomicModifyIORef ref (\x -> (h : x, ()))
    return h

-- | Registering a timeout action of killing this thread.
registerKillThread :: Manager -> IO Handle
registerKillThread m = do
    wtid <- myThreadId >>= mkWeakThreadId
    register m $ killIfExist wtid

-- If ThreadId is hold referred by a strong reference,
-- it leaks even after the thread is killed.
-- So, let's use a weak reference so that CG can throw ThreadId away.
-- deRefWeak checks if ThreadId referenced by the weak reference
-- exists. If exists, it means that the thread is alive.
killIfExist :: Weak ThreadId -> TimeoutAction
killIfExist wtid = deRefWeak wtid >>= maybe (return ()) killThread

#if !MIN_VERSION_base(4,6,0)
mkWeakThreadId :: ThreadId -> IO (Weak ThreadId)
mkWeakThreadId t@(ThreadId t#) = IO $ \s ->
   case mkWeak# t# t Nothing s of
      (# s1, w #) -> (# s1, Weak w #)
#endif

----------------------------------------------------------------

-- | Setting the state to active.
--   'Manager' turns active to inactive repeatedly.
tickle :: Handle -> IO ()
tickle (Handle _ iactive) = I.writeIORef iactive Active

-- | Setting the state to canceled.
--   'Manager' eventually removes this without timeout action.
cancel :: Handle -> IO ()
cancel (Handle _ iactive) = I.writeIORef iactive Canceled

-- | Setting the state to paused.
--   'Manager' does not change the value.
pause :: Handle -> IO ()
pause (Handle _ iactive) = I.writeIORef iactive Paused

-- | Setting the state to active.
--   This is an alias to 'ticle'.
resume :: Handle -> IO ()
resume = tickle

----------------------------------------------------------------

-- | Call the inner function with a timeout manager.
withManager :: Int -- ^ timeout in microseconds
            -> (Manager -> IO a)
            -> IO a
withManager timeout f = do
    -- FIXME when stopManager is available, use it
    man <- initialize timeout
    f man
