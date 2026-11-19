-- =====================================================================
--  KROK 6: godziny kursu wg kategorii, historia dokupionych godzin,
--          własne godziny pracy instruktora
--  Supabase → SQL Editor → Ctrl+A → wklej → Run. Uruchom tylko raz.
-- =====================================================================

-- 1. Godziny kursu: puste = wg kategorii (tabela szkoły / rozporządzenie)
alter table public.kursanci alter column godziny_kurs drop not null;
alter table public.kursanci alter column godziny_kurs drop default;
update public.kursanci set godziny_kurs = null where godziny_kurs = 30;   -- 30 było tylko wartością domyślną

-- własne godziny kursu szkoły dla kategorii (puste = jak w rozporządzeniu)
alter table public.szkoly
  add column if not exists godziny_kategorii jsonb not null default '{}'::jsonb;

-- 2. Historia dokupionych godzin
create table if not exists public.dokupione (
  id          uuid primary key default gen_random_uuid(),
  szkola_id   uuid not null references public.szkoly(id) on delete cascade,
  kursant_id  uuid not null references public.kursanci(id) on delete cascade,
  godziny     numeric not null check (godziny > 0),
  dzien       date not null default current_date,
  uwagi       text,
  utworzono   timestamptz not null default now()
);
create index if not exists dokupione_kursant on public.dokupione (kursant_id);

-- dotychczasowe sumy przenosimy jako jeden wpis
insert into public.dokupione (szkola_id, kursant_id, godziny, uwagi)
select szkola_id, id, godziny_dokupione, 'przeniesione z wcześniejszej sumy'
from public.kursanci
where godziny_dokupione > 0
  and not exists (select 1 from public.dokupione d where d.kursant_id = kursanci.id);

-- suma w kursanci.godziny_dokupione liczy się sama (widzą ją też instruktorzy)
create or replace function public.przelicz_dokupione()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_k uuid := coalesce(new.kursant_id, old.kursant_id);
begin
  update public.kursanci
     set godziny_dokupione = coalesce((select sum(godziny) from public.dokupione where kursant_id = v_k), 0)
   where id = v_k;
  if tg_op = 'UPDATE' and old.kursant_id <> new.kursant_id then
    update public.kursanci
       set godziny_dokupione = coalesce((select sum(godziny) from public.dokupione where kursant_id = old.kursant_id), 0)
     where id = old.kursant_id;
  end if;
  return null;
end $$;
revoke execute on function public.przelicz_dokupione() from public, anon;

drop trigger if exists dokupione_suma on public.dokupione;
create trigger dokupione_suma
  after insert or update or delete on public.dokupione
  for each row execute function public.przelicz_dokupione();

alter table public.dokupione enable row level security;

create policy "dokupione: biuro odczyt" on public.dokupione
  for select to authenticated
  using ((select public.czy_biuro()) and szkola_id = (select public.moja_szkola()));
create policy "dokupione: biuro dodaje" on public.dokupione
  for insert to authenticated
  with check ((select public.czy_biuro()) and szkola_id = (select public.moja_szkola())
              and exists (select 1 from public.kursanci k where k.id = kursant_id and k.szkola_id = (select public.moja_szkola())));
create policy "dokupione: biuro usuwa" on public.dokupione
  for delete to authenticated
  using ((select public.czy_biuro()) and szkola_id = (select public.moja_szkola()));

revoke all on public.dokupione from anon;
grant select, insert, delete on public.dokupione to authenticated;

-- 3. Własne godziny pracy instruktora (puste = jak ustawienia szkoły)
alter table public.instruktorzy
  add column if not exists godz_od text,
  add column if not exists godz_do text;

-- Gotowe. Powinien pojawić się komunikat "Success. No rows returned".
