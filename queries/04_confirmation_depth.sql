-- ============================================================
-- 04_confirmation_depth.sql
-- CC BI Semantic Model Redesign | BizOps | Sep 2026
--
-- Page:    Confirmation Depth
-- Answers: "How are confirmations distributed across tickets and
--           companies?"
--           Q4 — per ticket vs per company
--           Q6 — how many double confirmed?
--
-- ✅ VALIDATED (Sep 2026):
--   [ticket-manager].[customers] confirmed: id, name, vertical, SBU, PR, EliteEdge all exist.
--   NOTE: vertical column contains numeric codes (e.g. "5"), not display names.
--   If the report needs readable vertical names, a lookup join is required.
--   is_last_confirmer + ticket_status_action_count logic validated via vw_confirmation_actions.
--
-- Two sections:
--   Section A — Per-ticket: how many times was each ticket confirmed?
--               Uses is_last_confirmer = 1 to get one row per ticket
--               showing the final confirmation state and touch count.
--
--   Section B — Per-company: how many confirmed tickets per client?
--               Uses vw_tickets_all current state.
-- ============================================================


-- ============================================================
-- Section A: Per-ticket confirmation depth
-- How many tickets were confirmed once, twice, 3+ times?
-- ============================================================

SELECT
    ev.EventName                                AS event_name,
    CAST(ev.StartDate AS date)                  AS event_date,
    ev.EventType                                AS event_type,
    ca.confirmation_status,
    ca.ticket_status_action_count               AS times_confirmed_to_this_status,

    COUNT(DISTINCT ca.ticket_id)                AS ticket_count

FROM [dbo].[vw_confirmation_actions]    ca
JOIN [dbo].[vw_tickets_all]             t   ON  ca.ticket_id        = t.ticket_id
                                            AND t.is_reset_ghost    = 0
JOIN [DWH].[DimEvent]                   ev  ON  t.event_id          = ev.CVEventID

WHERE
    ca.is_rep_action        = 1
    AND ca.is_last_confirmer = 1    -- one row per ticket: the final confirmer
    AND LOWER(ca.confirmation_status) IN ('confirmed', 'double confirmed')

GROUP BY
    ev.CVEventID,
    ev.EventName,
    ev.StartDate,
    ev.EventType,
    ca.confirmation_status,
    ca.ticket_status_action_count

ORDER BY
    ev.StartDate            DESC,
    ca.confirmation_status,
    ca.ticket_status_action_count;


-- ============================================================
-- Section B: Per-company confirmed ticket count
-- How many clients have confirmations and how many tickets each?
-- ============================================================

SELECT
    ev.EventName                                AS event_name,
    CAST(ev.StartDate AS date)                  AS event_date,
    c.name                                      AS company_name,
    c.vertical,

    COUNT(DISTINCT t.ticket_id)                 AS total_tickets,

    COUNT(DISTINCT CASE
        WHEN LOWER(t.confirmation_status) = 'confirmed'
        THEN t.ticket_id
    END)                                        AS confirmed_tickets,

    COUNT(DISTINCT CASE
        WHEN LOWER(t.confirmation_status) = 'double confirmed'
        THEN t.ticket_id
    END)                                        AS double_confirmed_tickets,

    COUNT(DISTINCT CASE
        WHEN LOWER(t.confirmation_status) IN ('confirmed', 'double confirmed')
        THEN t.ticket_id
    END)                                        AS total_confirmed_tickets

FROM [dbo].[vw_tickets_all]            t
JOIN [DWH].[DimEvent]                   ev  ON  t.event_id          = ev.CVEventID
JOIN [10XHub].[customers]               c   ON  t.customer_id       = c.id

WHERE
    t.is_reset_ghost        = 0

GROUP BY
    ev.CVEventID,
    ev.EventName,
    ev.StartDate,
    c.id,
    c.name,
    c.vertical

HAVING
    COUNT(DISTINCT CASE
        WHEN LOWER(t.confirmation_status) IN ('confirmed', 'double confirmed')
        THEN t.ticket_id
    END) > 0    -- only show companies with at least one confirmation

ORDER BY
    ev.StartDate            DESC,
    total_confirmed_tickets DESC;
