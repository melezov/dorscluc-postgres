/*MIGRATION_DESCRIPTION
--CREATE: fer-Predavanje
New object Predavanje will be created in schema fer
--CREATE: fer-Predavanje-ID
New property ID will be created for Predavanje in fer
--CREATE: fer-Predavanje-naziv
New property naziv will be created for Predavanje in fer
--CREATE: fer-Predavanje-predavac
New property predavac will be created for Predavanje in fer
MIGRATION_DESCRIPTION*/

DO $$ BEGIN
    IF EXISTS(SELECT * FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = '-NGS-' AND c.relname = 'database_setting') THEN
        IF EXISTS(SELECT * FROM "-NGS-".Database_Setting WHERE Key ILIKE 'mode' AND NOT Value ILIKE 'unsafe') THEN
            RAISE EXCEPTION 'Database upgrade is forbidden. Change database mode to allow upgrade';
        END IF;
    END IF;
END $$ LANGUAGE plpgsql;

DO $$
DECLARE script VARCHAR;
BEGIN
    IF NOT EXISTS(SELECT * FROM pg_namespace WHERE nspname = '-NGS-') THEN
        CREATE SCHEMA "-NGS-";
        COMMENT ON SCHEMA "-NGS-" IS 'NGS generated';
    END IF;
    IF NOT EXISTS(SELECT * FROM pg_namespace WHERE nspname = 'public') THEN
        CREATE SCHEMA public;
        COMMENT ON SCHEMA public IS 'NGS generated';
    END IF;
    SELECT array_to_string(array_agg('DROP VIEW IF EXISTS ' || quote_ident(n.nspname) || '.' || quote_ident(cl.relname) || ' CASCADE;'), '')
    INTO script
    FROM pg_class cl
    INNER JOIN pg_namespace n ON cl.relnamespace = n.oid
    INNER JOIN pg_description d ON d.objoid = cl.oid
    WHERE cl.relkind = 'v' AND d.description LIKE 'NGS volatile%';
    IF length(script) > 0 THEN
        EXECUTE script;
    END IF;
END $$ LANGUAGE plpgsql;

CREATE TABLE IF NOT EXISTS "-NGS-".Database_Migration
(
    Ordinal SERIAL PRIMARY KEY,
    Dsls TEXT,
    Implementations BYTEA,
    Version VARCHAR,
    Applied_At TIMESTAMPTZ DEFAULT (CURRENT_TIMESTAMP)
);

CREATE OR REPLACE FUNCTION "-NGS-".Load_Last_Migration()
RETURNS "-NGS-".Database_Migration AS
$$
SELECT m FROM "-NGS-".Database_Migration m
ORDER BY Ordinal DESC
LIMIT 1
$$ LANGUAGE sql SECURITY DEFINER STABLE;

CREATE OR REPLACE FUNCTION "-NGS-".Persist_Concepts(dsls TEXT, implementations BYTEA, version VARCHAR)
  RETURNS void AS
$$
BEGIN
    INSERT INTO "-NGS-".Database_Migration(Dsls, Implementations, Version) VALUES(dsls, implementations, version);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION "-NGS-".Split_Uri(s text) RETURNS TEXT[] AS
$$
DECLARE i int;
DECLARE pos int;
DECLARE len int;
DECLARE res TEXT[];
DECLARE cur TEXT;
DECLARE c CHAR(1);
BEGIN
    pos = 0;
    i = 1;
    cur = '';
    len = length(s);
    LOOP
        pos = pos + 1;
        EXIT WHEN pos > len;
        c = substr(s, pos, 1);
        IF c = '/' THEN
            res[i] = cur;
            i = i + 1;
            cur = '';
        ELSE
            IF c = '\' THEN
                pos = pos + 1;
                c = substr(s, pos, 1);
            END IF;
            cur = cur || c;
        END IF;
    END LOOP;
    res[i] = cur;
    return res;
END
$$ LANGUAGE plpgsql SECURITY DEFINER IMMUTABLE;

CREATE OR REPLACE FUNCTION "-NGS-".Load_Type_Info(
    OUT type_schema character varying,
    OUT type_name character varying,
    OUT column_name character varying,
    OUT column_schema character varying,
    OUT column_type character varying,
    OUT column_index smallint,
    OUT is_not_null boolean,
    OUT is_ngs_generated boolean)
  RETURNS SETOF record AS
$BODY$
SELECT
    ns.nspname::varchar,
    cl.relname::varchar,
    atr.attname::varchar,
    ns_ref.nspname::varchar,
    typ.typname::varchar,
    (SELECT COUNT(*) + 1
    FROM pg_attribute atr_ord
    WHERE
        atr.attrelid = atr_ord.attrelid
        AND atr_ord.attisdropped = false
        AND atr_ord.attnum > 0
        AND atr_ord.attnum < atr.attnum)::smallint,
    atr.attnotnull,
    coalesce(d.description LIKE 'NGS generated%', false)
FROM
    pg_attribute atr
    INNER JOIN pg_class cl ON atr.attrelid = cl.oid
    INNER JOIN pg_namespace ns ON cl.relnamespace = ns.oid
    INNER JOIN pg_type typ ON atr.atttypid = typ.oid
    INNER JOIN pg_namespace ns_ref ON typ.typnamespace = ns_ref.oid
    LEFT JOIN pg_description d ON d.objoid = cl.oid
                                AND d.objsubid = atr.attnum
WHERE
    (cl.relkind = 'r' OR cl.relkind = 'v' OR cl.relkind = 'c')
    AND ns.nspname NOT LIKE 'pg_%'
    AND ns.nspname != 'information_schema'
    AND atr.attnum > 0
    AND atr.attisdropped = FALSE
ORDER BY 1, 2, 6
$BODY$
  LANGUAGE SQL STABLE;

CREATE OR REPLACE FUNCTION "-NGS-".Safe_Notify(target varchar, name varchar, operation varchar, uris varchar[]) RETURNS VOID AS
$$
DECLARE message VARCHAR;
DECLARE array_size INT;
BEGIN
    array_size = array_upper(uris, 1);
    message = name || ':' || operation || ':' || uris::TEXT;
    IF (array_size > 0 and length(message) < 8000) THEN
        PERFORM pg_notify(target, message);
    ELSEIF (array_size > 1) THEN
        PERFORM "-NGS-".Safe_Notify(target, name, operation, (SELECT array_agg(u) FROM (SELECT unnest(uris) u LIMIT (array_size+1)/2) u));
        PERFORM "-NGS-".Safe_Notify(target, name, operation, (SELECT array_agg(u) FROM (SELECT unnest(uris) u OFFSET (array_size+1)/2) u));
    ELSEIF (array_size = 1) THEN
        RAISE EXCEPTION 'uri can''t be longer than 8000 characters';
    END IF;
END
$$ LANGUAGE PLPGSQL SECURITY DEFINER;

CREATE OR REPLACE FUNCTION "-NGS-".cast_int(int[]) RETURNS TEXT AS
$$ SELECT $1::TEXT[]::TEXT $$ LANGUAGE SQL IMMUTABLE COST 1;
CREATE OR REPLACE FUNCTION "-NGS-".cast_bigint(bigint[]) RETURNS TEXT AS
$$ SELECT $1::TEXT[]::TEXT $$ LANGUAGE SQL IMMUTABLE COST 1;

DO $$ BEGIN
    -- unfortunately only superuser can create such casts
    IF EXISTS(SELECT * FROM pg_catalog.pg_user WHERE usename = CURRENT_USER AND usesuper) THEN
        IF NOT EXISTS (SELECT * FROM pg_catalog.pg_cast c JOIN pg_type s ON c.castsource = s.oid JOIN pg_type t ON c.casttarget = t.oid WHERE s.typname = '_int4' AND t.typname = 'text') THEN
            CREATE CAST (int[] AS text) WITH FUNCTION "-NGS-".cast_int(int[]) AS ASSIGNMENT;
        END IF;
        IF NOT EXISTS (SELECT * FROM pg_cast c JOIN pg_type s ON c.castsource = s.oid JOIN pg_type t ON c.casttarget = t.oid WHERE s.typname = '_int8' AND t.typname = 'text') THEN
            CREATE CAST (bigint[] AS text) WITH FUNCTION "-NGS-".cast_bigint(bigint[]) AS ASSIGNMENT;
        END IF;
    END IF;
END $$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION "-NGS-".Generate_Uri2(text, text) RETURNS text AS
$$
BEGIN
    RETURN replace(replace($1, '\','\\'), '/', '\/')||'/'||replace(replace($2, '\','\\'), '/', '\/');
END;
$$ LANGUAGE PLPGSQL IMMUTABLE;

CREATE OR REPLACE FUNCTION "-NGS-".Generate_Uri3(text, text, text) RETURNS text AS
$$
BEGIN
    RETURN replace(replace($1, '\','\\'), '/', '\/')||'/'||replace(replace($2, '\','\\'), '/', '\/')||'/'||replace(replace($3, '\','\\'), '/', '\/');
END;
$$ LANGUAGE PLPGSQL IMMUTABLE;

CREATE OR REPLACE FUNCTION "-NGS-".Generate_Uri4(text, text, text, text) RETURNS text AS
$$
BEGIN
    RETURN replace(replace($1, '\','\\'), '/', '\/')||'/'||replace(replace($2, '\','\\'), '/', '\/')||'/'||replace(replace($3, '\','\\'), '/', '\/')||'/'||replace(replace($4, '\','\\'), '/', '\/');
END;
$$ LANGUAGE PLPGSQL IMMUTABLE;

CREATE OR REPLACE FUNCTION "-NGS-".Generate_Uri5(text, text, text, text, text) RETURNS text AS
$$
BEGIN
    RETURN replace(replace($1, '\','\\'), '/', '\/')||'/'||replace(replace($2, '\','\\'), '/', '\/')||'/'||replace(replace($3, '\','\\'), '/', '\/')||'/'||replace(replace($4, '\','\\'), '/', '\/')||'/'||replace(replace($5, '\','\\'), '/', '\/');
END;
$$ LANGUAGE PLPGSQL IMMUTABLE;

CREATE OR REPLACE FUNCTION "-NGS-".Generate_Uri(text[]) RETURNS text AS
$$
BEGIN
    RETURN (SELECT array_to_string(array_agg(replace(replace(u, '\','\\'), '/', '\/')), '/') FROM unnest($1) u);
END;
$$ LANGUAGE PLPGSQL IMMUTABLE;

CREATE TABLE IF NOT EXISTS "-NGS-".Database_Setting
(
    Key VARCHAR PRIMARY KEY,
    Value TEXT NOT NULL
);

CREATE OR REPLACE FUNCTION "-NGS-".Create_Type_Cast(function VARCHAR, schema VARCHAR, from_name VARCHAR, to_name VARCHAR)
RETURNS void
AS
$$
DECLARE header VARCHAR;
DECLARE source VARCHAR;
DECLARE footer VARCHAR;
DECLARE col_name VARCHAR;
DECLARE type VARCHAR = '"' || schema || '"."' || to_name || '"';
BEGIN
    header = 'CREATE OR REPLACE FUNCTION ' || function || '
RETURNS ' || type || '
AS
$BODY$
SELECT ROW(';
    footer = ')::' || type || '
$BODY$ IMMUTABLE LANGUAGE sql;';
    source = '';
    FOR col_name IN
        SELECT
            CASE WHEN
                EXISTS (SELECT * FROM "-NGS-".Load_Type_Info() f
                    WHERE f.type_schema = schema AND f.type_name = from_name AND f.column_name = t.column_name)
                OR EXISTS(SELECT * FROM pg_proc p JOIN pg_type t_in ON p.proargtypes[0] = t_in.oid
                    JOIN pg_namespace n_in ON t_in.typnamespace = n_in.oid JOIN pg_namespace n ON p.pronamespace = n.oid
                    WHERE array_upper(p.proargtypes, 1) = 0 AND n.nspname = 'public' AND t_in.typname = from_name AND p.proname = t.column_name) THEN t.column_name
                ELSE null
            END
        FROM "-NGS-".Load_Type_Info() t
        WHERE
            t.type_schema = schema
            AND t.type_name = to_name
        ORDER BY t.column_index
    LOOP
        IF col_name IS NULL THEN
            source = source || 'null, ';
        ELSE
            source = source || '$1."' || col_name || '", ';
        END IF;
    END LOOP;
    IF (LENGTH(source) > 0) THEN
        source = SUBSTRING(source, 1, LENGTH(source) - 2);
    END IF;
    EXECUTE (header || source || footer);
END
$$ LANGUAGE plpgsql;;

DO $$ BEGIN
    IF NOT EXISTS(SELECT * FROM pg_namespace WHERE nspname = 'fer') THEN
        CREATE SCHEMA "fer";
        COMMENT ON SCHEMA "fer" IS 'NGS generated';
    END IF;
END $$ LANGUAGE plpgsql;

DO $$ BEGIN
    IF NOT EXISTS(SELECT * FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace WHERE n.nspname = 'fer' AND t.typname = '-ngs_Predavanje_type-') THEN
        CREATE TYPE "fer"."-ngs_Predavanje_type-" AS ();
        COMMENT ON TYPE "fer"."-ngs_Predavanje_type-" IS 'NGS generated';
    END IF;
END $$ LANGUAGE plpgsql;

DO $$ BEGIN
    IF NOT EXISTS(SELECT * FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'fer' AND c.relname = 'Predavanje') THEN
        CREATE TABLE "fer"."Predavanje" ();
        COMMENT ON TABLE "fer"."Predavanje" IS 'NGS generated';
    END IF;
END $$ LANGUAGE plpgsql;

DO $$ BEGIN
    IF NOT EXISTS(SELECT * FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'fer' AND c.relname = 'Predavanje_sequence') THEN
        CREATE SEQUENCE "fer"."Predavanje_sequence";
        COMMENT ON SEQUENCE "fer"."Predavanje_sequence" IS 'NGS generated';
    END IF;
END $$ LANGUAGE plpgsql;

DO $$ BEGIN
    IF NOT EXISTS(SELECT * FROM "-NGS-".Load_Type_Info() WHERE type_schema = 'fer' AND type_name = '-ngs_Predavanje_type-' AND column_name = 'ID') THEN
        ALTER TYPE "fer"."-ngs_Predavanje_type-" ADD ATTRIBUTE "ID" INT;
        COMMENT ON COLUMN "fer"."-ngs_Predavanje_type-"."ID" IS 'NGS generated';
    END IF;
END $$ LANGUAGE plpgsql;

DO $$ BEGIN
    IF NOT EXISTS(SELECT * FROM "-NGS-".Load_Type_Info() WHERE type_schema = 'fer' AND type_name = 'Predavanje' AND column_name = 'ID') THEN
        ALTER TABLE "fer"."Predavanje" ADD COLUMN "ID" INT;
        COMMENT ON COLUMN "fer"."Predavanje"."ID" IS 'NGS generated';
    END IF;
END $$ LANGUAGE plpgsql;

DO $$ BEGIN
    IF NOT EXISTS(SELECT * FROM "-NGS-".Load_Type_Info() WHERE type_schema = 'fer' AND type_name = '-ngs_Predavanje_type-' AND column_name = 'naziv') THEN
        ALTER TYPE "fer"."-ngs_Predavanje_type-" ADD ATTRIBUTE "naziv" VARCHAR;
        COMMENT ON COLUMN "fer"."-ngs_Predavanje_type-"."naziv" IS 'NGS generated';
    END IF;
END $$ LANGUAGE plpgsql;

DO $$ BEGIN
    IF NOT EXISTS(SELECT * FROM "-NGS-".Load_Type_Info() WHERE type_schema = 'fer' AND type_name = 'Predavanje' AND column_name = 'naziv') THEN
        ALTER TABLE "fer"."Predavanje" ADD COLUMN "naziv" VARCHAR;
        COMMENT ON COLUMN "fer"."Predavanje"."naziv" IS 'NGS generated';
    END IF;
END $$ LANGUAGE plpgsql;

DO $$ BEGIN
    IF NOT EXISTS(SELECT * FROM "-NGS-".Load_Type_Info() WHERE type_schema = 'fer' AND type_name = '-ngs_Predavanje_type-' AND column_name = 'predavac') THEN
        ALTER TYPE "fer"."-ngs_Predavanje_type-" ADD ATTRIBUTE "predavac" VARCHAR;
        COMMENT ON COLUMN "fer"."-ngs_Predavanje_type-"."predavac" IS 'NGS generated';
    END IF;
END $$ LANGUAGE plpgsql;

DO $$ BEGIN
    IF NOT EXISTS(SELECT * FROM "-NGS-".Load_Type_Info() WHERE type_schema = 'fer' AND type_name = 'Predavanje' AND column_name = 'predavac') THEN
        ALTER TABLE "fer"."Predavanje" ADD COLUMN "predavac" VARCHAR;
        COMMENT ON COLUMN "fer"."Predavanje"."predavac" IS 'NGS generated';
    END IF;
END $$ LANGUAGE plpgsql;

CREATE OR REPLACE VIEW "fer"."Predavanje_entity" AS
SELECT _entity."ID", _entity."naziv", _entity."predavac"
FROM
    "fer"."Predavanje" _entity
    ;
COMMENT ON VIEW "fer"."Predavanje_entity" IS 'NGS volatile';

CREATE OR REPLACE FUNCTION "URI"("fer"."Predavanje_entity") RETURNS TEXT AS $$
SELECT CAST($1."ID" as TEXT)
$$ LANGUAGE SQL IMMUTABLE SECURITY DEFINER;

CREATE OR REPLACE FUNCTION "fer"."cast_Predavanje_to_type"("fer"."-ngs_Predavanje_type-") RETURNS "fer"."Predavanje_entity" AS $$ SELECT $1::text::"fer"."Predavanje_entity" $$ IMMUTABLE LANGUAGE sql;
CREATE OR REPLACE FUNCTION "fer"."cast_Predavanje_to_type"("fer"."Predavanje_entity") RETURNS "fer"."-ngs_Predavanje_type-" AS $$ SELECT $1::text::"fer"."-ngs_Predavanje_type-" $$ IMMUTABLE LANGUAGE sql;

DO $$ BEGIN
    IF NOT EXISTS(SELECT * FROM pg_cast c JOIN pg_type s ON c.castsource = s.oid JOIN pg_type t ON c.casttarget = t.oid JOIN pg_namespace n ON n.oid = s.typnamespace AND n.oid = t.typnamespace
                    WHERE n.nspname = 'fer' AND s.typname = 'Predavanje_entity' AND t.typname = '-ngs_Predavanje_type-') THEN
        CREATE CAST ("fer"."-ngs_Predavanje_type-" AS "fer"."Predavanje_entity") WITH FUNCTION "fer"."cast_Predavanje_to_type"("fer"."-ngs_Predavanje_type-") AS IMPLICIT;
        CREATE CAST ("fer"."Predavanje_entity" AS "fer"."-ngs_Predavanje_type-") WITH FUNCTION "fer"."cast_Predavanje_to_type"("fer"."Predavanje_entity") AS IMPLICIT;
    END IF;
END $$ LANGUAGE plpgsql;

CREATE OR REPLACE VIEW "fer"."Predavanje_unprocessed_events" AS
SELECT _aggregate."ID"
FROM
    "fer"."Predavanje_entity" _aggregate
;
COMMENT ON VIEW "fer"."Predavanje_unprocessed_events" IS 'NGS volatile';

CREATE OR REPLACE FUNCTION "fer"."insert_Predavanje"(IN _inserted "fer"."Predavanje_entity"[]) RETURNS VOID AS
$$
BEGIN
    INSERT INTO "fer"."Predavanje" ("ID", "naziv", "predavac") VALUES(_inserted[1]."ID", _inserted[1]."naziv", _inserted[1]."predavac");

    PERFORM pg_notify('aggregate_roots', 'fer.Predavanje:Insert:' || array["URI"(_inserted[1])]::TEXT);
END
$$
LANGUAGE plpgsql SECURITY DEFINER;;

CREATE OR REPLACE FUNCTION "fer"."persist_Predavanje"(
IN _inserted "fer"."Predavanje_entity"[], IN _updated_original "fer"."Predavanje_entity"[], IN _updated_new "fer"."Predavanje_entity"[], IN _deleted "fer"."Predavanje_entity"[])
    RETURNS VARCHAR AS
$$
DECLARE cnt int;
DECLARE uri VARCHAR;
DECLARE tmp record;
DECLARE _update_count int = array_upper(_updated_original, 1);
DECLARE _delete_count int = array_upper(_deleted, 1);

BEGIN

    SET CONSTRAINTS ALL DEFERRED;



    INSERT INTO "fer"."Predavanje" ("ID", "naziv", "predavac")
    SELECT _i."ID", _i."naziv", _i."predavac"
    FROM unnest(_inserted) _i;



    UPDATE "fer"."Predavanje" as _tbl SET "ID" = (_u.changed)."ID", "naziv" = (_u.changed)."naziv", "predavac" = (_u.changed)."predavac"
    FROM (SELECT unnest(_updated_original) as original, unnest(_updated_new) as changed) _u
    WHERE _tbl."ID" = (_u.original)."ID";

    GET DIAGNOSTICS cnt = ROW_COUNT;
    IF cnt != _update_count THEN
        RETURN 'Updated ' || cnt || ' row(s). Expected to update ' || _update_count || ' row(s).';
    END IF;



    DELETE FROM "fer"."Predavanje"
    WHERE ("ID") IN (SELECT _d."ID" FROM unnest(_deleted) _d);

    GET DIAGNOSTICS cnt = ROW_COUNT;
    IF cnt != _delete_count THEN
        RETURN 'Deleted ' || cnt || ' row(s). Expected to delete ' || _delete_count || ' row(s).';
    END IF;


    PERFORM "-NGS-".Safe_Notify('aggregate_roots', 'fer.Predavanje', 'Insert', (SELECT array_agg(_i."URI") FROM unnest(_inserted) _i));
    PERFORM "-NGS-".Safe_Notify('aggregate_roots', 'fer.Predavanje', 'Update', (SELECT array_agg(_u."URI") FROM unnest(_updated_original) _u));
    PERFORM "-NGS-".Safe_Notify('aggregate_roots', 'fer.Predavanje', 'Change', (SELECT array_agg((_u.changed)."URI") FROM (SELECT unnest(_updated_original) as original, unnest(_updated_new) as changed) _u WHERE (_u.changed)."ID" != (_u.original)."ID"));
    PERFORM "-NGS-".Safe_Notify('aggregate_roots', 'fer.Predavanje', 'Delete', (SELECT array_agg(_d."URI") FROM unnest(_deleted) _d));

    SET CONSTRAINTS ALL IMMEDIATE;

    RETURN NULL;
END
$$
LANGUAGE plpgsql SECURITY DEFINER;

CREATE OR REPLACE FUNCTION "fer"."update_Predavanje"(IN _original "fer"."Predavanje_entity"[], IN _updated "fer"."Predavanje_entity"[]) RETURNS VARCHAR AS
$$
DECLARE cnt int;
BEGIN

    UPDATE "fer"."Predavanje" AS _tab SET "ID" = _updated[1]."ID", "naziv" = _updated[1]."naziv", "predavac" = _updated[1]."predavac" WHERE _tab."ID" = _original[1]."ID";
    GET DIAGNOSTICS cnt = ROW_COUNT;

    PERFORM pg_notify('aggregate_roots', 'fer.Predavanje:Update:' || array["URI"(_original[1])]::TEXT);
    IF (_original[1]."ID" != _updated[1]."ID") THEN
        PERFORM pg_notify('aggregate_roots', 'fer.Predavanje:Change:' || array["URI"(_updated[1])]::TEXT);
    END IF;
    RETURN CASE WHEN cnt = 0 THEN 'No rows updated' ELSE NULL END;
END
$$
LANGUAGE plpgsql SECURITY DEFINER;;

CREATE OR REPLACE FUNCTION "jelImaVezeSaPostgresom"("it" "fer"."Predavanje_entity") RETURNS BOOL AS $$
SELECT (COALESCE((("it")."naziv" LIKE '%' || 'PostgreSQL' || '%'), false::BOOL))::BOOL
$$ LANGUAGE SQL IMMUTABLE SECURITY DEFINER;

SELECT "-NGS-".Create_Type_Cast('"fer"."cast_Predavanje_to_type"("fer"."-ngs_Predavanje_type-")', 'fer', '-ngs_Predavanje_type-', 'Predavanje_entity');
SELECT "-NGS-".Create_Type_Cast('"fer"."cast_Predavanje_to_type"("fer"."Predavanje_entity")', 'fer', 'Predavanje_entity', '-ngs_Predavanje_type-');
UPDATE "fer"."Predavanje" SET "ID" = 0 WHERE "ID" IS NULL;
UPDATE "fer"."Predavanje" SET "naziv" = '' WHERE "naziv" IS NULL;
UPDATE "fer"."Predavanje" SET "predavac" = '' WHERE "predavac" IS NULL;

DO $$
DECLARE _pk VARCHAR;
BEGIN
    IF EXISTS(SELECT * FROM pg_index i JOIN pg_class c ON i.indrelid = c.oid JOIN pg_namespace n ON c.relnamespace = n.oid WHERE i.indisprimary AND n.nspname = 'fer' AND c.relname = 'Predavanje') THEN
        SELECT array_to_string(array_agg(sq.attname), ', ') INTO _pk
        FROM
        (
            SELECT atr.attname
            FROM pg_index i
            JOIN pg_class c ON i.indrelid = c.oid
            JOIN pg_attribute atr ON atr.attrelid = c.oid
            WHERE
                c.oid = '"fer"."Predavanje"'::regclass
                AND atr.attnum = any(i.indkey)
                AND indisprimary
            ORDER BY (SELECT i FROM generate_subscripts(i.indkey,1) g(i) WHERE i.indkey[i] = atr.attnum LIMIT 1)
        ) sq;
        IF ('ID' != _pk) THEN
            RAISE EXCEPTION 'Different primary key defined for table fer.Predavanje. Expected primary key: ID. Found: %', _pk;
        END IF;
    ELSE
        ALTER TABLE "fer"."Predavanje" ADD CONSTRAINT "pk_Predavanje" PRIMARY KEY("ID");
        COMMENT ON CONSTRAINT "pk_Predavanje" ON "fer"."Predavanje" IS 'NGS generated';
    END IF;
END $$ LANGUAGE plpgsql;
ALTER TABLE "fer"."Predavanje" ALTER "ID" SET NOT NULL;

DO $$
BEGIN
    IF NOT EXISTS(SELECT * FROM pg_class c JOIN pg_namespace n ON c.relnamespace = n.oid WHERE n.nspname = 'fer' AND c.relname = 'Predavanje_ID_seq' AND c.relkind = 'S') THEN
        CREATE SEQUENCE "fer"."Predavanje_ID_seq";
        ALTER TABLE "fer"."Predavanje"    ALTER COLUMN "ID" SET DEFAULT NEXTVAL('"fer"."Predavanje_ID_seq"');
        PERFORM SETVAL('"fer"."Predavanje_ID_seq"', COALESCE(MAX("ID"), 0) + 1000) FROM "fer"."Predavanje";
    END IF;
END $$ LANGUAGE plpgsql;
ALTER TABLE "fer"."Predavanje" ALTER "naziv" SET NOT NULL;
ALTER TABLE "fer"."Predavanje" ALTER "predavac" SET NOT NULL;

SELECT "-NGS-".Persist_Concepts('"dsl/fer.dsl"=>"module fer
{
  aggregate Predavanje {
    String  naziv;
    String  predavac;

    calculated Boolean jelImaVezeSaPostgresom from ''it => it.naziv.Contains(\"PostgreSQL\")'';
  }
}
"', '\x','1.5.5976.31080');
SELECT pg_notify('migration', 'new');
