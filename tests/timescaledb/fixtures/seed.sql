CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;

CREATE ROLE hasura_readonly LOGIN PASSWORD 'readonly-pass';
CREATE ROLE plugin_inventory LOGIN PASSWORD 'plugin-pass';

CREATE SCHEMA hdb_catalog;
CREATE TABLE hdb_catalog.hdb_metadata (id int PRIMARY KEY, metadata json NOT NULL, resource_version int NOT NULL DEFAULT 1);
INSERT INTO hdb_catalog.hdb_metadata VALUES (1, '{"version": 3, "sources": [{"name": "default"}]}', 42);

CREATE SCHEMA plugin_inventory AUTHORIZATION plugin_inventory;
CREATE TABLE plugin_inventory.items (id bigserial PRIMARY KEY, steam_id bigint NOT NULL, label text NOT NULL);
INSERT INTO plugin_inventory.items (steam_id, label) SELECT 76561198000000000 + g, 'Skin ' || g FROM generate_series(1, 250) g;
ALTER TABLE plugin_inventory.items OWNER TO plugin_inventory;

CREATE TABLE public.players (steam_id bigint PRIMARY KEY, name text NOT NULL, country text);
CREATE INDEX players_name_idx ON public.players (name);
INSERT INTO public.players (steam_id, name, country)
SELECT 76561197960000000 + g,
       (ARRAY['Émile','émile','Emile','emile','Zoë','zoe','ZOE','Ångström','angstrom','apple','Apple','APPLE','Straße','strasse','Ça va','ca va','naïve','NAÏVE','Øystein','oystein','Łukasz','lukasz','Ñandú','nandu','日本','東京','Ärger','arger','_under','-dash','Zürich','zurich','ìtalia','Italia','résumé','resume','RÉSUMÉ'])[1 + (g % 37)] || ' ' || g,
       (ARRAY['FR','DE','SE','NO','PL','ES','JP','IT','US'])[1 + (g % 9)]
FROM generate_series(1, 900) g;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO hasura_readonly;

CREATE OR REPLACE FUNCTION public.app_key_hint() RETURNS text LANGUAGE sql STABLE AS $$ SELECT left(current_setting('fivestack.app_key', true), 4) $$;

CREATE TABLE public.player_kills (
    id uuid NOT NULL DEFAULT gen_random_uuid(),
    "time" timestamptz NOT NULL,
    match_id uuid NOT NULL,
    match_map_id uuid NOT NULL,
    attacker_steam_id bigint NOT NULL,
    attacker_name text NOT NULL,
    weapon text NOT NULL,
    headshot boolean NOT NULL DEFAULT false
);
ALTER TABLE public.player_kills ADD PRIMARY KEY (id, "time", match_id, match_map_id);
INSERT INTO public.player_kills ("time", match_id, match_map_id, attacker_steam_id, attacker_name, weapon, headshot)
SELECT timestamptz '2026-01-01 00:00:00+00' + (g * interval '7 hours 13 minutes'),
       md5('match' || (g / 30))::uuid, md5('map' || (g / 15))::uuid,
       76561197960000000 + (g % 900),
       (ARRAY['Émile','zoe','Ångström','apple','Straße','Ça va','naïve','日本','Zürich','résumé'])[1 + (g % 10)] || g,
       (ARRAY['ak47','m4a1','awp','deagle','usp_silencer'])[1 + (g % 5)], g % 3 = 0
FROM generate_series(1, 700) g;
CREATE INDEX player_kills_attacker_name_idx ON public.player_kills (attacker_name);
SELECT create_hypertable('player_kills', 'time', chunk_time_interval => interval '1 day', migrate_data => true);

CREATE TABLE public.player_damages (
    id uuid NOT NULL DEFAULT gen_random_uuid(),
    "time" timestamptz NOT NULL,
    match_id uuid NOT NULL,
    match_map_id uuid NOT NULL,
    attacker_name text,
    damage int NOT NULL
);
ALTER TABLE public.player_damages ADD PRIMARY KEY (id, "time", match_id, match_map_id);
SELECT create_hypertable('player_damages', 'time', chunk_time_interval => interval '3 days', migrate_data => true);
INSERT INTO public.player_damages ("time", match_id, match_map_id, attacker_name, damage)
SELECT timestamptz '2026-01-01 00:00:00+00' + (g * interval '11 hours'),
       md5('match' || (g / 30))::uuid, md5('map' || (g / 15))::uuid,
       (ARRAY['Øystein','oystein','Łukasz','NAÏVE','東京'])[1 + (g % 5)] || g, (g * 7) % 100
FROM generate_series(1, 800) g;
CREATE INDEX player_damages_attacker_name_idx ON public.player_damages (attacker_name);

CREATE TABLE public.player_sanctions (
    id uuid NOT NULL DEFAULT gen_random_uuid(),
    created_at timestamptz NOT NULL DEFAULT now(),
    player_steam_id bigint NOT NULL,
    reason text
);
ALTER TABLE public.player_sanctions ADD PRIMARY KEY (id, created_at);
SELECT create_hypertable('player_sanctions', 'created_at', migrate_data => true);
INSERT INTO public.player_sanctions (created_at, player_steam_id, reason)
SELECT timestamptz '2026-03-01 00:00:00+00' + g * interval '2 days', 76561197960000000 + g, 'Grund für Sperre ' || g
FROM generate_series(1, 120) g;

GRANT SELECT ON ALL TABLES IN SCHEMA public TO hasura_readonly;
ANALYZE;
