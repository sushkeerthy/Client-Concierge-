-- ============================================================
-- 01_event_overview.sql
-- CC BI Semantic Model Redesign | BizOps | Sep 2026
--
-- Page:    Event Overview
-- Answers: "What is the current confirmation state for each event?"
--
-- Source of truth: vw_tickets_all (is_reset_ghost = 0 only)
--   Ghost rows (is_reset_ghost = 1) are no-show resets — they represent
--   tickets that already no-showed and were recycled. Excluding them here
--   makes this query match the EventFlow app UI exactly, which reads
--   directly from [10XHub].[tickets].
--
-- Grain: one row per event
--
-- Validation target: numbers here should match what the CC team
--   sees in the EventFlow app for each event's confirmation counts.
--
-- ⚠ OPEN QUESTION FOR KYLE — 'Scheduled' ticket status:
--   Status enum: Scheduled = associated with the event but NO attendee assigned yet.
--   This query currently counts Scheduled tickets in total_tickets.
--   The EventFlow app may exclude them (showing only Reserved+ which have an attendee).
--   Observed deltas:
--     CV-330 (Sep 24-25 10X360):   query = 48 total | app = 46  → 2 Scheduled tickets
--     CV-337 (Oct 09-11 Elite Edge): similar delta observed, exact count TBD
--   Decision needed: should Scheduled tickets count toward total_tickets?
--   If NO → add:  AND LOWER(t.status) NOT IN ('scheduled', 'cancelled')
--   If YES → no change needed (current behavior).
-- ============================================================

SELECT
    e.EventName                                                         AS event_name,
    e.EventCode                                                         AS event_code,
    e.EventType                                                         AS event_type,
    CAST(e.StartDate AS date)                                           AS event_date,
    e.TargetAttendance                                                  AS target_attendance,

    -- Total live tickets for this event (matches app count)
    COUNT(DISTINCT t.ticket_id)                                         AS total_tickets,

    -- Confirmed only (not yet double confirmed)
    COUNT(DISTINCT CASE
        WHEN LOWER(t.confirmation_status) = 'confirmed'
        THEN t.ticket_id
    END)                                                                AS confirmed,

    -- Double confirmed
    COUNT(DISTINCT CASE
        WHEN LOWER(t.confirmation_status) = 'double confirmed'
        THEN t.ticket_id
    END)                                                                AS double_confirmed,

    -- Combined: Confirmed + Double Confirmed
    COUNT(DISTINCT CASE
        WHEN LOWER(t.confirmation_status) IN ('confirmed', 'double confirmed')
        THEN t.ticket_id
    END)                                                                AS total_confirmed,

    -- % of total tickets that are confirmed (either level)
    ROUND(
        100.0
        * COUNT(DISTINCT CASE
            WHEN LOWER(t.confirmation_status) IN ('confirmed', 'double confirmed')
            THEN t.ticket_id
          END)
        / NULLIF(COUNT(DISTINCT t.ticket_id), 0),
        1
    )                                                                   AS pct_confirmed,

    -- % of target attendance reached
    ROUND(
        100.0
        * COUNT(DISTINCT CASE
            WHEN LOWER(t.confirmation_status) IN ('confirmed', 'double confirmed')
            THEN t.ticket_id
          END)
        / NULLIF(e.TargetAttendance, 0),
        1
    )                                                                   AS pct_of_target

FROM [dbo].[vw_tickets_all]         t
JOIN [DWH].[DimEvent]               e   ON t.event_id = e.CVEventID

WHERE
    t.is_reset_ghost = 0                    -- live tickets only — matches EventFlow app
    AND LOWER(t.status) != 'cancelled'      -- cancelled tickets excluded from all counts

GROUP BY
    e.CVEventID,
    e.EventName,
    e.EventCode,
    e.EventType,
    e.StartDate,
    e.TargetAttendance

ORDER BY e.StartDate DESC;
