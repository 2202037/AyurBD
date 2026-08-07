-- =====================================================================
-- 20260806000011_storage_bucket_limits.sql
--
-- Hardens the four Storage buckets.
--
-- BACKGROUND
--   storage_setup.sql deliberately does not create buckets (the migration
--   brief forbids data INSERTs), and the dashboard "limits" are optional.
--   On the live project all four buckets were created without them:
--   file_size_limit and allowed_mime_types are NULL (verified live), so
--   anyone with the anon key can upload an unlimited-size object of any
--   content type into the two public-write buckets (avatars,
--   product-images) and the private one.
--
--   This is configuration, not data, and it no-ops cleanly if a bucket
--   has not been created yet (0 rows updated), so it is safe on both a
--   fresh disposable project and the live one.
--
-- Bucket policy decided:
--   avatars, product-images    -> 2 MB, image/jpeg|png|webp
--   blog-covers                -> 4 MB, image/jpeg|png|webp
--   provider-documents         -> 8 MB, images + application/pdf
-- =====================================================================

update storage.buckets
   set file_size_limit    = 2097152,
       allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp']
 where id in ('avatars', 'product-images')
   and (file_size_limit    is distinct from 2097152
        or allowed_mime_types is distinct from
           array['image/jpeg', 'image/png', 'image/webp']);

update storage.buckets
   set file_size_limit    = 4194304,
       allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp']
 where id = 'blog-covers'
   and (file_size_limit    is distinct from 4194304
        or allowed_mime_types is distinct from
           array['image/jpeg', 'image/png', 'image/webp']);

update storage.buckets
   set file_size_limit    = 8388608,
       allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp', 'application/pdf']
 where id = 'provider-documents'
   and (file_size_limit    is distinct from 8388608
        or allowed_mime_types is distinct from
           array['image/jpeg', 'image/png', 'image/webp', 'application/pdf']);
