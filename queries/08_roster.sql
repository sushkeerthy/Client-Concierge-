-- ============================================================
-- 08_roster.sql
-- CC BI Semantic Model Redesign | BizOps | Sep 2026
--
-- Page:    Roster (Drillthrough / Detail)
-- Answers: "Give me everything about a specific event's tickets."
--
-- Source: vw_tickets_all + attendees + customers + DimEvent
--   Returns one row per ticket with all fields needed for the
--   CC team to look up any attendee, check confirmation status,
--   see travel details, and identify the purchaser.
--
-- In Power BI this page is a drillthrough target — the user
-- right-clicks an event on the Event Overview page and drills
-- through here. The event filter is applied automatically.
--
-- ✅ VALIDATED (Sep 2026):
--   FIXED: ev.City → ev.CityName, ev.Venue → ev.VenueName
--     City and Venue on DimEvent are numeric lookup IDs; CityName and VenueName
--     are the human-readable text columns (confirmed from live DimEvent data).
--   attendees columns confirmed: attendee_id, attendee_name, attendee_email,
--     attendee_phone, first_name, last_name, dietary_restrictions all exist ✅
--   customers columns confirmed: name, vertical, SBU, PR, EliteEdge all exist ✅
--     vertical is a numeric code — may need a lookup for display.
--
-- Ghost rows (is_reset_ghost = 1) are INCLUDED here intentionally
--   so the CC team can see no-show resets alongside live tickets.
--   The is_reset_ghost column surfaces the distinction.
-- ============================================================

SELECT
    ev.EventName                                AS event_name,
    CAST(ev.StartDate AS date)                  AS event_date,
    ev.EventType                                AS event_type,
    ev.CityName                                 AS event_city,   -- City column is a numeric ID; CityName is the readable text
    ev.VenueName                                AS venue,        -- Venue column is a numeric ID; VenueName is the readable text

    t.ticket_id,
    t.status                                    AS ticket_status,
    t.confirmation_status,
    t.confirmation_method,
    t.ticket_type,
    t.attendance_type,
    t.travel_details,
    t.outreach_restriction,
    t.ticket_price,
    t.is_comped,
    t.is_reset_ghost,                           -- flag so CC can see resets

    a.attendee_name,
    a.attendee_email,
    a.attendee_phone,
    a.first_name,
    a.last_name,
    a.dietary_restrictions,

    t.purchaser_name,
    t.purchaser_email,

    c.name                                      AS company_name,
    c.vertical,
    c.SBU,
    c.PR,
    c.EliteEdge

FROM [dbo].[vw_tickets_all]            t
JOIN [DWH].[DimEvent]                   ev  ON  t.event_id          = ev.CVEventID
JOIN [10XHub].[attendees]               a   ON  t.attendee_id       = a.attendee_id
JOIN [10XHub].[customers]               c   ON  t.customer_id       = c.id

-- No WHERE clause: Power BI drillthrough provides the event filter.
-- If running standalone for a specific event, add:
-- WHERE t.event_id = '<event_id_here>'

ORDER BY
    t.is_reset_ghost,       -- live tickets first, ghost rows at bottom
    c.name,
    a.attendee_name;
