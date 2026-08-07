/// §13 — Terms of use.
///
/// What a user agrees to by creating an account and using the service. This copy
/// describes the build as it actually works: payments are recorded locally with
/// no card gateway, SMS is logged but not sent, and push requires an in-app check
/// rather than arriving as a system notification.
library;

import 'package:flutter/material.dart';

import 'static_page_screen.dart';

class TermsScreen extends StatelessWidget {
  const TermsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const StaticPageView(
      title: 'Terms of use',
      intro:
          'By creating an account or using this service, you agree to the terms below.',
      updated: '2 August 2026',
      sections: [
        StaticSection(
          'Who can use this',
          'You must be at least 18 years old, or using the app with a parent or '
          'guardian, to create an account. Provider accounts (doctor, hospital, '
          'clinic, pharmacy) may only be created by someone authorised to represent '
          'that provider.',
        ),
        StaticSection(
          'Account security',
          'You are responsible for keeping your password safe. Do not share your '
          'login with anyone else. If you believe someone has accessed your '
          'account without permission, change your password immediately from the '
          'profile screen.',
        ),
        StaticSection(
          'Accurate information',
          'The details you give when creating an account must be truthful and '
          'current. Provider accounts are verified by an administrator before they '
          'appear in the directory, and accounts found to contain false or '
          'misleading information will be disabled.',
        ),
        StaticSection(
          'Appointments and orders',
          'When you book an appointment or place an order, you are making a request '
          'to the provider. The provider is responsible for confirming the '
          'appointment or fulfilling the order. We record the transaction but do '
          'not guarantee that the provider will accept it.',
        ),
        StaticSection(
          'Payments',
          'Payment records are stored locally against each appointment and order. '
          'No card or mobile-wallet gateway is connected to this build, so no '
          'money moves. When a real payment gateway is integrated, you agree to '
          'honour the amounts shown and to pay the provider directly or through '
          'that gateway.',
        ),
        StaticSection(
          'Reviews',
          'You may leave a review for any provider whose services you have used. '
          'Reviews are public and attributed to your name. Do not include '
          'defamatory, abusive, or medically identifying content. We reserve the '
          'right to remove reviews that violate these rules.',
        ),
        StaticSection(
          'Prohibited conduct',
          'Do not use this service to harass, impersonate, defraud, or otherwise '
          'harm another person. Do not attempt to bypass security measures, '
          'reverse-engineer the app, or access data you are not authorised to see. '
          'Accounts that violate these rules will be disabled without notice.',
        ),
        StaticSection(
          'Medical disclaimer',
          'This app lists providers and their self-reported details. It does not '
          'give medical advice, does not verify clinical outcomes, and is not a '
          'substitute for seeing a qualified practitioner. Any decision to book an '
          'appointment, take medicine, or follow a treatment plan is yours alone.',
        ),
        StaticSection(
          'Availability',
          'We make no guarantee that the service will be available at all times. '
          'The app or API may be unavailable due to maintenance, a server fault, '
          'or other causes beyond our control. We are not liable for any loss that '
          'results from such unavailability.',
        ),
        StaticSection(
          'Changes to these terms',
          'We may update these terms from time to time. The date at the top of '
          'this page shows when they were last reviewed. Continued use of the '
          'service after a change means you accept the updated terms.',
        ),
        StaticSection(
          'Termination',
          'You may delete your account at any time by contacting us. We may '
          'disable your account if you violate these terms or if required by law. '
          'When an account is disabled, you lose access to its data.',
        ),
      ],
    );
  }
}
