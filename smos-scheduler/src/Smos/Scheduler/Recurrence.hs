{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Smos.Scheduler.Recurrence
  ( RecurrenceHistory,
    LatestActivation (..),
    readReccurrenceHistory,
    computeLastRun,
    NextRun (..),
    computeNextRun,
    rentNextRun,
    haircutNextRun,
    parseSmosFileSchedule,
    parseEntrySchedule,
    addScheduleHashMetadata,
    scheduleHashPropertyName,
  )
where

import Conduit
import qualified Data.Conduit.Combinators as C
import Data.Map (Map)
import qualified Data.Map as M
import Data.Maybe
import Data.Time
import Data.Tree
import Data.Validity
import GHC.Generics (Generic)
import Path
import Safe
import Smos.Data
import Smos.Report.Archive
import Smos.Report.Config
import Smos.Report.ShouldPrint
import Smos.Report.Streaming
import Smos.Report.Time (timeNominalDiffTime)
import Smos.Scheduler.OptParse.Types
import System.Cron as Cron

type RecurrenceHistory = Map ScheduleItemHash LatestActivation

data LatestActivation = LatestActivation
  { latestActivationActivated :: !UTCTime,
    latestActivationClosed :: !(Maybe UTCTime)
  }
  deriving (Show, Eq, Generic)

instance Validity LatestActivation

instance Semigroup LatestActivation where
  (<>) la1@(LatestActivation a1 _) la2@(LatestActivation a2 _) =
    if a1 >= a2
      then la1
      else la2

readReccurrenceHistory :: DirectoryConfig -> IO RecurrenceHistory
readReccurrenceHistory dc = do
  workflowDir <- resolveDirWorkflowDir dc
  archiveDir <- resolveDirArchiveDir dc

  let go :: Path Rel File -> SmosFile -> RecurrenceHistory
      go rf sf =
        case parseSmosFileSchedule sf of
          Nothing -> M.empty
          Just h ->
            let EarliestLatest {..} = smosFileStateChanges sf
                mActivation = do
                  latestActivationActivated <- earliest
                  let latestActivationClosed = case stripProperPrefix archiveDir (workflowDir </> rf) of
                        Nothing ->
                          -- Not in archive, so definitely unfinished
                          Nothing
                        Just _ ->
                          -- In archive, so the latest entry represents completion
                          latest

                  pure LatestActivation {..}
             in case mActivation of
                  Nothing -> M.empty
                  Just a -> M.singleton h a

  runConduit $
    streamSmosFilesFromWorkflowRel Don'tHideArchive dc
      .| parseSmosFilesRel workflowDir
      .| printShouldPrint DontPrint -- TODO make this configurable
      .| C.map (uncurry go)
      .| C.foldl (M.unionWith (<>)) M.empty

parseSmosFileSchedule :: SmosFile -> Maybe ScheduleItemHash
parseSmosFileSchedule sf = case smosFileForest sf of
  [] -> Nothing
  (Node e _ : _) -> parseEntrySchedule e

parseEntrySchedule :: Entry -> Maybe ScheduleItemHash
parseEntrySchedule e = do
  hashPropertyValue <- M.lookup scheduleHashPropertyName (entryProperties e)
  parseScheduleItemHash (propertyValueText hashPropertyValue)

addScheduleHashMetadata :: ScheduleItemHash -> SmosFile -> SmosFile
addScheduleHashMetadata h sf = makeSmosFile $ goF (smosFileForest sf)
  where
    goF :: Forest Entry -> Forest Entry
    goF = \case
      [] -> [Node (goE emptyEntry) []]
      (t : rest) -> goT t : rest
    goT :: Tree Entry -> Tree Entry
    goT (Node e sub) = Node (goE e) sub
    goE :: Entry -> Entry
    goE e =
      let mpv = propertyValue $ renderScheduleItemHash h
       in case mpv of
            Nothing -> e
            Just pv ->
              e
                { entryProperties =
                    M.insert
                      scheduleHashPropertyName
                      pv
                      (entryProperties e)
                }

scheduleHashPropertyName :: PropertyName
scheduleHashPropertyName = "schedule-hash"

computeLastRun :: RecurrenceHistory -> ScheduleItemHash -> Maybe UTCTime
computeLastRun rh sih =
  latestActivationActivated <$> M.lookup sih rh

data NextRun
  = ActivateImmediatelyAsIfAt !UTCTime
  | ActivateNoSoonerThan !UTCTime
  | DoNotActivate
  deriving (Show, Eq, Generic)

instance Validity NextRun

computeNextRun :: RecurrenceHistory -> UTCTime -> ScheduleItem -> NextRun
computeNextRun rh now si =
  let sih = hashScheduleItem si
   in case M.lookup sih rh of
        Nothing -> ActivateImmediatelyAsIfAt $ case scheduleItemRecurrence si of
          RentRecurrence cs -> fromMaybe now $ rentNextRunAfter now cs
          HaircutRecurrence _ -> now
        Just la ->
          case scheduleItemRecurrence si of
            RentRecurrence cs -> case rentNextRun la cs of
              Just next -> ActivateNoSoonerThan next
              Nothing -> DoNotActivate
            HaircutRecurrence t -> case haircutNextRun la (timeNominalDiffTime t) of
              Just next -> ActivateNoSoonerThan next
              Nothing -> DoNotActivate

rentNextRun :: LatestActivation -> CronSchedule -> Maybe UTCTime
rentNextRun la = rentNextRunAfter (latestActivationActivated la)

rentNextRunAfter :: UTCTime -> CronSchedule -> Maybe UTCTime
rentNextRunAfter lastActivated cs = Cron.nextMatch cs lastActivated

haircutNextRun :: LatestActivation -> NominalDiffTime -> Maybe UTCTime
haircutNextRun la ndt =
  case latestActivationClosed la of
    Nothing ->
      -- Still in flight, don't reactivate
      Nothing
    Just closed ->
      -- Closed, plan next activation
      Just $ addUTCTime ndt closed

smosFileStateChanges :: SmosFile -> EarliestLatest UTCTime
smosFileStateChanges = foldMap entryStateChanges . concatMap flatten . smosFileForest

entryStateChanges :: Entry -> EarliestLatest UTCTime
entryStateChanges = stateHistoryStateChanges . entryStateHistory

stateHistoryStateChanges :: StateHistory -> EarliestLatest UTCTime
stateHistoryStateChanges sh =
  let l = map stateHistoryEntryTimestamp (unStateHistory sh)
   in EarliestLatest (lastMay l) (headMay l)

data EarliestLatest a = EarliestLatest
  { earliest :: Maybe a,
    latest :: Maybe a
  }

instance Ord a => Semigroup (EarliestLatest a) where
  (<>) (EarliestLatest me1 ml1) (EarliestLatest me2 ml2) =
    EarliestLatest
      { earliest = case (me1, me2) of
          (Just e1, Just e2) -> Just $ min e1 e2
          (_, Nothing) -> me1
          (Nothing, _) -> me2,
        latest = case (ml1, ml2) of
          (Just e1, Just e2) -> Just $ max e1 e2
          (_, Nothing) -> ml1
          (Nothing, _) -> ml2
      }

instance Ord a => Monoid (EarliestLatest a) where
  mempty = EarliestLatest Nothing Nothing
  mappend = (<>)
