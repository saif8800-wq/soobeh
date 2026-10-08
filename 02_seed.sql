-- ============================================================
-- SOOBEH KIOSK — 02_seed.sql (data demo)
-- Jalankan SEKALI selepas 01_schema.sql. Reset demo = 01 + 02.
-- ============================================================

-- Buang akaun demo lama (namespace @soobeh.app milik sistem ini sahaja)
delete from auth.users where email like '%@soobeh.app';

do $$ declare
  v_prev_start date := (date_trunc('month', now()) - interval '1 month')::date;
  v_prev_end   date := (date_trunc('month', now()) - interval '1 day')::date;
  v_cur_start  date := date_trunc('month', now())::date;
  v_cur_end    date := (date_trunc('month', now()) + interval '1 month' - interval '1 day')::date;
  v_next_start date := (date_trunc('month', now()) + interval '1 month')::date;
  v_next_end   date := (date_trunc('month', now()) + interval '2 month' - interval '1 day')::date;
  v_yesterday  date := now()::date - 1;
  v_ali uuid; v_minah uuid; v_chong uuid; v_sarah uuid; v_aida uuid;
  v_swap_entry uuid; v_sw1 uuid; v_sw1d date; v_sw2 uuid; v_sw2d date; v_sw3 uuid;
begin
  -- ===== 8 AKAUN DEMO (PIN = contoh sahaja) =====
  perform public.admin_create_user('ali01','Ali bin Abu','012-345 6789','staff','monthly','1234');
  perform public.admin_create_user('minah02','Minah binti Hassan','013-222 3344','staff','biweekly','1111');
  perform public.admin_create_user('chong03','Chong Wei Lun','017-888 9900','staff','biweekly','2222');
  perform public.admin_create_user('sarah04','Sarah Tan','019-112 2334','staff','monthly','3333');
  perform public.admin_create_user('aida05','Aida Rahman','011-223 4455','manager','monthly','9999');
  perform public.admin_create_user('boyan06','Boyan Karim','012-998 7766','manager','monthly','8888');
  perform public.admin_create_user('ravi07','Ravi Chandran','014-556 7788','manager','monthly','7777');
  perform public.admin_create_user('boss00','Encik Soobeh (Pengusaha)','010-123 4567','admin','monthly','0000');

  select id into v_ali   from public.profiles where username='ali01';
  select id into v_minah from public.profiles where username='minah02';
  select id into v_chong from public.profiles where username='chong03';
  select id into v_sarah from public.profiles where username='sarah04';
  select id into v_aida  from public.profiles where username='aida05';

  insert into public.settings (id) values (1) on conflict (id) do update set updated_at = now();

  -- ===== JADUAL RASMI: bulan lepas + bulan semasa (kiosk buka 7 hari, 2 syif) =====
  insert into public.schedule (date, shift, staff_id)
  select r.d, r.shift,
    case
      when r.isodow in (6,7) and r.shift = (case r.isodow when 6 then 'morning' else 'evening' end) then v_chong
      else (array[v_ali, v_minah, v_sarah])[1 + (r.rn % 3)]
    end
  from (
    select d, shift, row_number() over (order by d, shift) as rn, extract(isodow from d)::int as isodow
    from (select generate_series(v_prev_start, v_cur_end, interval '1 day')::date as d) days
    cross join (values ('morning'), ('evening')) as s(shift)
  ) r;

  insert into public.bookings (staff_id, date, shift, status)
  select staff_id, date, shift, 'approved' from public.schedule where date between v_prev_start and v_cur_end;

  insert into public.published (month_key, published_by)
  select to_char(d, 'YYYY-MM'), v_aida from (values (v_prev_start), (v_cur_start)) as t(d);

  -- ===== JUALAN DEMO: bulan lepas penuh + bulan semasa hingga semalam =====
  insert into public.sales (date, shift, amount, entered_by)
  select s.date, s.shift,
    round((case when extract(isodow from s.date) in (6,7)
                then 250 + random()*310 else 170 + random()*250 end)::numeric, 2),
    v_aida
  from public.schedule s
  where s.date >= v_prev_start and s.date <= v_yesterday;

  -- Rekod tidak hadir (Chong) — demo kesan kehadiran & gaji
  update public.schedule set no_show = true
  where id = (select id from public.schedule where staff_id = v_chong
              and date >= v_prev_start + 4 and date <= v_prev_end order by date limit 1);

  -- Pertukaran LAMPAU (diluluskan): Minah serah kepada Sarah
  select id into v_swap_entry from public.schedule
  where staff_id = v_minah and shift = 'evening' and date >= v_prev_start + 17
  order by date limit 1;
  if v_swap_entry is not null then
    update public.schedule set staff_id = v_sarah where id = v_swap_entry;
    insert into public.swaps (entry_id, from_staff, to_staff, reason, status, t_peer, t_mgr, decided_by)
    values (v_swap_entry, v_minah, v_sarah, 'Ada urusan keluarga pada tarikh tersebut.', 'approved',
            now() - interval '19 days', now() - interval '19 days', v_aida);
  end if;

  -- Pertukaran SEMASA: Chong → Sarah (menunggu persetujuan rakan)
  select id, date into v_sw1, v_sw1d from public.schedule
  where staff_id = v_chong and date >= now()::date order by date limit 1;
  if v_sw1 is not null then
    insert into public.swaps (entry_id, from_staff, to_staff, reason, status)
    values (v_sw1, v_chong, v_sarah, 'Balik kampung hujung minggu tersebut.', 'pending_peer');
    insert into public.notifications (user_id, msg, read, created_at)
    values (v_sarah, '🔄 Chong Wei Lun memohon pertukaran syif kepada anda: ' || to_char(v_sw1d,'DD/MM/YYYY') || '. Semak tab "Tukar Syif".', false, now() - interval '2 hours');
  end if;

  -- Pertukaran SEMASA dua hala: Sarah ⇄ Ali (menunggu manager)
  select id, date into v_sw2, v_sw2d from public.schedule
  where staff_id = v_sarah and shift = 'evening' and date >= now()::date order by date limit 1;
  select id into v_sw3 from public.schedule
  where staff_id = v_ali and shift = 'morning' and date >= now()::date order by date limit 1;
  if v_sw2 is not null and v_sw3 is not null then
    insert into public.swaps (entry_id, exchange_entry_id, from_staff, to_staff, reason, status, t_peer)
    values (v_sw2, v_sw3, v_sarah, v_ali, 'Tukar dua hala — lebih selesa untuk pengangkutan saya.', 'pending_manager', now() - interval '1 hour');
    insert into public.notifications (user_id, msg, read, created_at)
    values (v_ali, '🔄 Sarah Tan memohon tukar syif dua hala dengan anda. Semak tab "Tukar Syif".', true, now() - interval '2 hours');
  end if;

  -- ===== BULAN DEPAN: campuran menunggu / disahkan / tidak dipilih =====
  insert into public.bookings (staff_id, date, shift, status)
  select
    case when r.isodow in (6,7) and r.rn % 2 = 0 then v_chong
         else (array[v_ali, v_minah, v_sarah])[1 + (r.rn % 3)] end,
    r.d, r.shift,
    case when r.rn % 3 = 0 then 'approved' when r.rn % 7 = 0 then 'rejected' else 'pending' end
  from (
    select d, shift, row_number() over (order by d, shift) as rn, extract(isodow from d)::int as isodow
    from (select generate_series(v_next_start, v_next_end, interval '1 day')::date as d) days
    cross join (values ('morning'), ('evening')) as s(shift)
  ) r;
  -- Tambahan "staff ke-3" pada slot awal — demo had kapasiti
  insert into public.bookings (staff_id, date, shift, status)
  values (v_ali, v_next_start, 'morning', 'pending'), (v_minah, v_next_start, 'morning', 'pending');

  -- ===== SLIP GAJI DEMO (bulan lepas) =====
  insert into public.payslips (staff_id, start, "end", cycle, payload, created_by, created_at)
  values
  (v_ali, v_prev_start, v_prev_end, 'monthly',
   jsonb_build_object(
     'staffName','Ali bin Abu','username','ali01','cycle','monthly',
     'start',to_char(v_prev_start,'YYYY-MM-DD'),'end',to_char(v_prev_end,'YYYY-MM-DD'),
     'shiftCount',17,'hours',102,'basePay',816.00,'highHours',24,'extraPay',24.00,
     'salesSum',3420.50,'perfSum',3420.50,'perfAmt',100.00,'attAmt',30.00,'attWhy','',
     'includeBonus',true,'typh',10.00,'typhNo',3,'typhCountBefore',2,'total',980.00,
     'shifts','[]'::jsonb,'t',(extract(epoch from now() - interval '12 days')*1000)::bigint,'by','aida05'),
   v_aida, now() - interval '12 days'),
  (v_minah, v_prev_start, v_prev_start + 13, 'biweekly',
   jsonb_build_object(
     'staffName','Minah binti Hassan','username','minah02','cycle','biweekly',
     'start',to_char(v_prev_start,'YYYY-MM-DD'),'end',to_char(v_prev_start + 13,'YYYY-MM-DD'),
     'shiftCount',8,'hours',48,'basePay',384.00,'highHours',12,'extraPay',12.00,
     'salesSum',1610.00,'perfSum',3215.00,'perfAmt',0,'attAmt',0,
     'attWhy','Bonus dinilai bulanan — masuk pada slip kitaran kedua',
     'includeBonus',false,'typh',10.00,'typhNo',1,'typhCountBefore',0,'total',406.00,
     'shifts','[]'::jsonb,'t',(extract(epoch from now() - interval '12 days')*1000)::bigint,'by','aida05'),
   v_aida, now() - interval '12 days'),
  (v_minah, v_prev_start + 14, v_prev_end, 'biweekly',
   jsonb_build_object(
     'staffName','Minah binti Hassan','username','minah02','cycle','biweekly',
     'start',to_char(v_prev_start + 14,'YYYY-MM-DD'),'end',to_char(v_prev_end,'YYYY-MM-DD'),
     'shiftCount',9,'hours',54,'basePay',432.00,'highHours',18,'extraPay',18.00,
     'salesSum',1605.00,'perfSum',3215.00,'perfAmt',100.00,'attAmt',0,
     'attWhy','Terdapat rekod pertukaran syif',
     'includeBonus',true,'typh',10.00,'typhNo',2,'typhCountBefore',1,'total',560.00,
     'shifts','[]'::jsonb,'t',(extract(epoch from now() - interval '12 days')*1000)::bigint,'by','aida05'),
   v_aida, now() - interval '12 days');

  update public.profiles set typhoid_count = 3 where username = 'ali01';
  update public.profiles set typhoid_count = 2 where username = 'minah02';
  update public.profiles set typhoid_count = 3 where username = 'chong03';

  -- ===== NOTIFIKASI DEMO =====
  insert into public.notifications (user_id, msg, read, created_at)
  select p.id, '📅 Jadual rasmi ' || to_char(v_cur_start, 'YYYY-MM') || ' telah dikeluarkan. Sila semak "Jadual Saya".', true, now() - interval '26 days'
  from public.profiles p where p.role = 'staff';
  insert into public.notifications (user_id, msg, read, created_at)
  select p.id, '🧾 Slip gaji bulan lepas sedia untuk dilihat & dimuat turun.', false, now() - interval '12 days'
  from public.profiles p where p.username in ('ali01','minah02');
  insert into public.notifications (user_id, msg, read, created_at)
  select p.id, '📋 Terdapat permohonan tempahan syif untuk bulan depan yang menunggu pengesahan anda.', false, now() - interval '3 hours'
  from public.profiles p where p.role in ('manager','admin');
  insert into public.notifications (user_id, msg, read, created_at)
  select p.id, '🔄 Terdapat permohonan pertukaran syif yang menunggu kelulusan anda.', false, now() - interval '3 hours'
  from public.profiles p where p.role in ('manager','admin');

  insert into public.audit (action, detail) values ('system_seed','Data demo dimuatkan (staff, jadual, jualan, slip gaji, pertukaran)');
end $$;