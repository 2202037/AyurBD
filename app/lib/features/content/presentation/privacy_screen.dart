/// §13 — Privacy.
///
/// Describes the data this build actually holds and where it is kept. Everything
/// here is checkable against the code: the field lists match the registration
/// rules, and the storage claims match `secure_store.dart` (JWT in the OS
/// keystore) and `prefs_store.dart` (theme mode only).
///
/// No analytics or crash-reporting SDK is bundled, so there is no third-party
/// data sharing to disclose — and saying so is more useful than a boilerplate
/// clause that implies otherwise.
library;

import 'package:flutter/material.dart';

import '../../../app/router.dart';
import 'static_page_screen.dart';

class PrivacyScreen extends StatelessWidget {
  const PrivacyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const StaticPageView(
      title: 'Privacy',
      intro:
          'This notice explains what data AYUR collects, why, and where it is '
          'stored. It describes this build as it is written, not as it might '
          'later become.',
      updated: '2 August 2026',
      sections: [
        StaticSection(
          'What every account stores',
          'Creating any account records your name, email address, password (as a '
          'one-way hash — it is never stored or transmitted in readable form), and '
          'optionally your phone number, address, city and gender.',
        ),
        StaticSection(
          'What a patient account adds',
          'Only what you enter or generate by using the app:',
          bullets: [
            'Your blood group, if you set one. It pre-fills blood requests.',
            'Appointments you book, including the doctor, date, slot and any '
                'reason for the visit you type in.',
            'Orders you place, including the delivery address and phone number '
                'given at checkout.',
            'Reviews you write, which are public and shown with your name.',
            'Blood requests and donor registrations you submit, which are '
                'visible to other users searching the blood bank.',
            'Emergency requests you submit, including the phone numbers and '
                'location text you enter.',
          ],
        ),
        StaticSection(
          'What a provider account adds',
          'Provider registration collects the professional details an '
          'administrator needs in order to verify you — a BMDC number for a '
          'doctor, a trade or drug licence number for a hospital, clinic or '
          'pharmacy, along with your chamber or premises address, hours and fees. '
          'Once approved, these details are shown publicly in the directory, '
          'because that is what the directory is for.',
        ),
        StaticSection(
          'Feedback',
          'The feedback form records your subject line, message and category. If '
          'you are signed in, it is linked to your account; if you are not, it '
          'records the name, email and phone you type in so we can reply. '
          'Feedback is read by administrators only and is never published.',
        ),
        StaticSection(
          'What is stored on your device',
          'Two things, and nothing else:',
          bullets: [
            'Your session token, kept in the operating system keystore '
                '(Keychain on iOS, EncryptedSharedPreferences on Android). It is '
                'deleted when you sign out.',
            'Your light/dark theme choice, kept in ordinary app preferences '
                'because it is not sensitive.',
          ],
        ),
        StaticSection(
          'What we do not collect',
          'No analytics or crash-reporting library is bundled in this app. There '
          'is no advertising identifier, no behavioural tracking, and no '
          'third-party SDK receiving your data. The app talks to its own API and '
          'nothing else.',
        ),
        StaticSection(
          'Location',
          'The app does not read your device location. Nearby search works from '
          'the city and area you type, and any distance shown is calculated by the '
          'server from those text values — not from GPS.',
        ),
        StaticSection(
          'Who can see your data',
          'A provider sees the appointments and orders placed with them, and the '
          'reviews written about them. Administrators can see all accounts and '
          'content in order to verify providers and moderate reviews and feedback; '
          'those actions are written to an audit log. No other user can see your '
          'account details.',
        ),
        StaticSection(
          'Notifications',
          'Notifications are stored on the server and shown when you open the '
          'notifications screen. If a push service is connected in future, the app '
          'would register a device token for that purpose; in this build no such '
          'service is configured.',
        ),
        StaticSection(
          'Retention and deletion',
          'Your account and its records are kept for as long as the account '
          'exists. To delete your account, contact us from the address below and '
          'we will remove it along with its appointments, orders, reviews and '
          'requests. Anonymised aggregates that cannot identify you may remain.',
        ),
        StaticSection(
          'Your choices',
          'You can edit your name, phone, address, city and blood group from the '
          'profile screen, change your password there, and delete any review you '
          'have written. For anything you cannot change yourself, use the contact '
          'page.',
        ),
        StaticSection(
          'Security',
          'Passwords are hashed, sessions use signed tokens with an expiry, and '
          'the token never leaves the device keystore. No system is perfectly '
          'secure, so use a password you do not reuse elsewhere and sign out on '
          'shared devices.',
        ),
      ],
      footer: StaticPageButton(
        label: 'Contact us about your data',
        route: Routes.contact,
      ),
    );
  }
}
