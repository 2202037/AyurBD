-- =====================================================================
-- AYUR — storage_setup.sql
-- Supabase Storage buckets and access policies. Run AFTER rls_policies.sql.
-- =====================================================================
--
-- NO INSERT STATEMENTS. Please read PART 0 before running: it explains
-- why, and what you must do by hand as a result.
--
-- ---------------------------------------------------------------------
-- WHAT THE OLD SYSTEM DID, AND DID NOT DO
--
-- The PHP backend accepted no uploads at all. There is no move_uploaded_file
-- and no $_FILES anywhere in backend/. The seven file-bearing columns were
-- filled by the separate PHP website, and the Flutter app only ever READ
-- them, through AppConfig.resolveAsset(), which prefixed a relative path
-- with the XAMPP asset URL.
--
-- So "image upload/download uses Supabase Storage" is genuinely new
-- capability, not a port. The download half replaces resolveAsset(); the
-- upload half is a feature the Flutter app never had.
--
-- ---------------------------------------------------------------------
-- THE SEVEN COLUMNS AND THEIR BUCKETS
--
--   users.profile_image             -> avatars             (public read)
--   doctors.bmdc_certificate        -> provider-documents  (PRIVATE)
--   hospitals.license_document      -> provider-documents  (PRIVATE)
--   clinics.license_document        -> provider-documents  (PRIVATE)
--   pharmacies.license_document     -> provider-documents  (PRIVATE)
--   pharmacy_products.image         -> product-images      (public read)
--   blogs.cover_image               -> blog-covers         (public read)
--
-- Each column stores the OBJECT PATH inside its bucket, e.g.
-- '3f9a.../avatar.jpg' -- never a full URL. Storing a path rather than a
-- URL is what let the old code survive a hostname change, and it is what
-- lets this code survive a project-ref change.
--
-- ---------------------------------------------------------------------
-- PATH CONVENTION -- this is load-bearing, not cosmetic
--
--   avatars/<user_uuid>/<filename>
--   provider-documents/<user_uuid>/<filename>
--   product-images/<pharmacy_id>/<filename>
--   blog-covers/<filename>
--
-- Storage has no foreign keys. The only thing a policy can reason about
-- is the object's own path, via storage.foldername(name), which splits it
-- into a text[]. Putting the owner's id in the FIRST path segment is
-- therefore what makes "you may only write your own files" expressible at
-- all. If the Dart layer uploads to a different shape, these policies
-- will reject it -- the convention is a contract between the two.
--
-- ---------------------------------------------------------------------
-- WHY provider-documents IS PRIVATE
--
-- A BMDC certificate and a trade licence are identity documents. In a
-- public bucket every object is readable by anyone who can guess or is
-- given the URL, with no token and no log. They stay private, read by the
-- owner and by admins only, and the app reaches them through a
-- time-limited signed URL (createSignedUrl) rather than a public one.
-- =====================================================================


-- =====================================================================
-- PART 0 — CREATING THE BUCKETS (a manual step, deliberately)
--
-- In Supabase a bucket IS a row in storage.buckets. The normal way to
-- create one in SQL is therefore an INSERT, and your migration brief
-- forbids INSERT statements without exception. Rather than quietly decide
-- that "configuration is not data" on your behalf, this file contains no
-- INSERT and you pick one of the two routes below.
--
-- Nothing else in this file depends on which you choose; the policies in
-- PART 1 onward attach to the buckets by name once they exist.
--
-- ---------------------------------------------------------------------
-- ROUTE A -- Dashboard (no SQL, nothing to un-forbid)
--
--   Storage -> New bucket, four times:
--
--     name: avatars              Public: ON
--     name: product-images       Public: ON
--     name: blog-covers          Public: ON
--     name: provider-documents   Public: OFF        <-- must stay off
--
--   Optional but recommended, under each bucket's settings:
--     avatars             file size limit 2 MB,  MIME image/*
--     product-images      file size limit 2 MB,  MIME image/*
--     blog-covers         file size limit 4 MB,  MIME image/*
--     provider-documents  file size limit 8 MB,  MIME image/*, application/pdf
--
-- ---------------------------------------------------------------------
-- ROUTE B -- CLI (also no SQL)
--
--   supabase storage create-bucket avatars            --public
--   supabase storage create-bucket product-images     --public
--   supabase storage create-bucket blog-covers        --public
--   supabase storage create-bucket provider-documents
--
-- ---------------------------------------------------------------------
-- ROUTE C -- SQL, if you decide a bucket row is configuration rather than
-- data and want to lift the no-INSERT rule for these four lines only.
-- Left commented out; this file executes no INSERT as written.
--
--   insert into storage.buckets (id, name, public, file_size_limit,
--                                allowed_mime_types)
--   values
--     ('avatars',            'avatars',            true,  2097152,
--      array['image/jpeg','image/png','image/webp']),
--     ('product-images',     'product-images',     true,  2097152,
--      array['image/jpeg','image/png','image/webp']),
--     ('blog-covers',        'blog-covers',        true,  4194304,
--      array['image/jpeg','image/png','image/webp']),
--     ('provider-documents', 'provider-documents', false, 8388608,
--      array['image/jpeg','image/png','image/webp','application/pdf'])
--   on conflict (id) do nothing;
--
-- ---------------------------------------------------------------------
-- Confirm the four exist and provider-documents is NOT public before
-- continuing (read-only):
--
--   select id, public, file_size_limit from storage.buckets order by id;
-- =====================================================================

-- =====================================================================
-- PART 1 — RLS ON storage.objects
--
-- Supabase ships storage.objects with RLS already enabled, so this is a
-- no-op safety net for a self-hosted or reset project. It is not an
-- ALTER that can weaken anything.
-- =====================================================================

--alter table storage.objects enable row level security;

-- Re-runnable: drop this file's own policies before recreating them.
-- Scoped to these names only -- nothing belonging to Supabase is touched.
drop policy if exists avatars_read_public          on storage.objects;
drop policy if exists avatars_insert_own           on storage.objects;
drop policy if exists avatars_update_own           on storage.objects;
drop policy if exists avatars_delete_own           on storage.objects;
drop policy if exists provider_docs_read_own       on storage.objects;
drop policy if exists provider_docs_read_admin     on storage.objects;
drop policy if exists provider_docs_insert_own     on storage.objects;
drop policy if exists provider_docs_update_own     on storage.objects;
drop policy if exists provider_docs_delete_own     on storage.objects;
drop policy if exists provider_docs_delete_admin   on storage.objects;
drop policy if exists product_images_read_public   on storage.objects;
drop policy if exists product_images_insert_owner  on storage.objects;
drop policy if exists product_images_update_owner  on storage.objects;
drop policy if exists product_images_delete_owner  on storage.objects;
drop policy if exists blog_covers_read_public      on storage.objects;
drop policy if exists blog_covers_write_admin      on storage.objects;
drop policy if exists blog_covers_update_admin     on storage.objects;
drop policy if exists blog_covers_delete_admin     on storage.objects;

-- =====================================================================
-- PART 2 — avatars  (public read, owner write)
--
-- Path: avatars/<user_uuid>/<filename>
--
-- Read is public because a doctor's photo appears in the directory to
-- signed-out visitors, exactly as it did when it was served off the PHP
-- host. Note that a public bucket also needs a SELECT policy here for
-- authenticated clients that list objects; "public" governs the CDN path,
-- not storage.objects.
-- =====================================================================

create policy avatars_read_public
  on storage.objects for select to anon, authenticated
  using (bucket_id = 'avatars');

-- (storage.foldername(name))[1] is the first path segment. Requiring it to
-- equal the caller's uuid is what makes this "your own folder only".
create policy avatars_insert_own
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create policy avatars_update_own
  on storage.objects for update to authenticated
  using (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  )
  with check (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create policy avatars_delete_own
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'avatars'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

-- =====================================================================
-- PART 3 — provider-documents  (PRIVATE: owner + admin only)
--
-- Path: provider-documents/<user_uuid>/<filename>
--
-- No anon policy of any kind. A signed-out visitor cannot read, list, or
-- probe this bucket. The admin read policy is what lets the moderation
-- screen show a licence before verifying a provider.
-- =====================================================================

create policy provider_docs_read_own
  on storage.objects for select to authenticated
  using (
    bucket_id = 'provider-documents'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create policy provider_docs_read_admin
  on storage.objects for select to authenticated
  using (bucket_id = 'provider-documents' and public.is_admin());

create policy provider_docs_insert_own
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'provider-documents'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create policy provider_docs_update_own
  on storage.objects for update to authenticated
  using (
    bucket_id = 'provider-documents'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  )
  with check (
    bucket_id = 'provider-documents'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create policy provider_docs_delete_own
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'provider-documents'
    and (storage.foldername(name))[1] = (select auth.uid())::text
  );

create policy provider_docs_delete_admin
  on storage.objects for delete to authenticated
  using (bucket_id = 'provider-documents' and public.is_admin());

-- =====================================================================
-- PART 4 — product-images  (public read, owning pharmacy writes)
--
-- Path: product-images/<pharmacy_id>/<filename>
--
-- The owner here is a PHARMACY, not a user, so the first segment is the
-- bigint pharmacies.id and the check goes through current_pharmacy_id().
-- That helper is SECURITY DEFINER and STABLE, so it resolves the caller's
-- pharmacy once per statement without recursing into pharmacies' RLS.
-- =====================================================================

create policy product_images_read_public
  on storage.objects for select to anon, authenticated
  using (bucket_id = 'product-images');

create policy product_images_insert_owner
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'product-images'
    and (storage.foldername(name))[1] = public.current_pharmacy_id()::text
  );

create policy product_images_update_owner
  on storage.objects for update to authenticated
  using (
    bucket_id = 'product-images'
    and (storage.foldername(name))[1] = public.current_pharmacy_id()::text
  )
  with check (
    bucket_id = 'product-images'
    and (storage.foldername(name))[1] = public.current_pharmacy_id()::text
  );

create policy product_images_delete_owner
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'product-images'
    and (storage.foldername(name))[1] = public.current_pharmacy_id()::text
  );

-- =====================================================================
-- PART 5 — blog-covers  (public read, admin write)
--
-- Path: blog-covers/<filename>  -- flat, no owner segment.
--
-- Authoring is admin-only in this app (blogs_insert_admin in
-- rls_policies.sql), so there is no per-user folder to enforce and the
-- write policies gate on is_admin() instead of on the path.
-- =====================================================================

create policy blog_covers_read_public
  on storage.objects for select to anon, authenticated
  using (bucket_id = 'blog-covers');

create policy blog_covers_write_admin
  on storage.objects for insert to authenticated
  with check (bucket_id = 'blog-covers' and public.is_admin());

create policy blog_covers_update_admin
  on storage.objects for update to authenticated
  using (bucket_id = 'blog-covers' and public.is_admin())
  with check (bucket_id = 'blog-covers' and public.is_admin());

create policy blog_covers_delete_admin
  on storage.objects for delete to authenticated
  using (bucket_id = 'blog-covers' and public.is_admin());

-- =====================================================================
-- PART 6 — NOTES FOR THE DART LAYER
--
-- 1. Upload, honouring the path convention above:
--
--      final uid = supabase.auth.currentUser!.id;
--      final path = '$uid/avatar.jpg';
--      await supabase.storage.from('avatars').uploadBinary(
--            path, bytes,
--            fileOptions: const FileOptions(upsert: true),
--          );
--      // store the PATH, never the URL
--      await supabase.from('users')
--          .update({'profile_image': path}).eq('id', uid);
--
--    upsert: true matters -- without it a second avatar upload fails with
--    409 rather than replacing the first.
--
-- 2. Download, public buckets -- this is what replaces resolveAsset():
--
--      supabase.storage.from('avatars').getPublicUrl(path)
--
--    Synchronous, no token, and safe to hand straight to
--    CachedNetworkImage.
--
-- 3. Download, provider-documents -- NOT public, so getPublicUrl returns
--    a URL that 400s. Sign it:
--
--      await supabase.storage.from('provider-documents')
--          .createSignedUrl(path, 60);   // seconds
--
--    Sign on demand and do not cache the result past its expiry.
--
-- 4. Migrating the values already in these columns. The rows currently
--    hold PHP-era relative paths such as 'uploads/avatars/12.jpg', which
--    match no object in any bucket. Nothing here rewrites them -- this
--    file creates no data. Until a file is re-uploaded through the app,
--    those paths resolve to a missing object, so keep the UI's existing
--    placeholder/errorWidget behaviour on every image. It is already
--    there because the PHP host could 404 too.
--
-- =====================================================================
-- PART 7 — VERIFICATION (read-only; run after applying)
-- =====================================================================
--
--   -- four buckets, and provider-documents must be public = false
--   select id, public from storage.buckets order by id;
--
--   -- this file's policies, 18 of them
--   select policyname, cmd, roles
--     from pg_policies
--    where schemaname = 'storage' and tablename = 'objects'
--    order by policyname;
--
--   -- no policy may grant anon anything on the private bucket.
--   -- must return zero rows:
--   select policyname
--     from pg_policies
--    where schemaname = 'storage' and tablename = 'objects'
--      and 'anon' = any (roles)
--      and qual like '%provider-documents%';

