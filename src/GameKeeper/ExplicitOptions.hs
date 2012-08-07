{-# LANGUAGE RankNTypes #-}

-- |
-- Module      : GameKeeper.ExplicitOptions
-- Copyright   : (c) 2012 Brendan Hay <brendan@soundcloud.com>
-- License     : This Source Code Form is subject to the terms of
--               the Mozilla Public License, v. 2.0.
--               A copy of the MPL can be found in the LICENSE file or
--               you can obtain it at http://mozilla.org/MPL/2.0/.
-- Maintainer  : Brendan Hay <brendan@soundcloud.com>
-- Stability   : experimental
-- Portability : non-portable (GHC extensions)
--

module GameKeeper.ExplicitOptions (
    -- * Exported Types
      Options(..)
    , Health(..)

    -- * Functions
    , parseOptions
    ) where

import Data.Version                    (showVersion)
import Paths_gamekeeper                (version)
import System.Console.CmdArgs.Explicit hiding (modes)
import System.Environment              (getArgs)
import GameKeeper.Http
import GameKeeper.Metric        hiding (measure)

data Health = Health
    { healthWarn :: Double
    , healthCrit :: Double
    } deriving (Eq, Show)

data Options
    = Help SubMode
    | Version
    | Measure
      { optUri      :: Uri
      , optDays     :: Int
      , optSink     :: SinkOptions
      }
    | PruneConnections
      { optUri      :: Uri
      , optDays     :: Int
      }
    | PruneQueues
      { optUri      :: Uri
      }
    | CheckNode
      { optUri      :: Uri
      , optMessages :: Health
      , optMemory   :: Health
      }
    | CheckQueue
      { optUri      :: Uri
      , optMessages :: Health
      , optMemory   :: Health
      }
    deriving (Show)

data SubMode = SubMode
    { name  :: String
    , def   :: Options
    , help  :: String
    , flags :: [Flag Options]
    , modes :: [SubMode]
    } deriving (Show)

--
-- API
--

parseOptions :: IO (Either String Options)
parseOptions = do
    args <- getArgs
    return $ case processValue (expandMode program) args of
        (Help m) -> Left . show $ helpText [] HelpFormatOne (expandMode m)
        Version  -> Left programInfo
        opts     -> Right opts

--
-- Info
--

programName, programInfo :: String
programName = "gamekeeper"
programInfo = concat
    [ programName
    , " version "
    , showVersion version
    , " (C) Brendan Hay <brendan@soundcloud.com> 2012"
    ]

--
-- Defaults
--

uri :: Uri
uri = parseUri "http://guest:guest@127.0.0.1:55672/"

health, messages, memory :: Double -> Health
health crit = Health (fromInteger . floor $ crit / 2) crit
messages    = health
memory      = health

oneMonth :: Int
oneMonth = 30

quarterMillion, fiftyMillion :: Double
quarterMillion = 250000
fiftyMillion   = 50000000

twoGigabytes, tenGigabytes :: Double
twoGigabytes = 2048
tenGigabytes = 10240

--
-- Modes
--

measure :: SubMode
measure = subMode
    { name  = "measure"
    , def   = Measure uri oneMonth (SinkOptions Stdout "" "")
    , help  = "Measure and emit metrics to the specified sink"
    , flags = [uriFlag]
    }

pruneConnections :: SubMode
pruneConnections = subMode
    { name  = "connections"
    , def   = PruneConnections uri oneMonth
    , help  = "Perform idle connection pruning"
    , flags = [uriFlag]
    }

pruneQueues :: SubMode
pruneQueues = subMode
    { name  = "queues"
    , def   = PruneQueues uri
    , help  = "Perform inactive queue pruning"
    , flags = [uriFlag]
    }

prune :: SubMode
prune = subMode
    { name  = "prune"
    , def   = Help prune
    , help  = "Prune mode"
    , modes = [pruneConnections, pruneQueues]
    }

checkNode :: SubMode
checkNode = subMode
    { name  = "node"
    , def   = CheckNode uri (messages fiftyMillion) (memory tenGigabytes)
    , help  = "Check a node's memory and message backlog"
    , flags = [uriFlag]
    }

checkQueue :: SubMode
checkQueue = subMode
    { name  = "queue"
    , def   = CheckQueue uri (messages quarterMillion) (messages twoGigabytes)
    , help  = "Check a queue's memory and message backlog"
    , flags = [ uriFlag
              , flagReq ["mem-warning"] (\s o -> Right $ o { optMemory = Health 0 0 })
                "MB" "The warning threshold for memory usage"
              , flagReq ["mem-critical"] (\s o -> Right $ o { optMemory = Health 0 0 })
                "MB" "The critical threshold for memory usage"
              ]
    }

check :: SubMode
check = subMode
    { name  = "check"
    , def   = Help check
    , help  = "Check stuff"
    , modes = [checkNode, checkQueue]
    }

program :: SubMode
program = subMode
    { name  = programName
    , def   = Help program
    , help  = "Program help"
    , flags = [flagVersion (\_ -> Version)]
    , modes = [measure, prune, check]
    }

--
-- Mode Constructors
--

subMode :: SubMode
subMode = SubMode "" (Help program) "" [] []

expandMode :: SubMode -> Mode Options
expandMode m@SubMode{..} | null modes = child
                         | otherwise  = parent
  where
    errFlag = flagArg (\x _ -> Left $ "Unexpected argument " ++ x) ""
    child   = mode name def help errFlag $ appendDefaults m flags
    parent  = (modeEmpty def)
        { modeNames      = [name]
        , modeHelp       = help
        , modeArgs       = ([], Nothing)
        , modeGroupFlags = toGroup $ appendDefaults m flags
        , modeGroupModes = toGroup $ map expandMode modes
        }

--
-- Flags
--

uriFlag :: Flag Options
uriFlag = flagReq ["uri"] (\s o -> Right $ o { optUri = parseUri s }) "URI" help
  where
    help = "URI of the RabbitMQ HTTP API (default: guest@localhost:55672)"

helpFlag :: a -> Flag a
helpFlag m = flagNone ["help", "h"] (\_ -> m) "Display this help message"

appendDefaults :: SubMode -> [Flag Options] -> [Flag Options]
appendDefaults m = (++ [helpFlag $ Help m])