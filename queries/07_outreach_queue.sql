-- ============================================================
-- 07_outreach_queue.sql
-- CC BI Semantic Model Redesign | BizOps | Sep 2026
--
-- Page:    Outreach Queue
-- Answers: "Who can't be contacted and why?"
--
-- Source: vw_tickets_all (current state)
--   Returns ticket-level rows where outreach_restriction is set,
--   for upcoming events only.
--   This is an operational page — the CC team uses it to know
--   which tickets to skip when working their confirmation queue.
--
-- outreach_restriction values to validate with CC team:
--   'DNC', 'Restricted', NULL / 'None' (no restriction)
--
-- Grain: one row per ticket (detail-level for the CC team).
-- ============================================================

SELECT
    ev.EventName                                AS event_name,
    CAST(ev.StartDate AS date)                  AS event_date,
    ev.EventType                                AS event_type,
    t.outreach_restriction,
    t.ticket_id,
    t.confirmation_status,
    t.status                                    AS ticket_status,
    a.attendee_name,
    a.attendee_email,
    a.attendee_phone,
    t.purchaser_name,
    t.purchaser_email,
    c.name                                      AS company_name,
    c.vertical

FROM [dbo].[vw_tickets_all]            t
JOIN [DWH].[DimEvent]                   ev  ON  t.event_id          = ev.CVEventID
JOIN [10XHub].[attendees]               a   ON  t.attendee_id       = a.attendee_id
JOIN [10XHub].[customers]               c   ON  t.customer_id       = c.id

WHERE
    t.is_reset_ghost        = 0
    AND t.outreach_restriction IS NOT NULL
    AND LOWER(t.outreach_restriction) NOT IN ('none', '')   -- exclude non-restricted
    AND t.event_date        >= CAST(GETDATE() AS date)      -- upcoming events only

ORDER BY
    ev.StartDate,
    t.outreach_restriction,
    c.name,
    a.attendee_name;
