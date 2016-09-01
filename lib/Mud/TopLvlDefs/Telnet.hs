{-# LANGUAGE OverloadedStrings #-}

module Mud.TopLvlDefs.Telnet where

import Data.Text (Text)
import qualified Data.Text as T


{-# ANN module ("HLint: ignore Use camelCase" :: String) #-}


-- ==================================================


telnetECHO, telnetEOR, telnetGA, telnetIAC, telnetSB, telnetSE, telnetWILL, telnetWON'T :: Char
telnetECHO  = '\x01' -- 1
telnetEOR   = '\xEF' -- 239
telnetGA    = '\xF9' -- 249
telnetIAC   = '\xFF' -- 255
telnetSB    = '\xFA' -- 250
telnetSE    = '\xF0' -- 240
telnetWILL  = '\xFB' -- 251
telnetWON'T = '\xFC' -- 252


telnetEndOfRecord, telnetGoAhead, telnetHideInput, telnetShowInput :: Text
telnetEndOfRecord = T.pack [ telnetIAC, telnetEOR               ]
telnetGoAhead     = T.pack [ telnetIAC, telnetGA                ]
telnetHideInput   = T.pack [ telnetIAC, telnetWILL,  telnetECHO ]
telnetShowInput   = T.pack [ telnetIAC, telnetWON'T, telnetECHO ]
