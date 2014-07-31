{-# OPTIONS_GHC -funbox-strict-fields -Wall -Werror #-}
{-# LANGUAGE FlexibleContexts, KindSignatures, OverloadedStrings, RankNTypes #-}

module Mud.StateHelpers ( addToInv
                        , BothGramNos
                        , InvCoins
                        , dispAssocList
                        , dispGenericErrorMsg
                        , divider
                        , dumpFile
                        , dumpFileWithDividers
                        , findExit
                        , getArm
                        , getCloth
                        , getCoins
                        , getEnt
                        , getEntBothGramNos
                        , getEntBothGramNosInInv
                        , getEntNamesInInv
                        , getEntType
                        , getEntsInInv
                        , getEq
                        , getEqMap
                        , getInv
                        , getInvCoins
                        , getMob
                        , getMobGender
                        , getMobHand
                        , getPC
                        , getPCRm
                        , getPCRmId
                        , getPCRmInvCoins
                        , getPlaColumns
                        , getRm
                        , getRmLinks
                        , getWpn
                        , hasCoins
                        , hasEq
                        , hasInv
                        , hasInvOrCoins
                        , keysWS
                        , lookupPla
                        , lookupWS
                        , mkCoinsFromList
                        , mkCoinsList
                        , mkPlurFromBoth
                        , moveCoins
                        , moveInv
                        , onWorldState
                        , output
                        , outputCon
                        , outputConIndent
                        , outputIndent
                        , remFromInv
                        , sortInv
                        , updatePla
                        , updateWS
                        , updateWSSTM ) where

import Mud.StateDataTypes
import Mud.TopLvlDefs
import Mud.Util hiding (blowUp, patternMatchFail)
import qualified Mud.Util as U (blowUp, patternMatchFail)

import Control.Applicative ((<$>), (<*>), Const)
import Control.Concurrent.STM (atomically, STM)
import Control.Concurrent.STM.TVar (modifyTVar', readTVarIO, TVar)
import Control.Lens (_1, each)
import Control.Lens.Getter (Getting)
import Control.Lens.Operators ((%~), (^.))
import Control.Monad (unless)
import Control.Monad.IO.Class (liftIO, MonadIO)
import Control.Monad.State (gets)
import Control.Monad.State.Class (MonadState)
import Data.IntMap (IntMap, Key)
import Data.List (sortBy)
import Data.Monoid ((<>), mempty)
import qualified Data.IntMap.Lazy as IM (insert, keys, lookup)
import qualified Data.Map.Lazy as M (elems)
import qualified Data.Text as T
import qualified Data.Text.IO as T (putStrLn, readFile)


blowUp :: T.Text -> T.Text -> [T.Text] -> a
blowUp = U.blowUp "Mud.StateHelpers"


patternMatchFail :: T.Text -> [T.Text] -> a
patternMatchFail = U.patternMatchFail "Mud.StateHelpers"


-- ==================================================
-- Helpers for working with non-world state:


lookupPla :: Id -> MudStack Pla
lookupPla i = IM.lookup i <$> (gets (^.nonWorldState.plaTbl) >>= liftIO . readTVarIO) >>= maybeRet oops
  where
    oops = blowUp "lookupWS" "player not found in non-world state table for given key" [ showText i ]


updatePla :: Id -> Pla -> MudStack ()
updatePla i p = gets (^.nonWorldState.plaTbl) >>= \t ->
    liftIO . atomically . modifyTVar' t . IM.insert i $ p


getPlaColumns :: Id -> MudStack Int
getPlaColumns i = (^.columns) <$> lookupPla i


-- TODO: Move log state helpers here, too?


-- ==================================================
-- "output" and related helpers:


-- TODO: Can these be moved to a better place?


output :: T.Text -> MudStack ()
output t = getPlaColumns 0 >>= \cols ->
    mapM_ (liftIO . T.putStrLn) $ wordWrap cols t


outputIndent :: Int -> T.Text -> MudStack ()
outputIndent n t = getPlaColumns 0 >>= \cols ->
    liftIO . mapM_ T.putStrLn . wordWrapIndent n cols $ t


outputCon :: [T.Text] -> MudStack () -- Prefer over "output" when there would be more than two "<>"s.
outputCon = output . T.concat


outputConIndent :: Int -> [T.Text] -> MudStack ()
outputConIndent n = outputIndent n . T.concat


dumpFile :: FilePath -> MudStack () -- TODO: Implement paging.
dumpFile fn = takeADump =<< (liftIO . T.readFile $ fn)
  where
    takeADump contents = getPlaColumns 0 >>= \cols ->
        mapM_ (liftIO . T.putStrLn) (concat . wordWrapLines cols . T.lines $ contents)


dumpFileWithDividers :: FilePath -> MudStack ()
dumpFileWithDividers fn = divider >> dumpFile fn >> divider


divider :: MudStack ()
divider = getPlaColumns 0 >>= \cols ->
    liftIO . T.putStrLn . T.replicate cols $ "="


dispAssocList :: (Show a, Show b) => [(a, b)] -> MudStack ()
dispAssocList = mapM_ takeADump
  where
    takeADump (a, b) = outputIndent 2 $ (unquote . showText $ a) <> ": " <> showText b


dispGenericErrorMsg :: MudStack ()
dispGenericErrorMsg = output "Unfortunately, an error occured while executing your command."


-- ==================================================
-- Helpers for working with world state tables:


type WSTblLens a = ((TVar (IntMap a) -> Const (TVar (IntMap a)) (TVar (IntMap a))) -> WorldState -> Const (TVar (IntMap a)) WorldState)


lookupWS :: (Functor m, MonadState MudState m, MonadIO m) => Key -> WSTblLens a -> m a
i `lookupWS` tbl = IM.lookup i <$> (gets (^.worldState.tbl) >>= liftIO . readTVarIO) >>= maybeRet oops
  where
    oops = blowUp "lookupWS" "value not found in world state table for given key" [ showText i ]


updateWS :: forall a . Key -> Getting (TVar (IntMap a)) WorldState (TVar (IntMap a)) -> a -> MudStack ()
updateWS i tbl a = onWorldState $ \ws ->
    updateWSSTM (ws^.tbl) i a


onWorldState :: (WorldState -> STM ()) -> MudStack ()
onWorldState f = gets (^.worldState) >>= liftIO . atomically . f


updateWSSTM :: forall a . TVar (IntMap a) -> Key -> a -> STM ()
updateWSSTM t i a = modifyTVar' t . IM.insert i $ a


keysWS :: forall (f :: * -> *) a . (Functor f, MonadState MudState f, MonadIO f) => WSTblLens a -> f [Key]
keysWS tbl = IM.keys <$> (gets (^.worldState.tbl) >>= liftIO . readTVarIO)


-- ==================================================
-- Entities:


getEnt :: Id -> MudStack Ent
getEnt i = i `lookupWS` entTbl


getEntType :: Ent -> MudStack Type
getEntType e = let i = e^.entId
               in i `lookupWS` typeTbl


getEntsInInv :: Inv -> MudStack [Ent]
getEntsInInv = mapM getEnt


getEntNamesInInv :: Inv -> MudStack [T.Text]
getEntNamesInInv is = getEntsInInv is >>= \es ->
    return [ e^.name | e <- es ]


getEntSingsInInv :: Inv -> MudStack [T.Text]
getEntSingsInInv is = getEntsInInv is >>= \es ->
    return [ e^.sing | e <- es ]


type BothGramNos = (Sing, Plur)


getEntBothGramNos :: Ent -> BothGramNos
getEntBothGramNos e = (e^.sing, e^.plur)


getEntBothGramNosInInv :: Inv -> MudStack [BothGramNos]
getEntBothGramNosInInv is = map getEntBothGramNos <$> getEntsInInv is


mkPlurFromBoth :: BothGramNos -> Plur
mkPlurFromBoth (s, "") = s <> "s"
mkPlurFromBoth (_, p)  = p


-- ==================================================
-- Clothing:


getCloth :: Id -> MudStack Cloth
getCloth i = i `lookupWS` clothTbl


-- ==================================================
-- Inventories:


getInv :: Id -> MudStack Inv
getInv i = i `lookupWS` invTbl


hasInv :: Id -> MudStack Bool
hasInv i = not . null <$> getInv i


hasInvOrCoins :: Id -> MudStack Bool
hasInvOrCoins i = do
    hi <- hasInv   i
    hc <- hasCoins i
    return (hi || hc)


type InvCoins = (Inv, Coins)


getInvCoins :: Id -> MudStack InvCoins
getInvCoins i = (,) <$> getInv i <*> getCoins i


addToInv :: Inv -> Id -> MudStack ()
addToInv is ti = getInv ti >>= sortInv . (++ is) >>= updateWS ti invTbl


type FromId = Id
type ToId   = Id


remFromInv :: Inv -> FromId -> MudStack ()
remFromInv is fi = getInv fi >>= \fis ->
    updateWS fi invTbl . deleteFirstOfEach is $ fis


moveInv :: Inv -> FromId -> ToId -> MudStack ()
moveInv [] _  _  = return ()
moveInv is fi ti = remFromInv is fi >> addToInv is ti


sortInv :: Inv -> MudStack Inv
sortInv is = (map (^._1) . sortBy nameThenSing) <$> zipped
  where
    nameThenSing (_, n, s) (_, n', s') = (n `compare` n') <> (s `compare` s')
    zipped = zip3 is <$> getEntNamesInInv is <*> getEntSingsInInv is


-- ==================================================
-- Coins:


getCoins :: Id -> MudStack Coins
getCoins i = i `lookupWS` coinsTbl


mkCoinsList :: Coins -> [Int]
mkCoinsList (Coins (c, g, s)) = [c, g, s]


mkCoinsFromList :: [Int] -> Coins
mkCoinsFromList [cop, sil, gol] = Coins (cop, sil, gol)
mkCoinsFromList xs              = patternMatchFail "mkCoinsFromList" [ showText xs ]


hasCoins :: Id -> MudStack Bool
hasCoins i = not . all (== 0) . mkCoinsList <$> getCoins i


moveCoins :: Coins -> FromId -> ToId -> MudStack ()
moveCoins c fi ti = unless (c == mempty) $ subCoins c fi >> addCoins c ti


addCoins :: Coins -> Id -> MudStack ()
addCoins c i = getCoins i >>= \c' ->
    updateWS i coinsTbl $ c' <> c


subCoins :: Coins -> Id -> MudStack ()
subCoins c i = getCoins i >>= \c' ->
    updateWS i coinsTbl $ c' <> negateCoins c


negateCoins :: Coins -> Coins
negateCoins (Coins c) = Coins (each %~ negate $ c)


-- ==================================================
-- Weapons:


getWpn :: Id -> MudStack Wpn
getWpn i = i `lookupWS` wpnTbl


-- ==================================================
-- Armor:


getArm :: Id -> MudStack Arm
getArm i = i `lookupWS` armTbl


-- ==================================================
-- Equipment:


getEqMap :: Id -> MudStack EqMap
getEqMap i = i `lookupWS` eqTbl


getEq :: Id -> MudStack Inv
getEq i = M.elems <$> getEqMap i


hasEq :: Id -> MudStack Bool
hasEq i = not . null <$> getEq i


-- ==================================================
-- Mobiles:


getMob :: Id -> MudStack Mob
getMob i = i `lookupWS` mobTbl


getMobGender :: Id -> MudStack Gender
getMobGender i = (^.gender) <$> getMob i


getMobHand :: Id -> MudStack Hand
getMobHand i = (^.hand) <$> getMob i


-- ==================================================
-- PCs:


getPC :: Id -> MudStack PC
getPC i = i `lookupWS` pcTbl


-- ==================================================
-- Rooms:


getRm :: Id -> MudStack Rm
getRm i = i `lookupWS` rmTbl


getPCRmId :: Id -> MudStack Id
getPCRmId i = (^.rmId) <$> getPC i


getPCRm :: Id -> MudStack Rm
getPCRm i = getPCRmId i >>= getRm


getPCRmInvCoins :: Id -> MudStack InvCoins
getPCRmInvCoins i = getPCRmId i >>= getInvCoins


getRmLinks :: Id -> MudStack [RmLink]
getRmLinks i = (^.rmLinks) <$> getRm i


findExit :: LinkName -> Id -> MudStack (Maybe Id)
findExit ln i = getRmLinks i >>= \rls ->
    return $ case [ rl^.destId | rl <- rls, isValid rl ] of
      [] -> Nothing
      is -> Just . head $ is
  where
    isValid rl = ln `elem` stdLinkNames && ln == (rl^.linkName) || ln `notElem` stdLinkNames && ln `T.isInfixOf` (rl^.linkName)
