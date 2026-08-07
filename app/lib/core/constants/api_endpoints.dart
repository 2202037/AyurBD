/// REMOVED — safe to delete this file.
///
/// This was the PHP route table: every `/auth/login`, `/directory/doctors`,
/// `/admin/providers/{type}/moderate` path the app used to call, transcribed
/// from `backend/api/v1/index.php`.
///
/// There are no HTTP paths left to centralise. A Supabase repository names a
/// table, a view or an RPC instead, and PostgREST builds the URL — so the thing
/// this file existed to protect against (a hard-coded URL string drifting from
/// the backend's route table) can no longer happen.
///
/// Emptied rather than deleted only because the migration ran without shell
/// access. `git rm` it whenever convenient; nothing imports it.
///
/// Where the old paths went:
///   /auth/*                 ->  auth_repository.dart      (GoTrue)
///   /directory/*            ->  directory_repository.dart (tables + views)
///   /appointments/*         ->  appointment_repository.dart
///   /payments/*             ->  appointment_repository.dart
///   /patient/*              ->  patient_repository.dart
///   /provider/*             ->  provider_repository.dart
///   /pharmacy/*, /orders/*  ->  pharmacy_repository.dart
///   /blood-banks/*          ->  blood_repository.dart
///   /blog/*, /notifications ->  content_repository.dart
///   /admin/*                ->  admin_repository.dart
library;
