-- ============================================================
-- vw_confirmation_actions
-- CC BI Semantic Model Redesign | BizOps | Sep 2026
--
-- Purpose: One row per confirmation action (rep × ticket × status × day).
-- Provides the calculated columns that cannot come from table relationships:
--   - AZ timezone conversion
--   - Week labels relative to TODAY()
--   - is_first_travel_action
--   - is_last_confirmer
--   - ticket_outcome (Attended / No Show / etc.)
--
-- Relationships wired in the semantic model (NOT denormalized here):
--   ticket_id    → vw_tickets_all.ticket_id
--   user_email   → DimEmployee.Email
--
-- Includes pre-history fix: 128 tickets confirmed before history tracking
-- was enabled. Synthesized from tickets.confirmed_by / double_confirmed_by
-- where no matching history record exists.
--
-- Week anchor: 2024-01-01 (Monday). Week boundary = Monday.
-- Timezone: Arizona (UTC-7, no DST) via AT TIME ZONE conversion.
-- ============================================================

CREATE OR ALTER VIEW [dbo].[vw_confirmation_actions] AS

WITH

-- -------------------------------------------------------
-- STATUS UPDATE TOUCHES (primary source)
-- -------------------------------------------------------
status_touch AS (
    SELECT
        CAST(h.changed_by AS varchar(200))    AS user_email,
        CAST(h.ticket_id  AS varchar(100))    AS ticket_id,
        CASE UPPER(CAST(h.new_value AS varchar(100)))
            WHEN 'CONFIRMED'        THEN 'Confirmed'
            WHEN 'DOUBLE CONFIRMED' THEN 'Double Confirmed'
            ELSE CAST(h.new_value AS varchar(100))
        END                                   AS confirmation_status,
        CAST(
            h.changed_at AT TIME ZONE 'UTC'
                         AT TIME ZONE 'US Mountain Standard Time'
        AS date)                              AS action_date_az,
        h.changed_at AT TIME ZONE 'UTC'
                     AT TIME ZONE 'US Mountain Standard Time'
                                              AS action_ts_az,
        CASE WHEN CAST(h.changed_by AS varchar(200))
                  IN ('System', 'bulk-import') THEN 0 ELSE 1
        END                                   AS is_rep_action,
        CAST('Status Update' AS varchar(20))  AS confirmation_touch_source
    FROM [10XHub].[history] h
    WHERE CAST(h.action AS varchar(200)) = 'Confirmation status updated'
      AND UPPER(CAST(h.new_value AS varchar(200))) IN ('CONFIRMED', 'DOUBLE CONFIRMED')
),

-- -------------------------------------------------------
-- DATE UPDATE TOUCHES (re-confirmation via date change)
-- -------------------------------------------------------
date_touch AS (
    SELECT
        CAST(h.changed_by AS varchar(200))    AS user_email,
        CAST(h.ticket_id  AS varchar(100))    AS ticket_id,
        CAST('Confirmed' AS varchar(20))      AS confirmation_status,
        CAST(
            h.changed_at AT TIME ZONE 'UTC'
                         AT TIME ZONE 'US Mountain Standard Time'
        AS date)                              AS action_date_az,
        h.changed_at AT TIME ZONE 'UTC'
                     AT TIME ZONE 'US Mountain Standard Time'
                                              AS action_ts_az,
        CASE WHEN CAST(h.changed_by AS varchar(200))
                  IN ('System', 'bulk-import') THEN 0 ELSE 1
        END                                   AS is_rep_action,
        CAST('Date Update' AS varchar(20))    AS confirmation_touch_source
    FROM [10XHub].[history] h
    WHERE CAST(h.action AS varchar(200)) = 'Confirmation date updated'
),

-- -------------------------------------------------------
-- PRE-HISTORY TOUCHES
-- Tickets confirmed before history tracking was enabled.
-- Synthesized from tickets.confirmed_by / double_confirmed_by.
-- -------------------------------------------------------
pre_history_acts AS (
    SELECT
        CAST(t.confirmed_by       AS varchar(200)) AS user_email,
        CAST(t.ticket_id          AS varchar(100)) AS ticket_id,
        CAST('Confirmed'          AS varchar(20))  AS confirmation_status,
        CAST(t.confirmed_date     AS date)         AS action_date_az,
        CAST(t.confirmed_date     AS datetime2)    AS action_ts_az,
        1                                          AS is_rep_action,
        CAST('Pre-History Direct' AS varchar(20))  AS confirmation_touch_source
    FROM [10XHub].[tickets] t
    WHERE t.confirmed_by IS NOT NULL
      AND t.confirmed_by NOT IN ('System', 'bulk-import')
      AND NOT EXISTS (
          SELECT 1 FROM [10XHub].[history] h
          WHERE CAST(h.ticket_id AS varchar(100)) = CAST(t.ticket_id AS varchar(100))
            AND CAST(h.action    AS varchar(200)) = 'Confirmation status updated'
            AND UPPER(CAST(h.new_value AS varchar(200))) IN ('CONFIRMED', 'DOUBLE CONFIRMED')
      )

    UNION ALL

    SELECT
        CAST(t.double_confirmed_by   AS varchar(200)) AS user_email,
        CAST(t.ticket_id             AS varchar(100)) AS ticket_id,
        CAST('Double Confirmed'      AS varchar(20))  AS confirmation_status,
        CAST(t.double_confirmed_date AS date)         AS action_date_az,
        CAST(t.double_confirmed_date AS datetime2)    AS action_ts_az,
        1                                             AS is_rep_action,
        CAST('Pre-History Direct'    AS varchar(20))  AS confirmation_touch_source
    FROM [10XHub].[tickets] t
    WHERE t.double_confirmed_by IS NOT NULL
      AND t.double_confirmed_by NOT IN ('System', 'bulk-import')
      AND NOT EXISTS (
          SELECT 1 FROM [10XHub].[history] h
          WHERE CAST(h.ticket_id AS varchar(100)) = CAST(t.ticket_id AS varchar(100))
            AND CAST(h.action    AS varchar(200)) = 'Confirmation status updated'
            AND UPPER(CAST(h.new_value AS varchar(200))) IN ('CONFIRMED', 'DOUBLE CONFIRMED')
      )
),

-- -------------------------------------------------------
-- DEDUP: one row per (user_email × ticket_id × status × day)
-- -------------------------------------------------------
base_combined AS (
    SELECT * FROM status_touch
    UNION ALL
    SELECT * FROM date_touch
    UNION ALL
    SELECT * FROM pre_history_acts
),

unique_acts AS (
    SELECT
        user_email,
        ticket_id,
        confirmation_status,
        action_date_az,
        action_ts_az,
        is_rep_action,
        confirmation_touch_source
    FROM (
        SELECT *,
            ROW_NUMBER() OVER (
                PARTITION BY user_email, ticket_id,
                             UPPER(confirmation_status), action_date_az
                ORDER BY action_ts_az
            ) AS rn
        FROM base_combined
    ) x
    WHERE rn = 1
),

-- -------------------------------------------------------
-- FIRST TRAVEL ACTION FLAG
-- Earliest confirmation date per ticket where travel is confirmed
-- (double_confirm_type IS NOT NULL = Hotel/Flight booked)
-- -------------------------------------------------------
first_travel AS (
    SELECT
        CAST(h.ticket_id AS varchar(100)) AS ticket_id,
        MIN(CAST(
            h.changed_at AT TIME ZONE 'UTC'
                         AT TIME ZONE 'US Mountain Standard Time'
        AS date))                         AS first_travel_date
    FROM [10XHub].[history] h
    INNER JOIN [10XHub].[tickets] t
        ON CAST(t.ticket_id AS varchar(100)) = CAST(h.ticket_id AS varchar(100))
    WHERE CAST(h.action    AS varchar(200)) = 'Confirmation status updated'
      AND UPPER(CAST(h.new_value AS varchar(200))) IN ('CONFIRMED', 'DOUBLE CONFIRMED')
      AND CAST(h.changed_by AS varchar(200)) NOT IN ('System', 'bulk-import')
      AND t.double_confirm_type IS NOT NULL
    GROUP BY CAST(h.ticket_id AS varchar(100))
),

-- -------------------------------------------------------
-- NO-SHOW RESETS: original event context
-- -------------------------------------------------------
no_show_resets AS (
    SELECT
        CAST(r.root_ticket_id AS varchar(100))            AS root_ticket_id,
        MIN(CAST(r.event_date AS date))                   AS original_event_date,
        MIN(CAST(r.scheduled_event_name AS varchar(200))) AS original_event_name
    FROM [10XHub].[ticket_no_show_resets] r
    WHERE r.root_ticket_id IS NOT NULL
    GROUP BY CAST(r.root_ticket_id AS varchar(100))
),

-- -------------------------------------------------------
-- CORE: week math + enrichment
-- -------------------------------------------------------
core AS (
    SELECT
        ua.user_email,
        ua.ticket_id,
        ua.confirmation_status,
        ua.action_date_az,
        CAST(ua.action_ts_az AS datetime2)       AS action_time_az,
        ua.is_rep_action,
        ua.confirmation_touch_source,

        -- Week start (Monday anchor: 2024-01-01)
        DATEADD(DAY,
            -((DATEDIFF(DAY, '2024-01-01', ua.action_date_az)) % 7),
            ua.action_date_az
        )                                        AS week_start_date,

        YEAR(DATEADD(DAY,
            -((DATEDIFF(DAY, '2024-01-01', ua.action_date_az)) % 7),
            ua.action_date_az
        ))                                       AS week_year,

        DATEPART(ISO_WEEK, DATEADD(DAY,
            -((DATEDIFF(DAY, '2024-01-01', ua.action_date_az)) % 7),
            ua.action_date_az
        ))                                       AS week_number,

        -- Week offset relative to today (0 = this week, -1 = last week)
        DATEDIFF(DAY,
            DATEADD(DAY,
                -((DATEDIFF(DAY, '2024-01-01', CAST(GETDATE() AS DATE))) % 7),
                CAST(GETDATE() AS DATE)
            ),
            DATEADD(DAY,
                -((DATEDIFF(DAY, '2024-01-01', ua.action_date_az)) % 7),
                ua.action_date_az
            )
        ) / 7                                    AS week_offset,

        -- is_first_travel_action
        CASE
            WHEN t.double_confirm_type IS NOT NULL
             AND ua.action_date_az = ft.first_travel_date
            THEN 1 ELSE 0
        END                                      AS is_first_travel_action,

        -- ticket_outcome for attendance conversion
        CASE
            WHEN LOWER(CAST(t.status AS varchar(100))) = 'attended'  THEN 'Attended'
            WHEN nsr.root_ticket_id IS NOT NULL                      THEN 'No Show (Reset)'
            WHEN LOWER(CAST(t.status AS varchar(100))) = 'no show'   THEN 'No Show'
            WHEN LOWER(CAST(t.status AS varchar(100))) = 'cancelled' THEN 'Cancelled'
            ELSE 'Upcoming'
        END                                      AS ticket_outcome,
        CASE WHEN nsr.root_ticket_id IS NOT NULL THEN 1 ELSE 0 END
                                                 AS is_no_show_reset,

        -- Original event context for reset tickets
        COALESCE(nsr.original_event_date, CAST(t.event_date AS date))
                                                 AS original_event_date,
        COALESCE(
            nsr.original_event_name,
            CAST(t.scheduled_event_name AS varchar(200))
        )                                        AS original_event_name

    FROM unique_acts ua
    LEFT JOIN [10XHub].[tickets] t
        ON CAST(t.ticket_id AS varchar(100)) = ua.ticket_id
    LEFT JOIN first_travel ft
        ON ft.ticket_id = ua.ticket_id
    LEFT JOIN no_show_resets nsr
        ON nsr.root_ticket_id = ua.ticket_id
)

-- -------------------------------------------------------
-- FINAL: add week_label + window-function columns
-- -------------------------------------------------------
SELECT
    *,

    CASE
        WHEN week_offset =  0 THEN 'This Week'
        WHEN week_offset = -1 THEN 'Last Week'
        WHEN week_offset =  1 THEN 'Next Week'
        WHEN week_offset <  0 THEN CONCAT(ABS(week_offset), ' Weeks Ago')
        ELSE                       CONCAT(week_offset, ' Weeks Ahead')
    END                                          AS week_label,

    -- Confirmation rank per ticket × status (1 = first touch)
    ROW_NUMBER() OVER (
        PARTITION BY ticket_id, confirmation_status
        ORDER BY action_time_az
    )                                            AS ticket_confirmation_rank,

    -- Total touches per ticket × status
    COUNT(*) OVER (
        PARTITION BY ticket_id, confirmation_status
    )                                            AS ticket_status_action_count,

    -- Total touches per ticket across all statuses
    COUNT(*) OVER (
        PARTITION BY ticket_id
    )                                            AS ticket_total_action_count,

    -- Last confirmer flag: 1 = most recent rep for this ticket × status
    -- Use in DAX conversion measures to avoid double-counting
    CASE WHEN
        ROW_NUMBER() OVER (
            PARTITION BY ticket_id, confirmation_status
            ORDER BY action_time_az DESC
        ) = 1
    THEN 1 ELSE 0 END                            AS is_last_confirmer

FROM core;
