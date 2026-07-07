-- Dead-code cleanup: my_inquiry_list had a single Flutter caller
-- (getMyInquiryList) with no UI usage; both removed.
drop function if exists public.my_inquiry_list();
