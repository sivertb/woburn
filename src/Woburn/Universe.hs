module Woburn.Universe
    ( Universe (..)
    , Screen (..)
    , Workspace (..)
    , create
    , setOutputs
    , view
    , greedyView
    , insert
    , delete
    )
where

import Data.Rect
import Data.Word
import qualified Data.List.Zipper as Z
import qualified Data.Map as M
import Woburn.Output

data Universe a =
    Universe { screens  :: Z.Zipper (Screen a)
             , hidden   :: [ Workspace a ]
             , floating :: M.Map a (Rect Word32)
             }

data Screen a =
    Screen { workspace :: Workspace a
           , output    :: MappedOutput
           }

data Workspace a =
    Workspace { tag     :: String
              , windows :: Z.Zipper a
              }

-- | Creates a new 'Universe' given a list of workspace tags.
create :: [String] -> Universe a
create ws =
    Universe { screens  = Z.empty
             , hidden   = map (`Workspace` Z.empty) ws
             , floating = M.empty
             }

-- | Sets the outputs.
--
-- Creates a screen for each of the outputs, and hands it a workspace. If there
-- are fewer workspaces than outputs, there will only be created as many
-- workspaces as there are screens.
--
-- Existing screens are removed.
setOutputs :: [MappedOutput] -> Universe a -> Universe a
setOutputs os u =
    Universe { screens  = Z.fromList $ zipWith Screen ws os
             , hidden   = drop (length os) ws
             , floating = floating u
             }
    where
        ws = map workspace (Z.toList $ screens u) ++ hidden u

view :: String -> Universe a -> Universe a
view t u = undefined

greedyView :: String -> Universe a -> Universe a
greedyView t u = undefined

-- | Insert an item above the currently focused item.
--
-- If the 'Universe' does not contain any workspaces, nothing is inserted.
insert :: (Ord a, Eq a) => a -> Universe a -> Universe a
insert a u
    | Z.isEmpty (screens u) = u { hidden = mapFirst addToWorkspace (hidden u) }
    | otherwise             = u { screens = Z.modify addToScreen (screens u) }
    where
        mapFirst _ []     = []
        mapFirst f (x:xs) = f x : xs
        addToScreen s = s { workspace = addToWorkspace (workspace s) }
        addToWorkspace w = w { windows = Z.insert a (windows w) }

-- | Deletes an item from a 'Universe'.
delete :: (Ord a, Eq a) => a -> Universe a -> Universe a
delete a u =
    u { screens  = Z.modify delFromScreen (screens u)
      , hidden   = map delFromWorkspace (hidden u)
      , floating = M.delete a (floating u)
      }
    where
        delFromScreen s = s { workspace = delFromWorkspace (workspace s) }
        delFromWorkspace w = w { windows = Z.delete a (windows w) }

{-
focusDown :: Universe a -> Universe a
focusUp :: Universe a -> Universe a
focusMaster :: Universe a -> Universe a
focusWindow :: a -> Universe a -> Universe a

shift :: String -> Universe a -> Universe a
shiftWin :: String -> a -> Universe a -> Universe a
shiftMaster :: Universe a -> Universe a
swapMaster :: Universe a -> Universe a

float :: a -> Universe a -> Universe a
sink :: a -> Universe a -> Universe a
-}
