CREATE TRIGGER trigger_insert_user_data AFTER UPDATE OF email_confirmed_at ON auth.users FOR EACH ROW WHEN ((new.email_confirmed_at IS DISTINCT FROM old.email_confirmed_at)) EXECUTE FUNCTION insert_user_data();


create policy " Allow select by auth user"
on "storage"."objects"
as permissive
for select
to authenticated
using ((bucket_id = 'images'::text));


create policy " Allow update by owner"
on "storage"."objects"
as permissive
for update
to authenticated
using (((bucket_id = 'images'::text) AND (EXISTS ( SELECT 1
   FROM useridentify
  WHERE ((useridentify.user_id = ("substring"(objects.name, 'images/([^/]+)/'::text))::integer) AND (useridentify.uuid = (current_setting('request.jwt.claim.sub'::text))::uuid))))));


create policy "Allow delete by owner"
on "storage"."objects"
as permissive
for delete
to authenticated
using (((bucket_id = 'images'::text) AND (EXISTS ( SELECT 1
   FROM useridentify
  WHERE ((useridentify.uuid = auth.uid()) AND ((useridentify.user_id)::text = (storage.foldername(objects.name))[1]))))));


create policy "Allow insert by auth user"
on "storage"."objects"
as permissive
for insert
to authenticated
with check (((bucket_id = 'images'::text) AND (EXISTS ( SELECT 1
   FROM useridentify
  WHERE (useridentify.uuid = auth.uid())))));



