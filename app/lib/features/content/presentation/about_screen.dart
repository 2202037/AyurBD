/// §13 — About.
///
/// Describes what the platform does and, just as importantly, what it does not.
/// The integrations that were deliberately skipped (Firebase push, Google Maps,
/// a real SMS gateway, a live payment gateway) are named here rather than left
/// for a patient to discover mid-emergency.
library;

import 'package:flutter/material.dart';

import '../../../app/router.dart';
import 'static_page_screen.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const StaticPageView(
      title: 'About',
      intro:
          'AYUR is a directory and appointment platform for ayurvedic and general '
          'healthcare in Bangladesh. It brings doctors, hospitals, clinics and '
          'pharmacies into one place so a patient can find a provider, book a '
          'visit, order medicine and keep a record of all three.',
      sections: [
        StaticSection(
          'What you can do',
          'Every feature below works against a live API — nothing on this list is '
          'a placeholder.',
          bullets: [
            'Search doctors by specialty, city and area, and read verified '
                'patient reviews before booking.',
            'Browse hospitals, clinics and pharmacies, with opening hours, '
                'facilities and contact numbers.',
            'Book an appointment against a doctor’s published slots and track '
                'it through confirmed, completed or cancelled.',
            'Order medicine from a pharmacy catalogue with a cart and checkout.',
            'Search the blood bank for a group and city, or post a request of '
                'your own.',
            'Reach emergency hotlines, which are dialable without signing in.',
            'Leave a review for any provider you have used, and manage your '
                'reviews from one screen.',
          ],
        ),
        StaticSection(
          'Who it is for',
          'Five kinds of account can be created, and each sees a different app. '
          'Patients get the directory, booking and shop. Doctors get a chamber '
          'schedule and their appointment queue. Hospitals, clinics and '
          'pharmacies get a profile and a review inbox. Administrators verify '
          'providers and moderate content.',
        ),
        StaticSection(
          'Provider verification',
          'A provider account is created in a pending state and does not appear '
          'in the directory until an administrator approves it. That check is '
          'the reason a registration form asks for a BMDC number, a trade '
          'licence or a drug licence: the numbers are what an administrator '
          'verifies against.',
        ),
        StaticSection(
          'What this build does not do',
          'Some integrations need keys or accounts that are not part of this '
          'project, and stubbing them convincingly would be worse than saying '
          'so plainly:',
          bullets: [
            'Emergency SMS is recorded, not transmitted. There is no SMS '
                'gateway wired up, so the request form cannot summon help — dial '
                'the hotline numbers instead.',
            'Payments are recorded as pending against an appointment or order. '
                'No card or mobile-wallet gateway is connected, so no money '
                'moves.',
            'Push notifications are stored server-side and read in-app. There '
                'is no Firebase project behind them, so nothing arrives while '
                'the app is closed.',
            'Nearby search returns a distance-sorted list rather than a map. '
                'The distances are real; the map needs an API key.',
          ],
        ),
        StaticSection(
          'Medical disclaimer',
          'AYUR lists providers and their self-reported details. It does not '
          'give medical advice, does not verify clinical outcomes, and is not a '
          'substitute for seeing a qualified practitioner. In an emergency, call '
          'a hotline or go to the nearest hospital.',
        ),
      ],
      footer: StaticPageButton(
        label: 'Emergency hotlines',
        route: Routes.emergency,
      ),
    );
  }
}
