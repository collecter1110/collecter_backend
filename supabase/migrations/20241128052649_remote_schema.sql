

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE EXTENSION IF NOT EXISTS "pgsodium" WITH SCHEMA "pgsodium";






COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "pg_graphql" WITH SCHEMA "graphql";






CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgjwt" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE OR REPLACE FUNCTION "public"."delete_report_post"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  -- 같은 report_type과 reported_post_id를 가지며 status가 true인 행의 개수 조회
  IF (
    SELECT COUNT(*) 
    FROM reports
    WHERE status = true 
      AND report_type = NEW.report_type
      AND reported_post_id::jsonb = NEW.reported_post_id::jsonb
  ) >= 3 THEN

    -- report_type이 0인 경우 userinfo 테이블의 user_id와 일치하는지 확인 후 삭제
    IF NEW.report_type = 0 THEN
      UPDATE auth.users
      SET banned_until = NOW() + INTERVAL '7 days'
      WHERE id = (
        SELECT uuid 
        FROM useridentify
        WHERE user_id = (NEW.reported_post_id->>'user_id')::bigint
      );

    -- report_type이 1인 경우 collections 테이블의 collection_id와 일치할 때만 삭제
    ELSIF NEW.report_type = 1 THEN
      DELETE FROM collections
      WHERE id = (NEW.reported_post_id->>'collection_id')::bigint;

    -- report_type이 2인 경우 selections 테이블의 collection_id와 selection_id가 일치할 때만 삭제
    ELSIF NEW.report_type = 2 THEN
      DELETE FROM selections
      WHERE collection_id = (NEW.reported_post_id->>'collection_id')::bigint
        AND selection_id = (NEW.reported_post_id->>'selection_id')::bigint;
    END IF;

  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."delete_report_post"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."delete_selecting"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  -- selecting 테이블에서 삭제될 uuid를 저장할 변수
  found_uuid UUID;
BEGIN
  -- 삭제된 행의 is_selecting 값이 false인 경우에만 처리
  IF OLD.is_selecting = false THEN
    -- collection_id와 selection_id가 일치하는 모든 행의 uuid를 찾음
    FOR found_uuid IN
      SELECT uuid
      FROM public.selecting
      WHERE selected_collection_id = OLD.collection_id
        AND selected_selection_id = OLD.selection_id
    LOOP
      -- selecting 테이블에서 해당 uuid 삭제
      DELETE FROM public.selecting
      WHERE uuid = found_uuid;

      -- selections 테이블에서 selecting_uuid와 일치하는 행도 삭제
      DELETE FROM public.selections
      WHERE selecting_uuid = found_uuid;

      -- 삭제 후 디버깅 메시지 출력
      RAISE NOTICE 'Deleted selecting and related selections for uuid: %', found_uuid;
    END LOOP;
  END IF;

  RETURN OLD;
END;
$$;


ALTER FUNCTION "public"."delete_selecting"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."delete_user_by_owner"("user_uuid" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
begin
  -- 사용자를 auth.users 테이블에서 삭제
  delete from auth.users where id = user_uuid;
end;
$$;


ALTER FUNCTION "public"."delete_user_by_owner"("user_uuid" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."generate_selecting_uuid"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  IF NEW.is_selecting = true THEN
    IF NEW.selecting_uuid IS NULL THEN
      NEW.selecting_uuid := uuid_generate_v4();
    END IF;
  ELSE
    NEW.selecting_uuid := NULL; -- is_selecting이 false일 때 uuid를 제거할지 여부를 설정
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."generate_selecting_uuid"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_storage_files"("user_id" "text") RETURNS TABLE("file_name" "text")
    LANGUAGE "plpgsql"
    AS $$
begin
  return query
    select name from storage.objects
    where bucket_id = 'images'
      and (name like user_id || '/collections/%'
        or name like user_id || '/selections/%'
        or name like user_id || '/userinfo/%');
end;
$$;


ALTER FUNCTION "public"."get_storage_files"("user_id" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."insert_into_selecting"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  IF NEW.is_selecting = true THEN
    INSERT INTO public.selecting (uuid, selecting_collection_id, selecting_selection_id, selecting_user_id)
    VALUES (NEW.selecting_uuid, NEW.collection_id, NEW.selection_id, NEW.user_id);
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."insert_into_selecting"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."insert_user_data"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
    new_user_id INTEGER;  
BEGIN
    IF NEW.email_confirmed_at IS NOT NULL THEN
        -- useridentify 테이블에 데이터 삽입하고 생성된 user_id를 반환
        INSERT INTO public.useridentify(uuid, email)
        VALUES (
            NEW.id, 
            NEW.email
        )
        RETURNING user_id INTO new_user_id;
        -- userinfo 테이블에 반환된 user_id와 다른 데이터를 추가
        INSERT INTO public.userinfo(user_id, email, name, image_file_path, description)
        VALUES (
            new_user_id,  -- 새로 생성된 user_id를 사용
            NEW.email, 
            null,
            null,
            null
        );
    END IF;
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."insert_user_data"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."validate_tags_format"("tags" "jsonb") RETURNS boolean
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  elem TEXT;
BEGIN
  -- tags가 NULL이면 TRUE 반환
  IF tags IS NULL THEN
    RETURN TRUE;
  END IF;

  -- tags가 배열인지 확인
  IF jsonb_typeof(tags) <> 'array' THEN
    RETURN FALSE;
  END IF;

  -- 배열의 각 요소가 문자열이고 공백이 없는지 확인
  FOR elem IN SELECT jsonb_array_elements_text(tags)
  LOOP
    IF elem ~ '\s' THEN  -- 공백(띄어쓰기)이 있는 경우
      RETURN FALSE;
    END IF;
  END LOOP;

  RETURN TRUE;
END;
$$;


ALTER FUNCTION "public"."validate_tags_format"("tags" "jsonb") OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."collections" (
    "id" integer NOT NULL,
    "title" "text" NOT NULL,
    "description" "text",
    "created_at" "date" DEFAULT CURRENT_DATE NOT NULL,
    "user_id" integer NOT NULL,
    "image_file_path" "text",
    "tags" "jsonb",
    "user_name" "text" NOT NULL,
    "primary_keywords" "jsonb",
    "selection_num" integer DEFAULT 0 NOT NULL,
    "like_num" integer DEFAULT 0,
    "is_public" boolean DEFAULT false NOT NULL,
    CONSTRAINT "check_tags_format_no_whitespace" CHECK ("public"."validate_tags_format"("tags"))
);


ALTER TABLE "public"."collections" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."search_collections_by_keyword"("query" "text") RETURNS SETOF "public"."collections"
    LANGUAGE "sql" STABLE
    AS $$
  SELECT c.*
  FROM collections c
  JOIN keywordinfo k ON k.keyword_id = ANY (
    SELECT (elem->>'keyword_id')::int 
    FROM jsonb_array_elements(c.primary_keywords) elem
  )
  LEFT JOIN block b ON b.blocked_user_id = c.user_id
                     AND b.blocker_user_id = (
                       SELECT user_id
                       FROM useridentify
                       WHERE uuid = auth.uid()
                     )
  WHERE k.keyword_name ILIKE '%' || query || '%'
    AND b.blocked_user_id IS NULL; -- 차단된 사용자 제외
$$;


ALTER FUNCTION "public"."search_collections_by_keyword"("query" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."search_collections_by_keyword"("query" "text", "blocker_user" integer) RETURNS SETOF "public"."collections"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  RETURN QUERY
  SELECT c.*
  FROM collections c
  JOIN keywordinfo k ON k.keyword_id = ANY (
    SELECT (elem->>'keyword_id')::int 
    FROM jsonb_array_elements(c.primary_keywords) elem
  )
  LEFT JOIN block b ON b.blocked_user_id = c.user_id AND b.blocker_user_id = blocker_user
  WHERE k.keyword_name ILIKE '%' || query || '%'
    AND b.blocked_user_id IS NULL; -- 차단된 사용자 제외
END;
$$;


ALTER FUNCTION "public"."search_collections_by_keyword"("query" "text", "blocker_user" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."search_collections_by_tag"("query" "text") RETURNS SETOF "public"."collections"
    LANGUAGE "sql" STABLE
    AS $$
  SELECT c.*
  FROM collections c
  LEFT JOIN block b ON b.blocked_user_id = c.user_id
                     AND b.blocker_user_id = (
                       SELECT user_id
                       FROM useridentify
                       WHERE uuid = auth.uid()
                     )
  WHERE c.tags @> to_jsonb(ARRAY[query]::text[])
    AND b.blocked_user_id IS NULL; -- 차단된 사용자 제외
$$;


ALTER FUNCTION "public"."search_collections_by_tag"("query" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."validate_items_format"("items" "jsonb") RETURNS boolean
    LANGUAGE "plpgsql"
    AS $$BEGIN
    RETURN (
        jsonb_typeof(items) = 'array' AND
        (
            SELECT bool_and(
                jsonb_typeof(elem) = 'object' AND
                -- item_order가 존재하고 숫자인지 확인
                elem ? 'item_order' AND jsonb_typeof(elem->'item_order') = 'number' AND
                -- item_title이 존재하고 문자열인지 확인
                elem ? 'item_title' AND jsonb_typeof(elem->'item_title') = 'string'
            )
            FROM jsonb_array_elements(items) AS elem
        )
    );
END;$$;


ALTER FUNCTION "public"."validate_items_format"("items" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."validate_keywords_format"("keywords" "jsonb") RETURNS boolean
    LANGUAGE "plpgsql"
    AS $_$BEGIN
    RETURN (
        jsonb_typeof(keywords) = 'array' AND
        (
            SELECT bool_and(
                jsonb_typeof(elem) = 'object' AND
                jsonb_typeof(elem->'keyword_id') = 'number' AND  -- keyword_id가 숫자인지 확인
                elem->>'keyword_id' ~ '^\d+$' AND               -- keyword_id가 정수인지 확인
                elem ? 'keyword_name'                           -- keyword_name이 존재하는지 확인
            )
            FROM jsonb_array_elements(keywords) AS elem
        )
    );
END;$_$;


ALTER FUNCTION "public"."validate_keywords_format"("keywords" "jsonb") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."selections" (
    "collection_id" integer NOT NULL,
    "selection_id" integer NOT NULL,
    "title" character varying(255) NOT NULL,
    "description" "text",
    "user_id" integer NOT NULL,
    "owner_id" integer NOT NULL,
    "selecting_uuid" "uuid",
    "is_ordered" boolean DEFAULT false NOT NULL,
    "link" "text",
    "items" "jsonb",
    "keywords" "jsonb",
    "created_at" "date" DEFAULT CURRENT_DATE NOT NULL,
    "owner_name" "text" NOT NULL,
    "is_selectable" boolean DEFAULT false NOT NULL,
    "image_file_paths" "text"[],
    "is_selecting" boolean,
    "select_num" integer DEFAULT 0 NOT NULL,
    CONSTRAINT "check_items_format" CHECK ((("items" IS NULL) OR "public"."validate_items_format"("items"))),
    CONSTRAINT "check_keywords_format" CHECK ((("keywords" IS NULL) OR "public"."validate_keywords_format"("keywords")))
);


ALTER TABLE "public"."selections" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."search_selections_by_keyword"("query" "text") RETURNS SETOF "public"."selections"
    LANGUAGE "sql" STABLE
    AS $$
  SELECT s.*
  FROM selections s
  JOIN keywordinfo k ON k.keyword_id = ANY (
    SELECT (elem->>'keyword_id')::int 
    FROM jsonb_array_elements(s.keywords) elem
  )
  LEFT JOIN block b ON b.blocked_user_id = s.user_id
                     AND b.blocker_user_id = (
                       SELECT user_id
                       FROM useridentify
                       WHERE uuid = auth.uid()
                     )
  WHERE k.keyword_name ILIKE '%' || query || '%'
    AND b.blocked_user_id IS NULL; -- 차단된 사용자 제외
$$;


ALTER FUNCTION "public"."search_selections_by_keyword"("query" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."search_users"("query" "text") RETURNS TABLE("user_id" integer, "name" "text", "description" "text", "image_file_path" "text")
    LANGUAGE "sql" STABLE
    AS $$
  SELECT u.user_id, u.name, u.description, u.image_file_path
  FROM userinfo u
  LEFT JOIN block b ON b.blocked_user_id = u.user_id
                     AND b.blocker_user_id = (
                       SELECT user_id
                       FROM useridentify
                       WHERE uuid = auth.uid()
                     )
  WHERE to_tsvector('simple', u.name) @@ plainto_tsquery('simple', query)
    AND b.blocked_user_id IS NULL; -- 차단된 사용자 제외
$$;


ALTER FUNCTION "public"."search_users"("query" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_keyword_id"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  -- 최대 keyword_id 조회 후 새로운 값 설정
  NEW.keyword_id := (SELECT COALESCE(MAX(keyword_id), 0) + 1 FROM public.keywordinfo);
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."set_keyword_id"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_owner_name_in_selections"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    -- user_id에 따라 user_name을 userinfo 테이블에서 자동으로 설정
    NEW.owner_name := (SELECT name FROM public.userinfo WHERE userinfo.user_id = NEW.owner_id);
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."set_owner_name_in_selections"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_selection_id"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
DECLARE
    max_id INT;
BEGIN
    -- selection_id가 null일 때만 새로운 값을 설정
    IF NEW.selection_id IS NULL THEN
        -- 현재 그룹의 최대 selection_id를 찾음
        SELECT COALESCE(MAX(selection_id), 0) + 1 INTO max_id
        FROM selections
        WHERE collection_id = NEW.collection_id;

        -- 새로운 selection_id 설정
        NEW.selection_id = max_id;
    END IF;

    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."set_selection_id"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_user_name_in_collections"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
    -- user_id에 따라 user_name을 userinfo 테이블에서 자동으로 설정
    NEW.user_name := (SELECT name FROM public.userinfo WHERE userinfo.user_id = NEW.user_id);
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."set_user_name_in_collections"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_is_selecting_status"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$BEGIN
  -- DELETE 작업일 경우
  IF TG_OP = 'DELETE' THEN
    -- selecting 테이블에 더 이상 데이터가 없는지 확인 후 selections 테이블의 is_selecting을 NULL로 설정
    IF NOT EXISTS (
      SELECT 1
      FROM public.selecting
      WHERE selected_collection_id = OLD.selected_collection_id
        AND selected_selection_id = OLD.selected_selection_id
    ) THEN
      UPDATE public.selections
      SET is_selecting = NULL,
          select_num = select_num - 1  -- selection_num을 -1 감소
      WHERE collection_id = OLD.selected_collection_id
        AND selection_id = OLD.selected_selection_id;
    ELSE
      -- selecting이 남아있어도 selection_num을 -1 감소
      UPDATE public.selections
      SET select_num = select_num - 1
      WHERE collection_id = OLD.selected_collection_id
        AND selection_id = OLD.selected_selection_id;
    END IF;

  -- INSERT 작업일 경우
  ELSIF TG_OP = 'UPDATE' THEN
    -- 새로 입력된 데이터가 있는 경우 is_selecting 값을 false로 설정하고 selection_num을 +1 증가
    IF EXISTS (
      SELECT 1
      FROM public.selecting
      WHERE selected_collection_id = NEW.selected_collection_id
        AND selected_selection_id = NEW.selected_selection_id
    ) THEN
      UPDATE public.selections
      SET is_selecting = false,
          select_num = select_num + 1  -- selection_num을 +1 증가
      WHERE collection_id = NEW.selected_collection_id
        AND selection_id = NEW.selected_selection_id;
    ELSE
      -- 데이터가 없는 경우 is_selecting을 NULL로 설정
      UPDATE public.selections
      SET is_selecting = NULL
      WHERE collection_id = NEW.selected_collection_id
        AND selection_id = NEW.selected_selection_id;
    END IF;

  -- UPDATE 작업일 경우 (select_num 변경 없음)
  ELSIF TG_OP = 'INSERT' THEN
    UPDATE public.selections
    SET is_selecting = false
    WHERE collection_id = NEW.selected_collection_id
      AND selection_id = NEW.selected_selection_id;
  END IF;

  RETURN NEW;
END;$$;


ALTER FUNCTION "public"."update_is_selecting_status"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_like_num"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
BEGIN
  -- 좋아요 추가 시에는 NEW.collection_id 사용
  -- 좋아요 삭제 시에는 OLD.collection_id 사용
  UPDATE public.collections
  SET like_num = (
    SELECT COUNT(*)
    FROM public.likes
    WHERE collection_id = COALESCE(NEW.collection_id, OLD.collection_id)
  )
  WHERE id = COALESCE(NEW.collection_id, OLD.collection_id);

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_like_num"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_primary_keywords_trigger_function"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  -- 트리거가 호출되었는지 확인
  IF TG_OP = 'DELETE' THEN
    RAISE NOTICE 'Trigger function called for DELETE, collection_id: %', OLD.collection_id;

    -- DELETE 작업일 경우, OLD.collection_id를 사용
    WITH keyword_ranking AS (
      -- 동일한 keyword_id와 keyword_name에 대해 중복을 제거하고 카운트 합산
      SELECT
        s.collection_id,
        (k->>'keyword_id')::int AS keyword_id,  -- keyword_id를 int로 변환
        k->>'keyword_name' AS keyword_name,
        COUNT(*) AS keyword_count
      FROM
        public.selections s
      CROSS JOIN LATERAL
        jsonb_array_elements(s.keywords) AS k
      WHERE
        s.collection_id = OLD.collection_id  -- 삭제된 데이터의 collection_id
        AND s.keywords IS NOT NULL
      GROUP BY
        s.collection_id, k->>'keyword_id', k->>'keyword_name'
    ),
    ranked_keywords AS (
      SELECT
        collection_id,
        jsonb_build_object(
          'keyword_id', keyword_id::int,  -- keyword_id를 int로 저장
          'keyword_name', keyword_name,
          'count', keyword_count
        ) AS keyword_object,
        ROW_NUMBER() OVER (
          PARTITION BY collection_id
          ORDER BY keyword_count DESC, keyword_name ASC
        ) AS rank
      FROM
        keyword_ranking
    ),
    top_keywords AS (
      SELECT
        collection_id,
        jsonb_agg(keyword_object ORDER BY rank) AS keywords
      FROM
        ranked_keywords
      WHERE rank <= 3  -- 상위 3개의 키워드만 선택
      GROUP BY
        collection_id
    )
    UPDATE
      public.collections c
    SET
      primary_keywords = (
        SELECT keywords
        FROM top_keywords t
        WHERE t.collection_id = c.id
      )
    WHERE c.id = OLD.collection_id;   -- 삭제된 collection_id에 대해 업데이트

  ELSE
    -- INSERT 또는 UPDATE 작업일 경우, NEW.collection_id 사용
    RAISE NOTICE 'Trigger function called for INSERT or UPDATE, collection_id: %', NEW.collection_id;

    -- 이전 collection_id도 포함하여 업데이트
    -- 만약 collection_id가 UPDATE 되었을 경우, OLD.collection_id도 처리
    WITH keyword_ranking AS (
      -- 동일한 keyword_id와 keyword_name에 대해 중복을 제거하고 카운트 합산
      SELECT
        s.collection_id,
        (k->>'keyword_id')::int AS keyword_id,  -- keyword_id를 int로 변환
        k->>'keyword_name' AS keyword_name,
        COUNT(*) AS keyword_count
      FROM
        public.selections s
      CROSS JOIN LATERAL
        jsonb_array_elements(s.keywords) AS k
      WHERE
        s.collection_id IN (NEW.collection_id, OLD.collection_id)  -- 새롭게 삽입된 collection_id와 기존의 collection_id
        AND s.keywords IS NOT NULL
      GROUP BY
        s.collection_id, k->>'keyword_id', k->>'keyword_name'
    ),
    ranked_keywords AS (
      SELECT
        collection_id,
        jsonb_build_object(
          'keyword_id', keyword_id::int,  -- keyword_id를 int로 저장
          'keyword_name', keyword_name,
          'count', keyword_count
        ) AS keyword_object,
        ROW_NUMBER() OVER (
          PARTITION BY collection_id
          ORDER BY keyword_count DESC, keyword_name ASC
        ) AS rank
      FROM
        keyword_ranking
    ),
    top_keywords AS (
      SELECT
        collection_id,
        jsonb_agg(keyword_object ORDER BY rank) AS keywords
      FROM
        ranked_keywords
      WHERE rank <= 3  -- 상위 3개의 키워드만 선택
      GROUP BY
        collection_id
    )
    UPDATE
      public.collections c
    SET
      primary_keywords = (
        SELECT keywords
        FROM top_keywords t
        WHERE t.collection_id = c.id
      )
    WHERE c.id IN (NEW.collection_id, OLD.collection_id);   -- 삽입/업데이트된 collection_id와 기존 collection_id에 대해 업데이트
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_primary_keywords_trigger_function"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_selecting"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  -- is_selecting이 false이면 selected 컬럼을 업데이트
  IF NEW.is_selecting = false THEN
    -- 값이 다를 때만 업데이트 실행
    IF OLD.collection_id != NEW.collection_id OR OLD.selection_id != NEW.selection_id THEN
      UPDATE public.selecting
      SET selected_collection_id = NEW.collection_id,
          selected_selection_id = NEW.selection_id
      WHERE selected_collection_id = OLD.collection_id
        AND selected_selection_id = OLD.selection_id;
    END IF;

  -- is_selecting이 true이면 selecting 컬럼을 업데이트
  ELSIF NEW.is_selecting = true THEN
    -- 값이 다를 때만 업데이트 실행
    IF OLD.collection_id != NEW.collection_id OR OLD.selection_id != NEW.selection_id THEN
      UPDATE public.selecting
      SET selecting_collection_id = NEW.collection_id,
          selecting_selection_id = NEW.selection_id
      WHERE selecting_collection_id = OLD.collection_id
        AND selecting_selection_id = OLD.selection_id;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_selecting"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_selecting_selection"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$DECLARE
  -- 여러 개의 uuid를 저장할 변수
  uuid_record RECORD;
BEGIN
  -- is_selecting이 false일 경우에만 실행
  IF NEW.is_selecting = false THEN
    -- selecting 테이블에서 해당 collection_id와 selection_id로 모든 uuid를 찾음
    FOR uuid_record IN
      SELECT uuid
      FROM selecting
      WHERE selected_collection_id = NEW.collection_id
        AND selected_selection_id = NEW.selection_id
    LOOP
      -- uuid가 존재하면 selections 테이블의 selecting_uuid가 일치하는 데이터 업데이트
      UPDATE selections
      SET title = NEW.title,
          description = NEW.description,
          image_file_paths = NEW.image_file_paths,
          keywords = NEW.keywords,
          link = NEW.link,
          items = NEW.items,
          is_ordered = NEW.is_ordered,
          is_selectable = NEW.is_selectable
      WHERE selecting_uuid = uuid_record.uuid;

      -- 업데이트 후 디버깅 메시지 출력
      RAISE NOTICE 'Selection updated where selecting_uuid = %', uuid_record.uuid;
    END LOOP;
  END IF;

  -- 트리거는 항상 NEW 값을 반환해야 함
  RETURN NEW;
END;$$;


ALTER FUNCTION "public"."update_selecting_selection"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_selection_num_in_collections"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  -- DELETE 작업일 경우, OLD.collection_id를 사용
  IF TG_OP = 'DELETE' THEN
    -- 삭제된 collection_id에 대한 selection_num 업데이트
    WITH selection_count AS (
      SELECT
        s.collection_id,
        COUNT(*) AS selection_count
      FROM
        public.selections s
      WHERE s.collection_id = OLD.collection_id  -- 삭제된 데이터의 collection_id
      GROUP BY
        s.collection_id
    )
    UPDATE
      public.collections c
    SET
      selection_num = COALESCE((
        SELECT sc.selection_count
        FROM selection_count sc
        WHERE sc.collection_id = c.id
      ), 0)  -- NULL이 발생하면 0으로 설정
    WHERE c.id = OLD.collection_id;  -- 삭제된 collection_id에 대해 업데이트

  ELSE
    -- INSERT 또는 UPDATE 작업일 경우, NEW.collection_id와 OLD.collection_id 모두 처리
    -- 먼저 새로운 collection_id에 대한 selection_num 업데이트
    WITH selection_count AS (
      SELECT
        s.collection_id,
        COUNT(*) AS selection_count
      FROM
        public.selections s
      WHERE s.collection_id IN (NEW.collection_id, OLD.collection_id)  -- 새로운 데이터와 기존 데이터의 collection_id 모두 조회
      GROUP BY
        s.collection_id
    )
    UPDATE
      public.collections c
    SET
      selection_num = COALESCE((
        SELECT sc.selection_count
        FROM selection_count sc
        WHERE sc.collection_id = c.id
      ), 0)  -- NULL이 발생하면 0으로 설정
    WHERE c.id IN (NEW.collection_id, OLD.collection_id);  -- 삽입 또는 업데이트된 collection_id와 이전 collection_id에 대해 업데이트
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_selection_num_in_collections"() OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."block" (
    "id" bigint NOT NULL,
    "blocked_user_id" integer NOT NULL,
    "blocker_user_id" integer NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."block" OWNER TO "postgres";


ALTER TABLE "public"."block" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."block_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



ALTER TABLE "public"."collections" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."collection_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."keywordinfo" (
    "keyword_id" integer NOT NULL,
    "keyword_name" character varying(255) NOT NULL
);


ALTER TABLE "public"."keywordinfo" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."keywordinfo_keyword_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE "public"."keywordinfo_keyword_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."keywordinfo_keyword_id_seq" OWNED BY "public"."keywordinfo"."keyword_id";



CREATE TABLE IF NOT EXISTS "public"."likes" (
    "user_id" integer NOT NULL,
    "collection_id" integer NOT NULL,
    "id" bigint NOT NULL,
    "liked_at" timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


ALTER TABLE "public"."likes" OWNER TO "postgres";


ALTER TABLE "public"."likes" ALTER COLUMN "id" ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME "public"."likes_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE TABLE IF NOT EXISTS "public"."reports" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "report_reason" "text" NOT NULL,
    "reporter_user_id" bigint NOT NULL,
    "reported_post_id" "jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "status" boolean DEFAULT false NOT NULL,
    "report_type" smallint NOT NULL
);


ALTER TABLE "public"."reports" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."selecting" (
    "uuid" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "selected_collection_id" bigint,
    "selected_selection_id" bigint,
    "selected_user_id" bigint,
    "selecting_collection_id" bigint NOT NULL,
    "selecting_user_id" bigint NOT NULL,
    "created_at" timestamp without time zone DEFAULT (CURRENT_TIMESTAMP AT TIME ZONE 'Asia/Seoul'::"text") NOT NULL,
    "selecting_selection_id" integer NOT NULL
);


ALTER TABLE "public"."selecting" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."userinfo" (
    "name" "text",
    "email" "text" NOT NULL,
    "description" "text",
    "image_file_path" "text",
    "user_id" integer NOT NULL,
    "created_at" "date" DEFAULT CURRENT_DATE NOT NULL
);


ALTER TABLE "public"."userinfo" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."selectingview" WITH ("security_invoker"='true') AS
 WITH "selecting_with_user" AS (
         SELECT DISTINCT "s"."selecting_user_id",
            "s"."selected_user_id",
            "s"."selecting_collection_id",
            "s"."selecting_selection_id",
            "s"."selected_collection_id",
            "s"."selected_selection_id",
            "date"("s"."created_at") AS "created_date",
            "to_char"("s"."created_at", 'HH24:MI:SS'::"text") AS "created_time",
            "u_1"."name" AS "selecting_user_name",
            "s"."selected_user_id" AS "owner_id"
           FROM ("public"."selecting" "s"
             JOIN "public"."userinfo" "u_1" ON (("u_1"."user_id" = "s"."selecting_user_id")))
        ), "selecting_data" AS (
         SELECT "swu"."selecting_user_id",
            "swu"."selecting_collection_id",
            "swu"."selecting_selection_id",
            "swu"."created_date",
            "swu"."created_time",
            "se"."title" AS "selection_name",
            "swu"."selecting_user_name" AS "user_name",
            "se"."image_file_paths"[1] AS "image_file_paths",
            "se"."keywords",
            "se"."owner_name",
            "swu"."owner_id",
            "json_build_object"('collection_id', "swu"."selecting_collection_id", 'selection_id', "swu"."selecting_selection_id", 'user_id', "swu"."selecting_user_id") AS "properties"
           FROM ("selecting_with_user" "swu"
             JOIN "public"."selections" "se" ON ((("se"."collection_id" = "swu"."selecting_collection_id") AND ("se"."user_id" = "swu"."selecting_user_id") AND ("se"."selection_id" = "swu"."selecting_selection_id"))))
        ), "grouped_selecting_data" AS (
         SELECT "sd"."selecting_user_id",
            "sd"."created_date",
            "json_agg"("json_build_object"('created_time', "sd"."created_time", 'selection_name', "sd"."selection_name", 'user_name', "sd"."user_name", 'image_file_path', "sd"."image_file_paths", 'keywords', "sd"."keywords", 'owner_name', "sd"."owner_name", 'owner_id', "sd"."owner_id", 'properties', "sd"."properties") ORDER BY "sd"."created_time") AS "properties_by_time"
           FROM "selecting_data" "sd"
          GROUP BY "sd"."selecting_user_id", "sd"."created_date"
        ), "selected_data" AS (
         SELECT "swu"."selected_user_id",
            "swu"."selected_collection_id",
            "swu"."selected_selection_id",
            "swu"."created_date",
            "swu"."created_time",
            "se"."title" AS "selection_name",
            "swu"."selecting_user_name" AS "user_name",
            "se"."image_file_paths"[1] AS "image_file_paths",
            "se"."keywords",
            "se"."owner_name",
            "swu"."owner_id",
            "json_build_object"('collection_id', "swu"."selected_collection_id", 'selection_id', "swu"."selected_selection_id", 'user_id', "swu"."selected_user_id") AS "properties"
           FROM ("selecting_with_user" "swu"
             JOIN "public"."selections" "se" ON ((("se"."collection_id" = "swu"."selected_collection_id") AND ("se"."user_id" = "swu"."selected_user_id") AND ("se"."selection_id" = "swu"."selected_selection_id"))))
        ), "grouped_selected_data" AS (
         SELECT "sd"."selected_user_id",
            "sd"."created_date",
            "json_agg"("json_build_object"('created_time', "sd"."created_time", 'selection_name', "sd"."selection_name", 'user_name', "sd"."user_name", 'image_file_path', "sd"."image_file_paths", 'keywords', "sd"."keywords", 'owner_name', "sd"."owner_name", 'owner_id', "sd"."owner_id", 'properties', "sd"."properties") ORDER BY "sd"."created_time") AS "properties_by_time"
           FROM "selected_data" "sd"
          GROUP BY "sd"."selected_user_id", "sd"."created_date"
        )
 SELECT "u"."user_id",
    COALESCE(( SELECT "json_agg"("json_build_object"('created_date', "gsd"."created_date", 'data', "gsd"."properties_by_time") ORDER BY "gsd"."created_date") AS "json_agg"
           FROM "grouped_selecting_data" "gsd"
          WHERE ("gsd"."selecting_user_id" = "u"."user_id")), "json_build_array"("json_build_object"('created_date', NULL::"unknown", 'data', NULL::"unknown"))) AS "selecting_properties",
    COALESCE(( SELECT "json_agg"("json_build_object"('created_date', "gsd2"."created_date", 'data', "gsd2"."properties_by_time") ORDER BY "gsd2"."created_date") AS "json_agg"
           FROM "grouped_selected_data" "gsd2"
          WHERE ("gsd2"."selected_user_id" = "u"."user_id")), "json_build_array"("json_build_object"('created_date', NULL::"unknown", 'data', NULL::"unknown"))) AS "selected_properties"
   FROM "public"."userinfo" "u"
  GROUP BY "u"."user_id";


ALTER TABLE "public"."selectingview" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."selections_selection_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE "public"."selections_selection_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."selections_selection_id_seq" OWNED BY "public"."selections"."selection_id";



CREATE TABLE IF NOT EXISTS "public"."useridentify" (
    "uuid" "uuid" DEFAULT "auth"."uid"() NOT NULL,
    "email" "text" NOT NULL,
    "user_id" integer NOT NULL
);


ALTER TABLE "public"."useridentify" OWNER TO "postgres";


ALTER TABLE "public"."useridentify" ALTER COLUMN "user_id" ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME "public"."useridentify_user_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);



CREATE SEQUENCE IF NOT EXISTS "public"."userinfo_user_id_seq"
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER TABLE "public"."userinfo_user_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."userinfo_user_id_seq" OWNED BY "public"."userinfo"."user_id";



ALTER TABLE ONLY "public"."keywordinfo" ALTER COLUMN "keyword_id" SET DEFAULT "nextval"('"public"."keywordinfo_keyword_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."selections" ALTER COLUMN "selection_id" SET DEFAULT "nextval"('"public"."selections_selection_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."block"
    ADD CONSTRAINT "block_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."collections"
    ADD CONSTRAINT "collections_pkey" PRIMARY KEY ("id", "user_id");



ALTER TABLE ONLY "public"."keywordinfo"
    ADD CONSTRAINT "keywordinfo_keyword_name_key" UNIQUE ("keyword_name");



ALTER TABLE ONLY "public"."keywordinfo"
    ADD CONSTRAINT "keywordinfo_pkey" PRIMARY KEY ("keyword_name");



ALTER TABLE ONLY "public"."likes"
    ADD CONSTRAINT "likes_pkey" PRIMARY KEY ("user_id", "collection_id");



ALTER TABLE ONLY "public"."reports"
    ADD CONSTRAINT "report_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."selecting"
    ADD CONSTRAINT "selecting_pkey" PRIMARY KEY ("uuid");



ALTER TABLE ONLY "public"."selections"
    ADD CONSTRAINT "selections_pkey" PRIMARY KEY ("collection_id", "selection_id");



ALTER TABLE ONLY "public"."selections"
    ADD CONSTRAINT "selections_selecting_uuid_key" UNIQUE ("selecting_uuid");



ALTER TABLE ONLY "public"."block"
    ADD CONSTRAINT "unique_block_combination" UNIQUE ("blocked_user_id", "blocker_user_id");



ALTER TABLE ONLY "public"."collections"
    ADD CONSTRAINT "unique_collection_id" UNIQUE ("id");



ALTER TABLE ONLY "public"."likes"
    ADD CONSTRAINT "unique_like" UNIQUE ("collection_id", "user_id");



ALTER TABLE ONLY "public"."userinfo"
    ADD CONSTRAINT "unique_userid_username" UNIQUE ("user_id", "name");



ALTER TABLE ONLY "public"."useridentify"
    ADD CONSTRAINT "useridentify_pkey" PRIMARY KEY ("user_id");



ALTER TABLE ONLY "public"."userinfo"
    ADD CONSTRAINT "userinfo_email_key" UNIQUE ("email");



ALTER TABLE ONLY "public"."userinfo"
    ADD CONSTRAINT "userinfo_name_key" UNIQUE ("name");



ALTER TABLE ONLY "public"."userinfo"
    ADD CONSTRAINT "userinfo_pkey" PRIMARY KEY ("user_id");



CREATE INDEX "idx_keywordinfo_id" ON "public"."keywordinfo" USING "btree" ("keyword_id");



CREATE INDEX "idx_keywordinfo_name" ON "public"."keywordinfo" USING "btree" ("keyword_name");



CREATE INDEX "idx_keywords_on_collections" ON "public"."collections" USING "gin" ("primary_keywords" "jsonb_path_ops");



CREATE INDEX "idx_keywords_on_selections" ON "public"."selections" USING "gin" ("keywords" "jsonb_path_ops");



CREATE INDEX "idx_selections_collection_id" ON "public"."selections" USING "btree" ("collection_id");



CREATE INDEX "idx_tags_gin" ON "public"."collections" USING "gin" ("tags" "jsonb_path_ops");



CREATE INDEX "userinfo_name_gin_idx" ON "public"."userinfo" USING "gin" ("to_tsvector"('"simple"'::"regconfig", "name"));



CREATE OR REPLACE TRIGGER "after_like_delete" AFTER DELETE ON "public"."likes" FOR EACH ROW EXECUTE FUNCTION "public"."update_like_num"();



CREATE OR REPLACE TRIGGER "after_like_insert" AFTER INSERT ON "public"."likes" FOR EACH ROW EXECUTE FUNCTION "public"."update_like_num"();



CREATE OR REPLACE TRIGGER "before_keyword_insert" BEFORE INSERT ON "public"."keywordinfo" FOR EACH ROW EXECUTE FUNCTION "public"."set_keyword_id"();



CREATE OR REPLACE TRIGGER "set_owner_name_before_insert" BEFORE INSERT ON "public"."selections" FOR EACH ROW EXECUTE FUNCTION "public"."set_owner_name_in_selections"();



CREATE OR REPLACE TRIGGER "set_user_name_before_insert" BEFORE INSERT ON "public"."collections" FOR EACH ROW EXECUTE FUNCTION "public"."set_user_name_in_collections"();



CREATE OR REPLACE TRIGGER "trigger_delete_report_post" AFTER UPDATE OF "status" ON "public"."reports" FOR EACH ROW WHEN (("new"."status" = true)) EXECUTE FUNCTION "public"."delete_report_post"();



CREATE OR REPLACE TRIGGER "trigger_delete_selecting" AFTER DELETE ON "public"."selections" FOR EACH ROW EXECUTE FUNCTION "public"."delete_selecting"();



CREATE OR REPLACE TRIGGER "trigger_insert_into_selecting" AFTER INSERT ON "public"."selections" FOR EACH ROW WHEN (("new"."is_selecting" = true)) EXECUTE FUNCTION "public"."insert_into_selecting"();



CREATE OR REPLACE TRIGGER "trigger_set_selecting_uuid" BEFORE INSERT ON "public"."selections" FOR EACH ROW EXECUTE FUNCTION "public"."generate_selecting_uuid"();



CREATE OR REPLACE TRIGGER "trigger_set_selection_id" BEFORE INSERT OR UPDATE ON "public"."selections" FOR EACH ROW EXECUTE FUNCTION "public"."set_selection_id"();



CREATE OR REPLACE TRIGGER "trigger_update_is_selecting_status" AFTER INSERT OR DELETE OR UPDATE ON "public"."selecting" FOR EACH ROW EXECUTE FUNCTION "public"."update_is_selecting_status"();



CREATE OR REPLACE TRIGGER "trigger_update_selecting" AFTER UPDATE ON "public"."selections" FOR EACH ROW EXECUTE FUNCTION "public"."update_selecting"();



CREATE OR REPLACE TRIGGER "update_primary_keywords_trigger" AFTER INSERT OR DELETE OR UPDATE ON "public"."selections" FOR EACH ROW EXECUTE FUNCTION "public"."update_primary_keywords_trigger_function"();



CREATE OR REPLACE TRIGGER "update_selection_num_trigger" AFTER INSERT OR DELETE OR UPDATE ON "public"."selections" FOR EACH ROW EXECUTE FUNCTION "public"."update_selection_num_in_collections"();



CREATE OR REPLACE TRIGGER "update_selection_trigger" AFTER UPDATE ON "public"."selections" FOR EACH ROW EXECUTE FUNCTION "public"."update_selecting_selection"();



ALTER TABLE ONLY "public"."block"
    ADD CONSTRAINT "block_blocked_user_id_fkey" FOREIGN KEY ("blocked_user_id") REFERENCES "public"."userinfo"("user_id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."block"
    ADD CONSTRAINT "block_blocker_user_id_fkey" FOREIGN KEY ("blocker_user_id") REFERENCES "public"."userinfo"("user_id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."collections"
    ADD CONSTRAINT "collection_user_id_user_name_fkey" FOREIGN KEY ("user_id", "user_name") REFERENCES "public"."userinfo"("user_id", "name") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."collections"
    ADD CONSTRAINT "collections_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."userinfo"("user_id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."likes"
    ADD CONSTRAINT "likes_collection_id_fkey" FOREIGN KEY ("collection_id") REFERENCES "public"."collections"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."likes"
    ADD CONSTRAINT "likes_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."userinfo"("user_id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."reports"
    ADD CONSTRAINT "reports_reporter_user_id_fkey" FOREIGN KEY ("reporter_user_id") REFERENCES "public"."userinfo"("user_id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."selecting"
    ADD CONSTRAINT "selecting_uuid_fkey" FOREIGN KEY ("uuid") REFERENCES "public"."selections"("selecting_uuid") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."selections"
    ADD CONSTRAINT "selections_collection_id_user_id_fkey" FOREIGN KEY ("collection_id", "user_id") REFERENCES "public"."collections"("id", "user_id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."selections"
    ADD CONSTRAINT "selections_owner_id_fkey" FOREIGN KEY ("owner_id") REFERENCES "public"."userinfo"("user_id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."selections"
    ADD CONSTRAINT "selections_owner_id_owner_name_fkey" FOREIGN KEY ("owner_id", "owner_name") REFERENCES "public"."userinfo"("user_id", "name") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."useridentify"
    ADD CONSTRAINT "useridentification_uuid_fkey" FOREIGN KEY ("uuid") REFERENCES "auth"."users"("id") ON UPDATE CASCADE ON DELETE CASCADE;



ALTER TABLE ONLY "public"."userinfo"
    ADD CONSTRAINT "userinfo_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."useridentify"("user_id") ON UPDATE CASCADE ON DELETE CASCADE;



CREATE POLICY "Allow delete all users" ON "public"."selecting" FOR DELETE USING (true);



CREATE POLICY "Allow delete by admin" ON "public"."collections" FOR DELETE TO "service_role" USING (true);



CREATE POLICY "Allow delete by admin" ON "public"."keywordinfo" FOR DELETE TO "service_role" USING (true);



CREATE POLICY "Allow delete by admin" ON "public"."reports" FOR DELETE TO "service_role" USING (true);



CREATE POLICY "Allow delete by admin" ON "public"."selections" FOR DELETE TO "service_role" USING (true);



CREATE POLICY "Allow delete by blocker user" ON "public"."block" FOR DELETE TO "service_role" USING (("blocker_user_id" = ( SELECT "useridentify"."user_id"
   FROM "public"."useridentify"
  WHERE ("useridentify"."uuid" = "auth"."uid"()))));



CREATE POLICY "Allow delete by owner" ON "public"."collections" FOR DELETE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."useridentify"
  WHERE (("useridentify"."user_id" = "collections"."user_id") AND ("useridentify"."uuid" = "auth"."uid"())))));



CREATE POLICY "Allow delete by owner" ON "public"."likes" FOR DELETE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."useridentify"
  WHERE (("useridentify"."uuid" = "auth"."uid"()) AND ("useridentify"."user_id" = "likes"."user_id")))));



CREATE POLICY "Allow delete by owner" ON "public"."useridentify" FOR DELETE TO "authenticated" USING (("auth"."uid"() = "uuid"));



CREATE POLICY "Allow delete by owner" ON "public"."userinfo" FOR DELETE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."useridentify"
  WHERE (("useridentify"."uuid" = "auth"."uid"()) AND ("useridentify"."user_id" = "userinfo"."user_id")))));



CREATE POLICY "Allow delete by selecting or selected user" ON "public"."selecting" FOR DELETE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."useridentify"
  WHERE (("useridentify"."uuid" = "auth"."uid"()) AND (("useridentify"."user_id" = "selecting"."selected_user_id") OR ("useridentify"."user_id" = "selecting"."selecting_user_id"))))));



CREATE POLICY "Allow delete by user" ON "public"."selections" FOR DELETE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."useridentify"
  WHERE (("useridentify"."user_id" = "selections"."user_id") AND ("useridentify"."uuid" = "auth"."uid"())))));



CREATE POLICY "Allow insert by auth user" ON "public"."block" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Allow insert by auth user" ON "public"."collections" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Allow insert by auth user" ON "public"."keywordinfo" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Allow insert by auth user" ON "public"."likes" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Allow insert by auth user" ON "public"."reports" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Allow insert by auth user" ON "public"."selecting" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Allow insert by auth user" ON "public"."selections" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Allow insert by auth user" ON "public"."useridentify" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Allow insert by auth user" ON "public"."userinfo" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Allow select based on is_private" ON "public"."collections" FOR SELECT TO "authenticated" USING ((("is_public" = true) OR (EXISTS ( SELECT 1
   FROM "public"."useridentify"
  WHERE (("useridentify"."user_id" = "collections"."user_id") AND ("useridentify"."uuid" = "auth"."uid"()))))));



CREATE POLICY "Allow select based on is_private" ON "public"."selections" FOR SELECT TO "authenticated" USING (((EXISTS ( SELECT 1
   FROM "public"."useridentify"
  WHERE (("useridentify"."user_id" = "selections"."user_id") AND ("useridentify"."uuid" = "auth"."uid"())))) OR (EXISTS ( SELECT 1
   FROM "public"."collections"
  WHERE (("collections"."id" = "selections"."collection_id") AND ("collections"."is_public" = true))))));



CREATE POLICY "Allow select by admin" ON "public"."reports" FOR SELECT TO "service_role" USING (true);



CREATE POLICY "Allow select by anyone" ON "public"."userinfo" FOR SELECT USING (true);



CREATE POLICY "Allow select by auth user" ON "public"."keywordinfo" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Allow select by auth user" ON "public"."likes" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Allow select by auth user" ON "public"."selecting" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Allow select by blocker user" ON "public"."block" FOR SELECT USING (("blocker_user_id" = ( SELECT "useridentify"."user_id"
   FROM "public"."useridentify"
  WHERE ("useridentify"."uuid" = "auth"."uid"()))));



CREATE POLICY "Allow select by owner" ON "public"."useridentify" FOR SELECT TO "authenticated" USING (("auth"."uid"() = "uuid"));



CREATE POLICY "Allow update by admin" ON "public"."block" FOR UPDATE TO "service_role" USING (true);



CREATE POLICY "Allow update by admin" ON "public"."likes" FOR UPDATE TO "service_role" USING (true);



CREATE POLICY "Allow update by admin" ON "public"."reports" FOR UPDATE TO "service_role" USING (true);



CREATE POLICY "Allow update by admin" ON "public"."useridentify" FOR UPDATE TO "service_role" USING (true);



CREATE POLICY "Allow update by auth user" ON "public"."keywordinfo" FOR UPDATE TO "authenticated" USING (true);



CREATE POLICY "Allow update by owner" ON "public"."collections" FOR UPDATE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."useridentify"
  WHERE (("useridentify"."user_id" = "collections"."user_id") AND ("useridentify"."uuid" = "auth"."uid"())))));



CREATE POLICY "Allow update by owner" ON "public"."userinfo" FOR UPDATE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."useridentify"
  WHERE (("useridentify"."uuid" = "auth"."uid"()) AND ("useridentify"."user_id" = "userinfo"."user_id")))));



CREATE POLICY "Allow update by owner or user" ON "public"."selections" FOR UPDATE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."useridentify"
  WHERE (("useridentify"."user_id" = "selections"."owner_id") OR (("useridentify"."user_id" = "selections"."user_id") AND ("useridentify"."uuid" = "auth"."uid"()))))));



CREATE POLICY "Allow update by selecting or selected user" ON "public"."selecting" FOR UPDATE TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."useridentify"
  WHERE (("useridentify"."uuid" = "auth"."uid"()) AND (("useridentify"."user_id" = "selecting"."selected_user_id") OR ("useridentify"."user_id" = "selecting"."selecting_user_id"))))));



ALTER TABLE "public"."block" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."collections" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."keywordinfo" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."likes" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."reports" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."selecting" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."selections" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."useridentify" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."userinfo" ENABLE ROW LEVEL SECURITY;




ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";


ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."block";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."collections";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."selections";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."userinfo";



GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "service_role";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
































































































































































































GRANT ALL ON FUNCTION "public"."delete_report_post"() TO "anon";
GRANT ALL ON FUNCTION "public"."delete_report_post"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."delete_report_post"() TO "service_role";



GRANT ALL ON FUNCTION "public"."delete_selecting"() TO "anon";
GRANT ALL ON FUNCTION "public"."delete_selecting"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."delete_selecting"() TO "service_role";



GRANT ALL ON FUNCTION "public"."delete_user_by_owner"("user_uuid" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."delete_user_by_owner"("user_uuid" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."delete_user_by_owner"("user_uuid" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."generate_selecting_uuid"() TO "anon";
GRANT ALL ON FUNCTION "public"."generate_selecting_uuid"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."generate_selecting_uuid"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_storage_files"("user_id" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_storage_files"("user_id" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_storage_files"("user_id" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."insert_into_selecting"() TO "anon";
GRANT ALL ON FUNCTION "public"."insert_into_selecting"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."insert_into_selecting"() TO "service_role";



GRANT ALL ON FUNCTION "public"."insert_user_data"() TO "anon";
GRANT ALL ON FUNCTION "public"."insert_user_data"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."insert_user_data"() TO "service_role";



GRANT ALL ON FUNCTION "public"."validate_tags_format"("tags" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."validate_tags_format"("tags" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."validate_tags_format"("tags" "jsonb") TO "service_role";



GRANT ALL ON TABLE "public"."collections" TO "anon";
GRANT ALL ON TABLE "public"."collections" TO "authenticated";
GRANT ALL ON TABLE "public"."collections" TO "service_role";



GRANT ALL ON FUNCTION "public"."search_collections_by_keyword"("query" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."search_collections_by_keyword"("query" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."search_collections_by_keyword"("query" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."search_collections_by_keyword"("query" "text", "blocker_user" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."search_collections_by_keyword"("query" "text", "blocker_user" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."search_collections_by_keyword"("query" "text", "blocker_user" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."search_collections_by_tag"("query" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."search_collections_by_tag"("query" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."search_collections_by_tag"("query" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."validate_items_format"("items" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."validate_items_format"("items" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."validate_items_format"("items" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."validate_keywords_format"("keywords" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."validate_keywords_format"("keywords" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."validate_keywords_format"("keywords" "jsonb") TO "service_role";



GRANT ALL ON TABLE "public"."selections" TO "anon";
GRANT ALL ON TABLE "public"."selections" TO "authenticated";
GRANT ALL ON TABLE "public"."selections" TO "service_role";



GRANT ALL ON FUNCTION "public"."search_selections_by_keyword"("query" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."search_selections_by_keyword"("query" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."search_selections_by_keyword"("query" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."search_users"("query" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."search_users"("query" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."search_users"("query" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."set_keyword_id"() TO "anon";
GRANT ALL ON FUNCTION "public"."set_keyword_id"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_keyword_id"() TO "service_role";



GRANT ALL ON FUNCTION "public"."set_owner_name_in_selections"() TO "anon";
GRANT ALL ON FUNCTION "public"."set_owner_name_in_selections"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_owner_name_in_selections"() TO "service_role";



GRANT ALL ON FUNCTION "public"."set_selection_id"() TO "anon";
GRANT ALL ON FUNCTION "public"."set_selection_id"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_selection_id"() TO "service_role";



GRANT ALL ON FUNCTION "public"."set_user_name_in_collections"() TO "anon";
GRANT ALL ON FUNCTION "public"."set_user_name_in_collections"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_user_name_in_collections"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_is_selecting_status"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_is_selecting_status"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_is_selecting_status"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_like_num"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_like_num"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_like_num"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_primary_keywords_trigger_function"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_primary_keywords_trigger_function"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_primary_keywords_trigger_function"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_selecting"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_selecting"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_selecting"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_selecting_selection"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_selecting_selection"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_selecting_selection"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_selection_num_in_collections"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_selection_num_in_collections"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_selection_num_in_collections"() TO "service_role";





















GRANT ALL ON TABLE "public"."block" TO "anon";
GRANT ALL ON TABLE "public"."block" TO "authenticated";
GRANT ALL ON TABLE "public"."block" TO "service_role";



GRANT ALL ON SEQUENCE "public"."block_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."block_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."block_id_seq" TO "service_role";



GRANT ALL ON SEQUENCE "public"."collection_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."collection_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."collection_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."keywordinfo" TO "anon";
GRANT ALL ON TABLE "public"."keywordinfo" TO "authenticated";
GRANT ALL ON TABLE "public"."keywordinfo" TO "service_role";



GRANT ALL ON SEQUENCE "public"."keywordinfo_keyword_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."keywordinfo_keyword_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."keywordinfo_keyword_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."likes" TO "anon";
GRANT ALL ON TABLE "public"."likes" TO "authenticated";
GRANT ALL ON TABLE "public"."likes" TO "service_role";



GRANT ALL ON SEQUENCE "public"."likes_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."likes_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."likes_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."reports" TO "anon";
GRANT ALL ON TABLE "public"."reports" TO "authenticated";
GRANT ALL ON TABLE "public"."reports" TO "service_role";



GRANT ALL ON TABLE "public"."selecting" TO "anon";
GRANT ALL ON TABLE "public"."selecting" TO "authenticated";
GRANT ALL ON TABLE "public"."selecting" TO "service_role";



GRANT ALL ON TABLE "public"."userinfo" TO "anon";
GRANT ALL ON TABLE "public"."userinfo" TO "authenticated";
GRANT ALL ON TABLE "public"."userinfo" TO "service_role";



GRANT ALL ON TABLE "public"."selectingview" TO "anon";
GRANT ALL ON TABLE "public"."selectingview" TO "authenticated";
GRANT ALL ON TABLE "public"."selectingview" TO "service_role";



GRANT ALL ON SEQUENCE "public"."selections_selection_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."selections_selection_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."selections_selection_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."useridentify" TO "anon";
GRANT ALL ON TABLE "public"."useridentify" TO "authenticated";
GRANT ALL ON TABLE "public"."useridentify" TO "service_role";



GRANT ALL ON SEQUENCE "public"."useridentify_user_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."useridentify_user_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."useridentify_user_id_seq" TO "service_role";



GRANT ALL ON SEQUENCE "public"."userinfo_user_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."userinfo_user_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."userinfo_user_id_seq" TO "service_role";



ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES  TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES  TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES  TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES  TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS  TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS  TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS  TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS  TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES  TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES  TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES  TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES  TO "service_role";






























RESET ALL;
