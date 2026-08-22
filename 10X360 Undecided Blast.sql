-- ============================================================
-- 10X360 Undecided Blast — OPTIMIZED v3
-- Changes from v2:
--   [NEW] Added business_owner source from DWH.DimCustomerContact
--         (DimPerson where StaffTitleName = 'Owner' AND IsActiveName = 'Yes')
--   [NEW] business_owner bumped to priority 1 in contact source ranking
--   [FIX] ROW_NUMBER partition changed from
--         PARTITION BY customer_id, TRIM(LOWER(contact_email))
--         to PARTITION BY customer_id
--         (one best contact per customer, not one per unique email)
-- ============================================================
 
WITH cte_10x360_ud AS (
    SELECT t.customer_id, t.ticket_id, t.ticket_number, t.transaction_id,
        t.product_name, t.ticket_type, t.status, t.undecided_timestamp,
        t.outreach_restriction, t.registration_date, t.jarvis_nurture_enrolled_at,
        t.purchaser_name, t.purchaser_email, t.purchaser_phone
    FROM [10XHub].[tickets] t
    WHERE t.product_name LIKE '%10X360%'
      AND t.status IN ('undecided', 'open')
),
 
cte_scheduled_customers AS (
    SELECT DISTINCT customer_id
    FROM [10XHub].[tickets]
    WHERE product_name LIKE '%10X360%'
      AND status IN ('scheduled', 'reserved')
      AND event_date > GETDATE()
),
 
cte_new_buyers AS (
    SELECT customer_id FROM (
        SELECT f.SourceCustomerID AS customer_id,
               MIN(f.GLDate) AS first_purchase_date
        FROM [DWH].[FactGL] f
        INNER JOIN [DWH].[DimProduct] dp ON dp.CVProductID = f.CVProductID
        WHERE dp.ProductName LIKE '%10X360%'
          AND f.GLLineID != 0
          AND f.SalesOrderCashCollected > 0
        GROUP BY f.SourceCustomerID
    ) first_purchases
    WHERE first_purchase_date >= DATEADD(DAY, -60, GETDATE())
),
 
cte_refund_customers AS (
    SELECT DISTINCT f.SourceCustomerID AS customer_id
    FROM [DWH].[FactGL] f
    INNER JOIN [DWH].[DimProduct] dp ON dp.CVProductID = f.CVProductID
    LEFT JOIN [NetSuite].[silver_Transaction] st
        ON st.TransactionID = CAST(f.GLID AS BIGINT)
    WHERE dp.ProductName LIKE '%10X360%'
      AND f.IsGLPosting = 1
      AND (
          f.GLStatus IN ('Cash Refund : Undefined', 'Customer Refund : Undefined',
                         'CCard Refund : Undefined', 'Credit Memo : Fully Applied')
          OR (f.GLStatus = 'Credit Memo : Open' AND st.IsClosed = 1)
      )
),
 
cte_elite_status AS (
    SELECT SourceCustomerID AS customer_id, Elite AS elite_tier
    FROM (
        SELECT SourceCustomerID, Elite,
               ROW_NUMBER() OVER (PARTITION BY SourceCustomerID ORDER BY GLDate DESC) AS rn
        FROM [DWH].[FactGL]
        WHERE Elite IS NOT NULL
    ) ranked
    WHERE rn = 1
),
 
cte_ticket_summary AS (
    SELECT
        customer_id,
        COUNT(DISTINCT ticket_id)                             AS ticket_count,
        MIN(COALESCE(undecided_timestamp, registration_date)) AS priority_date,
        CASE
            WHEN MAX(CASE WHEN outreach_restriction = 'Do Not Contact' THEN 1 ELSE 0 END) = 1 THEN 'Do Not Contact'
            WHEN MAX(CASE WHEN outreach_restriction = 'Do Not Blast'   THEN 1 ELSE 0 END) = 1 THEN 'Do Not Blast'
            WHEN MAX(CASE WHEN outreach_restriction = 'Do Not Call'    THEN 1 ELSE 0 END) = 1 THEN 'Do Not Call'
            ELSE NULL
        END AS outreach_restriction
    FROM cte_10x360_ud
    GROUP BY customer_id
),
 
cte_ticket_types AS (
    SELECT customer_id,
        STRING_AGG(product_name + ' x' + CAST(cnt AS VARCHAR(10)), ', ')
            WITHIN GROUP (ORDER BY product_name) AS ticket_types
    FROM (
        SELECT customer_id, product_name, COUNT(*) AS cnt
        FROM cte_10x360_ud
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
        FROM cte_10x360_ud
    ) deduped
    GROUP BY customer_id
),
 
-- [OPT] Scoped to 10X360 customers only
cte_last_activity AS (
    SELECT t.customer_id,
        MAX(at2.blast_date)       AS last_blast_date,
        MAX(at2.last_called_date) AS last_called_date
    FROM [10XHub].[attendee_tickets] at2
    INNER JOIN [10XHub].[tickets] t ON t.ticket_id = at2.ticket_id
    WHERE t.customer_id IN (SELECT customer_id FROM cte_10x360_ud)
    GROUP BY t.customer_id
),
 
cte_contact_info AS (
    SELECT c.id AS customer_id,
        c.name AS business_name,
        c.cv_customer_id,
        CASE COALESCE(es.elite_tier, c.status)
            WHEN '3'        THEN 'ELITE125'
            WHEN '4'        THEN 'ELITE250'
            WHEN 'ELITE125' THEN 'ELITE125'
            WHEN 'ELITE250' THEN 'ELITE250'
            ELSE NULL
        END AS elite_status,
        dc.PRClientStatusName  AS pr_status,
        dc.SBUClientStatusName AS sbu_status
    FROM [10XHub].[customers] c
    LEFT JOIN cte_elite_status es ON es.customer_id = c.id
    LEFT JOIN [DWH].[DimCustomer] dc ON dc.CVCustomerID = c.cv_customer_id
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
            END
        ) AS rn
    FROM (
        SELECT DISTINCT ee.customer_id,
            CASE WHEN ee.purchaser_name  IN ('FabricImport', '') OR ee.purchaser_name  IS NULL THEN tr.purchaser_name  ELSE ee.purchaser_name  END AS contact_name,
            CASE WHEN ee.purchaser_email IN ('FabricImport', '') OR ee.purchaser_email IS NULL THEN tr.purchaser_email ELSE ee.purchaser_email END AS contact_email,
            CASE WHEN ee.purchaser_phone IN ('FabricImport', '') OR ee.purchaser_phone IS NULL THEN tr.purchaser_phone ELSE ee.purchaser_phone END AS contact_phone,
            'purchaser' AS contact_source
        FROM cte_10x360_ud ee
        LEFT JOIN [10XHub].[transactions] tr
            ON tr.cv_transaction_id = ee.transaction_id
        WHERE (ee.purchaser_email NOT IN ('FabricImport', '') AND ee.purchaser_email IS NOT NULL)
           OR (tr.purchaser_email  NOT IN ('FabricImport', '') AND tr.purchaser_email  IS NOT NULL)
 
        UNION ALL
 
        SELECT DISTINCT a.customer_id,
            a.attendee_name, a.attendee_email, a.attendee_phone, 'attendee'
        FROM [10XHub].[attendees] a
        INNER JOIN cte_10x360_ud ee ON ee.customer_id = a.customer_id
        WHERE a.attendee_email IS NOT NULL
          AND a.attendee_email NOT LIKE '%+placeholder@%'
 
        UNION ALL
 
        SELECT DISTINCT ee.customer_id,
            se.BusinessOwnerName COLLATE Latin1_General_100_CI_AS_KS_WS_SC_UTF8,
            se.Email             COLLATE Latin1_General_100_CI_AS_KS_WS_SC_UTF8,
            se.Phone             COLLATE Latin1_General_100_CI_AS_KS_WS_SC_UTF8,
            'netsuite'
        FROM cte_10x360_ud ee
        INNER JOIN [10XHub].[customers] c     ON c.id = ee.customer_id
        INNER JOIN [DWH].[DimCustomer] dc     ON dc.CVCustomerID = c.cv_customer_id
        INNER JOIN [NetSuite].[silver_Entity] se ON se.EntityID = dc.NetSuiteID
        WHERE se.Email IS NOT NULL AND se.Email != ''
 
        UNION ALL
 
        -- NEW: DWH business owner — highest priority
        SELECT DISTINCT ee.customer_id,
            dp.PersonName  COLLATE Latin1_General_100_CI_AS_KS_WS_SC_UTF8,
            dp.Email       COLLATE Latin1_General_100_CI_AS_KS_WS_SC_UTF8,
            dp.Phone       COLLATE Latin1_General_100_CI_AS_KS_WS_SC_UTF8,
            'business_owner'
        FROM cte_10x360_ud ee
        INNER JOIN [10XHub].[customers] c         ON c.id = ee.customer_id
        INNER JOIN [DWH].[DimCustomerContact] dcc ON dcc.Customer = c.cv_customer_id
        INNER JOIN [DWH].[DimPerson]          dp  ON dp.CVPersonID = dcc.Person
        WHERE dcc.StaffTitleName = 'Owner'
          AND dcc.IsActiveName   = 'Yes'
          AND dp.Email IS NOT NULL AND dp.Email != ''
    ) all_contacts
)
 
SELECT
    ci.business_name, ci.cv_customer_id,
    ac.contact_name, ac.contact_email, ac.contact_phone, ac.contact_source,
    ts.ticket_count, tt.ticket_types, ti.ticket_ids,
    ts.priority_date,
    DATEDIFF(DAY, ts.priority_date, GETDATE()) AS days_in_queue,
    ts.outreach_restriction,
    la.last_blast_date, la.last_called_date,
    ci.elite_status, ci.pr_status, ci.sbu_status,
    GETDATE() AS list_generated_at
FROM cte_all_contacts ac
INNER JOIN cte_contact_info   ci ON ci.customer_id = ac.customer_id
INNER JOIN cte_ticket_summary ts ON ts.customer_id = ac.customer_id
LEFT JOIN  cte_ticket_types   tt ON tt.customer_id = ac.customer_id
LEFT JOIN  cte_ticket_ids     ti ON ti.customer_id = ac.customer_id
LEFT JOIN  cte_last_activity  la ON la.customer_id = ac.customer_id
LEFT JOIN  cte_scheduled_customers sc ON sc.customer_id = ac.customer_id
LEFT JOIN  cte_new_buyers          nb ON nb.customer_id = ac.customer_id
LEFT JOIN  cte_refund_customers    rc ON rc.customer_id = ac.customer_id
WHERE ac.rn = 1
  AND sc.customer_id IS NULL
  AND nb.customer_id IS NULL
  AND rc.customer_id IS NULL
ORDER BY ts.priority_date ASC;