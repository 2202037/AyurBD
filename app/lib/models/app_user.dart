/// The signed-in account. Fields mirror the `users` table columns the API's
/// `user_public()` returns; anything the site has that the API doesn't expose is
/// deliberately absent rather than guessed (§15).
library;

import '../core/utils/formatters.dart';

/// The six roles from §4. Kept as an enum so the router's guards can't typo a
/// role string.
enum UserRole {
  patient,
  doctor,
  clinic,
  pharmacy,
  hospital,
  admin;

  static UserRole fromString(Object? value) {
    final s = Fmt.str(value).toLowerCase();
    return UserRole.values.firstWhere(
      (r) => r.name == s,
      // An unknown role must not be treated as admin. Fall back to the least
      // privileged role so a schema change can never widen access.
      orElse: () => UserRole.patient,
    );
  }

  String get label {
    switch (this) {
      case UserRole.patient:
        return 'Patient';
      case UserRole.doctor:
        return 'Doctor';
      case UserRole.clinic:
        return 'Clinic';
      case UserRole.pharmacy:
        return 'Pharmacy';
      case UserRole.hospital:
        return 'Hospital';
      case UserRole.admin:
        return 'Administrator';
    }
  }

  /// Only the patient journey is built out in this slice; the rest land on a
  /// stub dashboard. See §13 phases 7+.
  bool get isPatient => this == UserRole.patient;
  bool get isProvider =>
      this == UserRole.doctor ||
      this == UserRole.clinic ||
      this == UserRole.pharmacy ||
      this == UserRole.hospital;
}

class AppUser {
  const AppUser({
    required this.id,
    required this.name,
    required this.email,
    required this.role,
    this.phone,
    this.address,
    this.city,
    this.image,
    this.bloodGroup,
    this.isActive = true,
    this.createdAt,
  });

  /// `users.id` is a uuid — the same value as `auth.users.id`, which is what
  /// makes `auth.uid()` usable in every RLS policy. It was an int under
  /// MySQL/PHP; it is a String here because a uuid has no integer form.
  ///
  /// Comparisons stay exactly as they were written (`u.id == meId` in
  /// admin_users_screen.dart, for instance) because `==` on String is still
  /// value equality.
  final String id;
  final String name;
  final String email;
  final UserRole role;
  final String? phone;
  final String? address;
  final String? city;

  /// Wire key is `profile_image` (the `users` column name), not `image`.
  /// Reading the wrong one blanks every avatar without erroring.
  final String? image;

  /// Added by `database/migration_v1.sql` (`users.blood_group`) — used to
  /// prefill a blood request. Null until that migration is run.
  final String? bloodGroup;

  /// `users.is_active`. Defaults to true for rows/sessions that predate the
  /// column; an admin flipping this to false bans the account (future
  /// appointments are cancelled and the user notified server-side).
  final bool isActive;

  final String? createdAt;

  factory AppUser.fromJson(Map<String, dynamic> json) => AppUser(
        // Fmt.str, not Fmt.toInt: the value is a uuid string. Parsing it as an
        // int would have yielded 0 for every user, so every `u.id == meId`
        // check would have been true at once.
        id: Fmt.str(json['id']),
        name: Fmt.str(json['name'], 'Unnamed'),
        email: Fmt.str(json['email']),
        role: UserRole.fromString(json['role']),
        phone: Fmt.str(json['phone']).isEmpty ? null : Fmt.str(json['phone']),
        address: Fmt.str(json['address']).isEmpty ? null : Fmt.str(json['address']),
        city: Fmt.str(json['city']).isEmpty ? null : Fmt.str(json['city']),
        // `profile_image` from the API; `image` is the key our own toJson()
        // wrote in earlier builds, kept so a cached session still renders.
        image: Fmt.str(json['profile_image'] ?? json['image']).isEmpty
            ? null
            : Fmt.str(json['profile_image'] ?? json['image']),
        bloodGroup:
            Fmt.str(json['blood_group']).isEmpty ? null : Fmt.str(json['blood_group']),
        isActive: Fmt.toBool(json['is_active'], true),
        createdAt: Fmt.str(json['created_at']).isEmpty ? null : Fmt.str(json['created_at']),
      );

  /// Written to secure storage so a restart doesn't need a network round-trip
  /// before it can show the right shell.
  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'email': email,
        'role': role.name,
        'phone': phone,
        'address': address,
        'city': city,
        'profile_image': image,
        'blood_group': bloodGroup,
        'created_at': createdAt,
      };

  AppUser copyWith({
    String? name,
    String? phone,
    String? address,
    String? city,
    String? image,
    String? bloodGroup,
  }) =>
      AppUser(
        id: id,
        name: name ?? this.name,
        email: email,
        role: role,
        phone: phone ?? this.phone,
        address: address ?? this.address,
        city: city ?? this.city,
        image: image ?? this.image,
        bloodGroup: bloodGroup ?? this.bloodGroup,
        isActive: isActive,
        createdAt: createdAt,
      );

  /// For the admin users list: flips [isActive] in place after a ban/un-ban,
  /// keeping the row where it is instead of refetching the page.
  AppUser copyWithActive(bool active) => AppUser(
        id: id,
        name: name,
        email: email,
        role: role,
        phone: phone,
        address: address,
        city: city,
        image: image,
        bloodGroup: bloodGroup,
        isActive: active,
        createdAt: createdAt,
      );
}
