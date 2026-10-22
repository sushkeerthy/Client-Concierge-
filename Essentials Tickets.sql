-- ============================================================
-- Essentials Tickets
-- One row per business with any Essentials ticket in the Hub, every status included.
-- No exclusions: the team filters on the columns (statuses, dates, 10X360, contact rules).
-- ============================================================

WITH cte_tickets AS (
    SELECT t.customer_id, t.ticket_id, t.transaction_id, t.product_name, t.ticket_type,
        LOWER(t.status) AS status, t.event_date, t.undecided_timestamp, t.registration_date,
        t.outreach_restriction, t.purchaser_name, t.purchaser_email, t.purchaser_phone,
        t.sales_order_id, tr.transaction_date
    FROM IT_Data_Gateway.[10XHub].[tickets] t
    LEFT JOIN IT_Data_Gateway.[10XHub].[transactions] tr ON tr.cv_transaction_id = t.transaction_id
    WHERE t.product_name LIKE '%Essential%'
      AND t.is_deleted = 0
),

cte_ticket_summary AS (
    SELECT
        customer_id,
        COUNT(DISTINCT ticket_id)                                         AS ticket_count,
        COUNT(DISTINCT CASE WHEN status IN ('open', 'undecided', 'undecided_at_sale', 'expired')
                            THEN ticket_id END)                           AS unscheduled_tickets,
        CAST(MIN(transaction_date) AS DATE)                               AS first_purchase_date,
        CAST(MAX(transaction_date) AS DATE)                               AS latest_purchase_date,
        CAST(MIN(CASE WHEN status IN ('scheduled', 'reserved') AND event_date >= CAST(GETDATE() AS DATE)
                      THEN event_date END) AS DATE)                       AS next_event_date,
        CAST(MAX(CASE WHEN status = 'attended' THEN event_date END) AS DATE) AS last_attended_date,
        MIN(COALESCE(undecided_timestamp, registration_date))             AS priority_date,
        CASE
            WHEN MAX(CASE WHEN outreach_restriction = 'Do Not Contact' THEN 1 ELSE 0 END) = 1 THEN 'Do Not Contact'
            WHEN MAX(CASE WHEN outreach_restriction = 'Do Not Blast'   THEN 1 ELSE 0 END) = 1 THEN 'Do Not Blast'
            WHEN MAX(CASE WHEN outreach_restriction = 'Do Not Call'    THEN 1 ELSE 0 END) = 1 THEN 'Do Not Call'
            ELSE NULL
        END                                                               AS outreach_restriction
    FROM cte_tickets
    GROUP BY customer_id
),

cte_tm_status_counts AS (
    SELECT
        customer_id,
        COUNT(CASE WHEN status = 'open'              THEN 1 END) AS TM_Open,
        COUNT(CASE WHEN status = 'undecided'         THEN 1 END) AS TM_Undecided,
        COUNT(CASE WHEN status = 'undecided_at_sale' THEN 1 END) AS TM_UndecidedAtSale,
        COUNT(CASE WHEN status = 'expired'           THEN 1 END) AS TM_Expired,
        COUNT(CASE WHEN status = 'assigned'          THEN 1 END) AS TM_Assigned,
        COUNT(CASE WHEN status = 'scheduled'         THEN 1 END) AS TM_Scheduled,
        COUNT(CASE WHEN status = 'reserved'          THEN 1 END) AS TM_Reserved,
        COUNT(CASE WHEN status = 'attended'          THEN 1 END) AS TM_Attended,
        COUNT(CASE WHEN status = 'no show'           THEN 1 END) AS TM_NoShow,
        COUNT(CASE WHEN status = 'cancelled'         THEN 1 END) AS TM_Cancelled
    FROM cte_tickets
    GROUP BY customer_id
),

cte_ticket_types AS (
    SELECT customer_id,
        STRING_AGG(product_name + ' x' + CAST(cnt AS VARCHAR(10)), ', ')
            WITHIN GROUP (ORDER BY product_name) AS ticket_types
    FROM (
        SELECT customer_id, product_name, COUNT(*) AS cnt
        FROM cte_tickets
        GROUP BY customer_id, product_name
    ) counted
    GROUP BY customer_id
),

cte_ticket_ids AS (
    SELECT customer_id,
        STRING_AGG(CAST(ticket_id AS VARCHAR(50)), ', ')
            WITHIN GROUP (ORDER BY ticket_id) AS ticket_ids
    FROM (
        SELECT DISTINCT customer_id, ticket_id
        FROM cte_tickets
    ) deduped
    GROUP BY customer_id
),

cte_sales_orders AS (
    SELECT customer_id,
        STRING_AGG(CAST(sales_order_id AS VARCHAR(50)), ', ')
            WITHIN GROUP (ORDER BY sales_order_id) AS sales_orders
    FROM (
        SELECT DISTINCT customer_id, sales_order_id
        FROM cte_tickets
        WHERE sales_order_id IS NOT NULL AND TRIM(sales_order_id) != ''
    ) deduped
    GROUP BY customer_id
),

cte_last_activity AS (
    SELECT t.customer_id,
        MAX(CASE WHEN t.product_name LIKE '%Essential%' THEN at2.blast_date END)       AS last_blast_this_product,
        MAX(CASE WHEN t.product_name LIKE '%Essential%' THEN at2.last_called_date END) AS last_called_this_product,
        MAX(at2.blast_date)                                                      AS last_blast_all_products,
        MAX(at2.last_called_date)                                                AS last_called_all_products
    FROM IT_Data_Gateway.[10XHub].[attendee_tickets] at2
    INNER JOIN IT_Data_Gateway.[10XHub].[tickets] t ON t.ticket_id = at2.ticket_id
    WHERE t.customer_id IN (SELECT customer_id FROM cte_tickets)
    GROUP BY t.customer_id
),

-- First paid 10X360 sale; FactGL.SourceCustomerID is the NetSuite entity ID, so match on CVCustomerID
cte_10x360_first_purchase AS (
    SELECT c.id AS customer_id,
        CAST(MIN(f.GLDate) AS DATE) AS first_10x360_purchase_date
    FROM IT_Data_Gateway.[DWH].[FactGL] f
    INNER JOIN IT_Data_Gateway.[DWH].[DimProduct] dp ON dp.CVProductID = f.CVProductID
    INNER JOIN IT_Data_Gateway.[10XHub].[customers] c ON c.cv_customer_id = f.CVCustomerID
    WHERE dp.ProductName LIKE '%10X360%'
      AND f.GLLineID != 0
      AND f.SalesOrderCashCollected > 0
    GROUP BY c.id
),

cte_contact_info AS (
    SELECT c.id AS customer_id,
        c.name AS business_name,
        c.cv_customer_id,
        dc.EliteStatusName           AS elite_status,
        dc.PRClientStatusName        AS pr_status,
        dc.SBUClientStatusName       AS sbu_status,
        dc.AnnualBusinessRevenueName AS abr,
        dc.VerticalName              AS vertical,
        dc.SubVerticalName           AS sub_vertical
    FROM IT_Data_Gateway.[10XHub].[customers] c
    LEFT JOIN IT_Data_Gateway.[DWH].[DimCustomer] dc ON dc.CVCustomerID = c.cv_customer_id
),

cte_all_contacts AS (
    SELECT customer_id, contact_name, contact_email, contact_phone, contact_source,
        ROW_NUMBER() OVER (
            PARTITION BY customer_id
            ORDER BY CASE contact_source
                WHEN 'business_owner' THEN 1
                WHEN 'attendee'       THEN 2
                WHEN 'purchaser'      THEN 3
                WHEN 'netsuite'       THEN 4
                ELSE 5
            END,
            contact_email, contact_name, contact_phone
        ) AS rn
    FROM (
        SELECT DISTINCT tk.customer_id,
            CASE WHEN tk.purchaser_name  IN ('FabricImport', '') OR tk.purchaser_name  IS NULL THEN tr.purchaser_name  ELSE tk.purchaser_name  END AS contact_name,
            CASE WHEN tk.purchaser_email IN ('FabricImport', '') OR tk.purchaser_email IS NULL THEN tr.purchaser_email ELSE tk.purchaser_email END AS contact_email,
            CASE WHEN tk.purchaser_phone IN ('FabricImport', '') OR tk.purchaser_phone IS NULL THEN tr.purchaser_phone ELSE tk.purchaser_phone END AS contact_phone,
            'purchaser' AS contact_source
        FROM cte_tickets tk
        LEFT JOIN IT_Data_Gateway.[10XHub].[transactions] tr
            ON tr.cv_transaction_id = tk.transaction_id
        WHERE (tk.purchaser_email NOT IN ('FabricImport', '') AND tk.purchaser_email IS NOT NULL)
           OR (tr.purchaser_email NOT IN ('FabricImport', '') AND tr.purchaser_email IS NOT NULL)

        UNION ALL

        SELECT DISTINCT a.customer_id,
            a.attendee_name, a.attendee_email, a.attendee_phone,
            'attendee' AS contact_source
        FROM IT_Data_Gateway.[10XHub].[attendees] a
        WHERE a.customer_id IN (SELECT customer_id FROM cte_tickets)
          AND a.attendee_email IS NOT NULL
          AND a.attendee_email NOT LIKE '%+placeholder@%'

        UNION ALL

        SELECT DISTINCT c.id,
            se.BusinessOwnerName COLLATE Latin1_General_100_CI_AS_KS_WS_SC_UTF8,
            se.Email             COLLATE Latin1_General_100_CI_AS_KS_WS_SC_UTF8,
            se.Phone             COLLATE Latin1_General_100_CI_AS_KS_WS_SC_UTF8,
            'netsuite' AS contact_source
        FROM IT_Data_Gateway.[10XHub].[customers] c
        INNER JOIN IT_Data_Gateway.[DWH].[DimCustomer] dc     ON dc.CVCustomerID = c.cv_customer_id
        INNER JOIN IT_Data_Gateway.[NetSuite].[silver_Entity] se ON se.EntityID = dc.NetSuiteID
        WHERE c.id IN (SELECT customer_id FROM cte_tickets)
          AND se.Email IS NOT NULL AND se.Email != ''

        UNION ALL

        SELECT DISTINCT c.id,
            dp.PersonName  COLLATE Latin1_General_100_CI_AS_KS_WS_SC_UTF8,
            dp.Email       COLLATE Latin1_General_100_CI_AS_KS_WS_SC_UTF8,
            dp.Phone       COLLATE Latin1_General_100_CI_AS_KS_WS_SC_UTF8,
            'business_owner' AS contact_source
        FROM IT_Data_Gateway.[10XHub].[customers] c
        INNER JOIN IT_Data_Gateway.[DWH].[DimCustomerContact] dcc ON dcc.Customer = c.cv_customer_id
        INNER JOIN IT_Data_Gateway.[DWH].[DimPerson]          dp  ON dp.CVPersonID = dcc.Person
        WHERE c.id IN (SELECT customer_id FROM cte_tickets)
          AND dcc.StaffTitleName = 'Owner'
          AND dcc.IsActiveName   = 'Yes'
          AND dp.Email IS NOT NULL AND dp.Email != ''
    ) all_contacts
),

-- Tickets for this product, grouped by status
cte_summary_this_product AS (
    SELECT
        customer_id,
        STRING_AGG(status_group + ': ' + products, ' | ') WITHIN GROUP (ORDER BY
            CASE status_group
                WHEN 'undecided'         THEN 1
                WHEN 'undecided_at_sale' THEN 2
                WHEN 'open'              THEN 3
                WHEN 'reserved'          THEN 4
                WHEN 'scheduled'         THEN 5
                WHEN 'assigned'          THEN 6
                WHEN 'attended'          THEN 7
                WHEN 'no show'           THEN 8
                WHEN 'expired'           THEN 9
                WHEN 'cancelled'         THEN 10
                ELSE 11
            END
        ) AS ticket_summary
    FROM (
        SELECT customer_id, status_group,
            STRING_AGG(product_name + ' x' + CAST(cnt AS VARCHAR(10)), ', ')
                WITHIN GROUP (ORDER BY product_name) AS products
        FROM (
            SELECT customer_id, LOWER(status) AS status_group, product_name, COUNT(*) AS cnt
            FROM IT_Data_Gateway.[10XHub].[tickets]
            WHERE is_deleted = 0
              AND customer_id IN (SELECT customer_id FROM cte_tickets)
              AND product_name LIKE '%Essential%'
            GROUP BY customer_id, LOWER(status), product_name
        ) t
        GROUP BY customer_id, status_group
    ) sg
    GROUP BY customer_id
),

-- Every ticket the business holds, all products
cte_summary_all_products AS (
    SELECT
        customer_id,
        STRING_AGG(status_group + ': ' + products, ' | ') WITHIN GROUP (ORDER BY
            CASE status_group
                WHEN 'undecided'         THEN 1
                WHEN 'undecided_at_sale' THEN 2
                WHEN 'open'              THEN 3
                WHEN 'reserved'          THEN 4
                WHEN 'scheduled'         THEN 5
                WHEN 'assigned'          THEN 6
                WHEN 'attended'          THEN 7
                WHEN 'no show'           THEN 8
                WHEN 'expired'           THEN 9
                WHEN 'cancelled'         THEN 10
                ELSE 11
            END
        ) AS ticket_summary
    FROM (
        SELECT customer_id, status_group,
            STRING_AGG(product_name + ' x' + CAST(cnt AS VARCHAR(10)), ', ')
                WITHIN GROUP (ORDER BY product_name) AS products
        FROM (
            SELECT customer_id, LOWER(status) AS status_group, product_name, COUNT(*) AS cnt
            FROM IT_Data_Gateway.[10XHub].[tickets]
            WHERE is_deleted = 0
              AND customer_id IN (SELECT customer_id FROM cte_tickets)
            GROUP BY customer_id, LOWER(status), product_name
        ) t
        GROUP BY customer_id, status_group
    ) sg
    GROUP BY customer_id
)

SELECT
    ci.business_name,
    ci.cv_customer_id,

    -- Filters
    CASE
        WHEN tm.TM_Open + tm.TM_Undecided + tm.TM_UndecidedAtSale + tm.TM_Expired = 0 THEN 'No Open/Undecided/Expired'
        WHEN tm.TM_Open + tm.TM_Undecided + tm.TM_UndecidedAtSale = 0                 THEN 'Expired Only'
        WHEN tm.TM_Expired = 0                                                        THEN 'Open/Undecided Only'
        ELSE 'Open/Undecided + Expired'
    END AS ticket_status_group,
    ts.unscheduled_tickets,
    ts.ticket_count,
    ts.first_purchase_date,
    ts.latest_purchase_date,
    DATEDIFF(DAY, ts.latest_purchase_date, CAST(GETDATE() AS DATE)) AS days_since_latest_purchase,
    ts.next_event_date,
    ts.last_attended_date,
    CASE WHEN fx.first_10x360_purchase_date IS NOT NULL THEN 'Yes' ELSE 'No' END AS is_10x360_customer,
    fx.first_10x360_purchase_date,
    ci.elite_status,
    ci.pr_status,
    ci.sbu_status,
    ci.abr,
    ci.vertical,
    ci.sub_vertical,
    ts.outreach_restriction,
    la.last_blast_this_product,
    la.last_called_this_product,
    DATEDIFF(DAY,
        CASE WHEN la.last_called_this_product IS NULL OR la.last_blast_this_product > la.last_called_this_product
             THEN la.last_blast_this_product ELSE la.last_called_this_product END,
        GETDATE()) AS days_since_last_touch_this_product,
    la.last_blast_all_products,
    la.last_called_all_products,
    DATEDIFF(DAY,
        CASE WHEN la.last_called_all_products IS NULL OR la.last_blast_all_products > la.last_called_all_products
             THEN la.last_blast_all_products ELSE la.last_called_all_products END,
        GETDATE()) AS days_since_last_touch_all_products,

    -- Contact (one per business)
    ac.contact_name,
    ac.contact_email,
    ac.contact_phone,
    ac.contact_source,

    -- Ticket counts by status, this product
    tm.TM_Open, tm.TM_Undecided, tm.TM_UndecidedAtSale, tm.TM_Expired, tm.TM_Assigned,
    tm.TM_Scheduled, tm.TM_Reserved, tm.TM_Attended, tm.TM_NoShow, tm.TM_Cancelled,

    -- Detail
    ts.priority_date,
    DATEDIFF(DAY, ts.priority_date, GETDATE()) AS days_in_queue,
    tt.ticket_types,
    ti.ticket_ids,
    so.sales_orders,
    sp.ticket_summary AS ticket_summary_this_product,
    sa.ticket_summary AS ticket_summary_all_products,
    GETDATE() AS list_generated_at
FROM cte_all_contacts ac
INNER JOIN cte_contact_info          ci ON ci.customer_id = ac.customer_id
INNER JOIN cte_ticket_summary        ts ON ts.customer_id = ac.customer_id
INNER JOIN cte_tm_status_counts      tm ON tm.customer_id = ac.customer_id
LEFT JOIN  cte_ticket_types          tt ON tt.customer_id = ac.customer_id
LEFT JOIN  cte_ticket_ids            ti ON ti.customer_id = ac.customer_id
LEFT JOIN  cte_sales_orders          so ON so.customer_id = ac.customer_id
LEFT JOIN  cte_last_activity         la ON la.customer_id = ac.customer_id
LEFT JOIN  cte_10x360_first_purchase fx ON fx.customer_id = ac.customer_id
LEFT JOIN  cte_summary_this_product  sp ON sp.customer_id = ac.customer_id
LEFT JOIN  cte_summary_all_products  sa ON sa.customer_id = ac.customer_id
WHERE ac.rn = 1
ORDER BY ts.priority_date ASC;
