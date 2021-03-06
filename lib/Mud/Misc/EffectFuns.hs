{-# LANGUAGE OverloadedStrings #-}

module Mud.Misc.EffectFuns ( effectFuns
                           , instaEffectFuns ) where

import Mud.Data.State.MudData
import Mud.Data.State.Util.Get
import Mud.Data.State.Util.Misc
import Mud.Data.State.Util.Output
import Mud.Data.State.Util.Random
import Mud.TheWorld.Liqs
import Mud.Util.Misc


effectFuns :: [(FunName, EffectFun)]
effectFuns = pure (potTinnitusTag, tinnitusEffectFun)


instaEffectFuns :: [(FunName, InstaEffectFun)]
instaEffectFuns = pure (potTinnitusTag, tinnitusInstaEffectFun)


-----


tinnitusEffectFun :: EffectFun
tinnitusEffectFun i secs | isZero $ secs `mod` 5 = rndmDo_ 25 $ getMsgQueueColumns i <$> getState >>= \(mq, cols) ->
                               wrapSend mq cols "There is an awful ringing in your ears."
                         | otherwise = unit


tinnitusInstaEffectFun :: InstaEffectFun
tinnitusInstaEffectFun i = getMsgQueueColumns i <$> getState >>= \(mq, cols) ->
    wrapSend mq cols "There is a terrible ringing in your ears."
