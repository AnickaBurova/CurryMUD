{-# OPTIONS_GHC -fno-warn-type-defaults #-}
{-# LANGUAGE LambdaCase, MultiWayIf, OverloadedStrings, RecordWildCards, TupleSections, ViewPatterns #-}

module Mud.Data.State.Util.Output ( bcast
                                  , bcastAdmins
                                  , bcastAdminsExcept
                                  , bcastIfNotIncog
                                  , bcastIfNotIncogNl
                                  , bcastNl
                                  , bcastOtherAdmins
                                  , bcastOthersInRm
                                  , dbError
                                  , frame
                                  , massMsg
                                  , massSend
                                  , mkBcast
                                  , mkDfltPrompt
                                  , mkNTBcast
                                  , multiWrapSend
                                  , ok
                                  , parseDesig
                                  , retainedMsg
                                  , send
                                  , sendDfltPrompt
                                  , sendMsgBoot
                                  , sendPrompt
                                  , sendSilentBoot
                                  , wrapSend
                                  , wrapSendPrompt ) where

import Mud.Cmds.Msgs.Misc
import Mud.Data.Misc
import Mud.Data.State.MsgQueue
import Mud.Data.State.MudData
import Mud.Data.State.Util.Get
import Mud.Data.State.Util.Misc
import Mud.Misc.ANSI
import Mud.TopLvlDefs.Chars
import Mud.Util.List (nubSort)
import Mud.Util.Misc hiding (patternMatchFail)
import Mud.Util.Operators
import Mud.Util.Quoting
import Mud.Util.Text
import Mud.Util.Wrapping
import qualified Mud.Util.Misc as U (patternMatchFail)

import Control.Concurrent.STM (atomically)
import Control.Concurrent.STM.TQueue (writeTQueue)
import Control.Lens (views)
import Control.Lens.Operators ((<>~))
import Control.Monad (forM_, unless)
import Control.Monad.IO.Class (liftIO)
import Data.List ((\\), delete, elemIndex)
import Data.Maybe (fromJust, fromMaybe)
import Data.Monoid ((<>))
import Data.Text (Text)
import Prelude hiding (pi)
import qualified Data.IntMap.Lazy as IM (elems, toList)
import qualified Data.Text as T


patternMatchFail :: Text -> [Text] -> a
patternMatchFail = U.patternMatchFail "Mud.Data.State.Util.Output"


-- ============================================================


bcast :: [Broadcast] -> MudStack ()
bcast [] = unit
bcast bs = getState >>= \ms -> liftIO . atomically . forM_ bs . sendBcastSTM $ ms
  where
    sendBcastSTM ms (msg, is) = mapM_ helper is
      where
        helper targetId = case getType targetId ms of
          PCType  -> writeIt FromServer targetId
          NpcType -> maybeVoid (writeIt ToNpc) . getPossessor targetId $ ms
          t       -> patternMatchFail "bcast sendBcastSTM helper" [ showText t ]
        writeIt f i = let (mq, cols) = getMsgQueueColumns i ms
                      in writeTQueue mq . f . T.unlines . concatMap (wrap cols) . T.lines . parseDesig i ms $ msg


-----


bcastAdmins :: Text -> MudStack ()
bcastAdmins = bcastAdminsHelper id


bcastAdminsHelper :: (Inv -> Inv) -> Text -> MudStack ()
bcastAdminsHelper f msg =
    bcastNl . pure . (colorWith adminBcastColor msg, ) =<< f . getLoggedInAdminIds <$> getState


-----


bcastAdminsExcept :: Inv -> Text -> MudStack ()
bcastAdminsExcept = bcastAdminsHelper . flip (\\)


-----


bcastIfNotIncog :: Id -> [Broadcast] -> MudStack ()
bcastIfNotIncog i bs = getState >>= \ms -> onTrue (isPC i ms) (unless (isIncognito . getPla i $ ms)) . bcast $ bs


-----


bcastIfNotIncogNl :: Id -> [Broadcast] -> MudStack ()
bcastIfNotIncogNl i = bcastIfNotIncog i . appendNlBs


appendNlBs :: [Broadcast] -> [Broadcast]
appendNlBs bs = bs ++ [("\n", nubSort . concatMap snd $ bs)]


-----


bcastNl :: [Broadcast] -> MudStack ()
bcastNl = bcast . appendNlBs


-----


bcastOtherAdmins :: Id -> Text -> MudStack ()
bcastOtherAdmins = bcastAdminsHelper . delete


-----


bcastOthersInRm :: Id -> Text -> MudStack ()
bcastOthersInRm i msg = getState >>= \ms ->
    let helper = let ((i `delete`) -> ris) = getMobRmInv i ms
                 in bcast . pure $ (msg, findMobIds ms ris)
    in isPC i ms ? unless (isIncognito . getPla i $ ms) helper :? helper


-----


dbError :: MsgQueue -> Cols -> MudStack ()
dbError mq cols = wrapSend mq cols dbErrorMsg >> sendSilentBoot mq


-----


massMsg :: Msg -> MudStack ()
massMsg msg = liftIO . atomically . helperSTM =<< getState
  where
    helperSTM (views msgQueueTbl IM.elems -> mqs) = forM_ mqs $ flip writeTQueue msg


-----


massSend :: Text -> MudStack ()
massSend msg = liftIO . atomically . helperSTM =<< getState
  where
    helperSTM ms@(views msgQueueTbl IM.toList -> kvs) = forM_ kvs $ \(i, mq) ->
        let cols = getColumns i ms
        in writeTQueue mq . FromServer . frame cols . wrapUnlines cols $ msg


-----


mkBcast :: Id -> Text -> [Broadcast]
mkBcast i = pure . (, pure i)


-----


mkNTBcast :: Id -> Text -> [ClassifiedBcast]
mkNTBcast i = pure . NonTargetBcast . (, pure i)


-----


multiWrapSend :: MsgQueue -> Cols -> [Text] -> MudStack ()
multiWrapSend mq cols = send mq . multiWrapNl cols


-----


ok :: MsgQueue -> MudStack ()
ok mq = send mq . nlnl $ "OK!"


-----


parseDesig :: Id -> MudState -> Text -> Text
parseDesig i ms = loop (getIntroduced i ms)
  where
    loop intros txt
      | T.singleton stdDesigDelimiter `T.isInfixOf` txt
      , (left, pcd, rest) <- extractDesigTxt stdDesigDelimiter txt
      = case pcd of
        d@StdDesig { sDesigEntSing = Just es, .. } ->
          left                                            <>
          (es `elem` intros ? es :? expandEntName i ms d) <>
          loop intros rest
        d@StdDesig { sDesigEntSing = Nothing,  .. } ->
          left <> expandEntName i ms d <> loop intros rest
        _ -> patternMatchFail "parseDesig loop" [ showText pcd ]
      | T.singleton nonStdDesigDelimiter `T.isInfixOf` txt
      , (left, NonStdDesig { .. }, rest) <- extractDesigTxt nonStdDesigDelimiter txt
      = left <> (nsDesigEntSing `elem` intros ? nsDesigEntSing :? nsDesc) <> loop intros rest
      | otherwise = txt
    extractDesigTxt (T.singleton -> c) (T.breakOn c -> (left, T.breakOn c . T.tail -> (pcdTxt, T.tail -> rest)))
      | pcd <- deserialize . quoteWith c $ pcdTxt :: Desig
      = (left, pcd, rest)


expandEntName :: Id -> MudState -> Desig -> Text
expandEntName i ms StdDesig { .. } =
  let f      = mkCapsFun shouldCap
      (h, t) = headTail desigEntName
  in if isPC desigId ms
    then T.concat [ f "the ", xth, expandSex h, " ", t ]
    else let s = getSing desigId ms in onFalse (isCapital s) (f . ("the " <>)) s
  where
    xth = let intros  = getIntroduced i ms
              idsInRm = filter ((`notElem` intros) . (`getSing` ms)) $ i `delete` desigIds
              matches = foldr (\pi acc -> onTrue (mkUnknownPCEntName pi ms == desigEntName) (pi :) acc) [] idsInRm
          in length matches > 1 |?| (<> " ") . mkOrdinal . succ . fromJust . elemIndex desigId $ matches
    expandSex 'm'                = "male"
    expandSex 'f'                = "female"
    expandSex (T.singleton -> x) = patternMatchFail "expandEntName expandSex" [x]
expandEntName _ _ d = patternMatchFail "expandEntName" [ showText d ]


-----


retainedMsg :: Id -> MudState -> Text -> MudStack ()
retainedMsg targetId ms msg@(T.uncons -> Just (x, xs))
  | isNpc targetId ms                 = bcastNl . mkBcast targetId $ stripMarker
  | isLoggedIn . getPla targetId $ ms = let (targetMq, targetCols) = getMsgQueueColumns targetId ms
                                        in wrapSend targetMq targetCols stripMarker
  | otherwise                         = tweak $ plaTbl.ind targetId.retainedMsgs <>~ pure msg
  where
    stripMarker | x == fromPersonMarker = xs
                | otherwise             = msg
retainedMsg _ _ _ = unit


-----


send :: MsgQueue -> Text -> MudStack ()
send mq = liftIO . atomically . writeTQueue mq . FromServer


-----


sendDfltPrompt :: MsgQueue -> Id -> MudStack ()
sendDfltPrompt mq i = sendPrompt mq . mkDfltPrompt i =<< getState


mkDfltPrompt :: Id -> MudState -> Text
mkDfltPrompt i ms = let (hps, mps, pps, fps) = getPts i ms
                        marker               = colorWith indentColor " "
                    in marker <> " " <> spaces [ f "h" hps
                                               , f "m" mps
                                               , f "p" pps
                                               , f "f" fps ]
  where
    indentColor = isNpc i ms ? toNpcColor :? promptIndentColor
    f a (x, y)  = let c   = if | x == y    -> green
                               | per > 67  -> cyan
                               | per > 33  -> yellow
                               | per > 10  -> red
                               | otherwise -> magenta
                      per = round $ x `divide` y * 100
                  in colorWith c a <> showText x


-----


sendMsgBoot :: MsgQueue -> Maybe Text -> MudStack ()
sendMsgBoot mq = liftIO . atomically . writeTQueue mq . MsgBoot . fromMaybe dfltBootMsg


sendSilentBoot :: MsgQueue -> MudStack ()
sendSilentBoot mq = liftIO . atomically . writeTQueue mq $ SilentBoot


-----


sendPrompt :: MsgQueue -> Text -> MudStack ()
sendPrompt mq = liftIO . atomically . writeTQueue mq . Prompt


wrapSendPrompt :: MsgQueue -> Cols -> Text -> MudStack ()
wrapSendPrompt mq cols = sendPrompt mq . wrapUnlinesInit cols


-----


wrapSend :: MsgQueue -> Cols -> Text -> MudStack ()
wrapSend mq cols = send mq . wrapUnlinesNl cols
