import Control.Applicative
import Control.Monad
import Prelude
import System.Exit
import Test.MChan
import Test.STree
import Test.SurfaceMap
import Test.SurfaceTree
import Test.Zipper

tests :: [IO Bool]
tests = [ surfaceTreeTests
        , surfaceMapTests
        , sTreeTests
        , zipperTests
        , mChanTests
        ]

main :: IO ()
main = do
    res <- and <$> sequence tests
    unless res exitFailure
