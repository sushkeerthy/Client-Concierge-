-- ============================================================
-- 06_travel_status.sql
-- CC BI Semantic Model Redesign | BizOps | Sep 2026
--
-- Page:    Travel Status
-- Answers: "How many are traveling and what are their arrangements?"
--           Q9 — how many travel confirmations in each category?
--
-- Source: vw_tickets_all (current state)
--   travel_details column added Sep 2026.
--   Only confirmed tickets matter here — unconfirmed travel details
--   are not actionable.
--   Ghost rows (is_reset_ghost = 1) are excluded — their travel
--   data is NULL anyway.
--
-- ✅ VALIDATED (Sep 2026):
--   travel_details column: EXISTS on tickets ✅
--   attendance_type column: EXISTS on tickets ✅ — live value is 'In-Person' (hyphenated),
--   not 'In Person'. Query groups by this column so casing doesn't break anything,
--   but any slicer label or DAX filter must match 'In-Person' exactly.
--
-- travel_details expected values (validate with CC team):
--   'Hotel Only', 'Flight Only', 'Both', 'Is Local', NULL
--   NULL = travel not yet confirmed / not applicable
--
-- Grain: one row per event / travel_details category.
-- ============================================================

SELECT
    ev.EventName                                AS event_name,
    CAST(ev.StartDate AS date)                  AS event_date,
    ev.EventType                                AS event_type,
    t.attendance_type,                          -- In Person | Virtual

    -- Bucket NULLs so they show up cleanly in the report
    COALESCE(t.travel_details, 'Not Confirmed') AS travel_category,

    t.confirmation_status,

    COUNT(DISTINCT t.ticket_id)                 AS tickets

FROM [dbo].[vw_tickets_all]            t
JOIN [DWH].[DimEvent]                   ev  ON  t.event_id          = ev.CVEventID

WHERE
    t.is_reset_ghost        = 0
    AND LOWER(t.confirmation_status) IN ('confirmed', 'double confirmed')
    AND t.event_date        >= CAST(GETDATE() AS date)  -- upcoming events

GROUP BY
    ev.CVEventID,
    ev.EventName,
    ev.StartDate,
    ev.EventType,
    t.attendance_type,
    t.travel_details,
    t.confirmation_status

ORDER BY
    ev.StartDate,
    t.travel_details;
