module Woburn.Surface.Map
    ( SurfaceMap
    , lookupSurfaces
    , modifySurface
    , insertNew
    , delete
    , attach
    , shuffle
    , commit
    , setSync
    )
where

import Control.Applicative
import Control.Arrow
import qualified Data.Map as M
import Data.STree
import qualified Data.STree.Zipper as Z
import Data.Traversable
import Prelude
import Woburn.Surface
import qualified Woburn.Surface.Tree as ST

type SurfaceMap s = M.Map SurfaceId (Surface s, Either SurfaceId (STree SurfaceId))

-- | Maps 'SurfaceId' to the 'STree' it belongs in.
lookupSTree :: SurfaceId
            -> SurfaceMap s
            -> Maybe (STree SurfaceId)
lookupSTree sid ss = do
    (_, st) <- M.lookup sid ss
    findRoot st
    where
        findRoot (Right st) = return st
        findRoot (Left tid) = snd <$> M.lookup tid ss >>= findRoot

-- | Maps 'SurfaceId' to 'Surface'.
lookupSurface :: SurfaceId
              -> SurfaceMap s
              -> Maybe (Surface s)
lookupSurface sid = fmap fst . M.lookup sid

-- | Maps 'SurfaceId' to the 'STree' it belongs in, and maps 'SurfaceId's in
-- the tree to their corresponding 'Surface's.
lookupSurfaces :: SurfaceId
               -> SurfaceMap s
               -> Maybe (STree (Surface s))
lookupSurfaces sid sm = traverse (`lookupSurface` sm) =<< lookupSTree sid sm

-- | Modifies a surface.
modifySurface :: (Surface s -> Surface s)
              -> SurfaceId
              -> SurfaceMap s
              -> SurfaceMap s
modifySurface = M.adjust . first

-- | Inserts a shuffle for the given surface.
insertShuffle :: Shuffle
              -> SurfaceId
              -> SurfaceMap s
              -> SurfaceMap s
insertShuffle sh = M.adjust . first $ \s -> s { surfShuffle = sh : surfShuffle s }

-- | Inserts a new 'Surface' into the 'SurfaceMap'.
insertNew :: SurfaceId
          -> Surface s
          -> SurfaceMap s
          -> SurfaceMap s
insertNew sid surf = M.insert sid (surf, Right $ singleton sid)

-- | Updates the surface tree.
updateTree :: STree SurfaceId
           -> SurfaceMap s
           -> SurfaceMap s
updateTree st = M.adjust (second . const $ Right st) (label st)

-- | Updates the surface tree of all the children of a removed node.
updateChildren :: STree SurfaceId
               -> SurfaceMap s
               -> SurfaceMap s
updateChildren (STree ls _ rs) ss = foldr updateTree ss (ls ++ rs)

-- | Detaches a surface from the surface it is currently attached, or does
-- nothing if it is not attached to another surface.
detach :: SurfaceId
       -> SurfaceMap s
       -> Maybe (SurfaceMap s)
detach sid ss = do
    stree <- lookupSTree sid ss
    ptr   <- ST.findSid sid stree
    return $ case ST.delete sid stree of
               Nothing                    -> ss
               Just (stree', subtree, sh) ->
                   foldr ($) ss
                   [ maybe id (insertShuffle sh . label . Z.getTree) (Z.up ptr)
                   , updateTree stree'
                   , updateTree subtree
                   ]

-- | Deletes a 'Surface' from the 'SurfaceMap'.
delete :: SurfaceId
       -> SurfaceMap s
       -> Maybe (SurfaceMap s)
delete sid ss = do
    ss'   <- detach sid ss
    stree <- lookupSTree sid ss'
    return $ foldr ($) ss'
        [ updateChildren stree
        , M.delete sid
        ]

-- | Attaches a surface to another surface.
attach :: SurfaceId
       -> Maybe SurfaceId
       -> SurfaceMap s
       -> Maybe (SurfaceMap s)
attach sid mtid ss = do
    ss' <- detach sid ss
    case mtid of
      Nothing  -> return ss'
      Just tid -> do
          stree <- lookupSTree sid ss'
          ttree <- lookupSTree tid ss'
          ptr   <- ST.findSid tid ttree
          return $ updateTree (Z.toTree $ Z.insert stree ptr) ss'

shuffle :: ShuffleOperation
        -> SurfaceId
        -> SurfaceId
        -> SurfaceMap s
        -> Maybe (SurfaceMap s)
shuffle op sid tid ss = undefined

commit :: SurfaceId
       -> SurfaceState
       -> SurfaceMap s
       -> Maybe ([Surface s], SurfaceMap s)
commit sid sm = undefined

setSync :: SurfaceId
        -> Bool
        -> SurfaceMap s
        -> Maybe ([Surface s], SurfaceMap s)
setSync sid sync sm = undefined
