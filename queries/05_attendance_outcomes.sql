-- ============================================================
-- 05_attendance_outcomes.sql
-- CC BI Semantic Model Redesign | BizOps | Sep 2026
--
-- Page:    Attendance Outcomes
-- Answers: "Do confirmations actually turn into attendance?"
--           Q7 — how many confirmations turned to attendance?
--           Q8 — how many confirmations turned to no shows?
--
-- Source: vw_tickets_all (current state) joined to vw_confirmation_actions
--   Past events only (event_date < today).
--   is_last_confirmer = 1 gives one row per ticket — the rep who last
--   held the confirmation. t.status is the authoritative outcome field.
--
-- t.status relevant values for this page:
--   'Attended'   → confirmed, showed up        (Q7)
--   'No Show'    → confirmed, did not show up  (Q8)
--   All other statuses (Open, Reserved, etc.) are excluded —
--   they only appear on future/in-progress tickets, not past events.
--
-- Grain: one row per event / confirmation_status / ticket status.
--   Power BI computes the rates (Attended %, No Show %).
-- ============================================================

SELECT
    ev.EventName                                AS event_name,
    CAST(ev.StartDate AS date)                  AS event_date,
    ev.EventType                                AS event_type,
    ca.confirmation_status,                     -- Confirmed | Double Confirmed
    t.status                                    AS ticket_status, -- Attended | No Show

    COUNT(DISTINCT ca.ticket_id)                AS tickets

FROM [dbo].[vw_confirmation_actions]    ca
JOIN [dbo].[vw_tickets_all]             t   ON  ca.ticket_id        = t.ticket_id
                                            AND t.is_reset_ghost    = 0
JOIN [DWH].[DimEvent]                   ev  ON  t.event_id          = ev.CVEventID

WHERE
    ca.is_rep_action        = 1
    AND ca.is_last_confirmer = 1                                    -- one row per ticket
    AND LOWER(ca.confirmation_status) IN ('confirmed', 'double confirmed')
    AND t.event_date        < CAST(GETDATE() AS date)               -- past events only
    AND LOWER(t.status)     IN ('attended', 'no show')              -- outcomes only

GROUP BY
    ev.CVEventID,
    ev.EventName,
    ev.StartDate,
    ev.EventType,
    ca.confirmation_status,
    t.status

ORDER BY
    ev.StartDate            DESC,
    ca.confirmation_status,
    t.status;
