/// Payment receipt screen — shows the generated receipt after successful Stripe payment.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../../core/constants/app_theme.dart';
import '../../../core/network/api_exception.dart';
import '../../../models/appointment_models.dart';
import '../data/appointment_repository.dart';

class ReceiptScreen extends ConsumerStatefulWidget {
  const ReceiptScreen({super.key, required this.appointmentId});

  final int appointmentId;

  @override
  ConsumerState<ReceiptScreen> createState() => _ReceiptScreenState();
}

class _ReceiptScreenState extends ConsumerState<ReceiptScreen> {
  PaymentReceipt? _receipt;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadReceipt();
  }

  Future<void> _loadReceipt() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final repo = ref.read(appointmentRepositoryProvider);
      final receipt = await repo.getReceipt(appointmentId: widget.appointmentId);
      if (mounted) {
        setState(() {
          _receipt = receipt;
          _loading = false;
        });
      }
    } on ApiException catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message;
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = 'Failed to load receipt.';
          _loading = false;
        });
      }
    }
  }

  Future<void> _generatePdf() async {
    if (_receipt == null) return;

    final pdf = pw.Document();
    final r = _receipt!;

    pdf.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(32),
        build: (context) => [
          // Header
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  pw.Text('AYUR', style: pw.TextStyle(fontSize: 28, fontWeight: pw.FontWeight.bold, color: PdfColors.teal)),
                  pw.Text('Payment Receipt', style: pw.TextStyle(fontSize: 18, color: PdfColors.grey800)),
                ],
              ),
              pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.end,
                children: [
                  pw.Text('Receipt #${r.id}', style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold)),
                  pw.Text('Date: ${_fmtDate(r.paidAt)}', style: pw.TextStyle(fontSize: 12, color: PdfColors.grey600)),
                ],
              ),
            ],
          ),
          pw.SizedBox(height: 24),
          pw.Divider(thickness: 1, color: PdfColors.grey300),
          pw.SizedBox(height: 16),

          // Appointment Details
          pw.Text('Appointment Details', style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 8),
          _buildDetailRow('Doctor', r.doctorName),
          _buildDetailRow('Clinic', r.clinicName ?? 'N/A'),
          _buildDetailRow('Address', r.clinicAddress ?? 'N/A'),
          _buildDetailRow('Date', r.appointmentDate),
          _buildDetailRow('Time', r.appointmentTime),
          pw.SizedBox(height: 16),

          // Patient Details
          pw.Text('Patient Details', style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 8),
          _buildDetailRow('Name', r.patientName),
          pw.SizedBox(height: 16),

          // Payment Details
          pw.Text('Payment Details', style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 8),
          _buildDetailRow('Payment Method', r.paymentMethod),
          _buildDetailRow('Transaction ID', r.stripeTransactionId),
          _buildDetailRow('Gateway Reference', r.gatewayReference),
          _buildDetailRow('Paid At', _fmtDateTime(r.paidAt)),
          pw.SizedBox(height: 16),

          // Amount Breakdown
          pw.Text('Amount Breakdown', style: pw.TextStyle(fontSize: 16, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 8),
          pw.Table(
            border: pw.TableBorder.all(color: PdfColors.grey300),
            columnWidths: {
              0: const pw.FlexColumnWidth(3),
              1: const pw.FlexColumnWidth(2),
            },
            children: [
              _buildTableRow('Consultation Fee', _fmtMoney(r.fee), bold: true),
              _buildTableRow('Platform Fee (2%)', _fmtMoney(r.platformFee)),
              _buildTableRow('Doctor\'s Share', _fmtMoney(r.doctorShare)),
              pw.TableRow(
                decoration: const pw.BoxDecoration(color: PdfColors.teal50),
                children: [
                  pw.Padding(
                    padding: const pw.EdgeInsets.all(8),
                    child: pw.Text('Total Paid', style: pw.TextStyle(fontWeight: pw.FontWeight.bold)),
                  ),
                  pw.Padding(
                    padding: const pw.EdgeInsets.all(8),
                    child: pw.Text(_fmtMoney(r.amount), style: pw.TextStyle(fontWeight: pw.FontWeight.bold, color: PdfColors.teal)),
                  ),
                ],
              ),
            ],
          ),
          pw.SizedBox(height: 24),
          pw.Divider(thickness: 1, color: PdfColors.grey300),
          pw.SizedBox(height: 16),

          // Footer
          pw.Text(
            'Thank you for using AYUR. This receipt confirms your payment for the appointment.\n'
            'Please present the confirmation code at the clinic.',
            style: pw.TextStyle(fontSize: 11, color: PdfColors.grey600),
            textAlign: pw.TextAlign.center,
          ),
          pw.SizedBox(height: 8),
          pw.Text(
            'AYUR Healthcare Platform | https://ayurbd.com',
            style: pw.TextStyle(fontSize: 10, color: PdfColors.grey500),
            textAlign: pw.TextAlign.center,
          ),
        ],
      ),
    );

    await Printing.layoutPdf(onLayout: (format) async => pdf.save());
  }

  pw.TableRow _buildTableRow(String label, String value, {bool bold = false}) {
    return pw.TableRow(
      children: [
        pw.Padding(
          padding: const pw.EdgeInsets.all(8),
          child: pw.Text(label, style: pw.TextStyle(fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal)),
        ),
        pw.Padding(
          padding: const pw.EdgeInsets.all(8),
          child: pw.Text(value, style: pw.TextStyle(fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal), textAlign: pw.TextAlign.right),
        ),
      ],
    );
  }

  pw.Widget _buildDetailRow(String label, String value) {
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 2),
      child: pw.Row(
        children: [
          pw.SizedBox(width: 100, child: pw.Text(label, style: pw.TextStyle(fontWeight: pw.FontWeight.bold, fontSize: 11, color: PdfColors.grey700))),
          pw.Text(': ', style: pw.TextStyle(fontSize: 11, color: PdfColors.grey700)),
          pw.Expanded(child: pw.Text(value, style: pw.TextStyle(fontSize: 11))),
        ],
      ),
    );
  }

  String _fmtMoney(double amount) => '৳${amount.toStringAsFixed(2)}';
  String _fmtDate(DateTime dt) => '${dt.day}/${dt.month}/${dt.year}';
  String _fmtDateTime(DateTime dt) => '${dt.day}/${dt.month}/${dt.year} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Payment Receipt'),
        actions: [
          if (_receipt != null)
            IconButton(
              tooltip: 'Download PDF',
              icon: const Icon(Icons.picture_as_pdf),
              onPressed: _generatePdf,
            ),
          if (_receipt != null)
            IconButton(
              tooltip: 'Share',
              icon: const Icon(Icons.share),
              onPressed: _generatePdf, // Printing handles share
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.error_outline, size: 48, color: theme.colorScheme.error),
                        const SizedBox(height: 16),
                        Text(_error!, textAlign: TextAlign.center),
                        const SizedBox(height: 16),
                        FilledButton(onPressed: _loadReceipt, child: const Text('Retry')),
                      ],
                    ),
                  ),
                )
              : _receipt == null
                  ? const Center(child: Text('No receipt found.'))
                  : SingleChildScrollView(
                      padding: const EdgeInsets.all(AppTheme.gap),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Header Card
                          Card(
                            color: theme.colorScheme.primaryContainer,
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Row(
                                children: [
                                  Icon(Icons.receipt_long, size: 32, color: theme.colorScheme.primary),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text('Payment Receipt', style: theme.textTheme.titleLarge?.copyWith(color: theme.colorScheme.onPrimaryContainer)),
                                        Text('Receipt #${_receipt!.id}', style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onPrimaryContainer.withOpacity(0.8))),
                                      ],
                                    ),
                                  ),
                                  Text(_fmtDate(_receipt!.paidAt), style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onPrimaryContainer.withOpacity(0.7))),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),

                          // Appointment Details
                          _sectionTitle('Appointment Details'),
                          _detailCard([
                            _detailRow('Doctor', _receipt!.doctorName),
                            _detailRow('Clinic', _receipt!.clinicName ?? 'N/A'),
                            _detailRow('Address', _receipt!.clinicAddress ?? 'N/A'),
                            _detailRow('Date', _receipt!.appointmentDate),
                            _detailRow('Time', _receipt!.appointmentTime),
                          ]),
                          const SizedBox(height: 16),

                          // Patient Details
                          _sectionTitle('Patient Details'),
                          _detailCard([
                            _detailRow('Name', _receipt!.patientName),
                          ]),
                          const SizedBox(height: 16),

                          // Payment Details
                          _sectionTitle('Payment Details'),
                          _detailCard([
                            _detailRow('Payment Method', _receipt!.paymentMethod),
                            _detailRow('Transaction ID', _receipt!.stripeTransactionId),
                            _detailRow('Gateway Reference', _receipt!.gatewayReference),
                            _detailRow('Paid At', _fmtDateTime(_receipt!.paidAt)),
                          ]),
                          const SizedBox(height: 16),

                          // Amount Breakdown
                          _sectionTitle('Amount Breakdown'),
                          _detailCard([
                            _detailRow('Consultation Fee', _fmtMoney(_receipt!.fee)),
                            _detailRow('Platform Fee (2%)', _fmtMoney(_receipt!.platformFee)),
                            _detailRow('Doctor\'s Share', _fmtMoney(_receipt!.doctorShare)),
                            const Divider(),
                            _detailRow('Total Paid', _fmtMoney(_receipt!.amount), isTotal: true),
                          ]),
                          const SizedBox(height: 24),

                          // Action Buttons
                          Row(
                            children: [
                              Expanded(
                                child: OutlinedButton.icon(
                                  onPressed: _generatePdf,
                                  icon: const Icon(Icons.picture_as_pdf),
                                  label: const Text('Download PDF'),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: FilledButton.icon(
                                  onPressed: _generatePdf,
                                  icon: const Icon(Icons.share),
                                  label: const Text('Share'),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 24),
                          Center(
                            child: Text(
                              'Thank you for using AYUR. Please present the confirmation code at the clinic.',
                              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ],
                      ),
                    ),
    );
  }

  Widget _sectionTitle(String title) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(title, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
    );
  }

  Widget _detailCard(List<Widget> children) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        ),
      ),
    );
  }

  Widget _detailRow(String label, String value, {bool isTotal = false}) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: isTotal ? FontWeight.w600 : FontWeight.normal,
              color: isTotal ? theme.colorScheme.onSurface : theme.colorScheme.onSurfaceVariant,
            ),
          ),
          Text(
            value,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: isTotal ? FontWeight.w600 : FontWeight.normal,
              color: isTotal ? theme.colorScheme.primary : theme.colorScheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}