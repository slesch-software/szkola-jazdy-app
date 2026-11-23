-- =====================================================================
--  KROK 32: kolejność instruktorów (każdy dla siebie), wynik egzaminu
--           (biuro i instruktor), prośba o opinię Google
--  Supabase → SQL Editor → Ctrl+A → wklej → Run. Można uruchomić ponownie.
-- =====================================================================

-- ---------- 1. KOLEJNOŚĆ INSTRUKTORÓW – zapisana przy koncie osoby ----------
alter table public.profile add column if not exists kolejnosc_instr jsonb;   -- ["id1","id2",...]

create or replace function public.zapisz_kolejnosc_instr(p_kolejnosc jsonb)
returns void language plpgsql volatile security definer set search_path = '' as $$
begin
  if auth.uid() is null then raise exception 'BRAK_UPRAWNIEN'; end if;
  if p_kolejnosc is not null and jsonb_typeof(p_kolejnosc) <> 'array' then raise exception 'ZLE_DANE'; end if;
  update public.profile set kolejnosc_instr = p_kolejnosc where id = auth.uid();
end $$;
revoke execute on function public.zapisz_kolejnosc_instr(jsonb) from public, anon;
grant  execute on function public.zapisz_kolejnosc_instr(jsonb) to authenticated;

-- ---------- 2. WYNIK EGZAMINU ----------
alter table public.jazdy
  add column if not exists wynik       text check (wynik is null or wynik in ('zdal', 'nie')),
  add column if not exists wynik_kiedy timestamptz;

-- biuro albo instruktor tej jazdy wpisuje / zmienia / kasuje wynik (p_wynik: 'zdal', 'nie' albo null)
create or replace function public.ustaw_wynik_egzaminu(p_jazda uuid, p_wynik text)
returns void language plpgsql volatile security definer set search_path = '' as $$
declare j public.jazdy%rowtype; v_dzien date;
begin
  if p_wynik is not null and p_wynik not in ('zdal', 'nie') then raise exception 'ZLE_DANE'; end if;
  select * into j from public.jazdy where id = p_jazda for update;
  if not found or j.szkola_id is distinct from public.moja_szkola() then raise exception 'BRAK_UPRAWNIEN'; end if;
  if not (public.czy_biuro() or j.instruktor_id = public.moj_instruktor()) then raise exception 'BRAK_UPRAWNIEN'; end if;
  if j.rodzaj <> 'egzamin' or j.kursant_id is null then raise exception 'TO_NIE_EGZAMIN'; end if;
  if j.poczatek > now() + interval '15 minutes' then raise exception 'EGZAMIN_JESZCZE_NIE'; end if;
  update public.jazdy set wynik = p_wynik, wynik_kiedy = case when p_wynik is null then null else now() end where id = j.id;
  v_dzien := (j.poczatek at time zone 'Europe/Warsaw')::date;
  if p_wynik = 'zdal' then
    update public.kursanci set zdal = v_dzien where id = j.kursant_id;
  else
    -- cofnięcie „zdał” z tego egzaminu: data zdania znika, chyba że inny egzamin też jest zdany
    update public.kursanci k set zdal = (
        select max((x.poczatek at time zone 'Europe/Warsaw')::date) from public.jazdy x
         where x.kursant_id = k.id and x.rodzaj = 'egzamin' and x.wynik = 'zdal')
     where k.id = j.kursant_id and k.zdal = v_dzien;
  end if;
end $$;
revoke execute on function public.ustaw_wynik_egzaminu(uuid, text) from public, anon;
grant  execute on function public.ustaw_wynik_egzaminu(uuid, text) to authenticated;

-- lista kursantów: dochodzi wynik egzaminu (zmienia się typ wyniku, więc najpierw drop)
drop function if exists public.jazdy_kursantow(uuid[]);
create function public.jazdy_kursantow(p_ids uuid[])
returns table (kursant_id uuid, poczatek timestamptz, koniec timestamptz, rodzaj text, nie_liczy boolean,
               potwierdzona boolean, godz_egzaminu time, wynik text, instruktor_id uuid)
language sql stable security definer set search_path = '' as $$
  select j.kursant_id, j.poczatek, j.koniec, j.rodzaj, j.nie_liczy, j.potwierdzona, j.godz_egzaminu, j.wynik, j.instruktor_id
    from public.jazdy j
   where j.szkola_id = public.moja_szkola() and j.kursant_id = any(p_ids)
$$;
revoke execute on function public.jazdy_kursantow(uuid[]) from public, anon;
grant  execute on function public.jazdy_kursantow(uuid[]) to authenticated;

-- ---------- 3. PROŚBA O OPINIĘ GOOGLE ----------
alter table public.szkoly
  add column if not exists opinia_link  text,
  add column if not exists opinia_tresc text;
alter table public.kursanci add column if not exists opinia_wyslana date;

-- Gotowe. Powinien pojawić się komunikat "Success. No rows returned".
