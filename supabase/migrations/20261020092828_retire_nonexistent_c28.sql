-- C-28 does not exist physically. Preserve history and prevent new assignments.
DO $$ DECLARE sid uuid; BEGIN
 SELECT id INTO sid FROM public.parking_spots WHERE code='C-28' AND zone='C' FOR UPDATE;
 IF sid IS NULL THEN RETURN; END IF;
 IF EXISTS(SELECT 1 FROM public.monthly_subscribers WHERE parking_spot_id=sid AND active)
 OR EXISTS(SELECT 1 FROM public.rotation_sessions WHERE spot_id=sid AND status='inside')
 OR EXISTS(SELECT 1 FROM public.parking_sessions WHERE spot_id=sid AND status='inside')
 OR EXISTS(SELECT 1 FROM public.reservations WHERE assigned_spot_id=sid AND finished_at IS NULL AND status NOT IN('completed','cancelled','expired')) THEN
 RAISE EXCEPTION 'C-28 still has an active assignment'; END IF;
 UPDATE public.parking_spots SET active=false,updated_at=now() WHERE id=sid;
END $$;