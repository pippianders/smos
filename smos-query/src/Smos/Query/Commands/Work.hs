{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}

module Smos.Query.Commands.Work
  ( smosQueryWork,
  )
where

import Conduit
import Data.List (intercalate)
import Data.List.NonEmpty (NonEmpty)
import Data.Map (Map)
import qualified Data.Map as M
import qualified Data.Text as T
import Data.Time
import Path
import Smos.Query.Config
import Smos.Query.Formatting
import Smos.Query.OptParse.Types
import Smos.Report.Entry
import Smos.Report.Filter
import Smos.Report.Projection
import Smos.Report.Work

smosQueryWork :: WorkSettings -> Q ()
smosQueryWork WorkSettings {..} = do
  src <- asks smosQueryConfigReportConfig
  now <- liftIO getZonedTime
  let wc = smosReportConfigWorkConfig src
  let contexts = workReportConfigContexts wc
  mcf <- forM workSetContext $ \cn ->
    case M.lookup cn contexts of
      Nothing -> dieQ $ unwords ["Context not found:", T.unpack $ contextNameText cn]
      Just cf -> pure cf
  wd <- liftIO $ resolveReportWorkflowDir src
  pd <- liftIO $ resolveReportProjectsDir src
  let mpd = stripProperPrefix wd pd
  let wrc =
        WorkReportContext
          { workReportContextNow = now,
            workReportContextProjectsSubdir = mpd,
            workReportContextBaseFilter = workReportConfigBaseFilter wc,
            workReportContextCurrentContext = mcf,
            workReportContextTimeProperty = workReportConfigTimeProperty wc,
            workReportContextTime = workSetTime,
            workReportContextAdditionalFilter = workSetFilter,
            workReportContextContexts = contexts,
            workReportContextChecks = workReportConfigChecks wc,
            workReportContextSorter = workSetSorter,
            workReportContextWaitingThreshold = workSetWaitingThreshold,
            workReportContextStuckThreshold = workSetStuckThreshold
          }
  sp <- getShouldPrint
  wr <- produceWorkReport workSetHideArchive sp (smosReportConfigDirectoryConfig src) wrc
  cc <- asks smosQueryConfigColourConfig
  outputChunks $
    renderWorkReport
      cc
      now
      contexts
      workSetWaitingThreshold
      workSetStuckThreshold
      workSetProjection
      wr

renderWorkReport :: ColourConfig -> ZonedTime -> Map ContextName EntryFilterRel -> Word -> Word -> NonEmpty Projection -> WorkReport -> [Chunk]
renderWorkReport cc now ctxs waitingThreshold stuckThreshold ne WorkReport {..} =
  mconcat $
    concat $
      intercalate [spacer] $
        filter
          (not . null)
          [ unlessNull
              workReportNextBegin
              [ sectionHeading "Next meeting",
                [formatAsBicolourTable cc $ maybe [] ((: []) . formatAgendaEntry now) workReportNextBegin]
              ],
            unlessNull
              ctxs
              $ unlessNull
                workReportEntriesWithoutContext
                [ warningHeading
                    "Entries without context",
                  [entryTable workReportEntriesWithoutContext]
                ],
            unlessNull
              workReportCheckViolations
              ( flip concatMap (M.toList workReportCheckViolations) $
                  \(f, violations) ->
                    unlessNull violations [warningHeading ("Check violation for " <> renderFilter f), [entryTable violations]]
              ),
            unlessNull
              workReportAgendaEntries
              [ sectionHeading "Deadlines",
                [agendaTable]
              ],
            unlessNull
              workReportOverdueWaiting
              [ warningHeading "Overdue Waiting Entries",
                [waitingTable]
              ],
            unlessNull
              workReportOverdueStuck
              [ warningHeading "Overdue Stuck Projects",
                [stuckTable]
              ],
            unlessNull
              workReportResultEntries
              [ sectionHeading "Next actions",
                [entryTable workReportResultEntries]
              ]
          ]
  where
    unlessNull l r =
      if null l
        then []
        else r
    sectionHeading t = heading $ underline $ fore white $ chunk t
    warningHeading t = heading $ underline $ fore red $ chunk ("WARNING: " <> t)
    heading c = [formatAsBicolourTable cc [[c]]]
    spacer = [formatAsBicolourTable cc [[chunk " "]]]
    entryTable = renderEntryReport cc . makeEntryReport ne
    agendaTable = formatAsBicolourTable cc $ map (formatAgendaEntry now) workReportAgendaEntries
    waitingTable = formatAsBicolourTable cc $ map (formatWaitingEntry waitingThreshold (zonedTimeToUTC now)) workReportOverdueWaiting
    stuckTable = formatAsBicolourTable cc $ map (formatStuckReportEntry stuckThreshold (zonedTimeToUTC now)) workReportOverdueStuck
