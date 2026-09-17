-- ============================================================
-- 02_rep_performance.sql
-- CC BI Semantic Model Redesign | BizOps | Sep 2026
--
-- Page:    Rep Performance
-- Answers: "How many tickets did each rep confirm — today, this week,
--           by event?"
--
-- Source: vw_confirmation_actions (activity log)
--   NOT vw_tickets_all — this page is about what reps DID,
--   not the current state of tickets.
--
-- Fix for overcounting:
--   COUNT DISTINCT ticket_id per rep per day.
--   If a rep confirms the same ticket 3 times in one day (e.g. it
--   bounced to undecided twice), it still counts as 1 — they got
--   one ticket confirmed.
--
-- is_rep_action = 1 filters out system-generated actions (dialer,
--   automated status changes). Only human rep touches count.
--
-- Grain: one row per rep / date / event / confirmation_status.
--   Power BI slicers handle the today / this week aggregation.
--
-- ⚠ OPEN QUESTION FOR KYLE — tickets with no event_id:
--   A small number of confirmation actions in the history log have
--   no event_id on the ticket at the time of the action (ticket was
--   confirmed before being assigned to an event, or data anomaly).
--   This query's JOIN to vw_tickets_all (via event_id → DimEvent)
--   will DROP those actions — they won't appear for any rep.
--   Decision needed: should these count (toward a rep's total),
--   or are they safe to ignore?
--
-- ✅ VALIDATED (Sep 2026):
--   is_rep_action exact logic (from view definition):
--     changed_by NOT IN ('System', 'bulk-import') → is_rep_action = 1
--   Three touch sources feed vw_confirmation_actions:
--     'Status Update'    – history action = 'Confirmation status updated'
--     'Date Update'      – history action = 'Confirmation date updated'
--     'Pre-History Direct' – synthesized from tickets.confirmed_by where no
--                            matching history row exists (~128 tickets)
--   Date Update is the dominant source on many days (e.g. Sep 17: 57 Date Update
--   vs 10 Status Update). Earlier validation pass missed this — counts corrected.
-- ============================================================

SELECT
    e.EmployeeName                              AS rep_name,
    e.Email                                     AS rep_email,
    e.Team                                      AS rep_team,
    ca.action_date_az                           AS action_date,
    ca.week_label,
    ca.week_offset,       -- 0 = current week, -1 = last week, etc.
    ev.EventName                                AS event_name,
    ev.EventType                                AS event_type,
    CAST(ev.StartDate AS date)                  AS event_date,
    ca.confirmation_status,

    -- Distinct tickets confirmed: one ticket = one credit even if
    -- the rep touched it multiple times on the same day.
    COUNT(DISTINCT ca.ticket_id)                AS tickets_confirmed

FROM [dbo].[vw_confirmation_actions]    ca
JOIN [DWH].[DimEmployee]                e   ON  ca.user_email       = e.Email
JOIN [dbo].[vw_tickets_all]             t   ON  ca.ticket_id        = t.ticket_id
                                            AND t.is_reset_ghost    = 0
JOIN [DWH].[DimEvent]                   ev  ON  t.event_id          = ev.CVEventID

WHERE
    ca.is_rep_action        = 1     -- human rep actions only
    AND LOWER(ca.confirmation_status) IN ('confirmed', 'double confirmed')

GROUP BY
    e.EmployeeName,
    e.Email,
    e.Team,
    ca.action_date_az,
    ca.week_label,
    ca.week_offset,
    ev.EventName,
    ev.EventType,
    ev.StartDate,
    ca.confirmation_status

ORDER BY
    ca.action_date_az       DESC,
    tickets_confirmed       DESC;
