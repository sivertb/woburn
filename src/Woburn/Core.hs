{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}
module Woburn.Core
    ( Request (..)
    , Event (..)
    , Error
    , handleInput
    , newCoreState

    -- * Core input commands.
    , CoreInput (..)

    -- * Core output.
    , CoreOutputF (..)
    )
where

import Control.Applicative
import Control.Arrow
import Control.Monad.Free
import Control.Monad.Free.TH
import Control.Monad.Reader
import Control.Monad.State
import Control.Lens hiding (universe)
import Data.Foldable
import Data.Maybe
import Data.Int
import Data.Rect
import Data.Tuple
import Data.Traversable (mapAccumR)
import qualified Data.Map as M
import qualified Data.Set as S
import Data.Word
import Linear

import Prelude

import qualified Woburn.Backend as B
import Woburn.Buffer
import Woburn.Layout
import Woburn.Output
import Woburn.Protocol.Core
import Woburn.Surface
import qualified Woburn.Surface.Map as SM
import qualified Woburn.Universe as U
import Woburn.Types

data ClientSurfaceId = ClientSurfaceId ClientId SurfaceId
    deriving (Eq, Ord, Show)

data CoreState s =
    CoreState { outputs  :: [MappedOutput]
              , clients  :: M.Map ClientId (ClientData s)
              , universe :: U.Universe ClientSurfaceId
              , layedOut :: [(MappedOutput, [(Rect Word32, ClientSurfaceId)])]
              }

data ClientData s =
    ClientData { surfaces :: SM.SurfaceMap s }

-- | A core request.
data Request =
    SurfaceCreate SurfaceId
  | SurfaceDestroy SurfaceId
  | SurfaceCommit [(SurfaceId, SurfaceState (V2 Int32, SurfaceId))]
  deriving (Eq, Show)

-- | A core event.
data Event =
    OutputAdded MappedOutput
  | OutputRemoved MappedOutput
  | SurfaceFrame [SurfaceId]
  | BufferReleased Buffer
  | WindowConfigure SurfaceId (V2 Word32)
  | Error Error
  deriving (Eq, Show)

-- | A core error.
data Error =
    BadSurface
  | BadWindow
  deriving (Eq, Show)

data CoreInput s =
    ClientAdd ClientId
  | ClientDel ClientId
  | ClientRequest ClientId Request
  | BackendEvent B.Event
  deriving (Eq, Show)

data CoreOutputF s a =
    ClientEvent (Maybe ClientId) Event a
  | BackendRequest (B.Request s) a
  | BackendSurfGet (s -> a)
  | CoreError String a
  deriving (Functor)

$(makeFree ''CoreOutputF)

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

backendCommit :: (MonadState (CoreState s) m, MonadFree (CoreOutputF s) m) => [Surface s ()] -> m ()
backendCommit ss = do
    l  <- gets layedOut
    cs <- gets clients

    backendRequest . B.SurfaceCommit ss $ mapLayoutToSurfaces cs l
    where
        -- | Maps all the 'ClientSurfaceId' in the layout to the containing
        -- rectangle along with the surface tree, and maps the 'MappedOutput'
        -- to their respective 'OutputId'.
        mapLayoutToSurfaces :: M.Map ClientId (ClientData s)
                            -> [(MappedOutput, [(Rect Word32, ClientSurfaceId)])]
                            -> [(OutputId, [(Rect Word32, [(V2 Int32, s)])])]
        mapLayoutToSurfaces cs =
            map (outputId . mappedOutput . fst &&& mapWindowsToSurfaces cs . first (topLeft . mappedRect))

        -- Maps a list of 'Rect's along with the 'ClientWindowId' to a list of
        -- 'Rect's with trees of the surface data and the surface's window
        -- offset.
        mapWindowsToSurfaces :: M.Map ClientId (ClientData s)
                             -> (V2 Word32, [(Rect Word32, ClientSurfaceId)])
                             -> [(Rect Word32, [(V2 Int32, s)])]
        mapWindowsToSurfaces cs (off, ws) =
            map (second $ mapWindowToSurfaces cs off) ws

        -- Maps a window to a tree of the surface data with the surface offset
        -- within the window.
        mapWindowToSurfaces :: M.Map ClientId (ClientData s)
                            -> V2 Word32
                            -> ClientSurfaceId
                            -> [(V2 Int32, s)]
        mapWindowToSurfaces cs off (ClientSurfaceId cid sid) = fromMaybe [] $ do
            cd   <- M.lookup cid cs
            return
                . map (second surfData)
                $ SM.lookupAll (fmap fromIntegral off) sid (surfaces cd)

-- | Finds the windows that have changed between two layouts.
layoutDiff :: [(MappedOutput, [(Rect Word32, ClientSurfaceId)])] -- ^ The new layout.
           -> [(MappedOutput, [(Rect Word32, ClientSurfaceId)])] -- ^ The old layout.
           -> [(V2 Word32, ClientSurfaceId)]                     -- ^ The windows that has changed.
layoutDiff new' old' = filter (`S.notMember` S.fromList old) new
    where
        new = concatMap (map (first size) . snd) new'
        old = concatMap (map (first size) . snd) old'

-- | Handles backend events.
handleBackendEvent :: (MonadState (CoreState s) m, MonadFree (CoreOutputF s) m) => B.Event -> m ()
handleBackendEvent evt =
    case evt of
         B.BufferReleased buf -> clientEvent (Just $ bufClientId buf) (BufferReleased buf)

         B.OutputAdded out -> do
             mOut <- state $ \s ->
                 let outs = snd . deleteOutput (outputId out) $ outputs s
                     mOut = mapOutput (outputsRight outs) out
                 in
                 (mOut, s { outputs = mOut : outs })
             clientEvent Nothing (OutputAdded mOut)
             setUniverse $ U.setOutputs <$> gets outputs <*> gets universe

         B.OutputRemoved oid -> do
             mOut <- state $ \s -> second (\x -> s { outputs = x}) . deleteOutput oid $ outputs s
             case mOut of
                  Nothing  -> coreError "Backend removed a non-existing output"
                  Just out -> clientEvent Nothing (OutputRemoved out)
             setUniverse $ U.setOutputs <$> gets outputs <*> gets universe

         B.OutputFrame oid -> do
             wins <- gets (U.onOutput oid . universe)
             cs   <- gets clients
             mapM_
                (\(cid, sids) -> clientEvent (Just cid) (SurfaceFrame sids))
                (mapMaybe (mapWindowToSurfaces cs) wins)
    where
        -- | Maps a window to its list of surfaces.
        mapWindowToSurfaces cs (ClientSurfaceId cid sid) = do
            cd  <- M.lookup cid cs
            return (cid, SM.lookupAllIds sid (surfaces cd))

-- | Sends a configure event for a single window.
configureWindow :: MonadFree (CoreOutputF s) m
                => V2 Word32        -- ^ The window size.
                -> ClientSurfaceId  -- ^ The window ID.
                -> m ()
configureWindow sz (ClientSurfaceId cid sid) =
    clientEvent (Just cid) (WindowConfigure sid sz)

-- | Sets the universe, and recomputes the layout.
setUniverse :: (MonadState (CoreState s) m, MonadFree (CoreOutputF s) m)
            => m (U.Universe ClientSurfaceId)
            -> m ()
setUniverse f = do
    uni <- f
    ws  <- state $ updateUniverse uni
    mapM_ (uncurry configureWindow) ws
    where
        updateUniverse uni s =
            let newLayout = layout uni
                oldLayout = layedOut s
            in
            (layoutDiff newLayout oldLayout, s { universe = uni, layedOut = newLayout })

modifyUniverse :: (MonadState (CoreState s) m, MonadFree (CoreOutputF s) m)
               => (U.Universe ClientSurfaceId -> U.Universe ClientSurfaceId) -> m ()
modifyUniverse f = setUniverse (f <$> gets universe)

handleCoreRequest :: (MonadState (CoreState s) m, MonadFree (CoreOutputF s) m) => ClientId -> Request -> m ()
handleCoreRequest cid req =
    case req of
         SurfaceCreate      sid      -> do
             surf <- create <$> backendSurfGet
             modifySurfaces $ SM.insert sid surf
         SurfaceDestroy     sid      -> do
             msurf <- lookupSurface sid
             modifyUniverse . U.delete $ ClientSurfaceId cid sid
             backendCommit []
             modifySurfaces $ SM.delete sid
             maybe (return ()) (backendRequest . B.SurfaceDestroy . (: []) . void) msurf
         SurfaceCommit sids -> do
             (ops, surfs) <- (unzip . catMaybes) <$> mapM
                (\(sid, ss) ->
                    state $ \s ->
                        maybe (Nothing, s) (first Just) $ do
                            cd   <- M.lookup cid (clients s)
                            surf <- SM.lookup sid (surfaces cd)

                            let surf' = surf { surfState = ss }
                                cd'   = cd { surfaces = SM.insert sid surf' (surfaces cd) }
                                s'    = s { clients = M.insert cid cd' (clients s) }

                            return ((uniOp sid ss (surfState surf), void surf'), s')
                )
                sids
             modifyUniverse $ foldr (.) id ops
             backendCommit surfs
    where
        -- Remove or add the surface as a window if it is (un)mapped.
        uniOp sid ss oldSs =
            case (isMapped oldSs, isMapped ss) of
              (True , False) -> U.delete $ ClientSurfaceId cid sid
              (False, True ) -> U.insert $ ClientSurfaceId cid sid
              _              -> id

        modifyClient f = modify $ \s -> s { clients = M.adjust f cid (clients s) }
        modifySurfaces f = modifyClient $ \c -> c { surfaces = f (surfaces c) }
        lookupSurface sid = gets $ \s -> do
            cd <- M.lookup cid (clients s)
            SM.lookup sid (surfaces cd)

announceOutputs :: (MonadState (CoreState s) m, MonadFree (CoreOutputF s) m) => ClientId -> m ()
announceOutputs cid = do
    os <- gets outputs
    mapM_ (clientEvent (Just cid) . OutputAdded) os

-- | Handles the various core inputs.
handleInput :: (MonadState (CoreState s) m, MonadFree (CoreOutputF s) m) => CoreInput s -> m ()
handleInput input =
    case input of
         BackendEvent  evt     -> handleBackendEvent evt
         ClientRequest cid req -> handleCoreRequest cid req
         ClientAdd     cid     -> do
             modify (\s -> s { clients = M.insert cid newClientData (clients s) })
             announceOutputs cid
         ClientDel     cid     -> do
             -- When a client is deleted we have to remove the client data
             cd <- state $ \s -> (M.lookup cid (clients s), s { clients  = M.delete cid (clients s) })
             -- and all of its windows
             modifyUniverse . U.filter $ \(ClientSurfaceId cid' _) -> cid' /= cid
             backendCommit []
             -- and destoy its surfaces
             backendRequest . B.SurfaceDestroy $ maybe [] (map void . SM.elems . surfaces) cd
    where
        newClientData = ClientData SM.empty

-- | Creates a new 'CoreState'.
newCoreState :: CoreState s
newCoreState =
    CoreState { outputs  = []
              , clients  = M.empty
              , universe = U.create ["workspace"]
              , layedOut = []
              }
