-- ============================================================
-- 05_attendance_outcomes.sql
-- CC BI Semantic Model Redesign | BizOps | Sep 2026
--
-- Page:    Attendance Outcomes
-- Answers: "Do confirmations actually turn into attendance?"
--           Q7 — how many confirmations turned to attendance?
--           Q8 — how many confirmations turned to no shows?
--
-- Source: vw_confirmation_actions (has ticket_outcome)
--   Past events only (event_date < today).
--   is_last_confirmer = 1 gives one row per ticket showing the
--   rep who last held the confirmation and what happened to it.
--
-- ticket_outcome values to validate with CC team:
--   'Attended', 'No Show', 'No Show (Reset)', others?
--
-- Grain: one row per event / confirmation_status / ticket_outcome.
--   Power BI computes the rates (Attended %, No Show %).
-- ============================================================

SELECT
    ev.EventName                                AS event_name,
    CAST(ev.StartDate AS date)                  AS event_date,
    ev.EventType                                AS event_type,
    ca.confirmation_status,                     -- Confirmed | Double Confirmed
    ca.ticket_outcome,                          -- Attended | No Show | No Show (Reset) | ...

    COUNT(DISTINCT ca.ticket_id)                AS tickets

FROM [dbo].[vw_confirmation_actions]    ca
JOIN [dbo].[vw_tickets_all]             t   ON  ca.ticket_id        = t.ticket_id
                                            AND t.is_reset_ghost    = 0
JOIN [DWH].[DimEvent]                   ev  ON  t.event_id          = ev.CVEventID

WHERE
    ca.is_rep_action        = 1
    AND ca.is_last_confirmer = 1            -- one row per ticket
    AND LOWER(ca.confirmation_status) IN ('confirmed', 'double confirmed')
    AND t.event_date        < CAST(GETDATE() AS date)   -- past events only
    AND ca.ticket_outcome   IS NOT NULL

GROUP BY
    ev.CVEventID,
    ev.EventName,
    ev.StartDate,
    ev.EventType,
    ca.confirmation_status,
    ca.ticket_outcome

ORDER BY
    ev.StartDate            DESC,
    ca.confirmation_status,
    ca.ticket_outcome;
