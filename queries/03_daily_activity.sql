-- ============================================================
-- 03_daily_activity.sql
-- CC BI Semantic Model Redesign | BizOps | Sep 2026
--
-- Page:    Daily Activity
-- Answers: "What did the team do today and this week?"
--           - How many confirmations by day
--           - Breakdown by confirmation method (touch source)
--           - Breakdown by event type (Elite Edge filter for Q2)
--
-- Source: vw_confirmation_actions (activity log)
--
-- confirmation_touch_source: how the action was logged
--   e.g. Manual, Dialer, System — the "method" the rep used
--
-- Grain: one row per date / event / touch source / status.
--   tickets_confirmed uses DISTINCT to avoid double-counting
--   a ticket touched multiple times in the same day.
--
-- ✅ VALIDATED (Sep 2026) — daily ticket counts:
--   Raw history confirms daily confirmation counts for last 14 days.
--   DISTINCT working correctly — Sep 11 CV-337 shows 14 distinct tickets
--   vs 16 total actions (2 tickets touched twice that day, absorbed by DISTINCT).
--
-- ✅ confirmation_touch_source confirmed values (from view definition):
--   'Status Update'      – history action = 'Confirmation status updated'
--   'Date Update'        – history action = 'Confirmation date updated'
--   'Pre-History Direct' – synthesized from tickets.confirmed_by (~128 tickets,
--                          confirmed before history tracking was enabled)
--   NOTE: Date Update is often the dominant source. Sep 17 example:
--     Date Update = 57 tickets, Status Update = 10. Missing this source
--     understates daily totals significantly.
--
-- ✅ week_offset / week_label confirmed (from view definition):
--   Week anchor: 2024-01-01 (Monday). Week boundary = Monday.
--   Timezone: Arizona (UTC-7, no DST) via 'US Mountain Standard Time'.
--   week_offset: 0 = this week, -1 = last week, +1 = next week.
--   week_label: 'This Week', 'Last Week', 'N Weeks Ago', 'N Weeks Ahead'.
-- ============================================================

SELECT
    ca.action_date_az                           AS action_date,
    ca.week_label,
    ca.week_offset,       -- 0 = current week, -1 = last week
    ev.EventName                                AS event_name,
    ev.EventType                                AS event_type,   -- filter on 'Elite Edge' for Q2
    CAST(ev.StartDate AS date)                  AS event_date,
    ca.confirmation_status,
    ca.confirmation_touch_source,               -- Manual / Dialer / System / etc.

    -- Distinct tickets that had a confirmation action on this date
    COUNT(DISTINCT ca.ticket_id)                AS tickets_confirmed,

    -- Total actions taken (one ticket can have multiple actions in a day)
    COUNT(*)                                    AS total_actions

FROM [dbo].[vw_confirmation_actions]    ca
JOIN [dbo].[vw_tickets_all]             t   ON  ca.ticket_id        = t.ticket_id
                                            AND t.is_reset_ghost    = 0
JOIN [DWH].[DimEvent]                   ev  ON  t.event_id          = ev.CVEventID

WHERE
    ca.is_rep_action        = 1     -- human rep actions only

GROUP BY
    ca.action_date_az,
    ca.week_label,
    ca.week_offset,
    ev.EventName,
    ev.EventType,
    ev.StartDate,
    ca.confirmation_status,
    ca.confirmation_touch_source

ORDER BY
    ca.action_date_az       DESC,
    ev.EventType,
    tickets_confirmed       DESC;
