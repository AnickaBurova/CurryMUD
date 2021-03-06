{-# LANGUAGE LambdaCase, MultiWayIf, OverloadedStrings, RecordWildCards, TupleSections, ViewPatterns #-}

module Mud.Threads.Act ( drinkAct
                       , sacrificeAct
                       , startAct
                       , stopAct
                       , stopActs
                       , stopNpcActs ) where

import Mud.Cmds.Util.Misc
import Mud.Data.Misc
import Mud.Data.State.MsgQueue
import Mud.Data.State.MudData
import Mud.Data.State.Util.Calc
import Mud.Data.State.Util.Destroy
import Mud.Data.State.Util.Get
import Mud.Data.State.Util.Misc
import Mud.Data.State.Util.Noun
import Mud.Data.State.Util.Output
import Mud.Data.State.Util.Random
import Mud.Misc.Database
import Mud.Threads.Effect
import Mud.Threads.Misc
import Mud.TopLvlDefs.Misc
import Mud.TopLvlDefs.Seconds
import Mud.Util.List
import Mud.Util.Misc
import Mud.Util.Operators
import Mud.Util.Quoting
import Mud.Util.Text
import qualified Mud.Misc.Logging as L (logNotice, logPla)

import Control.Exception.Lifted (finally, handle)
import Control.Lens (at, to, view, views)
import Control.Lens.Operators ((?~), (.~), (&), (%~), (^.))
import Control.Monad (join)
import Control.Monad.IO.Class (liftIO)
import Data.List (delete)
import Data.Maybe (isJust)
import Data.Monoid ((<>))
import Data.Text (Text)
import Data.Time (UTCTime, diffUTCTime, getCurrentTime)
import GHC.Stack (HasCallStack)
import qualified Data.Map.Strict as M (elems, insert, lookup)
import qualified Data.Text as T
import System.Time.Utils (renderSecs)


logNotice :: Text -> Text -> MudStack ()
logNotice = L.logNotice "Mud.Threads.Act"


logPla :: Text -> Id -> Text -> MudStack ()
logPla = L.logPla "Mud.Threads.Act"


-- ==================================================


startAct :: HasCallStack => Id -> ActType -> Fun -> MudStack ()
startAct i actType f = handle (threadStarterExHandler i fn . Just . pp $ actType) $ do
    logPla fn i $ pp actType <> " act started."
    a <- runAsync . threadAct i actType $ f
    tweak $ mobTbl.ind i.actMap.at actType ?~ a
  where
    fn = "startAct"


stopAct :: HasCallStack => Id -> ActType -> MudStack ()
stopAct i actType = views (at actType) (maybeVoid throwDeath) . getActMap i =<< getState


stopActs :: HasCallStack => Id -> MudStack ()
stopActs i = sequence_ [ logPla "stopActs" i "stopping all acts.", mapM_ throwWait . M.elems . getActMap i =<< getState ]


stopNpcActs :: HasCallStack => MudStack ()
stopNpcActs = sequence_ [ logNotice "stopNpcActs" "stopping NPC acts.", mapM_ stopActs . getNpcIds =<< getState ]


threadAct :: HasCallStack => Id -> ActType -> Fun -> MudStack ()
threadAct i actType f = let a = (>> f) . setThreadType $ case actType of Attacking   -> undefined -- TODO
                                                                         Drinking    -> DrinkingThread    i
                                                                         Eating      -> EatingThread      i
                                                                         Sacrificing -> SacrificingThread i
                            b = do logPla "threadAct" i $ pp actType <> " act finished."
                                   tweak $ mobTbl.ind i.actMap.at actType .~ Nothing
                        in handle (threadExHandler (Just i) . pp $ actType) $ a `finally` b


-- ==================================================


drinkAct :: HasCallStack => DrinkBundle -> MudStack ()
drinkAct DrinkBundle { .. } = modifyStateSeq f `finally` tweak (mobTbl.ind drinkerId.nowDrinking .~ Nothing)
  where
    f ms = let t  = thrice prd . T.concat $ [ "You begin drinking "
                                            , renderLiqNoun drinkLiq the
                                            , " from the "
                                            , drinkVesselSing ]
               d  = mkStdDesig drinkerId ms DoCap
               bs = pure ( T.concat [ serialize d, " begins drinking from ", renderVesselSing, "." ]
                         , drinkerId `delete` desigIds d )
               fs = pure . handle (die (Just drinkerId) (pp Drinking)) . sequence_ $ gs
               gs = [ multiWrapSend1Nl drinkerMq drinkerCols . dropEmpties $ [ t, drinkLiq^.liqDrinkDesc ]
                    , bcastIfNotIncogNl drinkerId bs
                    , loop 0 ]
           in (ms & mobTbl.ind drinkerId.nowDrinking ?~ (drinkLiq, drinkVesselSing), fs)
    renderVesselSing    = drinkVesselSing |&| (isJust drinkVesselId ? aOrAn :? the)
    loop x@(succ -> x') = do
        liftIO . delaySecs $ 1
        now <- liftIO getCurrentTime
        consume drinkerId . pure . StomachCont (drinkLiq^.liqId.to Left) now $ False
        (ms, newCont) <- case drinkVesselId of
          Just i  -> modifyState $ \ms -> let g (_, m) = let newCont = m == 1 ? Nothing :? Just (drinkLiq, pred m)
                                                             ms'     = ms & vesselTbl.ind i.vesselCont .~ newCont
                                                         in (ms', (ms', Right newCont))
                                          in maybe (ms, (ms, Left ())) g . getVesselCont i $ ms
          Nothing -> (, Left ()) <$> getState
        let (stomAvail, _) = calcStomachAvailSize drinkerId ms
            d              = mkStdDesig drinkerId ms DoCap
            bcastHelper b  = bcastIfNotIncogNl drinkerId . pure $ ( T.concat [ serialize d
                                                                             , " finishes drinking from "
                                                                             , renderVesselSing
                                                                             , b |?| " after draining it dry"
                                                                             , "." ]
                                                                  , drinkerId `delete` desigIds d )
        if | newCont == Right Nothing -> (>> bcastHelper True) . ioHelper x' $ T.concat [ "You drain the "
                                                                                        , drinkVesselSing
                                                                                        , " dry after "
                                                                                        , mkMouthfulTxt x'
                                                                                        , " mouthful"
                                                                                        , sOnNon1 x
                                                                                        , "." ]
           | isZero stomAvail -> let t = thrice prd " that you have to stop drinking. You don't feel so good"
                                 in (>> bcastHelper False) . ioHelper x' . T.concat $ [ "You are so full after "
                                                                                      , mkMouthfulTxt x'
                                                                                      , " mouthful"
                                                                                      , sOnNon1 x
                                                                                      , t ]
           | x' == drinkAmt   -> (>> bcastHelper False) . ioHelper x' $ "You finish drinking."
           | otherwise        -> loop x'
    mkMouthfulTxt x | x <= 8    = showText x
                    | otherwise = "many"
    ioHelper m t    = do logPla "drinkAct ioHelper" drinkerId . T.concat $ [ "drank "
                                                                           , showText m
                                                                           , " mouthful"
                                                                           , sOnNon1 m
                                                                           , " of "
                                                                           , renderLiqNoun drinkLiq aOrAn
                                                                           , " "
                                                                           , let DistinctLiqId i = drinkLiq^.liqId
                                                                             in parensQuote . showText $ i
                                                                           , " from "
                                                                           , renderVesselSing
                                                                           , "." ]
                         wrapSend drinkerMq drinkerCols t
                         sendDfltPrompt drinkerMq drinkerId


-----


sacrificeAct :: HasCallStack => Id -> MsgQueue -> Id -> GodName -> MudStack ()
sacrificeAct i mq ci gn = handle (die (Just i) (pp Sacrificing)) $ do
    liftIO . delaySecs $ sacrificeSecs
    modifyStateSeq $ \ms ->
        let helper f = (sacrificesTblHelper ms, fs)
              where
                fs = [ destroy . pure $ ci, f, sacrificeBonus i gn, sendDfltPrompt mq i ]
            sacrificesTblHelper = pcTbl.ind i.sacrificesTbl %~ f
              where
                f tbl = maybe (M.insert gn 1 tbl) (flip (M.insert gn) tbl . succ) . M.lookup gn $ tbl
            foldHelper    targetId = (mkBcastHelper targetId :)
            mkBcastHelper targetId = ( "The " <> mkCorpseAppellation targetId ms ci <> " fades away and disappears."
                                     , pure targetId )
        in if ((&&) <$> uncurry hasType <*> (== CorpseType) . uncurry getType) (ci, ms)
          then helper $ case findInvContaining ci ms of
            Just invId -> if | getType invId ms == RmType ->
                                   let mobIds = findMobIds ms . getInv invId $ ms
                                   in bcastNl $ if ((&&) <$> (`isIncognitoId` ms) <*> (`elem` mobIds)) i
                                     then pure . mkBcastHelper $ i
                                     else foldr foldHelper [] mobIds
                             | isNpcPC invId ms -> bcastNl . pure . mkBcastHelper $ invId
                             | otherwise        -> unit
            Nothing    -> unit
          else (ms, [])


sacrificeBonus :: HasCallStack => Id -> GodName -> MudStack ()
sacrificeBonus i gn@(pp -> gn') = getSing i <$> getState >>= \s -> do
    now <- liftIO getCurrentTime
    let operation = do insertDbTblSacrifice . SacrificeRec (showText now) s $ gn'
                       lookupSacrifices s gn'
        next count
          | count < 2 = logHelper . prd $ "first sacrifice made to " <> gn'
          | otherwise =
              let msg = T.concat [ commaShow count, " sacrifices to ", gn', "; " ]
              in if isZero $ count `mod` 10
                then join <$> withDbExHandler "sac_bonus" (lookupSacBonusTime s gn') >>= \case
                  Nothing   -> applyBonus i s gn now
                  Just time -> let diff@(T.pack . renderSecs -> secs) = round $ now `diffUTCTime` time
                               in if diff > fromIntegral oneDayInSecs
                                 then applyBonus i s gn now
                                 else logHelper . T.concat $ [ msg
                                                             , "not enough time has passed since the last bonus "
                                                             , parensQuote $ secs <> " seconsd since last bonus"
                                                             , "." ]
                else logHelper $ msg <> "no bonus yet."
    maybeVoid next =<< withDbExHandler "sacrifice" operation
  where
    logHelper = logPla "sacrificeBonus" i


applyBonus :: HasCallStack => Id -> Sing -> GodName -> UTCTime -> MudStack ()
applyBonus i s gn now = do
    logPla "applyBonus" i "applying bonus."
    withDbExHandler_ "sac_bonus" . insertDbTblSacBonus . SacBonusRec (showText now) s . pp $ gn
    let f = \case Aule      -> let a = (,) <$> rndmElem (mkXpPairs allValues) <*> rndmElem (allValues :: [Attrib])
                                   b = ((>>) <$> uncurry maxXp . fst <*> effectHelper Nothing (15, 15) . snd)
                               in a >>= b
                  Caila     -> f Aule
                  Celoriel  -> maxXp curPp maxPp >>  effectHelper Nothing     (5,  15) Ps
                  Dellio    -> maxXpHelper       >>  effectHelper Nothing     (5,  15) Dx
                  Drogo     -> maxXp curMp maxMp >>  effectHelper Nothing     (5,  15) Ma
                  Iminye    -> maxXpHelper       >>  effectHelper (Just "Dx") (3,  8 ) Dx
                                                 >>  effectHelper (Just "Ht") (3,  8 ) Ht
                  Itulvatar -> maxXpHelper       >> (effectHelper Nothing     (10, 15) =<< rndmElem [ St, Dx, Ht ])
                  Murgorhd  -> f Aule
                  Rhayk     -> maxXp curHp maxHp >>  effectHelper Nothing     (5,  15) St
                  Rumialys  -> maxXp curFp maxFp >>  effectHelper Nothing     (5,  15) Ht
    f gn
  where
    mkXpPairs   = let helper ptsType acc = (: acc) $ case ptsType of Hp -> (curHp, maxHp)
                                                                     Mp -> (curMp, maxMp)
                                                                     Pp -> (curPp, maxPp)
                                                                     Fp -> (curFp, maxFp)
                  in foldr helper []
    maxXpHelper = uncurry maxXp =<< rndmElem (mkXpPairs [ Hp, Fp ])
    effectHelper effTagSuff range attrib = let tag     = "sacrificeBonus" <> pp gn <> fromMaybeEmp effTagSuff
                                               effSub  = MobEffectAttrib attrib
                                               effVal  = Just . EffectRangedVal $ range
                                               effFeel = Just . EffectFeeling tag $ sacrificeBonusSecs
                                           in startEffect i . Effect (Just tag) effSub effVal sacrificeBonusSecs $ effFeel
    maxXp curXpLens maxXpLens            = tweak $ \ms -> let x = view (mobTbl.ind i.maxXpLens) ms
                                                          in ms & mobTbl.ind i.curXpLens .~ x
