-- ============================================================
-- vw_tickets_all
-- CC BI Semantic Model Redesign | BizOps | Sep 2026
--
-- Purpose: UNION ALL of live tickets + no-show reset ghost rows.
-- DirectLake cannot UNION two tables natively, so this view
-- serves as the single fact table for all ticket-level pages.
--
-- Grain: one row per ticket (live) or per deduplicated reset ghost.
--   is_reset_ghost = 0  →  from 10XHub.tickets
--   is_reset_ghost = 1  →  from 10XHub.ticket_no_show_resets
--
-- Ghost row dedup logic:
--   - Only rows with CONFIRMED or DOUBLE CONFIRMED status
--   - Deduplicated to latest reset per (event_id, root_ticket_id)
--   - Excluded if root_ticket_id still exists in tickets for same event
--
-- NULL columns on ghost rows (not available on resets table):
--   product_category_name, person_id, undecided_timestamp,
--   purchaser_name, travel_details
--   Use DimEvent.EventTypeName via relationship for product filtering
--   on ghost rows.
--
-- Change log:
--   Sep 2026  Added travel_details (tickets.travel_details).
--             No new joins; column is already on the source table —
--             adding it to the SELECT does not change the query plan.
--             NULL on ghost rows (ticket_no_show_resets has no travel data).
-- ============================================================

CREATE OR ALTER VIEW [dbo].[vw_tickets_all] AS

WITH tickets_live AS (
    SELECT
        CAST(t.ticket_id             AS varchar(100))  AS ticket_id,
        t.event_id,
        t.event_type_id,
        t.attendee_id,
        t.customer_id,
        CAST(t.product_category_name AS varchar(200))  AS product_category_name,
        CAST(t.product_name          AS varchar(200))  AS product_name,
        CAST(t.scheduled_event_name  AS varchar(200))  AS scheduled_event_name,
        CAST(t.ticket_type           AS varchar(100))  AS ticket_type,
        CAST(t.status                AS varchar(100))  AS status,
        CAST(t.confirmation_status   AS varchar(100))  AS confirmation_status,
        CAST(t.event_date            AS date)          AS event_date,
        t.ticket_price,
        CAST(t.confirmation_method   AS varchar(100))  AS confirmation_method,
        CAST(t.confirmed_date        AS date)          AS confirmed_date,
        CAST(t.double_confirm_type   AS varchar(100))  AS double_confirm_type,
        CAST(t.outreach_restriction  AS varchar(100))  AS outreach_restriction,
        t.person_id,
        CAST(t.sales_order_id        AS varchar(100))  AS sales_order_id,
        CAST(t.purchaser_email       AS varchar(200))  AS purchaser_email,
        CAST(t.purchaser_name        AS varchar(200))  AS purchaser_name,
        COALESCE(CAST(t.is_comped    AS int), 0)       AS is_comped,
        t.undecided_timestamp,
        CAST(t.attendance_type       AS varchar(50))   AS attendance_type,
        CAST(t.travel_details        AS varchar(8000)) AS travel_details,  -- added Sep 2026
        CAST(0                       AS bit)           AS is_reset_ghost
    FROM [10XHub].[tickets] t
),

tickets_reset_ghost AS (
    SELECT
        CAST(x.ticket_id             AS varchar(100))  AS ticket_id,
        x.event_id,
        x.event_type_id,
        x.attendee_id,
        x.customer_id,
        CAST(NULL                    AS varchar(200))  AS product_category_name,
        CAST(x.product_name          AS varchar(200))  AS product_name,
        CAST(x.scheduled_event_name  AS varchar(200))  AS scheduled_event_name,
        CAST(x.ticket_type           AS varchar(100))  AS ticket_type,
        CAST('no show'               AS varchar(100))  AS status,
        CAST(x.confirmation_status   AS varchar(100))  AS confirmation_status,
        CAST(x.event_date            AS date)          AS event_date,
        x.ticket_price,
        CAST(x.confirmation_method   AS varchar(100))  AS confirmation_method,
        CAST(x.confirmed_date        AS date)          AS confirmed_date,
        CAST(x.double_confirm_type   AS varchar(100))  AS double_confirm_type,
        CAST(x.outreach_restriction  AS varchar(100))  AS outreach_restriction,
        CAST(NULL                    AS int)           AS person_id,
        CAST(x.sales_order_id        AS varchar(100))  AS sales_order_id,
        CAST(x.purchaser_email       AS varchar(200))  AS purchaser_email,
        CAST(NULL                    AS varchar(200))  AS purchaser_name,
        COALESCE(CAST(x.is_comped    AS int), 0)       AS is_comped,
        CAST(NULL                    AS datetime2)     AS undecided_timestamp,
        CAST(x.attendance_type       AS varchar(50))   AS attendance_type,
        CAST(NULL                    AS varchar(8000)) AS travel_details,  -- not available on resets table
        CAST(1                       AS bit)           AS is_reset_ghost
    FROM (
        SELECT
            r.*,
            ROW_NUMBER() OVER (
                PARTITION BY r.event_id, CAST(r.root_ticket_id AS varchar(100))
                ORDER BY r.reset_at DESC
            ) AS rn
        FROM [10XHub].[ticket_no_show_resets] r
        WHERE UPPER(CAST(r.confirmation_status AS varchar(100))) IN ('CONFIRMED', 'DOUBLE CONFIRMED')
          AND NOT EXISTS (
              SELECT 1
              FROM [10XHub].[tickets] t2
              WHERE CAST(t2.ticket_id AS varchar(100)) = CAST(r.root_ticket_id AS varchar(100))
                AND t2.event_id = r.event_id
          )
    ) x
    WHERE x.rn = 1
)

SELECT * FROM tickets_live
UNION ALL
SELECT * FROM tickets_reset_ghost;
