revoke delete on table "public"."categoryinfo" from "anon";

revoke insert on table "public"."categoryinfo" from "anon";

revoke update on table "public"."categoryinfo" from "anon";

drop function if exists "public"."get_storage_files"(user_id text);


