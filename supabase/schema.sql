-- Schema des analyses de parties EVA.
-- A executer une fois dans Supabase : tableau de bord -> SQL Editor -> Run.
--
-- Deux partis pris expliquent toute la structure.
--
-- 1. Le pseudo est decoupe en tag et nom. L'equipe peut etre renommee — BVS
--    devient peut-etre NT — et stocker « BVSxTibco » entier ferait de « NTxTibco »
--    un autre joueur : l'historique de chacun serait coupe en deux au changement
--    de nom. Les statistiques par joueur s'agregent donc sur `nom`, jamais sur le
--    pseudo complet. Le tag reste enregistre, mais pour l'histoire.
--
-- 2. « Notre equipe » est un booleen fige a l'import, pas une comparaison de tag.
--    Le tag en vigueur sert une seule fois, au moment ou la partie entre en base ;
--    ensuite plus rien ne depend de lui. Un renommage ne recalcule donc rien.
--    Meme raison pour le camp orange ou bleu, qui change d'une partie a l'autre :
--    il est releve, jamais suppose.

-- ---------------------------------------------------------------- identite
-- Nom et logo de l'equipe, partages par tout le monde. Une seule ligne.
create table if not exists identite (
  id         int primary key default 1 check (id = 1),
  nom        text not null default 'BVS',
  logo       text,                      -- image en data URL, ou null pour celui du site
  maj        timestamptz not null default now()
);
insert into identite (id, nom) values (1, 'BVS') on conflict (id) do nothing;

-- ------------------------------------------------------------------ parties
create table if not exists parties (
  id             uuid primary key default gen_random_uuid(),
  dt             date not null,
  h              text not null,          -- HH:MM, tel que saisi dans l'onglet Matchs
  carte          text,
  mode           text,
  resultat       text check (resultat in ('V', 'N', 'D')),
  notre_tag      text not null,          -- le tag du jour, pour l'histoire
  adverse_tag    text,
  pov            text,                   -- pseudo du joueur dont vient l'enregistrement
  images         int,
  morts          int,
  attribuees     int,
  brut           jsonb not null,         -- le fichier complet, en reserve
  cree           timestamptz not null default now(),
  -- Une partie est identifiee par sa date et son heure, comme dans le site.
  unique (dt, h)
);

-- ----------------------------------------------------------------- joueurs
create table if not exists joueurs_partie (
  partie_id      uuid not null references parties(id) on delete cascade,
  slot           int not null,           -- numero de casque, tire au sort par le maitre de jeu
  tag            text not null,
  nom            text not null,          -- sans le tag : c'est la clef de l'historique
  notre_equipe   boolean not null,
  camp           text check (camp in ('alliance', 'rebels')),
  kills          int,
  morts          int,
  assists        int,
  score          int,
  primary key (partie_id, slot)
);

-- ------------------------------------------------------------------- frags
create table if not exists frags (
  id             bigserial primary key,
  partie_id      uuid not null references parties(id) on delete cascade,
  image          int,
  instant        int,                    -- secondes restantes au chrono
  tueur_slot     int,                    -- null : mort sans tueur (chute, zone)
  victime_slot   int not null,
  allie          boolean not null default false
);

create index if not exists frags_partie on frags (partie_id);
create index if not exists joueurs_nom on joueurs_partie (nom);
create index if not exists parties_carte on parties (carte);
create index if not exists parties_adverse on parties (adverse_tag);

-- ------------------------------------------------------- vues d'agregation
-- Bilan par joueur, toutes parties confondues. Agrege sur `nom`, donc insensible
-- a un changement de tag.
create or replace view bilan_joueur as
select j.nom,
       bool_or(j.notre_equipe)                as chez_nous,
       count(*)                               as parties,
       sum(j.kills)                           as kills,
       sum(j.morts)                           as morts,
       sum(j.assists)                         as assists,
       round(sum(j.kills)::numeric
             / nullif(sum(j.morts), 0), 2)    as ratio
from joueurs_partie j
group by j.nom;

-- Bilan par carte, de notre point de vue.
create or replace view bilan_carte as
select p.carte,
       count(*)                                          as parties,
       count(*) filter (where p.resultat = 'V')          as victoires,
       sum(j.kills) filter (where j.notre_equipe)        as nos_kills,
       sum(j.morts) filter (where j.notre_equipe)        as nos_morts
from parties p
join joueurs_partie j on j.partie_id = p.id
group by p.carte;

-- Bilan par adversaire — la base du carnet.
create or replace view bilan_adversaire as
select p.adverse_tag,
       count(distinct p.id)                              as parties,
       count(distinct p.id) filter (where p.resultat = 'V') as victoires,
       sum(j.kills) filter (where j.notre_equipe)        as nos_kills,
       sum(j.morts) filter (where j.notre_equipe)        as nos_morts
from parties p
join joueurs_partie j on j.partie_id = p.id
group by p.adverse_tag;

-- -------------------------------------------------------------- protection
-- Ouvert en ecriture, choix assume : l'equipe est petite et le depot GitHub
-- garde une copie versionnee de chaque analyse, donc une base polluee se remet
-- d'aplomb. A resserrer le jour ou ca devient genant — remplacer `true` par
-- `auth.role() = 'authenticated'` dans les trois politiques d'ecriture suffit.
alter table identite       enable row level security;
alter table parties        enable row level security;
alter table joueurs_partie enable row level security;
alter table frags          enable row level security;

do $$
declare t text;
begin
  foreach t in array array['identite', 'parties', 'joueurs_partie', 'frags'] loop
    execute format('drop policy if exists lecture on %I', t);
    execute format('drop policy if exists ecriture on %I', t);
    execute format('create policy lecture  on %I for select using (true)', t);
    execute format('create policy ecriture on %I for all using (true) with check (true)', t);
  end loop;
end $$;

-- ============================================================================
-- 2. Parties collees depuis le jeu (27/07/2026)
-- ============================================================================
-- Deux tables distinctes de `parties` et `joueurs_partie`, volontairement.
-- `matchs` existe pour toute partie jouee, des qu'elle est collee. `parties` n'
-- existe que pour celles qu'on a pris le temps d'analyser en video. Les fusionner
-- obligerait a inventer des colonnes vides pour l'immense majorite des parties.
-- Elles se rejoignent sur (dt, h), la meme clef que partout ailleurs.

create table if not exists matchs (
  id            uuid primary key default gen_random_uuid(),
  dt            date not null,
  h             text not null,
  carte         text,
  mode          text,
  resultat      text check (resultat in ('V', 'N', 'D')),
  notre_tag     text,
  adverse_tag   text,
  -- La liste du jeu ne donne que les chiffres de celui qui colle, pas ceux de
  -- l equipe : on les garde tels quels et on note de qui ils viennent.
  colleur_nom   text,
  colleur_k     int,
  colleur_d     int,
  colleur_a     int,
  pct_nous      int,
  pct_eux       int,
  cree          timestamptz not null default now(),
  maj           timestamptz not null default now(),
  unique (dt, h)
);

-- Tableau des scores tel que le jeu l affiche. C est la reference pour les K/D/A :
-- il vient du jeu, quand joueurs_partie est deduit de la video.
create table if not exists scores_match (
  match_id      uuid not null references matchs(id) on delete cascade,
  tag           text not null,
  nom           text not null,
  notre_equipe  boolean not null,
  rang          int,
  mvp           boolean not null default false,
  kills         int,
  morts         int,
  assists       int,
  score         int,
  primary key (match_id, tag, nom)
);

create index if not exists matchs_carte    on matchs (carte);
create index if not exists matchs_adverse  on matchs (adverse_tag);
create index if not exists scores_nom      on scores_match (nom);

-- Ecarts entre le tableau du jeu et les chiffres tires de la video. On les
-- expose au lieu de les corriger : sur Atlantis les deux concordaient joueur par
-- joueur, et c est ce controle qui a valide toute la lecture des morts.
create or replace view ecarts_video as
select m.dt, m.h, m.carte, s.nom,
       s.kills as k_jeu, j.kills as k_video, s.kills - j.kills as ecart_k,
       s.morts as d_jeu, j.morts as d_video, s.morts - j.morts as ecart_d
from matchs m
join scores_match s  on s.match_id = m.id
join parties p       on p.dt = m.dt and p.h = m.h
join joueurs_partie j on j.partie_id = p.id and j.nom = s.nom
where s.kills is distinct from j.kills or s.morts is distinct from j.morts;

alter table matchs       enable row level security;
alter table scores_match enable row level security;
do $$
declare t text;
begin
  foreach t in array array['matchs', 'scores_match'] loop
    execute format('drop policy if exists lecture on %I', t);
    execute format('drop policy if exists ecriture on %I', t);
    execute format('create policy lecture  on %I for select using (true)', t);
    execute format('create policy ecriture on %I for all using (true) with check (true)', t);
  end loop;
end $$;
