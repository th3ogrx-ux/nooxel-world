-- À coller dans Supabase → SQL Editor → Run
create table if not exists public.items (
  id bigint generated always as identity primary key,
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  title text not null check (char_length(title) between 1 and 200),
  created_at timestamptz not null default now()
);

alter table public.items enable row level security;

create policy "items_select_own" on public.items for select using (auth.uid() = user_id);
create policy "items_insert_own" on public.items for insert with check (auth.uid() = user_id);
create policy "items_delete_own" on public.items for delete using (auth.uid() = user_id);
