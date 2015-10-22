{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE TupleSections #-}
module Woburn.Core
    ( Request
    , Event
    , Error
    , ClientId
    , run
    )
where

import Control.Arrow
import Control.Concurrent
import Control.Concurrent.Async
import Control.Concurrent.MChan.Split
import Control.Monad.Except
import Control.Monad.Reader
import Control.Monad.State
import Control.Lens hiding (universe)
import Data.Maybe
import Data.Int
import Data.Rect
import Data.STree
import Data.Tuple
import Data.Traversable (mapAccumR)
import qualified Data.Map as M
import qualified Data.Set.Diet as D
import Data.Word
import Linear

import Prelude

import qualified Woburn.Backend as B
import Woburn.Layout
import Woburn.Output
import Woburn.Protocol
import Woburn.Surface
import Woburn.Surface.Tree
import Woburn.Window
import qualified Woburn.Universe as U

data ClientWindowId = ClientWindowId ClientId WindowId
    deriving (Eq, Ord, Show)

data CoreState s =
    CoreState { outputs  :: [MappedOutput]
              , clients  :: M.Map ClientId (ClientData s)
              , ids      :: D.Diet Word32
              , universe :: U.Universe ClientWindowId
              , layedOut :: [(MappedOutput, [(Rect Word32, ClientWindowId)])]
              }

data CoreData s =
    CoreData { backendRequest :: WMChan (B.Request s)
             , backendSurfGet :: IO s
             }

data ClientData s =
    ClientData { surfaces :: M.Map SurfaceId (Surface s, Either SurfaceId (STree SurfaceId))
               , windows  :: M.Map WindowId Window
               , output   :: WMChan Event
               }

type Core s a = ReaderT (CoreData s) (StateT (CoreState s) IO) a

runCore :: CoreData s -> CoreState s -> Core s a -> IO a
runCore cd cs c = evalStateT (runReaderT c cd) cs

newtype ClientId = ClientId Word32
    deriving (Eq, Ord, Show, Num, Real, Integral, Enum)

data Request =
    WindowCreate WindowId SurfaceId
  | WindowDestroy WindowId
  | WindowSetTitle WindowId String
  | WindowSetClass WindowId String
  | SurfaceCreate SurfaceId
  | SurfaceDestroy SurfaceId
  | SurfaceAttach SurfaceId (Maybe SurfaceId)
  | SurfaceCommit SurfaceId SurfaceState
  | SurfaceSetPosition SurfaceId (V2 Int32)
  | SurfaceSetSync SurfaceId Bool
  | SurfacePlaceAbove SurfaceId SurfaceId
  | SurfacePlaceBelow SurfaceId SurfaceId
  deriving (Eq, Show)

data Event =
    OutputAdded MappedOutput
  | OutputRemoved MappedOutput
  | Error Error
  deriving (Eq, Show)

data Error =
    BadSurface SurfaceId
  | BadShuffle SurfaceId SurfaceId
  | BadWindow WindowId
  deriving (Eq, Show)

data Message =
    ClientAdd ClientId (WMChan Event)
  | ClientDel ClientId
  | ClientRequest ClientId Request
  | BackendEvent B.Event

-- | Returns the size of an 'Output'.
outputSize :: Output -> V2 Word32
outputSize o
    | isPortrait = V2 h w
    | otherwise  = V2 w h
    where
        m = outputCurMode o
        s = outputScale o
        w = modeWidth  m `div` s
        h = modeHeight m `div` s
        -- Checks if the output is in portrait mode.
        isPortrait = case outputTransform o of
                          WlOutputTransformNormal     -> False
                          WlOutputTransform90         -> True
                          WlOutputTransform180        -> False
                          WlOutputTransform270        -> True
                          WlOutputTransformFlipped    -> False
                          WlOutputTransformFlipped90  -> True
                          WlOutputTransformFlipped180 -> False
                          WlOutputTransformFlipped270 -> True

-- | Maps an output at a given X-offset into the global compositor space.
mapOutput :: Word32 -> Output -> MappedOutput
mapOutput off out = MappedOutput out . shiftX off $ outRect out
    where
        outRect = Rect 0 . fmap (subtract 1) . outputSize

-- | Gives a list of 'Output's positions in the global compositor space.
--
-- The first 'Output' in the list will be the right-most 'Output'.
mapOutputs :: Word32 -> [Output] -> [MappedOutput]
mapOutputs start = snd . mapAccumR f start
    where
        f off out =
            let out'@(MappedOutput _ r) = mapOutput off out
            in (off + width r, out')

-- | Returns the right-most edge of a list of outputs, assuming the first
-- element is the right-most one.
outputsRight :: [MappedOutput] -> Word32
outputsRight []    = 0
outputsRight (o:_) = mappedRect o ^. to bottomRight . _x . to (+ 1)

-- | Deletes an output from a list of mapped outputs, and returns the deleted
-- item (or 'Nothing' if it was not in the list), along with a list of the
-- other outputs remapped to fill the hole of the removed output.
deleteOutput :: OutputId -> [MappedOutput] -> (Maybe MappedOutput, [MappedOutput])
deleteOutput oid os =
    let (as, bs) = span ((/= oid) . outputId . mappedOutput) os
    in
    case bs of
         []     -> (Nothing, as)
         (x:xs) -> (Just x, mapOutputs (outputsRight xs) (map mappedOutput as) ++ xs)

-- | Sets the universe, and recomputes the layout.
setUniverse :: Core s (U.Universe ClientWindowId) -> Core s ()
setUniverse f = do
    u <- f
    modify $ \s -> s { universe = u, layedOut = layout u }

modifyUniverse :: (U.Universe ClientWindowId -> U.Universe ClientWindowId) -> Core s ()
modifyUniverse f = setUniverse (f <$> gets universe)

modifyClient :: ClientId -> (ClientData s -> ClientData s) -> Core s ()
modifyClient cid f = modify $ \s -> s { clients = M.adjust f cid (clients s) }

-- | Handles backend events.
handleBackendEvent :: B.Event -> Core s ()
handleBackendEvent evt = do
    case evt of
         B.OutputAdded   out -> do
             mOut <- state $ \s ->
                 let outs = snd . deleteOutput (outputId out) $ outputs s
                     mOut = mapOutput (outputsRight outs) out
                 in
                 (mOut, s { outputs = mOut : outs })
             sendClientEvent Nothing (OutputAdded mOut)
         B.OutputRemoved oid -> do
             mOut <- state $ \s -> second (\x -> s { outputs = x}) . deleteOutput oid $ outputs s
             case mOut of
                  Nothing  -> error "Backend removed a non-existing output"
                  Just out -> sendClientEvent Nothing (OutputRemoved out)
    setUniverse $ U.setOutputs <$> gets outputs <*> gets universe
    -- TODO: Send Commit request

handleCoreRequest :: ClientId -> Request -> Core s ()
handleCoreRequest cid req =
    case req of
         WindowCreate       wid sid   -> do
             modifyUniverse $ U.insert (ClientWindowId cid wid)
             modifyWindows  $ M.insert wid (Window "" "" sid)
         WindowDestroy      wid       -> do
             modifyUniverse $ U.delete (ClientWindowId cid wid)
             modifyWindows  $ M.delete wid
         WindowSetTitle     wid title -> modifyWindow wid $ \w -> w { winTitle = title }
         WindowSetClass     wid cls   -> modifyWindow wid $ \w -> w { winClass = cls }

         SurfaceCreate      sid       -> undefined
         SurfaceDestroy     sid       -> undefined
         SurfaceAttach      sid tid   -> undefined
         SurfaceCommit      sid ss    -> undefined
         SurfaceSetPosition sid pos   -> undefined
         SurfaceSetSync     sid sync  -> undefined
         SurfacePlaceAbove  sid tid   -> undefined
         SurfacePlaceBelow  sid tid   -> undefined
    where
        modifyWindows f = modifyClient cid $ \c -> c { windows = f (windows c) }
        modifyWindow wid f = modifyWindows $ M.adjust f wid

handleMsg :: Message -> Core s ()
handleMsg msg =
    case msg of
         BackendEvent  evt     -> handleBackendEvent evt
         ClientRequest cid req -> handleCoreRequest cid req
         ClientAdd     cid evt -> modify $ \s -> s { clients = M.insert cid (newClientData evt) (clients s) }
         ClientDel     cid     -> modify $ \s -> s { clients = M.delete cid (clients s) }
    where
        newClientData = ClientData M.empty M.empty

sendBackendRequest :: B.Request s -> Core s ()
sendBackendRequest req = asks backendRequest >>= liftIO . (`writeMChan` req)

-- | Sends an event to one or all clients.
--
-- If passed 'Nothing' as the first argument, the event is sent to all clients,
-- otherwise it is only sent to the specified client.
--
-- Trying to send an event to a client that does not exist results in an error.
sendClientEvent :: Maybe ClientId -> Event -> Core s ()
sendClientEvent Nothing evt =
    gets clients >>=
        mapM_ (liftIO . (`writeMChan` evt) . output) . M.elems
sendClientEvent (Just cid) evt =
    gets clients >>=
        maybe
            (error "Trying to send an event to an unknown client")
            (liftIO . (`writeMChan` evt) . output) . M.lookup cid

-- | Returns a producer of messages.
--
-- Passes on backend events, and creates threads to handle new clients.
msgGenerator :: RMChan (WMChan Event, RMChan Request) -- ^ New client.
             -> RMChan B.Event                        -- ^ Incoming backend events.
             -> IO (RMChan Message)                   -- ^ Combined backend and client data.
msgGenerator newClients bEvt = do
    (msgRChan, msgWChan) <- newMChan
    dVar                 <- newMVar D.empty

    -- Pass on events from the backend.
    linkAsync . readUntilClosed bEvt $ writeMChan msgWChan . BackendEvent

    -- Wait for new clients.
    linkAsync . readUntilClosed newClients $ \(cEvt, cReq) -> do
        -- Create client ID, and notify the core
        cid <- modifyMVar dVar (return . swap . fromMaybe (error "Ran out of client IDs!") . D.minView)
        writeMChan msgWChan $ ClientAdd cid cEvt

        -- Pass on requests from the client, and signal the core when it is closed.
        linkAsync $ do
            readUntilClosed cReq $ writeMChan msgWChan . ClientRequest cid
            writeMChan msgWChan $ ClientDel cid
            modifyMVar_ dVar (return . D.insert cid)

    return msgRChan
    where
        linkAsync io = async io >>= link

-- | Runs the core.
run :: WMChan (B.Request s)                  -- ^ Outgoing requests to the backend.
    -> RMChan B.Event                        -- ^ Incoming events from the backend.
    -> IO s                                  -- ^ An IO computation to create a new backend surface.
    -> RMChan (WMChan Event, RMChan Request) -- ^ New client connections.
    -> IO ()
run bReq bEvt bSurfGet newClients = do
    msg <- msgGenerator newClients bEvt

    let cd = CoreData { backendRequest = bReq
                      , backendSurfGet = bSurfGet
                      }
        cs = CoreState { outputs  = []
                       , clients  = M.empty
                       , ids      = D.empty
                       , universe = U.create ["workspace"]
                       , layedOut = []
                       }

    runCore cd cs $ readUntilClosed msg handleMsg
